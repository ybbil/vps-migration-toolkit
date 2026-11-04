#!/bin/bash
# מטרה: לייצא רשימה מאושרת של משתמשים וקבוצות Linux, כולל hashes וקבוצות,
# לחבילה מוצפנת שניתנת לשחזור ביעד.
# בטיחות: הסקריפט אינו משנה חשבונות; הוא דורש allowlist, יעד הצפנה מלא,
# source marker ב-execute, אינו מייצא private keys ואינו מייצא sudo אוטומטית.
# תוצאה רצויה: חבילה מוצפנת ושלמה; sudo נשאר לביקורת ידנית בלבד.
set -euo pipefail
set +x
umask 077

if [ "$#" -ne 4 ] || { [ "$1" != --preflight ] && [ "$1" != --execute ]; }; then
  printf 'Usage: %s --preflight|--execute ALLOWLIST.tsv age:RECIPIENT|gpg:40_HEX_FINGERPRINT OUTPUT.tar.enc\n' "$0" >&2
  printf 'This reads password hashes and creates an encrypted export; it requires explicit source approval.\n' >&2
  exit 2
fi

run_mode=$1
allowlist=$2
recipient=$3
output=$4
partial="${output}.partial"

case $recipient in
  age:*)
    encryption=age
    recipient_value=${recipient#age:}
    command -v age >/dev/null
    [ -n "$recipient_value" ]
    ;;
  gpg:[0-9A-Fa-f][0-9A-Fa-f]*)
    encryption=gpg
    recipient_value=${recipient#gpg:}
    [[ $recipient_value =~ ^[0-9A-Fa-f]{40}$ ]]
    command -v gpg >/dev/null
    gpg --batch --list-keys "$recipient_value" >/dev/null
    ;;
  *)
    printf 'Recipient must use age: or gpg: with a full 40-hex fingerprint.\n' >&2
    exit 2
    ;;
esac
[ -r "$allowlist" ]
[ "$(head -n 1 "$allowlist")" = $'kind\tname\taction\texpected_id\texpected_primary_gid\treason' ]
[ ! -e "$output" ]
[ ! -e "$partial" ]
[ ! -e "${output}.sha256" ]

awk -F'\t' '
  NR == 1 { next }
  NF != 6 { bad=1 }
  $1 !~ /^(user|group)$/ { bad=1 }
  $2 !~ /^[A-Za-z_][A-Za-z0-9_-]*[$]?$/ { bad=1 }
  $3 !~ /^(custom-create|package-verify|omit)$/ { bad=1 }
  $4 !~ /^[0-9]+$/ { bad=1 }
  $1 == "user" && $5 !~ /^[0-9]+$/ { bad=1 }
  $1 == "group" && $5 != "" { bad=1 }
  seen[$1 SUBSEP $2]++ > 0 { bad=1 }
  END { exit bad }
' "$allowlist"

while IFS=$'\t' read -r kind name action expected_id expected_primary_gid _; do
  [ "$kind" = kind ] && continue
  [ "$action" = omit ] && continue
  if [ "$kind" = user ]; then
    record=$(getent passwd "$name")
    [ "$(cut -d: -f3 <<< "$record")" = "$expected_id" ]
    [ "$(cut -d: -f4 <<< "$record")" = "$expected_primary_gid" ]
  else
    record=$(getent group "$name")
    [ "$(cut -d: -f3 <<< "$record")" = "$expected_id" ]
  fi
done < "$allowlist"

if [ "$run_mode" = --preflight ]; then
  # שלב 1: בדיקת קלט בלבד; התוצאה הרצויה היא PASS ללא קריאת shadow או יצירת חבילה.
  printf 'PASS: identity allowlist, IDs, encryption recipient and output path are valid\n'
  exit 0
fi

# שלב 2: execute דורש זיהוי קשיח של שרת המקור ואישור ייחודי.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"
require_source_marker
require_approval EXPORT_LINUX_IDENTITIES

stage=$(mktemp -d /dev/shm/linux-identity-export.XXXXXX)
case $stage in /dev/shm/linux-identity-export.*) ;; *) exit 1 ;; esac
cleanup() {
  find "$stage" -depth -delete
  if [ -e "$partial" ]; then rm -f -- "$partial"; fi
}
trap cleanup EXIT

install -d -m 0700 "$stage/identity" "$stage/groups" "$stage/files"
printf 'kind\tname\taction\n' > "$stage/identity/selection.tsv"
: > "$stage/identity/passwd"
: > "$stage/identity/shadow"
: > "$stage/groups/group"
: > "$stage/groups/gshadow"
: > "$stage/groups/required-names"
printf 'user\tprimary_group\tall_groups\n' > "$stage/groups/memberships.tsv"
printf 'path\tuid\tgid\tmode\n' > "$stage/files/metadata.tsv"

