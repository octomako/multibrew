#!/bin/bash
# multibrew

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly VERSION="1.0.0"
readonly CONFIG_FORMAT="4"
readonly PREFIX="/opt/homebrew"
readonly BREW_BIN="$PREFIX/bin/brew"
readonly CONFIG_DIR="/var/db/multibrew"
readonly CONFIG_FILE="$CONFIG_DIR/config"
readonly PATH_FILE="/etc/paths.d/homebrew"
readonly LOCK_DIR="/private/var/run/multibrew.lock"
readonly BREW_GROUP="multibrew"
readonly ADMIN_GROUP="admin"
readonly INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
readonly GIT_MARKER="# managed by multibrew"
readonly ACL_PERMISSIONS="read,write,append,delete,delete_child,list,search,add_file,add_subdirectory,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"
readonly USERS_SETTINGS_URL="x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"

COMMAND=""
USERS_OPTION=""
ANALYTICS_OPTION=""
ASSUME_YES=0
VERBOSE=0
COLOR_MODE="auto"
LOCK_HELD=0
SUDO_KEEPALIVE_PID=""
TEMP_FILE=""
INVOKING_USER="${SUDO_USER:-}"

OWNER=""
GROUP_CREATED="0"
GROUP_UUID=""
PATH_CREATED="0"
ANALYTICS="off"
OLD_SYSTEM_GIT_PREFIX="0"
OLD_SYSTEM_GIT_CHILDREN="0"
SELECTED_USERS=()

RED=""
GREEN=""
YELLOW=""
BLUE=""
BOLD=""
RESET=""

# interface

usage() {
    cat <<EOF_USAGE
multibrew $VERSION

usage
  sudo multibrew <command> [options]

commands
  mount       set up shared Homebrew
  unmount     remove shared access and keep Homebrew
  repair      repair the shared setup
  update      update Homebrew and repair the shared setup
  members     manage the multibrew group
  status      audit the shared setup
  erase       remove Homebrew and the shared setup

options
  --users LIST       comma separated users for mount
  --analytics        enable Homebrew analytics
  --no-analytics     disable Homebrew analytics
  -y, --yes          accept ordinary confirmations
  --color             always use color
  --no-color          never use color
  --verbose           show detailed output
  -h, --help          show help
  -V, --version       show the version
EOF_USAGE
}

configure_colors() {
    local enabled=0

    case "$COLOR_MODE" in
        always) enabled=1 ;;
        never) enabled=0 ;;
        auto)
            if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
                enabled=1
            fi
            ;;
    esac

    if [[ "$enabled" -eq 1 ]]; then
        RED=$'\033[0;31m'
        GREEN=$'\033[0;32m'
        YELLOW=$'\033[0;33m'
        BLUE=$'\033[0;34m'
        BOLD=$'\033[1m'
        RESET=$'\033[0m'
    fi
}

step() {
    printf '%s==>%s%s %s\n' "$BLUE" "$BOLD" "$RESET" "$*"
}

success() {
    printf '%s%sok%s %s\n' "$GREEN" "$BOLD" "$RESET" "$*"
}

detail() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        printf '    %s\n' "$*"
    fi
}

warning() {
    printf '%s%swarning:%s %s\n' "$YELLOW" "$BOLD" "$RESET" "$*" >&2
}

error() {
    printf '%s%serror:%s %s\n' "$RED" "$BOLD" "$RESET" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

die_with_status() {
    local status="$1"
    shift

    if [[ ! "$status" =~ ^[0-9]+$ || "$status" -eq 0 ]]; then
        status=1
    fi

    error "$*"
    exit "$status"
}

read_tty() {
    local prompt="$1"
    local output_name="$2"
    local value=""

    [[ -r /dev/tty ]] || die "interactive input is unavailable"
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r value </dev/tty || die "input was cancelled"
    printf -v "$output_name" '%s' "$value"
}

confirm() {
    local answer=""

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        return 0
    fi

    read_tty "$1 [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

confirm_phrase() {
    local answer=""

    printf '%s\n' "$1" >/dev/tty
    read_tty "type '$2' to continue: " answer
    [[ "$answer" == "$2" ]] || die "confirmation did not match"
}

set_analytics_option() {
    if [[ -n "$ANALYTICS_OPTION" && "$ANALYTICS_OPTION" != "$1" ]]; then
        die "use only one analytics option"
    fi

    ANALYTICS_OPTION="$1"
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            mount|unmount|repair|update|members|status|erase)
                [[ -z "$COMMAND" ]] || die "use only one command"
                COMMAND="$1"
                ;;
            install)
                [[ -z "$COMMAND" ]] || die "use only one command"
                COMMAND="mount"
                ;;
            group)
                [[ -z "$COMMAND" ]] || die "use only one command"
                COMMAND="members"
                ;;
            uninstall)
                [[ -z "$COMMAND" ]] || die "use only one command"
                COMMAND="erase"
                ;;
            help)
                usage
                exit 0
                ;;
            --users)
                shift
                [[ "$#" -gt 0 ]] || die "--users requires a value"
                USERS_OPTION="$1"
                ;;
            --analytics) set_analytics_option "on" ;;
            --no-analytics) set_analytics_option "off" ;;
            -y|--yes) ASSUME_YES=1 ;;
            --color) COLOR_MODE="always" ;;
            --no-color) COLOR_MODE="never" ;;
            --verbose) VERBOSE=1 ;;
            -h|--help)
                usage
                exit 0
                ;;
            -V|--version)
                printf '%s\n' "$VERSION"
                exit 0
                ;;
            *) die "unknown argument: $1" ;;
        esac

        shift
    done
}

validate_argument_scope() {
    [[ -n "$COMMAND" ]] || {
        usage
        exit 0
    }

    if [[ "$COMMAND" != "mount" && -n "$USERS_OPTION" ]]; then
        die "--users is only valid with mount"
    fi

    case "$COMMAND" in
        mount|repair|update) ;;
        *)
            [[ -z "$ANALYTICS_OPTION" ]] ||
                die "analytics options are only valid with mount, repair, or update"
            ;;
    esac
}

# process safety

cleanup_temp_file() {
    if [[ -n "$TEMP_FILE" ]]; then
        /bin/rm -f "$TEMP_FILE"
        TEMP_FILE=""
    fi
}

stop_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        /bin/kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}

release_resources() {
    stop_sudo_keepalive
    cleanup_temp_file

    if [[ "$LOCK_HELD" -eq 1 ]]; then
        /bin/rm -rf "$LOCK_DIR"
        LOCK_HELD=0
    fi
}

handle_error() {
    local exit_code="$?"

    trap - ERR
    error "command failed on line $1: $2"
    exit "$exit_code"
}

handle_signal() {
    release_resources
    exit 130
}

