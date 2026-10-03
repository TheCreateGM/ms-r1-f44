# NPU support (CIX ZHOUYI V3, 28.8 TOPS) on the MINISFORUM MS-R1

## What the MS-R1 NPU needs

1. **Kernel driver** – the ZHOUYI (ArmChina) NPU driver.  This image uses the
   upstream-style `drivers/misc/armchina-npu` driver that comes with the
   Sky1-Linux patch set (`CONFIG_ARMCHINA_NPU=m`,
   `CONFIG_ARMCHINA_NPU_ARCH_V3=y`).  It is a platform driver matched by ACPI
   HID **`CIXH4000`**, creates a misc character device **`/dev/aipu`**, and
   enumerates the three per-core power domains from the child devices
   `CRE0/CRE1/CRE2`.
2. **ACPI description** – the firmware must publish `\_SB.NPU0` (`CIXH4000`).
   Firmware images that do publish it but omit the child `_HID` need the SSDT
   override below.
3. **Userspace driver (UMD)** – CIX's NOE runtime (`libnoe.so`) which opens
   `/dev/aipu` and drives inference.
4. **Firmware** – the NPU bring-up firmware is loaded by the **UEFI**, not by
   the kernel driver (`aipu.ko`/`armchina_npu` never call
   `request_firmware()`), so it is a firmware-level requirement.

## What this image ships

| Item | Location | Status |
|---|---|---|
| NPU kernel driver | `/usr/lib/modules/6.19.10-300.fc44.msr1/kernel/drivers/misc/armchina-npu.ko.xz` and in the initramfs | built, ACPI-matched, auto-loaded by udev (MODULE_DEVICE_TABLE) |
| ACPI SSDT override | `kernel/firmware/acpi/ssdt-msr1-npu-core-hid.aml` inside `initramfs-6.19.10-300.fc44.msr1.img` | loaded by `CONFIG_ACPI_TABLE_UPGRADE` |
| Device permissions | `/usr/lib/udev/rules.d/60-msr1-npu.rules` (`/dev/aipu` → `video`, `uaccess`) | active |
| Loader/status unit | `msr1-npu.service` → `/usr/libexec/ms-r1/msr1-npu-start` | enabled, fails safe |
| Status tool | `/usr/bin/msr1-npu-check` (`--smoke` also runs the NOE smoke test) | – |
| NOE userspace | `/usr/lib/ms-r1/npu/lib/{libnoe.so,libaipudrv.so}`, `/usr/lib/ms-r1/npu/bin/{noe_sd,noe_llm,aipu_sd_demo,aipu_llm_test}` | from the MINISFORUM MS-R1 image 2026-04-29 |
| Firmware update files | `/usr/share/ms-r1/BIOS/` – `cix_flash_all2_MGP1WSB_20260429.bin`, `FlashUpdate.efi` | for the NPU-capable firmware |

### The SSDT override

`/kernel/firmware/acpi/ssdt-msr1-npu-core-hid.aml` is an override table that
re-opens `\_SB.NPU0.CRE0/CRE1/CRE2` and adds `Name (_HID, "CIXH4010")` plus a
`_UID`.  Without it those children are not enumerated as platform devices and
the driver's `bus_find_device_by_fwnode()` returns NULL, which leads to
`pm_runtime_enable(NULL)`.  The kernel loads the table from an uncompressed
cpio archive prepended to the initramfs (the mechanism documented in
`Documentation/admin-guide/acpi/initrd_table_override.rst`).  The source ASL
is in `/usr/share/doc/ms-r1/` (BSD-2-Clause-Patent).

Verify it was applied:

```sh
dmesg | grep -i "ACPI table found in initrd"
ls /sys/bus/acpi/devices/CIXH4010:0*      # expect 3 cores
```

## What works immediately, and what does not

* **Firmware level.**  The original 2025-10 firmware (build 1.0) neither
  describes the NPU in ACPI nor contains the NPU bring-up firmware; on that
  BIOS the NPU cannot be enabled by any software.  MINISFORUM ships
  `2026-04-29-UpdateNPUSupport` (edk2 1.2.1+) which fixes both; the flash
  image is included in `/usr/share/ms-r1/BIOS/` with `FlashUpdate.efi`.
  See the upstream report: minisforum-docs/MS-R1-Docs issue #24.
* **Kernel level.**  With the MS-R1 kernel of this image, the NPU driver is
  present, ACPI-matched and safe: if the cores are not enumerable
  `msr1-npu.service` refuses to load the module instead of oopsing.
* **ABI level.**  `libnoe.so` from the vendor image targets the CIX SDK's
  k6.6 ioctl ABI.  The `armchina-npu` driver in the patch set is the
  mainline-style driver and uses the current (v3) UMD structures, so the
  vendor `libnoe.so` **may** reject job submissions with
  `[UMD ERR] aipu.cpp: schedule job [fail]`.  If that happens, the fix is a
  matching UMD build from `cixtech/cix_opensource__release__npu_driver`
  (branch `cix_mainline_dev`) – the kernel side is already in place and no
  kernel change is required.
* **Models.**  The demo binaries need CIX-compiled model packages.  The
  tokenizer and seed files are shipped under `/usr/lib/ms-r1/npu/share/`.
  Run them with:

  ```sh
  msr1-npu-check --smoke      # device + UMD smoke test, no model needed
  cd /usr/lib/ms-r1/npu/share && \
      LD_LIBRARY_PATH=/usr/lib/ms-r1/npu/lib /usr/lib/ms-r1/npu/bin/noe_sd
  ```

## Licensing / provenance of the shipped binaries

`libnoe.so`, `libaipudrv.so` and the `*_demo` binaries are the proprietary
CIX/MINISFORUM userspace components taken from the official MS-R1 system image
(`linux-fs-20260429.sdcard`, shipped with the board).  They carry **no
explicit redistribution licence**, so they are redistributed here unmodified
and only for use with the MS-R1 NPU.  If you are redistributing this ISO
beyond your own machine, rebuild without them:

```
MSR1_WITH_NPU_UMD=0 ./build-msr1.sh
```

The kernel driver itself is GPL (`drivers/misc/armchina-npu`, from the
Sky1-Linux patch set) and the SSDT override is BSD-2-Clause-Patent; neither
has this restriction, so the NPU still enumerates with `MSR1_WITH_NPU_UMD=0`
and only the vendor demo programs are absent.

Neither the kernel driver nor the SSDT override has been executed against
real MS-R1 hardware, and the `libnoe.so` ABI question above is unresolved.
Nothing in this image should be read as a claim that NPU inference works -
see `BUILD.md` for what was and was not tested.
