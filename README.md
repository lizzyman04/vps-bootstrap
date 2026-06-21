<div align="center">

# 🛡️ VPS Bootstrap

**Turn a freshly-bought VPS into a hardened, ready-to-use server — in one command.**

Creates an admin user, installs your SSH key, locks SSH down to key-only,
configures a firewall and `fail2ban`, and updates the system — safely, with
every common foot-gun already handled.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg?logo=gnu-bash&logoColor=white)](setup.sh)
![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20RHEL%20%7C%20Rocky%20%7C%20Alma%20%7C%20Fedora-orange.svg)
![Idempotent](https://img.shields.io/badge/Idempotent-yes-success.svg)

</div>

---

## ✨ What it does

In a single run, the script:

| | Step |
|---|---|
| 📦 | Updates the system and installs base tools |
| 👤 | Creates an administrator (`sudo`) user |
| 🔑 | Installs your SSH **public** key for that user |
| 🔒 | Hardens SSH — key-only auth, no direct root login |
| 🧱 | Configures a firewall (`ufw` or `firewalld`), opening only the ports you need |
| 🚫 | Installs and configures `fail2ban` against SSH brute-force |
| 🐳 | Optionally installs Docker Engine |

Works on **Debian/Ubuntu** and **RHEL/Rocky/Alma/Fedora**, and is idempotent
where possible — safe to re-run.

---

## 🚀 Quick start

> [!TIP]
> **Just bought a VPS? This is the path you want.** Run it from **your own
> machine** — you never copy-paste anything on the server.

```bash
curl -fsSL https://raw.githubusercontent.com/lizzyman04/vps-bootstrap/main/connect.sh | bash
```

`connect.sh` asks for the server IP, the SSH username (default `root`), and
optionally a local SSH **public** key to install. It then opens an SSH session
and runs `setup.sh` on the server for you.

When the remote setup finishes successfully, `connect.sh` can also add a
convenience **SSH alias** to your local `~/.ssh/config` — so next time you just
run `ssh <alias>` instead of the full command. It suggests a name (e.g.
`vps-<last-octet>`), fills in the host, admin user, identity file, and port,
and never duplicates or overwrites an existing entry.

> [!IMPORTANT]
> **Your server password is handled by SSH — never by this project.**
> `connect.sh` does **not** read, store, pass, or echo your password. There is
> no `sshpass` and no `expect`. You type it **once**, at OpenSSH's own native
> prompt. Under the hood it runs `ssh -t … 'curl … | sudo bash'`; the `-t` keeps
> the session interactive so both the password prompt and the `setup.sh` wizard
> work normally.

No SSH key yet? Generate one first:

```bash
ssh-keygen -t ed25519
```

---

## 🖥️ Running on the server directly

Already SSH'd into the box? Run `setup.sh` there. No clone required.

### ✅ Recommended — download, read, run

The safest path: fetch the script, **skim what it does**, then run it.

```bash
curl -fsSL https://raw.githubusercontent.com/lizzyman04/vps-bootstrap/main/setup.sh -o setup.sh
sudo bash setup.sh
```

### ⚡ One-liner (pipe)

```bash
curl -fsSL https://raw.githubusercontent.com/lizzyman04/vps-bootstrap/main/setup.sh | sudo bash
```

The wizard still works when piped — every prompt reads from `/dev/tty`, so the
pipe consuming stdin doesn't break interactivity.

> [!WARNING]
> Never pipe a script from the internet straight into a root shell without
> reading it first. Download it, skim it, *then* run it as root. The recommended
> two-step above lets you do exactly that.

---

## 🧭 How `setup.sh` runs

### Interactive wizard (default)

With no flags, the script walks you through **every** setting one at a time,
showing a sensible `[default]` in brackets:

> admin user · SSH key (paste it or give a `.pub` path) · SSH port ·
> password/root-login hardening · `fail2ban` · firewall · Docker · system
> upgrade · extra ports · `fail2ban` exempt IP

It then prints a summary of your choices and asks for **one final confirmation**
before changing anything.

### Non-interactive (power users)

Pass `--yes` to skip the wizard and drive everything from flags/defaults. Any
flag also overrides its matching prompt, so you can mix the two:

```bash
sudo bash setup.sh \
  --user lizzyman04 \
  --ssh-key-file ~/.ssh/id_ed25519.pub \
  --extra-ports "80,443" \
  --with-docker \
  --yes
```

Run `sudo bash setup.sh --help` for the full list.

---

## ⚙️ Options

| Flag | Description |
|------|-------------|
| `--user NAME` | Admin (sudo) user to create. **Required.** |
| `--ssh-key "KEY"` | Public SSH key to install. |
| `--ssh-key-file PATH` | Read the public key from a file. |
| `--ssh-port N` | SSH port (default: `22`). |
| `--extra-ports "80,443"` | Extra TCP ports to open. |
| `--ignore-ip CIDR` | IP/CIDR exempt from `fail2ban`. |
| `--no-disable-password` | Keep password auth (not recommended). |
| `--no-disable-root` | Keep direct root SSH login. |
| `--no-fail2ban` | Skip `fail2ban`. |
| `--no-firewall` | Skip firewall. |
| `--no-upgrade` | Skip the system package upgrade. |
| `--with-docker` | Install Docker Engine. |
| `--yes` | Non-interactive (assume yes). |

---

## 🧱 Why the defensive design

This script was written after a real setup that hit every common foot-gun.
It encodes those lessons so you don't repeat them:

- **No IPv6-only lockout.** If you change the SSH port and the system uses
  `ssh.socket`, the script binds the port on **both** `0.0.0.0` and `[::]`
  explicitly. A bare `ListenStream=PORT` can silently become IPv6-only and lock
  out IPv4 clients.
- **No mid-setup self-ban.** `fail2ban`'s `ignoreip` (loopback, plus an optional
  admin IP) is written **before** the jail goes active.
- **No bricked SSH.** The SSH config is validated with `sshd -t` **before** any
  restart. A bad config aborts instead of cutting your access.
- **No password lockout.** The SSH key is installed **before** password auth is
  disabled, and the script refuses to disable passwords if no key is present.
- **Cloud-init override handled.** Many cloud images ship a
  `50-cloud-init.conf` that re-enables password auth and wins over later
  drop-ins; the script neutralizes it.

---

## ✔️ After it finishes

> [!CAUTION]
> **Before logging out**, open a *new* terminal and confirm you can still get in:

```bash
ssh NAME@<server-ip>
```

If it works, you're done. If not, fix it from your still-open session or the
provider's VNC/serial console — *before* you disconnect.

---

## 🔐 Safety notes

- Set a strong sudo password for the admin user afterwards: `sudo passwd NAME`.
  Avoid dates or anything guessable.
- Back up your private SSH key. With password auth disabled, that key is your
  only way in.
- Test in a throwaway VPS before trusting this on something important.

---

## 📄 License

Released under the [MIT License](LICENSE).
