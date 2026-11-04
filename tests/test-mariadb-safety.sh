#!/bin/bash
set -euo pipefail
umask 077

toolkit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/mariadb-safety.XXXXXX)
trap 'find -P "$tmp" -depth -delete' EXIT
fakebin=$tmp/bin
state=$tmp/state
remote_root=$tmp/remote
source_datadir=$tmp/source-datadir
source_tmp=$tmp/source-tmp
mkdir -p "$fakebin" "$state" "$remote_root" "$source_datadir" "$source_tmp"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() { if "$@"; then fail "unexpected success: $*"; fi; }

cat > "$fakebin/mariadb" <<'EOF'
#!/bin/sh
case "$*" in
  *"SHOW GRANTS"*) printf '%s\n' 'GRANT SELECT, RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO fixture' ;;
  *"@@GLOBAL.datadir"*) printf '%s/\n' "$FAKE_SOURCE_DATADIR" ;;
  *) printf '%s\n' '11.8.6-MariaDB-fixture' ;;
esac
EOF
cat > "$fakebin/mariadb-backup" <<'EOF'
#!/bin/sh
case "$*" in
  *--version*) printf '%s\n' 'mariadb-backup based on MariaDB server 11.8.6 fixture' ;;
  *--backup*) printf 'synthetic-stream'; exit "${FAKE_BACKUP_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
cat > "$fakebin/ssh" <<'EOF'
#!/bin/sh
eval "remote=\${$#}"
case "$remote" in
  *"available="*) [ "${FAKE_REMOTE_GATE:-ok}" = ok ]; exit ;;
esac
translated=$(printf '%s' "$remote" | sed "s#/var/tmp/#$FAKE_REMOTE_ROOT/#g")
FAKE_STATE=$FAKE_STATE PATH=$PATH sh -c "$translated"
EOF
cat > "$fakebin/ln" <<'EOF'
#!/bin/sh
eval "destination=\${$#}"
printf '%s\n' "$destination" >> "$FAKE_STATE/publish-order"
exec /bin/ln "$@"
EOF
cat > "$fakebin/mariadbd" <<'EOF'
#!/bin/sh
printf '%s\n' 'mariadbd  Ver 11.8.6-MariaDB fixture'
EOF
printf '#!/bin/sh\nexit 0\n' > "$fakebin/mbstream"
printf '#!/bin/sh\nexit 1\n' > "$fakebin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$fakebin/mariadb-admin"
chmod 0755 "$fakebin"/*

printf '[client]\nuser=fixture\n' > "$tmp/client.cnf"
chmod 0600 "$tmp/client.cnf"
hostname_value=$(hostname -f)
machine_id=$(cat /etc/machine-id)
printf 'ACTIVE_VPS_MIGRATION_SOURCE=YES\nHOSTNAME=%s\nMACHINE_ID=%s\n' "$hostname_value" "$machine_id" > "$tmp/source-marker"
printf 'APPROVED=YES\nACTION=STREAM_MARIADB_BACKUP\nHOSTNAME=%s\nMACHINE_ID=%s\n' "$hostname_value" "$machine_id" > "$tmp/approval"
chmod 0600 "$tmp/approval"

base_env=(env PATH="$fakebin:$PATH" FAKE_STATE="$state" FAKE_REMOTE_ROOT="$remote_root" FAKE_SOURCE_DATADIR="$source_datadir" MARIADB_BACKUP_MIN_FREE_GIB=0 MARIADB_BACKUP_TMP_MIN_FREE_GIB=0 MARIADB_BACKUP_TMP_PERCENT=0 MARIADB_BACKUP_TMPDIR="$source_tmp" MIGRATION_SOURCE_MARKER="$tmp/source-marker" MIGRATION_APPROVAL=STREAM_MARIADB_BACKUP MIGRATION_APPROVAL_FILE="$tmp/approval")
FAKE_BACKUP_RC=7 "${base_env[@]}" bash "$toolkit/mariadb-backup-stream.sh" --execute "$tmp/client.cnf" target /var/tmp/safety.xbstream "$tmp/stream-fail.tsv" && fail 'stream failure accepted'
[ ! -e "$remote_root/safety.xbstream.COMPLETE" ] || fail 'failed stream published COMPLETE'
printf 'PASS: stream failure did not publish a valid backup\n'

rm -f "$state/publish-order"
FAKE_BACKUP_RC=0 "${base_env[@]}" bash "$toolkit/mariadb-backup-stream.sh" --execute "$tmp/client.cnf" target /var/tmp/safety-success.xbstream "$tmp/stream-success.tsv"
for output in safety-success.xbstream safety-success.xbstream.sha256 safety-success.xbstream.COMPLETE; do
  [ -f "$remote_root/$output" ] || fail "missing fixture publication: $output"
done
expected_order=$(printf '%s\n%s\n%s' "$remote_root/safety-success.xbstream" "$remote_root/safety-success.xbstream.sha256" "$remote_root/safety-success.xbstream.COMPLETE")
[ "$(cat "$state/publish-order")" = "$expected_order" ] || fail 'publication order was not archive, checksum, COMPLETE'
published_hash=$(awk '{print $1}' "$remote_root/safety-success.xbstream.sha256")
[ "$published_hash" = "$(sha256sum "$remote_root/safety-success.xbstream" | awk '{print $1}')" ] || fail 'published checksum is invalid'
grep -Fq $'PASS\tpublish\t' "$tmp/stream-success.tsv" || fail 'publication was not reported'
printf 'PASS: fixture filesystem published archive, checksum, COMPLETE in order\n'

FAKE_REMOTE_GATE=low expect_failure "${base_env[@]}" bash "$toolkit/mariadb-backup-stream.sh" --preflight "$tmp/client.cnf" target /var/tmp/space.xbstream "$tmp/space.tsv"
printf 'PASS: insufficient remote space rejected\n'
FAKE_REMOTE_GATE=exists expect_failure "${base_env[@]}" bash "$toolkit/mariadb-backup-stream.sh" --preflight "$tmp/client.cnf" target /var/tmp/existing.xbstream "$tmp/existing.tsv"
printf 'PASS: existing/locked archive gate rejected\n'

printf 'archive\n' > "$tmp/archive.xbstream"
sha256sum "$tmp/archive.xbstream" > "$tmp/archive.xbstream.sha256"
archive_sha=$(sha256sum "$tmp/archive.xbstream" | awk '{print $1}')
archive_bytes=$(stat -c %s "$tmp/archive.xbstream")
printf 'FORMAT=VPS_MIGRATION_MARIADB_BACKUP_V1\nARCHIVE=%s\nSHA256=%s\nBYTES=%s\nTOKEN=fixture\n' "$tmp/archive.xbstream" "$archive_sha" "$archive_bytes" > "$tmp/archive.xbstream.COMPLETE"
expect_failure env PATH="$fakebin:$PATH" MARIADB_RESTORE_MIN_FREE_GIB=0 bash "$toolkit/mariadb-restore.sh" --dry-run "$tmp/archive.xbstream" /fixture/../fixture/mariadb-restore.BAD /fixture/not-a-datadir "$tmp/path.tsv"
printf 'PASS: non-canonical restore path rejected\n'

cp "$tmp/archive.xbstream.COMPLETE" "$tmp/archive.xbstream.COMPLETE.good"
sed -i 's/^SHA256=.*/SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$tmp/archive.xbstream.COMPLETE"
expect_failure env PATH="$fakebin:$PATH" MARIADB_RESTORE_MIN_FREE_GIB=0 bash "$toolkit/mariadb-restore.sh" --dry-run "$tmp/archive.xbstream" /fixture/mariadb-restore.BAD /fixture/not-a-datadir "$tmp/complete.tsv"
mv "$tmp/archive.xbstream.COMPLETE.good" "$tmp/archive.xbstream.COMPLETE"
printf 'PASS: mismatched COMPLETE rejected without apply or system-path access\n'

