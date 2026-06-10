# WSL idle fix

Applied on 2026-06-10.

## What changed

- `C:\Users\Wota\.wslconfig` now uses:
  - `networkingMode=nat`
  - `firewall=true`
  - `vmIdleTimeout=86400000`
- `setup-ubuntu-ssh.ps1` now writes the same `.wslconfig` values during future setup runs.
- `setup-ubuntu-ssh.ps1` records the active LAN interface alias and lets the refresh task retry until the network and WSL SSH listener are both ready.
- the refresh task now rebuilds the Windows `portproxy` and firewall rule instead of relying on stale IPs.
- `README.md` was updated to reflect the new idle-resilience settings.

## Why

This reduces the chance that WSL 2 becomes unreachable from external SSH clients after being idle for a while. The main mitigation is increasing the VM idle timeout, keeping a permanent WSL process alive, and making the startup refresh task resilient to DHCP and boot timing.

## Apply

Run:

```powershell
wsl --shutdown
```

Then start the distro again. If OpenSSH inside WSL is managed by systemd, make sure it is enabled:

```bash
sudo systemctl enable ssh
sudo systemctl restart ssh
```

