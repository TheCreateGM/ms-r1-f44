# Fedora Workstation 44 Live (aarch64) for the MINISFORUM MS-R1

This image is the official **Fedora Workstation 44 (1.7) aarch64 live image**
with the MINISFORUM MS-R1 platform integration added.  It is still a Fedora
image: the same package set, the same SELinux policy, the same official
repositories and GPG verification, the same GNOME/Wayland session, and it
installs to disk with the normal Anaconda workflow.

## What was added and why

| Component | Purpose |
|---|---|
| Kernel `6.19.10-300.fc44.msr1` | Upstream Linux 6.19.10 + the [Sky1-Linux](https://github.com/Sky1-Linux/linux-sky1) patch set (139 patches).  Fedora's own 6.19 kernel has no CIX SKY1 PCIe host bridge, no ACPI bindings for the CIX GPU/audio/NPU and no Sky1 clocks/regulators, so without this kernel the MS-R1 comes up without PCIe (no NVMe, no 10GbE, no GPU).  See `HARDWARE.md`. |
| `initramfs-6.19.10-300.fc44.msr1.img` | The Fedora live initramfs (dracut, `root=live:CDLABEL=…`) extended with the MS-R1 kernel modules **and** an ACPI SSDT override that adds the missing `_HID "CIXH4010"` to the NPU core devices. |
| NPU userspace, udev rules, services | CIX NOE UMD (`libnoe.so`) and the AIPU demo binaries from the MINISFORUM MS-R1 image, `/dev/aipu` permissions, `msr1-npu.service`, `msr1-npu-check`.  See `NPU.md`.  These vendor binaries carry no explicit redistribution licence - see `NPU.md`. |
| Power policy | `msr1-power.service` + `/etc/msr1-power.conf`: cpufreq/schedutil, ACPI CPPC EPP, NVMe APST, USB autosuspend tuning, PCIe runtime PM.  See `POWER.md`. |
| `kernel-msr1` RPM | The MS-R1 kernel packaged as an offline RPM in `/usr/share/ms-r1/kernel/`, plus `kernel-msr1.ks`, so an installation can put the MS-R1 kernel on disk.  See `BUILD.md`. |
| `msr1-info` | One-shot hardware/power/NPU summary for bug reports. |

## Boot menu

1. **Fedora Workstation Live (MS-R1 / CIX Sky1)** – *default*.
   The MS-R1 kernel with the parameters validated for this board.
2. **Fedora Workstation Live (MS-R1, verbose)** – same, plus `rd.debug shell`
   on the console; the console stays on the PL011 UART.
3. **Fedora Workstation Live (MS-R1, low power)** – same, plus
   `pcie_aspm=powersave` (experimental; see `POWER.md`).
4. **Fedora Workstation Live (stock Fedora kernel)** / **Test this media** –
   the unmodified Fedora 6.19.10 kernel, for other ARM64 machines and for
   checking the medium itself.
5. **Troubleshooting** – basic graphics (`nomodeset`), rescue shell
   (`rd.break=pre-mount`).

## First boot

The live session starts a GNOME Wayland session as the `liveuser` account
created by `livesys` on first boot, networking comes up through
NetworkManager (DHCP), and `dnf` works out of the box against the official
Fedora 44 repositories with GPG checking enabled.

## Installing to disk

This ISO carries no anaconda kernel, so the installer is started from the
running live session:

```
sudo anaconda --kickstart=/usr/share/ms-r1/kernel-msr1.ks
```

That installs the `kernel-msr1` RPM from
`/usr/share/ms-r1/kernel/`, so the installed system boots with the CIX/Sky1
support.  **Without** the kickstart, anaconda installs the stock Fedora
kernel, which does not drive the MS-R1's PCIe/GPU/NPU - use the kickstart.
Details in `BUILD.md`.

## Verification on this machine

Everything in this image was validated offline on an x86_64 Fedora 44 build
host (ISO structure, EFI/GRUB, AArch64 kernel and initramfs, RPM database,
architecture, SELinux labels, broken symlinks, secrets scan, …).  The image
was **not** booted on physical MS-R1 hardware, so hardware-level behaviour
(PCIe link training, GPU modesetting, NPU inference) is documented as
expected rather than measured.  See `/usr/share/doc/ms-r1/BUILD.md` for the
exact validation list.
