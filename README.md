# Windows WSL Ubuntu LAN SSH Kit

Installing WSL is easy. Turning it into a clean, repeatable, LAN-accessible Ubuntu environment is usually not.

This repository exists to remove that friction. It installs and manages a dedicated `Ubuntu` WSL instance, configures SSH for it, and exposes it to other devices on your local network through a lightweight Windows-side relay. The goal is to make a personal Windows PC much easier to use as an AI agent host, a lightweight training box, or a LAN-reachable Ubuntu machine for development work, without leaving a full WSL VM running all the time.

## Why this exists

Configuring WSL for this kind of use case is usually more annoying than it should be:

- installing Ubuntu in WSL is only the first step
- enabling SSH properly inside WSL takes extra manual work
- making other devices on your home LAN reach that WSL instance is even more awkward
- repeating the same setup on another Windows machine is tedious and error-prone
- keeping WSL always alive just so SSH stays reachable wastes memory and power

This project is for the "my Windows PC should also act like a simple Ubuntu box" scenario:

- you want to host AI agents on your own Windows machine
- you want to run deep learning or other long-running workloads in WSL
- you want to SSH into that Ubuntu environment from a laptop, another desktop, or another device on your LAN
- you want the setup to be scripted, reproducible, and easy to reinstall

## What setup does

Running `setup-ubuntu-ssh.ps1` will:

- install or repair the managed WSL distro named `Ubuntu`
- create or refresh the default Linux user from `setup-defaults.json`
- prompt for a Linux password on first bootstrap, or when you explicitly reset it
- install `openssh-server` inside Ubuntu
- write `/etc/wsl.conf`
- write a managed SSH drop-in at `/etc/ssh/sshd_config.d/99-wsl-ssh-lan.conf`
- create a Windows scheduled task named `WSL SSH Relay`
- create a Windows firewall rule for TCP `2222`
- write `%USERPROFILE%\.wslconfig` with idle-friendly WSL settings

The managed SSH policy is:

- port `2222`
- password login enabled
- root login disabled
- `AllowUsers ubuntu`
- forwarding features disabled

## Quick Start

Run all commands from an elevated PowerShell window.

### First install

```powershell
.\setup-ubuntu-ssh.ps1
```

By default, setup automatically chooses a suitable LAN IPv4 address from an active `Private` or `DomainAuthenticated` adapter.

If the Linux user does not exist yet, setup will ask you to enter and confirm a password. That password must be at least 8 characters long and must not contain a colon or newline.

### Choose a specific listen address

```powershell
.\setup-ubuntu-ssh.ps1 -ListenAddress <your-lan-ipv4-address>
```

Use this only when you want to pin the relay to a specific address on the host.

### Non-interactive install

If setup is being launched through automation or a hidden elevated window, pass the password explicitly so the script does not need to prompt:

```powershell
$linuxPassword = Read-Host -AsSecureString "Linux password"
.\setup-ubuntu-ssh.ps1 -LinuxPassword $linuxPassword
```

### Reset the Linux password later

```powershell
.\setup-ubuntu-ssh.ps1 -ResetLinuxPassword
```

If the user already exists, ordinary reruns of setup leave the current Linux password unchanged unless you explicitly pass `-LinuxPassword` or `-ResetLinuxPassword`.

## After setup

At the end of setup, the script prints the SSH command you should use.

With the current defaults, it looks like this:

```bash
ssh -p 2222 ubuntu@<host-lan-ip>
```

If you need to inspect the repository-managed Linux setup metadata later:

```powershell
wsl.exe -d Ubuntu -u root -- cat /var/lib/wslssh-lan/setup.json
```

That file stores only repository-managed metadata such as the Linux username. It does not store the Linux password.

## Uninstall

To remove the managed Ubuntu instance and the Windows-side relay configuration:

```powershell
.\uninstall-ubuntu-ssh.ps1
```

Important:

- the uninstall script removes only the distro named in `manifest.json`
- by default, that distro name is `Ubuntu`
- it does not remove unrelated WSL distros such as `UbuntuCheck`

## Validation

To run the repository consistency checks:

```powershell
.\validate-repository.ps1
```

This validates the manifest, template rendering, generated relay script, and key setup assumptions.

## Common Issues

### SSH says "REMOTE HOST IDENTIFICATION HAS CHANGED"

This usually means the Ubuntu instance was reinstalled and its SSH host keys changed.

On the client machine:

```bash
ssh-keygen -R "[<host-lan-ip>]:2222"
ssh -p 2222 ubuntu@<host-lan-ip>
```

Then verify the new host key and answer `yes`.

If your SSH client points to a specific offending line in `~/.ssh/known_hosts`, deleting that line manually is also fine.

### Setup seems stuck during password configuration

If setup is running in a hidden elevated window or another non-interactive context, it cannot prompt for a password.

Use:

```powershell
$linuxPassword = Read-Host -AsSecureString "Linux password"
.\setup-ubuntu-ssh.ps1 -LinuxPassword $linuxPassword
```

Or rerun setup manually in a visible elevated PowerShell window.

### `wsl` still opens Ubuntu after uninstall

Check which distro is still registered:

```powershell
wsl -l -v
```

This repository only manages the distro named in `manifest.json`. If another distro remains registered and is set as default, plain `wsl` will still open that one.

## Managed files and configuration

Key repository files:

- `manifest.json`
  - central configuration for distro name, SSH port, relay settings, and file paths
- `setup-defaults.json`
  - default Linux username
- `linux-security-profile.json`
  - reusable Linux-side WSL and SSH baseline
- `templates/WslSshRelay.TypeDefinition.cs`
  - C# relay template rendered into the generated PowerShell relay script
- `setup-ubuntu-ssh.ps1`
  - install and repair entry point
- `uninstall-ubuntu-ssh.ps1`
  - uninstall entry point
- `validate-repository.ps1`
  - repository self-check

Managed runtime paths:

- `%USERPROFILE%\.wslconfig`
- `C:\ProgramData\WslSshLan\WslSshRelay.ps1`
- `/var/lib/wslssh-lan/setup.json`
- `state/setup-state.json`

## Notes

- `%USERPROFILE%\.wslconfig` is written with:
  - `memory=12GB`
  - `networkingMode=nat`
  - `firewall=true`
  - `vmIdleTimeout=15000`
  - `autoMemoryReclaim=dropCache`
- the Windows firewall rule is scoped to `Domain,Private` and `LocalSubnet`
- the relay starts WSL on demand and lets it shut down again after the configured idle window
- if `%USERPROFILE%\.wslconfig` already existed before setup, the previous content is preserved and restored during uninstall or rollback
- if you want long-running training jobs to survive disconnects, use `tmux` or `screen`, or increase `relayIdleShutdownSeconds` in `manifest.json`

## Publishing / contribution notes

- keep `README.md`, `manifest.json`, and the PowerShell scripts in git
- change the bootstrap logic by editing the scripts and templates in this repo
- do not treat a local WSL image as the source of truth
