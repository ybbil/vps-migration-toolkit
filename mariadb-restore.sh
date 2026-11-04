#!/bin/bash
# מטרה: להכין ולהעתיק physical backup של MariaDB אל datadir ריק ביעד.
# בטיחות: יעד מזוהה, snapshot מאושר, שירות כבוי, checksum, גרסאות תואמות,
# prepared path מוגבל ונפח דיסק מינימלי; לעולם לא מוחקים datadir קיים.
# תוצאה רצויה: copy-back מלא כאשר MariaDB נשאר כבוי לבדיקה ידנית.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
archive=${2:-}
prepared=${3:-}
datadir=${4:-}
report=${5:-}
case $mode in --dry-run|--apply) ;; *) die "usage: $0 --dry-run|--apply ARCHIVE.xbstream PREPARED_DIR DATADIR REPORT" ;; esac
[ "$#" -eq 5 ] || die "usage: $0 MODE ARCHIVE PREPARED_DIR DATADIR REPORT"
for command in mariadb-backup mbstream mariadbd sha256sum systemctl stat df awk realpath du date pgrep fuser; do need_cmd "$command"; done
need_file "$archive"
need_file "${archive}.sha256"
need_file "${archive}.COMPLETE"
safe_report_path "$report"
archive=$(canonical_existing_path "$archive")
require_no_symlink_components "$archive"
require_no_symlink_components "${archive}.sha256"
require_no_symlink_components "${archive}.COMPLETE"
sha256sum -c "${archive}.sha256" >/dev/null
complete_format=$(sed -n 's/^FORMAT=//p' "${archive}.COMPLETE")
complete_archive=$(sed -n 's/^ARCHIVE=//p' "${archive}.COMPLETE")
complete_sha256=$(sed -n 's/^SHA256=//p' "${archive}.COMPLETE")
complete_bytes=$(sed -n 's/^BYTES=//p' "${archive}.COMPLETE")
complete_token=$(sed -n 's/^TOKEN=//p' "${archive}.COMPLETE")
[ "$complete_format" = VPS_MIGRATION_MARIADB_BACKUP_V1 ] || die 'invalid backup COMPLETE format'
[ "$complete_archive" = "$archive" ] || die 'backup COMPLETE archive path mismatch'
[[ $complete_sha256 =~ ^[0-9a-f]{64}$ ]] || die 'invalid backup COMPLETE SHA256'
[[ $complete_bytes =~ ^[0-9]+$ ]] || die 'invalid backup COMPLETE byte count'
[[ $complete_token =~ ^[A-Za-z0-9._-]+$ ]] || die 'invalid backup COMPLETE token'
[ "$complete_sha256" = "$(sha256sum "$archive" | awk '{print $1}')" ] || die 'backup COMPLETE SHA256 mismatch'
[ "$complete_bytes" -eq "$(stat -c %s "$archive")" ] || die 'backup COMPLETE byte count mismatch'
[ "$(awk 'NF {count++} END {print count+0}' "${archive}.COMPLETE")" -eq 5 ] || die 'backup COMPLETE has unexpected fields'
checksum_record=$(awk 'NF {print $1 " " $2; count++} END {if (count != 1) exit 1}' "${archive}.sha256") || die 'backup checksum file must contain exactly one record'
[ "$checksum_record" = "$complete_sha256 $archive" ] || die 'backup checksum record does not match COMPLETE'
[ "${prepared:0:1}" = / ] || die 'prepared path must be absolute'
[ "$prepared" = "$(realpath -m -- "$prepared")" ] || die 'prepared path must be canonical'
require_no_symlink_components "$prepared"
[ "$datadir" = /var/lib/mysql ] || die 'restore datadir must be explicitly /var/lib/mysql'
require_no_symlink_components "$datadir"
# שלב 1: prepared directory מותר רק באזור migration ייעודי, לא תחת /etc או datadir.
case $prepared in /var/tmp/mariadb-restore.*|/srv/vps-migration/mariadb-restore.*) ;; *) die 'prepared path must match /var/tmp/mariadb-restore.* or /srv/vps-migration/mariadb-restore.*' ;; esac
target_server_version=$(mariadbd --version 2>&1 | head -n1)
tool_version=$(mariadb-backup --version 2>&1 | head -n1)
target_mm=$(grep -oE '[0-9]+\.[0-9]+' <<< "$target_server_version" | head -n1)
tool_mm=$(grep -oE '[0-9]+\.[0-9]+' <<< "$tool_version" | head -n1)
[ -n "$target_mm" ] && [ "$target_mm" = "$tool_mm" ] || die "target MariaDB/backup tool major.minor mismatch: server=$target_mm tool=$tool_mm"
archive_bytes=$(stat -c %s "$archive")
available_bytes=$(df -PB1 "$(dirname -- "$prepared")" | awk 'NR==2 {print $4}')
minimum_free_gib=${MARIADB_RESTORE_MIN_FREE_GIB:-10}
[[ $minimum_free_gib =~ ^[0-9]+$ ]] || die 'MARIADB_RESTORE_MIN_FREE_GIB must be a non-negative integer'
minimum_free_bytes=$((minimum_free_gib * 1024 * 1024 * 1024))
required_bytes=$((archive_bytes * 3 + minimum_free_bytes))
[ "$available_bytes" -ge "$required_bytes" ] || die "insufficient free space for restore: available=$available_bytes required=$required_bytes"
printf 'status\tcheck\tdetail\nPASS\tarchive-checksum\tvalid\nPASS\tbackup-tool\t%s\n' "$(mariadb-backup --version 2>&1 | head -n1)" > "$report"
printf 'PASS\ttarget-server\t%s\nPASS\tfree-space\tavailable=%s required=%s\n' "$target_server_version" "$available_bytes" "$required_bytes" >> "$report"

