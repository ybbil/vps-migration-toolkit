#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: העתקת staging לנתיבי היעד.
# בטיחות: יציאה בקוד 64 מונעת overwrite ללא rollback מקומי אמין.
# תוצאה רצויה: rsync ישיר ומבוקר מהיעד לפי OPERATIONS.md.
printf 'RETIRED: restore-files.sh must not be run; use the reviewed direct rsync procedure.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
staging=${2:-}
roots=${3:-}
report=${4:-}
case $mode in --dry-run|--apply) ;; *) die "usage: $0 --dry-run|--apply STAGING_ROOT ROOTS.tsv REPORT" ;; esac
[ "$#" -eq 4 ] || die "usage: $0 --dry-run|--apply STAGING_ROOT ROOTS.tsv REPORT"
need_cmd rsync
rsync --version | grep -q 'ACLs' || die 'rsync lacks ACL support'
rsync --version | grep -q 'xattrs' || die 'rsync lacks xattr support'
need_dir "$staging"
need_file "$roots"
safe_report_path "$report"
if [ "$mode" = --apply ]; then
  need_root
  require_target_marker
  require_approval RESTORE_FILES
fi

tmp=$(mktemp "${report}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf 'status\tsource\tdestination\tmode\tdetail\n' > "$tmp"
flags=(-aHAX --numeric-ids --itemize-changes --protect-args)
[ "$mode" = --apply ] || flags+=(-n)

while IFS=$'\034' read -r source_path class restore_path mutable excludes; do
  [ "$source_path" = source_path ] && continue
  source_tree="$staging/${source_path#/}"
  [ -e "$source_tree" ] || die "staged root missing: $source_tree"
  while IFS= read -r source_uid; do getent passwd "$source_uid" >/dev/null || die "target UID missing: $source_uid ($source_tree)"; done < <(find "$source_tree" -xdev -printf '%U\n' | sort -nu)
  while IFS= read -r source_gid; do getent group "$source_gid" >/dev/null || die "target GID missing: $source_gid ($source_tree)"; done < <(find "$source_tree" -xdev -printf '%G\n' | sort -nu)
  case $restore_path in /|/etc|/usr|/var|/home|/opt|/srv) die "restore_path too broad: $restore_path" ;; esac
  install_parent=$(dirname -- "$restore_path")
  [ -d "$install_parent" ] || { [ "$mode" = --dry-run ] || install -d -m 0755 "$install_parent"; }
  if [ -d "$source_tree" ]; then
    rsync "${flags[@]}" "$source_tree/" "$restore_path/" >> "$tmp" 2>&1
  else
    rsync "${flags[@]}" "$source_tree" "$restore_path" >> "$tmp" 2>&1
  fi
  printf 'PASS\t%s\t%s\t%s\tmetadata-preserving rsync; no --delete\n' "$source_tree" "$restore_path" "$mode" >> "$tmp"
done < <(awk 'BEGIN{FS="\t";OFS=sprintf("%c",28)}{$1=$1;print}' "$roots")

printf 'SUMMARY\t-\t-\t%s\tcomplete\n' "$mode" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
note "restore report: $report"
note 'rollback: restore the provider snapshot; reverse rsync is intentionally unsupported'
