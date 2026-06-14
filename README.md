# Docker Services Backup (DSB)

<p align="center">
  <a href="https://github.com/MOIS3Y/dsb/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge&labelColor=101418" alt="License">
  </a>
  <a href="https://github.com/MOIS3Y/dsb/blob/main/flake.nix">
    <img src="https://img.shields.io/badge/Nix-Enabled-blueviolet?style=for-the-badge&logo=nixos&logoColor=white&labelColor=101418" alt="Nix">
  </a>
  <a href="https://www.docker.com/">
    <img src="https://img.shields.io/badge/Docker-Ready-2496ED?style=for-the-badge&logo=docker&logoColor=white&labelColor=101418" alt="Docker">
  </a>
  <a href="https://github.com/koalaman/shellcheck">
    <img src="https://img.shields.io/badge/ShellCheck-Passing-success?style=for-the-badge&logo=gnu-bash&logoColor=white&labelColor=101418" alt="ShellCheck">
  </a>
</p>

My personal script for automating and orchestrating Docker service backups 
using [`restic`](https://restic.net/) (a fast, secure, and efficient 
backup program).

This repository contains a robust, fault-tolerant Bash script that I built 
to manage backups across my NixOS VPS instances. It acts as a thin orchestrator 
that safely stops specific databases and services before taking a snapshot 
to ensure data consistency, then reliably brings them back up.

I decided to share it in case someone else running self-hosted Docker stacks 
finds it useful.

## Key Features

* **Universal Storage Support**: DSB acts as a thin wrapper around restic, 
  meaning it natively supports any backend restic supports (S3, B2, SFTP, 
  Local, etc.). Use the `--option` flag to pass custom backend parameters.
* **Label-Based Orchestration**: No need to hardcode container names. Just 
  add the `dsb.stop.required=true` label to your `docker-compose.yml`, and 
  the script will automatically discover, stop, and restart those containers 
  during the backup process.
* **Strict State Verification**: The script explicitly verifies that target 
  containers are fully stopped before executing `restic`. If a container 
  hangs, the backup is safely aborted to prevent data corruption.
* **Guaranteed Restarts**: Uses bash `trap` signals. Even if the backup fails, 
  the `restic` binary crashes, or you manually interrupt the script with 
  `Ctrl+C`, your services will be brought back online.
* **12-Factor Ready**: Supports `RESTIC_REPOSITORY_FILE` and `RESTIC_PASSWORD_FILE`
  to securely inject configuration without exposing credentials in the process 
  tree or logs, making it ideal for systemd services and NixOS modules.
* **Multi-Server Tagging**: Automatically tags snapshots with the system 
  hostname (or custom tags), making it easy to store backups from multiple 
  servers in a single repository and prune them independently.

## Limitations

* **Container-Level Stoppage**: This script orchestrates backups by stopping 
  the entire container. It does *not* execute application-level dumps. Expect 
  a few seconds of downtime for labeled services during the backup.
* **Bind Mounts Only**: Because the script backs up a specific filesystem 
  path (e.g., `/services`), it only captures data stored in Docker bind 
  mounts. Native Docker volumes are not automatically captured.
* **Root Privileges**: The script must be run as `root` (or a user in the 
  `docker` group with read access to your volumes) to interact with the 
  Docker daemon and read all files in the backup path.

## Installation

### For NixOS / Nix Users (Recommended)

> [!TIP]
> **No installation required!**
> Because `dsb` is packaged as a Flake, you don't actually need to install 
> it permanently. You can execute it directly from GitHub anywhere:
> ```bash
> sudo nix run github:MOIS3Y/dsb -- backup
> ```

To add it permanently to your NixOS system via Flakes:

```nix
# flake.nix
{
  inputs.dsb.url = "github:MOIS3Y/dsb";

  outputs = { self, nixpkgs, dsb, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # ...
        ({ pkgs, ... }: {
          environment.systemPackages = [
            dsb.packages.${pkgs.stdenv.hostPlatform.system}.default
          ];
        })
      ];
    };
  };
}
```

### For Generic Linux

1. Ensure `docker` and `restic` are installed on your system.
2. Download the script and make it executable:

```bash
sudo curl -Lo /usr/local/bin/dsb \
  https://raw.githubusercontent.com/MOIS3Y/dsb/main/src/dsb.sh
sudo chmod +x /usr/local/bin/dsb
```

## Usage & Configuration

### 1. Tag your containers

In your `docker-compose.yml`, add the `dsb.stop.required` label to any 
service that needs to be stopped to maintain data consistency:

```yaml
services:
  stalwart-mail:
    image: stalwartlabs/mail-server:latest
    labels:
      - "dsb.stop.required=true"
    volumes:
      - ./data:/opt/stalwart/data
```

### 2. Configure Authentication

> [!NOTE]
> Restic encrypts everything with zero trust. If you lose your password, 
> your backups are permanently gone. Store your password in a secure manager.

Create a secure file containing your Restic repository URL (optional but recommended) and password:

```bash
echo "s3:s3.amazonaws.com/my-backup-bucket" > /etc/dsb/repo.txt
echo "MySuperSecretPassword" > /etc/dsb/pass.txt
chmod 600 /etc/dsb/*.txt
```

### 3. CLI Examples

**Standard Backup (using secure files):**
```bash
dsb \
  --path /services \
  --repo-file /etc/dsb/repo.txt \
  --password-file /etc/dsb/pass.txt \
  backup
```

**Automated SFTP Backup (preventing hangs):**
```bash
dsb \
  --repo sftp:user@host:/backups \
  --password-file /etc/dsb/pass.txt \
  --option sftp.args="-o BatchMode=yes" \
  backup
```

**List Backups (Filtering by Tag):**
```bash
dsb \
  --repo-file /etc/dsb/repo.txt \
  --password-file /etc/dsb/pass.txt \
  --tags "vps-web-01" \
  list
```

**Clean Up Old Snapshots:**
```bash
dsb \
  --repo-file /etc/dsb/repo.txt \
  --password-file /etc/dsb/pass.txt \
  --tags "vps-web-01" \
  prune
```

**Safe Restoration (Single File/Folder):**
```bash
dsb \
  --repo-file /etc/dsb/repo.txt \
  --password-file /etc/dsb/pass.txt \
  restic restore latest \
  --target /tmp/recovery \
  --include /services/apps/bulwark
```

## Automation Examples

### Method A: NixOS Systemd Timers (Recommended)

Because `dsb` executes `restic` as a child process via `bash -c`, any variables defined in the `Environment` or exported within the script are properly inherited.

```nix
{ config, pkgs, lib, inputs, ... }:

let
  dsb = lib.getExe inputs.dsb.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  # Shared Environment Variables for all tasks
  environment.variables = {
    DSB_BACKUP_PATH = "/services";
    RESTIC_REPOSITORY_FILE = "/run/secrets/restic_repo";
    RESTIC_PASSWORD_FILE = "/run/secrets/restic_password";
  };

  # Daily Backup Task
  systemd.services.docker-backup = {
    description = "Docker Services Backup";
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${dsb} backup";
      User = "root";
    };
  };

  systemd.timers.docker-backup = {
    description = "Daily timer for Docker Services Backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
    };
  };

  # Weekly Prune Task
  systemd.services.docker-backup-prune = {
    description = "Prune old Docker Services Backups";
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${dsb} prune";
      User = "root";
    };
  };

  systemd.timers.docker-backup-prune = {
    description = "Weekly timer to prune old backups";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 05:00:00";
      Persistent = true;
    };
  };
}
```

### Method B: Standard Cron (Generic Linux)

> [!TIP]
> **Keep your Crontab clean**
> Instead of writing long one-liners in your crontab, it's often cleaner 
> to create a small wrapper script that exports variables and calls `dsb`.

```bash
# Run backup daily at 03:00 AM
0 3 * * * RESTIC_REPOSITORY_FILE="/etc/dsb/repo.txt" RESTIC_PASSWORD_FILE="/etc/dsb/pass.txt" /usr/local/bin/dsb backup >> /var/log/dsb-backup.log 2>&1

# Run prune weekly on Sunday at 05:00 AM
0 5 * * 0 RESTIC_REPOSITORY_FILE="/etc/dsb/repo.txt" RESTIC_PASSWORD_FILE="/etc/dsb/pass.txt" /usr/local/bin/dsb prune >> /var/log/dsb-prune.log 2>&1
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.