#!/bin/sh
# uninstall.sh: remove srt completely, with or without a working srt binary.
#
#   sh uninstall.sh                 show the plan, ask, then remove
#   sh uninstall.sh -y              no questions
#   sh uninstall.sh --dry-run       print what would be removed, change nothing
#   sh uninstall.sh --purge-keys    also delete the SSH keys used by the tunnels
#   curl -fsSL https://raw.githubusercontent.com/vkust/ssh-reverse-tunnel/main/uninstall.sh | sh
#
# Removes: tunnel services (systemd user, launchd, procd, pid-file fallback), the srt
# binary, its helper, tunnel configs, and leftovers of the first ssh-reverse-tunnel version.
# Keeps: SSH keys (unless --purge-keys), ~/.ssh/known_hosts, anything on the VPS.
set -eu

ASSUME_YES=0
DRY_RUN=0
PURGE_KEYS=0

info() { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --purge-keys) PURGE_KEYS=1 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

have() { command -v "$1" >/dev/null 2>&1; }

CONF_DIR="${SRT_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/srt}"
TUN_DIR="$CONF_DIR/tunnels"
RUN_DIR="$CONF_DIR/run"
LEGACY_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ssh-reverse-tunnel"
USER_UNIT_DIR="$HOME/.config/systemd/user"

# Refuse to remove something that is obviously not ours.
guard_path() {
    case "$1" in
        ""|/|"$HOME"|"$HOME/"|/usr|/usr/local|/usr/local/bin|/etc) die "refusing to remove '$1'" ;;
    esac
}

