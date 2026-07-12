#!/bin/bash
# multibrew installer

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly SCRIPT_URL="https://raw.githubusercontent.com/octomako/multibrew/main/multibrew.sh"
readonly INSTALL_PATH="/usr/local/bin/multibrew"

TEMP_FILE=""

cleanup() {
    [[ -n "$TEMP_FILE" ]] && /bin/rm -f "$TEMP_FILE"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

trap cleanup EXIT

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || die "multibrew only supports macOS"
[[ "$EUID" -ne 0 ]] || die "run the installer without sudo"

TEMP_FILE="$(/usr/bin/mktemp /private/tmp/multibrew-install.XXXXXX)"
printf '==> downloading multibrew\n'

/usr/bin/curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "$SCRIPT_URL" -o "$TEMP_FILE" ||
    die "could not download multibrew"

[[ -s "$TEMP_FILE" ]] || die "the download is empty"
/bin/bash -n "$TEMP_FILE" || die "the downloaded script has invalid Bash syntax"
/usr/bin/grep -q '^readonly VERSION=' "$TEMP_FILE" || die "the download does not look like multibrew"

printf '==> installing multibrew\n'

/usr/bin/sudo /bin/mkdir -p "$(/usr/bin/dirname "$INSTALL_PATH")"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 "$TEMP_FILE" "$INSTALL_PATH"

printf 'ok multibrew %s is installed\n' "$("$INSTALL_PATH" --version)"
printf '\nrun sudo multibrew mount\n'
