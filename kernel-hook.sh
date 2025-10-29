#!/bin/sh
readonly STATE_DIR="/kernel-hook"
readonly TMP_DIR="$STATE_DIR/KERNEL-MODULES-$$"
FIRST_INSTALL=0

if [ "$1" = "post-commit" ]; then
    [ -f /first_install ] && FIRST_INSTALL=1

    for kernel in /lib/modules/*; do
        if [ -d "$kernel" ] && [ ! -f "/persist/$kernel" ]; then
            kernel="$(basename "$kernel")"
            mkdir -p "${TMP_DIR:?}/$kernel"
            cp -r "/lib/modules/$kernel" "${TMP_DIR:?}/$kernel"
            mksquashfs "${TMP_DIR:?}/$kernel" "${STATE_DIR:?}/modules-$kernel.squashfs" -comp zstd || {
                echo "ERROR CREATING MODULE SQUASHFS: $kernel"
                rm -rf "${TMP_DIR:?}/$kernel"
            }

            #if [ "$FIRST_INSTALL" = 1 ]; then
            #    mv "${STATE_DIR:?}/modules-$kernel.squashfs" /
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
