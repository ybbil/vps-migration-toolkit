#!/bin/bash
# מטרה: בדיקת מבנה סטטית לערכת ההעברה.
# בטיחות: אינו מפעיל Apply; הוא כותב רק toolkit-validation.txt בפרויקט.
# תוצאה רצויה: syntax תקין, artifacts קיימים, retired guards קיימים ו-SUMMARY failures=0.
set -euo pipefail
set +x
umask 077

toolkit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
report="$toolkit/toolkit-validation.txt"
tmp=$(mktemp "$toolkit/.toolkit-validation.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
failures=0
pass() { printf 'PASS\t%s\n' "$*" >> "$tmp"; }
fail() { printf 'FAIL\t%s\n' "$*" >> "$tmp"; failures=$((failures + 1)); }

for script in "$toolkit"/*.sh "$toolkit"/lib/*.sh "$toolkit"/tests/*.sh; do
  bash -n "$script" && pass "bash syntax: ${script#"$toolkit/"}" || fail "bash syntax: $script"
done

awk -F'\t' 'NF!=7{bad++} END{exit bad}' "$toolkit/coverage-matrix.tsv" && pass 'coverage matrix has exactly 7 columns' || fail 'coverage matrix column mismatch'
[ "$(head -n1 "$toolkit/coverage-matrix.tsv")" = $'component\tsource\texport_or_backup\trestore\tvalidation\timplementation_status\tremaining_gate' ] && pass 'coverage matrix header' || fail 'coverage matrix header'

for required in OPERATIONS.md EXECUTION-GUIDE.md OPEN-GAPS.md coverage-matrix.tsv export-linux-identities.sh import-linux-identities.sh export-package-inventory.sh restore-apt-sources.sh restore-packages.sh compare-package-inventory.sh sync-files.sh restore-files.sh generate-content-manifest.sh compare-content-manifests.sh restore-project-dependencies.sh mariadb-backup-stream.sh mariadb-restore.sh verify-mariadb.sh mail-migration.sh export-secrets.sh restore-secrets.sh restore-automation.sh restore-security-policy.sh verify-restored-system.sh; do
  [ -s "$toolkit/$required" ] && pass "required artifact: $required" || fail "missing artifact: $required"
done

for retired in build-config-plan.sh export-secrets.sh mail-migration.sh restore-apt-sources.sh restore-automation.sh restore-configs.sh restore-files.sh restore-project-dependencies.sh restore-secrets.sh restore-security-policy.sh sync-files.sh; do
  if sed -n '1,8p' "$toolkit/$retired" | grep -Fq 'RETIRED' && sed -n '1,8p' "$toolkit/$retired" | grep -Eq '^exit 64$'; then
    pass "retired guard: $retired"
  else
    fail "missing retired guard: $retired"
  fi
done

if rg -n '^[[:space:]]*(rm[[:space:]]+-rf|rsync .*--delete|ufw[[:space:]]+disable)|PermitRootLogin[[:space:]]+yes' "$toolkit" --glob '*.sh' >/dev/null; then
  fail 'forbidden destructive or access-opening command detected'
else
  pass 'no forbidden rm -rf/rsync --delete/root-login/ufw-disable command'
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=error "$toolkit"/*.sh "$toolkit"/lib/*.sh "$toolkit"/tests/*.sh &&
     shellcheck --severity=warning \
       "$toolkit/lib/common.sh" \
       "$toolkit/mariadb-backup-stream.sh" \
       "$toolkit/mariadb-restore.sh" \
       "$toolkit/verify-mariadb.sh" \
       "$toolkit/tests/test-mariadb-safety.sh"; then
    pass 'ShellCheck: repository has no errors; MariaDB/common safety scope has no warnings'
  else
    fail 'ShellCheck'
  fi
else
  printf 'SKIP\tShellCheck unavailable; no installation performed\n' >> "$tmp"
fi

printf 'SUMMARY\tfailures=%d\n' "$failures" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
printf 'Toolkit validation: %s; failures=%d\n' "$report" "$failures"
if [ "$failures" -gt 0 ]; then exit 1; fi
