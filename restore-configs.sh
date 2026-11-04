#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: התקנת configs מסווגים.
# בטיחות: יציאה בקוד 64 מונעת cron מוקדם ודריסת package defaults.
# תוצאה רצויה: staging, diff, merge ו-lint ידניים לפני install.
printf 'RETIRED: restore-configs.sh must not be run; use staged manual merges and native lint.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
staging=${2:-}
plan=${3:-}
report=${4:-}
journal=${5:-}
case $mode in
  --dry-run) [ "$#" -eq 4 ] || die "usage: $0 --dry-run STAGING PLAN.tsv REPORT" ;;
  --apply) [ "$#" -eq 5 ] || die "usage: $0 --apply STAGING PLAN.tsv REPORT TMPFS_JOURNAL" ;;
  *) die "usage: $0 --dry-run STAGING PLAN REPORT | --apply STAGING PLAN REPORT JOURNAL" ;;
esac
need_dir "$staging"
need_file "$plan"
safe_report_path "$report"
[ "$(head -n1 "$plan")" = $'staged_relative_path\ttarget_path\taction\towner_uid\towner_gid\tmode\tcomponent' ] || die 'invalid config plan header'

tmp=$(mktemp "${report}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf 'status\tcomponent\ttarget\taction\tdetail\n' > "$tmp"
stops=0
while IFS=$'\034' read -r relative target action uid gid mode_value component; do
  [ "$relative" = staged_relative_path ] && continue
  case $target in /etc/*) ;; *) die "config target must be under /etc: $target" ;; esac
  case $action in install|merge|omit) ;; *) die "invalid config action: $action" ;; esac
  [ "$action" = omit ] && { printf 'PASS\t%s\t%s\tomit\tapproved omission\n' "$component" "$target" >> "$tmp"; continue; }
  source_file="$staging/$relative"
  [ -f "$source_file" ] || { printf 'STOP\t%s\t%s\t%s\tstaged file missing\n' "$component" "$target" "$action" >> "$tmp"; stops=$((stops + 1)); continue; }
  if [ "$action" = merge ]; then
    printf 'STOP\t%s\t%s\tmerge\tmanual reviewed merge required\n' "$component" "$target" >> "$tmp"
    stops=$((stops + 1))
  else
    if [ "$component" = systemd ] && [ "${MIGRATION_SKIP_SYSTEMD_ANALYZE:-0}" != 1 ] && command -v systemd-analyze >/dev/null 2>&1; then
      systemd-analyze verify "$source_file" >/dev/null || { printf 'STOP\t%s\t%s\tinstall\tsystemd-analyze verify failed\n' "$component" "$target" >> "$tmp"; stops=$((stops + 1)); continue; }
    fi
    printf 'PLAN\t%s\t%s\tinstall\towner=%s:%s mode=%s\n' "$component" "$target" "$uid" "$gid" "$mode_value" >> "$tmp"
  fi
done < <(awk 'BEGIN{FS="\t";OFS=sprintf("%c",28)}{$1=$1;print}' "$plan")

if [ "$stops" -gt 0 ]; then
  printf 'SUMMARY\t-\t-\t-\tstop_conditions=%d\n' "$stops" >> "$tmp"
  mv -- "$tmp" "$report"; trap - EXIT; exit 1
fi

if [ "$mode" = --apply ]; then
  need_root
  require_target_marker
  require_approval RESTORE_CONFIGS
  [ "${MIGRATION_SKIP_SYSTEMD_ANALYZE:-0}" = 0 ] || die 'systemd validation cannot be skipped in apply mode'
  [ -d "$journal" ] || install -d -m 0700 "$journal"
  require_tmpfs_path "$journal"
  install -d -m 0700 "$journal/files"
  while IFS=$'\034' read -r relative target action uid gid mode_value component; do
    [ "$relative" = staged_relative_path ] && continue
    [ "$action" = install ] || continue
    if [ -e "$target" ]; then cp -a --parents "$target" "$journal/files"; fi
  done < <(awk 'BEGIN{FS="\t";OFS=sprintf("%c",28)}{$1=$1;print}' "$plan")
  while IFS=$'\034' read -r relative target action uid gid mode_value component; do
    [ "$relative" = staged_relative_path ] && continue
    [ "$action" = install ] || continue
    install -d -m 0755 "$(dirname -- "$target")"
    cp -a -- "$staging/$relative" "$target"
    chown "$uid:$gid" "$target"
    chmod "$mode_value" "$target"
  done < <(awk 'BEGIN{FS="\t";OFS=sprintf("%c",28)}{$1=$1;print}' "$plan")

  command -v sshd >/dev/null && sshd -t
  command -v apache2ctl >/dev/null && apache2ctl configtest
  command -v postfix >/dev/null && postfix check
  command -v doveconf >/dev/null && doveconf -n >/dev/null
  command -v visudo >/dev/null && visudo -c >/dev/null
fi

printf 'SUMMARY\t-\t-\t%s\tstop_conditions=0\n' "$mode" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
note "configuration report: $report"
note 'rollback: restore target snapshot or reviewed files from the tmpfs journal before starting services'
