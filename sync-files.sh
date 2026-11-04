#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: target-pull אל staging.
# בטיחות: יציאה בקוד 64 מונעת מסלול כפול ותלות במצב staging קודם.
# תוצאה רצויה: rsync ישיר שנבדק עם -n, roots מפורשים וללא --delete.
printf 'RETIRED: sync-files.sh must not be run; use the reviewed direct target-pull rsync procedure.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
source_host=${2:-}
roots=${3:-}
staging=${4:-}
report=${5:-}
case $mode in --dry-run|--apply-initial|--apply-final) ;; *) die "usage: $0 --dry-run|--apply-initial|--apply-final SOURCE_SSH ROOTS.tsv STAGING_ROOT REPORT" ;; esac
[ "$#" -eq 5 ] || die "usage: $0 MODE SOURCE_SSH ROOTS.tsv STAGING_ROOT REPORT"
need_cmd rsync
rsync --version | grep -q 'ACLs' || die 'rsync lacks ACL support'
rsync --version | grep -q 'xattrs' || die 'rsync lacks xattr support'
need_file "$roots"
need_dir "$staging"
safe_report_path "$report"
[ "$(head -n 1 "$roots")" = $'source_path\tclass\trestore_path\tmutable\texcludes' ] || die 'invalid roots header'
case $source_host in ''|*[!A-Za-z0-9._@-]*) die 'unsafe SOURCE_SSH alias' ;; esac

if [ "$mode" != --dry-run ]; then
  require_target_marker
  require_approval SYNC_FILES_TO_STAGING
fi

tmp=$(mktemp "${report}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf 'status\troot\tclass\tmode\tdetail\n' > "$tmp"
rsync_flags=(-aHAX --numeric-ids --relative --itemize-changes --protect-args)
[ "$mode" != --dry-run ] || rsync_flags+=(-n)
[ "$mode" = --dry-run ] || rsync_flags+=(--partial)

while IFS=$'\034' read -r source_path class restore_path mutable excludes; do
  [ "$source_path" = source_path ] && continue
  case $source_path in /*) ;; *) die "source path must be absolute: $source_path" ;; esac
  case $restore_path in /*) ;; *) die "restore path must be absolute: $restore_path" ;; esac
  case $source_path in /var/lib/mysql|/var/lib/mysql/*) die 'physical MariaDB files must never use rsync' ;; esac
  [ "$mutable" = yes ] || [ "$mutable" = no ] || die "invalid mutable value: $mutable"
  exclude_args=()
  if [ -n "$excludes" ]; then
    IFS=';' read -r -a exclude_values <<< "$excludes"
    for pattern in "${exclude_values[@]}"; do exclude_args+=(--exclude "$pattern"); done
  fi
  remote_path="$source_host:/./${source_path#/}"
  if rsync "${rsync_flags[@]}" "${exclude_args[@]}" --rsync-path='sudo -n rsync' "$remote_path" "$staging/" >> "$tmp" 2>&1; then
    printf 'PASS\t%s\t%s\t%s\trsync completed\n' "$source_path" "$class" "$mode" >> "$tmp"
  else
    printf 'FAIL\t%s\t%s\t%s\trsync failed; staging is incomplete\n' "$source_path" "$class" "$mode" >> "$tmp"
    mv -- "$tmp" "$report"
    trap - EXIT
    exit 1
  fi
done < <(awk 'BEGIN{FS="\t";OFS=sprintf("%c",28)}{$1=$1;print}' "$roots")

printf 'SUMMARY\t-\t-\t%s\tcomplete; no --delete used\n' "$mode" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
note "file synchronization report: $report"
note 'rollback: discard the staging tree or restore the target snapshot; this script never writes back to the source'
