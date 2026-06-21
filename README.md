# vps-setup

A single-command Bash script to execute common setup and hardening tasks on a
newly created VPS. Multi-distro (Debian/Ubuntu and RHEL/Rocky/Alma/Fedora).

## What it does

In one run, the script:

- Updates the system and installs base tools.
- Creates an administrator (sudo) user.
- Installs your SSH public key for that user.
- Configures a firewall (`ufw` or `firewalld`), opening only the ports you need.
- Hardens SSH: key-only authentication, no direct root login.
- Installs and configures `fail2ban` to protect SSH from brute-force attempts.
- Optionally installs Docker Engine.

## Why the defensive design

This script was written after a real setup that hit every common foot-gun.
It encodes those lessons so you don't repeat them:

- **No IPv6-only lockout.** If you change the SSH port and the system uses
  `ssh.socket`, the script binds the port on **both** `0.0.0.0` and `[::]`
  explicitly. A bare `ListenStream=PORT` can silently become IPv6-only and
  lock out IPv4 clients.
- **No mid-setup self-ban.** `fail2ban`'s `ignoreip` (loopback, plus an
  optional admin IP) is written **before** the jail goes active.
- **No bricked SSH.** The SSH config is validated with `sshd -t` **before**
  any restart. A bad config aborts instead of cutting your access.
- **No password lockout.** The SSH key is installed **before** password auth
  is disabled, and the script refuses to disable passwords if no key is
  present.
- **Cloud-init override handled.** Many cloud images ship a
  `50-cloud-init.conf` that re-enables password auth and wins over later
  drop-ins; the script neutralizes it.

## Usage

```bash
sudo ./vps-setup.sh \
  --user lizzyman04 \
  --ssh-key-file ~/.ssh/id_ed25519.pub \
  --extra-ports "80,443" \
  --with-docker \
  --yes
```

Run `sudo ./vps-setup.sh --help` for all options.

### Recommended first run (interactive, safest)

```bash
sudo ./vps-setup.sh --user NAME --ssh-key "ssh-ed25519 AAAA... you@host"
```

Then, **before logging out**, open a new terminal and confirm:

```bash
ssh NAME@<server-ip>
```

If it works, you're done. If not, fix it from your still-open session or the
provider's VNC/serial console.

## Options

| Flag | Description |
|------|-------------|
| `--user NAME` | Admin (sudo) user to create. **Required.** |
| `--ssh-key "KEY"` | Public SSH key to install. |
| `--ssh-key-file PATH` | Read the public key from a file. |
| `--ssh-port N` | SSH port (default: 22). |
| `--extra-ports "80,443"` | Extra TCP ports to open. |
| `--ignore-ip CIDR` | IP/CIDR exempt from fail2ban. |
| `--no-disable-password` | Keep password auth (not recommended). |
| `--no-disable-root` | Keep direct root SSH login. |
| `--no-fail2ban` | Skip fail2ban. |
| `--no-firewall` | Skip firewall. |
| `--no-upgrade` | Skip the system package upgrade. |
| `--with-docker` | Install Docker Engine. |
| `--yes` | Non-interactive (assume yes). |

## Safety notes

- Set a strong sudo password for the admin user afterwards:
  `sudo passwd NAME`. Avoid dates or anything guessable.
- Back up your private SSH key. With password auth disabled, that key is your
  only way in.
- Test in a throwaway VPS before trusting it on something important.

## License

MIT
