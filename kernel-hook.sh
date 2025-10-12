#!/bin/sh
readonly STATE_DIR="/run/kernel-hook/"
readonly VERSION="/run/kernel-hook/kernel-version"
readonly NEEDS_REBUILD="/run/kernel-hook/kernel-needs-rebuild"
readonly TMP_DIR="/run/kernel-hook/KERNEL-MODULES-$$/"

if [ "$1" = "pre-commit" ]; then

    mkdir -p "$STATE_DIR" 
    first_install=0

    if [ -d /lib/modules ]; then
        prev_version="$(ls /lib/modules)"
    else
        first_install=1
    fi

    [ -z "$prev_version" ] && echo 1 > "$NEEDS_REBUILD"
    echo "$prev_version" > "$VERSION"

elif [ "$1" = "post-commit" ]; then

    [ "$first_install" = 0 ] && {
        prev_version="$(cat "$VERSION")"
        new_version="$(ls /lib/modules)"

        [ "$prev_version" != "$new_version" ] && echo 1 > "$NEEDS_REBUILD"

        [ "$(cat $NEEDS_REBUILD)" = 1 ] && {
            mkdir "$TMP_DIR"
            cp -r "/lib/modules/$new_version" "$TMP_DIR"
            mksquashfs "$TMP_DIR" "modules-$new_version.squashfs" -comp zstd || {
                echo "ERROR CREATING MODULE SQUASHFS."
                rm -rf "$TMP_DIR"
            }
            mv "modules-$new_version.squashfs" /
        }
    }
    rm -rf "$STATE_DIR"

fi
