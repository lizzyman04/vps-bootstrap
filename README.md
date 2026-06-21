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

## Easiest path: just bought a VPS?

Run `connect.sh` **from your own machine**. You enter the server IP, type the
root password once **at SSH's own prompt**, and the server gets fully
configured — no cloning, no copy-pasting commands on the server.

```bash
curl -fsSL https://raw.githubusercontent.com/lizzyman04/vps-bootstrap/main/connect.sh | bash
```

It asks for the server IP, the SSH username (default `root`), and optionally a
local SSH **public** key to install for the new admin user. Then it opens an
SSH session and runs `setup.sh` on the server for you.

> **About the password:** `connect.sh` **never reads, stores, passes, or echoes
> your server password.** There is no `sshpass` and no `expect`. You type the
> password exactly once, at OpenSSH's own native prompt — the password is
> handled entirely by SSH and never touches these scripts. (`connect.sh` runs
> `ssh -t … 'curl … | sudo bash'`; the `-t` keeps the session interactive so
> both the SSH password prompt and the `setup.sh` wizard work normally.)

Don't have an SSH key yet? Generate one first:

```bash
ssh-keygen -t ed25519
```

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

You can run it straight from GitHub — no clone required.

### Recommended: download, then run

Download the script, **read it**, then run it. This is the safest path and the
interactive wizard works reliably:

```bash
curl -fsSL https://raw.githubusercontent.com/lizzyman04/vps-bootstrap/main/setup.sh -o setup.sh
sudo bash setup.sh
```

### One-liner (pipe)

```bash
curl -fsSL https://raw.githubusercontent.com/lizzyman04/vps-bootstrap/main/setup.sh | sudo bash
```

The wizard still works when piped — every prompt reads from `/dev/tty`, so the
pipe consuming stdin doesn't break interactivity.

> **Security note:** never pipe a script from the internet straight into a root
> shell without reading it first. Download it, skim what it does, *then* run it
> as root. The recommended two-step above lets you do exactly that.

### Interactive first-run wizard

With no flags, the script walks you through every setting one at a time, showing
a sensible `[default]` in brackets — admin user, SSH key (paste the key or give
a path to a `.pub` file), SSH port, password/root-login hardening, fail2ban,
firewall, Docker, system upgrade, extra ports, and a fail2ban exempt IP. It then
prints a summary of your choices and asks for one final confirmation before
changing anything.

### Non-interactive (power users)

Pass `--yes` to skip the wizard and drive everything from flags/defaults. Any
flag also overrides its matching prompt, so you can mix flags with the wizard:

```bash
sudo bash setup.sh \
  --user lizzyman04 \
  --ssh-key-file ~/.ssh/id_ed25519.pub \
  --extra-ports "80,443" \
  --with-docker \
  --yes
```

Run `sudo bash setup.sh --help` for all options.

### After it finishes

**Before logging out**, open a new terminal and confirm:

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
