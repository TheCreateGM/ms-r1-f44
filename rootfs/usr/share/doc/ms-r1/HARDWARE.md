# MINISFORUM MS-R1 hardware and how this image drives it

## Platform

| Item | Value |
|---|---|
| Board | MS-R1, P1WSB / `MGP1WSB` |
| SoC | CIX P1 / CP8180, internal name **Sky1** |
| CPU | 12 cores: 8× Cortex-A720 (4 big @2.6 GHz + 4 medium) + 4× Cortex-A520, Armv9 |
| GPU | Arm Immortalis-G720 MC10 (10 cores), panthor driver, CIX display/DPTX output |
| NPU | CIX ZHOUYI V3, 3 cores, 28.8 TOPS (`CIXH4000` + 3× `CIXH4010`) |
| Memory | LPDDR5-5500, up to 64 GB, ECC capable (soldered) |
| Storage | M.2 2280 NVMe (PCIe 4.0 x4), U.2 adapter via PCIe slot |
| Network | 2× 10 GbE (Realtek RTL8127, r8125/r8126), M.2 E-Key Wi-Fi 6E + BT 5.3 (MediaTek), 2.5 GbE-capable USB |
| Display | HDMI 2.0, 2× USB-C (DP Alt Mode) |
| Audio | HDMI, 3.5 mm combo jack/line-in, ALC2xx HDA codec + CIX SOF/HDSS |
| PCIe | one PCIe 4.0 x16 slot (x8 electrical) for eGPU / U.2 / NIC |
| Firmware | EDK2/AA64 UEFI (NPU bring-up firmware added by the 2026-04-29 BIOS) |

## Why a separate kernel is required

The MS-R1 is an **ACPI** platform: it has no device tree that Linux can use,
everything (CPUs, GIC, timers, power buttons, PCIe root complex, GPU, HDA,
NPU) is described by the UEFI firmware in ACPI tables.

Fedora's own aarch64 kernel (6.19.10-300.fc44) does contain the first upstream
CIX SKY1 support that landed in Linux 6.19 (`ARCH_CIX`, the SCMI mailbox, the
Orion O6 device tree) – that support is **device-tree based**.  What is still
only in vendor/downstream trees is:

* the **PCIe host bridge** (`PCI_SKY1`, `PCIE_CADENCE_HOST`) – without it the
  kernel never finds the root complex, so NVMe, the RTL8127 NICs, the Wi-Fi
  module and any eGPU are invisible,
* the **ACPI resource lookup / clock / reset / GPIO / regulator glue** for the
  SoC (`CIX_ACPI_RESOURCE_LOOKUP`, `CLK_SKY1_ACPI`, …),
* the **ACPI bindings** for the GPU (panthor `CIXH5000`), the CIX HDA audio
  block and the NPU,
* the **Zhouyi NPU driver** (`drivers/misc/armchina-npu`).

The `Sky1-Linux` patch set (the one Armbian ships for the CIX P1 family)
provides all of the above and supports booting the same SoC from ACPI, which
is exactly what the MS-R1 needs.  This image therefore builds

    upstream Linux 6.19.10  +  Sky1-Linux patches-latest (139 patches)
    + Fedora's aarch64 kernel configuration (so the live image keeps all of
      Fedora's storage/graphics/security features)

and ships it as `6.19.10-300.fc44.msr1` **in addition to** Fedora's stock
kernel.  Nothing is removed: the stock kernel remains available from the boot
menu and stays the kernel the installed system falls back to.

## Kernel modules that carry the platform

* `pci-sky1`, `pcie-cadence-host` – PCIe root complex (NVMe, NIC, eGPU)
* `panthor`, `drm-cix`, `drm-linlondp`, `drm-trilin-*` – GPU and display out
* `armchina-npu` – ZHOUYI NPU (see `NPU.md`)
* `snd-hda-cix-ipbloq`, `snd-soc-cix`, `snd-soc-sof-cix` – audio
* `snd-r8125` / `snd-r8126` – NIC audio (Realtek)
* `cix-mailbox`, `arm-scmi`, `cpufreq-scmi`, `acpi-cppc-cpufreq` – clock and
  CPU frequency control
* `cadence-gpio`, `pinctrl-sky1`, `reset-sky1`, `regulator-sky1` – SoC glue
* `dwc3`, `cdns-usb`, `cix-usbdp-phy` – USB 3/Type-C (power delivery)

All of them are in `/usr/lib/modules/6.19.10-300.fc44.msr1/` **and** in the
initramfs, so a clean install to disk and an update of the live environment
keep the same hardware support.

## Kernel command line used

`root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image console=tty0 console=ttyAMA0,115200n8 pcie_aspm=off cma=512M clk_ignore_unused=1 cpufreq.default_governor=schedutil quiet rhgb`

| Argument | Why |
|---|---|
| `root=live:CDLABEL=Fedora-WS-Live-44`, `rd.live.image` | Fedora live session (unchanged from the stock entries). |
| `console=tty0 console=ttyAMA0,115200n8` | Graphical console plus the SoC PL011 UART (115200 8N1, the vendor rate) for early boot diagnostics. |
| `pcie_aspm=off` | MINISFORUM/CIX ship the MS-R1 with ASPM off; enabling L1.2 on this firmware is not validated and can leave a PCIe endpoint (NVMe/NIC/eGPU) with a dead link after resume.  A separate low-power boot entry turns it on. |
| `cma=512M` | Contiguous memory for the GPU (panthor) and NPU DMA buffers.  The CIX vendor boot args use 640 MB; 512 MB keeps the reservation modest while still avoiding CMA exhaustion. |
| `clk_ignore_unused=1` | SoC clocks that no driver claims are left enabled instead of shutting the clock gate down during boot (recommended for CIX P1 ACPI boots).  Costs a little idle power, avoids boot hangs. |
| `cpufreq.default_governor=schedutil` | schedutil is the Fedora default governor and reacts to CPU pressure without the wake latency of `ondemand`. |

Not used on purpose: `arm-smmu-v3.disable_bypass=0` (vendor-only parameter,
does not exist in upstream 6.19 – passing it would only produce an "unknown
kernel parameter" warning), `earlycon=pl011,0x040d0000` (vendor MMIO address,
the PL011 console already works through ACPI), `acpi=force` (arm64 uses ACPI
by default), `efi=noruntime` (only needed for the vendor device-tree boot path).
