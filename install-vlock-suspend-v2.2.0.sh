#!/usr/bin/bash
# Install a secure VT lock-and-suspend shortcut for GNOME sessions where the
# desktop's native lock screen is unavailable.
#
# Runtime sequence:
#   Super+L -> system service -> open a free VT -> kbd vlock -a -> suspend
#   -> resume to vlock -> authenticate -> return to the existing GNOME session
#
# This script deliberately does not alter device wakeup settings. Spurious
# wakeups from docks, monitors, USB devices, or firmware are machine-specific.

set -euo pipefail

readonly SCRIPT_VERSION="2.2.0"
readonly APP_ID="vlock-suspend"
readonly MANAGED_MARKER="# Managed by install-vlock-suspend.sh"
readonly ROOT_HELPER="/usr/local/libexec/vlock-suspend"
readonly MEDIA_SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
readonly CUSTOM_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
readonly CUSTOM_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vlock-suspend/"
readonly LEGACY_CUSTOM_PATH_1="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vlock-console/"
readonly LEGACY_WRAPPER="${HOME}/.local/bin/vlock-console"

USER_NAME="$(id -un)"
USER_UID="$(id -u)"
UNIT_NAME="vlock-suspend-${USER_UID}.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
SUDOERS_FILE="/etc/sudoers.d/vlock-suspend-${USER_UID}"
LEGACY_POLICY_FILES=(
    "/etc/polkit-1/rules.d/49-vlock-suspend-${USER_UID}.rules"
    "/etc/polkit-1/rules.d/49-vlock-suspend-${USER_UID}.rules.bak"
    "/etc/polkit-1/rules.d/49-vlock-suspend-${USER_UID}.rules.disabled"
    "/etc/polkit-1/rules.d/00-vlock-suspend-${USER_UID}.rules"
)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${APP_ID}"
SCREENSAVER_BACKUP="${STATE_DIR}/screensaver-binding.json"
LEGACY_SCREENSAVER_BACKUP="${STATE_DIR}/screensaver-binding.gvariant"
SHORTCUT_COMMAND=""

WORK_DIR=""

OPENVT=""
VLOCK=""
RUNUSER=""
SYSTEMCTL=""
LOGINCTL=""
LOGGER=""
FLOCK=""
GETENT=""
CAT=""
PYTHON=""
SETSID=""
CHVT=""
SLEEP=""
KILL=""
SUDO=""
VISUDO=""

usage() {
    cat <<EOF
Usage: $(basename "$0") COMMAND

Commands:
  install     Install or update the lock-and-suspend feature
  uninstall   Remove it and restore the previous GNOME lock binding
  status      Show installation and shortcut status
  test        Start the installed lock-and-suspend service
  abort       Stop a wedged lock-and-suspend service (for SSH recovery)
  logs        Show service and helper logs from the current boot
  help        Show this help

Run commands as the target user, not with sudo. Install and uninstall must run
from that user's GNOME desktop session.
EOF
}

note() {
    printf '%s\n' "$*"
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_regular_desktop_user() {
    (( EUID != 0 )) || die "Run this command as the logged-in GNOME user, not with sudo."
    [[ -n "${HOME:-}" && -d "$HOME" ]] || die "A valid user home directory is required."
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] ||
        die "Run this command from a terminal inside the GNOME desktop session."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

resolve_command() {
    local name=$1
    local resolved

    resolved="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || die "Required command not found: $name"
    readlink -f -- "$resolved"
}

validate_kbd_binary() {
    local path=$1
    local label=$2
    local owner

    owner="$(rpm -qf --qf '%{NAME}\n' "$path" 2>/dev/null || true)"
    [[ "$owner" == "kbd" ]] ||
        die "$label must be supplied by Fedora's kbd package; found owner '${owner:-unknown}' for $path"
}

resolve_dependencies() {
    local cmd

    for cmd in bash basename cat chmod chvt flock getent grep gsettings install kill loginctl logger mkdir mktemp mv openvt python3 readlink rm rpm runuser setsid sleep sudo systemctl visudo; do
        require_command "$cmd"
    done

    OPENVT="$(resolve_command openvt)"
    VLOCK="$(resolve_command vlock)"
    RUNUSER="$(resolve_command runuser)"
    SYSTEMCTL="$(resolve_command systemctl)"
    LOGINCTL="$(resolve_command loginctl)"
    LOGGER="$(resolve_command logger)"
    FLOCK="$(resolve_command flock)"
    GETENT="$(resolve_command getent)"
    CAT="$(resolve_command cat)"
    PYTHON="$(resolve_command python3)"
    SETSID="$(resolve_command setsid)"
    CHVT="$(resolve_command chvt)"
    SLEEP="$(resolve_command sleep)"
    KILL="$(resolve_command kill)"
    SUDO="$(resolve_command sudo)"
    VISUDO="$(resolve_command visudo)"

    validate_kbd_binary "$VLOCK" vlock
    validate_kbd_binary "$OPENVT" openvt
    validate_kbd_binary "$CHVT" chvt

    [[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] ||
        die "Unsupported username for the generated system unit: $USER_NAME"

    SHORTCUT_COMMAND="${SUDO} -n ${SYSTEMCTL} start --no-block ${UNIT_NAME}"

    if ! "$PYTHON" - <<'PY' >/dev/null 2>&1; then
from gi.repository import Gio
assert Gio.SettingsSchemaSource.get_default() is not None
PY
        die "Python GObject bindings for Gio are required."
    fi

    gsettings list-schemas | grep -Fx "$MEDIA_SCHEMA" >/dev/null ||
        die "GNOME media-key settings schema is unavailable."
    gsettings list-relocatable-schemas | grep -Fx "$CUSTOM_SCHEMA" >/dev/null ||
        die "GNOME custom-keybinding relocatable settings schema is unavailable."

    [[ -d /etc/sudoers.d ]] || die "sudoers include directory is unavailable."
}

resolve_uninstall_dependencies() {
    local cmd

    for cmd in dconf grep gsettings python3 readlink sudo systemctl; do
        require_command "$cmd"
    done

    PYTHON="$(resolve_command python3)"
    SYSTEMCTL="$(resolve_command systemctl)"
    if ! "$PYTHON" - <<'PY' >/dev/null 2>&1; then
from gi.repository import Gio
assert Gio.SettingsSchemaSource.get_default() is not None
PY
        die "Python GObject bindings for Gio are required."
    fi

    gsettings list-schemas | grep -Fx "$MEDIA_SCHEMA" >/dev/null ||
        die "GNOME media-key settings schema is unavailable."
    gsettings list-relocatable-schemas | grep -Fx "$CUSTOM_SCHEMA" >/dev/null ||
        die "GNOME custom-keybinding relocatable settings schema is unavailable."
}

check_suspend_support() {
    local result

    if command -v busctl >/dev/null 2>&1; then
        result="$(busctl call \
            org.freedesktop.login1 \
            /org/freedesktop/login1 \
            org.freedesktop.login1.Manager \
            CanSuspend 2>/dev/null || true)"
        case "$result" in
            *'"yes"'*|*'"challenge"'*) ;;
            *) warn "logind did not report normal suspend support: ${result:-no response}" ;;
        esac
    fi
}

