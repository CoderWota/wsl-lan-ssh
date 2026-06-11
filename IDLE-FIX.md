# WSL low-resource relay

Applied on 2026-06-11.

## What changed

- `%USERPROFILE%\.wslconfig` is now written with:
  - `memory=12GB`
  - `networkingMode=nat`
  - `firewall=true`
  - `vmIdleTimeout=15000`
  - `autoMemoryReclaim=dropCache`
- `setup-ubuntu-ssh.ps1` now provisions a Windows-side SSH relay task instead of a permanent WSL keep-alive process.
- the relay starts WSL only when an SSH client connects, then shuts the distro down again after the configured idle window if no sessions remain.
- setup now recreates a dedicated inbound Windows Firewall rule for the relay port and removes it again during uninstall.
- console output and relay log files are written in UTF-8 so localized interface names stay readable.
- if `%USERPROFILE%\.wslconfig` already existed, setup now restores that original file during uninstall or rollback instead of deleting it outright.
- the Windows relay C# type definition now lives as a repository template and is rendered into the generated relay script during setup, instead of being embedded inline in the setup script.
- the repository `setup-defaults.json` file now provides the default Linux username, setup prompts for a Linux password during first bootstrap or explicit reset, and the root-only `/var/lib/wslssh-lan/setup.json` file inside the distro stores only repository-managed Linux setup metadata.
- `README.md` now documents the on-demand relay flow and the tradeoff for long-running jobs.

## Why

This keeps idle memory and power use low without giving up LAN SSH access. The host keeps only a small Windows listener alive, while WSL is started on demand and terminated again after it has been idle for a while.

## Apply

Run:

```powershell
wsl --shutdown
```

If WSL features were just enabled, rerun `.\setup-ubuntu-ssh.ps1` after reboot so the remaining WSL-specific steps can finish. The script now asks for that reboot at the end of the staging pass instead of stopping immediately after feature enablement.