trap release_resources EXIT
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR
trap handle_signal HUP INT TERM

require_root() {
    [[ "$EUID" -eq 0 ]] || die "run with sudo: sudo multibrew $COMMAND"
}

require_supported_mac() {
    local os_name=""
    local architecture=""
    local macos_version=""
    local macos_major=""

    os_name="$(/usr/bin/uname -s)"
    architecture="$(/usr/bin/uname -m)"
    macos_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
    macos_major="${macos_version%%.*}"

    [[ "$os_name" == "Darwin" ]] || die "multibrew only supports macOS"
    [[ "$macos_major" =~ ^[0-9]+$ ]] || die "could not determine the macOS version"
    [[ "$macos_major" -ge 14 ]] || die "multibrew requires macOS Sonoma 14 or newer"

    if [[ "$architecture" != "arm64" ]]; then
        if [[ "$(/usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null || printf '0')" == "1" ]]; then
            die "this shell is using Rosetta, rerun with: arch -arm64 sudo multibrew $COMMAND"
        fi

        die "multibrew only supports Apple Silicon"
    fi

    detail "macOS $macos_version on Apple Silicon"
}

resolve_invoking_user() {
    if [[ -z "$INVOKING_USER" || "$INVOKING_USER" == "root" ]]; then
        INVOKING_USER="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
    fi

    if [[ -z "$INVOKING_USER" || "$INVOKING_USER" == "root" || "$INVOKING_USER" == "loginwindow" ]]; then
        die "run multibrew from a signed in administrator account using sudo"
    fi

    valid_local_name "$INVOKING_USER" || die "invalid local username: $INVOKING_USER"
    user_exists "$INVOKING_USER" || die "user does not exist: $INVOKING_USER"
    is_admin_user "$INVOKING_USER" || die "$INVOKING_USER must be a local administrator"
    detail "invoking administrator: $INVOKING_USER"
}