check_managed_or_absent() {
    local path=$1

    # Always inspect root-managed paths through sudo so an inaccessible
    # existing file is not mistaken for an absent one.
    if sudo test -e "$path"; then
        sudo grep -Fq "$MANAGED_MARKER" "$path" ||
            die "Refusing to overwrite unmanaged file: $path"
    fi
}

sudoers_file_is_recognized() {
    local path=$1
    local expected_start expected_stop expected_pair noncomment

    expected_start="${USER_NAME} ALL=(root) NOPASSWD: ${SYSTEMCTL} start --no-block ${UNIT_NAME}"
    expected_stop="${USER_NAME} ALL=(root) NOPASSWD: ${SYSTEMCTL} stop ${UNIT_NAME}"
    expected_pair="${expected_start}"$'\n'"${expected_stop}"

    sudo test -e "$path" || return 1
    if sudo grep -Fq "$MANAGED_MARKER" "$path" 2>/dev/null; then
        return 0
    fi

    noncomment="$(sudo grep -Ev '^[[:space:]]*(#|$)' "$path" 2>/dev/null || true)"
    [[ "$noncomment" == "$expected_start" || "$noncomment" == "$expected_pair" ]]
}

check_sudoers_managed_or_absent() {
    if sudo test -e "$SUDOERS_FILE" && ! sudoers_file_is_recognized "$SUDOERS_FILE"; then
        die "Refusing to overwrite unrecognized sudoers file: $SUDOERS_FILE"
    fi
}

remove_sudoers_file_if_recognized() {
    if ! sudo test -e "$SUDOERS_FILE"; then
        return 0
    fi

    if sudoers_file_is_recognized "$SUDOERS_FILE"; then
        sudo rm -f -- "$SUDOERS_FILE"
    else
        warn "Leaving unrecognized sudoers file in place: $SUDOERS_FILE"
    fi
}

check_system_lock_services_inactive() {
    local active_units

    active_units="$(systemctl list-units \
        --type=service \
        --state=active,activating \
        --no-legend \
        'vlock-suspend-*.service' 2>/dev/null || true)"

    [[ -z "$active_units" ]] ||
        die "A vlock-suspend system service is active. Complete authentication before updating."
}

check_legacy_unit_inactive() {
    local legacy

    for legacy in vlock-console.service vlock-suspend.service; do
        if systemctl --user is-active --quiet "$legacy" 2>/dev/null; then
            die "Legacy user service $legacy is active. Unlock first, then rerun the installer."
        fi
    done
}

make_work_dir() {
    WORK_DIR="$(mktemp -d -t vlock-suspend.XXXXXX)"
    chmod 0700 "$WORK_DIR"
}