# Everything we plan to do is collected here first, then printed or executed.
PLAN=""
add() { PLAN="$PLAN
$1"; }

# ---------- collect ----------

collect_services() {
    if [ -d "$TUN_DIR" ]; then
        for f in "$TUN_DIR"/*.conf; do
            [ -f "$f" ] || continue
            n="$(basename "$f" .conf)"
            add "tunnel service: $n"
            add "tunnel config:  $f"
        done
    fi

    if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
        for u in $(systemctl --user list-unit-files --no-legend 'srt@*.service' 2>/dev/null | awk '{print $1}'); do
            add "systemd unit:   $u"
        done
        for u in $(systemctl --user list-unit-files --no-legend 'ssh-reverse-tunnel*.service' 2>/dev/null | awk '{print $1}'); do
            add "legacy unit:    $u"
        done
    fi
    if [ -f "$USER_UNIT_DIR/srt@.service" ]; then add "unit file:      $USER_UNIT_DIR/srt@.service"; fi
    if [ -f "$USER_UNIT_DIR/ssh-reverse-tunnel.service" ]; then add "legacy unit file: $USER_UNIT_DIR/ssh-reverse-tunnel.service"; fi

    if [ "$(uname -s)" = Darwin ]; then
        for p in "$HOME/Library/LaunchAgents"/com.srt.*.plist "$HOME/Library/LaunchAgents/com.ssh-reverse-tunnel.plist"; do
            if [ -f "$p" ]; then add "launchd agent:  $p"; fi
        done
    fi

    if [ -f /etc/init.d/srt ]; then add "procd init:    /etc/init.d/srt"; fi

    if [ -d "$RUN_DIR" ]; then
        for p in "$RUN_DIR"/*.pid; do
            if [ -f "$p" ]; then add "pid file:      $p"; fi
        done
    fi
}

collect_legacy() {
    for f in "$HOME/.local/bin/ssh-reverse-tunnel-run" "$HOME/.local/bin/proxy_connect.py"; do
        if [ -e "$f" ]; then add "legacy file:    $f"; fi
    done
    if [ -d "$LEGACY_CONF" ]; then add "legacy config:  $LEGACY_CONF"; fi
    if [ -f "$HOME/Library/Logs/ssh-reverse-tunnel.log" ]; then add "legacy log:     $HOME/Library/Logs/ssh-reverse-tunnel.log"; fi
}

collect_binaries() {
    for d in "$HOME/.local/bin" /usr/local/bin "$HOME/bin"; do
        if [ -f "$d/srt" ]; then add "binary:          $d/srt"; fi
    done
    for d in "$HOME/.local/share/srt" /usr/local/share/srt; do
        if [ -d "$d" ]; then add "helper dir:     $d"; fi
    done
    if [ -d "$CONF_DIR" ]; then add "config dir:     $CONF_DIR"; fi
}

# Keys referenced by tunnel configs, plus the known key names of the old version.
# Without --purge-keys they are only listed; with it they are deleted.
KEY_LIST=""
collect_keys() {
    if [ -d "$TUN_DIR" ]; then
        for f in "$TUN_DIR"/*.conf; do
            [ -f "$f" ] || continue
            k="$(sed -n "s/^KEY_FILE='\(.*\)'$/\1/p" "$f")"
            if [ -n "$k" ]; then KEY_LIST="$KEY_LIST
$k"; fi
        done
    fi
    for k in "$HOME/.ssh"/srt_* "$HOME/.ssh/ssh_reverse_tunnel" "$HOME/.ssh/vps_tunnel"; do
        if [ -f "$k" ]; then KEY_LIST="$KEY_LIST
$k"; fi
    done
    # plain for-loop: a pipe into while would run add() in a subshell and lose the plan
    SORTED_KEYS="$(printf '%s\n' "$KEY_LIST" | sed '/^$/d' | sort -u)"
    for k in $SORTED_KEYS; do
        case "$k" in *.pub) continue ;; esac
        for f in "$k" "$k.pub"; do
            [ -f "$f" ] || continue
            if [ "$PURGE_KEYS" = 1 ]; then add "ssh key (purge): $f"
            else add "ssh key (kept):  $f"; fi
        done
    done
}

# ---------- act ----------

run() { # run COMMAND... : execute unless dry-run; failures are reported, not fatal
    if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; return 0; fi
    "$@" || warn "failed: $*"
}

do_services() {
    if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
        for u in $(systemctl --user list-unit-files --no-legend 'srt@*.service' 'ssh-reverse-tunnel*.service' 2>/dev/null | awk '{print $1}'); do
            run systemctl --user disable --now "$u"
        done
        run systemctl --user reset-failed
    fi

    if [ -d "$TUN_DIR" ]; then
        for f in "$TUN_DIR"/*.conf; do
            [ -f "$f" ] || continue
            n="$(basename "$f" .conf)"
            if [ "$(uname -s)" = Darwin ]; then
                run launchctl bootout "gui/$(id -u)/com.srt.$n"
            fi
        done
    fi
    if [ "$(uname -s)" = Darwin ]; then
        run launchctl bootout "gui/$(id -u)/com.ssh-reverse-tunnel"
    fi

    if [ -d "$RUN_DIR" ]; then
        for p in "$RUN_DIR"/*.pid; do
            [ -f "$p" ] || continue
            pid="$(cat "$p" 2>/dev/null || true)"
            case "$pid" in ''|*[!0-9]*) ;; *) run kill "$pid" ;; esac
        done
    fi

    if [ -f /etc/init.d/srt ]; then { run /etc/init.d/srt stop; run /etc/init.d/srt disable; }; fi
}

do_files() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "$PLAN" | sed '/^$/d' | while IFS= read -r line; do
            case "$line" in
                *"unit file"*|*"launchd agent"*|*"procd init"*|*"binary"*|*"helper dir"*|*"config dir"*|*"legacy"*|*"ssh key"*|*"pid file"*|*"tunnel config"*)
                    printf '    [dry-run] %s\n' "${line#*: }" ;;
            esac
        done
        return 0
    fi

    rm -f "$USER_UNIT_DIR/srt@.service" "$USER_UNIT_DIR/ssh-reverse-tunnel.service"
    rm -f "$USER_UNIT_DIR/default.target.wants/ssh-reverse-tunnel.service"
    rm -f "$USER_UNIT_DIR"/default.target.wants/srt@*.service
    have systemctl && systemctl --user daemon-reload >/dev/null 2>&1 || true

    if [ "$(uname -s)" = Darwin ]; then
        rm -f "$HOME/Library/LaunchAgents"/com.srt.*.plist "$HOME/Library/LaunchAgents/com.ssh-reverse-tunnel.plist"
        rm -f "$HOME/Library/Logs/ssh-reverse-tunnel.log"
    fi
    if [ -f /etc/init.d/srt ]; then rm -f /etc/init.d/srt || true; fi

    for f in "$HOME/.local/bin/srt" /usr/local/bin/srt "$HOME/bin/srt"; do
        if [ -f "$f" ]; then grep -q "srt" "$f" 2>/dev/null && rm -f "$f"; fi
    done
    rm -f "$HOME/.local/bin/ssh-reverse-tunnel-run" "$HOME/.local/bin/proxy_connect.py"

    guard_path "$CONF_DIR"; rm -rf "$CONF_DIR"
    guard_path "$LEGACY_CONF"; rm -rf "$LEGACY_CONF"
    rm -rf "$HOME/.local/share/srt"
    rm -rf /usr/local/share/srt 2>/dev/null || true
}

do_keys() { # delete the key files the plan marked for purge (only with --purge-keys)
    [ "$PURGE_KEYS" = 1 ] || return 0
    _purge_list="$(printf '%s\n' "$PLAN" | sed -n 's/^ssh key (purge): *//p')"
    for f in $_purge_list; do
        run rm -f "$f"
    done
}

# ---------- main ----------

collect_services
collect_legacy
collect_binaries
collect_keys

if [ -z "$PLAN" ]; then
    info "nothing to remove: no srt or ssh-reverse-tunnel files found"
    exit 0
fi

info "будет удалено (dry-run: ничего не меняется):" 
echo "$PLAN" | sed '/^$/d' | sed 's/^/    /'
echo
info "не трогается: ssh-ключи (кроме --purge-keys), ~/.ssh/known_hosts, файлы на VPS (authorized_keys, sshd_config)"

if [ "$DRY_RUN" = 1 ]; then
    info "dry-run: ничего не удалено"
    exit 0
fi

if [ "$ASSUME_YES" = 0 ]; then
    printf 'Продолжить? [y/N]: '
    _a=""; IFS= read -r _a || _a=""
    case "$_a" in y|Y|yes|Yes) ;; *) info "отменено"; exit 0 ;; esac
fi

info "остановка сервисов"
do_services
info "удаление файлов"
do_files
do_keys

info "готово. Проверка: systemctl --user list-unit-files | grep -i srt  (должно быть пусто)"
