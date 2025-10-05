#!/bin/sh

edge=0
verbose=0
root_uuid="$(cat ./root_uuid)"
cmdline="root=UUID=$root_uuid"
user=""
no_device=0

# Colors for log messages
red="$(printf '\033[0;31m')"
blue="$(printf '\033[0;34m')"
green="$(printf '\033[0;32m')"
white="$(printf '\033[0m')"

parse_arguments() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-device)
        no_device=1
        shift ;;
      --user)
        shift
        user="$1"
        shift ;;
      --cmdline)
        shift
        cmdline="$cmdline $1"
        shift ;;
      -e|--edge)
        edge=1
        shift ;;
      -v|--verbose)
        verbose=1
        shift ;;
      -h|--help)
        echo "Usage: $0 [-v|--verbose] MOUNTPOINT [COMMAND]"
        exit 0 ;;
      --)
        shift 
        break ;;
      -*)
        echo "Unknown option: $1"
        exit 1 ;;
      *)
        break ;;
    esac
  done
}

log_error() {
  printf "%s[ERROR]%s: %s\n" "$red" "$white" "$1" >&2
  exit 1
}

log_info() {
  printf "%s[INFO]%s: %s\n" "$green" "$white" "$1"
}

log_debug() {
  [ "$verbose" = "1" ] && printf "%s[DEBUG]%s: %s\n" "$blue" "$white" "$1"
  return 0
}

update_repositories() {
  log_info "Updating repositories"

  [ "$edge" -eq 1 ] && {
    log_debug "Using 'edge' branch"
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
  log_debug "Installing base packages"
  apk add alpine-base linux-lts wpa_supplicant util-linux util-linux-login linux-pam systemd-efistub ukify squashfs-tools \
    || log_error "in install_packages: failed to install critical packages"
  setup-wayland-base || log_error "in install_packages: failed to install critical packages"

  [ -n "$user" ] && apk add doas
}

configure_services() {
  log_info "Configuring services"
  rc-update add hwdrivers boot     || log_error "In configure_services: Failed to add critical service"
  rc-update add elogind default    || log_error "In configure_services: Failed to add critical service"
  rc-update add squashdir shutdown || log_error "In configure_services: Failed to add critical service"
  rc-update del dbus sysinit
  rc-update add dbus default       || log_error "In configure_services: Failed to add critical service"
}

configure_etc() {
  log_info "Configuring /etc"

  log_debug "Configuring interfaces"
  cat > /etc/network/interfaces << EOF
auto lo

auto wlan0
iface wlan0 inet dhcp
EOF

  log_debug "Configuring PAM"
  cat > /etc/pam.d/login << EOF
auth       required     pam_securetty.so
auth       required     pam_unix.so
account    required     pam_unix.so
session    required     pam_unix.so
session    required     pam_env.so
session    required     pam_elogind.so
EOF

  log_debug "Using agetty instead of getty"
  sed -i 's|/sbin/getty|/sbin/agetty|g' /etc/inittab
  
  log_debug "Configuring mkinitfs"
  echo 'features="base ext4 keymap kms scsi usb zram squashfs custom"' > /etc/mkinitfs/mkinitfs.conf

  # See this bug:
  # https://web.archive.org/web/20251002224414/https://lists.alpinelinux.org/~alpine/users/%3C61b39753.1c69fb81.d43fe.c2b9%40mx.google.com%3E
  echo "messagebus:x:104:messagebus" >> /etc/group
  echo "messagebus:x:99:99:messagebus user:/run/dbus:/sbin/nologin" >> /etc/passwd
}

build_uki() {
  log_info "Building UKI"
  ukify \
    /boot/vmlinuz-lts \
    /boot/initramfs-lts \
    --stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
    --cmdline "$cmdline" \
    --output /boot/EFI/BOOT/BOOTX64.EFI
}

setup_user() {
  log_info "Creating user: $user"
  useradd "$user"
  usermod -a -G wheel "$user"

  printf "\n%s\n" "Enter a password for $user:"
  passwd "$user"

  mkdir -p "/home/$user" || true
  chown -R "$user" "/home/$user"

  [ "$no_device" = 1 ] && {
    log_debug "--no-device flag set. Not creating user-owned directories on disk"
    mkdir -p /mnt || true
    mount "/dev/disk/by-uuid/$root_uuid" /mnt
    
    chown -R "/mnt/$user/Documents"
    mkdir -p "/mnt/$user/Documents" || true
    ln -s "/mnt/$user/Documents" "/home/$user/Documents"

    umount -R /mnt
  }
}

main() {
  parse_arguments "$@"

  configure_etc

  update_repositories

  install_packages

  configure_services

  build_uki

  [ -n "$user" ] && setup_user

  printf "\n%s\n" "Enter a password for root:"
  passwd
}

main "$@"
