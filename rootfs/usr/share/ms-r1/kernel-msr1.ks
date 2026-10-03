# Kickstart for installing Fedora Workstation 44 on the MINISFORUM MS-R1 from
# this live image, with the MS-R1 kernel as the default kernel.
#
# Usage (from the running live session):
#     sudo anaconda --kickstart=/usr/share/ms-r1/kernel-msr1.ks
#
# Everything except the disk partitioning is left to anaconda's normal
# Fedora defaults, so the installed system is an ordinary Fedora Workstation
# 44 system; the only difference is the additional kernel-msr1 package.

%pre --interpreter=builtin
# The live image ships the MS-R1 kernel as an offline RPM so that the
# installed system boots with the CIX/Sky1 support built in.  Check that it
# really is reachable before anaconda starts building the target.
test -f /usr/share/ms-r1/kernel/kernel-msr1-*.rpm
%end

install
lang en_US.UTF-8
keyboard us
timezone UTC
rootpw --lock
selinux --enforcing
firewall --enabled --service=ssh
network --bootproto=dhcp --device=link --onboot=on
services --enabled=gdm NetworkManager

# Install the MS-R1 kernel from the offline RPM that the live image carries.
%packages --ignoremissing
@core
@workstation-environment
kernel-msr1
%end

%post
# Make sure the MS-R1 kernel is the first entry the bootloader offers and
# that BLS points at the initramfs the package ships.
for f in /boot/loader/entries/*.conf; do
    [ -e "$f" ] || continue
    grep -q '^version 6.19.10-300.fc44.msr1$' "$f" || continue
    sed -i 's|^initrd /boot/initramfs-\([^ ]*\)\.img.*|initrd /boot/initramfs-\1.img $tuned_initrd|' "$f"
done
grub2-mkconfig -o /boot/grub2/grub.cfg
%end