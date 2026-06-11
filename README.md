# WSL Ubuntu SSH Recovery Kit

This repository bootstraps a clean Ubuntu WSL distro and wires it for LAN-accessible SSH. It no longer depends on a local tar image or any GitHub release asset.

## What this repository contains

- `manifest.json`
  - Single source of truth for distro name, SSH port, resource limits, task names, and script paths
- `setup-defaults.json`
  - Repository default for the Linux username
- `linux-security-profile.json`
  - Repository copy of the current Ubuntu SSH hardening baseline
  - Used to render `/etc/wsl.conf` and the managed sshd drop-in during setup
- `templates/WslSshRelay.TypeDefinition.cs`
  - Relay C# type definition template stored in the repository
  - Rendered into the PowerShell relay wrapper that `setup-ubuntu-ssh.ps1` writes to `C:\ProgramData\WslSshLan\WslSshRelay.ps1`
- `/var/lib/wslssh-lan/setup.json`
  - Created inside the Ubuntu distro on first run
  - Stores the generated or custom Linux password outside the git repo
- `validate-fixtures.json`
  - Test fixtures used by `validate-repository.ps1`
- `setup-ubuntu-ssh.ps1`
  - Installs Ubuntu directly with `wsl --install -d Ubuntu --web-download --no-launch`
  - Creates the Linux user, installs `openssh-server`, and writes `/etc/wsl.conf` plus an sshd drop-in
  - Rebuilds the Windows-side SSH relay, inbound firewall rule, scheduled task, and idle-shutdown behavior
  - Renders the relay C# type definition from the repository template instead of hardcoding that block inline
  - Forces console output and relay logs to UTF-8 so localized interface names and other non-ASCII text stay readable
- `uninstall-ubuntu-ssh.ps1`
  - Removes the Ubuntu distro and host-side runtime configuration
  - Preserves the PowerShell scripts and manifest for later reuse
- `state/setup-state.json`
  - Generated after setup
  - Used by uninstall to restore prior Windows SSH service and firewall state

## Expected behavior

The setup flow is designed for a clean Windows host:

- enables the required WSL Windows features if they are missing
- installs Ubuntu directly through WSL
- sets the default Linux user from `setup-defaults.json`, with `ubuntu` as the packaged default username
- applies the SSH and WSL hardening template from `linux-security-profile.json`
- stores the generated password inside `/var/lib/wslssh-lan/setup.json`
- keeps SSH on port `2222`
- allows password login inside WSL
- exposes SSH to devices on the local subnet through a lightweight Windows relay listener
- disables Windows host `sshd` to avoid exposing port `22`
- starts WSL on the first SSH connection, then terminates it again after the configured idle window when no SSH sessions remain

## Usage

Run from an elevated PowerShell session.

### Setup

```powershell
.\setup-ubuntu-ssh.ps1
.\setup-ubuntu-ssh.ps1 -ListenAddress 192.0.2.10
```

If WSL features are not enabled yet, the script stages the install, then asks for a reboot at the end so the remaining WSL-specific steps can be finished after Windows comes back up. After reboot, run the same command again.

If Ubuntu is not installed yet, setup installs it directly through WSL, then bootstraps the distro in place.

If `setup-defaults.json` is not present, setup stops because it needs the repository default username.

If `/var/lib/wslssh-lan/setup.json` is not present, setup creates it inside the Ubuntu distro from the repository defaults and generates a new password, then uses those values to configure the distro.

To inspect the generated credentials later, read that file from inside WSL as root:

```powershell
wsl.exe -d Ubuntu -u root -- cat /var/lib/wslssh-lan/setup.json
```

### Uninstall

```powershell
.\uninstall-ubuntu-ssh.ps1
```

### Validate

```powershell
.\validate-repository.ps1
```

This runs a static sanity check over the manifest, setup script, uninstall script, generated relay script, and Linux bootstrap configuration logic.

## Troubleshooting

### SSH says "REMOTE HOST IDENTIFICATION HAS CHANGED"

If the Ubuntu instance was reinstalled, SSH host keys inside WSL were regenerated. In that case, SSH clients that connected before will still have the old host key cached in `~/.ssh/known_hosts`, and they will refuse to connect until that stale entry is removed.

On the client machine, remove the old key for this host and reconnect:

```bash
ssh-keygen -R "[192.0.2.10]:2222"
ssh -p 2222 ubuntu@192.0.2.10
```

When prompted, verify and accept the new host key with `yes`.

If the client reported a specific offending line in `~/.ssh/known_hosts`, deleting that line manually works too.

## Safety notes

- `setup-ubuntu-ssh.ps1` repairs an existing `Ubuntu` distro in place, and refreshes `.wslconfig`, scheduled tasks, and `ProgramData` scripts as needed.
- if `%USERPROFILE%\.wslconfig` already existed before setup, the script preserves its previous contents in state and restores them on uninstall or rollback
- `setup-ubuntu-ssh.ps1` and the generated relay script force UTF-8 output, so log files and localized interface names should remain readable end to end.
- the repository `setup-defaults.json` file stores the default Linux username, `linux-security-profile.json` stores the reusable Linux security baseline, and `/var/lib/wslssh-lan/setup.json` inside the distro stores the generated or custom password for the machine
- `.wslconfig` is written with `memory=12GB`, `networkingMode=nat`, `firewall=true`, `vmIdleTimeout=15000`, and `autoMemoryReclaim=dropCache` to keep the VM small when idle and return unused pages to Windows quickly
- the relay task starts WSL only when an SSH client connects, waits for `sshd` inside WSL to come up, and then proxies the SSH stream
- the Windows firewall allow rule is scoped to `Domain,Private`, `LocalSubnet`, and TCP `2222`
- the WSL sshd policy remains password-based by design for broad client compatibility on the LAN
- if you want long-running training jobs to survive a disconnect, keep the session open with `tmux`/`screen` or raise `relayIdleShutdownSeconds` in `manifest.json`

## Suggested repo workflow

- track `README.md`, `manifest.json`, and the PowerShell scripts in git
- regenerate the Ubuntu bootstrap behavior by editing the scripts, not by committing a tar image
