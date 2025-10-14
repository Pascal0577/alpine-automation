#!/bin/sh
readonly STATE_DIR="/run/kernel-hook"
readonly VERSION="$STATE_DIR/kernel-version"
readonly NEEDS_REBUILD="$STATE_DIR/kernel-needs-rebuild"
readonly TMP_DIR="$STATE_DIR/KERNEL-MODULES-$$/"
readonly FIRST_INSTALL="$STATE_DIR/first-install"

if [ "$1" = "pre-commit" ]; then

    mkdir -p "$STATE_DIR" 
    echo 0 > "$FIRST_INSTALL"
    echo 0 > "$NEEDS_REBUILD"

    if [ -d /lib/modules ]; then
        prev_version="$(ls /lib/modules)"
    else
        echo 1 > "$FIRST_INSTALL"
    fi

    [ -z "$prev_version" ] && echo 1 > "$NEEDS_REBUILD"
    echo "$prev_version" > "$VERSION"

elif [ "$1" = "post-commit" ]; then

    [ "$(cat "$FIRST_INSTALL")" = 0 ] && {
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
