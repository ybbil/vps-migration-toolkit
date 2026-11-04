#!/bin/bash
# EMERGENCY ONLY — מטרה: להחזיר secret files שנשמרו ב-journal זמני.
# בטיחות: שירותים כבויים, maintenance marker ואישור rollback; journal עלול להיעלם באתחול.
# תוצאה רצויה: החזרת הקבצים הקודמים או הסרת קבצים חדשים שתועדו.
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
require_approval ROLLBACK_SECRETS
require_tmpfs_path "$journal"
need_file "$journal/APPLY_STARTED"
need_file "$journal/created-paths"
maintenance_marker=${MIGRATION_MAINTENANCE_MARKER:-/run/vps-migration-maintenance}
grep -Fxq 'NO_SERVING_TRAFFIC=YES' "$maintenance_marker" || die "maintenance marker missing: $maintenance_marker"
safe_report_path "$report"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case $path in /etc/*|/root/*|/home/*|/opt/*|/var/www/*) find "$path" -maxdepth 0 -type f -delete ;; *) die "unsafe created secret path: $path" ;; esac
done < "$journal/created-paths"

if [ -d "$journal/files" ]; then
  while IFS= read -r backup; do
    relative=${backup#"$journal/files"}
    case $relative in /etc/*|/root/*|/home/*|/opt/*|/var/www/*) install -d -m 0750 "$(dirname -- "$relative")"; cp -a -- "$backup" "$relative" ;; *) die "unsafe backup path: $relative" ;; esac
  done < <(find "$journal/files" -type f -print)
fi
printf 'status\tdetail\nPASS\trecorded secret files restored or removed\n' > "$report"
note 'rollback completed while services remained stopped'
