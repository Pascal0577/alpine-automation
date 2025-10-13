#!/bin/sh
readonly STATE_DIR="/run/firmware-hook/"
readonly VERSION="$STATE_DIR/firmware-version"
readonly NEEDS_REBUILD="$STATE_DIR/firmware-needs-rebuild"
readonly FIRST_INSTALL="$STATE_DIR/first-install"

if [ "$1" = "pre-commit" ]; then

    mkdir -p "$STATE_DIR" 
    echo 0 > "$FIRST_INSTALL"
    echo 0 > "$NEEDS_REBUILD"

    if [ ! -e "/first_install" ]; then
        prev_version="$(apk info linux-firmware | awk 'NR==1{print $1}')"
    else
        echo 1 > "$FIRST_INSTALL"
    fi

    [ -z "$prev_version" ] && echo 1 > "$NEEDS_REBUILD"
    echo "$prev_version" > "$VERSION"

elif [ "$1" = "post-commit" ]; then

    [ "$(cat "$FIRST_INSTALL")" = 0 ] && {
        prev_version="$(cat "$VERSION")"
        new_version="$(apk info linux-firmware | awk 'NR==1{print $1}')"

        [ "$prev_version" != "$new_version" ] && echo 1 > "$NEEDS_REBUILD"

        [ "$(cat $NEEDS_REBUILD)" = 1 ] && {
            cd /
            mksquashfs /lib/firmware firmware.squashfs -no-compression -no-strip || {
                echo "ERROR CREATING MODULE SQUASHFS."
            }
            mv "firmware.squashfs" /persist
        }
    }
    rm -rf "$STATE_DIR"

fi

