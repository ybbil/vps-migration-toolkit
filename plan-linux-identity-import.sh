#!/bin/bash
# מטרה: לתכנן Import של זהויות ללא שינוי מערכת.
# בטיחות: פועל רק מ-tmpfs, מאמת payload, מזהה התנגשויות ומונע sudo אוטומטי.
# תוצאה רצויה: דוח ללא STOP; כל שינוי צפוי מופיע מראש.
set -euo pipefail
set +x
umask 077

stage=${1:-}
report=${2:-}
if [ -z "$stage" ] || [ -z "$report" ] || [ ! -d "$stage" ]; then
  printf 'Usage: %s DECRYPTED_TMPFS_STAGE PLAN.tsv\n' "$0" >&2
  exit 2
fi

case $stage in /dev/shm/*|/run/*) ;; *) printf 'Refusing non-tmpfs staging path: %s\n' "$stage" >&2; exit 2 ;; esac
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# שלב 1: אימות payload ו-checksums לפני השוואה למצב היעד.
bash "$script_dir/validate-identity-payload.sh" "$stage" >/dev/null
for required in SHA256SUMS allowlist.tsv identity/selection.tsv identity/passwd identity/shadow groups/group groups/gshadow groups/memberships.tsv; do
  [ -f "$stage/$required" ] || { printf 'Missing payload file: %s\n' "$required" >&2; exit 2; }
done
(
  cd "$stage"
  sha256sum -c SHA256SUMS >/dev/null
)

tmp=$(mktemp "${report}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf 'result\taction\tkind\tname\texpected\tactual\treason\n' > "$tmp"
stops=0

emit() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$tmp"
  [ "$1" != STOP ] || stops=$((stops + 1))
}

while IFS=$'\t' read -r kind name action; do
  [ "$kind" = kind ] && continue
  if [ "$kind" = group ]; then
    record=$(awk -F: -v n="$name" '$1==n {print; exit}' "$stage/groups/group")
    expected_gid=$(cut -d: -f3 <<< "$record")
    if by_name=$(getent group "$name"); then :; else by_name=''; fi
    if by_gid=$(getent group "$expected_gid"); then :; else by_gid=''; fi
    if [ "$action" = package-verify ]; then
      if [ -z "$by_name" ]; then
        emit STOP VERIFY group "$name" "$expected_gid" MISSING 'package-created group absent'
      elif [ "$(cut -d: -f3 <<< "$by_name")" != "$expected_gid" ]; then
        emit STOP VERIFY group "$name" "$expected_gid" "$(cut -d: -f3 <<< "$by_name")" 'package group GID mismatch; never overwrite'
      else
        emit OK VERIFY group "$name" "$expected_gid" "$expected_gid" 'package group matches'
      fi
    elif [ -z "$by_name" ] && [ -z "$by_gid" ]; then
      emit OK CREATE group "$name" "$expected_gid" MISSING 'approved custom group creation'
    elif [ "$(cut -d: -f1 <<< "$by_gid")" = "$name" ] && [ "$(cut -d: -f3 <<< "$by_name")" = "$expected_gid" ]; then
      emit OK VERIFY group "$name" "$expected_gid" "$expected_gid" 'existing custom group matches'
    else
      emit STOP COLLISION group "$name" "$expected_gid" "${by_name:-$by_gid}" 'name or GID collision'
    fi
  fi
done < "$stage/identity/selection.tsv"

# שלב 2: בדיקת משתמשים, UID/GID, home ו-shell; אין שינוי בשלב זה.
while IFS=$'\t' read -r kind name action; do
  [ "$kind" = kind ] && continue
  [ "$kind" = user ] || continue
  record=$(awk -F: -v n="$name" '$1==n {print; exit}' "$stage/identity/passwd")
  expected_uid=$(cut -d: -f3 <<< "$record")
  expected_gid=$(cut -d: -f4 <<< "$record")
  expected_home=$(cut -d: -f6 <<< "$record")
  expected_shell=$(cut -d: -f7 <<< "$record")
  expected="$expected_uid:$expected_gid:$expected_home:$expected_shell"
  if by_name=$(getent passwd "$name"); then :; else by_name=''; fi
  if by_uid=$(getent passwd "$expected_uid"); then :; else by_uid=''; fi
  if [ "$action" = package-verify ]; then
    if [ -z "$by_name" ]; then
      emit STOP VERIFY user "$name" "$expected" MISSING 'package-created account absent'
    else
      actual="$(cut -d: -f3,4,6,7 <<< "$by_name")"
      [ "$actual" = "$expected" ] && emit OK VERIFY user "$name" "$expected" "$actual" 'package account matches' || emit STOP VERIFY user "$name" "$expected" "$actual" 'package account mismatch; never overwrite'
    fi
  elif [ -z "$by_name" ] && [ -z "$by_uid" ]; then
    emit OK CREATE user "$name" "$expected" MISSING 'approved custom account creation'
  elif [ -n "$by_name" ] && [ "$(cut -d: -f1 <<< "$by_uid")" = "$name" ]; then
    actual="$(cut -d: -f3,4,6,7 <<< "$by_name")"
    [ "$actual" = "$expected" ] && emit OK VERIFY user "$name" "$expected" "$actual" 'existing custom account matches' || emit STOP COLLISION user "$name" "$expected" "$actual" 'identity mismatch'
  else
    emit STOP COLLISION user "$name" "$expected" "${by_name:-$by_uid}" 'name or UID collision'
  fi

  shadow_hash=$(awk -F: -v n="$name" '$1==n {print $2; exit}' "$stage/identity/shadow")
  case $shadow_hash in
    \!*|\**) password_state=locked-or-disabled ;;
    '') password_state=no-password-hash ;;
    *) password_state=encrypted-password-hash ;;
  esac
  emit OK RESTORE-ACCOUNT-STATE user "$name" "$password_state" REDACTED 'hash value deliberately excluded from plan'
done < "$stage/identity/selection.tsv"

# שלב 3: תכנון memberships רק לאחר שכל ההתנגשויות נבדקו.
while IFS=$'\t' read -r user primary groups; do
  [ "$user" = user ] && continue
  emit OK MEMBERSHIP user "$user" "$primary:$groups" NOT-APPLIED 'apply only after all groups pass collision checks'
done < "$stage/groups/memberships.tsv"

# שלב 4: sudo נשאר Gate ידני. רק fingerprints מוצגים; לא מותקן קובץ.
while IFS=$'\t' read -r sudo_path sudo_hash; do
  [ "$sudo_path" = path ] && continue
  emit REVIEW SUDO-MANUAL file "$sudo_path" "$sudo_hash" NOT-APPLIED 'manual least-privilege merge and visudo required'
done < "$stage/sudo-review.tsv"

while IFS=$'\t' read -r key_path uid gid mode; do
  [ "$key_path" = path ] && continue
  emit OK SSH-INSTALL file "$key_path" "$uid:$gid:$mode" NOT-APPLIED 'authorized_keys only; compare fingerprints after install'
done < "$stage/files/metadata.tsv"

# שלב 5: תוצאה רצויה היא STOP_COUNT=0; REVIEW של sudo אינו Apply אוטומטי.
printf 'SUMMARY\tSTOP_COUNT\t%d\t-\t-\t-\t-\n' "$stops" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
printf 'Identity dry-run plan: %s; stop_conditions=%d\n' "$report" "$stops"
if [ "$stops" -gt 0 ]; then exit 1; fi
exit 0
