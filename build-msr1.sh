#!/usr/bin/env bash
#
# build-msr1.sh - Build a Fedora Workstation 44 Live (aarch64) ISO for the
#                  MINISFORUM MS-R1 (CIX CP8180 "CP8180" / P1 / "Sky1" SoC).
#
# The official ISO Fedora-Workstation-Live-44-1.7.aarch64.iso is used as the
# base.  What this build adds on top of it:
#   * kernel 6.19.10-300.fc44.msr1 = upstream 6.19.10 + the Sky1-Linux patch
#     set (CIX PCIe host bridge, ACPI glue, panthor/CIX display, CIX audio,
#     ARM China Zhouyi NPU, SCMI cpufreq, ...) so the MS-R1 has working
#     PCIe/NVMe/network/GPU/audio/NPU under Fedora,
#   * an MS-R1 initramfs (Fedora live dracut initramfs + MS-R1 modules + the
#     ACPI SSDT override that adds the missing NPU core _HIDs),
#   * NPU userspace (CIX NOE UMD + demo binaries), udev rules, services,
#   * a conservative MS-R1 power policy,
#   * a BLS entry + kernel files so the same stack survives installation.
#
# Usage:  ./build-msr1.sh [stage ...]      stages: 0 10 15 20 30 40 50 all
#
set -euo pipefail

# ------------------------------------------------------------------ settings
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$PROJ/work"; LOGS="$WORK/logs"; STAGE="$WORK/stage"
KVER="6.19.10-300.fc44.msr1"
BASE_ISO="$PROJ/Fedora-Workstation-Live-44-1.7.aarch64.iso"
OUT_ISO="$PROJ/Fedora-Workstation-Live-44-1.7-MS-R1.aarch64.iso"
VOLID="Fedora-WS-Live-44"
LINUX_VER="6.19.10"
KERNEL_TREE="$WORK/kernel/try-${LINUX_VER}"
STOCK_KVER="6.19.10-300.fc44.aarch64"
CROSS="aarch64-linux-gnu-"
JOBS="$(nproc)"
MACHINE_ID="871c57ed5c934e71b70201ab24e95a64"

ROOTFS="$STAGE/rootfs"                     # writable copy of the live rootfs
INITRD="$STAGE/initramfs-msr1"             # extracted dracut initramfs
KOUT="$WORK/out/kernel"                    # kernel artefacts

# verified kernel command line for the MS-R1 (see rootfs/usr/share/doc/ms-r1/HARDWARE.md)
MSR1_ARGS_COMMON="console=tty0 console=ttyAMA0,115200n8 cma=512M clk_ignore_unused=1 cpufreq.default_governor=schedutil"
MSR1_ARGS="pcie_aspm=off $MSR1_ARGS_COMMON"
MSR1_ARGS_LOWPOWER="pcie_aspm=powersave pcie_aspm_policy=default $MSR1_ARGS_COMMON"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOGS/build.log"; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOGS/build.log" >&2; exit 1; }
run()  { "$@" >>"$LOGS/build.log" 2>&1 || die "command failed: $*"; }
asroot(){ pkexec "$@"; }

# ============================================================== stage 00: env
stage_env() {
  mkdir -p "$LOGS" "$STAGE" "$WORK/out"
  for t in xorriso 7z cpio zstd make gcc patch iasl mkfs.erofs setfiles rpm python3 xz tar; do
    command -v "$t" >/dev/null || die "missing required tool: $t"
  done
  [ -f "$BASE_ISO" ] || die "base ISO not found: $BASE_ISO"
  log "stage 00 env OK - base ISO $(du -h "$BASE_ISO" | cut -f1), $JOBS jobs"
}

