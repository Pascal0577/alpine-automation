# Kernel Command Line Options
## Hardware Requirements
- A USB device with an EFI System Partition formatted with FAT32, and a root partition formatted as ext4, xfs, or btrfs.
- The root partition must have a `rootfs.squashfs` and `firmware.squashfs`. If persistence is desire, `upperfs.squashfs` must exist as well.
- The root partition must not contain any logical volumes (I am still working out how to work this out)

## Kernel Command Line Parameters
- `root=UUID=<uuid of root partition>`:
    - This is what the initramfs uses to identify the root partition so it can mount it. 
- `zram` or `zram=<sizeM | sizeG>`:
    - Whether or not the root filesystem should be stored on a ZRAM block, with a total of `size` M or G allocated.
    - If size is not specified, the zram block will be as large as possible
    - If this parameter is not given, the initramfs will use tmpfs for the ramdisc
- `zram.comp=<lz4 | zstd | xz>`: What compression algorithm should be used for the ZRAM block. By default, `zstd` compression is used.
- `boot_type=<default_boot | backup_boot | clean_boot>`:
    - Not intended to be used by the user. 
    - This is a variable used in the initramfs to determine which squashfs image to use, if any.
    - `boot_type=default_boot` looks for `upperfs.squashfs`
    - `boot_type=backup_boot` looks for `upperfs-backup.squashfs`
    - `boot_type=clean_boot` does not decompress any upperfs image.
- `cryptdevice=UUID=<uuid of encrypted partition>:<name>`:
    - The encrypted filesystem that the initramfs should unlock
    - It is decrypted to `/dev/mapper/<name>`
    - Decryption via key files not yet supported.
- `squashfs_version=<image name>`
    - The name of the squashfs image to be unpacked into tmpfs/zram. Looks for `<image name>.squashfs` on the USB partition.

