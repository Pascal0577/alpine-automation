#!/bin/sh

edge=0
verbose=0

while [ $# -gt 0 ]; do
  case "$1" in
    -e|--edge)
      edge=1
      shift ;;
    -v|--verbose)
      verbose=1
      shift ;;
    -h|--help)
      echo "Usage: $0 [-v|--verbose] MOUNTPOINT [COMMAND]"
      exit 0 ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1"
      exit 1 ;;
    *)
      break ;;
  esac
done

update_repositories() {
  # Sorry for weird formatting
  [ "$edge" -eq 1 ] && {
    cat > /etc/apk/repositories<< EOF
https://dl-cdn.alpinelinux.org/alpine/edge/main
https://dl-cdn.alpinelinux.org/alpine/edge/community
@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing
EOF
    }

  apk update
  apk upgrade
}

install_packages() {
  # local packages = ("linux-lts" "networkmanager")
  apk add alpine-base linux-lts wpa_supplicant
  apk add util-linux util-linux-login linux-pam
  apk add systemd-efistub ukify squashfs-tools
  setup-wayland-base
}

configure_services() {
  rc-update add hwdrivers boot
  rc-update add elogind default
  rc-update add squashdir shutdown
  rc-update del dbus sysinit
  rc-update add dbus default
}

configure_etc() {
  cat > /etc/network/interfaces << EOF
auto lo

auto wlan0
iface wlan0 inet dhcp
EOF

  cat > /etc/pam.d/login << EOF
auth       required     pam_securetty.so
auth       required     pam_unix.so
account    required     pam_unix.so
session    required     pam_unix.so
session    required     pam_env.so
session    required     pam_elogind.so
EOF

  sed -i 's|/sbin/getty|/sbin/agetty|g' /etc/inittab

  # https://web.archive.org/web/20251002224414/https://lists.alpinelinux.org/~alpine/users/%3C61b39753.1c69fb81.d43fe.c2b9%40mx.google.com%3E
  echo "messagebus:x:104:messagebus" >> /etc/group
  echo "messagebus:x:99:99:messagebus user:/run/dbus:/sbin/nologin" >> /etc/passwd
}

main() {
  root_uuid="$(cat ./root_uuid)"

  update_repositories

  install_packages

  configure_services

  configure_etc

  echo 'features="base ext4 keymap kms scsi usb zram squashfs simpledrm custom"' > /etc/mkinitfs/mkinitfs.conf

  mkinitfs -i /usr/share/mkinitfs/init.sh "$(ls /lib/modules/)"

  ukify \
    /boot/vmlinuz-lts \
    /boot/initramfs-lts \
    --stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
    --cmdline "root=UUID=$root_uuid zram" \
    --output /boot/EFI/BOOT/BOOTX64.EFI

  passwd

  # umount /boot
}

main "$@"
