**English** | **[Русский](README.ru.md)**

---

# srt: reverse SSH tunnels to a VPS

`srt` opens tunnels **from a machine that has no inbound access** (behind NAT or a
CONNECT-only proxy) **to a VPS**, so the machine can be reached from anywhere through
the VPS. The machine opens the tunnel itself; nothing else in the path has to run.

```
 you ──ssh -p 2222──▶ VPS:2222 ══ reverse tunnel ══▶ this machine ─┬─▶ 127.0.0.1:22        (itself)
                                 (opened by srt)                   └─▶ 10.0.0.5:80         (LAN host)
```

- One machine can run several tunnels: to different VPS hosts, to different ports, and to
  other hosts in the local network, not only to itself.
- Outbound SSH can go through an HTTP CONNECT proxy (e.g. one that intercepts TLS).
- Each tunnel is a separate service that restarts itself and survives reboots (see Linux note).

## Install

One line (needs `curl` or `wget`, and `sudo` for system packages when not root):

```sh
curl -fsSL https://raw.githubusercontent.com/vkust/ssh-reverse-tunnel/main/install.sh | sh
```

No `curl`? Use `wget -qO- https://raw.githubusercontent.com/vkust/ssh-reverse-tunnel/main/install.sh | sh`.

The installer downloads the source, detects the system, installs ssh and python3, and starts the wizard for the first tunnel. Your answers are read from the terminal, so the pipe does not stop the questions.

From a checkout:
```sh
git clone https://github.com/vkust/ssh-reverse-tunnel && cd ssh-reverse-tunnel
sh install.sh            # guided
```

Unattended:
```sh
curl -fsSL https://raw.githubusercontent.com/vkust/ssh-reverse-tunnel/main/install.sh | sh -s -- -y --vps 192.0.2.10 --proxy proxy.example.com:3128
```

`install.sh` detects the package format and architecture and uses the matching manager:

| Format | Systems | Package manager |
|---|---|---|
| deb | Debian, Ubuntu | apt-get |
| rpm | Fedora, RHEL, openSUSE | dnf / yum / zypper |
| pacman | Arch | pacman |
| apk | Alpine, OpenWrt 24+ | apk |
| ipk | OpenWrt (opkg) | opkg |
| brew | macOS | Homebrew |

Check what it sees: `srt platform`.

Native Windows is not a target. Run `srt` in WSL2 or on the machine that actually holds the connection.

## Manage tunnels

```sh
srt add                         # wizard: name, VPS, proxy, target host:port, VPS port, key
srt add --name nas --vps 192.0.2.10 --target 10.0.0.5 --target-port 80 --remote-port 8080 -y
srt list                        # all tunnels with status
srt show nas
srt check [nas|all]             # VPS login via key, port listening on VPS, service state
srt restart nas                 # start | stop | restart | status  [NAME|all]
srt logs nas -f
srt key nas                     # public key to install on the VPS
srt remove nas [--purge-key]
srt uninstall                   # remove all tunnels and services
```

Each tunnel is stored as `~/.config/srt/tunnels/NAME.conf`. The name is the handle for
all commands. A VPS port can be used by one tunnel only; `srt add` refuses a clash.

### What the target means

- `--target 127.0.0.1` (default): this machine's own port, e.g. sshd on 22.
- `--target 10.0.0.5`: a host of the local network reachable from this machine. Traffic
  goes VPS → tunnel → this machine → that host. The LAN host does not need to know about the tunnel.

## VPS side

Run once on the VPS as root:
```sh
sudo srt setup-vps
```
This sets `GatewayPorts clientspecified` (so tunnels can bind on a public address), tests
sshd, and restarts it. Open the tunnel ports in your firewall (`ufw allow 2222/tcp`).
The VPS needs `srt` only if you want the command; the tunnel works without it.

## Key and access

- `srt add` generates a passwordless ed25519 key per VPS host (`~/.ssh/srt_<host>`), because services start unattended.
- If key login fails, `srt add` offers `ssh-copy-id` once.
- **Anyone who can reach `VPS:PORT` gets an sshd login prompt on the target.** Keep password
  auth off on the target, and restrict the port to known addresses on the VPS firewall.

## Linux note: start at boot

Tunnels are systemd user services (`srt@NAME.service`). Without linger they stop at logout
and do not start at boot. `srt add` prints the command when linger is off:
```sh
sudo loginctl enable-linger $USER
```

## Layout

| Path | Purpose |
|---|---|
| `install.sh` | installer: detection, dependencies, install, first tunnel |
| `srt` | the tool (POSIX sh): tunnels, services, checks |
| `scripts/proxy_connect.py` | ProxyCommand helper for HTTP CONNECT proxies (stdlib only) |
| `tests/` | unit tests for the proxy helper |
| `.github/workflows/ci.yml` | unit tests, shellcheck, install → add → remove → uninstall |

## Troubleshooting

- `Permission denied (publickey)`: `srt key NAME`, install that key on the VPS for the tunnel's user.
- `remote port forwarding failed`: `GatewayPorts` is off on the VPS (`sudo srt setup-vps`) or the port is taken.
- `proxy refused CONNECT`: the proxy does not allow that destination port. Probe it: `curl -x http://PROXY -v telnet://HOST:22`.
- `srt check` says the VPS listens but the tunnel is not running: another tunnel or process owns that port.

## Uninstall

```sh
srt uninstall && sh install.sh --uninstall
```
Keys in `~/.ssh/srt_*` are kept; delete them if unused.

## License

MIT, see LICENSE.
