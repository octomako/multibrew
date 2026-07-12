#!/bin/bash
# multibrew uninstaller

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly INSTALL_PATH="/usr/local/bin/multibrew"

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || {
    printf 'error: multibrew only supports macOS\n' >&2
    exit 1
}

[[ "$EUID" -ne 0 ]] || {
    printf 'error: run the uninstaller without sudo\n' >&2
    exit 1
}

printf '==> removing multibrew\n'
/usr/bin/sudo /bin/rm -f "$INSTALL_PATH"
printf 'the multibrew command is removed\n'

if [[ -f /var/db/multibrew/config ]]; then
    printf '\nthe shared Homebrew setup is still mounted\n'
fi