# שלב 2: Dry-run מסתיים לפני extract; Restore trial מלא עדיין חובה לפני GO.
[ "$mode" = --apply ] || { note "MariaDB restore dry-run passed: $report"; exit 0; }
need_root
require_target_marker
require_approval RESTORE_MARIADB
snapshot_marker=${MIGRATION_SNAPSHOT_MARKER:-/run/vps-migration-snapshot-approved}
snapshot_max_age=${MIGRATION_SNAPSHOT_MAX_AGE_SECONDS:-86400}
[[ $snapshot_max_age =~ ^[0-9]+$ ]] || die 'MIGRATION_SNAPSHOT_MAX_AGE_SECONDS must be a non-negative integer'
require_fresh_snapshot_marker "$snapshot_marker" "$snapshot_max_age"
# שלב 3: מוודאים שהשירות כבוי ושה-datadir ריק; אין מחיקה אוטומטית.
systemctl is-active --quiet mariadb && die 'MariaDB must be stopped'
if pgrep -x mariadbd >/dev/null 2>&1 || pgrep -x mysqld >/dev/null 2>&1 ||
   pgrep -f '(^|/)(mariadbd|mysqld)([[:space:]]|$)' >/dev/null 2>&1; then
  die 'a MariaDB/MySQL server process is still running'
fi
if [ -e "$datadir" ] && fuser -s -- "$datadir"; then
  die 'a process is still using the MariaDB datadir'
fi
[ ! -e "$prepared" ] || die "prepared directory already exists: $prepared"
if [ -e "$datadir" ]; then
  [ -d "$datadir" ] || die 'datadir is not a directory'
  [ -z "$(find "$datadir" -mindepth 1 -maxdepth 1 -print -quit)" ] || die 'target datadir must be empty'
else
  install -d -o mysql -g mysql -m 0750 "$datadir"
fi
install -d -m 0700 "$prepared"
restore_phase=extract
report_restore_failure() {
  local exit_status=$?
  if [ "$exit_status" -ne 0 ]; then
    printf 'FAIL\t%s\trestore stopped before completion (rc=%s)\n' "$restore_phase" "$exit_status" >> "$report"
  fi
  return "$exit_status"
}
trap report_restore_failure EXIT
# שלב 4: extract וגרסת backup נבדקים לפני prepare/copy-back.
mbstream -x -C "$prepared" < "$archive"
extracted_bytes=$(du -sB1 -- "$prepared" | awk '{print $1}')
prepare_available=$(df -PB1 "$prepared" | awk 'NR==2 {print $4}')
datadir_available=$(df -PB1 "$datadir" | awk 'NR==2 {print $4}')
prepare_device=$(stat -c %d "$prepared")
datadir_device=$(stat -c %d "$datadir")
prepare_overhead_percent=${MARIADB_PREPARE_OVERHEAD_PERCENT:-25}
[[ $prepare_overhead_percent =~ ^[0-9]+$ ]] || die 'MARIADB_PREPARE_OVERHEAD_PERCENT must be a non-negative integer'
prepare_overhead=$(((extracted_bytes * prepare_overhead_percent + 99) / 100))
prepare_required=$((prepare_overhead + minimum_free_bytes))
datadir_required=$((extracted_bytes + minimum_free_bytes))
if [ "$prepare_device" = "$datadir_device" ]; then
  prepare_required=$((prepare_overhead + extracted_bytes + minimum_free_bytes))
  datadir_required=$prepare_required
fi
[ "$prepare_available" -ge "$prepare_required" ] || die "insufficient prepared-filesystem space after extract: available=$prepare_available required=$prepare_required"
[ "$datadir_available" -ge "$datadir_required" ] || die "insufficient datadir-filesystem space after extract: available=$datadir_available required=$datadir_required"
printf 'PASS\textracted-size\tbytes=%s\nPASS\tprepared-filesystem-space\tavailable=%s required=%s\nPASS\tdatadir-filesystem-space\tavailable=%s required=%s\n' "$extracted_bytes" "$prepare_available" "$prepare_required" "$datadir_available" "$datadir_required" >> "$report"
need_file "$prepared/xtrabackup_info"
backup_version=$(awk -F'= ' '/^tool_version/ {print $2; exit}' "$prepared/xtrabackup_info")
backup_mm=$(grep -oE '[0-9]+\.[0-9]+' <<< "$backup_version" | head -n1)
[ -n "$backup_mm" ] && [ "$backup_mm" = "$tool_mm" ] || die "backup/restore tool major.minor mismatch: backup=$backup_mm tool=$tool_mm"
restore_phase=prepare
mariadb-backup --prepare --target-dir="$prepared" >> "$report" 2>&1
restore_phase=copy-back
mariadb-backup --copy-back --target-dir="$prepared" >> "$report" 2>&1
chown -R mysql:mysql "$datadir"
# שלב 5: התוצאה הרצויה היא datadir משוחזר והשירות עדיין כבוי.
printf 'PASS\tcopy-back\tcomplete; server remains stopped\nPENDING\trestore-trial\trequires isolated server start, verify-mariadb comparison, application read/write tests, and shutdown\n' >> "$report"
restore_phase=complete
trap - EXIT
note 'rollback: keep MariaDB stopped and restore the target snapshot or the package-empty datadir; never run this script on the source'
