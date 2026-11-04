#!/bin/bash
# מטרה: ליצור ביעד רק משתמשים וקבוצות custom-create שאושרו מראש.
# בטיחות: Dry-run כברירת מסלול, target marker קשיח, collision plan, journal ב-tmpfs;
# אין שינוי לחשבונות package-verify ואין התקנת sudo אוטומטית.
# תוצאה רצויה: UID/GID, hash, מצב חשבון, memberships ו-authorized_keys תואמים למקור.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$script_dir/lib/common.sh"

mode=${1:-}
stage=${2:-}
report=${3:-}
journal=${4:-}

case $mode in
  --dry-run)
    [ "$#" -eq 3 ] || die "usage: $0 --dry-run DECRYPTED_TMPFS_STAGE REPORT.tsv"
    exec bash "$script_dir/plan-linux-identity-import.sh" "$stage" "$report"
    ;;
  --apply)
    [ "$#" -eq 4 ] || die "usage: $0 --apply DECRYPTED_TMPFS_STAGE REPORT.tsv TMPFS_JOURNAL_DIR"
    ;;
  *) die "usage: $0 --dry-run STAGE REPORT | --apply STAGE REPORT TMPFS_JOURNAL_DIR" ;;
esac

# שלב 1: Apply מותר רק ביעד המזוהה ובאישור ייחודי.
need_root
require_target_marker
require_approval APPLY_LINUX_IDENTITIES
snapshot_marker=${MIGRATION_SNAPSHOT_MARKER:-/run/vps-migration-snapshot-approved}
grep -Fxq 'TARGET_SNAPSHOT_CONFIRMED=YES' "$snapshot_marker" || die "snapshot approval marker missing: $snapshot_marker"
require_tmpfs_path "$stage"
[ -d "$journal" ] || install -d -m 0700 "$journal"
require_tmpfs_path "$journal"
safe_report_path "$report"
[ ! -e "$journal/APPLY_STARTED" ] || die "journal already used: $journal"

for command in groupadd useradd usermod chpasswd chage install cp cmp awk getent id ssh-keygen; do need_cmd "$command"; done
for file in SHA256SUMS identity/selection.tsv identity/passwd identity/shadow groups/group groups/gshadow groups/memberships.tsv files/metadata.tsv sudo-review.tsv; do
  need_file "$stage/$file"
done
(
  cd "$stage"
  sha256sum -c SHA256SUMS >/dev/null
)

plan_tmp=$(mktemp /tmp/linux-identity-plan.XXXXXX)
password_input=''
trap 'rm -f -- "$plan_tmp"; if [ -n "$password_input" ]; then rm -f -- "$password_input"; fi' EXIT
bash "$script_dir/plan-linux-identity-import.sh" "$stage" "$plan_tmp"

# שלב 2: כל ההתנגשויות נבדקות לפני שינוי החשבון הראשון.
while IFS=$'\t' read -r key_path uid gid mode_value; do
  [ "$key_path" = path ] && continue
  source_file="$stage/files$key_path"
  need_file "$source_file"
  owner=$(awk -F: -v u="$uid" '$3==u {print $1; exit}' "$stage/identity/passwd")
  action=$(awk -F'\t' -v u="$owner" '$1=="user" && $2==u {print $3; exit}' "$stage/identity/selection.tsv")
  [ "$action" = custom-create ] || die "authorized_keys is forbidden for non-custom account: $key_path"
  if [ "$action" = custom-create ] && [ -e "$key_path" ] && ! cmp -s -- "$source_file" "$key_path"; then die "custom authorized_keys collision: $key_path"; fi
  [ "$mode_value" = 600 ] || die "unsafe authorized_keys mode in payload: $key_path ($mode_value)"
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || die "invalid key ownership metadata: $key_path"
done < "$stage/files/metadata.tsv"

install -d -m 0700 "$journal/files"
cp -a --parents /etc/passwd /etc/shadow /etc/group /etc/gshadow "$journal/files"
: > "$journal/created-groups"
: > "$journal/created-users"
: > "$journal/created-homes"
: > "$journal/installed-authorized-keys"
# נשמר קובץ ריק לתאימות rollback; Import חדש לעולם אינו מתקין sudo fragments.
: > "$journal/installed-sudo-fragments"
: > "$journal/created-ssh-dirs"
printf 'started=%s\n' "$(date --iso-8601=seconds)" > "$journal/APPLY_STARTED"

