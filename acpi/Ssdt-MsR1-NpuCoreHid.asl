/** @file
 *  Ssdt-MsR1-NpuCoreHid.asl - ACPI SSDT override for the MINISFORUM MS-R1
 *  (CIX CP8180 / P1 "Sky1" SoC, ZHOUYI V3 NPU).
 *
 *  Loaded by the kernel through CONFIG_ACPI_TABLE_UPGRADE from an uncompressed
 *  cpio archive that this image prepends to the MS-R1 initramfs
 * (see /kernel/firmware/acpi/ inside the initramfs cpio).
 *
 *  Why this is needed
 *  ------------------
 *  The MS-R1 DSDT exposes the NPU as \_SB.NPU0 (_HID "CIXH4000") with three
 *  core children \_SB.NPU0.CRE0/CRE1/CRE2.  Those children only carry
 *  _ADR=Zero, no _HID.  ACPI only enumerates a device with an _HID (or _HID
 *  plus _UID) as a platform device, so the ArmChina Zhouyi NPU driver
 * (drivers/misc/armchina-npu, matched by HID CIXH4000) cannot find its
 *  per-core power domains:
 *
 *      cix_aipu_priv->pd_core[i] = bus_find_device_by_fwnode(&platform_bus_type, child);
 *      pm_runtime_enable(cix_aipu_priv->pd_core[i]);
 *
 *  and the lookup returns NULL.  The CIX reference ACPI source
 * (cixtech/edk2-platforms, Dsdt-NPU.asl) does set _HID = "CIXH4010" on each
 *  core; the firmware images that do publish the NPU (2026-03-12 ARM
 *  SystemReady and 2026-04-29 "UpdateNPUSupport") drop it.  This SSDT simply
 *  adds it back.
 *
 *  ACPI namespaces are global across tables, so re-opening a Scope declared in
 *  the DSDT and adding a Name to it is well defined and does not require a
 *  DSDT replacement.
 *
 *  If a future firmware release already provides these _HIDs, the Name()
 *  operators simply rewrite the same value, so the override stays harmless.
 *
 *  NOTE: on the original 2025-10 BIOS (build 1.0) the NPU is not described in
 *  ACPI at all and the NPU bring-up firmware is missing; that firmware has to
 *  be flashed first (see /usr/share/doc/ms-r1/NPU.md).
 *
 *  SPDX-License-Identifier: BSD-2-Clause-Patent
 *  Source: https://github.com/FyrbyAdditive/ms-r1-npu-hack (Ssdt-MsR1-NpuCoreHid.asl)
**/

DefinitionBlock ("ssdt-msr1-npu-core-hid.aml", "SSDT", 2, "MSR1", "NPUCRHID", 0x00000001)
{
  External (\_SB.NPU0,      DeviceObj)
  External (\_SB.NPU0.CRE0, DeviceObj)
  External (\_SB.NPU0.CRE1, DeviceObj)
  External (\_SB.NPU0.CRE2, DeviceObj)

  Scope (\_SB.NPU0.CRE0)
  {
    Name (_HID, "CIXH4010")
    Name (_UID, 0x0)
  }

  Scope (\_SB.NPU0.CRE1)
  {
    Name (_HID, "CIXH4010")
    Name (_UID, 0x1)
  }

  Scope (\_SB.NPU0.CRE2)
  {
    Name (_HID, "CIXH4010")
    Name (_UID, 0x2)
  }
}
