#!/bin/bash
# מטרה: להפיק SHA-256 וסוג עבור roots מאושרים לצורך אימות תוכן.
# בטיחות: קריאה בלבד אך עלולה ליצור I/O משמעותי; אין להריץ על mutable data ללא חלון מתאים.
# תוצאה רצויה: manifest ממוין שניתן להשוות מול היעד.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

roots=${1:-}
output=${2:-}
secret_manifest=${3:-}
[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || die "usage: $0 ROOTS.tsv OUTPUT.tsv [SECRETS.tsv]"
need_file "$roots"
[ -z "$secret_manifest" ] || need_file "$secret_manifest"
safe_report_path "$output"
need_cmd sha256sum
tmp=$(mktemp "${output}.tmp.XXXXXX")
body=$(mktemp "${output}.body.XXXXXX")
trap 'rm -f -- "$tmp" "$body"' EXIT
printf 'path\ttype\tsize\tsha256\tsymlink_target\n' > "$tmp"

while IFS=$'\034' read -r root class restore_path mutable excludes; do
  [ "$root" = source_path ] && continue
  [ -e "$root" ] || die "content root missing: $root"
  while IFS= read -r -d '' path; do
    if [ -n "$secret_manifest" ] && awk -F'\t' -v p="$path" 'NR>1 && $1==p {found=1} END{exit !found}' "$secret_manifest"; then
      continue
    fi
    relative=${path#"$root"/}
    skip=0
    if [ -n "$excludes" ] && [ "$path" != "$root" ]; then
      IFS=';' read -r -a exclude_values <<< "$excludes"
      for pattern in "${exclude_values[@]}"; do
        if [[ $relative == $pattern ]]; then skip=1; break; fi
      done
    fi
    [ "$skip" -eq 0 ] || continue
    if [ -L "$path" ]; then
      printf '%s\tl\t%s\t-\t%s\n' "$path" "$(stat -c %s -- "$path")" "$(readlink -- "$path")" >> "$body"
    elif [ -f "$path" ]; then
      printf '%s\tf\t%s\t%s\t\n' "$path" "$(stat -c %s -- "$path")" "$(sha256sum -- "$path" | awk '{print $1}')" >> "$body"
    elif [ -d "$path" ]; then
      printf '%s\td\t-\t-\t\n' "$path" >> "$body"
    fi
  done < <(find "$root" -xdev -print0)
done < <(awk 'BEGIN{FS="\t";OFS=sprintf("%c",28)}{$1=$1;print}' "$roots")

sort -t $'\t' -k1,1 "$body" >> "$tmp"
mv -- "$tmp" "$output"
trap - EXIT
rm -f -- "$body"
note "content manifest created: $output"
