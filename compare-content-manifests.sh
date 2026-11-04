#!/bin/bash
# מטרה: להשוות manifests של תוכן מקור ויעד לפי SHA-256, סוג ו-symlink.
# בטיחות: קריאה בלבד; נכתב דוח חדש בלבד. תוצאה רצויה: failures=0 לפני GO.
# שלבים: טעינת שני manifests, השוואה דו-כיוונית, כתיבת SUMMARY ועצירה על mismatch.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

source_manifest=${1:-}
target_manifest=${2:-}
report=${3:-}
[ "$#" -eq 3 ] || die "usage: $0 SOURCE_CONTENT.tsv TARGET_CONTENT.tsv REPORT.tsv"
need_file "$source_manifest"
need_file "$target_manifest"
safe_report_path "$report"
tmp=$(mktemp "${report}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf 'status\tpath\texpected\tactual\tdetail\n' > "$tmp"
awk -F'\t' -v OFS='\t' '
  NR==FNR {if(FNR>1){t[$1]=$2 "|" $3 "|" $4 "|" $5; seen[$1]=1} next}
  FNR==1 {next}
  {s[$1]=1; expected=$2 "|" $3 "|" $4 "|" $5
   if(!($1 in seen)) print "FAIL",$1,expected,"MISSING","target path absent"
   else if(expected!=t[$1]) print "FAIL",$1,expected,t[$1],"content/type mismatch"
   else matches++}
  END {for(p in seen) if(!(p in s)) print "FAIL",p,"ABSENT",t[p],"unexpected target path";
       print "PASS","matched",matches+0,matches+0,"exact content records"}
' "$target_manifest" "$source_manifest" >> "$tmp"
failures=$(awk -F'\t' '$1=="FAIL"{n++}END{print n+0}' "$tmp")
printf 'SUMMARY\t-\t-\t-\tfailures=%d\n' "$failures" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
if [ "$failures" -gt 0 ]; then exit 1; fi
