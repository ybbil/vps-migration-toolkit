#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: התקנת secret payload.
# בטיחות: יציאה בקוד 64 משום שאימות הנתיבים הישן אינו מספק.
# תוצאה רצויה: התקנה ידנית מ-tmpfs, קובץ-אחר-קובץ, עם owner/mode.
printf 'RETIRED: restore-secrets.sh must not be run; use the approved manual tmpfs restore procedure.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
stage=${2:-}
report=${3:-}
journal=${4:-}
case $mode in
  --dry-run) [ "$#" -eq 3 ] || die "usage: $0 --dry-run DECRYPTED_TMPFS_STAGE REPORT" ;;
  --apply) [ "$#" -eq 4 ] || die "usage: $0 --apply DECRYPTED_TMPFS_STAGE REPORT TMPFS_JOURNAL" ;;
  *) die "usage: $0 --dry-run STAGE REPORT | --apply STAGE REPORT JOURNAL" ;;
esac
require_tmpfs_path "$stage"
need_file "$stage/SHA256SUMS"
need_file "$stage/metadata.tsv"
safe_report_path "$report"
(
  cd "$stage"
  sha256sum -c SHA256SUMS >/dev/null
)

tmp=$(mktemp "${report}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf 'status\tpath\texpected_metadata\ttarget_state\taction\n' > "$tmp"
stops=0
while IFS=$'\t' read -r path uid gid mode_value action; do
  [ "$path" = path ] && continue
  source_file="$stage/files$path"
  [ -f "$source_file" ] || { printf 'STOP\t%s\t-\tMISSING\tpayload-file-missing\n' "$path" >> "$tmp"; stops=$((stops + 1)); continue; }
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $mode_value =~ ^[0-7]{3,4}$ ]] || die "invalid metadata for $path"
  if [ -e "$path" ]; then target_state=$(stat -c '%u:%g:%a' "$path"); else target_state=MISSING; fi
  printf 'PLAN\t%s\t%s:%s:%s\t%s\tinstall-after-owner-exists\n' "$path" "$uid" "$gid" "$mode_value" "$target_state" >> "$tmp"
done < "$stage/metadata.tsv"

if [ "$stops" -gt 0 ]; then
  printf 'SUMMARY\t-\t-\t-\tstop_conditions=%d\n' "$stops" >> "$tmp"
  mv -- "$tmp" "$report"; trap - EXIT; exit 1
fi

if [ "$mode" = --apply ]; then
  need_root
  require_target_marker
  require_approval RESTORE_SECRETS
  [ -d "$journal" ] || install -d -m 0700 "$journal"
  require_tmpfs_path "$journal"
  install -d -m 0700 "$journal/files"
  : > "$journal/created-paths"
  printf 'started=%s\n' "$(date --iso-8601=seconds)" > "$journal/APPLY_STARTED"
  while IFS=$'\t' read -r path uid gid mode_value action; do
    [ "$path" = path ] && continue
    getent passwd "$uid" >/dev/null || die "target UID missing for secret: $path ($uid)"
    getent group "$gid" >/dev/null || die "target GID missing for secret: $path ($gid)"
    if [ -e "$path" ]; then cp -a --parents "$path" "$journal/files"; else printf '%s\n' "$path" >> "$journal/created-paths"; fi
  done < "$stage/metadata.tsv"
  while IFS=$'\t' read -r path uid gid mode_value action; do
    [ "$path" = path ] && continue
    install -d -m 0750 "$(dirname -- "$path")"
    cp -a -- "$stage/files$path" "$path"
    chown "$uid:$gid" "$path"
    chmod "$mode_value" "$path"
  done < "$stage/metadata.tsv"
fi

printf 'SUMMARY\t-\t-\t-\tstop_conditions=0;mode=%s\n' "$mode" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
note "secrets restore report: $report"
note 'rollback: restore the target snapshot or approved files from the tmpfs journal before any service starts'
