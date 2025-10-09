## Goals
I aim to create a versatile RAM-based operating system optimized for USB devices. This means maximizing responsiveness and minimizing I/O operations to the disk for longevity. Data recovery and filesystem utilities will be included by default.

## Overview

### General Info
The system is split into multiple squashfs images: `rootfs.squashfs`, `modules.squashfs`, `firmware.squashfs`, and `upperfs.squashfs`. `rootfs.squashfs` contains the base installation of the system, with kernel modules split to `modules-<version>.squashfs` and firmware to `firmware.squashfs`. `upperfs.squashfs` contains any additional packages, files, or changes to files. On boot, `rootfs.squashfs` and `upperfs.squashfs` are mounted as an overlayfs; this is how `upperfs.squashfs` contains all the changes to `rootfs.squashfs`. On shutdown, the overlayfs upperdir is squashed back down to `upperfs.squashfs` and the previous image is backed up. This allows changes to persist across reboots.

There are three boot types: default, backup, and clean. Default boot unpacks `upperfs.squashfs`, backup boot unpacks `upperdir-backup.squashfs`, and clean boot does not unpack any squashfs image, nor does it save any changes to the upperdir on shutdown. When the machine turns on, a GRUB menu greets the use with each option.

A swapfile is created on the USB stick, and configured to have low swappiness so that it is only used where memory is very nearly out so that the system does not crash. In general we want to try to avoid writing to the USB very often.

### Boot Process:
GRUB is loaded by the UEFI, which allows the user to pick a system to boot with. If the device is encrypted, the initramfs will prompt the user to unlock it. If the zram option is enabled, a zram block will be created, configured, and mounted to `/sysroot/upper/upper`. If the zram option is not enabled, tmpfs will be mounted at `/sysroot/upper/upper`. If the boot type is not clean boot, then the squashfs image that the user selected from the GRUB menu will be unpacked into `/sysroot/upper/upper`. Then `rootfs.squashfs` is mounted to `/sysroot/rootfs/`. `firmware.squashfs` and `modules-<version>.squashfs` are mounted to `/sysroot/firmware/` and `/sysroot/modules-<version>/`, respectively. An overlayfs if created at `/sysroot/overlay_root` with `/sysroot/rootfs` as the lowerdir, `/sysroot/upper/upper` as the upperdir, and `/sysroot/upper/work` as the workdir. Several mount points are moved around to make sure kernel modules, firmware, and the separate lowerdir and upperdirs are available once `switch_root` occurs. The USB's filesystem is mounted at `/persist`. The initramfs then switches root to `/sysroot/overlay_root/` and starts the init system. The init system does its typical stuff as well as creating symlinks from `/perist/user/*` to `/home/user/`.

### Runtime:
Most packages are installed via an `apk` which functions as the typical `apk` package manager most of the time. In the typical scenario, packages are simply installed system-wide and into the upperdir. This means that all user-installed packages will not be in the `rootfs.squashfs`, but rather the `upperfs.squashfs`. Special packages (including kernels, GRUB, firmware, and mkinitfs) have triggers or install in such a way that is incompatible with this system's architecture. As such, when these packages are installed or upgraded, they are fetched with `apk fetch`, unpacked, patched, and are re-packaged before being installed. This ensures that GRUB updates do not break the custom GRUB menus, or that kernel modules are not installed into the upperdir for example.

### Shutdown:
The `upperdir` is squashed to `/persist/upperfs-tmp.squashfs`. This is then mounted to `/tmp/upperfs-test/`. If no errors occur, `/persist/upperfs-backup.squashfs` is deleted, `/persist/upperfs.squashfs` is copied to `/persist/upperfs-backup.squashfs`, and `/persist/upperfs-tmp.squashfs` is copied to `/persist/upperfs.squashfs`, which saves any changes the user might have made to the filesystem. The rest of the shutdown process proceeds as normal, like in a typical Linux system.


## System Architecture
/dev/sda1 is formatted as FAT32 and /dev/sda2 is formatted as ext4.
```
/dev/sda1                  
├── EFI/ 
│   └── BOOT/
│       └── BOOTX64.EFI              <- GRUB
├── grub 
│   └── (grub configuration files)
├── vmlinuz-lts                     <- Root filesystem
└── initramfs-lts                   <- Root filesystem

/dev/sda2
├── user/                           <- owned by user. Contents symlinked to /home/user/ on startup
│   ├── Documents/
│   ├── Pictures/
│   └── (anything else user wants to store on the USB)
├── rootfs.squashfs                 <- Root filesystem
├── firmware.squashfs               <- Firmware
├── modules-<version>.squashfs      <- All of the kernel modules for linux-<version>
└── upperdir.squashfs               <- Installed packages, user configs, etc
```

## Contributing
This is just a hobby project. Feel free to:
- Open issues for bugs
- Submit PRs (no formal process yet)

No guarantees on response time, I just work on this when I have the energy/free time :)

## Installation
Clone the repo, and format your USB drive like above. Run the `./build-image.sh` script and go through the prompts. 
