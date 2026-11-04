#!/bin/bash
# EMERGENCY ONLY — מטרה: להחזיר account databases וקבצי SSH מתוך journal ב-tmpfs.
# בטיחות: יעד במצב maintenance בלבד, ללא תהליכי משתמשים ובאישור rollback ייחודי.
# תוצאה רצויה: חזרה לנקודת pre-import; snapshot ספק עדיין מועדף.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

journal=${1:-}
report=${2:-}
[ "$#" -eq 2 ] || die "usage: $0 TMPFS_JOURNAL REPORT"
need_root
require_target_marker
require_approval ROLLBACK_LINUX_IDENTITIES
require_tmpfs_path "$journal"
need_file "$journal/APPLY_STARTED"
for file in passwd shadow group gshadow; do need_file "$journal/files/etc/$file"; done
maintenance_marker=${MIGRATION_MAINTENANCE_MARKER:-/run/vps-migration-maintenance}
grep -Fxq 'NO_SERVING_TRAFFIC=YES' "$maintenance_marker" || die "maintenance marker missing: $maintenance_marker"
safe_report_path "$report"

while IFS= read -r user; do
  [ -n "$user" ] || continue
  if pgrep -u "$user" >/dev/null 2>&1; then die "created user still has processes: $user"; fi
done < "$journal/created-users"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case $path in
    /home/*/.ssh/authorized_keys|/root/.ssh/authorized_keys)
      if [ -e "$journal/files$path" ]; then cp -a -- "$journal/files$path" "$path"; else find "$path" -maxdepth 0 -delete; fi
      ;;
    *) die "unsafe authorized_keys rollback path: $path" ;;
  esac
done < "$journal/installed-authorized-keys"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case $path in /etc/sudoers.d/*) find "$path" -maxdepth 0 -delete ;; *) die "unsafe sudo rollback path: $path" ;; esac
done < "$journal/installed-sudo-fragments"

cp -a -- "$journal/files/etc/passwd" /etc/passwd
cp -a -- "$journal/files/etc/shadow" /etc/shadow
cp -a -- "$journal/files/etc/group" /etc/group
cp -a -- "$journal/files/etc/gshadow" /etc/gshadow
if [ -d "$journal/files/etc/sudoers.d" ]; then cp -a -- "$journal/files/etc/sudoers.d/." /etc/sudoers.d/; fi
visudo -c >/dev/null

while IFS= read -r home; do
  [ -n "$home" ] || continue
  case $home in /home/*) find "$home" -depth -type d -empty -delete ;; *) die "unsafe created home path: $home" ;; esac
done < "$journal/created-homes"
while IFS= read -r ssh_dir; do
  [ -n "$ssh_dir" ] || continue
  case $ssh_dir in /home/*/.ssh|/root/.ssh) find "$ssh_dir" -depth -type d -empty -delete ;; *) die "unsafe SSH directory path: $ssh_dir" ;; esac
done < "$journal/created-ssh-dirs"
printf 'status\tdetail\nPASS\tidentity account databases and recorded files restored from journal\n' > "$report"
note 'rollback completed; provider snapshot remains the preferred rollback if any data ownership was assigned'
