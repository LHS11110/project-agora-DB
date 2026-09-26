#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${1:-}"
if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer with sudo so it can add a systemd timer." >&2
  exit 2
fi
if [ -z "$BACKUP_ROOT" ] || [[ ! "$BACKUP_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Usage: sudo $0 /absolute/path/to/mounted-backup-storage" >&2
  exit 2
fi
if [ ! -d "$BACKUP_ROOT" ] || ! mountpoint -q "$BACKUP_ROOT"; then
  echo "Backup path must already be mounted; refusing to schedule local-disk backups." >&2
  exit 2
fi
BACKUP_ROOT="$(realpath -e "$BACKUP_ROOT")"
if [[ ! "$BACKUP_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Resolved backup path contains unsupported characters for a systemd unit." >&2
  exit 2
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! "$REPO_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Resolved repository path contains unsupported characters for a systemd unit." >&2
  exit 2
fi
SERVICE_FILE=/etc/systemd/system/agora-db-backup.service
TIMER_FILE=/etc/systemd/system/agora-db-backup.timer

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Project Agora database snapshots to durable storage
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
RequiresMountsFor=$BACKUP_ROOT
ConditionPathIsMountPoint=$BACKUP_ROOT

[Service]
Type=oneshot
User=root
Environment=AGORA_BACKUP_ROOT=$BACKUP_ROOT
ExecStart=$REPO_ROOT/ops/backup-all.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Daily Project Agora database backup

[Timer]
OnCalendar=*-*-* 03:15:00 UTC
Persistent=true
RandomizedDelaySec=15m
Unit=agora-db-backup.service

[Install]
WantedBy=timers.target
EOF

chmod 644 "$SERVICE_FILE" "$TIMER_FILE"
systemctl daemon-reload
systemctl enable --now agora-db-backup.timer
systemctl list-timers agora-db-backup.timer --no-pager
