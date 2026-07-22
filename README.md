# wsl-config

This repository contains Windows Subsystem for Linux (WSL) support scripts and configuration helpers for the Sandbox workspace.

## Purpose

The `wsl-config` repo provides a bootstrap script for WSL environments that installs required packages, enables Docker, and configures Homebrew and Flux-related tooling for the Sandbox setup.

## Files

- `wsl-setup.sh` — main setup script for WSL. It installs packages, Docker Engine, Homebrew, and common developer tools.

## Requirements

- WSL2 with a supported Linux distribution (Ubuntu or similar)
- sudo access from a regular user account
- internet connectivity to download packages and install Homebrew

## Usage

Run the setup script with sudo from your normal user account:

```bash
cd /path/to/wsl-config
sudo sh ./wsl-setup.sh
```

The script must be executed as root via sudo, because it:

- creates a sudoers entry for the current normal user
- installs APT packages
- installs Docker Engine if it is not already present
- installs Homebrew for the normal user
- installs brew packages needed for Kubernetes and Flux workflows
- creates shell initialization for Homebrew
- optionally clones kubectx/kubens and creates symlinks

## Installed tools

The script installs or verifies the following components:

- `build-essential`, `curl`, `file`, `tilix`
- Docker Engine and related packages
- Homebrew for Linux
- Homebrew packages: `git`, `curl`, `wget`, `zsh`, `tmux`, `neovim`, `python`, `libpq`, `htop`, `ripgrep`, `fd`, `fzf`, `bat`, `jq`, `awscli`, `k9s`, `docker`, `minikube`, `kubectl`, `flux`
- `kubectx` and `kubens`

## Notes

- The script adds Homebrew initialization to the normal user profile (`~/.profile`, and `~/.zshrc` if it exists).
- After the script runs, open a new shell session or source the profile to use Homebrew-installed tools.

```bash
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

- If Docker is installed successfully, the script adds the normal user to the `docker` group. You may need to log out and log back in for group membership to take effect.

## Troubleshooting

- If the script fails because it cannot determine the normal user, rerun it as `sudo ./wsl-setup.sh` from your normal user session.
- If `systemctl` is unavailable in your WSL distribution, Docker may need to be started manually.
- If Homebrew install is skipped due to missing binary, check the output for the cause and verify the `brew` path in `/home/linuxbrew/.linuxbrew/bin/brew`.
- If you see `failed to create fsnotify watcher: too many open files`, rerun the setup script. It now writes:
	- `/etc/sysctl.d/99-sandbox-inotify.conf` with higher inotify limits
	- `/etc/security/limits.d/99-sandbox-nofile.conf` with higher `nofile` limits for your user

Verify current limits:

```bash
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances fs.inotify.max_queued_events
ulimit -n
```