while IFS=$'\t' read -r kind user action expected_uid expected_gid _; do
  [ "$kind" = kind ] && continue
  [ "$kind" = user ] || continue
  [ "$action" = omit ] && continue

  passwd_record=$(getent passwd "$user")
  shadow_record=$(getent shadow "$user")
  actual_uid=$(cut -d: -f3 <<< "$passwd_record")
  actual_gid=$(cut -d: -f4 <<< "$passwd_record")
  [ "$actual_uid" = "$expected_uid" ]
  [ "$actual_gid" = "$expected_gid" ]

  printf 'user\t%s\t%s\n' "$user" "$action" >> "$stage/identity/selection.tsv"
  printf '%s\n' "$passwd_record" >> "$stage/identity/passwd"
  printf '%s\n' "$shadow_record" >> "$stage/identity/shadow"
  approved_groups=''
  while IFS= read -r group_name; do
    [ -n "$group_name" ] || continue
    group_action=$(awk -F'\t' -v g="$group_name" '$1=="group" && $2==g {print $3; exit}' "$allowlist")
    [ -n "$group_action" ] || die "group missing from allowlist: $group_name (user: $user)"
    [ "$group_action" = omit ] && continue
    approved_groups="${approved_groups}${approved_groups:+ }${group_name}"
    printf '%s\n' "$group_name" >> "$stage/groups/required-names"
  done < <(id -nG "$user" | tr ' ' '\n')
  primary_group=$(id -gn "$user")
  case " $approved_groups " in *" $primary_group "*) ;; *) die "primary group is omitted: $primary_group (user: $user)" ;; esac
  printf '%s\t%s\t%s\n' "$user" "$primary_group" "$approved_groups" >> "$stage/groups/memberships.tsv"

  # שלב 3: authorized_keys מועתקים רק למשתמש custom-create.
  # חשבון package-verify נבדק בלבד ולעולם אינו מקבל מפתח מהמקור.
  [ "$action" = custom-create ] || continue
  home=$(cut -d: -f6 <<< "$passwd_record")
  for key_file in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
    if [ -f "$key_file" ]; then
      cp --parents --preserve=mode,ownership,timestamps -- "$key_file" "$stage/files"
      printf '%s\t%s\t%s\t%s\n' "$key_file" "$(stat -c '%u' -- "$key_file")" "$(stat -c '%g' -- "$key_file")" "$(stat -c '%a' -- "$key_file")" >> "$stage/files/metadata.tsv"
    fi
  done
done < "$allowlist"

sort -u -o "$stage/groups/required-names" "$stage/groups/required-names"
while IFS= read -r required_group; do
  [ -n "$required_group" ] || continue
  awk -F'\t' -v g="$required_group" '$1=="group" && $2==g && $3!="omit" {found=1} END{exit !found}' "$allowlist"
done < "$stage/groups/required-names"

while IFS=$'\t' read -r kind group action expected_gid _ _; do
  [ "$kind" = kind ] && continue
  [ "$kind" = group ] || continue
  [ "$action" = omit ] && continue
  group_record=$(getent group "$group")
  actual_gid=$(cut -d: -f3 <<< "$group_record")
  [ "$actual_gid" = "$expected_gid" ]
  printf 'group\t%s\t%s\n' "$group" "$action" >> "$stage/identity/selection.tsv"
  printf '%s\n' "$group_record" >> "$stage/groups/group"
  getent gshadow "$group" >> "$stage/groups/gshadow"
done < "$allowlist"

# שלב 4: sudo אינו מועתק אוטומטית. נשמרים fingerprints בלבד לצורך merge ידני.
printf 'path\tsha256\n' > "$stage/sudo-review.tsv"
while IFS= read -r sudo_file; do
  printf '%s\t%s\n' "$sudo_file" "$(sha256sum -- "$sudo_file" | awk '{print $1}')" >> "$stage/sudo-review.tsv"
done < <(find /etc/sudoers.d -maxdepth 1 -type f -print 2>/dev/null | sort)
if [ -f /etc/sudoers ]; then
  printf '/etc/sudoers\t%s\n' "$(sha256sum /etc/sudoers | awk '{print $1}')" >> "$stage/sudo-review.tsv"
fi

cp -- "$allowlist" "$stage/allowlist.tsv"
cp -- /etc/os-release "$stage/os-release"
printf 'created=%s\nhost=%s\n' "$(date --iso-8601=seconds)" "$(hostname -f)" > "$stage/export-metadata.txt"
(
  cd "$stage"
  find . -type f ! -name SHA256SUMS -print0 |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
)

# שלב 5: נחתמים כל קובצי ה-payload ונבדקת התאמה לפני הצפנה.
bash "$script_dir/validate-identity-payload.sh" "$stage" >/dev/null

if [ "$encryption" = age ]; then
  tar --numeric-owner --acls --xattrs -C "$stage" -cf - . |
    age -r "$recipient_value" -o "$partial"
else
  tar --numeric-owner --acls --xattrs -C "$stage" -cf - . |
  gpg --batch --trust-model always --encrypt --recipient "$recipient_value" --output "$partial"
fi
# שלב 6: התוצאה הרצויה היא archive מוצפן אטומי ו-checksum חיצוני.
test -s "$partial"
mv -- "$partial" "$output"
sha256sum "$output" > "${output}.sha256"
printf 'Encrypted identity export created: %s\n' "$output"
