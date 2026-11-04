#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: תכנון ובדיקת cron/timers/hooks.
# בטיחות: יציאה בקוד 64 מונעת תחושת Restore שגויה או הפעלה מוקדמת.
# תוצאה רצויה: שחזור ידני כשהכול disabled עד Gate ה-cutover.
printf 'RETIRED: restore-automation.sh is documentation-only. Follow the automation gates in OPERATIONS.md.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
report=${2:-}
[ "$#" -eq 2 ] || die "usage: $0 --dry-run|--verify-disabled REPORT"
safe_report_path "$report"
printf 'status\tcomponent\tdetail\n' > "$report"
case $mode in
  --dry-run)
    printf 'PLAN\tcron\trestore through reviewed config plan; validate each user with crontab -u USER -l\nPLAN\tsystemd\trestore units/drop-ins; run systemd-analyze verify; daemon-reload only after approval\nPLAN\ttimers\tkeep disabled until cutover owner gate\nPLAN\thooks\tkeep Dovecot Sieve and business hooks inactive until mail gate\n' >> "$report"
    ;;
  --verify-disabled)
    require_target_marker
    for unit in cron postfix dovecot opendkim; do
      if systemctl is-active --quiet "$unit"; then printf 'STOP\t%s\tunexpectedly active\n' "$unit" >> "$report"; failures=1; else printf 'PASS\t%s\tinactive\n' "$unit" >> "$report"; fi
    done
    systemctl list-timers --all --no-pager >> "$report"
    [ "${failures:-0}" -eq 0 ] || exit 1
    ;;
  *) die "unknown mode: $mode" ;;
esac
printf 'SUMMARY\t%s\tcomplete\n' "$mode" >> "$report"
note 'rollback: disable restored timers/jobs and restore the target snapshot; never enable automation on both servers'
