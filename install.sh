#!/bin/sh
# srt installer. Interactive by default; flags make it unattended.
#
#   sh install.sh                        guided: detects the system, asks questions
#   sh install.sh -y --vps 1.2.3.4       no questions, defaults plus the given VPS
#   sh install.sh --no-tunnel            install srt only; add tunnels later: srt add
#   sh install.sh --uninstall            remove srt, services and all tunnels
#
# Detects the native package format and architecture:
#   deb (apt), rpm (dnf/yum/zypper), apk (Alpine, OpenWrt 24+), ipk (OpenWrt opkg),
#   pacman (Arch), brew (macOS). Installs ssh and python3 with that manager.
set -eu

# Bootstrap for "curl ... | sh": there is no checkout next to the script, so fetch
# the source archive into a temp dir and run its installer. Set SRT_ARCHIVE_URL to
# override the source (used by tests).
SRT_REPO="${SRT_REPO:-vkust/ssh-reverse-tunnel}"
SRT_ARCHIVE_URL="${SRT_ARCHIVE_URL:-https://codeload.github.com/$SRT_REPO/tar.gz/refs/heads/${SRT_BRANCH:-main}}"

_script_dir() {
    case "$0" in
        */*) (cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
        *) pwd ;;
    esac
}
HERE="$(_script_dir)"

if [ ! -f "$HERE/srt" ] || [ ! -f "$HERE/scripts/proxy_connect.py" ]; then
    command -v tar >/dev/null 2>&1 || { echo "xx  tar is required" >&2; exit 1; }
    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/srt-install.XXXXXX")" || exit 1
    echo "==> downloading $SRT_ARCHIVE_URL"
    case "$SRT_ARCHIVE_URL" in
        file://*) cp "${SRT_ARCHIVE_URL#file://}" "$_tmp/src.tgz" ;;
        *)
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL "$SRT_ARCHIVE_URL" -o "$_tmp/src.tgz"
            elif command -v wget >/dev/null 2>&1; then
                wget -qO "$_tmp/src.tgz" "$SRT_ARCHIVE_URL"
            else
                echo "xx  need curl or wget to download the source" >&2; exit 1
            fi ;;
    esac
    tar -xzf "$_tmp/src.tgz" -C "$_tmp"
    _src="$(find "$_tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -f "$_src/install.sh" ] || { echo "xx  archive has no install.sh" >&2; exit 1; }
    # the wizard reads answers from the terminal, not from the piped script
    if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then
        exec sh "$_src/install.sh" "$@" </dev/tty
    fi
    exec sh "$_src/install.sh" "$@"
fi

ASSUME_YES=0
DO_TUNNEL=1
UNINSTALL=0
PREFIX=""
VPS_OPT=""

info() { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sh install.sh [options]

  -y, --yes         no questions; defaults and the flags below
  --vps HOST        VPS address (needed with -y when adding a tunnel)
  --no-tunnel       install srt only; add tunnels later with: srt add
  --prefix DIR      where the srt binary goes (default: /usr/local/bin as root, else ~/.local/bin)
  --uninstall       remove srt, its services, all tunnels and the installed files
  -h, --help        this help

Other settings (proxy, ports, target host, user) are asked by the wizard, or
pass them to 'srt add' with the same flags, e.g.:
  sh install.sh -y --vps 192.0.2.10 --vps-user root --proxy proxy.example.com:3128
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --vps)    [ $# -ge 2 ] || die "--vps needs a value"; VPS_OPT="$2"; shift ;;
        --no-tunnel) DO_TUNNEL=0 ;;
        --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX="$2"; shift ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

is_root() { [ "$(id -u)" = 0 ]; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- detection ----------

detect() {
    OS_KERNEL="$(uname -s)"
    OS_NAME="$OS_KERNEL"
    PKG_FORMAT=none
    PKG_CMD=""
    PKG_ARCH="$(uname -m)"

    case "$OS_KERNEL" in
        Linux)
            if [ -f /etc/openwrt_release ]; then
                OS_NAME="$(. /etc/openwrt_release; echo "${DISTRIB_DESCRIPTION:-OpenWrt}")"
                if have apk; then PKG_FORMAT=apk; PKG_CMD=apk
                elif have opkg; then
                    PKG_FORMAT=ipk; PKG_CMD=opkg
                    PKG_ARCH="$(opkg print-architecture 2>/dev/null | awk '$1=="arch"{a=$2} END{print a}')"
                fi
            else
                OS_NAME="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
                for m in apt-get:deb dnf:rpm yum:rpm zypper:rpm pacman:pacman apk:apk; do
                    c="${m%%:*}"; f="${m##*:}"
                    if have "$c"; then PKG_FORMAT="$f"; PKG_CMD="$c"; break; fi
                done
                if [ "$PKG_FORMAT" = deb ] && have dpkg; then PKG_ARCH="$(dpkg --print-architecture)"; fi
            fi
            if grep -qi microsoft /proc/version 2>/dev/null; then OS_NAME="$OS_NAME (WSL)"; fi
            ;;
        Darwin)
            OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || true)"
            if have brew; then PKG_FORMAT=brew; PKG_CMD=brew; fi
            ;;
        *) die "unsupported system: $OS_KERNEL (Linux, macOS or OpenWrt)" ;;
    esac

    if [ -z "$PREFIX" ]; then
        if is_root && [ "$PKG_FORMAT" != brew ]; then PREFIX=/usr/local/bin
        else PREFIX="$HOME/.local/bin"; fi
    fi

    SUDO=""
    if [ "$PKG_FORMAT" != brew ] && ! is_root && have sudo; then SUDO="sudo"; fi

    if is_root && [ "$PKG_FORMAT" != brew ]; then SHARE_DIR=/usr/local/share/srt
    else SHARE_DIR="$HOME/.local/share/srt"; fi
}

print_platform() {
    info "system:     $OS_NAME"
    info "package:    $PKG_FORMAT ${PKG_CMD:+($PKG_CMD) }arch=$PKG_ARCH"
    info "install to: $PREFIX/srt  (helper: $SHARE_DIR/proxy_connect.py)"
}

# ---------- dependencies ----------

pkg_install() {
    [ "$PKG_FORMAT" = none ] && die "no supported package manager found; install ssh and python3 manually"
    case "$PKG_FORMAT" in
        deb)    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
                $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        rpm)    if have dnf; then $SUDO dnf install -y -q "$@"; else $SUDO yum install -y -q "$@"; fi ;;
        pacman) $SUDO pacman -S --noconfirm --needed "$@" ;;
        apk)    $SUDO apk add --no-cache "$@" ;;
        ipk)    opkg update >/dev/null 2>&1 || true; opkg install "$@" ;;
        brew)   brew install "$@" ;;
    esac
}

# The only place where package names differ per format.
dep_pkg() { # dep_pkg ssh|python -> native package name
    case "$1:$PKG_FORMAT" in
        ssh:rpm) echo openssh-clients ;;
        ssh:pacman) echo openssh ;;
        ssh:*) echo openssh-client ;;
        python:ipk) echo python3-light ;;
        python:*) echo python3 ;;
    esac
}

install_deps() {
    missing=""
    { have ssh && have ssh-keygen; } || missing="$missing ssh"
    have python3 || missing="$missing python"
    if [ -z "$missing" ]; then info "dependencies present: ssh, ssh-keygen, python3"; return 0; fi
    pkgs=""
    for d in $missing; do pkgs="$pkgs $(dep_pkg "$d")"; done
    info "installing:$pkgs"
    # shellcheck disable=SC2086
    pkg_install $pkgs
    { have ssh && have ssh-keygen; } || die "ssh still missing after install"
    have python3 || warn "python3 missing: proxy mode falls back to 'nc -X connect' (no proxy login)"
}

# ---------- files ----------

install_files() {
    mkdir -p "$PREFIX" "$SHARE_DIR"
    cp "$HERE/scripts/proxy_connect.py" "$SHARE_DIR/proxy_connect.py"
    chmod 644 "$SHARE_DIR/proxy_connect.py"

    # Bake the helper location into the installed copy of srt.
    _tmp="$PREFIX/srt.new.$$"
    sed "s|^SRT_SHARE_BAKED=.*|SRT_SHARE_BAKED='$SHARE_DIR'|" "$HERE/srt" > "$_tmp"
    grep -q "^SRT_SHARE_BAKED='$SHARE_DIR'" "$_tmp" || { rm -f "$_tmp"; die "failed to set helper path in srt"; }
    chmod 755 "$_tmp"
    mv "$_tmp" "$PREFIX/srt"
    info "installed $PREFIX/srt"

    case ":$PATH:" in
        *":$PREFIX:"*) ;;
        *) warn "$PREFIX is not in PATH. Add it: export PATH=\"$PREFIX:\$PATH\"" ;;
    esac
}

# ---------- uninstall ----------

do_uninstall() {
    detect
    if [ -x "$PREFIX/srt" ]; then
        "$PREFIX/srt" uninstall || true
        rm -f "$PREFIX/srt"
        info "removed $PREFIX/srt"
    else
        warn "no srt in $PREFIX"
    fi
    for d in /usr/local/share/srt "$HOME/.local/share/srt"; do
        if [ -d "$d" ]; then rm -rf "$d"; info "removed $d"; fi
    done
    info "done. SSH keys (srt_*) in ~/.ssh were kept; delete them manually if unused."
}

# ---------- main ----------

if [ "$UNINSTALL" = 1 ]; then do_uninstall; exit 0; fi

[ -f "$HERE/srt" ] && [ -f "$HERE/scripts/proxy_connect.py" ] \
    || die "run install.sh from the repository checkout (needs srt and scripts/)"

detect
print_platform

if [ "$ASSUME_YES" = 0 ]; then
    printf 'Continue? [Y/n]: '
    _a=""; IFS= read -r _a || _a=""
    case "${_a:-y}" in y|Y|yes|Yes) ;; *) die "aborted" ;; esac
fi

install_deps
install_files

if [ "$DO_TUNNEL" = 1 ]; then
    echo
    info "add your first tunnel (the wizard asks the rest)"
    if [ "$ASSUME_YES" = 1 ]; then
        [ -n "$VPS_OPT" ] || die "-y needs --vps HOST to add a tunnel (or use --no-tunnel)"
        "$PREFIX/srt" add -y --vps "$VPS_OPT"
    else
        "$PREFIX/srt" add ${VPS_OPT:+--vps "$VPS_OPT"}
    fi
else
    info "srt installed. Add tunnels with: srt add"
fi
