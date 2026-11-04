#!/bin/bash
# מטרה: להשוות manifests של זהויות, הרשאות ונתיבים בין מקור ליעד.
# בטיחות: אין גישה ישירה לשרתים ואין שינוי; הקלט חייב להיות freshly generated.
# תוצאה רצויה: failures=0, ללא UID/GID collision או fingerprint חסר.
set -euo pipefail

source_dir=${1:-}
target_dir=${2:-}
report=${3:-/tmp/source-target-comparison.$(date +%Y%m%dT%H%M%S).tsv}
compare_mtime=${COMPARE_MTIME:-0}
umask 077

case $compare_mtime in 0|1) ;; *) printf 'COMPARE_MTIME must be 0 or 1\n' >&2; exit 2 ;; esac

if [ -z "$source_dir" ] || [ -z "$target_dir" ] || [ ! -d "$source_dir" ] || [ ! -d "$target_dir" ]; then
  printf 'Usage: %s SOURCE_MANIFEST_DIR TARGET_MANIFEST_DIR [REPORT.tsv]\n' "$0" >&2
  printf 'TARGET_MANIFEST_DIR must be freshly generated on the target host.\n' >&2
  exit 2
fi

required=(users.tsv groups.tsv memberships.tsv path-permissions.tsv config-files.tsv mail-files.tsv authorized-keys-fingerprints.tsv)
for file in "${required[@]}"; do
  [ -s "$source_dir/$file" ] || { printf 'Missing source manifest: %s/%s\n' "$source_dir" "$file" >&2; exit 2; }
  [ -s "$target_dir/$file" ] || { printf 'Missing target manifest: %s/%s\n' "$target_dir" "$file" >&2; exit 2; }
done

tmp=$(mktemp "${report}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf 'status\tcategory\tobject\texpected\tactual\tdetail\n' > "$tmp"

compare_keyed_tsv() {
  local category=$1 source_file=$2 target_file=$3 key_column=$4 value_columns=$5
  awk -F'\t' -v OFS='\t' -v category="$category" -v keycol="$key_column" -v cols="$value_columns" '
    function value(    n,a,i,v) {
      n=split(cols,a,","); v=""
      for(i=1;i<=n;i++) v=v (i==1 ? "" : "|") $a[i]
      return v
    }
    NR==FNR {
      if(FNR==1) next
      key=$keycol; target[key]=value(); target_seen[key]=1; next
    }
    FNR==1 { next }
    {
      key=$keycol; expected=value(); source_seen[key]=1
      if(!(key in target_seen)) print "FAIL",category,key,expected,"MISSING","absent from target manifest"
      else if(expected != target[key]) print "FAIL",category,key,expected,target[key],"value mismatch"
      else matches++
    }
    END {
      for(key in target_seen) if(!(key in source_seen)) print "FAIL",category,key,"ABSENT",target[key],"unexpected target entry"
      print "PASS",category "-summary","matched",matches+0,matches+0,"exact entries matched"
    }
  ' "$target_file" "$source_file" >> "$tmp"
}

compare_keyed_tsv user "$source_dir/users.tsv" "$target_dir/users.tsv" 1 '2,3,4,5,6'
compare_keyed_tsv group "$source_dir/groups.tsv" "$target_dir/groups.tsv" 1 '2,3'
compare_keyed_tsv membership "$source_dir/memberships.tsv" "$target_dir/memberships.tsv" 1 '2,3,4'

awk -F'\t' -v OFS='\t' '
  NR==FNR {if(FNR>1) target_uid[$2]=$1; next}
  FNR>1 && ($2 in target_uid) && target_uid[$2]!=$1 {
    print "FAIL","uid-collision",$2,$1,target_uid[$2],"UID belongs to a different target name"
  }
' "$target_dir/users.tsv" "$source_dir/users.tsv" >> "$tmp"
awk -F'\t' -v OFS='\t' '
  NR==FNR {if(FNR>1) target_gid[$2]=$1; next}
  FNR>1 && ($2 in target_gid) && target_gid[$2]!=$1 {
    print "FAIL","gid-collision",$2,$1,target_gid[$2],"GID belongs to a different target name"
  }
' "$target_dir/groups.tsv" "$source_dir/groups.tsv" >> "$tmp"

path_columns='2,3,4,5,6,8'
[ "$compare_mtime" = 0 ] || path_columns='2,3,4,5,6,7,8'
compare_keyed_tsv path "$source_dir/path-permissions.tsv" "$target_dir/path-permissions.tsv" 1 "$path_columns"
compare_keyed_tsv mail-path "$source_dir/mail-files.tsv" "$target_dir/mail-files.tsv" 1 "$path_columns"
compare_keyed_tsv config-path "$source_dir/config-files.tsv" "$target_dir/config-files.tsv" 1 '2,3,4,5,6,7'

awk -F'\t' -v OFS='\t' '
  function key(){return $1 SUBSEP $5}
  function shown(){return $1 "|" $5}
  NR==FNR {if(FNR>1){target[key()]=$2 "|" $3 "|" $4; label[key()]=shown()} next}
  FNR==1 {next}
  {
    k=key(); source[k]=1; expected=$2 "|" $3 "|" $4
    if(!(k in target)) print "FAIL","ssh-fingerprint",shown(),expected,"MISSING","key fingerprint absent from target"
    else if(expected!=target[k]) print "FAIL","ssh-fingerprint",shown(),expected,target[k],"authorized_keys metadata mismatch"
    else matches++
  }
  END {
    for(k in target) if(!(k in source)) print "FAIL","ssh-fingerprint",label[k],"ABSENT",target[k],"unexpected target fingerprint"
    print "PASS","ssh-fingerprint-summary","matched",matches+0,matches+0,"fingerprints and metadata matched"
  }
' "$target_dir/authorized-keys-fingerprints.tsv" "$source_dir/authorized-keys-fingerprints.tsv" >> "$tmp"

failures=$(awk -F'\t' '$1=="FAIL" {n++} END{print n+0}' "$tmp")
checks=$(awk 'END{print NR-1}' "$tmp")
printf 'SUMMARY\tchecks\t%s\t-\t-\tfailures=%s\n' "$checks" "$failures" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
printf 'Source-to-target report: %s; failures=%d\n' "$report" "$failures"
if [ "$failures" -gt 0 ]; then exit 1; fi
exit 0