while IFS=$'\t' read -r kind name action; do
  [ "$kind" = kind ] && continue
  [ "$kind" = group ] || continue
  [ "$action" = custom-create ] || continue
  record=$(awk -F: -v n="$name" '$1==n {print; exit}' "$stage/groups/group")
  [ -n "$record" ] || die "group record missing: $name"
  gid=$(cut -d: -f3 <<< "$record")
  if ! getent group "$name" >/dev/null; then
    groupadd --gid "$gid" "$name"
    printf '%s\n' "$name" >> "$journal/created-groups"
  fi
done < "$stage/identity/selection.tsv"

# שלב 3: יצירת custom users בלבד; package accounts אינם משתנים.
while IFS=$'\t' read -r kind name action; do
  [ "$kind" = kind ] && continue
  [ "$kind" = user ] || continue
  [ "$action" = custom-create ] || continue
  record=$(awk -F: -v n="$name" '$1==n {print; exit}' "$stage/identity/passwd")
  [ -n "$record" ] || die "passwd record missing: $name"
  IFS=: read -r _ _ uid gid gecos home shell <<< "$record"
  if ! getent passwd "$name" >/dev/null; then
    useradd --uid "$uid" --gid "$gid" --comment "$gecos" --home-dir "$home" --shell "$shell" --no-create-home "$name"
    printf '%s\n' "$name" >> "$journal/created-users"
  fi
  if [ ! -d "$home" ]; then
    install -d -o "$uid" -g "$gid" -m 0750 "$home"
    printf '%s\n' "$home" >> "$journal/created-homes"
  fi

  shadow_record=$(awk -F: -v n="$name" '$1==n {print; exit}' "$stage/identity/shadow")
  [ -n "$shadow_record" ] || die "shadow record missing: $name"
  IFS=: read -r _ hash last min max warn inactive expire _ <<< "$shadow_record"
  password_input=$(mktemp /dev/shm/chpasswd.XXXXXX)
  printf '%s:%s\n' "$name" "$hash" > "$password_input"
  chpasswd -e < "$password_input"
  find "$password_input" -delete
  password_input=''
  [ -z "$last" ] || chage -d "$last" "$name"
  chage -m "${min:-0}" -M "${max:--1}" -W "${warn:--1}" -I "${inactive:--1}" -E "${expire:--1}" "$name"
done < "$stage/identity/selection.tsv"

# שלב 4: שחזור קבוצות משלימות רק למשתמשים שנוצרו במסלול המאושר.
while IFS=$'\t' read -r user primary all_groups; do
  [ "$user" = user ] && continue
  action=$(awk -F'\t' -v u="$user" '$1=="user" && $2==u {print $3; exit}' "$stage/identity/selection.tsv")
  [ "$action" = custom-create ] || continue
  supplementary=$(tr ' ' '\n' <<< "$all_groups" | awk -v p="$primary" '$0!="" && $0!=p' | paste -sd, -)
  usermod -G "$supplementary" "$user"
done < "$stage/groups/memberships.tsv"

# שלב 5: התקנת authorized_keys רק עבור custom-create ובעלות מספרית מאומתת.
while IFS=$'\t' read -r key_path uid gid mode_value; do
  [ "$key_path" = path ] && continue
  owner=$(awk -F: -v u="$uid" '$3==u {print $1; exit}' "$stage/identity/passwd")
  action=$(awk -F'\t' -v u="$owner" '$1=="user" && $2==u {print $3; exit}' "$stage/identity/selection.tsv")
  [ "$action" = custom-create ] || die "refusing SSH mutation for package account: $owner"
  source_file="$stage/files$key_path"
  ssh_dir=$(dirname -- "$key_path")
  if [ ! -d "$ssh_dir" ]; then
    install -d -o "$uid" -g "$gid" -m 0700 "$ssh_dir"
    printf '%s\n' "$ssh_dir" >> "$journal/created-ssh-dirs"
  fi
  if [ -e "$key_path" ]; then cp -a --parents "$key_path" "$journal/files"; fi
  install -o "$uid" -g "$gid" -m "$mode_value" "$source_file" "$key_path"
  printf '%s\n' "$key_path" >> "$journal/installed-authorized-keys"
done < "$stage/files/metadata.tsv"

# שלב 6: sudo אינו משתנה. התוצאה הרצויה היא חשבונות תקינים ו-journal שלם.
printf 'completed=%s\n' "$(date --iso-8601=seconds)" > "$journal/APPLY_COMPLETED"
cp -- "$plan_tmp" "$report"
trap - EXIT
rm -f -- "$plan_tmp"
note "identity import completed; rollback journal: $journal"
note 'rollback: restore the provider snapshot; do not overwrite account databases while the target is serving traffic'