stage_root_helper() {
    local file="${WORK_DIR}/vlock-suspend"

    {
        cat <<EOF
#!/usr/bin/bash
$MANAGED_MARKER
set -u
EOF
        printf 'readonly OPENVT=%q\n' "$OPENVT"
        printf 'readonly VLOCK=%q\n' "$VLOCK"
        printf 'readonly RUNUSER=%q\n' "$RUNUSER"
        printf 'readonly SYSTEMCTL=%q\n' "$SYSTEMCTL"
        printf 'readonly LOGINCTL=%q\n' "$LOGINCTL"
        printf 'readonly LOGGER=%q\n' "$LOGGER"
        printf 'readonly FLOCK=%q\n' "$FLOCK"
        printf 'readonly GETENT=%q\n' "$GETENT"
        printf 'readonly CAT=%q\n' "$CAT"
        printf 'readonly PYTHON=%q\n' "$PYTHON"
        printf 'readonly SETSID=%q\n' "$SETSID"
        printf 'readonly CHVT=%q\n' "$CHVT"
        printf 'readonly SLEEP=%q\n' "$SLEEP"
        printf 'readonly KILL=%q\n' "$KILL"
        cat <<'HELPER'
readonly ACTIVE_VT_FILE=/sys/class/tty/tty0/active
readonly LOCK_FILE=/run/lock/vlock-suspend.lock
readonly SUSPEND_CONFIRM_NS=100000000

log_message() {
    "$LOGGER" -t vlock-suspend -- "$*"
}

fail() {
    log_message "$*"
    exit 1
}

boot_delta_ns() {
    "$PYTHON" - <<'PY'
import time

print(
    time.clock_gettime_ns(time.CLOCK_BOOTTIME)
    - time.clock_gettime_ns(time.CLOCK_MONOTONIC)
)
PY
}

process_group_is_safe() {
    local pid=$1

    "$PYTHON" - "$pid" <<'PY'
import os
import sys

pid = int(sys.argv[1])

try:
    data = open(f"/proc/{pid}/stat", "r", encoding="ascii").read()
except OSError:
    raise SystemExit(1)

right_paren = data.rfind(")")
if right_paren < 0:
    raise SystemExit(1)

fields = data[right_paren + 2 :].split()
if len(fields) < 3:
    raise SystemExit(1)

process_group = int(fields[2])
raise SystemExit(0 if process_group == pid and process_group != os.getpgrp() else 1)
PY
}

openvt_pid=""
original_vt=""

cleanup_launcher() {
    local pid=${openvt_pid:-}
    local original_number
    local group_kill=false

    [[ "$pid" =~ ^[0-9]+$ ]] || return 0

    if "$KILL" -0 "$pid" 2>/dev/null; then
        if process_group_is_safe "$pid"; then
            group_kill=true
            "$KILL" -TERM -- "-$pid" 2>/dev/null || true
        else
            log_message "Launcher PID $pid is not a safe process-group leader; terminating only that PID"
            "$KILL" -TERM -- "$pid" 2>/dev/null || true
        fi

        "$SLEEP" 0.2

        if [[ "$group_kill" == true ]]; then
            "$KILL" -KILL -- "-$pid" 2>/dev/null || true
        else
            "$KILL" -KILL -- "$pid" 2>/dev/null || true
        fi
    fi

    wait "$pid" 2>/dev/null || true

    if [[ "$original_vt" =~ ^tty([0-9]+)$ ]]; then
        original_number=${BASH_REMATCH[1]}
        "$CHVT" "$original_number" 2>/dev/null || true
    fi

    openvt_pid=""
}

on_signal() {
    log_message "Interrupted; cleaning up the lock launcher"
    trap - EXIT
    cleanup_launcher
    exit 1
}

trap cleanup_launcher EXIT
trap on_signal HUP INT TERM

[[ $EUID -eq 0 ]] || fail "Root privileges are required"
[[ $# -eq 2 ]] || fail "Expected username and UID arguments"

lock_user=$1
lock_uid=$2

[[ "$lock_uid" =~ ^[0-9]+$ ]] || fail "Invalid UID: $lock_uid"
(( lock_uid != 0 )) || fail "Refusing to lock as root"

passwd_entry="$($GETENT passwd "$lock_user" 2>/dev/null || true)"
[[ -n "$passwd_entry" ]] || fail "No passwd entry for user $lock_user"

IFS=: read -r resolved_user _ resolved_uid _ <<<"$passwd_entry"
[[ "$resolved_user" == "$lock_user" && "$resolved_uid" == "$lock_uid" ]] ||
    fail "Username and UID do not match"

lock_dir=${LOCK_FILE%/*}
[[ -d "$lock_dir" && -w "$lock_dir" ]] ||
    fail "Lock directory is unavailable or not writable: $lock_dir"
if [[ -e "$LOCK_FILE" && ! -w "$LOCK_FILE" ]]; then
    fail "Lock file is not writable: $LOCK_FILE"
fi
if ! : >"$LOCK_FILE"; then
    fail "Could not create or truncate lock file: $LOCK_FILE"
fi
exec 9<>"$LOCK_FILE"

if ! "$FLOCK" -n 9; then
    log_message "Another lock-and-suspend operation is already active"
    exit 0
fi

display_session="$($LOGINCTL show-user "$lock_user" -p Display --value 2>/dev/null || true)"
[[ -n "$display_session" ]] || fail "No graphical display session found for $lock_user"

session_active="$($LOGINCTL show-session "$display_session" -p Active --value 2>/dev/null || true)"
session_remote="$($LOGINCTL show-session "$display_session" -p Remote --value 2>/dev/null || true)"
session_class="$($LOGINCTL show-session "$display_session" -p Class --value 2>/dev/null || true)"
session_uid="$($LOGINCTL show-session "$display_session" -p User --value 2>/dev/null || true)"
session_vt="$($LOGINCTL show-session "$display_session" -p VTNr --value 2>/dev/null || true)"

[[ "$session_active" == yes ]] || fail "The graphical session is not active"
[[ "$session_remote" == no ]] || fail "Refusing to operate on a remote session"
[[ "$session_class" == user ]] || fail "Unexpected session class: ${session_class:-unknown}"
[[ "$session_uid" == "$lock_uid" ]] || fail "The display session belongs to another UID"
[[ "$session_vt" =~ ^[0-9]+$ && "$session_vt" -gt 0 ]] ||
    fail "The graphical session has no virtual terminal"

original_vt="$($CAT "$ACTIVE_VT_FILE" 2>/dev/null || true)"
[[ "$original_vt" == "tty${session_vt}" ]] ||
    fail "Active VT $original_vt does not match graphical session VT tty${session_vt}"

log_message "Starting kbd vlock for $lock_user from $original_vt"

"$SETSID" "$OPENVT" -s -w -- \
    "$RUNUSER" -u "$lock_user" -- \
    "$VLOCK" -a &
openvt_pid=$!

# Wait until openvt has switched to a different VT and something has changed
# that VT to VT_PROCESS mode. For Fedora kbd vlock -a this is a sound readiness
# proxy, although VT_PROCESS alone does not prove how release requests are
# handled.
if ! locked_vt="$($PYTHON - "$original_vt" "$openvt_pid" <<'PY'
import fcntl
import os
import re
import sys
import time

VT_GETMODE = 0x5601
VT_PROCESS = 1
ACTIVE_VT = "/sys/class/tty/tty0/active"

original = sys.argv[1]
pid = int(sys.argv[2])
deadline = time.monotonic() + 5.0
last_error = "lock VT did not become ready"


def process_state(process_id):
    try:
        data = open(f"/proc/{process_id}/stat", "r", encoding="ascii").read()
    except FileNotFoundError:
        return None
    except OSError as error:
        return f"error:{error}"

    right_paren = data.rfind(")")
    if right_paren < 0:
        return "error:malformed /proc stat"

    fields = data[right_paren + 2 :].split()
    if not fields:
        return "error:malformed /proc stat"

    return fields[0]


while time.monotonic() < deadline:
    state = process_state(pid)
    if state is None:
        print("openvt exited before the lock became ready", file=sys.stderr)
        raise SystemExit(1)
    if state == "Z":
        print("openvt became a zombie before the lock became ready", file=sys.stderr)
        raise SystemExit(1)
    if state.startswith("error:"):
        last_error = state.removeprefix("error:")

    try:
        with open(ACTIVE_VT, "r", encoding="ascii") as handle:
            current = handle.read().strip()
    except OSError as error:
        last_error = f"cannot read active VT: {error}"
        time.sleep(0.05)
        continue

    match = re.fullmatch(r"tty([0-9]+)", current)
    if current != original and match:
        path = f"/dev/{current}"
        try:
            descriptor = os.open(path, os.O_RDWR | os.O_NOCTTY)
            try:
                mode = bytearray(8)  # struct vt_mode on Linux
                fcntl.ioctl(descriptor, VT_GETMODE, mode, True)
            finally:
                os.close(descriptor)
        except OSError as error:
            last_error = f"cannot inspect {path}: {error}"
        else:
            if mode[0] == VT_PROCESS:
                print(current)
                raise SystemExit(0)
            last_error = f"{current} is active but not in VT_PROCESS mode"

    time.sleep(0.05)

print(last_error, file=sys.stderr)
raise SystemExit(1)
PY
)"; then
    log_message "Lock readiness verification failed; refusing to suspend"
    exit 1
fi

suspend_before_ns="$(boot_delta_ns)" ||
    fail "Could not sample suspend clock before requesting suspend"
[[ "$suspend_before_ns" =~ ^-?[0-9]+$ ]] ||
    fail "Invalid suspend clock sample before suspend"

log_message "$locked_vt is active in VT_PROCESS mode; requesting suspend"
"$SYSTEMCTL" suspend
suspend_result=$?

if (( suspend_result == 0 )); then
    log_message "Suspend request accepted by logind; waiting for vlock authentication"
else
    log_message "Suspend request failed with status $suspend_result; waiting for vlock authentication"
fi

# From here, openvt owns its normal lifecycle. Signals still invoke
# cleanup_launcher, but an ordinary EXIT must not tear it down prematurely.
trap - EXIT
wait "$openvt_pid"
vlock_result=$?
openvt_pid=""

log_message "vlock/openvt exited with status $vlock_result"

suspend_after_ns="$(boot_delta_ns)" || suspend_after_ns=""
if [[ "$suspend_after_ns" =~ ^-?[0-9]+$ ]]; then
    suspend_growth_ns=$((suspend_after_ns - suspend_before_ns))
    (( suspend_growth_ns >= 0 )) || suspend_growth_ns=0
    suspend_growth_ms=$((suspend_growth_ns / 1000000))
    log_message "Observed suspend-clock growth: ${suspend_growth_ms} ms"
else
    suspend_growth_ns=0
    log_message "Could not sample suspend clock after vlock exited"
fi

if (( suspend_result != 0 )); then
    exit "$suspend_result"
fi

if (( suspend_growth_ns < SUSPEND_CONFIRM_NS )); then
    log_message "No real suspend interval was detected; inspect the kernel journal for console-switch or suspend errors"
    exit 1
fi

# A completed authentication normally returns zero. Preserve unexpected
# failures in the system service status for diagnostics.
exit "$vlock_result"
HELPER
    } >"$file"

    chmod 0755 "$file"
    bash -n "$file"
}

stage_system_unit() {
    local file="${WORK_DIR}/${UNIT_NAME}"

    cat >"$file" <<EOF
$MANAGED_MARKER
[Unit]
Description=Lock all virtual consoles and suspend for ${USER_NAME}
Documentation=man:vlock(1) man:openvt(1)
After=systemd-logind.service
Wants=systemd-logind.service
[Service]
Type=oneshot
ExecStart=${ROOT_HELPER} ${USER_NAME} ${USER_UID}
TimeoutStartSec=infinity
TimeoutStopSec=3s
KillMode=control-group
StandardOutput=journal
StandardError=journal
EOF

    chmod 0644 "$file"
}

stage_sudoers_rule() {
    local file="${WORK_DIR}/$(basename "$SUDOERS_FILE")"

    cat >"$file" <<EOF
$MANAGED_MARKER
# Permit only ${USER_NAME} to start or stop only ${UNIT_NAME}, without authentication.
${USER_NAME} ALL=(root) NOPASSWD: ${SYSTEMCTL} start --no-block ${UNIT_NAME}
${USER_NAME} ALL=(root) NOPASSWD: ${SYSTEMCTL} stop ${UNIT_NAME}
EOF

    chmod 0440 "$file"
    "$VISUDO" -cf "$file" >/dev/null
}

install_root_files() {
    local sudoers_tmp="/etc/sudoers.d/.vlock-suspend-${USER_UID}.new.$$"

    sudo -v

    check_managed_or_absent "$ROOT_HELPER"
    check_managed_or_absent "$UNIT_FILE"
    check_sudoers_managed_or_absent

    sudo install -d -o root -g root -m 0755 /usr/local/libexec
    sudo install -o root -g root -m 0755 "${WORK_DIR}/vlock-suspend" "$ROOT_HELPER"
    sudo install -o root -g root -m 0644 "${WORK_DIR}/${UNIT_NAME}" "$UNIT_FILE"

    # Install through a dot-prefixed temporary name, validate it as root, then
    # atomically replace the active sudoers include.
    sudo rm -f -- "$sudoers_tmp"
    if ! sudo install -o root -g root -m 0440 \
        "${WORK_DIR}/$(basename "$SUDOERS_FILE")" "$sudoers_tmp"; then
        sudo rm -f -- "$sudoers_tmp"
        die "Could not stage the sudoers rule."
    fi
    if ! sudo "$VISUDO" -cf "$sudoers_tmp" >/dev/null; then
        sudo rm -f -- "$sudoers_tmp"
        die "The staged sudoers rule failed validation."
    fi
    sudo mv -f -- "$sudoers_tmp" "$SUDOERS_FILE"

    if command -v restorecon >/dev/null 2>&1; then
        sudo restorecon -F "$ROOT_HELPER" "$UNIT_FILE" "$SUDOERS_FILE" >/dev/null 2>&1 || true
    fi

    sudo "$VISUDO" -cf "$SUDOERS_FILE" >/dev/null
    sudo systemctl daemon-reload
}

install_shortcut_transaction() {
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"

    VLOCK_MEDIA_SCHEMA="$MEDIA_SCHEMA" \
    VLOCK_CUSTOM_SCHEMA="$CUSTOM_SCHEMA" \
    VLOCK_CUSTOM_PATH="$CUSTOM_PATH" \
    VLOCK_LEGACY_PATH_1="$LEGACY_CUSTOM_PATH_1" \
    VLOCK_LEGACY_WRAPPER="$LEGACY_WRAPPER" \
    VLOCK_COMMAND="$SHORTCUT_COMMAND" \
    VLOCK_BACKUP="$SCREENSAVER_BACKUP" \
    VLOCK_LEGACY_BACKUP="$LEGACY_SCREENSAVER_BACKUP" \
    "$PYTHON" - <<'PY'
import ast
import json
import os
import shlex
import stat
import tempfile
from gi.repository import Gio

MEDIA_SCHEMA = os.environ["VLOCK_MEDIA_SCHEMA"]
CUSTOM_SCHEMA = os.environ["VLOCK_CUSTOM_SCHEMA"]
CUSTOM_PATH = os.environ["VLOCK_CUSTOM_PATH"]
LEGACY_PATHS = {
    os.environ["VLOCK_LEGACY_PATH_1"],
}
LEGACY_WRAPPER = os.path.realpath(os.environ["VLOCK_LEGACY_WRAPPER"])
COMMAND = os.environ["VLOCK_COMMAND"]
BACKUP = os.environ["VLOCK_BACKUP"]
LEGACY_BACKUP = os.environ["VLOCK_LEGACY_BACKUP"]
TARGET = "<Super>l"
KEYS = ("name", "command", "binding")


def require_write(result, description):
    if not result:
        raise RuntimeError(f"failed to write {description}")


source = Gio.SettingsSchemaSource.get_default()
for schema_id in (MEDIA_SCHEMA, CUSTOM_SCHEMA):
    if source.lookup(schema_id, True) is None:
        raise RuntimeError(f"required schema is unavailable: {schema_id}")

media = Gio.Settings.new(MEDIA_SCHEMA)
if not media.is_writable("custom-keybindings"):
    raise RuntimeError("GNOME custom-keybindings setting is not writable")
if not media.is_writable("screensaver"):
    raise RuntimeError("GNOME screensaver binding is not writable")

original_paths = list(media.get_strv("custom-keybindings"))
original_screensaver_user_value = media.get_user_value("screensaver")
settings_cache = {}
snapshots = {}


def custom_settings(path):
    if path not in settings_cache:
        settings_cache[path] = Gio.Settings.new_with_path(CUSTOM_SCHEMA, path)
    return settings_cache[path]


def snapshot(path):
    settings = custom_settings(path)
    snapshots[path] = {key: settings.get_user_value(key) for key in KEYS}


def restore_snapshot(path):
    settings = custom_settings(path)
    for key, value in snapshots[path].items():
        if value is None:
            settings.reset(key)
        else:
            settings.set_value(key, value)


def normalize(binding):
    return "".join(binding.split()).casefold()


def is_recognized_legacy_wrapper(command):
    # The original manual setup can point GNOME at a per-user wrapper instead
    # of putting the systemctl command directly in dconf. Adopt only the exact
    # ~/.local/bin/vlock-console file, and only after verifying ownership,
    # permissions, size, and references to the known legacy runtime.
    try:
        argv = shlex.split(command, posix=True)
    except ValueError:
        return False

    if len(argv) != 1 or not os.path.isabs(argv[0]):
        return False

    candidate = os.path.realpath(argv[0])
    if candidate != LEGACY_WRAPPER:
        return False

    try:
        info = os.stat(candidate, follow_symlinks=True)
        if not stat.S_ISREG(info.st_mode):
            return False
        if info.st_uid != os.getuid():
            return False
        if info.st_mode & 0o022:
            return False
        if info.st_size > 32768:
            return False
        with open(candidate, "r", encoding="utf-8", errors="replace") as handle:
            content = handle.read(32769)
    except OSError:
        return False

    return (
        "vlock-console.service" in content
        or "vlock-suspend.service" in content
        or "vlock-and-suspend-root" in content
        or "vlock-console-root" in content
    )


def is_recognized_legacy_command(command):
    # GNOME may allocate arbitrary paths such as custom3/ when a shortcut is
    # created through Settings. Recognize both direct legacy commands and the
    # verified wrapper used by the earlier manual setup.
    return (
        "vlock-console.service" in command
        or "vlock-suspend.service" in command
        or "vlock-and-suspend-root" in command
        or "vlock-console-root" in command
        or is_recognized_legacy_wrapper(command)
    )

recognized_legacy = []
for path in original_paths:
    settings = custom_settings(path)
    binding = settings.get_string("binding")
    command = settings.get_string("command")
    targets_super_l = normalize(binding) == normalize(TARGET)
    app_specific_path = path in LEGACY_PATHS
    recognized_command = is_recognized_legacy_command(command)

    # Fixed paths owned by earlier versions are safe to clean even when stale
    # or empty. Arbitrary GNOME paths are adopted only when their command is a
    # verified legacy command/wrapper.
    if path != CUSTOM_PATH and (app_specific_path or recognized_command):
        recognized_legacy.append(path)
        continue

    if path != CUSTOM_PATH and targets_super_l:
        name = settings.get_string("name") or "unnamed shortcut"
        raise RuntimeError(
            f"Super+L is already assigned to custom shortcut '{name}' at {path}"
        )

for path in set([CUSTOM_PATH, *recognized_legacy]):
    snapshot(path)


def validated_binding_list(value):
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError("backup is not a string list")
    return value


def write_backup_if_missing():
    existing_backup_error = None

    if os.path.isfile(BACKUP) and os.path.getsize(BACKUP) > 0:
        try:
            with open(BACKUP, "r", encoding="utf-8") as handle:
                validated_binding_list(json.load(handle))
            return
        except Exception as error:
            # Attempt recovery from the legacy backup below. Never replace a
            # damaged backup with the currently disabled binding silently.
            existing_backup_error = error

    value = None
    if os.path.isfile(LEGACY_BACKUP) and os.path.getsize(LEGACY_BACKUP) > 0:
        try:
            with open(LEGACY_BACKUP, "r", encoding="utf-8") as handle:
                value = validated_binding_list(ast.literal_eval(handle.read().strip()))
        except Exception:
            value = None

    if value is None and existing_backup_error is not None:
        raise ValueError(f"existing screensaver backup is invalid: {existing_backup_error}")

    if value is None:
        current = list(media.get_strv("screensaver"))
        if recognized_legacy and not current:
            default_value = media.get_default_value("screensaver")
            value = list(default_value.unpack()) if default_value is not None else current
        else:
            value = current

    directory = os.path.dirname(BACKUP)
    descriptor, temporary = tempfile.mkstemp(prefix=".screensaver-binding.", dir=directory)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle)
            handle.write("\n")
        os.replace(temporary, BACKUP)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


write_backup_if_missing()

try:
    paths = [path for path in original_paths if path not in recognized_legacy]
    if CUSTOM_PATH not in paths:
        paths.append(CUSTOM_PATH)

    own = custom_settings(CUSTOM_PATH)
    for key in KEYS:
        if not own.is_writable(key):
            raise RuntimeError(f"GNOME custom shortcut key is not writable: {key}")

    require_write(own.set_string("name", "Lock and Suspend"), "shortcut name")
    require_write(own.set_string("command", COMMAND), "shortcut command")
    require_write(own.set_string("binding", TARGET), "shortcut binding")
    require_write(media.set_strv("custom-keybindings", paths), "custom-keybindings list")

    # Install the working replacement first, then release GNOME's built-in
    # binding. A failure rolls both settings back below.
    require_write(media.set_strv("screensaver", []), "built-in lock binding")

    for path in recognized_legacy:
        settings = custom_settings(path)
        for key in KEYS:
            settings.reset(key)

    Gio.Settings.sync()
except Exception:
    if original_screensaver_user_value is None:
        media.reset("screensaver")
    else:
        media.set_value("screensaver", original_screensaver_user_value)
    media.set_strv("custom-keybindings", original_paths)
    for path in snapshots:
        restore_snapshot(path)
    Gio.Settings.sync()
    raise
PY

}

remove_legacy_runtime_files() {
    local legacy_path

    for legacy_path in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/vlock-console.service" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/vlock-suspend.service"; do
        if [[ -f "$legacy_path" ]] && grep -Eq 'vlock' "$legacy_path"; then
            rm -f -- "$legacy_path"
        fi
    done

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user reset-failed vlock-console.service vlock-suspend.service 2>/dev/null || true

    for legacy_helper in \
        /usr/local/sbin/vlock-and-suspend-root \
        /usr/local/sbin/vlock-console-root; do
        if [[ -e "$legacy_helper" ]]; then
            sudo rm -f -- "$legacy_helper"
        fi
    done

    VLOCK_LEGACY_WRAPPER="$LEGACY_WRAPPER" \
    VLOCK_USER_UID="$USER_UID" \
    "$PYTHON" - <<'PY'
import os
import stat

path = os.environ["VLOCK_LEGACY_WRAPPER"]
uid = int(os.environ["VLOCK_USER_UID"])

try:
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise SystemExit(0)
    if info.st_uid != uid or info.st_mode & 0o022 or info.st_size > 32768:
        raise SystemExit(0)
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        content = handle.read(32769)
    if any(token in content for token in (
        "vlock-console.service",
        "vlock-suspend.service",
        "vlock-and-suspend-root",
        "vlock-console-root",
    )):
        os.unlink(path)
except FileNotFoundError:
    pass
PY
}

remove_legacy_policy_files() {
    local file

    for file in "${LEGACY_POLICY_FILES[@]}"; do
        if ! sudo test -e "$file"; then
            continue
        fi

        # Remove only rules that clearly refer to this service. This covers
        # older managed rules and the temporary diagnostic replacements used
        # while testing polkit, without deleting unrelated policy.
        if sudo grep -Fq "$MANAGED_MARKER" "$file" 2>/dev/null ||
           { sudo grep -Fq "$UNIT_NAME" "$file" 2>/dev/null &&
             sudo grep -Fq 'org.freedesktop.systemd1.manage-units' "$file" 2>/dev/null; }; then
            sudo rm -f -- "$file"
        else
            warn "Leaving unrecognized legacy policy file in place: $file"
        fi
    done

    file=/etc/polkit-1/rules.d/00-vlock-debug.rules
    if sudo test -e "$file" &&
       sudo grep -Fq 'VLOCK' "$file" 2>/dev/null &&
       sudo grep -Fq 'org.freedesktop.systemd1' "$file" 2>/dev/null; then
        sudo rm -f -- "$file"
    fi
}

sudoers_authorizes_start() {
    local systemctl_path=$1

    sudo -n -l -- \
        "$systemctl_path" start --no-block "$UNIT_NAME" \
        >/dev/null 2>&1
}

sudoers_authorizes_stop() {
    local systemctl_path=$1

    sudo -n -l -- \
        "$systemctl_path" stop "$UNIT_NAME" \
        >/dev/null 2>&1
}

install_all() {
    require_regular_desktop_user
    resolve_dependencies
    check_suspend_support
    check_system_lock_services_inactive
    check_legacy_unit_inactive
    make_work_dir

    stage_root_helper
    stage_system_unit
    stage_sudoers_rule
    install_root_files

    if ! sudoers_authorizes_start "$SYSTEMCTL"; then
        die "The installed sudoers rule does not authorize the exact service-start command. The existing shortcut was not changed."
    fi
    if ! sudoers_authorizes_stop "$SYSTEMCTL"; then
        die "The installed sudoers rule does not authorize the exact recovery stop command. The existing shortcut was not changed."
    fi

    if ! install_shortcut_transaction; then
        warn "GNOME shortcut installation failed. The system files remain installed but are not bound to Super+L."
        exit 1
    fi

    remove_legacy_runtime_files
    remove_legacy_policy_files

    cat <<EOF
Installed vlock-suspend ${SCRIPT_VERSION} for ${USER_NAME}.

Test it with:

    $(basename "$0") test

The expected sequence is:

    vlock console -> suspend -> resume to vlock -> password -> existing GNOME session

Runtime authorizes only the exact start and recovery-stop commands and does not open
an administrative authentication dialog.

Emergency recovery from SSH:

    ${SUDO} -n ${SYSTEMCTL} stop ${UNIT_NAME}

A physical keyboard is required at the vlock console. If PAM account lockout
prevents local authentication, use the SSH recovery command or reboot.
Device wakeup configuration is not modified.
EOF
}

restore_and_remove_shortcut_transaction() {
    VLOCK_MEDIA_SCHEMA="$MEDIA_SCHEMA" \
    VLOCK_CUSTOM_SCHEMA="$CUSTOM_SCHEMA" \
    VLOCK_CUSTOM_PATH="$CUSTOM_PATH" \
    VLOCK_LEGACY_PATH_1="$LEGACY_CUSTOM_PATH_1" \
    VLOCK_BACKUP="$SCREENSAVER_BACKUP" \
    VLOCK_LEGACY_BACKUP="$LEGACY_SCREENSAVER_BACKUP" \
    "$PYTHON" - <<'PY'
import ast
import json
import os
from gi.repository import Gio

MEDIA_SCHEMA = os.environ["VLOCK_MEDIA_SCHEMA"]
CUSTOM_SCHEMA = os.environ["VLOCK_CUSTOM_SCHEMA"]
CUSTOM_PATH = os.environ["VLOCK_CUSTOM_PATH"]
LEGACY_PATHS = {
    os.environ["VLOCK_LEGACY_PATH_1"],
}
BACKUP = os.environ["VLOCK_BACKUP"]
LEGACY_BACKUP = os.environ["VLOCK_LEGACY_BACKUP"]
KEYS = ("name", "command", "binding")


def require_write(result, description):
    if not result:
        raise RuntimeError(f"failed to write {description}")


media = Gio.Settings.new(MEDIA_SCHEMA)
if not media.is_writable("custom-keybindings"):
    raise RuntimeError("GNOME custom-keybindings setting is not writable")
if not media.is_writable("screensaver"):
    raise RuntimeError("GNOME screensaver binding is not writable")

original_paths = list(media.get_strv("custom-keybindings"))
original_screensaver_user_value = media.get_user_value("screensaver")
settings_cache = {}
snapshots = {}


def custom_settings(path):
    if path not in settings_cache:
        settings_cache[path] = Gio.Settings.new_with_path(CUSTOM_SCHEMA, path)
    return settings_cache[path]


def snapshot(path):
    settings = custom_settings(path)
    snapshots[path] = {key: settings.get_user_value(key) for key in KEYS}


def restore_snapshot(path):
    settings = custom_settings(path)
    for key, value in snapshots[path].items():
        if value is None:
            settings.reset(key)
        else:
            settings.set_value(key, value)


paths_to_remove = {CUSTOM_PATH, *LEGACY_PATHS}
for path in paths_to_remove:
    snapshot(path)

try:
    # Restore the built-in binding before removing the replacement, so a
    # partial failure does not leave the user without any Super+L action.
    restored = None
    backup_error = None

    if os.path.isfile(BACKUP) and os.path.getsize(BACKUP) > 0:
        try:
            with open(BACKUP, "r", encoding="utf-8") as handle:
                restored = json.load(handle)
        except Exception as error:
            backup_error = error

    if restored is None and os.path.isfile(LEGACY_BACKUP) and os.path.getsize(LEGACY_BACKUP) > 0:
        try:
            with open(LEGACY_BACKUP, "r", encoding="utf-8") as handle:
                restored = ast.literal_eval(handle.read().strip())
        except Exception as error:
            if backup_error is None:
                backup_error = error

    if restored is not None:
        if not isinstance(restored, list) or not all(isinstance(item, str) for item in restored):
            raise ValueError("invalid screensaver backup")
        require_write(media.set_strv("screensaver", restored), "restored built-in lock binding")
    elif backup_error is not None:
        raise ValueError(f"could not read screensaver backup: {backup_error}")
    else:
        media.reset("screensaver")

    require_write(
        media.set_strv(
            "custom-keybindings",
            [path for path in original_paths if path not in paths_to_remove],
        ),
        "custom-keybindings list",
    )

    for path in paths_to_remove:
        settings = custom_settings(path)
        for key in KEYS:
            settings.reset(key)

    Gio.Settings.sync()
except Exception:
    if original_screensaver_user_value is None:
        media.reset("screensaver")
    else:
        media.set_value("screensaver", original_screensaver_user_value)
    media.set_strv("custom-keybindings", original_paths)
    for path in snapshots:
        restore_snapshot(path)
    Gio.Settings.sync()
    raise
PY

    dconf reset -f "$CUSTOM_PATH"
    dconf reset -f "$LEGACY_CUSTOM_PATH_1" 2>/dev/null || true
}

check_target_unit_inactive() {
    local state

    state="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
    case "$state" in
        active|activating|deactivating)
            die "$UNIT_NAME is $state. Complete vlock authentication or use the documented SSH recovery command before uninstalling."
            ;;
    esac
}

remove_root_files() {
    remove_sudoers_file_if_recognized
    sudo rm -f -- "$UNIT_FILE"
    sudo systemctl daemon-reload
    sudo systemctl reset-failed "$UNIT_NAME" 2>/dev/null || true

    # Keep the shared helper if another user-specific unit still references it.
    if ! compgen -G '/etc/systemd/system/vlock-suspend-[0-9]*.service' >/dev/null; then
        sudo rm -f -- "$ROOT_HELPER"
    fi
}

uninstall_all() {
    require_regular_desktop_user
    resolve_uninstall_dependencies
    check_target_unit_inactive

    restore_and_remove_shortcut_transaction
    remove_root_files
    remove_legacy_runtime_files
    remove_legacy_policy_files
    rm -rf -- "$STATE_DIR"

    note "Removed vlock-suspend for $USER_NAME and restored the previous GNOME lock binding."
}

show_status() {
    local load_state active_state systemctl_path

    (( EUID != 0 )) ||
        die "Run status as the logged-in desktop user, not with sudo."

    systemctl_path="$(
        readlink -f -- \
            "$(command -v systemctl 2>/dev/null || printf '/usr/bin/systemctl')" \
            2>/dev/null ||
            printf '/usr/bin/systemctl'
    )"

    printf 'Version:             %s\n' "$SCRIPT_VERSION"
    printf 'Target user:         %s (UID %s)\n' "$USER_NAME" "$USER_UID"
    printf 'Root helper:         '
    [[ -x "$ROOT_HELPER" ]] && printf 'installed\n' || printf 'missing\n'
    printf 'System unit file:    '
    [[ -f "$UNIT_FILE" ]] && printf 'installed\n' || printf 'missing\n'
    printf 'Sudoers rule:        '
    if sudoers_authorizes_start "$systemctl_path" && sudoers_authorizes_stop "$systemctl_path"; then
        printf 'installed and authorized (start/stop)\n'
    elif [[ -f "$SUDOERS_FILE" ]] || sudo -n test -f "$SUDOERS_FILE" 2>/dev/null; then
        printf 'installed; authorization not verified\n'
    elif [[ -x "${SUDOERS_FILE%/*}" ]]; then
        printf 'missing\n'
    else
        printf 'unknown (root-only directory)\n'
    fi

    load_state="$(systemctl show "$UNIT_NAME" -p LoadState --value 2>/dev/null || true)"
    [[ -n "$load_state" ]] || load_state="unavailable"
    printf 'Unit load state:     %s\n' "$load_state"

    active_state="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
    [[ -n "$active_state" ]] || active_state="unavailable"
    printf 'Unit active state:   %s\n' "$active_state"

    if command -v gsettings >/dev/null 2>&1 &&
       gsettings list-schemas 2>/dev/null | grep -Fx "$MEDIA_SCHEMA" >/dev/null; then
        printf 'Built-in binding:    '
        gsettings get "$MEDIA_SCHEMA" screensaver 2>/dev/null || printf 'unavailable\n'
        printf 'Custom binding:      '
        gsettings get "$CUSTOM_SCHEMA:$CUSTOM_PATH" binding 2>/dev/null || printf 'unavailable\n'
        printf 'Custom command:      '
        gsettings get "$CUSTOM_SCHEMA:$CUSTOM_PATH" command 2>/dev/null || printf 'unavailable\n'
    else
        printf 'GNOME settings:      unavailable in this environment\n'
    fi
}

test_installation() {
    require_regular_desktop_user
    require_command systemctl
    require_command sudo
    SYSTEMCTL="$(resolve_command systemctl)"
    SUDO="$(resolve_command sudo)"

    [[ -x "$ROOT_HELPER" ]] || die "Root helper is not installed."
    [[ -f "$UNIT_FILE" ]] || die "System unit is not installed."

    note "Starting $UNIT_NAME. The display should switch to vlock and then suspend."
    note "After unlocking, run '$(basename "$0") logs' and confirm that a suspend-clock interval was observed."
    if ! "$SUDO" -n "$SYSTEMCTL" start --no-block "$UNIT_NAME"; then
        die "The exact passwordless sudo start command failed. Rerun install and inspect sudoers."
    fi
}

abort_installation() {
    (( EUID != 0 )) ||
        die "Run abort as the target desktop user, not with sudo."
    require_command systemctl
    require_command sudo
    SYSTEMCTL="$(resolve_command systemctl)"
    SUDO="$(resolve_command sudo)"

    note "Stopping $UNIT_NAME and releasing its service control group."
    if ! "$SUDO" -n "$SYSTEMCTL" stop "$UNIT_NAME"; then
        die "The exact passwordless sudo recovery-stop command failed."
    fi
}

show_logs() {
    (( EUID != 0 )) ||
        die "Run logs as the logged-in desktop user, not with sudo."
    require_command journalctl

    printf '%s\n' '--- system service ---'
    journalctl -b -u "$UNIT_NAME" --no-pager
    printf '%s\n' '--- helper messages ---'
    journalctl -b -t vlock-suspend --no-pager
    printf '%s\n' '--- kernel suspend/console diagnostics ---'
    journalctl -b -k --no-pager |
        grep -E 'Console-switch failed|PM: suspend|PM: resume|suspend entry|suspend exit' ||
        true
}

case "${1:-install}" in
    install) install_all ;;
    uninstall) uninstall_all ;;
    status) show_status ;;
    test) test_installation ;;
    abort) abort_installation ;;
    logs) show_logs ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
