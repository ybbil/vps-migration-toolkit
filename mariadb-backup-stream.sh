#!/bin/bash
# מטרה: ליצור physical backup עקבי של MariaDB ולהזרים אותו ישירות ליעד המבודד.
# בטיחות: התאמת major.minor, source/target identity markers, SSH host-key קיים,
# archive חדש בלבד ואישור execute ייחודי.
# תוצאה רצויה: xbstream, SHA256 ו-COMPLETE שפורסם אחרון ביעד.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
option_file=${2:-}
target_host=${3:-}
remote_archive=${4:-}
report=${5:-}
case $mode in --preflight|--execute) ;; *) die "usage: $0 --preflight|--execute OPTION_FILE TARGET_SSH REMOTE_ARCHIVE REPORT" ;; esac
[ "$#" -eq 5 ] || die "usage: $0 MODE OPTION_FILE TARGET_SSH REMOTE_ARCHIVE REPORT"
for command in mariadb-backup mariadb ssh stat awk df du realpath mktemp; do need_cmd "$command"; done
need_file "$option_file"
safe_report_path "$report"
mode_bits=$(stat -c %a "$option_file")
case $mode_bits in 400|600|640) ;; *) die "unsafe backup option-file mode: $mode_bits" ;; esac
case $target_host in ''|*[!A-Za-z0-9._@-]*) die 'unsafe target SSH alias' ;; esac
[[ $remote_archive =~ ^/[A-Za-z0-9._/-]+\.xbstream$ ]] || die 'remote archive must be a safe absolute .xbstream path'
case "$remote_archive" in *'/../'*|*'/./'*|*'//'*) die 'remote archive path must be canonical' ;; esac

printf 'status\tcheck\tvalue\n' > "$report"
# שלב 1: בודקים גרסת שרת/כלי והרשאות option file.
backup_version=$(mariadb-backup --version 2>&1 | head -n 1)
server_version=$(mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e 'SELECT VERSION()' 2>>"$report")
grants=$(mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e 'SHOW GRANTS FOR CURRENT_USER' 2>>"$report")
grep -Eq 'GRANT ALL PRIVILEGES ON \*\.\*' <<< "$grants" && die 'backup account is over-privileged; use only SELECT, RELOAD, PROCESS, LOCK TABLES and BINLOG MONITOR'
global_grants=$(grep -E ' ON \*\.\* ' <<< "$grants" || true)
for required_grant in SELECT RELOAD PROCESS 'LOCK TABLES' 'BINLOG MONITOR'; do
  grep -Eq "GRANT .*($required_grant).*( ON |,)" <<< "$global_grants" || die "backup account lacks required global privilege: $required_grant"
done
if grep -Eq '\b(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|SUPER|FILE|SHUTDOWN|CREATE USER|GRANT OPTION)\b' <<< "$grants"; then
  die 'backup account has unnecessary mutation/administrative privileges'
