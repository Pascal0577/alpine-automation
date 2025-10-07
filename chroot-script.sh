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

  rm ./root_uuid
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
  apk add alpine-base linux-lts wpa_supplicant util-linux util-linux-login linux-pam squashfs-tools \
    || log_error "in install_packages: failed to install critical packages"
  setup-wayland-base || log_error "in install_packages: failed to install critical packages"

  # The grub trigger will fail due to lack of device being mounted at /
  # This is expected behavior. Grub is configured manually later
  # We let it fail gracefully here
  apk add grub-efi efibootmgr
  log_info "The grub trigger is expected to fail here" | grep -v "grub.*trigger: exited with error" || true

  [ -n "$user" ] && apk add doas
}

configure_services() {
  log_info "Configuring services"
  rc-update add hwdrivers boot     || log_error "In configure_services: Failed to add critical service"
  rc-update add elogind default    || log_error "In configure_services: Failed to add critical service"
  rc-update add squashdir shutdown || log_error "In configure_services: Failed to add critical service"
  rc-update del dbus sysinit
  rc-update add dbus default       || log_error "In configure_services: Failed to add critical service"
  rc-update add cgroups sysinit    || log_error "In configure_services: Failed to add critical service"
  rc-update add devfs sysinit      || log_error "In configure_services: Failed to add critical service"
  rc-update add hostname boot      || log_error "In configure_services: Failed to add critical service"
  rc-update add sysctl boot        || log_error "In configure_services: Failed to add critical service"
  rc-update add bootmisc boot      || log_error "In configure_services: Failed to add critical service"
  rc-update add modules boot       || log_error "In configure_services: Failed to add critical service"
}

configure_etc() {
  log_info "Configuring /etc"

  log_debug "Setting hostname"
  printf "\n%s" "Enter a hostname for this device: "
  read -r hostname
  echo "$hostname" > /etc/hostname

  log_debug "Configuring interfaces"
  cat > /etc/network/interfaces << EOF
auto lo

auto wlan0
iface wlan0 inet dhcp

auto eth0
iface eth0 inet dhcp
EOF

  log_debug "Configuring PAM"
  mkdir -p /etc/pam.d/
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
  echo "messagebus:x:99:messagebus" >> /etc/group
  echo "messagebus:x:99:99:messagebus user:/run/dbus:/sbin/nologin" >> /etc/passwd
}

install_bootloader() {
  log_info "Installing bootloader"
  grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=BOOT \
    --removable || log_error "In install_bootloader: grub-install failed"

  log_debug "Creating grub configuration at /boot/grub/grub.cfg"
  cat > /boot/grub/grub.cfg << EOF
set timeout=10
set default=0

menuentry "Alpine Linux (Default)" {
    linux /vmlinuz-lts $cmdline boot_type=default_boot
    initrd /initramfs-lts
}

menuentry "Alpine Linux (Backup)" {
    linux /vmlinuz-lts $cmdline boot_type=backup_boot
    initrd /initramfs-lts
}

menuentry "Alpine Linux (Clean Boot)" {
    linux /vmlinuz-lts $cmdline boot_type=clean_boot
    initrd /initramfs-lts
}
EOF
}

setup_user() {
  echo "permit persist :wheel" > /etc/doas.conf

  log_info "Creating user: $user"
  useradd "$user"
  usermod -a -G wheel "$user"

  printf "\n%s\n" "Enter a password for $user:"
  passwd "$user"

  mkdir -p "/home/$user" || true
  chown -R "$user":"$user" "/home/$user"

  if [ "$no_device" = 0 ]; then
    mkdir -p /mnt || true
    mount "/dev/disk/by-uuid/$root_uuid" /mnt
    
    for dir in Documents Pictures Videos; do
      mkdir -p "/mnt/$user/$dir" || true
      ln -s "/persist/$user/$dir" "/home/$user/$dir"
    done

    chown -R "$user":"$user" "/mnt/$user/"
    umount -R /mnt
  else 
    log_debug "--no-device flag set. Not creating user-owned directories on disk"
  fi
}

main() {
  parse_arguments "$@"

  configure_etc

  update_repositories

  install_packages

  configure_services

  install_bootloader

  [ -n "$user" ] && setup_user

  printf "\n%s\n" "Enter a password for root:"
  passwd
}

main "$@"
