#!/bin/bash
# מטרה: להפיק מדדי MariaDB קלים, ובמצב מפורש גם בדיקות מלאות וכבדות.
# בטיחות: במקור COUNT(*) ו-mariadb-check אסורים ללא --source-heavy ואישור נפרד.
# מידע רגיש: SHOW CREATE USER ו-SHOW GRANTS עוברים hashing בזיכרון ואינם נשמרים גולמיים.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

scope=${1:-}
option_file=${2:-}
report=${3:-}
[ "$#" -eq 3 ] || die "usage: $0 --source-light|--source-heavy|--target OPTION_FILE REPORT.tsv"
heavy=no
case $scope in
  --source-light) require_source_marker; require_approval AUDIT_MARIADB_SOURCE_LIGHT ;;
  --source-heavy) require_source_marker; require_approval AUDIT_MARIADB_SOURCE_HEAVY; heavy=yes ;;
  --target) require_target_marker; heavy=yes ;;
  *) die "usage: $0 --source-light|--source-heavy|--target OPTION_FILE REPORT.tsv" ;;
esac
need_file "$option_file"
safe_report_path "$report"
for suffix in table-metrics.tsv accounts.tsv account-fingerprints.tsv exact-row-counts.tsv row-counts.sql mariadb-check.txt sha256; do
  safe_report_path "${report}.${suffix}"
done
for command in mariadb mariadb-admin sha256sum; do need_cmd "$command"; done
[ "$heavy" = no ] || need_cmd mariadb-check
case $(stat -c %a "$option_file") in 400|600|640) ;; *) die 'unsafe MariaDB option-file mode' ;; esac
mariadb-admin --defaults-extra-file="$option_file" ping >/dev/null

printf 'metric\tvalue\nmode\t%s\n' "$scope" > "$report"
queries=(
  'schemas|SELECT COUNT(*) FROM information_schema.SCHEMATA'
  "base_tables|SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_TYPE='BASE TABLE' AND TABLE_SCHEMA NOT IN ('information_schema','performance_schema','sys')"
  "views|SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','sys')"
  "routines|SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA NOT IN ('information_schema','performance_schema','sys')"
  "triggers|SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA NOT IN ('information_schema','performance_schema','sys')"
  "events|SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA NOT IN ('information_schema','performance_schema','sys')"
  'accounts|SELECT COUNT(*) FROM mysql.user'
)
for item in "${queries[@]}"; do
  name=${item%%|*}; sql=${item#*|}
  value=$(mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e "$sql")
  printf '%s\t%s\n' "$name" "$value" >> "$report"
done
mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e \
  "SELECT TABLE_SCHEMA,TABLE_NAME,COALESCE(DATA_LENGTH,0),COALESCE(INDEX_LENGTH,0) FROM information_schema.TABLES WHERE TABLE_TYPE='BASE TABLE' AND TABLE_SCHEMA NOT IN ('information_schema','performance_schema','sys') ORDER BY TABLE_SCHEMA,TABLE_NAME" \
  > "${report}.table-metrics.tsv"
mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e \
  "SELECT CONCAT(QUOTE(User),'@',QUOTE(Host)) FROM mysql.user ORDER BY User,Host" > "${report}.accounts.tsv"
: > "${report}.account-fingerprints.tsv"
while IFS= read -r account; do
  [ -n "$account" ] || continue
  create_hash=$(mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e "SHOW CREATE USER $account" | sha256sum | awk '{print $1}')
  grants_hash=$(mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e "SHOW GRANTS FOR $account" | LC_ALL=C sort | sha256sum | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$account" "$create_hash" "$grants_hash" >> "${report}.account-fingerprints.tsv"
done < "${report}.accounts.tsv"

if [ "$heavy" = yes ]; then
  mariadb --defaults-extra-file="$option_file" --batch --skip-column-names -e \
    "SELECT CONCAT('SELECT ', QUOTE(TABLE_SCHEMA), ',', QUOTE(TABLE_NAME), ',COUNT(*) FROM \`', REPLACE(TABLE_SCHEMA,'\`','\`\`'), '\`.\`', REPLACE(TABLE_NAME,'\`','\`\`'), '\`;') FROM information_schema.TABLES WHERE TABLE_TYPE='BASE TABLE' AND TABLE_SCHEMA NOT IN ('information_schema','performance_schema','sys') ORDER BY TABLE_SCHEMA,TABLE_NAME" \
    > "${report}.row-counts.sql"
  mariadb --defaults-extra-file="$option_file" --batch --skip-column-names < "${report}.row-counts.sql" > "${report}.exact-row-counts.tsv"
  mariadb-check --defaults-extra-file="$option_file" --all-databases --check > "${report}.mariadb-check.txt"
else
  printf 'SKIPPED\texact-row-counts\trequires --source-heavy and separate approval\nSKIPPED\tmariadb-check\trequires --source-heavy and separate approval\n' >> "$report"
fi

hash_files=("$report" "${report}.table-metrics.tsv" "${report}.accounts.tsv" "${report}.account-fingerprints.tsv")
if [ "$heavy" = yes ]; then hash_files+=("${report}.exact-row-counts.tsv" "${report}.mariadb-check.txt"); fi
sha256sum "${hash_files[@]}" > "${report}.sha256"
chmod 0600 "$report" "${report}."*
note 'MariaDB validation complete; raw authentication clauses and grants were not persisted'