fi
backup_mm=$(grep -oE '[0-9]+\.[0-9]+' <<< "$backup_version" | head -n1)
server_mm=$(grep -oE '^[0-9]+\.[0-9]+' <<< "$server_version")
[ -n "$backup_mm" ] && [ "$backup_mm" = "$server_mm" ] || die "MariaDB backup/server major.minor mismatch: backup=$backup_mm server=$server_mm"
# שלב 2: מתחברים רק ל-host key מוכר ומוודאים שזה יעד מסומן ושנתיב הפלט חדש.
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes)
remote_min_free_gib=${MARIADB_BACKUP_MIN_FREE_GIB:-20}
[[ $remote_min_free_gib =~ ^[0-9]+$ ]] || die 'MARIADB_BACKUP_MIN_FREE_GIB must be a non-negative integer'
backup_size_margin_percent=${MARIADB_BACKUP_SIZE_MARGIN_PERCENT:-25}
[[ $backup_size_margin_percent =~ ^[0-9]+$ ]] || die 'MARIADB_BACKUP_SIZE_MARGIN_PERCENT must be a non-negative integer'
source_datadir=$(mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e 'SELECT @@GLOBAL.datadir' 2>>"$report")
source_datadir=${source_datadir%/}
[ -d "$source_datadir" ] || die "MariaDB datadir is not readable as a directory: $source_datadir"
source_bytes=$(du -sB1 -- "$source_datadir" | awk '{print $1}')
[[ $source_bytes =~ ^[0-9]+$ ]] || die 'could not estimate physical backup size'
remote_required_bytes=$((source_bytes + (source_bytes * backup_size_margin_percent + 99) / 100 + remote_min_free_gib * 1024 * 1024 * 1024))
source_tmpdir=${MARIADB_BACKUP_TMPDIR:-/var/tmp}
[ "${source_tmpdir:0:1}" = / ] || die 'MARIADB_BACKUP_TMPDIR must be absolute'
source_tmpdir=$(canonical_existing_path "$source_tmpdir")
require_no_symlink_components "$source_tmpdir"
[ -d "$source_tmpdir" ] && [ -w "$source_tmpdir" ] || die "backup temporary directory is not writable: $source_tmpdir"
case $source_tmpdir in "$source_datadir"|"$source_datadir"/*) die 'backup temporary directory must not be inside MariaDB datadir' ;; esac
source_tmp_min_gib=${MARIADB_BACKUP_TMP_MIN_FREE_GIB:-2}
source_tmp_percent=${MARIADB_BACKUP_TMP_PERCENT:-10}
[[ $source_tmp_min_gib =~ ^[0-9]+$ && $source_tmp_percent =~ ^[0-9]+$ ]] || die 'backup temporary space settings must be non-negative integers'
source_tmp_required=$(((source_bytes * source_tmp_percent + 99) / 100 + source_tmp_min_gib * 1024 * 1024 * 1024))
source_tmp_available=$(df -PB1 "$source_tmpdir" | awk 'NR==2 {print $4}')
[ "$source_tmp_available" -ge "$source_tmp_required" ] || die "insufficient source temporary space: available=$source_tmp_available required=$source_tmp_required"
remote_parent=$(dirname -- "$remote_archive")
ssh "${ssh_opts[@]}" "$target_host" "set -eu; test -f /etc/vps-migration-target; grep -Fxq 'ISOLATED_VPS_MIGRATION_TARGET=YES' /etc/vps-migration-target; grep -Fxq \"HOSTNAME=\$(hostname -f)\" /etc/vps-migration-target; grep -Fxq \"MACHINE_ID=\$(cat /etc/machine-id)\" /etc/vps-migration-target; test -d '$remote_parent'; test -w '$remote_parent'; test ! -e '$remote_archive'; test ! -e '${remote_archive}.sha256'; test ! -e '${remote_archive}.COMPLETE'; test ! -e '${remote_archive}.lock'; available=\$(df -PB1 '$remote_parent' | awk 'NR==2 {print \$4}'); test \"\$available\" -ge '$remote_required_bytes'"
printf 'PASS\tbackup-version\t%s\nPASS\tserver-version\t%s\nPASS\tremote-path\t%s\n' \
  "$backup_version" "$server_version" "$remote_archive" > "$report"
printf 'PASS\tbackup-grants\tminimal SELECT, RELOAD, PROCESS, LOCK TABLES and BINLOG MONITOR present\n' >> "$report"
printf 'PASS\tsource-safety\tread-only hot stream; datadir-bytes=%s; no source archive\n' "$source_bytes" >> "$report"
printf 'PASS\tsource-temp-space\tpath=%s available=%s required=%s\nPASS\tremote-free-space\tavailable gate requires=%s estimated-backup=%s\n' "$source_tmpdir" "$source_tmp_available" "$source_tmp_required" "$remote_required_bytes" "$source_bytes" >> "$report"

[ "$mode" = --execute ] || { note "MariaDB backup preflight passed: $report"; exit 0; }
# שלב 3: Execute דורש marker של המקור ואישור מפורש; הפעולה עלולה ליצור עומס I/O.
require_source_marker
require_approval STREAM_MARIADB_BACKUP
note 'starting approved hot physical backup; source I/O and application latency must be monitored externally'
source_work=$(mktemp -d "$source_tmpdir/mariadb-backup-work.XXXXXX")
cleanup_source_work() { [ ! -e "$source_work" ] || cleanup_tree "$source_work" "$source_tmpdir/mariadb-backup-work."; }
trap cleanup_source_work EXIT
remote_token="$$.$RANDOM"
remote_partial="${remote_archive}.partial.${remote_token}"
if ! ssh "${ssh_opts[@]}" "$target_host" "set -eu; umask 077; mkdir '${remote_archive}.lock'; printf '%s\n' '$remote_token' > '${remote_archive}.lock/owner'; test ! -e '$remote_archive'; test ! -e '${remote_archive}.sha256'; test ! -e '${remote_archive}.COMPLETE'; (set -C; : > '$remote_partial')"; then
  printf 'FAIL\treservation\tarchive exists or another backup owns the lock\n' >> "$report"
  exit 1
fi
if ! mariadb-backup --defaults-extra-file="$option_file" --backup --stream=xbstream --tmpdir="$source_tmpdir" --target-dir="$source_work" |
  ssh "${ssh_opts[@]}" "$target_host" "set -eu; cat > '$remote_partial'"; then
  ssh "${ssh_opts[@]}" "$target_host" "set -eu; test \"\$(cat '${remote_archive}.lock/owner')\" = '$remote_token'; rm -f '${remote_archive}.lock/owner'; rmdir '${remote_archive}.lock'" || true
  printf 'FAIL\tstream\tfinal archive not published; quarantined partial=%s\n' "$remote_partial" >> "$report"
  exit 1
fi
if ! ssh "${ssh_opts[@]}" "$target_host" "set -eu; umask 077; test -d '${remote_archive}.lock'; test \"\$(cat '${remote_archive}.lock/owner')\" = '$remote_token'; test ! -e '$remote_archive'; test ! -e '${remote_archive}.sha256'; test ! -e '${remote_archive}.COMPLETE'; checksum=\$(sha256sum '$remote_partial' | awk '{print \$1}'); bytes=\$(stat -c %s '$remote_partial'); printf '%s  %s\n' \"\$checksum\" '$remote_archive' > '${remote_archive}.sha256.partial.${remote_token}'; printf 'FORMAT=VPS_MIGRATION_MARIADB_BACKUP_V1\nARCHIVE=%s\nSHA256=%s\nBYTES=%s\nTOKEN=%s\n' '$remote_archive' \"\$checksum\" \"\$bytes\" '$remote_token' > '${remote_archive}.COMPLETE.partial.${remote_token}'; ln '$remote_partial' '$remote_archive' || exit 1; ln '${remote_archive}.sha256.partial.${remote_token}' '${remote_archive}.sha256' || { rm -f '$remote_archive'; exit 1; }; ln '${remote_archive}.COMPLETE.partial.${remote_token}' '${remote_archive}.COMPLETE' || { rm -f '$remote_archive' '${remote_archive}.sha256'; exit 1; }; rm -f '$remote_partial' '${remote_archive}.sha256.partial.${remote_token}' '${remote_archive}.COMPLETE.partial.${remote_token}' '${remote_archive}.lock/owner'; rmdir '${remote_archive}.lock'"; then
  printf 'FAIL\tpublish\tatomic no-overwrite publication failed; inspect lock/partial\n' >> "$report"
  exit 1
fi
printf 'PASS\tstream\tcomplete\nPASS\tpublish\tarchive, checksum, then COMPLETE published without overwrite by lock owner\n' >> "$report"
# שלב 4: תוצאה רצויה היא archive אטומי עם checksum; partial נשאר quarantine במקרה כשל.
note 'rollback: no MariaDB source state was changed; quarantine or remove the remote partial/archive only with target approval'
