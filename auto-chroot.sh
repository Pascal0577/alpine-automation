#!/bin/sh

set -eu

red="$(printf '\033[0;31m')"
yellow="$(printf '\033[0;33m')"
green="$(printf '\033[0;32m')"
white="$(printf '\033[0m')"
verbose=0
did_cleanup=0

parse_cmdline() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--verbose)
        verbose=1
        shift ;;
      -h|--help)
        echo "Usage: $0 [-v|--verbose] MOUNTPOINT [COMMAND]"
        exit 0 ;;
      --)
        shift; 
        break ;;
      -*)
        echo "Unknown option: $1"
        exit 1 ;;
      *)
        break ;;
    esac
  done
}

# Fancy unicode characters yaayyyyy :3
if printf '%s' "$LANG" | grep -q 'UTF-8'; then
  tick="✔ "
  cross="✘"
  warn="⚠"
else
  tick="+"
  cross="-"
  warn="!"
fi

# If $1 is unset then this is empty string
mountpoint="${1:-}"
shell="/bin/sh"

log_success() {
  printf "%s[${tick} SUCCESS]%s: %s\n" "$green" "$white" "$1"
  return 0
}

log_warn() {
  printf "%s[${warn} WARNING]%s: %s\n" "$yellow" "$white" "$1"
  return 0
}

log_error() {
  printf "%s[${cross} ERROR]%s: %s\n" "$red" "$white" "$1"
  exit 1
}

log_debug() {
  [ "$verbose" -eq 1 ] && printf "[DEBUG] %s\n" "$1"
  return 0
}

is_mounted() {
  log_debug "Checking if $1 is a mountpoint"
  if [ "$verbose" -eq 1 ]; then
    mountpoint "$1"
  else
    mountpoint -q "$1" 2>/dev/null
  fi
}

check_command() {
  log_debug "Checking if $1 is a command"
  command -v "$1" >/dev/null 2>&1 || log_error "Command '$1' not found"
}

run_mount() {
  if [ "$verbose" -eq 1 ]; then
    mount "$@"
  else
    mount "$@" 2>/dev/null
  fi
}

run_umount() {
  if [ "$verbose" -eq 1 ]; then
    umount "$@"
  else
    umount "$@" 2>/dev/null
  fi
}

setup_network() {
  log_debug "Trying to set up network configuration"
  if [ -f /etc/resolv.conf ] && [ ! -f "$1/etc/resolv.conf.arch-chroot-backup" ]; then
    [ -f "$1/etc/resolv.conf" ] && mv "$1/etc/resolv.conf" "$1/etc/resolv.conf.arch-chroot-backup"
    cp -L /etc/resolv.conf "$1/etc/resolv.conf" 2>/dev/null || log_warn "Failed to copy resolv.conf"
  fi
}

cleanup() {
  # Try to prevent cleanup from getting called twice
  [ "$did_cleanup" -eq 1 ] && {
    log_warn "cleanup already called!"
    return 1
  }
  did_cleanup=1

  log_debug "Running cleanup ..."

  if [ -f "$1/etc/resolv.conf.arch-chroot-backup" ]; then
    mv "$1/etc/resolv.conf.arch-chroot-backup" "$1/etc/resolv.conf"
  else
    rm -f "$1/etc/resolv.conf"
  fi

  run_umount -R "$1/proc" || log_warn "Failed to umount $1/proc"
  run_umount -R "$1/sys"  || log_warn "Failed to umount $1/sys"
  run_umount -R "$1/dev"  || log_warn "Failed to umount $1/dev"
  run_umount -R "$1/run"  || log_warn "Failed to umount $1/run"
  log_success "Cleaned up successfully."
}

cleanup_wrapper() {
  [ -d "$mountpoint" ] && cleanup "$mountpoint"
}

mount_filesystems() {
  failed=0
  log_debug "Mounting filesystems ..."
 
  # is_mounted is used to prevent mounting the filesystem when
  # something's already mounted there
  is_mounted "$1/proc" || {
    run_mount -t proc /proc "$1/proc" || { log_warn "Failed to mount /proc"; failed=1; }
  }
  is_mounted "$1/sys" || {
    run_mount --rbind /sys "$1/sys" || { log_warn "Failed to rbind /sys"; failed=1; }
    run_mount --make-rslave "$1/sys" || { log_warn "Failed to make-rslave /sys"; failed=1; }
  }
  is_mounted "$1/dev" || {
    run_mount --rbind /dev "$1/dev" || { log_warn "Failed to rbind /dev"; failed=1; }
    run_mount --make-rslave "$1/dev" || { log_warn "Failed to make-rslave /dev"; failed=1; }
  }
  is_mounted "$1/run" || {
    run_mount --rbind /run "$1/run" || { log_warn "Failed to rbind /run"; failed=1; }
    run_mount --make-rslave "$1/run" || { log_warn "Failed to make-rslave /run"; failed=1; }
  }

  return $failed
}

main() {
  log_debug "Checking if a proper mountpoint is provided: ${mountpoint}"
  [ -z "$mountpoint" ] && log_error "No mountpoint provided"

  log_debug "Checking if user is root"
  [ "$(id -u)" != "0" ] && log_error "Must run as root."

  check_command mount
  check_command umount
  check_command chroot
  check_command realpath
  check_command mountpoint

  parse_cmdline "$@"
  
  log_debug "Taking realpath of $mountpoint"
  mountpoint="$(realpath "$mountpoint")"
  trap cleanup_wrapper EXIT INT TERM

  log_debug "Checking if mountpoint exists"
  [ ! -d "$mountpoint" ] && log_error "Mountpoint does not exist."

  log_debug "Checking if bash is in the chroot environment"
  [ -x "$mountpoint/bin/bash" ] && {
    shell="/bin/bash"
    log_debug "bash found, setting it to be the default shell"
  }

  command="${2:-$shell}"
  log_debug "Command to run upon entering the chroot environment: ${command}"
  
  log_debug "Checking if /etc/profile exists in the chroot environment"
  [ -e "$mountpoint/etc/profile" ] && {
    command=". /etc/profile && $command"
    log_debug "/etc/profile found, sourcing it when entering the chroot environment"
  }

  is_mounted "$mountpoint" || log_warn "$mountpoint is not a mountpoint"

  if mount_filesystems "$mountpoint"; then
    setup_network "$mountpoint"
    log_debug "Command running: chroot '$mountpoint' '$shell' -c '$command; exit 0'"
    chroot "$mountpoint" "$shell" -c "$command; exit 0"
  else
    exit_code=$?
    log_error "Filesystem mounts failed with exit code: $exit_code"
  fi
}

main "$@"