printf 'APPROVED=YES\nACTION=AUDIT_MARIADB_SOURCE_LIGHT\nHOSTNAME=%s\nMACHINE_ID=%s\n' "$hostname_value" "$machine_id" > "$tmp/light-approval"
chmod 0600 "$tmp/light-approval"
env PATH="$fakebin:$PATH" MIGRATION_SOURCE_MARKER="$tmp/source-marker" MIGRATION_TARGET_MARKER="$tmp/no-target-marker" MIGRATION_APPROVAL=AUDIT_MARIADB_SOURCE_LIGHT MIGRATION_APPROVAL_FILE="$tmp/light-approval" bash "$toolkit/verify-mariadb.sh" --source-light "$tmp/client.cnf" "$tmp/source-light.tsv"
grep -Fq $'SKIPPED\texact-row-counts' "$tmp/source-light.tsv" || fail 'source-light did not skip exact row counts'
grep -Fq $'SKIPPED\tmariadb-check' "$tmp/source-light.tsv" || fail 'source-light did not skip mariadb-check'
[ ! -e "$tmp/source-light.tsv.exact-row-counts.tsv" ] || fail 'source-light created exact row counts'
[ ! -e "$tmp/source-light.tsv.mariadb-check.txt" ] || fail 'source-light ran mariadb-check'
grep -Eq '^[^[:space:]]+[[:space:]][0-9a-f]{64}[[:space:]][0-9a-f]{64}$' "$tmp/source-light.tsv.account-fingerprints.tsv" || fail 'account fingerprints were not generated'
printf 'PASS: source-light skipped heavy checks and persisted only account fingerprints\n'

printf 'PASS: test never invokes restore apply and all writes remain below %s\n' "$tmp"
