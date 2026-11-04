#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: preflight ותוכנית cutover לדואר.
# בטיחות: יציאה בקוד 64 מונעת הצגת plan חלקי כאישור מוכנות.
# תוצאה רצויה: עבודה לפי checklist הדואר הידני ב-OPERATIONS.md.
printf 'RETIRED: mail-migration.sh is not an executable migration control. Follow OPERATIONS.md.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
report=${2:-}
[ "$#" -eq 2 ] || die "usage: $0 --source-preflight|--target-verify|--cutover-plan REPORT"
safe_report_path "$report"
tmp=$(mktemp "${report}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf 'status\tcomponent\tdetail\n' > "$tmp"

case $mode in
  --source-preflight)
    for command in postconf doveconf postqueue; do need_cmd "$command"; done
    postconf -n >/dev/null
    doveconf -n >/dev/null
    queue_count=$(postqueue -p | awk '/^[0-9]+ Requests/ {print $1; found=1} END{if(!found) print 0}')
    maildir_count=$(find /var/mail -xdev -type f | wc -l)
    hook_count=$(find /var/mail-hooks-data -xdev -type f | wc -l)
    printf 'PASS\tpostfix\tconfiguration readable\nPASS\tdovecot\tconfiguration readable\nPASS\tqueue\tmessages=%s\nPASS\tmaildir\tfiles=%s\nPASS\thooks\tfiles=%s\n' "$queue_count" "$maildir_count" "$hook_count" >> "$tmp"
    ;;
  --target-verify)
    require_target_marker
    for command in postfix doveconf postqueue; do need_cmd "$command"; done
    postfix check
    doveconf -n >/dev/null
    systemctl is-active --quiet postfix && { printf 'STOP\tpostfix\tmust remain inactive during trial\n' >> "$tmp"; mv "$tmp" "$report"; trap - EXIT; exit 1; }
    printf 'PASS\tpostfix\tconfiguration check passed and service inactive\nPASS\tdovecot\tconfiguration parse passed\n' >> "$tmp"
    ;;
  --cutover-plan)
    printf 'PLAN\t1\tblock/queue new SMTP and stop LMTP/Sieve/hooks on source\nPLAN\t2\tdrain or inventory Postfix queue; record queue IDs\nPLAN\t3\tfinal MariaDB backup/restore while application writes are stopped\nPLAN\t4\tfinal rsync Maildir/hooks with -aHAX --numeric-ids and content checksums\nPLAN\t5\tstart exactly one delivery/hook pipeline on target; keep source relay-only\nPLAN\t6\tvalidate SMTP submission IMAP DKIM TLS aliases quotas and queue\nPLAN\t7\tchange DNS only after gates; retain source overlap without local delivery\nPLAN\trollback\tstop target delivery; reconcile new mail by Message-ID/content hash; restore old routing\n' >> "$tmp"
    ;;
  *) die "unknown mode: $mode" ;;
esac

printf 'SUMMARY\t%s\tcomplete\n' "$mode" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
note "mail report: $report"
