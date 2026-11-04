#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: Export מוצפן של סודות.
# בטיחות: יציאה מיידית בקוד 64 מונעת איסוף או העברה מקריים.
# תוצאה רצויה: שימוש ידני ב-allowlist וב-tar+age/GPG לפי OPERATIONS.md.
printf 'RETIRED: export-secrets.sh must not be run; use the approved manual encrypted-secret procedure.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

[ "$#" -eq 5 ] && { [ "$1" = --preflight ] || [ "$1" = --execute ]; } || die "usage: $0 --preflight|--execute SECRETS.tsv ALLOWLIST.tsv age:RECIPIENT|gpg:FINGERPRINT OUTPUT.enc"
run_mode=$1
manifest=$2
allowlist=$3
recipient=$4
output=$5
need_file "$manifest"
need_file "$allowlist"
[ "$(head -n 1 "$allowlist")" = $'path\taction\treason' ] || die 'invalid secret allowlist header'
[ ! -e "$output" ] && [ ! -e "${output}.partial" ] || die 'output already exists'

case $recipient in
  age:*) encryption=age; recipient_value=${recipient#age:}; need_cmd age ;;
  gpg:*) encryption=gpg; recipient_value=${recipient#gpg:}; [[ $recipient_value =~ ^[0-9A-Fa-f]{40}$ ]] || die 'GPG recipient must be a 40-hex fingerprint'; need_cmd gpg; gpg --batch --list-keys "$recipient_value" >/dev/null ;;
  *) die 'recipient must use age: or gpg:' ;;
esac

while IFS=$'\t' read -r path action reason; do
  [ "$path" = path ] && continue
  case $action in include|omit|rotate) ;; *) die "invalid secret action for $path: $action" ;; esac
  [ "$action" = include ] || continue
  awk -F'\t' -v p="$path" 'NR>1 && $1==p {found=1} END{exit !found}' "$manifest" || die "secret not present in manifest: $path"
  [ -f "$path" ] || die "approved secret is not a regular file: $path"
done < "$allowlist"

if [ "$run_mode" = --preflight ]; then
  printf 'PASS: secret allowlist, source files, encryption recipient and output path are valid\n'
  exit 0
fi

stage=$(mktemp -d /dev/shm/vps-secrets-export.XXXXXX)
require_tmpfs_path "$stage"
partial="${output}.partial"
cleanup() { cleanup_tree "$stage" /dev/shm/vps-secrets-export.; [ ! -e "$partial" ] || rm -f -- "$partial"; }
trap cleanup EXIT
install -d -m 0700 "$stage/files"
printf 'path\tuid\tgid\tmode\taction\n' > "$stage/metadata.tsv"

while IFS=$'\t' read -r path action reason; do
  [ "$path" = path ] && continue
  [ "$action" = include ] || continue
  cp --parents --preserve=mode,ownership,timestamps -- "$path" "$stage/files"
  printf '%s\t%s\t%s\t%s\tinclude\n' "$path" "$(stat -c %u "$path")" "$(stat -c %g "$path")" "$(stat -c %a "$path")" >> "$stage/metadata.tsv"
done < "$allowlist"

cp -- "$allowlist" "$stage/allowlist.tsv"
(
  cd "$stage"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
if [ "$encryption" = age ]; then
  tar --numeric-owner --acls --xattrs -C "$stage" -cf - . | age -r "$recipient_value" -o "$partial"
else
  tar --numeric-owner --acls --xattrs -C "$stage" -cf - . | gpg --batch --encrypt --recipient "$recipient_value" --output "$partial"
fi
test -s "$partial"
mv -- "$partial" "$output"
sha256sum "$output" > "${output}.sha256"
note "encrypted secrets package created: $output"
