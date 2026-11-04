#!/bin/bash
# מטרה: לבדוק חוזים, guards ו-Dry-run באמצעות נתונים סינתטיים בלבד.
# בטיחות: אין Apply/Execute; כל staging תחת /tmp או /dev/shm ונמחק בסיום.
# תוצאה רצויה: כל PASS צפוי וכל פעולה מסוכנת/retired נכשלת כמתוכנן.
set -euo pipefail
set +x
umask 077

toolkit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
report="$toolkit/test-results.txt"
tmp_root=$(mktemp -d /tmp/vps-migration-fixtures.XXXXXX)
identity_stage=$(mktemp -d /dev/shm/vps-migration-identity-fixture.XXXXXX)
secret_stage=$(mktemp -d /dev/shm/vps-migration-secret-fixture.XXXXXX)
cleanup() {
  find "$tmp_root" -depth -delete
  find "$identity_stage" -depth -delete
  find "$secret_stage" -depth -delete
}
trap cleanup EXIT
printf 'status\ttest\tdetail\n' > "$report"

pass() { printf 'PASS\t%s\t%s\n' "$1" "$2" >> "$report"; }
fail() { printf 'FAIL\t%s\t%s\n' "$1" "$2" >> "$report"; exit 1; }
expect_failure() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "$name" 'unexpected success'; else pass "$name" 'expected non-zero exit'; fi
}

