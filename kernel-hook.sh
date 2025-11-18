#!/bin/sh
readonly STATE_DIR="/kernel-hook"
readonly TMP_DIR="$STATE_DIR/KERNEL-MODULES-$$"

if [ "$1" = "post-commit" ]; then
    for kernel in /lib/modules/*; do
        kernel="$(basename "$kernel")"
        if [ -d "$kernel" ] && [ ! -f "/persist/$kernel" ]; then
            mkdir -p "${TMP_DIR:?}/$kernel"
            cp -r "/lib/modules/$kernel" "${TMP_DIR:?}/$kernel"
            mksquashfs "${TMP_DIR:?}/$kernel" "${STATE_DIR:?}/modules-$kernel.squashfs" -comp zstd || {
                echo "ERROR CREATING MODULE SQUASHFS: $kernel"
                rm -rf "${TMP_DIR:?}/$kernel"
            }
            if [ -d /persist ]; then
                mv "${STATE_DIR:?}/modules-$kernel.squashfs" /persist
            else
                echo "ERROR: /persist does not exist. Exiting."
                rm -rf ${STATE_DIR:?}
                exit 1
            fi
        fi
    done
    rm -rf ${STATE_DIR:?}
fi
