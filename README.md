# WSL Ubuntu SSH Recovery Kit

This repository captures a restorable WSL2 Ubuntu instance and the Windows-side automation needed to bring back LAN-accessible SSH after a reset or reinstall.

## What this repository contains

- `artifacts/ubuntu-ssh-image.tar`
  - Exported WSL root filesystem image of the `Ubuntu` distro
  - Ignored by git because it is large and machine-specific
  - If missing locally, `setup-ubuntu-ssh.ps1` can fetch it from a GitHub Release asset
- `manifest.json`
  - Single source of truth for distro name, Linux user, SSH port, task names, and paths
- `setup-ubuntu-ssh.ps1`
  - Restores the Ubuntu instance from the tar image
  - Rebuilds host-side NAT SSH forwarding, firewall rule, scheduled tasks, and keep-alive behavior
- `uninstall-ubuntu-ssh.ps1`
  - Removes the imported distro and host-side runtime configuration
  - Preserves the tar image, manifest, and scripts for later reuse
- `instances/`
  - Import target directory used by `wsl --import`
- `state/setup-state.json`
  - Generated after setup
  - Used by uninstall to restore prior Windows SSH service and firewall state

## Expected behavior

The setup flow is designed for a clean Windows host:

- imports `Ubuntu` as WSL2
- sets default WSL user to `ubuntu`
- keeps SSH on port `2222`
- allows password login inside WSL
- exposes SSH to devices on the local subnet through Windows `portproxy`
- disables Windows host `sshd` to avoid exposing port `22`
- recreates the forwarding path automatically after reboot via scheduled tasks

## Usage

Run from an elevated PowerShell session.

### Setup

```powershell
.\setup-ubuntu-ssh.ps1
.\setup-ubuntu-ssh.ps1 -ListenAddress 192.0.2.10
```

If WSL features are not enabled yet, the script enables them and exits. After reboot, run the same command again.

If `artifacts\ubuntu-ssh-image.tar` is not present, setup tries these sources in order:

- `manifest.json` field `imageDownloadUrl`, if configured
- the repository's GitHub `origin` remote, using the latest release asset named `ubuntu-ssh-image.tar`

### Uninstall

```powershell
.\uninstall-ubuntu-ssh.ps1
```

### Validate

```powershell
.\validate-repository.ps1
```

This runs a static sanity check over the manifest, setup script, uninstall script, generated refresh script, and GitHub origin parsing logic.

This removes:

- the imported `Ubuntu` distro
- the `instances\Ubuntu` directory
- scheduled tasks
- the Windows firewall rule for port `2222`
- the managed Windows `portproxy` entry for port `2222`
- the generated `ProgramData` refresh script

This keeps:

- `artifacts\ubuntu-ssh-image.tar`
- `manifest.json`
- `setup-ubuntu-ssh.ps1`
- `uninstall-ubuntu-ssh.ps1`

## Safety notes

- `setup-ubuntu-ssh.ps1` stops on conflicts instead of overwriting existing `Ubuntu`, `.wslconfig`, scheduled tasks, or `ProgramData` scripts.
- `.wslconfig` is written with `networkingMode=nat` and `firewall=true`.
- the Windows firewall allow rule is scoped to `Domain,Private`, `LocalSubnet`, and TCP `2222`
- the WSL sshd policy remains password-based by design for broad client compatibility on the LAN

## Suggested repo workflow

- track `README.md`, `manifest.json`, and the PowerShell scripts in git
- keep the tar image outside git unless you intentionally move it into Git LFS or another artifact store
- regenerate `artifacts/ubuntu-ssh-image.tar` whenever you want to capture a new known-good Ubuntu state

## How to distribute the image with this repository

By default, `artifacts/ubuntu-ssh-image.tar` is ignored by git because it is large. The repository stays independently runnable by downloading the image from a Release asset when needed, and you still have three practical ways to ship it together with this project.

### Option 1: GitHub Release asset (recommended)

Use the git repository for scripts and metadata, and upload the tar image as a Release asset.

Workflow:

1. push this repository to GitHub
2. create a tagged release
3. upload `artifacts/ubuntu-ssh-image.tar` to that release
4. on a new machine, clone the repository and run `.\setup-ubuntu-ssh.ps1`

The setup script will automatically download the release asset into `artifacts\ubuntu-ssh-image.tar`.

This keeps normal git operations fast and avoids committing a 10 GB binary into repository history.

### Option 2: Git LFS

If you want the image to travel through git itself, use Git LFS.

Example:

```powershell
git lfs install
git lfs track "artifacts/ubuntu-ssh-image.tar"
git add .gitattributes artifacts/ubuntu-ssh-image.tar
git commit -m "Track WSL image with Git LFS"
```

If you choose Git LFS, remove the image line from `.gitignore` first:

```text
artifacts/ubuntu-ssh-image.tar
```

This approach works, but it depends on Git LFS being enabled on the remote and can consume storage and bandwidth quotas quickly.

### Option 3: Keep the image outside git and place it manually

For private use, the simplest path is often:

1. commit only the scripts and `manifest.json`
2. copy `ubuntu-ssh-image.tar` through a portable drive, NAS, cloud disk, or LAN share
3. place it at `artifacts\ubuntu-ssh-image.tar`
4. run `.\setup-ubuntu-ssh.ps1`

This repository is already prepared for that workflow.