for script in "$toolkit"/*.sh "$toolkit"/lib/*.sh; do bash -n "$script" || fail bash-syntax "$script"; done
pass bash-syntax 'all toolkit scripts'

bash "$toolkit/tests/test-hostinger-firewall.sh" >/dev/null
pass hostinger-firewall 'mock success/rerun, CSV VPS isolation, unassigned export, duplicate, strict management coverage/anti-any, sync-polling, disconnect and partial-failure recovery guards'

cp -a "$toolkit/tests/fixtures/identity/." "$identity_stage/"
(
  cd "$identity_stage"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
bash "$toolkit/validate-identity-payload.sh" "$identity_stage" >/dev/null
pass identity-contract 'export/import payload schemas and checksums agree'

# בדיקת בטיחות: marker חייב להיות קשור ל-hostname ול-machine-id הנוכחיים.
bad_marker="$tmp_root/bad-target-marker"
printf 'ISOLATED_VPS_MIGRATION_TARGET=YES\nHOSTNAME=wrong.invalid\nMACHINE_ID=wrong\n' > "$bad_marker"
expect_failure target-marker-binding env MIGRATION_TARGET_MARKER="$bad_marker" bash -c '. "$1"; require_target_marker' _ "$toolkit/lib/common.sh"
good_marker="$tmp_root/good-target-marker"
printf 'ISOLATED_VPS_MIGRATION_TARGET=YES\nHOSTNAME=%s\nMACHINE_ID=%s\n' "$(hostname -f)" "$(cat /etc/machine-id)" > "$good_marker"
MIGRATION_TARGET_MARKER="$good_marker" MIGRATION_SOURCE_MARKER="$tmp_root/no-source-marker" bash -c '. "$1"; require_target_marker' _ "$toolkit/lib/common.sh"
pass target-marker-positive 'hostname and machine-id binding accepted only when exact'

# common.sh: אישור קשור לפעולה ולשרת, וסימון כפול מקור/יעד חוסם שינוי.
approval_file="$tmp_root/approval"
printf 'APPROVED=YES\nACTION=FIXTURE_ACTION\nHOSTNAME=%s\nMACHINE_ID=%s\n' "$(hostname -f)" "$(cat /etc/machine-id)" > "$approval_file"
chmod 0600 "$approval_file"
MIGRATION_APPROVAL=FIXTURE_ACTION MIGRATION_APPROVAL_FILE="$approval_file" bash -c '. "$1"; require_approval FIXTURE_ACTION' _ "$toolkit/lib/common.sh"
pass scoped-approval 'action, hostname, machine-id and protected approval file accepted'
expect_failure scoped-approval-wrong-action env MIGRATION_APPROVAL=OTHER MIGRATION_APPROVAL_FILE="$approval_file" bash -c '. "$1"; require_approval OTHER' _ "$toolkit/lib/common.sh"

source_marker="$tmp_root/source-marker"
printf 'ACTIVE_VPS_MIGRATION_SOURCE=YES\nHOSTNAME=%s\nMACHINE_ID=%s\n' "$(hostname -f)" "$(cat /etc/machine-id)" > "$source_marker"
expect_failure dual-role-rejected env MIGRATION_SOURCE_MARKER="$source_marker" MIGRATION_TARGET_MARKER="$good_marker" bash -c '. "$1"; require_target_marker' _ "$toolkit/lib/common.sh"

report_parent="$tmp_root/report-parent"
install -d "$report_parent"
MIGRATION_REPORT="$report_parent/new.tsv" bash -c '. "$1"; safe_report_path "$MIGRATION_REPORT"' _ "$toolkit/lib/common.sh"
: > "$report_parent/existing.tsv"
expect_failure report-no-overwrite env MIGRATION_REPORT="$report_parent/existing.tsv" bash -c '. "$1"; safe_report_path "$MIGRATION_REPORT"' _ "$toolkit/lib/common.sh"
ln -s /tmp "$report_parent/link"
expect_failure report-symlink-component env MIGRATION_REPORT="$report_parent/link/report.tsv" bash -c '. "$1"; safe_report_path "$MIGRATION_REPORT"' _ "$toolkit/lib/common.sh"
pass common-path-guards 'report overwrite and symlink traversal rejected'

cleanup_fixture="$tmp_root/cleanup.fixture"
install -d "$cleanup_fixture"
printf 'fixture\n' > "$cleanup_fixture/file"
CLEANUP_FIXTURE="$cleanup_fixture" CLEANUP_PREFIX="$tmp_root/cleanup." bash -c '. "$1"; cleanup_tree "$CLEANUP_FIXTURE" "$CLEANUP_PREFIX"' _ "$toolkit/lib/common.sh"
[ ! -e "$cleanup_fixture" ] || fail cleanup-tree 'fixture tree remained'
pass cleanup-tree 'canonical scoped tree removed without following symlinks'

# בדיקת בטיחות: payload שמכיל sudo fragment נדחה.
sudo_negative=$(mktemp -d /dev/shm/vps-migration-sudo-negative.XXXXXX)
cp -a "$identity_stage/." "$sudo_negative/"
install -d "$sudo_negative/files/etc/sudoers.d"
printf 'zzmigfixture ALL=(ALL) NOPASSWD: ALL\n' > "$sudo_negative/files/etc/sudoers.d/unsafe"
(
  cd "$sudo_negative"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
expect_failure sudo-payload-rejected bash "$toolkit/validate-identity-payload.sh" "$sudo_negative"
find "$sudo_negative" -depth -delete

# בדיקת בטיחות: authorized_keys לחשבון package-verify נדחה.
ssh_negative=$(mktemp -d /dev/shm/vps-migration-ssh-negative.XXXXXX)
cp -a "$identity_stage/." "$ssh_negative/"
sed -i 's/custom-create/package-verify/g' "$ssh_negative/allowlist.tsv" "$ssh_negative/identity/selection.tsv"
(
  cd "$ssh_negative"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
expect_failure package-account-ssh-rejected bash "$toolkit/validate-identity-payload.sh" "$ssh_negative"
find "$ssh_negative" -depth -delete

if getent passwd zzmigfixture >/dev/null || getent group zzmigfixturegrp >/dev/null || getent passwd 59990 >/dev/null || getent group 59990 >/dev/null; then
  fail identity-fixture-preflight 'synthetic identity or numeric ID collides with host'
fi
bash "$toolkit/plan-linux-identity-import.sh" "$identity_stage" "$tmp_root/identity-plan.tsv" >/dev/null
pass identity-dry-run 'synthetic custom identity planned without mutation'

# Dry-run מבודד ל-Exporter: getent ו-age מזויפים; אין קריאת זהויות אמיתיות ואין הצפנה.
identity_fakebin="$tmp_root/identity-fakebin"
install -d "$identity_fakebin"
printf '#!/bin/sh\nexit 0\n' > "$identity_fakebin/age"
printf '#!/bin/sh\ncase "$1:$2" in passwd:zzmigfixture) echo "zzmigfixture:x:59990:59990:Fixture:/home/zzmigfixture:/bin/bash";; group:zzmigfixturegrp) echo "zzmigfixturegrp:x:59990:";; *) exit 2;; esac\n' > "$identity_fakebin/getent"
chmod 0755 "$identity_fakebin/age" "$identity_fakebin/getent"
PATH="$identity_fakebin:$PATH" bash "$toolkit/export-linux-identities.sh" --preflight "$toolkit/tests/fixtures/identity/allowlist.tsv" age:fixture "$tmp_root/identity-export.enc" >/dev/null
pass identity-export-preflight 'synthetic allowlist validated without shadow read or export'

negative_stage=$(mktemp -d /dev/shm/vps-migration-identity-negative.XXXXXX)
cp -a "$identity_stage/." "$negative_stage/"
sed -i 's/59990/0/g' "$negative_stage/allowlist.tsv" "$negative_stage/identity/passwd" "$negative_stage/groups/group" "$negative_stage/files/metadata.tsv"
(
  cd "$negative_stage"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
expect_failure identity-collision bash "$toolkit/plan-linux-identity-import.sh" "$negative_stage" "$tmp_root/negative-plan.tsv"
find "$negative_stage" -depth -delete

install -d "$tmp_root/content/sub"
printf 'fixture-content\n' > "$tmp_root/content/sub/a.txt"
ln -s sub/a.txt "$tmp_root/content/link"
printf 'source_path\tclass\trestore_path\tmutable\texcludes\n%s\tfixture\t%s\tno\t\n' "$tmp_root/content" "$tmp_root/content" > "$tmp_root/roots.tsv"
bash "$toolkit/generate-content-manifest.sh" "$tmp_root/roots.tsv" "$tmp_root/content-source.tsv"
bash "$toolkit/compare-content-manifests.sh" "$tmp_root/content-source.tsv" "$tmp_root/content-source.tsv" "$tmp_root/content-positive.tsv"
pass content-positive 'checksums and symlink targets match'
cp "$tmp_root/content-source.tsv" "$tmp_root/content-negative.tsv"
sed -i 's/[a-f0-9]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$tmp_root/content-negative.tsv"
expect_failure content-negative bash "$toolkit/compare-content-manifests.sh" "$tmp_root/content-source.tsv" "$tmp_root/content-negative.tsv" "$tmp_root/content-failure.tsv"

install -d "$tmp_root/staging/fixture-data" "$tmp_root/restore-parent"
printf 'restore-fixture\n' > "$tmp_root/staging/fixture-data/file.txt"
printf 'source_path\tclass\trestore_path\tmutable\texcludes\n/fixture-data\tfixture\t%s\tno\t\n' "$tmp_root/restore-parent/target" > "$tmp_root/restore-roots.tsv"
expect_failure retired-restore-files bash "$toolkit/restore-files.sh" --dry-run "$tmp_root/staging" "$tmp_root/restore-roots.tsv" "$tmp_root/restore-files.tsv"

install -d "$tmp_root/config-staging/etc/systemd/system"
printf '[Unit]\nDescription=Synthetic fixture\n[Service]\nType=oneshot\nExecStart=/usr/bin/true\n' > "$tmp_root/config-staging/etc/systemd/system/zzfixture.service"
printf 'path\ttype\tuid\tgid\tmode_octal\tsize\tsymlink_target\n/etc/systemd/system/zzfixture.service\tf\t0\t0\t644\t37\t\n' > "$tmp_root/config-files.tsv"
printf 'path\tuid\tgid\tmode\tconsumer\ttransfer_class\tsecurity_action\n' > "$tmp_root/secrets.tsv"
expect_failure retired-build-config-plan bash "$toolkit/build-config-plan.sh" "$tmp_root/config-files.tsv" "$tmp_root/secrets.tsv" "$tmp_root/config-plan.tsv"
expect_failure retired-restore-configs bash "$toolkit/restore-configs.sh" --dry-run "$tmp_root/config-staging" "$tmp_root/config-plan.tsv" "$tmp_root/config-restore.tsv"

install -d "$secret_stage/files/etc"
printf 'SYNTHETIC_SECRET=not-real\n' > "$secret_stage/files/etc/migfixture.secret"
chmod 600 "$secret_stage/files/etc/migfixture.secret"
printf 'path\tuid\tgid\tmode\taction\n/etc/migfixture.secret\t0\t0\t600\tinclude\n' > "$secret_stage/metadata.tsv"
printf 'path\taction\treason\n/etc/migfixture.secret\tinclude\tsynthetic\n' > "$secret_stage/allowlist.tsv"
(
  cd "$secret_stage"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
expect_failure retired-restore-secrets bash "$toolkit/restore-secrets.sh" --dry-run "$secret_stage" "$tmp_root/secrets-plan.tsv"
expect_failure identity-apply-guard bash "$toolkit/import-linux-identities.sh" --apply "$identity_stage" "$tmp_root/identity-apply.tsv" "$identity_stage/journal"

package_dir="$tmp_root/packages"
install -d "$package_dir"
package_version=$(dpkg-query -W -f='${Version}' bash)
package_arch=$(dpkg-query -W -f='${Architecture}' bash)
printf 'package\tversion\tarchitecture\tstatus\nbash\t%s\t%s\tii\n' "$package_version" "$package_arch" > "$package_dir/dpkg-packages.tsv"
: > "$package_dir/apt-holds.txt"
printf 'bash\n' > "$package_dir/apt-manual.txt"
for apt_path in /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/preferences /etc/apt/preferences.d /etc/apt/keyrings; do
  if [ -e "$apt_path" ]; then cp -a --parents "$apt_path" "$package_dir"; fi
done
(
  cd "$package_dir"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
expect_failure retired-apt-sources bash "$toolkit/restore-apt-sources.sh" --dry-run "$package_dir" "$tmp_root/apt-sources-plan.tsv"
bash "$toolkit/restore-packages.sh" --dry-run "$package_dir" "$tmp_root/package-plan.tsv"
pass package-dry-run 'exact installed version recognized without installation'
expect_failure package-apply-guard bash "$toolkit/restore-packages.sh" --apply "$package_dir" "$tmp_root/package-apply.tsv"

# Dry-run מבודד לשני כלי MariaDB: binaries ותוכן archive סינתטיים בלבד.
maria_fakebin="$tmp_root/maria-fakebin"
install -d "$maria_fakebin"
printf '#!/bin/sh\nprintf "%%s\\n" "mariadb-backup based on MariaDB server 10.11.0 fixture"\n' > "$maria_fakebin/mariadb-backup"
printf '#!/bin/sh\nprintf "%%s\\n" "mariadbd  Ver 10.11.0-MariaDB fixture"\n' > "$maria_fakebin/mariadbd"
printf '#!/bin/sh\nexit 0\n' > "$maria_fakebin/mbstream"
printf '#!/bin/sh\nexit 0\n' > "$maria_fakebin/systemctl"
printf '#!/bin/sh\ncase "$*" in *"SHOW GRANTS"*) printf "%%s\\n" "GRANT SELECT, RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO fixture" ;; *"@@GLOBAL.datadir"*) printf "%%s/\\n" "$MARIADB_FIXTURE_DATADIR" ;; *) printf "%%s\\n" "10.11.0-MariaDB-fixture" ;; esac\n' > "$maria_fakebin/mariadb"
printf '#!/bin/sh\nexit 0\n' > "$maria_fakebin/ssh"
chmod 0755 "$maria_fakebin"/*
printf '[client]\nuser=fixture\npassword=synthetic-not-real\n' > "$tmp_root/mariadb.cnf"
chmod 0600 "$tmp_root/mariadb.cnf"
install -d "$tmp_root/mariadb-source-datadir" "$tmp_root/mariadb-source-tmp"
MARIADB_FIXTURE_DATADIR="$tmp_root/mariadb-source-datadir" MARIADB_BACKUP_TMPDIR="$tmp_root/mariadb-source-tmp" MARIADB_BACKUP_TMP_MIN_FREE_GIB=0 MARIADB_BACKUP_TMP_PERCENT=0 MARIADB_BACKUP_MIN_FREE_GIB=0 PATH="$maria_fakebin:$PATH" bash "$toolkit/mariadb-backup-stream.sh" --preflight "$tmp_root/mariadb.cnf" fixture-target /var/tmp/fixture.xbstream "$tmp_root/mariadb-backup-preflight.tsv"
pass mariadb-backup-preflight 'synthetic versions and remote gate passed without DB or network access'
printf 'synthetic-xbstream-not-real\n' > "$tmp_root/fixture.xbstream"
sha256sum "$tmp_root/fixture.xbstream" > "$tmp_root/fixture.xbstream.sha256"
fixture_sha=$(sha256sum "$tmp_root/fixture.xbstream" | awk '{print $1}')
fixture_bytes=$(stat -c %s "$tmp_root/fixture.xbstream")
printf 'FORMAT=VPS_MIGRATION_MARIADB_BACKUP_V1\nARCHIVE=%s\nSHA256=%s\nBYTES=%s\nTOKEN=fixture\n' "$tmp_root/fixture.xbstream" "$fixture_sha" "$fixture_bytes" > "$tmp_root/fixture.xbstream.COMPLETE"
MARIADB_RESTORE_MIN_FREE_GIB=0 PATH="$maria_fakebin:$PATH" bash "$toolkit/mariadb-restore.sh" --dry-run "$tmp_root/fixture.xbstream" /var/tmp/mariadb-restore.FIXTURE /var/lib/mysql "$tmp_root/mariadb-restore-plan.tsv"
pass mariadb-restore-dry-run 'synthetic archive checksum, target version and capacity preflight passed'

printf 'project_path\tmanager\tinstall_mode\taction\n/var/www/synthetic-fixture\tcomposer\tproduction\tomit\n' > "$tmp_root/project-dependencies.tsv"
expect_failure retired-project-dependencies bash "$toolkit/restore-project-dependencies.sh" --dry-run "$tmp_root/project-dependencies.tsv" "$tmp_root/project-dependencies-plan.tsv"

printf 'service\tprotocol_port\tlisten_address\taddress_family\tauthorized_source\tfirewall_effect\tadditional_protection\trequired_on_target\tclassification_or_gap\nssh\t22/tcp\t0.0.0.0\tIPv4\tadmin CIDR\tallow exact\tkeys\tyes\tfixture\n' > "$tmp_root/network.tsv"
printf 'UFW STATUS VERBOSE\nUFW STATUS NUMBERED\nIPTABLES-SAVE IPv4\nIP6TABLES-SAVE IPv6\nNFTABLES RULESET\nWIREGUARD CONFIG, SECRETS REDACTED\n' > "$tmp_root/firewall.txt"
expect_failure retired-security-policy bash "$toolkit/restore-security-policy.sh" "$tmp_root/network.tsv" "$tmp_root/firewall.txt" "$tmp_root/security-plan.tsv"
expect_failure retired-mail-plan bash "$toolkit/mail-migration.sh" --cutover-plan "$tmp_root/mail-plan.tsv"
expect_failure retired-automation bash "$toolkit/restore-automation.sh" --dry-run "$tmp_root/automation-plan.tsv"
expect_failure retired-sync-files bash "$toolkit/sync-files.sh" --dry-run fixture "$toolkit/tests/fixtures/mysql-root.tsv" "$tmp_root" "$tmp_root/rsync.tsv"

expect_failure retired-export-secrets bash "$toolkit/export-secrets.sh" --preflight "$tmp_root/secrets.tsv" "$tmp_root/secrets.tsv" age:fixture "$tmp_root/secrets.enc"

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning \
    "$toolkit/lib/common.sh" \
    "$toolkit/mariadb-backup-stream.sh" \
    "$toolkit/mariadb-restore.sh" \
    "$toolkit/verify-mariadb.sh" \
    "$toolkit/tests/test-mariadb-safety.sh"; then
    pass shellcheck 'MariaDB/common safety scope; no warnings or errors'
  else
    fail shellcheck 'reported warnings or errors'
  fi
else
  printf 'SKIP\tshellcheck\tnot available; not installed or downloaded\n' >> "$report"
fi

printf 'SUMMARY\tall\tPASS\n' >> "$report"
printf 'Fixture tests passed: %s\n' "$report"