acquire_lock() {
    local existing_pid=""

    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        LOCK_HELD=1
        return
    fi

    existing_pid="$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null || true)"

    if [[ "$existing_pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$existing_pid" 2>/dev/null; then
        die "another multibrew command is running with pid $existing_pid"
    fi

    warning "removing a stale multibrew lock"
    /bin/rm -rf "$LOCK_DIR"
    /bin/mkdir "$LOCK_DIR"
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    LOCK_HELD=1
}

# local accounts

valid_local_name() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

user_exists() {
    /usr/bin/dscl . -read "/Users/$1" >/dev/null 2>&1
}

group_exists() {
    /usr/bin/dscl . -read "/Groups/$1" >/dev/null 2>&1
}

user_home() {
    /usr/bin/dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null |
        /usr/bin/awk '{print $2}'
}

user_primary_group() {
    /usr/bin/id -gn "$1" 2>/dev/null
}

group_uuid() {
    /usr/bin/dscl . -read "/Groups/$1" GeneratedUID 2>/dev/null |
        /usr/bin/awk '{print $2}'
}

is_admin_user() {
    /usr/bin/id -Gn "$1" |
        /usr/bin/tr ' ' '\n' |
        /usr/bin/grep -qx "$ADMIN_GROUP"
}

is_group_member() {
    /usr/sbin/dseditgroup -o checkmember -m "$1" "$BREW_GROUP" 2>/dev/null |
        /usr/bin/grep -q 'yes'
}

group_members() {
    /usr/bin/dscl . -read "/Groups/$BREW_GROUP" GroupMembership 2>/dev/null |
        /usr/bin/cut -d: -f2- |
        /usr/bin/xargs -n1 2>/dev/null || true
}

group_has_nested_groups() {
    local value=""

    value="$(/usr/bin/dscl . -read "/Groups/$BREW_GROUP" NestedGroups 2>/dev/null || true)"
    value="${value#NestedGroups:}"
    [[ -n "${value//[[:space:]]/}" ]]
}

list_local_admins() {
    local username=""
    local uid=""
    local home=""

    while IFS=$'\t' read -r username uid; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        [[ "$uid" -ge 500 && "$uid" -lt 65534 ]] || continue

        home="$(user_home "$username")"
        [[ "$home" == /Users/* ]] || continue
        is_admin_user "$username" || continue
        printf '%s\n' "$username"
    done < <(
        /usr/bin/dscl . -list /Users UniqueID |
            /usr/bin/awk '{print $1 "\t" $2}'
    )
}

list_local_users() {
    local username=""
    local uid=""
    local home=""

    while IFS=$'\t' read -r username uid; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        [[ "$uid" -ge 500 && "$uid" -lt 65534 ]] || continue

        home="$(user_home "$username")"
        [[ "$home" == /Users/* ]] || continue
        printf '%s\n' "$username"
    done < <(
        /usr/bin/dscl . -list /Users UniqueID |
            /usr/bin/awk '{print $1 "\t" $2}'
    )
}

normalize_users() {
    local input="$1"
    local include_invoker="${2:-0}"
    local item=""
    local seen=" "
    local IFS=','
    local -a items=()

    SELECTED_USERS=()
    read -r -a items <<<"$input"

    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"

        [[ -n "$item" ]] || continue
        valid_local_name "$item" || die "invalid username: $item"
        user_exists "$item" || die "user does not exist: $item"
        is_admin_user "$item" || die "$item is not a local administrator"

        if [[ "$seen" != *" $item "* ]]; then
            SELECTED_USERS+=("$item")
            seen+="$item "
        fi
    done

    if [[ "$include_invoker" == "1" && "$seen" != *" $INVOKING_USER "* ]]; then
        SELECTED_USERS+=("$INVOKING_USER")
    fi
}

select_admin_users() {
    local include_invoker="${1:-0}"
    local input=""
    local item=""
    local user=""
    local default_index=""
    local seen=" "
    local index=0
    local IFS=','
    local -a admins=()
    local -a items=()

    SELECTED_USERS=()

    while IFS= read -r user; do
        [[ -n "$user" ]] && admins+=("$user")
    done < <(list_local_admins)

    [[ "${#admins[@]}" -gt 0 ]] || die "no local administrators were found"

    printf '\nlocal administrators\n\n'
    for ((index = 0; index < ${#admins[@]}; index++)); do
        printf '  [%d] %s\n' "$((index + 1))" "${admins[$index]}"
        if [[ "${admins[$index]}" == "$INVOKING_USER" ]]; then
            default_index="$((index + 1))"
        fi
    done
    printf '\n'

    if [[ "$include_invoker" == "1" ]]; then
        read_tty "select users by number, separated by commas [$default_index]: " input
        input="${input:-$default_index}"
    else
        read_tty "select users by number, separated by commas: " input
        [[ -n "$input" ]] || die "no users were selected"
    fi

    read -r -a items <<<"$input"

    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ "$item" =~ ^[0-9]+$ ]] || die "invalid selection: $item"
        [[ "$item" -ge 1 && "$item" -le "${#admins[@]}" ]] || die "selection is out of range: $item"
        user="${admins[$((item - 1))]}"

        if [[ "$seen" != *" $user "* ]]; then
            SELECTED_USERS+=("$user")
            seen+="$user "
        fi
    done

    if [[ "$include_invoker" == "1" && "$seen" != *" $INVOKING_USER "* ]]; then
        SELECTED_USERS+=("$INVOKING_USER")
    fi
}

validate_group_members() {
    local user=""

    group_has_nested_groups &&
        die "the multibrew group contains nested groups, use direct users only"

    while IFS= read -r user; do
        [[ -n "$user" ]] || continue
        user_exists "$user" || die "the multibrew group contains a missing user: $user"
        is_admin_user "$user" || die "the multibrew group contains a non administrator: $user"
    done < <(group_members)
}

ensure_group() {
    step "checking the multibrew group"

    if group_exists "$BREW_GROUP"; then
        GROUP_CREATED="0"
        validate_group_members
        success "using the existing multibrew group"
    else
        /usr/sbin/dseditgroup -o create -r "multibrew shared Homebrew users" "$BREW_GROUP"
        group_exists "$BREW_GROUP" || die "could not create the multibrew group"
        GROUP_CREATED="1"
        success "created the multibrew group"
    fi

    GROUP_UUID="$(group_uuid "$BREW_GROUP")"
    [[ "$GROUP_UUID" =~ ^[0-9A-Fa-f-]{36}$ ]] ||
        die "could not determine the multibrew group identity"
}

add_group_member() {
    local user="$1"

    user_exists "$user" || die "user does not exist: $user"
    is_admin_user "$user" || die "$user is not a local administrator"

    if is_group_member "$user"; then
        detail "$user is already a multibrew member"
        return
    fi

    step "adding $user to multibrew"
    /usr/sbin/dseditgroup -o edit -a "$user" -t user "$BREW_GROUP"
    is_group_member "$user" || die "could not add $user to multibrew"
    success "added $user to multibrew"
}

remove_group_member() {
    local user="$1"

    [[ "$user" != "$OWNER" ]] || die "the Homebrew owner cannot be removed"
    is_group_member "$user" || die "$user is not a multibrew member"

    step "removing $user from multibrew"
    /usr/sbin/dseditgroup -o edit -d "$user" -t user "$BREW_GROUP"
    is_group_member "$user" && die "could not remove $user from multibrew"
    success "removed $user from multibrew"
}

# configuration

write_config() {
    local temporary=""

    /bin/mkdir -p "$CONFIG_DIR"
    /usr/sbin/chown root:wheel "$CONFIG_DIR"
    /bin/chmod 0755 "$CONFIG_DIR"
    temporary="$(umask 077; /usr/bin/mktemp "$CONFIG_DIR/config.XXXXXX")"

    cat >"$temporary" <<EOF_CONFIG
FORMAT=$CONFIG_FORMAT
OWNER=$OWNER
GROUP=$BREW_GROUP
GROUP_CREATED=$GROUP_CREATED
GROUP_UUID=$GROUP_UUID
PATH_CREATED=$PATH_CREATED
ANALYTICS=$ANALYTICS
EOF_CONFIG

    /usr/sbin/chown root:wheel "$temporary"
    /bin/chmod 0600 "$temporary"
    /bin/mv -f "$temporary" "$CONFIG_FILE"
}

load_config() {
    local key=""
    local value=""
    local format=""
    local configured_group=""
    local seen=" "

    [[ -f "$CONFIG_FILE" ]] || die "shared Homebrew is not mounted, run sudo multibrew mount"
    [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$CONFIG_FILE")" == "root:wheel:600" ]] ||
        die "the multibrew config permissions are invalid"

    OWNER=""
    GROUP_CREATED=""
    GROUP_UUID=""
    PATH_CREATED=""
    ANALYTICS="off"
    OLD_SYSTEM_GIT_PREFIX="0"
    OLD_SYSTEM_GIT_CHILDREN="0"

    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        [[ "$seen" != *" $key "* ]] || die "duplicate config key: $key"
        seen+="$key "

        case "$key" in
            FORMAT) format="$value" ;;
            OWNER) OWNER="$value" ;;
            GROUP) configured_group="$value" ;;
            GROUP_CREATED) GROUP_CREATED="$value" ;;
            GROUP_UUID) GROUP_UUID="$value" ;;
            PATH_CREATED) PATH_CREATED="$value" ;;
            ANALYTICS) ANALYTICS="$value" ;;
            GIT_PREFIX_TRUST_CREATED) OLD_SYSTEM_GIT_PREFIX="$value" ;;
            GIT_CHILD_TRUST_CREATED) OLD_SYSTEM_GIT_CHILDREN="$value" ;;
            *) die "unknown config key: $key" ;;
        esac
    done <"$CONFIG_FILE"

    [[ "$format" == "3" || "$format" == "$CONFIG_FORMAT" ]] ||
        die "the multibrew config format is not supported"
    [[ -z "$configured_group" || "$configured_group" == "$BREW_GROUP" ]] ||
        die "this setup uses an unsupported group: $configured_group"
    valid_local_name "$OWNER" || die "the Homebrew owner in the config is invalid"
    [[ "$GROUP_CREATED" == "0" || "$GROUP_CREATED" == "1" ]] || die "the group state is invalid"
    [[ "$PATH_CREATED" == "0" || "$PATH_CREATED" == "1" ]] || die "the path state is invalid"
    [[ "$ANALYTICS" == "off" || "$ANALYTICS" == "on" ]] || die "the analytics state is invalid"
    [[ "$GROUP_UUID" =~ ^[0-9A-Fa-f-]{36}$ ]] || die "the group identity is invalid"
}

apply_analytics_option() {
    if [[ -n "$ANALYTICS_OPTION" ]]; then
        ANALYTICS="$ANALYTICS_OPTION"
    fi
}

validate_configuration() {
    user_exists "$OWNER" || die "the Homebrew owner no longer exists: $OWNER"
    is_admin_user "$OWNER" || die "the Homebrew owner is no longer an administrator: $OWNER"
    group_exists "$BREW_GROUP" || die "the multibrew group no longer exists"
    [[ "$(group_uuid "$BREW_GROUP")" == "$GROUP_UUID" ]] ||
        die "the multibrew group was replaced"
    is_group_member "$OWNER" || die "the Homebrew owner is not a multibrew member"
    validate_group_members
}

remove_config() {
    /bin/rm -rf "$CONFIG_DIR"
}

# user execution

run_as_user() {
    local user="$1"
    shift

    local home=""
    local name=""
    local value=""
    local -a environment=(
        "USER=$user"
        "LOGNAME=$user"
        "SHELL=/bin/zsh"
        "PATH=$PREFIX/bin:$PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        "PWD=/"
    )

    user_exists "$user" || die "user does not exist: $user"
    home="$(user_home "$user")"
    [[ "$home" == /* ]] || die "could not determine the home directory for $user"
    environment+=("HOME=$home")

    if [[ "$ANALYTICS" == "off" ]]; then
        environment+=("HOMEBREW_NO_ANALYTICS=1")
    fi

    for name in TERM COLORTERM LANG LC_ALL LC_CTYPE HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
        value="$(/usr/bin/printenv "$name" 2>/dev/null || true)"
        [[ -n "$value" ]] && environment+=("$name=$value")
    done

    (
        cd /
        exec /usr/bin/sudo -H -u "$user" -- /usr/bin/env -i "${environment[@]}" "$@"
    )
}

run_as_owner() {
    run_as_user "$OWNER" "$@"
}

run_official_installer() {
    if [[ -t 0 ]]; then
        run_as_owner /bin/bash "$1" </dev/tty >/dev/tty 2>/dev/tty
        return
    fi

    run_as_owner /usr/bin/sudo -n -v >/dev/null 2>&1 ||
        die "a non interactive mount requires cached sudo access for $OWNER"

    run_as_owner /usr/bin/env NONINTERACTIVE=1 /bin/bash "$1"
}

authorize_owner_sudo() {
    if run_as_owner /usr/bin/sudo -n true >/dev/null 2>&1; then
        success "Homebrew authorization is already active"
        return
    fi

    step "requesting one administrator authorization for $OWNER"
    run_as_owner /usr/bin/sudo -v </dev/tty >/dev/tty || die "administrator authorization failed"
    success "Homebrew authorization is active"
}

start_sudo_keepalive() {
    stop_sudo_keepalive

    (
        while /bin/sleep 30; do
            run_as_owner /usr/bin/sudo -n -v >/dev/null 2>&1 || exit 0
        done
    ) &

    SUDO_KEEPALIVE_PID="$!"
}

# Apple tools

command_line_tools_ready() {
    /usr/bin/xcode-select -p >/dev/null 2>&1 &&
        /usr/bin/xcrun --find git >/dev/null 2>&1 &&
        /usr/bin/xcrun --find clang >/dev/null 2>&1 &&
        [[ -x /usr/bin/curl ]]
}

ensure_command_line_tools() {
    step "checking Apple Command Line Tools"

    if command_line_tools_ready; then
        success "Apple Command Line Tools are ready"
        return
    fi

    warning "Apple Command Line Tools are missing or incomplete"
    run_as_user "$INVOKING_USER" /usr/bin/xcode-select --install 2>/dev/null || true
    die "finish the Apple installer and run multibrew again"
}

# Git trust

user_git_directory() {
    printf '%s/.config/multibrew' "$(user_home "$1")"
}

user_git_file() {
    printf '%s/gitconfig' "$(user_git_directory "$1")"
}

user_git_include_exists() {
    local user="$1"
    local file=""

    file="$(user_git_file "$user")"
    run_as_user "$user" /usr/bin/git config --global --get-all include.path 2>/dev/null |
        /usr/bin/grep -Fxq "$file"
}

write_user_git_trust() {
    local user="$1"
    local primary_group=""
    local directory=""
    local file=""

    primary_group="$(user_primary_group "$user")"
    directory="$(user_git_directory "$user")"
    file="$(user_git_file "$user")"

    [[ -n "$primary_group" ]] || die "could not determine the primary group for $user"

    if [[ -f "$file" ]] && ! /usr/bin/grep -Fxiq "$GIT_MARKER" "$file"; then
        die "$file exists but is not managed by multibrew"
    fi

    run_as_user "$user" /bin/mkdir -p "$directory"
    /usr/sbin/chown "$user:$primary_group" "$directory"
    /bin/chmod 0700 "$directory"

    cat >"$file" <<EOF_GIT
$GIT_MARKER
[safe]
    directory = $PREFIX
    directory = $PREFIX/*
EOF_GIT

    /usr/sbin/chown "$user:$primary_group" "$file"
    /bin/chmod 0600 "$file"

    if ! user_git_include_exists "$user"; then
        run_as_user "$user" /usr/bin/git config --global --add include.path "$file"
    fi
}

remove_user_git_trust() {
    local user="$1"
    local directory=""
    local file=""
    local escaped=""

    user_exists "$user" || return
    directory="$(user_git_directory "$user")"
    file="$(user_git_file "$user")"
    escaped="$(printf '%s' "$file" | /usr/bin/sed 's/[][\\.^$*+?{}|()]/\\&/g')"

    run_as_user "$user" /usr/bin/git config --global --unset-all include.path "^${escaped}$" 2>/dev/null || true

    if [[ -f "$file" ]] && /usr/bin/grep -Fxiq "$GIT_MARKER" "$file"; then
        /bin/rm -f "$file"
        /bin/rmdir "$directory" 2>/dev/null || true
    fi
}

user_git_trust_valid() {
    local user="$1"
    local file=""

    file="$(user_git_file "$user")"
    [[ -f "$file" ]] || return 1
    [[ "$(/usr/bin/stat -f '%Su:%Lp' "$file" 2>/dev/null)" == "$user:600" ]] || return 1
    /usr/bin/grep -Fxiq "$GIT_MARKER" "$file" || return 1
    /usr/bin/grep -Fxq "    directory = $PREFIX" "$file" || return 1
    /usr/bin/grep -Fxq "    directory = $PREFIX/*" "$file" || return 1
    user_git_include_exists "$user"
}

sync_git_trust() {
    local user=""

    step "syncing Git trust"

    while IFS= read -r user; do
        [[ -n "$user" ]] || continue

        if is_group_member "$user"; then
            write_user_git_trust "$user"
        else
            remove_user_git_trust "$user"
        fi
    done < <(list_local_users)

    success "Git trust is synced"
}

remove_all_git_trust() {
    local home=""
    local user=""
    local file=""

    step "removing multibrew Git trust"

    while IFS= read -r -d '' home; do
        user="$(/usr/bin/stat -f '%Su' "$home" 2>/dev/null || true)"
        file="$home/.config/multibrew/gitconfig"

        if [[ -n "$user" ]] && user_exists "$user"; then
            remove_user_git_trust "$user"
        elif [[ -f "$file" ]] && /usr/bin/grep -Fxiq "$GIT_MARKER" "$file"; then
            /bin/rm -f "$file"
            /bin/rmdir "$home/.config/multibrew" 2>/dev/null || true
        fi
    done < <(/usr/bin/find /Users -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    success "multibrew Git trust is removed"
}

remove_old_system_git_trust() {
    local escaped=""

    if [[ "$OLD_SYSTEM_GIT_PREFIX" == "1" ]]; then
        escaped="$(printf '%s' "$PREFIX" | /usr/bin/sed 's/[][\\.^$*+?{}|()]/\\&/g')"
        /usr/bin/git config --system --unset-all safe.directory "^${escaped}$" 2>/dev/null || true
        OLD_SYSTEM_GIT_PREFIX="0"
    fi

    if [[ "$OLD_SYSTEM_GIT_CHILDREN" == "1" ]]; then
        escaped="$(printf '%s' "$PREFIX/*" | /usr/bin/sed 's/[][\\.^$*+?{}|()]/\\&/g')"
        /usr/bin/git config --system --unset-all safe.directory "^${escaped}$" 2>/dev/null || true
        OLD_SYSTEM_GIT_CHILDREN="0"
    fi
}

# Homebrew files

expected_path_file() {
    printf '%s' "$PREFIX/bin"
}

path_file_content_valid() {
    [[ -f "$PATH_FILE" ]] && [[ "$(/bin/cat "$PATH_FILE")" == "$(expected_path_file)" ]]
}

path_file_valid() {
    path_file_content_valid &&
        [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$PATH_FILE" 2>/dev/null)" == "root:wheel:644" ]]
}

preflight_path_file() {
    if [[ -f "$PATH_FILE" ]] && ! path_file_content_valid; then
        die "$PATH_FILE already exists with different contents"
    fi
}

install_path_file() {
    /bin/mkdir -p /etc/paths.d

    if [[ -f "$PATH_FILE" ]]; then
        path_file_content_valid || die "$PATH_FILE already exists with different contents"
        /usr/sbin/chown root:wheel "$PATH_FILE"
        /bin/chmod 0644 "$PATH_FILE"
        return
    fi

    PATH_CREATED="1"
    printf '%s\n' "$PREFIX/bin" >"$PATH_FILE"
    /usr/sbin/chown root:wheel "$PATH_FILE"
    /bin/chmod 0644 "$PATH_FILE"
}

preflight_prefix() {
    if [[ -x "$BREW_BIN" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            confirm "adopt the existing Homebrew installation at $PREFIX" ||
                die "the existing Homebrew installation was left unchanged"
        fi
        return
    fi

    if [[ -e "$PREFIX" && -n "$(/bin/ls -A "$PREFIX" 2>/dev/null || true)" ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            warning "a partial shared Homebrew setup was found and mount will resume"
            return
        fi

        die "$PREFIX is not empty and does not contain a valid Homebrew installation"
    fi
}

install_or_adopt_homebrew() {
    local reported_prefix=""
    local install_status=0

    step "checking Homebrew"

    if [[ -x "$BREW_BIN" ]]; then
        reported_prefix="$(run_as_owner "$BREW_BIN" --prefix 2>/dev/null || true)"
        [[ "$reported_prefix" == "$PREFIX" ]] ||
            die "$BREW_BIN does not report $PREFIX"
        success "using the existing Homebrew installation"
        return
    fi

    TEMP_FILE="$(/usr/bin/mktemp /private/tmp/multibrew-homebrew-install.XXXXXX)"

    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --proto '=https' \
        --proto-redir '=https' \
        --tlsv1.2 \
        "$INSTALL_URL" \
        --output "$TEMP_FILE" || die "could not download the official Homebrew installer"

    [[ -s "$TEMP_FILE" ]] || die "the Homebrew installer download is empty"
    /usr/sbin/chown root:wheel "$TEMP_FILE"
    /bin/chmod 0644 "$TEMP_FILE"

    step "installing Homebrew as $OWNER"

    if run_official_installer "$TEMP_FILE"; then
        install_status=0
    else
        install_status=$?
    fi

    cleanup_temp_file

    [[ "$install_status" -eq 0 ]] ||
        die_with_status "$install_status" "the Homebrew installer failed with exit code $install_status"
    [[ -x "$BREW_BIN" ]] || die "Homebrew did not create $BREW_BIN"
    success "Homebrew is installed at $PREFIX"
}

configure_analytics() {
    step "setting Homebrew analytics to $ANALYTICS"

    if [[ "$ANALYTICS" == "on" ]]; then
        run_as_owner "$BREW_BIN" analytics on
    else
        run_as_owner "$BREW_BIN" analytics off
    fi

    success "Homebrew analytics are $ANALYTICS"
}

verify_homebrew() {
    local reported_prefix=""
    local reported_repository=""
    local version=""

    [[ -x "$BREW_BIN" ]] || return 1
    reported_prefix="$(run_as_owner "$BREW_BIN" --prefix 2>/dev/null)" || return 1
    reported_repository="$(run_as_owner "$BREW_BIN" --repository 2>/dev/null)" || return 1
    version="$(run_as_owner "$BREW_BIN" --version 2>/dev/null | /usr/bin/head -n 1)" || return 1

    [[ "$reported_prefix" == "$PREFIX" ]] || return 1
    [[ "$reported_repository" == "$PREFIX" ]] || return 1
    [[ "$version" == Homebrew* ]] || return 1
    success "$version"
}

run_homebrew_update() {
    local status=0

    step "updating Homebrew as $OWNER"

    if run_as_owner "$BREW_BIN" update; then
        success "Homebrew is up to date"
        return 0
    else
        status=$?
        return "$status"
    fi
}

# shared permissions

acl_entry() {
    printf 'group:%s allow %s' "$BREW_GROUP" "$ACL_PERMISSIONS"
}

remove_group_acl() {
    local path="$1"
    local index=""

    while IFS= read -r index; do
        [[ "$index" =~ ^[0-9]+$ ]] || continue
        /bin/chmod -a# "$index" "$path"
    done < <(
        /bin/ls -lde "$path" 2>/dev/null |
            /usr/bin/awk -v group="group:$BREW_GROUP " '
                index($0, group) {
                    sub(/^[[:space:]]*/, "")
                    split($0, fields, ":")
                    print fields[1]
                }
            ' |
            /usr/bin/sort -rn
    )
}

apply_shared_permissions() {
    local path=""
    local entry=""

    [[ -d "$PREFIX" ]] || die "the Homebrew prefix is missing: $PREFIX"
    /bin/mkdir -p "$PREFIX/var"
    entry="$(acl_entry)"

    step "applying shared Homebrew permissions"
    /usr/sbin/chown -R "$OWNER:$BREW_GROUP" "$PREFIX"
    /bin/chmod -R g+rwX "$PREFIX"
    /usr/bin/find "$PREFIX" -type d -exec /bin/chmod g+s {} +

    while IFS= read -r -d '' path; do
        remove_group_acl "$path"
        /bin/chmod +a "$entry" "$path"
    done < <(/usr/bin/find "$PREFIX" -type d -print0)

    success "shared Homebrew permissions are ready"
}

restore_owner_permissions() {
    local path=""

    [[ -d "$PREFIX" ]] || return
    step "restoring owner only Homebrew permissions"

    while IFS= read -r -d '' path; do
        remove_group_acl "$path"
    done < <(/usr/bin/find "$PREFIX" -print0)

    /usr/sbin/chown -R "$OWNER:$ADMIN_GROUP" "$PREFIX"
    /bin/chmod -R u+rwX,go+rX,go-w "$PREFIX"
    /usr/bin/find "$PREFIX" -type d -exec /bin/chmod g-s {} +
    success "Homebrew is owned by $OWNER"
}

permission_problem() {
    local problem=""

    if [[ "$(/usr/bin/stat -f '%Su' "$PREFIX" 2>/dev/null || true)" != "$OWNER" ]]; then
        printf 'the prefix owner is not %s' "$OWNER"
        return
    fi

    if [[ "$(/usr/bin/stat -f '%Sg' "$PREFIX" 2>/dev/null || true)" != "$BREW_GROUP" ]]; then
        printf 'the prefix group is not %s' "$BREW_GROUP"
        return
    fi

    problem="$(/usr/bin/find "$PREFIX" -type d ! -group "$BREW_GROUP" -print -quit 2>/dev/null || true)"
    if [[ -n "$problem" ]]; then
        printf 'a directory has the wrong group: %s' "$problem"
        return
    fi

    problem="$(/usr/bin/find "$PREFIX" -type d ! -perm -2000 -print -quit 2>/dev/null || true)"
    if [[ -n "$problem" ]]; then
        printf 'a directory is missing group inheritance: %s' "$problem"
        return
    fi

    problem="$(/usr/bin/find "$PREFIX" -type d ! -perm -0020 -print -quit 2>/dev/null || true)"
    if [[ -n "$problem" ]]; then
        printf 'a directory is not group writable: %s' "$problem"
    fi
}

probe_user_access() {
    local user="$1"
    local file="$PREFIX/var/.multibrew-probe-$user-$$"

    run_as_user "$user" /usr/bin/touch "$file" >/dev/null 2>&1 &&
        run_as_user "$user" /bin/rm -f "$file" >/dev/null 2>&1 &&
        [[ "$(run_as_user "$user" "$BREW_BIN" --prefix 2>/dev/null)" == "$PREFIX" ]]
}

probe_acl_inheritance() {
    local creator="$OWNER"
    local tester="$OWNER"
    local member=""
    local file="$PREFIX/var/.multibrew-acl-probe-$$"

    while IFS= read -r member; do
        if [[ -n "$member" && "$member" != "$creator" ]]; then
            tester="$member"
            break
        fi
    done < <(group_members)

    run_as_user "$creator" /bin/sh -c 'umask 077; : > "$1"' sh "$file" >/dev/null 2>&1 || return 1

    if ! /bin/ls -le "$file" 2>/dev/null |
        /usr/bin/grep -Eq "group:${BREW_GROUP}.*allow"; then
        /bin/rm -f "$file"
        return 1
    fi

    if [[ "$tester" != "$creator" ]] &&
       ! run_as_user "$tester" /bin/sh -c 'printf x >> "$1"' sh "$file" >/dev/null 2>&1; then
        /bin/rm -f "$file"
        return 1
    fi

    /bin/rm -f "$file"
}

# removal helpers

find_homebrew_launch_items() {
    local directory="$1"

    [[ -d "$directory" ]] || return 0

    /usr/bin/find "$directory" \
        -maxdepth 1 \
        -type f \
        -name 'homebrew.mxcl.*.plist' \
        -print0 2>/dev/null || true
}

remove_homebrew_launch_items() {
    local home=""
    local user=""
    local uid=""
    local plist=""

    step "removing Homebrew launch items"

    while IFS= read -r -d '' home; do
        user="$(/usr/bin/stat -f '%Su' "$home" 2>/dev/null || true)"
        uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"

        while IFS= read -r -d '' plist; do
            if [[ -n "$uid" ]]; then
                /bin/launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1 || true
            fi
            /bin/rm -f "$plist"
        done < <(find_homebrew_launch_items "$home/Library/LaunchAgents")
    done < <(/usr/bin/find /Users -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    while IFS= read -r -d '' plist; do
        /bin/launchctl bootout system "$plist" >/dev/null 2>&1 || true
        /bin/rm -f "$plist"
    done < <(find_homebrew_launch_items /Library/LaunchDaemons)

    while IFS= read -r -d '' plist; do
        while IFS= read -r user; do
            uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"
            [[ -n "$uid" ]] && /bin/launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1 || true
        done < <(list_local_users)
        /bin/rm -f "$plist"
    done < <(find_homebrew_launch_items /Library/LaunchAgents)

    success "Homebrew launch items are removed"
}

stop_all_homebrew_services() {
    local user=""

    step "stopping Homebrew services"

    while IFS= read -r user; do
        [[ -n "$user" ]] || continue
        detail "stopping services for $user"
        run_as_user "$user" "$BREW_BIN" services stop --all >/dev/null 2>&1 || true
    done < <(group_members)

    remove_homebrew_launch_items
    success "Homebrew services are stopped"
}

remove_all_casks() {
    local cask=""
    local -a casks=()
    local -a failed=()

    step "listing installed Homebrew casks"
    TEMP_FILE="$(/usr/bin/mktemp /private/tmp/multibrew-casks.XXXXXX)"

    run_as_owner "$BREW_BIN" list --cask >"$TEMP_FILE" ||
        die "could not list installed casks and nothing destructive was removed"

    while IFS= read -r cask; do
        [[ -n "$cask" ]] && casks+=("$cask")
    done <"$TEMP_FILE"

    cleanup_temp_file

    if [[ "${#casks[@]}" -eq 0 ]]; then
        success "no installed casks were found"
        return
    fi

    success "found ${#casks[@]} installed casks"
    warning "cask data cleanup may require Full Disk Access for this terminal"
    authorize_owner_sudo
    start_sudo_keepalive

    for cask in "${casks[@]}"; do
        step "removing cask and its data: $cask"

        if run_as_owner "$BREW_BIN" uninstall --cask --zap --force "$cask"; then
            success "removed cask: $cask"
        else
            failed+=("$cask")
            warning "could not completely remove cask: $cask"
        fi
    done

    stop_sudo_keepalive

    if [[ "${#failed[@]}" -gt 0 ]]; then
        die "cask removal failed for: ${failed[*]} and Homebrew was preserved"
    fi
}

remove_all_homebrew_user_state() {
    local home=""

    step "removing Homebrew caches and logs"

    while IFS= read -r -d '' home; do
        [[ "$home" == /Users/* ]] || continue
        /bin/rm -rf \
            "$home/Library/Caches/Homebrew" \
            "$home/Library/Logs/Homebrew" \
            "$home/.cache/Homebrew" \
            "$home/.config/homebrew"
    done < <(/usr/bin/find /Users -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    /bin/rm -rf /Library/Caches/Homebrew /Library/Logs/Homebrew
    success "Homebrew caches and logs are removed"
}

remove_group_if_owned() {
    if [[ "$GROUP_CREATED" != "1" ]]; then
        success "the existing multibrew group was preserved"
        return
    fi

    if ! group_exists "$BREW_GROUP"; then
        success "the multibrew group is already absent"
        return
    fi

    [[ "$(group_uuid "$BREW_GROUP")" == "$GROUP_UUID" ]] ||
        die "the multibrew group identity changed and it will not be deleted"

    step "deleting the multibrew group"
    /usr/sbin/dseditgroup -o delete "$BREW_GROUP" || die "could not delete the multibrew group"
    group_exists "$BREW_GROUP" && die "the multibrew group still exists"
    success "the multibrew group is deleted"
}

verify_complete_erase() {
    local failures=0
    local home=""
    local path=""

    step "checking for erase residue"

    for path in \
        "$PREFIX" \
        "$CONFIG_DIR" \
        /Applications/Homebrew \
        /Applications/HomebrewApps \
        /Library/Caches/Homebrew \
        /Library/Logs/Homebrew; do
        if [[ -e "$path" || -L "$path" ]]; then
            warning "residue remains: $path"
            failures=$((failures + 1))
        fi
    done

    if [[ "$PATH_CREATED" == "1" && ( -e "$PATH_FILE" || -L "$PATH_FILE" ) ]]; then
        warning "residue remains: $PATH_FILE"
        failures=$((failures + 1))
    fi

    if [[ "$GROUP_CREATED" == "1" ]] && group_exists "$BREW_GROUP"; then
        warning "residue remains: group $BREW_GROUP"
        failures=$((failures + 1))
    fi

    while IFS= read -r -d '' home; do
        for path in \
            "$home/Library/Caches/Homebrew" \
            "$home/Library/Logs/Homebrew" \
            "$home/.cache/Homebrew" \
            "$home/.config/homebrew"; do
            if [[ -e "$path" || -L "$path" ]]; then
                warning "residue remains: $path"
                failures=$((failures + 1))
            fi
        done

        if [[ -f "$home/.config/multibrew/gitconfig" ]] &&
           /usr/bin/grep -Fxiq "$GIT_MARKER" "$home/.config/multibrew/gitconfig"; then
            warning "residue remains: $home/.config/multibrew/gitconfig"
            failures=$((failures + 1))
        fi
    done < <(/usr/bin/find /Users -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    if /usr/bin/find /Users /Library/LaunchAgents /Library/LaunchDaemons \
        -type f -name 'homebrew.mxcl.*.plist' -print -quit 2>/dev/null |
        /usr/bin/grep -q .; then
        warning "one or more Homebrew launch items remain"
        failures=$((failures + 1))
    fi

    [[ "$failures" -eq 0 ]] || die "erase finished with $failures residue problems"
    success "erase residue check passed"
}

# commands

prepare_mount() {
    local user=""

    if [[ -f "$CONFIG_FILE" ]]; then
        load_config
        validate_configuration
        apply_analytics_option

        if [[ -n "$USERS_OPTION" ]]; then
            normalize_users "$USERS_OPTION" 1
            for user in "${SELECTED_USERS[@]}"; do
                add_group_member "$user"
            done
        fi

        return
    fi

    OWNER="$INVOKING_USER"
    ANALYTICS="off"

    if [[ ! -e "$PATH_FILE" ]]; then
        PATH_CREATED="1"
    fi

    warning "every multibrew member can modify software used by every other member"
    confirm "continue with trusted local administrators only" || die "mount was cancelled"

    ensure_group

    if [[ -n "$USERS_OPTION" ]]; then
        normalize_users "$USERS_OPTION" 1
    else
        select_admin_users 1
    fi

    for user in "${SELECTED_USERS[@]}"; do
        add_group_member "$user"
    done

    apply_analytics_option
    write_config
}

mount_homebrew() {
    local update_status=0

    step "mounting shared Homebrew"
    ensure_command_line_tools
    preflight_path_file
    preflight_prefix
    prepare_mount
    sync_git_trust
    remove_old_system_git_trust
    install_or_adopt_homebrew
    apply_shared_permissions
    install_path_file

    if run_homebrew_update; then
        update_status=0
    else
        update_status=$?
    fi

    apply_shared_permissions
    configure_analytics
    verify_homebrew || die "Homebrew failed verification after mount"
    write_config

    if [[ "$update_status" -ne 0 ]]; then
        die_with_status "$update_status" "Homebrew update failed with exit code $update_status and permissions were repaired"
    fi

    success "shared Homebrew is mounted"
    printf '\n  owner      %s\n' "$OWNER"
    printf '  group      %s\n' "$BREW_GROUP"
    printf '  analytics  %s\n' "$ANALYTICS"
    printf '\nsign out and back in after changing group membership\n'
}

unmount_homebrew() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        success "shared Homebrew is already unmounted"
        return
    fi

    step "unmounting shared Homebrew"
    load_config
    validate_configuration
    confirm "remove shared access and keep Homebrew for $OWNER" || die "unmount was cancelled"

    remove_all_git_trust
    remove_old_system_git_trust
    restore_owner_permissions
    remove_group_if_owned
    remove_config

    success "shared Homebrew is unmounted"
    printf '\nHomebrew remains installed for %s\n' "$OWNER"
}

repair_homebrew() {
    step "repairing shared Homebrew"
    ensure_command_line_tools
    load_config
    apply_analytics_option
    validate_configuration
    [[ -x "$BREW_BIN" ]] || die "Homebrew is missing: $BREW_BIN"
    remove_old_system_git_trust
    sync_git_trust
    apply_shared_permissions
    install_path_file
    configure_analytics
    verify_homebrew || die "Homebrew failed verification after repair"
    write_config
    success "shared Homebrew is repaired"
}

update_homebrew() {
    local update_status=0

    step "updating shared Homebrew"
    ensure_command_line_tools
    load_config
    apply_analytics_option
    validate_configuration
    [[ -x "$BREW_BIN" ]] || die "Homebrew is missing: $BREW_BIN"
    remove_old_system_git_trust
    sync_git_trust
    apply_shared_permissions
    install_path_file
    configure_analytics
    verify_homebrew || die "Homebrew failed verification before update"

    if run_homebrew_update; then
        update_status=0
    else
        update_status=$?
    fi

    apply_shared_permissions
    configure_analytics
    verify_homebrew || die "Homebrew failed verification after update"
    write_config

    if [[ "$update_status" -ne 0 ]]; then
        die_with_status "$update_status" "Homebrew update failed with exit code $update_status and permissions were repaired"
    fi

    success "shared Homebrew is updated"
}

manage_members() {
    local choice=""
    local user=""
    local remove_user=""

    load_config
    validate_configuration

    printf '\nmultibrew members\n\n'
    group_members | /usr/bin/sed 's/^/  /'
    printf '\n  [1] add users\n'
    printf '  [2] remove a user\n'
    printf '  [3] open Users & Groups\n'
    printf '  [4] done\n\n'
    read_tty "choose an option [1-4]: " choice

    case "$choice" in
        1)
            select_admin_users 0
            for user in "${SELECTED_USERS[@]}"; do
                add_group_member "$user"
            done
            sync_git_trust
            warning "changed users must sign out and back in"
            ;;
        2)
            read_tty "user to remove: " remove_user
            valid_local_name "$remove_user" || die "invalid username"
            remove_group_member "$remove_user"
            remove_user_git_trust "$remove_user"
            warning "changed users must sign out and back in"
            ;;
        3)
            run_as_user "$INVOKING_USER" /usr/bin/open "$USERS_SETTINGS_URL" >/dev/null 2>&1 ||
                run_as_user "$INVOKING_USER" /usr/bin/open -b com.apple.systempreferences >/dev/null 2>&1 ||
                die "could not open Users & Groups"
            success "opened Users & Groups"
            printf '\nafter editing multibrew membership run sudo multibrew repair\n'
            ;;
        4) return ;;
        *) die "invalid selection" ;;
    esac
}

show_status() {
    local failures=0
    local user=""
    local problem=""
    local analytics_state=""

    if [[ ! -f "$CONFIG_FILE" ]]; then
        success "shared Homebrew is not mounted"
        if [[ -x "$BREW_BIN" ]]; then
            OWNER="$INVOKING_USER"
            verify_homebrew || true
        fi
        return
    fi

    step "checking shared Homebrew"
    load_config

    if command_line_tools_ready; then
        success "Apple Command Line Tools are ready"
    else
        warning "Apple Command Line Tools are missing or incomplete"
        failures=$((failures + 1))
    fi

    if user_exists "$OWNER" && is_admin_user "$OWNER"; then
        success "owner is valid: $OWNER"
    else
        warning "the owner is missing or is not an administrator: $OWNER"
        failures=$((failures + 1))
    fi

    if group_exists "$BREW_GROUP" && [[ "$(group_uuid "$BREW_GROUP")" == "$GROUP_UUID" ]]; then
        success "group identity is valid: $BREW_GROUP"
    else
        warning "the multibrew group is missing or was replaced"
        failures=$((failures + 1))
    fi

    if is_group_member "$OWNER"; then
        success "$OWNER belongs to multibrew"
    else
        warning "$OWNER is not a multibrew member"
        failures=$((failures + 1))
    fi

    if verify_homebrew; then
        :
    else
        warning "Homebrew failed verification"
        failures=$((failures + 1))
    fi

    if [[ ! -d "$PREFIX" ]]; then
        warning "the Homebrew prefix is missing: $PREFIX"
        failures=$((failures + 1))
    else
        problem="$(permission_problem)"
        if [[ -n "$problem" ]]; then
            warning "$problem"
            failures=$((failures + 1))
        else
            success "Homebrew directory permissions are consistent"
        fi
    fi

    if [[ -d "$PREFIX/var" ]] && probe_acl_inheritance; then
        success "new Homebrew files inherit shared access"
    else
        warning "shared ACL inheritance is not working"
        failures=$((failures + 1))
    fi

    if path_file_valid; then
        success "the Homebrew path file is valid"
    else
        warning "the Homebrew path file is missing or invalid"
        failures=$((failures + 1))
    fi

    if analytics_state="$(run_as_owner "$BREW_BIN" analytics state 2>/dev/null)"; then
        success "analytics preference is $ANALYTICS"
        while IFS= read -r problem; do
            [[ -n "$problem" ]] && detail "$problem"
        done <<<"$analytics_state"
    else
        warning "could not read the Homebrew analytics state"
        failures=$((failures + 1))
    fi

    while IFS= read -r user; do
        [[ -n "$user" ]] || continue

        if ! user_exists "$user" || ! is_admin_user "$user"; then
            warning "invalid multibrew member: $user"
            failures=$((failures + 1))
            continue
        fi

        if user_git_trust_valid "$user"; then
            success "$user has valid Git trust"
        else
            warning "$user is missing managed Git trust"
            failures=$((failures + 1))
        fi

        if probe_user_access "$user"; then
            success "$user can use and modify Homebrew"
        else
            warning "$user cannot fully use Homebrew"
            failures=$((failures + 1))
        fi
    done < <(group_members)

    [[ "$failures" -eq 0 ]] || die "status found $failures problems"
    success "shared Homebrew passed every check"
}

prepare_homebrew_for_erase() {
    if verify_homebrew; then
        return
    fi

    warning "Homebrew is damaged and cannot list installed casks"
    step "repairing Homebrew before erase"
    ensure_command_line_tools
    install_or_adopt_homebrew
    apply_shared_permissions
    verify_homebrew || die "Homebrew could not be repaired and nothing destructive was removed"
    success "Homebrew is ready for erase"
}

erase_homebrew() {
    step "erasing shared Homebrew"
    load_config
    validate_configuration
    prepare_homebrew_for_erase

    confirm_phrase \
        "this removes Homebrew, formulae, casks, applications, services, caches, logs, and the shared setup" \
        "ERASE HOMEBREW"

    stop_all_homebrew_services
    remove_all_casks
    remove_all_homebrew_user_state
    remove_all_git_trust
    remove_old_system_git_trust

    step "removing the Homebrew prefix"
    /bin/rm -rf "$PREFIX"
    success "removed $PREFIX"

    if [[ "$PATH_CREATED" == "1" ]]; then
        /bin/rm -f "$PATH_FILE"
    fi

    /bin/rm -rf /Applications/Homebrew /Applications/HomebrewApps
    remove_group_if_owned
    remove_config
    verify_complete_erase

    success "Homebrew and the shared setup are erased"
    printf '\nthe multibrew command is still installed\n'
}

# entry point

main() {
    parse_arguments "$@"
    configure_colors
    validate_argument_scope
    require_root
    require_supported_mac
    resolve_invoking_user
    acquire_lock

    case "$COMMAND" in
        mount) mount_homebrew ;;
        unmount) unmount_homebrew ;;
        repair) repair_homebrew ;;
        update) update_homebrew ;;
        members) manage_members ;;
        status) show_status ;;
        erase) erase_homebrew ;;
        *) die "no valid command was selected" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
