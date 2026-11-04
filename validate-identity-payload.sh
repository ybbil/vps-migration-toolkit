#!/bin/bash
# מטרה: לאמת את חוזה חבילת הזהויות לפני תכנון או Import.
# בטיחות: קריאה בלבד ב-tmpfs; דוחה checksum שגוי, קבצים עודפים, private keys,
# sudo payload ו-authorized_keys שאינו שייך ל-custom-create.
# תוצאה רצויה: PASS רק עבור payload מצומצם שזהה לפורמט ה-Exporter.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

stage=${1:-}
[ "$#" -eq 1 ] || die "usage: $0 DECRYPTED_TMPFS_STAGE"
require_tmpfs_path "$stage"
# שלב 1: סכמות וקבצים נדרשים.
for file in SHA256SUMS allowlist.tsv identity/selection.tsv identity/passwd identity/shadow groups/group groups/gshadow groups/memberships.tsv files/metadata.tsv sudo-review.tsv; do need_file "$stage/$file"; done
[ "$(head -n1 "$stage/allowlist.tsv")" = $'kind\tname\taction\texpected_id\texpected_primary_gid\treason' ] || die 'invalid allowlist schema'
[ "$(head -n1 "$stage/identity/selection.tsv")" = $'kind\tname\taction' ] || die 'invalid selection schema'
[ "$(head -n1 "$stage/groups/memberships.tsv")" = $'user\tprimary_group\tall_groups' ] || die 'invalid membership schema'
[ "$(head -n1 "$stage/files/metadata.tsv")" = $'path\tuid\tgid\tmode' ] || die 'invalid file metadata schema'
(
  # שלב 2: כל קובץ רשום חייב להתאים ל-checksum.
  cd "$stage"
  sha256sum -c SHA256SUMS >/dev/null
)
# אין לאפשר קבצים שאינם חתומים, למעט SHA256SUMS עצמו.
while IFS= read -r -d '' payload_file; do
  relative=${payload_file#"$stage/"}
  [ "$relative" = SHA256SUMS ] && continue
  awk -v p="./$relative" '$2==p {found=1} END{exit !found}' "$stage/SHA256SUMS" || die "unsigned payload file: $relative"
done < <(find "$stage" -type f -print0)

while IFS=$'\t' read -r kind name action; do
  [ "$kind" = kind ] && continue
  awk -F'\t' -v k="$kind" -v n="$name" -v a="$action" 'NR>1 && $1==k && $2==n && $3==a {ok=1} END{exit !ok}' "$stage/allowlist.tsv" || die "selection not authorized by allowlist: $kind/$name"
  case $kind in
    user)
      awk -F: -v n="$name" '$1==n {ok=1} END{exit !ok}' "$stage/identity/passwd" || die "passwd record missing: $name"
      awk -F: -v n="$name" '$1==n {ok=1} END{exit !ok}' "$stage/identity/shadow" || die "shadow record missing: $name"
      awk -F'\t' -v n="$name" 'NR>1 && $1==n {ok=1} END{exit !ok}' "$stage/groups/memberships.tsv" || die "membership record missing: $name"
      ;;
    group)
      awk -F: -v n="$name" '$1==n {ok=1} END{exit !ok}' "$stage/groups/group" || die "group record missing: $name"
      awk -F: -v n="$name" '$1==n {ok=1} END{exit !ok}' "$stage/groups/gshadow" || die "gshadow record missing: $name"
      ;;
    *) die "invalid identity kind: $kind" ;;
  esac
done < "$stage/identity/selection.tsv"

while IFS=$'\t' read -r path uid gid mode_value; do
  [ "$path" = path ] && continue
  case $path in /*/.ssh/authorized_keys|*/.ssh/authorized_keys2) ;; *) die "non-authorized_keys file in SSH metadata: $path" ;; esac
  need_file "$stage/files$path"
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $mode_value =~ ^[0-7]{3,4}$ ]] || die "invalid file metadata: $path"
  owner=$(awk -F: -v u="$uid" '$3==u {print $1; exit}' "$stage/identity/passwd")
  [ -n "$owner" ] || die "authorized_keys UID is not present in selected passwd records: $path"
  action=$(awk -F'\t' -v u="$owner" '$1=="user" && $2==u {print $3; exit}' "$stage/identity/selection.tsv")
  [ "$action" = custom-create ] || die "authorized_keys is allowed only for custom-create users: $path"
done < "$stage/files/metadata.tsv"

# שלב 3: מוודאים שאין payload של sudo או מפתחות פרטיים.
[ ! -e "$stage/files/etc/sudoers" ] || die 'sudoers payload is forbidden; use manual reviewed merge'
if [ -d "$stage/files/etc/sudoers.d" ] && find "$stage/files/etc/sudoers.d" -type f -print -quit | grep -q .; then
  die 'sudoers.d payload is forbidden; use manual reviewed merge'
fi
if find "$stage/files" -type f \( -name 'id_*' -o -name '*_rsa' -o -name '*_ed25519' \) -print -quit | grep -q .; then
  die 'private-key-like file detected in identity payload'
fi
# תוצאה רצויה: המבנה, ההרשאות הלוגיות והתוכן המוצפן מוכנים לתכנון Import.
printf 'PASS: identity payload contract and checksums are valid\n'
