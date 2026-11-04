#!/bin/bash
# מטרה: להשוות את מצב החבילות בפועל בין המקור ליעד.
# בטיחות: קריאה בלבד מ-inventories; נכתב דוח בלבד.
# תוצאה רצויה: כל package record נדרש תואם; target-only מדווח כ-INFO.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

source_inventory=${1:-}
target_inventory=${2:-}
report=${3:-}
[ "$#" -eq 3 ] || die "usage: $0 SOURCE_INVENTORY TARGET_INVENTORY REPORT.tsv"
need_file "$source_inventory/dpkg-packages.tsv"
need_file "$target_inventory/dpkg-packages.tsv"
safe_report_path "$report"
printf 'status\tpackage\tsource\ttarget\tdetail\n' > "$report"
awk -F'\t' -v OFS='\t' '
  NR==FNR {if(FNR>1){t[$1]=$2 "|" $3 "|" $4; seen[$1]=1} next}
  FNR==1 {next}
  {s[$1]=1; expected=$2 "|" $3 "|" $4
   if(!($1 in seen)) print "FAIL",$1,expected,"MISSING","package absent"
   else if(expected!=t[$1]) print "FAIL",$1,expected,t[$1],"version/architecture/status mismatch"
   else matches++}
  END {for(p in seen) if(!(p in s)) print "INFO",p,"ABSENT",t[p],"target-only package";
       print "PASS","matched",matches+0,matches+0,"exact package records"}
' "$target_inventory/dpkg-packages.tsv" "$source_inventory/dpkg-packages.tsv" >> "$report"
failures=$(awk -F'\t' '$1=="FAIL"{n++}END{print n+0}' "$report")
printf 'SUMMARY\t-\t-\t-\tfailures=%d\n' "$failures" >> "$report"
if [ "$failures" -gt 0 ]; then exit 1; fi
