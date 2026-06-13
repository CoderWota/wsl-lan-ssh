# Windows WSL Ubuntu LAN SSH Kit

This project installs and manages a dedicated `Ubuntu` WSL distro, enables SSH inside it, and exposes it to your local network through a lightweight Windows-side relay.

It is aimed at the "my Windows PC should also behave like a small Ubuntu box" use case: AI agents, development workloads, remote shells, and long-running jobs inside WSL without keeping the VM permanently alive.

## What it does

Running `setup-ubuntu-ssh.ps1` will:

- install or repair the managed `Ubuntu` WSL distro
- create or refresh the default Linux user from `setup-defaults.json`
- prompt for a Linux password on first bootstrap, or when you explicitly reset it
- install required Ubuntu packages inside the managed distro, including `openssh-server`, `build-essential`, `jq`, `ripgrep`, `fd-find`, and `fzf`
- write `/etc/wsl.conf`
- write a managed SSH drop-in at `/etc/ssh/sshd_config.d/99-wsl-ssh-lan.conf`
- create a Windows scheduled task named `WSL SSH Relay`
- create a Windows firewall rule for TCP `2222`
- write `%USERPROFILE%\.wslconfig` with idle-friendly WSL settings

The default managed SSH policy is:

- port `2222`
- password login enabled
- root login disabled
- `AllowUsers ubuntu`
- TCP forwarding enabled for VS Code Remote-SSH
- stream-local forwarding enabled for VS Code Remote-SSH
- agent forwarding disabled

## Quick Start

Run setup from an elevated PowerShell window:

```powershell
.\setup-ubuntu-ssh.ps1
```

At the end, setup prints the SSH command to use. With default settings it will look like:

```bash
ssh -p 2222 ubuntu@<host-lan-ip>
```

If you want to pin the relay to one specific LAN IPv4:

```powershell
.\setup-ubuntu-ssh.ps1 -ListenAddress <your-lan-ipv4-address>
```

If setup is running non-interactively, pass the Linux password explicitly:

```powershell
$linuxPassword = Read-Host -AsSecureString "Linux password"
.\setup-ubuntu-ssh.ps1 -LinuxPassword $linuxPassword
```

To reset the Linux password later:

```powershell
.\setup-ubuntu-ssh.ps1 -ResetLinuxPassword
```

## Configuration

Most users only need these files:

- `setup-defaults.json`
  - default Linux username
- `manifest.json`
  - distro name, SSH port, relay settings, file paths, and the Ubuntu bootstrap package list
- `linux-security-profile.json`
  - Linux-side WSL and SSH baseline

Useful defaults:

- distro name: `Ubuntu`
- SSH port: `2222`
- default Linux user: `ubuntu`
- WSL memory limit: `12GB`
- `%USERPROFILE%\.wslconfig` includes `localhostForwarding=true`

## Uninstall

To remove the managed Ubuntu instance and Windows relay configuration:

```powershell
.\uninstall-ubuntu-ssh.ps1
```

The uninstall script removes only the distro named in `manifest.json`.

## Validation

To run the repository consistency checks:

```powershell
.\validate-repository.ps1
```

This validates the manifest, template rendering, generated relay script, and key setup assumptions.

## Common Issues

### SSH says "REMOTE HOST IDENTIFICATION HAS CHANGED"

This usually means the Ubuntu instance was reinstalled and its SSH host keys changed.

```bash
ssh-keygen -R "[<host-lan-ip>]:2222"
ssh -p 2222 ubuntu@<host-lan-ip>
```

### Setup cannot prompt for a password

If setup is running in a hidden or non-interactive context, pass `-LinuxPassword` explicitly:

```powershell
$linuxPassword = Read-Host -AsSecureString "Linux password"
.\setup-ubuntu-ssh.ps1 -LinuxPassword $linuxPassword
```

### SSH connects, then closes after about 15 seconds

Check the Linux-side logs first:

```powershell
wsl.exe -d Ubuntu -u root -- journalctl -u ssh --no-pager -n 50
wsl.exe -d Ubuntu -u root -- tail -n 100 /var/log/auth.log
```

If you changed `%USERPROFILE%\.wslconfig`, apply it with:

```powershell
wsl --shutdown
```

## Managed Files

Key repository files:

- `manifest.json`
- `setup-defaults.json`
- `linux-security-profile.json`
- `templates/Install-WslBootstrapPackages.sh`
- `templates/WslSshRelay.TypeDefinition.cs`
- `templates/WslSshRelay.ps1`
- `setup-ubuntu-ssh.ps1`
- `uninstall-ubuntu-ssh.ps1`
- `validate-repository.ps1`

Managed runtime paths:

- `%USERPROFILE%\.wslconfig`
- `C:\ProgramData\WslSshLan\WslSshRelay.ps1`
- `/var/lib/wslssh-lan/setup.json`
- `state/setup-state.json`

## Notes

- the relay starts WSL on demand and shuts it down again after the configured idle window
- if `%USERPROFILE%\.wslconfig` already existed before setup, the previous content is preserved and restored during uninstall or rollback
- if you want long-running jobs to survive disconnects, use `tmux` or increase `relayIdleShutdownSeconds` in `manifest.json`
