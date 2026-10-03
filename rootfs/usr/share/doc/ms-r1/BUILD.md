# How this image is built

This document describes the reproducible build that turns the official
`Fedora-Workstation-Live-44-1.7.aarch64.iso` into
`Fedora-Workstation-Live-44-1.7-MS-R1.aarch64.iso`.

## Method

The build **modifies the official ISO in place** rather than rebuilding a
live image from a kickstart.  That keeps the image an unmodified Fedora 44
Workstation Live product - same packages, same anaconda, same GDM/Wayland
stack, same SELinux policy, same `ostree`/`dnf` configuration - and layers the
MS-R1 support on top.  Three layers are touched, and the distinction between
them matters:

| Layer | Path inside the ISO | What this build changes |
| --- | --- | --- |
| ISO 9660 / EFI | `/boot/...`, `/EFI/...` | new `linux-msr1` + `initrd-msr1`, new `grub.cfg` |
| live root filesystem | `/LiveOS/squashfs.img` (EROFS) | extra kernel modules, udev rules, systemd units, tools, docs, NPU userspace, `kernel-msr1` RPM |
| initramfs (ISO level) | `/boot/aarch64/loader/initrd-msr1` | MS-R1 module set + ACPI SSDT override |

The EFI boot chain is *not* replaced: `EFI/BOOT/BOOTAA64.EFI` (shim) loads
`EFI/BOOT/grubaa64.efi`, and `EFI/BOOT/grub.cfg` does

```
search --file --set=root /boot/0x503d6c7e
set prefix=($root)/boot/grub2
configfile ($root)/boot/grub2/grub.cfg
```

so replacing `/boot/grub2/grub.cfg` is what changes the menu.  The El Torito
UEFI boot image is replayed unchanged with `xorriso -boot_image any replay`,
which keeps Secure Boot (shim/MOK) and the vendor-signed `BOOTAA64.EFI`
intact.

## The live filesystem

The live root filesystem is rebuilt as an EROFS image with the same filesystem
UUID as the original (`F5D6509B-0553-0A4A-888F-0DC4B272DD9E`) so that the
live boot parameters and the dracut `LiveOS` module keep working.  Compression
defaults to `lzma,6` (matches the original image's LZMA and lands at 34% of the
raw tree, ~3.3 GB); override with `MSR1_EROFS_COMPRESS` to trade build time
against ISO size (`lz4hc` → 4.5 GB, `zstd19` → 3.77 GB).

The MS-R1 kernel tree is installed **once**, into `/usr/lib/modules/$KVER`, with
no duplicate `kernel/`-prefixed copy.  `depmod` indexes whatever it finds, so
stage 20 removes any stale directory first and then verifies that every entry
in the resulting `modules.dep` resolves to a real file before the ISO is
written.  The stock Fedora kernel tree (`/usr/lib/modules/6.19.10-300.fc44.aarch64/`)
is left untouched.

## The kernel

`6.19.10-300.fc44.msr1` = upstream Linux 6.19.10 (the version Fedora 44
ships) + the 139 patches of <https://github.com/Sky1-Linux/linux-sky1> +
this project's `config/msr1-kernel.fragment`, configured from Fedora's own
aarch64 config so that the module set stays a superset of the stock kernel.

Why a second kernel at all: the MS-R1 is an **ACPI-only** board and upstream
Linux 6.19 carries no driver for most of its peripherals.  The Sky1-Linux
patch set adds them - the Cadence PCIe host controller for the SoC itself
(`drivers/pci/pcie-cadence/` + `PCI_SKY1`), ACPI glue for every peripheral,
the CIX display driver and panthor GPU support, CIX audio, the CIX USB/PHY
controllers, networking and the ArmChina Zhouyi V3 NPU driver.  With the
stock Fedora kernel the MS-R1 has no working PCIe (so no NVMe, no 10 GbE),
no GPU and no NPU.

The stock kernel is **kept** in the image and is reachable from the boot menu,
so the image still boots on generic aarch64 hardware.

## The ACPI SSDT override

The ArmChina Zhouyi driver matches the NPU controller by ACPI HID `CIXH4000`
and then looks up one power domain per compute core:

