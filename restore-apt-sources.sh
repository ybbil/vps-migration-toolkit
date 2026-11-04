#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: העתקת sources ו-keyrings.
# בטיחות: יציאה בקוד 64 מונעת העתקה עיוורת בין גרסאות OS.
# תוצאה רצויה: repositories מוגדרים ידנית ומתאימים ליעד.
printf 'RETIRED: restore-apt-sources.sh must not be run; configure target repositories manually.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
inventory=${2:-}
report=${3:-}
journal=${4:-}
case $mode in
  --dry-run) [ "$#" -eq 3 ] || die "usage: $0 --dry-run INVENTORY REPORT" ;;
  --apply) [ "$#" -eq 4 ] || die "usage: $0 --apply INVENTORY REPORT TMPFS_JOURNAL" ;;
  *) die "usage: $0 --dry-run INVENTORY REPORT | --apply INVENTORY REPORT JOURNAL" ;;
esac
need_dir "$inventory/etc/apt"
need_file "$inventory/SHA256SUMS"
safe_report_path "$report"
(
  cd "$inventory"
  sha256sum -c SHA256SUMS >/dev/null
)
printf 'status\tpath\ttarget_state\taction\n' > "$report"
stops=0
while IFS= read -r source_file; do
  target_file=${source_file#"$inventory"}
  case $target_file in /etc/apt/auth.conf|/etc/apt/auth.conf.d/*) die 'APT authentication files must use the encrypted secrets path' ;; esac
  if [ -e "$target_file" ] && cmp -s "$source_file" "$target_file"; then state=identical; action=none; else state=$([ -e "$target_file" ] && printf different || printf missing); action=install; fi
  printf 'PLAN\t%s\t%s\t%s\n' "$target_file" "$state" "$action" >> "$report"
done < <(find "$inventory/etc/apt" -type f -print)

for target_root in /etc/apt/sources.list.d /etc/apt/preferences.d /etc/apt/keyrings; do
  [ -d "$target_root" ] || continue
  while IFS= read -r target_file; do
    relative=${target_file#/}
    if [ ! -f "$inventory/$relative" ]; then
      printf 'STOP\t%s\ttarget-only\treview/remove-or-keep-explicitly\n' "$target_file" >> "$report"
      stops=$((stops + 1))
    fi
  done < <(find "$target_root" -type f -print)
done

if [ "$stops" -gt 0 ]; then printf 'SUMMARY\t-\t-\tstop_conditions=%d\n' "$stops" >> "$report"; exit 1; fi
if [ "$mode" = --apply ]; then
  need_root
  require_target_marker
  require_approval RESTORE_APT_SOURCES
  [ -d "$journal" ] || install -d -m 0700 "$journal"
  require_tmpfs_path "$journal"
  install -d -m 0700 "$journal/files"
  for target_root in /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/preferences.d /etc/apt/keyrings; do
    if [ -e "$target_root" ]; then cp -a --parents "$target_root" "$journal/files"; fi
  done
  while IFS= read -r source_file; do
    target_file=${source_file#"$inventory"}
    install -d -m 0755 "$(dirname -- "$target_file")"
    cp -a -- "$source_file" "$target_file"
  done < <(find "$inventory/etc/apt" -type f -print)
  apt-get update
fi
printf 'SUMMARY\t-\t-\tstop_conditions=0;mode=%s\n' "$mode" >> "$report"
note 'rollback: restore the target snapshot or /etc/apt from the tmpfs journal, then run apt-get update again'
