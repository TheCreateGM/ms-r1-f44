# Power management on the MINISFORUM MS-R1

The policy is deliberately conservative: this is a 28 W desktop workstation,
so the goal is *low idle power without any risk of an unstable or sluggish
machine*, not maximum battery-style throttling.

## What is applied

`msr1-power.service` runs `/usr/libexec/ms-r1/msr1-power-apply` once at
`multi-user.target`.  It reads `/etc/msr1-power.conf` (every knob is
optional) and applies, in order:

1. **CPU frequency policy** – `schedutil` governor and the ACPI CPPC
   *energy performance preference* `balance_performance`.
   The MS-R1 is driven by ACPI CPPC (`CONFIG_ACPI_CPPC_CPUFREQ`) and SCMI
   performance domains (`CONFIG_ARM_SCMI_CPUFREQ`, supplied by the CIX mailbox
   driver), so this works without any vendor kernel.
2. **cpuidle** – left at the default `menu` governor so the firmware can use
   deep C-states.  `performance`/`poll` are *not* forced.
3. **PCIe** – runtime PM (`power/control=auto`) for display, USB and other
   non-storage peripherals; storage and Ethernet controllers are pinned to
   `on` so the root device and the network link never drop.
   ASPM is **not** changed here: see below.
4. **NVMe** – `nvme_core.apst_latency_tolerance_us` is lowered from the
   default 100000 µs to 2000 µs so the SSD enters a lower APST state on an
   idle desktop while staying well below any interactive latency.
5. **GPU/NPU** – left to their own runtime PM (`panthor`, the CIX display
   driver and the NPU driver manage power domains themselves).
6. **USB** – `60-msr1-power.rules` raises the runtime autosuspend delay from
   Fedora's 2 s default to 60 s for peripherals, and keeps hubs, USB mass
   storage and all block devices awake.

## Why ASPM stays off by default

The CIX/MINISFORUM firmware boots the MS-R1 with `pcie_aspm=off` (visible in
the vendor `GRUB/GRUB.CFG`).  Turning on L1.2 without a validated link-state
machine commonly leaves an endpoint (NVMe, RTL8127, eGPU) with a dead link
after suspend/resume or a warm reboot.  The image therefore ships:

* `Fedora Workstation Live (MS-R1 / CIX Sky1)` – `pcie_aspm=off` (default,
  matches vendor validation)
* `Fedora Workstation Live (MS-R1, low power)` – `pcie_aspm=powersave`
  (experimental; use only if your board survives suspend/resume with it, and
  set `MSR1_PCIE_ASPM_POLICY=powersave` in `/etc/msr1-power.conf` to keep the
  policy consistent after the kernel parameter is gone)

`clk_ignore_unused=1` is passed on the command line: unclaimed SoC clocks stay
enabled.  This costs a few milliwatts of idle power but avoids boot hangs on
clocks that no driver claims yet.

## Suspend / resume

Suspend-to-RAM is available through ACPI (the firmware exposes the power
button and the CIX patch set wires up the PM domains).  Because ASPM is off
by default, the PCIe link stays valid across suspend.  Hibernate
(`CONFIG_HIBERNATION=y`) is compiled in but, like Fedora's own ARM live
images, it is not the default.

## Tuning it

```sh
# more aggressive idle down-clocking (~5-10% lower idle power)
sudo sed -i 's/^MSR1_EPP=.*/MSR1_EPP="balance_power"/' /etc/msr1-power.conf
sudo systemctl restart msr1-power.service

# inspect what is actually applied
systemctl status msr1-power.service
journalctl -t msr1-power -b
cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
cat /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference
cat /sys/module/pcie_aspm/parameters/policy
```

`tuned` is present in the image and an `msr1-edge` profile is shipped in
`/usr/lib/tuned/`; the concrete settings above are applied by
`msr1-power.service` so they work with or without tuned.