```c
fwnode_for_each_child_node(p_dev->dev.fwnode, child) {
        if (!strncmp(acpi_device_bid(to_acpi_device_node(child)), "CRE", 3)) {
                cix_aipu_priv->pd_core[i] =
                        bus_find_device_by_fwnode(&platform_bus_type, child);
                pm_runtime_enable(cix_aipu_priv->pd_core[i]);   /* NULL deref */
```

`acpi_device_bid()` is the **ACPI object name** (`CRE0`/`CRE1`/`CRE2`), and
those children only carry `_ADR`, no `_HID`, so the ACPI bus never
enumerates them and `bus_find_device_by_fwnode()` returns `NULL` - an
immediate oops.  `acpi/Ssdt-MsR1-NpuCoreHid.asl` adds
`_HID = "CIXH4010"` and `_UID` to the three core scopes, which makes the ACPI
bus enumerate them and the platform bus enrol them, which is exactly what the
lookup needs.

The AML is delivered through `CONFIG_ACPI_TABLE_UPGRADE=y`: the kernel scans
the *raw* initramfs for an uncompressed `newc` cpio archive containing
`kernel/firmware/acpi/*.aml` (`drivers/acpi/tables.c:acpi_table_upgrade()`,
`lib/earlycpio.c:find_cpio_data()`).  Stage 40 therefore concatenates an
uncompressed early cpio in front of the zstd-compressed dracut image, which
is the same mechanism `dracut`'s early-microcode support uses and is handled
by the kernel's `unpack_to_rootfs()`.

## The initramfs

The MS-R1 initramfs is Fedora's own live initramfs (so that the live-session
dracut modules, `LiveOS` handling and the EROFS mount keep working) with the
kernel's release directory replaced by ours.  The module set is the one
Fedora's live initramfs already carries, re-taken from *our* tree, plus the
transitive dependency closure of everything matching
`cix|sky1|armchina|scmi|panthor|cadence|cpsw|dwc3|phy-cix|aipu|mbox-cix|erofs`.
Shipping all 5 600 modules instead would add ~200 MB to the initramfs for no
benefit.

## SELinux

`mkfs.erofs` is run twice over the same information on purpose: the overlay
files are created on the build host and would otherwise carry a `user_*`
context, so stage 20 relabels the whole tree with `setfiles -r` using the
image's own `file_contexts`, and stage 30 additionally passes
`--file-contexts` to `mkfs.erofs`.  The result is verified by mounting the new
image and reading `security.selinux` off `/usr/bin/bash` before the ISO is
written.

## Installing to disk

This ISO has **no anaconda kernel** (there is no `/images` directory), so
installation is started from the running live session:

```
sudo anaconda --kickstart=/usr/share/ms-r1/kernel-msr1.ks
```

The kickstart installs `kernel-msr1` from the offline RPM that stage 45 packs
into `/usr/share/ms-r1/kernel/`, so the installed system boots the MS-R1
kernel without any network access.

Without the kickstart an ordinary installation gets the stock Fedora kernel,
which is *not* usable on the MS-R1 (no PCIe/NPU).  Use the kickstart, or copy
`/boot/vmlinuz-6.19.10-300.fc44.msr1`, `/boot/initramfs-6.19.10-300.fc44.msr1.img`
and `/usr/lib/modules/6.19.10-300.fc44.msr1/` from the live session and add a
BLS entry for them.

## Validation

`./validate-msr1.sh` checks the finished ISO: ISO 9660 structure, volume id,
El Torito UEFI boot image, MBR, the EFI chain, the GRUB menu, the kernel
(`file`, EFI stub, no x86-64 binaries), the initramfs (cpio readable, module
set present, ACPI override present and checksum-valid), the live filesystem
(EROFS mount, module tree, BLS entry, udev rules, units, docs, BIOS files,
executable bits, RPM database, package architecture, broken symlinks, SELinux
contexts, no key material), the offline kernel RPM (version, architecture,
file list), and finally the SHA256.  The result is written to
`work/validate/report.txt`.

The check is non-destructive: the ISO is extracted with `xorriso -osirrox on`,
the EROFS image is mounted read-only with `pkexec mount -o ro,loop`, and every
check that needs root is reported as SKIP with the reason if `pkexec` is not
available.  As of the last build the report is 86 PASS / 0 FAIL / 0 SKIP.
