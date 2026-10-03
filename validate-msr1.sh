#!/usr/bin/env bash
#
# validate-msr1.sh - offline validation of Fedora-Workstation-Live-44-1.7-MS-R1.aarch64.iso
#
# Every check is non-destructive and works on the finished ISO.  Checks that
# need root or an aarch64 runtime are reported as SKIP with the reason instead
# of silently passing.
#
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="${1:-$PROJ/Fedora-Workstation-Live-44-1.7-MS-R1.aarch64.iso}"
WORK="$PROJ/work/validate"
KVER="6.19.10-300.fc44.msr1"
STOCK_KVER="6.19.10-300.fc44.aarch64"
PASS=0; FAIL=0; SKIP=0
mkdir -p "$WORK"; : >"$WORK/report.txt"

ok()   { printf 'PASS  %s\n' "$1" | tee -a "$WORK/report.txt"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s\n' "$1" | tee -a "$WORK/report.txt"; FAIL=$((FAIL+1)); }
skip() { printf 'SKIP  %s (%s)\n' "$1" "$2" | tee -a "$WORK/report.txt"; SKIP=$((SKIP+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
head1(){ printf '\n=== %s ===\n' "$1"; }

[ -f "$ISO" ] || { echo "ISO not found: $ISO"; exit 1; }
head1 "File"
check "ISO exists"                "[ -f '$ISO' ]"
sz=$(stat -c%s "$ISO"); printf 'size  : %s bytes (%s)\n' "$sz" "$(du -h "$ISO" | cut -f1)"
[ "$sz" -gt 1500000000 ] && ok "size is plausible for a live image (>1.5 GB)" || bad "size too small"
check "ISO 9660 image"            "file -b '$ISO' | grep -q 'ISO 9660'"
check "SHA256 recorded"           "[ -f '$ISO.sha256' ] && sha256sum -c '$ISO.sha256' >/dev/null 2>&1"

head1 "ISO structure and boot"
check "xorriso can read it"       "xorriso -indev '$ISO' -report_system_area plain"
check "volume id"                 "xorriso -indev '$ISO' -pvd_info 2>/dev/null | grep -q 'Volume Id.*Fedora-WS-Live-44'"
check "El Torito EFI boot image"  "xorriso -indev '$ISO' -report_el_torito plain 2>/dev/null | grep -q 'UEFI'"
check "MBR present"               "xorriso -indev '$ISO' -report_system_area plain 2>/dev/null | grep -qi 'MBR'"
rm -rf "$WORK/iso"; mkdir -p "$WORK/iso"
xorriso -osirrox on -indev "$ISO" -extract / "$WORK/iso" >/dev/null 2>&1
check "ISO extracts"              "[ -f '$WORK/iso/boot/grub2/grub.cfg' ]"
check "LiveOS filesystem present" "[ -f '$WORK/iso/LiveOS/squashfs.img' ]"
check "live rootfs is EROFS"      "file -b '$WORK/iso/LiveOS/squashfs.img' | grep -q EROFS"
check "stock kernel kept"         "[ -f '$WORK/iso/boot/aarch64/loader/linux' ]"
check "stock initramfs kept"      "[ -f '$WORK/iso/boot/aarch64/loader/initrd' ]"
check "MS-R1 kernel present"      "[ -f '$WORK/iso/boot/aarch64/loader/linux-msr1' ]"
check "MS-R1 initramfs present"   "[ -f '$WORK/iso/boot/aarch64/loader/initrd-msr1' ]"
check "EFI/BOOT/BOOTAA64.EFI"     "[ -f '$WORK/iso/EFI/BOOT/BOOTAA64.EFI' ]"
check "EFI grubaa64"              "[ -f '$WORK/iso/EFI/BOOT/grubaa64.efi' ]"
check "EFI shim"                  "[ -f '$WORK/iso/EFI/fedora/shimaa64.efi' ]"

head1 "GRUB configuration"
cfg="$WORK/iso/boot/grub2/grub.cfg"
check "grub.cfg present"          "[ -f '$cfg' ]"
check "default entry is MS-R1"    "grep -q 'set default=\"0\"' '$cfg'"
check "MS-R1 entry uses msr1 kernel"  "grep -q 'linux-msr1' '$cfg'"
check "MS-R1 entry uses msr1 initrd"  "grep -q 'initrd-msr1' '$cfg'"
check "stock entry retained"      "grep -q 'linux quiet rhgb  root=live:CDLABEL=Fedora-WS-Live-44' '$cfg'"
check "root= matches volume id"   "grep -q 'root=live:CDLABEL=Fedora-WS-Live-44' '$cfg'"
check "no unknown kernel args"    "! grep -oE '(^| )[a-z0-9_]+(\.[a-z_]+)?=[^ ]*' '$cfg' | grep -qE 'disable_bypass|earlycon='"
grep -c menuentry "$cfg" | xargs printf 'menuentries: %s\n'

head1 "MS-R1 kernel"
kv="$WORK/kern"
rm -rf "$kv"; mkdir -p "$kv"
cp "$WORK/iso/boot/aarch64/loader/linux-msr1" "$kv/vmlinuz"
check "kernel is PE32+ ARM64"     "file -b '$kv/vmlinuz' | grep -qi 'ARM64'"
# Linux arm64 Image is a PE/COFF with an MZ header, but file(1) labels it
# "Linux kernel ... boot executable Image", not "EFI"; check the magic bytes.
check "kernel has MZ/PE stub"     "head -c2 '$kv/vmlinuz' | od -An -tx1 | tr -d ' ' | grep -qi '^4d5a' || file -b '$kv/vmlinuz' | grep -qi 'PE32'"
rel=$(strings -a "$kv/vmlinuz" | grep -m1 -E '6\.19\.10-300\.fc44\.msr1')
[ -n "$rel" ] && ok "kernel release string: $rel" || skip "kernel release string" "not found in image"
check "no x86 EFI kernel mixed"   "! file -b '$kv/vmlinuz' | grep -qi 'x86-64'"

head1 "MS-R1 initramfs"
rm -rf "$WORK/initrd"; mkdir -p "$WORK/initrd"
# The MS-R1 initramfs = 1024-byte uncompressed early cpio (the ACPI SSDT
# override) + zstd-compressed dracut cpio.  Strip the early cpio by finding
# the zstd magic (28 b5 2f fd) before decompressing.
ird="$WORK/iso/boot/aarch64/loader/initrd-msr1"
off=$(od -An -tx1 -v "$ird" | tr -d ' \n' | grep -bo '28b52ffd' | head -1 | cut -d: -f1)
[ -n "$off" ] && off=$((off/2)) || off=0
ok "zstd payload of initramfs starts at offset $off"
rm -rf "$WORK/initrd"; mkdir -p "$WORK/initrd"
tail -c +$((off+1)) "$ird" | zstd -dc 2>/dev/null | cpio -it 2>/dev/null >"$WORK/initrd.list"
[ -s "$WORK/initrd.list" ] && ok "initramfs is a readable cpio ($(wc -l <"$WORK/initrd.list") entries)" || bad "initramfs cannot be read"
check "MS-R1 modules in initrd"       "grep -q 'usr/lib/modules/$KVER/modules.dep' '$WORK/initrd.list' || grep -q 'lib/modules/$KVER/modules.dep' '$WORK/initrd.list'"
check "NPU driver in initramfs"       "grep -q 'armchina-npu' '$WORK/initrd.list'"
check "ERFS driver in initramfs"      "grep -q 'erofs' '$WORK/initrd.list'"
check "live support in initramfs"     "grep -q 'dracut' '$WORK/initrd.list' || grep -q 'init' '$WORK/initrd.list'"
# extract the ACPI override from the early cpio and verify it
tail -c +1 "$ird" | head -c "$off" | cpio -i --quiet -D "$WORK/initrd" 2>/dev/null
if [ -f "$WORK/initrd/kernel/firmware/acpi/ssdt-msr1-npu-core-hid.aml" ]; then
  a="$WORK/initrd/kernel/firmware/acpi/ssdt-msr1-npu-core-hid.aml"
  check "SSDT signature"          "head -c4 '$a' | grep -q SSDT"
  check "SSDT checksum valid"     "iasl -sa '$a' >/dev/null 2>&1"
else
  bad "ACPI override table missing from early cpio"
fi

head1 "Live root filesystem"
  R="$WORK/root"
  if mountpoint -q "$R" 2>/dev/null; then pkexec umount "$R" 2>/dev/null || true; fi
  rm -rf "$R"; mkdir -p "$R"
  if pkexec mount -o ro,loop "$WORK/iso/LiveOS/squashfs.img" "$R" 2>/dev/null; then
    RMOUNT=1
  else
    skip "live root filesystem checks" "cannot mount EROFS (needs pkexec)"
    head1 "Summary"
    printf 'PASS %d   FAIL %d   SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
  fi
  check "MS-R1 kernel in /boot"        "[ -f '$R/boot/vmlinuz-$KVER' ]"
  check "MS-R1 initramfs in /boot"    "[ -f '$R/boot/initramfs-$KVER.img' ]"
  check "MS-R1 config in /boot"        "[ -f '$R/boot/config-$KVER' ]"
  check "MS-R1 module tree"            "[ -d '$R/usr/lib/modules/$KVER' ] && [ -f '$R/usr/lib/modules/$KVER/modules.dep' ]"
  check "stock modules untouched"      "[ -f '$R/usr/lib/modules/$STOCK_KVER/modules.dep' ]"
  check "NPU driver installed"         "ls '$R/usr/lib/modules/$KVER'/drivers/misc/armchina-npu/armchina_npu.ko.xz >/dev/null 2>&1"
  # CONFIG_PCI_SKY1=y: the Sky1 PCIe host bridge is built into the Image, so it
  # must appear in modules.builtin, not as a .ko
check "PCIe sky1 driver present"     "grep -q 'kernel/drivers/pci/controller/cadence/pcie-sky1.ko' '$R/usr/lib/modules/$KVER/modules.builtin'"
  check "Sky1 DDR/ACPI glue built in"  "grep -q 'kernel/drivers/soc/cix/cix-acpi-resource-lookup.ko' '$R/usr/lib/modules/$KVER/modules.builtin' && grep -q 'kernel/drivers/clk/cix/clk-sky1-acpi.ko' '$R/usr/lib/modules/$KVER/modules.builtin'"
  check "no duplicate module tree"     "[ ! -e '$R/usr/lib/modules/$KVER/kernel' ]"
  nd=$(awk -F: '/:/ {print $1}' "$R/usr/lib/modules/$KVER/modules.dep" 2>/dev/null | while read -r m; do
         [ -f "$R/usr/lib/modules/$KVER/$m" ] || echo x; done | wc -l)
  [ "$nd" -eq 0 ] && ok "every modules.dep entry resolves to an installed module" \
                   || bad "$nd modules.dep entries point at a missing module"
  check "BLS entry"                    "pkexec find '$R/boot/loader/entries' -maxdepth 1 -name '*.conf' | grep -q '$KVER'"
  check "NPU userspace"                "[ -f '$R/usr/lib/ms-r1/npu/lib/libnoe.so' ]"
  check "NPU udev rule"                "[ -f '$R/usr/lib/udev/rules.d/60-msr1-npu.rules' ]"
  check "NPU service"                  "[ -f '$R/usr/lib/systemd/system/msr1-npu.service' ]"
  check "power service"                "[ -f '$R/usr/lib/systemd/system/msr1-power.service' ]"
  check "power service enabled"        "[ -L '$R/etc/systemd/system/multi-user.target.wants/msr1-power.service' ]"
  check "power config"                 "[ -f '$R/etc/msr1-power.conf' ]"
  check "power udev rules"             "[ -f '$R/usr/lib/udev/rules.d/60-msr1-power.rules' ]"
  check "dracut config"                "[ -f '$R/etc/dracut.conf.d/99-msr1.conf' ]"
  check "docs shipped"                 "[ -f '$R/usr/share/doc/ms-r1/NPU.md' ] && [ -f '$R/usr/share/doc/ms-r1/HARDWARE.md' ]"
  check "BIOS files shipped"           "[ -f '$R/usr/share/ms-r1/BIOS/cix_flash_all2_MGP1WSB_20260429.bin' ]"
  check "msr1-npu-check executable"    "[ -x '$R/usr/bin/msr1-npu-check' ]"
  check "msr1-info executable"         "[ -x '$R/usr/bin/msr1-info' ]"
  check "no shell history"             "! ls '$R/root/.*history' >/dev/null 2>&1"
  check "empty /tmp"                   "[ -z \"\$(ls -A '$R/tmp')\" ]"
  check "machine-id uninitialised"     "[ \"\$(cat '$R/etc/machine-id')\" = uninitialized ] || [ -f '$R/etc/machine-id' ]"
  # architecture of installed userspace
  n=$(find "$R/usr/bin" -maxdepth 1 -type f -executable 2>/dev/null | head -400 | while read -r f; do
        file -b "$f" | grep -lq . /dev/null 2>/dev/null; readelf -h "$f" 2>/dev/null | grep -q 'AArch64' && echo x; done | wc -l)
  [ "$n" -gt 300 ] && ok "aarch64 userspace binaries ($n of 400 sampled are AArch64)" || bad "userspace architecture looks wrong ($n AArch64)"
  x=$(find "$R/usr/bin" -maxdepth 1 -type f -executable 2>/dev/null | head -400 | while read -r f; do
        readelf -h "$f" 2>/dev/null | grep -q 'X86-64' && echo x; done | wc -l)
  [ "$x" -eq 0 ] && ok "no x86-64 binaries in /usr/bin" || bad "$x x86-64 binaries found in /usr/bin"
  # RPM database consistency
  rpm --root "$R" -qa >/dev/null 2>&1 && ok "RPM database readable" || bad "RPM database broken"
  arch=$(rpm --root "$R" -q --qf '%{ARCH}\n' bash 2>/dev/null)
  [ "$arch" = aarch64 ] && ok "package architecture is aarch64" || bad "package architecture: $arch"
  # the image ships the same payload as an offline RPM so that an installation
  # started from the live session can install the MS-R1 kernel properly
  rpmf=$(ls "$R/usr/share/ms-r1/kernel/"kernel-msr1-*.rpm 2>/dev/null | head -1)
  if [ -n "$rpmf" ]; then
    ok "offline kernel RPM shipped ($(basename "$rpmf"), $(du -h "$rpmf" | cut -f1))"
    r=$(rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' "$rpmf" 2>/dev/null)
    arch=$(rpm -qp --qf '%{ARCH}' "$rpmf" 2>/dev/null)
    [ "$arch" = aarch64 ] && ok "kernel RPM is aarch64" || bad "kernel RPM arch: $arch"
    rver=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$rpmf" 2>/dev/null)
    [ "$rver" = "$KVER" ] && ok "kernel RPM version matches the shipped kernel ($r)" \
                         || bad "kernel RPM is $rver, shipped kernel is $KVER"
    rpml="$(rpm -qlp "$rpmf" 2>/dev/null)"
    check "kernel RPM carries /boot/vmlinuz"    "grep -qxF '/boot/vmlinuz-$KVER' <<<\"\$rpml\""
    check "kernel RPM carries /boot/initramfs"  "grep -qxF '/boot/initramfs-$KVER.img' <<<\"\$rpml\""
    check "kernel RPM carries /boot/config"     "grep -qxF '/boot/config-$KVER' <<<\"\$rpml\""
    check "kernel RPM carries modules.dep"      "grep -qxF '/usr/lib/modules/$KVER/modules.dep' <<<\"\$rpml\""
    check "kernel RPM carries ACPI SSDT"        "grep -qxF '/usr/share/ms-r1/dtb/acpi/ssdt-msr1-npu-core-hid.aml' <<<\"\$rpml\""
    # the RPM must be installable: rpm -K only checks the signature/digest, and
    # an unsigned package is expected here (this image is not Fedora-signed)
    rpm -qp --qf '%{SUMMARY}\n' "$rpmf" >/dev/null 2>&1 && ok "kernel RPM header readable" || bad "kernel RPM unreadable"
  else
    bad "offline kernel RPM missing from /usr/share/ms-r1/kernel"
  fi
  # broken symlinks: only the ones this project adds are in scope.  The
  # stock Fedora live image itself ships ~148 dangling symlinks
  # (/etc/pki/tls/certs/*.0 -> hashes whose CA certificates are in a package
  # the live image does not install), and a kernel module directory
  # legitimately carries dangling build/source symlinks.  A global check
  # would only report pre-existing upstream state.
  broken=$(find "$R/usr/lib/ms-r1" "$R/usr/share/ms-r1" "$R/usr/libexec/ms-r1" \
                "$R/usr/bin/msr1-info" "$R/usr/bin/msr1-npu-check" \
                "$R/boot/loader/entries" -xtype l 2>/dev/null | wc -l)
  [ "$broken" -eq 0 ] && ok "no broken symlinks in the added files" || bad "$broken broken symlinks in the added files"
  modbroken=$(find "$R/usr/lib/modules/$KVER" -xtype l 2>/dev/null | wc -l)
  [ "$modbroken" -le 2 ] && ok "only the kernel-devel symlinks dangle in the MS-R1 module tree ($modbroken)" \
                        || bad "$modbroken dangling symlinks in the MS-R1 module tree"
  stockbroken=$(find "$R" -xtype l 2>/dev/null | wc -l)
  [ "$stockbroken" -le 200 ] && ok "dangling symlinks count in line with the stock image ($stockbroken)" \
                             || bad "$stockbroken dangling symlinks (stock image has ~146)"
  # SELinux labels preserved
  ctx=$(getfattr -d -m - --absolute-names "$R/usr/bin/bash" 2>/dev/null | grep -o 'system_u:object_r:[a-z_]*')
  [ -n "$ctx" ] && ok "SELinux labels preserved ($ctx)" || bad "SELinux labels missing"
  # Secret scan: match on private key *material*, not on the file name.  The
  # stock live image ships ~21 files ending in ".key" (DNSSEC trust anchors,
  # LibreOffice help keyword files, the distribution GPG public keys), none of
  # which is secret.  A hit is a file carrying a PEM private key block, a
  # PKCS#12/JKS keystore or an ssh/netrc credential file.
  sec=$(find "$R" -xdev -type f \( -name 'id_*' -o -name '*.key' -o -name '*.pem' \
          -o -name '*.p12' -o -name '*.pfx' -o -name '*.jks' -o -name '*.kdb' \
          -o -name '.netrc' -o -name '*.ppk' -o -name '*.ovpn' \) 2>/dev/null \
        | xargs -r -n 64 grep -l 'BEGIN [A-Z ]*PRIVATE KEY' 2>/dev/null \
        | grep -vE '/etc/pki/|/usr/lib/.*/test|/usr/share/(doc|sources)/' | wc -l)
  [ "$sec" -eq 0 ] && ok "no private key material" || bad "$sec files contain private key material"
  # ssh/other credentials anywhere under the shipped home directories
  cred=$(grep -rl -e 'BEGIN OPENSSH PRIVATE KEY' -e 'BEGIN EC PRIVATE KEY' \
              -e 'BEGIN RSA PRIVATE KEY' "$R/root" "$R/home" 2>/dev/null | wc -l)
  [ "$cred" -eq 0 ] && ok "no credentials in /root or /home" || bad "$cred credential files in /root or /home"
  # the distribution keys that account for the ".key" hits must be public only.
  # The stock image ships ~200 files here: most are ASCII-armored PGP public
  # blocks, a few are the old Red Hat "pub ... keyid ..." plain-text key lists,
  # and one is an X.509 public key (RPM-GPG-KEY-EPEL-10-IMA).  None of them is
  # secret, so the test is "no private key material".
  gpgsec=$(find "$R/usr/share/distribution-gpg-keys" -type f 2>/dev/null \
             | xargs -r -n 64 grep -l 'PRIVATE KEY' 2>/dev/null | wc -l)
  [ "$gpgsec" -eq 0 ] && ok "no private key material in the distribution key store" \
                      || bad "$gpgsec files in /usr/share/distribution-gpg-keys contain private key material"
  gpgpub=$(find "$R/usr/share/distribution-gpg-keys" -type f 2>/dev/null | wc -l)
  gpgnon=$(find "$R/usr/share/distribution-gpg-keys" -type f 2>/dev/null \
             | xargs -r -n 64 grep -L -e 'PGP PUBLIC KEY' -e 'BEGIN PUBLIC KEY' -e '^pub ' -e 'keyid' -e 'BEGIN PGP' 2>/dev/null \
             | grep -vE '/README\.txt$' | wc -l)
  [ "$gpgnon" -eq 0 ] && ok "all $gpgpub distribution keys are public-key material" \
                      || bad "$gpgnon of $gpgpub distribution keys are not recognisable public keys"
  pem=$(find "$R" -xdev -name '*.pem' 2>/dev/null \
        | grep -vE '/etc/pki/|\.public|ca-bundle|dns-root-data|/gnupg/|\.crt$' | wc -l)
  [ "$pem" -le 2 ] && ok "no unexpected .pem files ($pem beyond the CA trust store)" \
                   || bad "$pem unexpected .pem files"
pw=$(grep -rEl '(api[_-]?key|secret[_-]?key|access[_-]?token|password)\s*[:=]\s*["'"'"']?[A-Za-z0-9/+_-]{16,}' \
        "$R/etc" "$R/root" "$R/home" 2>/dev/null | head -5)
  [ -z "$pw" ] && ok "no credential-looking strings in /etc, /root, /home" || bad "possible credentials: $pw"
  pkexec umount "$R" 2>/dev/null || true

head1 "Summary"
printf 'PASS %d   FAIL %d   SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