# ====================================================== stage 10: MS-R1 kernel
stage_kernel() {
  log "stage 10: MS-R1 kernel (Linux $LINUX_VER + Sky1 patch set)"
  if [ ! -d "$KERNEL_TREE" ]; then
    local tar=/tmp/linux-${LINUX_VER}.tar.xz
    [ -f "$tar" ] || { log "downloading kernel source"; wget -q -O "$tar" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz"; }
    log "unpacking kernel source"; cp -a "/tmp/linux-${LINUX_VER}" "$KERNEL_TREE"
  fi
  [ -d "$WORK/ref/linux-sky1" ] || { log "cloning Sky1-Linux"; git clone --depth 1 https://github.com/Sky1-Linux/linux-sky1.git "$WORK/ref/linux-sky1"; }
  if [ ! -f "$KERNEL_TREE/.sky1-patched" ]; then
    local a=0 f=0
    : >"$LOGS/patches-sky1.log"
    for p in "$WORK/ref/linux-sky1/patches-latest"/*.patch; do
      if patch -d "$KERNEL_TREE" -p1 --forward --batch -s <"$p" >>"$LOGS/patches-sky1.log" 2>&1; then a=$((a+1)); else
        f=$((f+1)); log "  patch needs manual attention: $(basename "$p")"; fi
    done
    find "$KERNEL_TREE" \( -name '*.orig' -o -name '*.rej' \) -delete
    log "  $a patches applied, $f skipped"; touch "$KERNEL_TREE/.sky1-patched"
  fi
  if [ ! -f "$KERNEL_TREE/.config.msr1" ]; then
    log "configuring kernel (Fedora aarch64 config + Sky1 options + MS-R1 fragment)"
    local fedcfg="$WORK/kernel/fedora-aarch64.config"
    [ -f "$fedcfg" ] || {
      wget -q -O /tmp/kernel-core.aarch64.rpm "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/aarch64/os/Packages/k/kernel-core-6.19.10-300.fc44.aarch64.rpm"
      (cd "$WORK/kernel" && rpm2cpio /tmp/kernel-core.aarch64.rpm | cpio -idm --quiet "./lib/modules/*" 2>/dev/null)
      cp "$WORK/kernel/lib/modules/$STOCK_KVER/config" "$fedcfg"; }
    cp "$fedcfg" "$KERNEL_TREE/.config-fedora"
    cp "$WORK/ref/linux-sky1/config/config.sky1-latest" "$KERNEL_TREE/.config-sky1"
    ( cd "$KERNEL_TREE"
      ./scripts/kconfig/merge_config.sh -m -O . .config-fedora .config-sky1 >/dev/null
      ./scripts/kconfig/merge_config.sh -m -O . .config "$PROJ/config/msr1-kernel.fragment" >/dev/null
      # Fedora's config names an absolute firmware directory that only exists
      # inside the RPM build root; building outside it makes kbuild fail.
      sed -i -e '/^CONFIG_EXTRA_FIRMWARE=/d' -e '/^CONFIG_EXTRA_FIRMWARE_DIR=/d' .config
      make ARCH=arm64 CROSS_COMPILE=$CROSS olddefconfig >/dev/null )
    cp "$KERNEL_TREE/.config" "$KERNEL_TREE/.config.msr1"
    log "  release: $(make -s -C "$KERNEL_TREE" ARCH=arm64 kernelversion)"
  fi
  if [ ! -f "$KERNEL_TREE/arch/arm64/boot/Image" ]; then
    log "compiling kernel (long)"
    make -C "$KERNEL_TREE" ARCH=arm64 CROSS_COMPILE=$CROSS -j"$JOBS" Image modules >>"$LOGS/kernel-build.log" 2>&1 || die "kernel build failed - see work/logs/kernel-build.log"
    log "  kernel built"
  fi
  log "stage 10 OK"
}

# ================================================== stage 15: collect artefacts
stage_collect() {
  log "stage 15: collecting kernel artefacts"
  rm -rf "$KOUT"; mkdir -p "$KOUT/boot" "$KOUT/lib/modules/$KVER"
  cp "$KERNEL_TREE/arch/arm64/boot/Image" "$KOUT/boot/vmlinuz-$KVER"
  cp "$KERNEL_TREE/.config" "$KOUT/boot/config-$KVER"
  cp "$KERNEL_TREE/System.map" "$KOUT/boot/System.map-$KVER"
  ( cd "$KERNEL_TREE" && find . -name '*.ko' -print | sed 's|^\./||' | sort ) >"$LOGS/modules.list"
  log "  $(wc -l <"$LOGS/modules.list") modules built"
  ( cd "$KERNEL_TREE" && tar -cf - --files-from="$LOGS/modules.list" ) |
    ( cd "$KOUT/lib/modules/$KVER" && tar -xf - )
  # Fedora ships xz-compressed modules; this kernel is built without
  # CONFIG_MODULE_COMPRESS, so compress them here to keep the module tree the
  # same size inside the EROFS live filesystem (and to keep the ISO small).
  log "  compressing modules (xz -2)"
  ( cd "$KOUT/lib/modules/$KVER" && find . -name '*.ko' -print0 | xargs -0 -P "$JOBS" -n 200 xz -2 ) \
    >>"$LOGS/build.log" 2>&1 || die "module compression failed"
  # modules.dep / modules.order still name the uncompressed .ko files
  for m in modules.dep modules.order modules.softdep; do
    [ -f "$KOUT/lib/modules/$KVER/$m" ] || continue
    sed -i -e 's/\.ko\.xz/.ko/g' -e 's/\.ko/.ko.xz/g' "$KOUT/lib/modules/$KVER/$m"
  done
  cp -a "$KERNEL_TREE"/modules.* "$KOUT/lib/modules/$KVER/" 2>/dev/null || true
  for m in modules.dep modules.order modules.softdep; do
    [ -f "$KOUT/lib/modules/$KVER/$m" ] || continue
    sed -i -e 's/\.ko\.xz/.ko/g' -e 's/\.ko/.ko.xz/g' "$KOUT/lib/modules/$KVER/$m"
  done
  # signature side files and the kernel-devel symlinks are not part of this
  # package and would be dangling on the target
  find "$KOUT/lib/modules/$KVER" -maxdepth 1 -type f -name '.*' -delete
  rm -f "$KOUT/lib/modules/$KVER/build" "$KOUT/lib/modules/$KVER/source"
  asroot depmod -b "$KOUT" "$KVER" >>"$LOGS/build.log" 2>&1 || die "depmod failed"
  log "stage 15 OK - modules $(du -sh "$KOUT/lib/modules/$KVER" | cut -f1)"
}

# ==================================================== stage 20: live rootfs
stage_rootfs() {
  log "stage 20: integrating MS-R1 support into the live root filesystem"
  [ -d "$ROOTFS" ] || die "staged rootfs missing - extract it first (see work/logs/build.log)"
  # -- kernel + modules ----------------------------------------------------
  # Remove any module directory of an earlier build first: a previous layout
  # kept the raw "kernel/"-prefixed tree next to the collected one, and depmod
  # would then index two different builds of the same kernel version.
  asroot bash -c "rm -rf '$ROOTFS/usr/lib/modules/$KVER'"
  asroot bash -c "cp -a '$KOUT/lib/modules/$KVER' '$ROOTFS/usr/lib/modules/'"
  asroot bash -c "install -D -m 0644 '$KOUT/boot/vmlinuz-$KVER'  '$ROOTFS/boot/vmlinuz-$KVER'
                  install -D -m 0644 '$KOUT/boot/config-$KVER'  '$ROOTFS/boot/config-$KVER'
                  install -D -m 0644 '$KOUT/boot/System.map-$KVER' '$ROOTFS/boot/System.map-$KVER'"
  cp -a "$KOUT/lib/modules/$KVER/modules.builtin" "$KOUT/lib/modules/$KVER/modules.builtin.modinfo" \
       "$ROOTFS/usr/lib/modules/$KVER/" 2>/dev/null || true
  asroot depmod -b "$ROOTFS/usr" "$KVER" >>"$LOGS/build.log" 2>&1 || die "depmod in the live rootfs failed"
  # depmod silently indexes whatever it finds, so verify that every module it
  # recorded really is in the tree we shipped
  local dangling
  dangling=$(awk -F: '/:/ {print $1}' "$ROOTFS/usr/lib/modules/$KVER/modules.dep" | while read -r m; do
                [ -f "$ROOTFS/usr/lib/modules/$KVER/$m" ] || echo "$m"; done | head -5)
  [ -z "$dangling" ] || die "modules.dep references modules that are not installed: $dangling"

  # -- project overlay (udev rules, units, tools, docs, config) -------------
  asroot bash -c "cp -a '$PROJ/rootfs/.' '$ROOTFS/'"

  # -- NPU userspace (proprietary CIX binaries, see NPU.md) ----------------
  if [ "${MSR1_WITH_NPU_UMD:-1}" = 0 ]; then
    log "  NPU userspace skipped (MSR1_WITH_NPU_UMD=0) - kernel driver only"
  else
    asroot bash -c "mkdir -p '$ROOTFS/usr/lib/ms-r1/npu/lib' '$ROOTFS/usr/lib/ms-r1/npu/bin' '$ROOTFS/usr/lib/ms-r1/npu/share' '$ROOTFS/usr/share/ms-r1/BIOS'
                    cp -a '$PROJ/thirdparty/npu/lib/.'  '$ROOTFS/usr/lib/ms-r1/npu/lib/'
                    cp -a '$PROJ/thirdparty/npu/bin/.'  '$ROOTFS/usr/lib/ms-r1/npu/bin/'
                    cp -a '$PROJ/thirdparty/npu/share/.' '$ROOTFS/usr/lib/ms-r1/npu/share/' 2>/dev/null || true
                    cp -a '$PROJ/thirdparty/bios/.'     '$ROOTFS/usr/share/ms-r1/BIOS/'"
  fi

  # -- NPU smoke test / tools permissions ----------------------------------
  asroot chmod 0755 "$ROOTFS/usr/bin/msr1-npu-check" "$ROOTFS/usr/bin/msr1-info" \
                    "$ROOTFS/usr/libexec/ms-r1/msr1-power-apply" "$ROOTFS/usr/libexec/ms-r1/msr1-npu-start"

  # -- bootloader entry (BLS) so installed systems boot the MS-R1 kernel ----
  # The machine-id/UUID below is the one the shipped live image was built
  # with; on a machine that installs to disk kernel-install rewrites the whole
  # entry, so these paths only have to be self-consistent here.
  asroot bash -c "mkdir -p '$ROOTFS/boot/loader/entries'
                  cat > '$ROOTFS/boot/loader/entries/$MACHINE_ID-$KVER.conf' <<'EOF'
title Fedora Linux ($KVER) 44 (Workstation Edition) - MS-R1 (CIX Sky1)
version $KVER
linux /boot/vmlinuz-$KVER
initrd /boot/initramfs-$KVER.img \$tuned_initrd
options $MSR1_ARGS root=UUID=dfa7a159-afff-495c-b025-942aec87502b ro rootflags=subvol=root net.ifnames=0 \$tuned_params
grub_users \$grub_users
grub_arg --unrestricted
grub_class fedora
EOF"

  # -- SELinux labels ------------------------------------------------------
  # Everything is relabelled from the image's own policy, because the files
  # added above were created on the build host and would otherwise carry a
  # user_* context.
  asroot setfiles -r "$ROOTFS" "$ROOTFS/etc/selinux/targeted/contexts/files/file_contexts" \
        "$ROOTFS" >>"$LOGS/build.log" 2>&1 || log "  setfiles reported differences (see log)"

  # -- enable the MS-R1 services ------------------------------------------
  asroot bash -c "ln -sf /usr/lib/systemd/system/msr1-power.service '$ROOTFS/etc/systemd/system/multi-user.target.wants/msr1-power.service'
                  ln -sf /usr/lib/systemd/system/msr1-npu.service  '$ROOTFS/etc/systemd/system/multi-user.target.wants/msr1-npu.service'"

  # -- housekeeping: no build leftovers, no shell history, no secrets -------
  asroot bash -c "rm -f  '$ROOTFS/root/.bash_history' '$ROOTFS/root/.bash_logout' \
                  rm -rf '$ROOTFS/home/liveuser/.cache' 2>/dev/null || true
                  find '$ROOTFS/var/log' -type f -name '*.log' -delete 2>/dev/null || true
                  find '$ROOTFS/tmp' -mindepth 1 -delete 2>/dev/null || true
                  rm -rf '$ROOTFS/usr/share/doc/ms-r1/build-host' 2>/dev/null || true"
  log "stage 20 OK"
}

# ================================================= stage 30: EROFS live image
stage_erofs() {
  log "stage 30: building the EROFS live filesystem"
  local out="$WORK/out/LiveOS/squashfs.img"
  mkdir -p "$WORK/out/LiveOS"
  # Same filesystem UUID as the original image: the live boot parameters and
  # the dracut live module look the filesystem up by it.
  local uuid="F5D6509B-0553-0A4A-888F-0DC4B272DD9E"
  local fc="$ROOTFS/etc/selinux/targeted/contexts/files/file_contexts"
  # pkexec drops the working directory, so pass absolute paths everywhere.
  # mkfs.erofs argument order is: [options] FILE SOURCE(s)
  # The stock Fedora live image compresses at ~34%; plain lz4hc lands near
  # 59% because the MS-R1 module tree, the MS-R1 initramfs and the
  # kernel-msr1 RPM are already compressed.  Override with
  # MSR1_EROFS_COMPRESS to trade build time against ISO size.
  asroot mkfs.erofs ${MSR1_EROFS_COMPRESS:--zlzma,6} -T"$JOBS" -U "$uuid" \
        --file-contexts "$fc" "$out" "$ROOTFS" >>"$LOGS/build.log" 2>&1 \
    || die "mkfs.erofs failed (see work/logs/build.log)"
  log "  LiveOS/squashfs.img $(du -h "$out" | cut -f1)"
  # the live session mounts the root filesystem read-only; make sure the
  # result really is readable and carries the SELinux contexts
  local mp=/tmp/msr1-erofs-check
  pkexec mkdir -p "$mp"
  pkexec mount -o ro,loop "$out" "$mp" >>"$LOGS/build.log" 2>&1 || die "cannot mount the new EROFS image"
  local ctx
  ctx="$(getfattr --only-values -n security.selinux "$mp/usr/bin/bash" 2>/dev/null || true)"
  [ -n "$ctx" ] || die "the new EROFS image lost its SELinux labels"
  log "  SELinux context on /usr/bin/bash: $ctx"
  pkexec umount "$mp" >>"$LOGS/build.log" 2>&1 || true
}

# ============================================ stage 40: MS-R1 initramfs image
stage_initramfs() {
  log "stage 40: building the MS-R1 initramfs"
  local stock="$WORK/extracts/initrd.img"
  [ -f "$stock" ] || die "cannot find the stock initramfs (work/extracts/initrd.img)"
  rm -rf "$INITRD"; mkdir -p "$INITRD"
  # the build user cannot mknod(2); the device nodes are placeholders that
  # devtmpfs replaces at boot, so a warning here is not fatal
  ( cd "$INITRD" && zstd -dc "$stock" | cpio -idm --quiet --no-preserve-owner 2>/dev/null ) || true
  [ -x "$INITRD/init" ] || die "cannot unpack initramfs"
  for n in console kmsg null random urandom zero full tty tty1; do
    [ -e "$INITRD/dev/$n" ] || : >"$INITRD/dev/$n"
  done
  # Reuse the module set Fedora's live initramfs carries (it is the set
  # dracut determined to be needed to reach a live session), but take the
  # files from *our* kernel tree, and add the MS-R1 specific drivers.
  local sdir="$INITRD/usr/lib/modules/$STOCK_KVER"
  local ddir="$INITRD/usr/lib/modules/$KVER"
  : >"$LOGS/initrd-modules-missing.log"
  [ -f "$sdir/modules.dep" ] || die "stock module directory ($sdir/modules.dep) missing in the initramfs"
  mkdir -p "$ddir"
  cp -a "$INITRD/usr/lib/modules/keys" "$ddir/" 2>/dev/null || true
  local nsel=0 nmiss=0 m
  while read -r m; do
    m="${m%.ko.xz}.ko"
    if [ -f "$KOUT/lib/modules/$KVER/$m.xz" ]; then
      mkdir -p "$ddir/$(dirname "$m")"
      cp -a "$KOUT/lib/modules/$KVER/$m.xz" "$ddir/$m.xz"
      nsel=$((nsel+1))
    elif [ -f "$KOUT/lib/modules/$KVER/$m" ]; then
      mkdir -p "$ddir/$(dirname "$m")"
      cp -a "$KOUT/lib/modules/$KVER/$m" "$ddir/$m"
      nsel=$((nsel+1))
    else
      nmiss=$((nmiss+1)); echo "$m" >>"$LOGS/initrd-modules-missing.log"
    fi
  done < <(awk -F: '$0 ~ /:/ {print $1}' "$sdir/modules.dep" | sed 's|^kernel/||')
  log "  $nsel modules taken from the live set, $nmiss not built (see work/logs/initrd-modules-missing.log)"

  # Everything the MS-R1 needs on top of that, with its dependencies, taken
  # from our modules.dep so the closure is complete.
  local extra='kernel/drivers/misc/armchina-npu|kernel/drivers/pci/sky1|cix|sky1|armchina|scmi|panthor|cadence|cpsw|dwc3|phy-cix|aipu|mbox-cix|fs/erofs|regulator-cix|soc/cix|nvmem-cix|thermal/cix'
  MODSRC="$KOUT/lib/modules/$KVER" MODDST="$ddir" MODPAT="$extra" MODOUT="$WORK/out/initrd-extra-modules.list" \
    python3 - "$KOUT/lib/modules/$KVER/modules.dep" <<'PY' || die "cannot compute the module closure"
import os, re, sys
dep_path = sys.argv[1]
deps = {}
with open(dep_path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        path, _, rest = line.partition(':')
        deps[path] = rest.split()
pat = re.compile(os.environ['MODPAT'])
want = [p for p in deps if pat.search(p)]
seen, stack = set(), list(want)
while stack:
    m = stack.pop()
    if m in seen:
        continue
    seen.add(m)
    stack.extend(deps.get(m, ()))
seen = {m if m.endswith('.ko.xz') else m + '.xz' for m in seen}
seen = sorted(m for m in seen if os.path.exists(os.path.join(os.environ['MODSRC'], m)))
with open(os.environ['MODOUT'], 'w') as fh:
    fh.write('\n'.join(seen) + '\n')
PY
  while read -r m; do
    [ -n "$m" ] || continue
    [ -f "$KOUT/lib/modules/$KVER/$m" ] || continue
    mkdir -p "$ddir/$(dirname "$m")"
    [ -f "$ddir/$m" ] || cp -a "$KOUT/lib/modules/$KVER/$m" "$ddir/$m"
  done <"$WORK/out/initrd-extra-modules.list"
  log "  $(wc -l <"$WORK/out/initrd-extra-modules.list") MS-R1/ACPI modules added"
  rm -rf "$sdir"
  cp "$KOUT/lib/modules/$KVER/modules.builtin" \
     "$KOUT/lib/modules/$KVER/modules.builtin.modinfo" \
     "$KOUT/lib/modules/$KVER/modules.builtin.alias.bin" "$ddir/" 2>/dev/null || true
  : >"$ddir/modules.order"
  depmod -b "$INITRD/usr" "$KVER" >>"$LOGS/build.log" 2>&1 || die "depmod in the initramfs failed"

  # ACPI override table: uncompressed early cpio prepended to the image
  local aml="$PROJ/acpi/ssdt-msr1-npu-core-hid.aml"
  [ -f "$aml" ] || ( cd "$PROJ/acpi" && iasl -p ssdt-msr1-npu-core-hid Ssdt-MsR1-NpuCoreHid.asl ) >>"$LOGS/build.log" 2>&1
  local early="$WORK/out/early-cpio"; rm -rf "$early"; mkdir -p "$early/kernel/firmware/acpi"
  cp "$aml" "$early/kernel/firmware/acpi/"
  ( cd "$early" && find . -print0 | cpio --null -o -H newc --quiet ) > "$WORK/out/acpi-override.cpio"
  ( cd "$INITRD" && find . -print0 | cpio --null -o -H newc --quiet ) | zstd -19 -T0 -q > "$WORK/out/initrd-msr1.zst"
  cat "$WORK/out/acpi-override.cpio" "$WORK/out/initrd-msr1.zst" > "$WORK/out/initramfs-$KVER.img"
  asroot install -D -m 0644 "$WORK/out/initramfs-$KVER.img" "$ROOTFS/boot/initramfs-$KVER.img"
  log "  initramfs $(du -h "$WORK/out/initramfs-$KVER.img" | cut -f1) (ACPI override $(stat -c%s "$WORK/out/acpi-override.cpio") bytes)"
}

# ================================== stage 45: kernel-msr1 RPM (offline package)
# Packs the artefacts this image ships so that an installation started from
# the live session can install the MS-R1 kernel with dnf instead of copying
# files around by hand.  Built on the x86_64 build host: the package contains
# aarch64 payload, which rpm handles fine, no foreign binary is executed.
stage_rpm() {
  log "stage 45: building the kernel-msr1 RPM"
  if [ "${MSR1_WITH_RPM:-1}" = 0 ]; then log "  skipped (MSR1_WITH_RPM=0)"; return 0; fi
  command -v rpmbuild >/dev/null || { log "  rpmbuild missing - skipped"; return 0; }
  local top="$WORK/rpmbuild" src="$WORK/rpmbuild/payload"
  rm -rf "$top"; mkdir -p "$top/payload/boot" "$top/payload/usr/lib/modules/$KVER" \
                        "$top/payload/usr/share/ms-r1" "$top/SPECS" "$top/RPMS" "$top/SRPMS" "$top/BUILD" \
                        "$WORK/out/rpms"
  cp "$KOUT/boot/vmlinuz-$KVER" "$KOUT/boot/config-$KVER" "$KOUT/boot/System.map-$KVER" \
     "$top/payload/boot/"
  cp "$WORK/out/initramfs-$KVER.img" "$top/payload/boot/initramfs-$KVER.img"
  cp -a "$KOUT/lib/modules/$KVER/." "$top/payload/usr/lib/modules/$KVER/"
  mkdir -p "$top/payload/usr/share/ms-r1/dtb/acpi"
  cp "$PROJ/acpi/ssdt-msr1-npu-core-hid.aml" "$top/payload/usr/share/ms-r1/dtb/acpi/"

  cat >"$top/SPECS/kernel-msr1.spec" <<EOF
Name:           kernel-msr1
Version:        $LINUX_VER
Release:        300.fc44.msr1
Summary:        Linux kernel for the MINISFORUM MS-R1 (CIX Sky1)
License:        GPL-2.0-only
Provides:       kernel-modules = %{version}-%{release}
Requires:       dracut >= 059
Requires:       coreutils
%description
Upstream Linux $LINUX_VER with the Sky1-Linux patch set (CIX PCIe host
bridge, ACPI glue for the Sky1 peripherals, panthor/CIX display, CIX audio,
the ArmChina Zhouyi V3 NPU driver and the SCMI/CPPC cpufreq backends), built
with Fedora's aarch64 configuration.  Installs into /boot and
/usr/lib/modules so an installation started from this live image can boot
the MS-R1 kernel.
%post
%depmod %{version}-%{release}
%postun
if [ \$1 = 0 ]; then
    for f in /boot/loader/entries/*.conf; do
        [ -e "\$f" ] || continue
        grep -q "^version %{version}-%{release}\$" "\$f" 2>/dev/null && rm -f "\$f"
    done
fi
%files
/boot/*
/usr/lib/modules/%{version}-%{release}/*
/usr/share/ms-r1/*
EOF
  # the payload is staged on the host; copy it into the buildroot at %install
  sed -i "s|^%post$|%install\ncp -a $src/boot %{buildroot}/boot\nmkdir -p %{buildroot}/usr/lib/modules %{buildroot}/usr/share/ms-r1\ncp -a $src/usr/lib/modules/$KVER %{buildroot}/usr/lib/modules/\nmkdir -p %{buildroot}/usr/share/ms-r1/dtb/acpi\ncp -a $src/usr/share/ms-r1/dtb/acpi/. %{buildroot}/usr/share/ms-r1/dtb/acpi/\n%post|" "$top/SPECS/kernel-msr1.spec"

  rpmbuild --define "_topdir $top" --define "dist .fc44" --target aarch64 \
           -bb "$top/SPECS/kernel-msr1.spec" >>"$LOGS/build.log" 2>&1 \
    || { log "  rpmbuild FAILED - see work/logs/build.log (continuing without the RPM)"; return 0; }
  local rpm
  rpm="$(ls -1 "$top"/RPMS/aarch64/kernel-msr1-*.rpm 2>/dev/null | head -1)"
  [ -n "$rpm" ] || { log "  no RPM produced"; return 0; }
  cp "$rpm" "$WORK/out/rpms/"
  asroot install -D -m 0644 "$rpm" "$ROOTFS/usr/share/ms-r1/kernel/$(basename "$rpm")"
  log "  $(basename "$rpm") $(du -h "$rpm" | cut -f1)"
  log "stage 45 OK"
}

# ========================================================= stage 50: ISO image
stage_iso() {
  log "stage 50: assembling the ISO"
  rm -f "$OUT_ISO"
  local kern="$WORK/out/kernel/boot/vmlinuz-$KVER"
  local initrd="$WORK/out/initramfs-$KVER.img"
  [ -f "$kern" ] && [ -f "$initrd" ] || die "kernel/initramfs artefacts missing"
  # grub.cfg: stock Fedora entries + the MS-R1 entries (default first)
  local cfg="$WORK/out/grub.cfg"
  sed -e "s|@KVER@|$KVER|g" -e "s|@VOLID@|$VOLID|g" \
      -e "s|@ARGS@|$MSR1_ARGS|g" -e "s|@LOWPWR@|$MSR1_ARGS_LOWPOWER|g" \
      "$PROJ/config/grub.cfg.msr1" > "$cfg"
  # -map (not -update_r): with -indev/-outdev the imported tree is only
  # writable through -map, and -map creates the two new files as well.
  # -boot_image any replay re-applies the El Torito / MBR / GPT settings of
  # the source image, so Secure Boot (shim -> grubaa64.efi) is unchanged.
  xorriso -indev "$BASE_ISO" \
      -boot_image any replay \
      -volid "$VOLID" \
      -map "$WORK/out/LiveOS/squashfs.img" /LiveOS/squashfs.img \
      -map "$kern"   /boot/aarch64/loader/linux-msr1 \
      -map "$initrd" /boot/aarch64/loader/initrd-msr1 \
      -map "$cfg"    /boot/grub2/grub.cfg \
      -outdev "$OUT_ISO" >>"$LOGS/build.log" 2>&1 || die "xorriso failed (see work/logs/build.log)"
  grep -q 'SORRY' <(grep -A3 'xorriso :' "$LOGS/build.log" | tail -40) && die "xorriso reported problems (see work/logs/build.log)"
  log "  ISO $(du -h "$OUT_ISO" | cut -f1)"
  sha256sum "$OUT_ISO" | tee "$OUT_ISO.sha256"
  log "stage 50 OK - $OUT_ISO"
}

main() {
  mkdir -p "$LOGS"; touch "$LOGS/build.log"
  for s in "${@:-all}"; do
    case "$s" in
      all) stage_env; stage_kernel; stage_collect; stage_rootfs; stage_initramfs; stage_rpm; stage_erofs; stage_iso ;;
      0|env) stage_env ;; 10|kernel) stage_kernel ;; 15|collect) stage_collect ;;
      20|rootfs) stage_rootfs ;; 30|erofs) stage_erofs ;; 40|initramfs) stage_initramfs ;;
      45|rpm) stage_rpm ;; 50|iso) stage_iso ;;
      *) die "unknown stage: $s" ;;
    esac
  done
}
main "$@"
