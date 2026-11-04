#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: סיווג תצורות אוטומטי.
# בטיחות: יציאה מיידית בקוד 64; אין קריאת manifests ואין כתיבה.
# תוצאה רצויה: המפעיל עובר ל-staging ו-diff ידני לפי OPERATIONS.md.
printf 'RETIRED: build-config-plan.sh is documentation-only; use manual reviewed config staging/diff.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

config_manifest=${1:-}
secret_manifest=${2:-}
output=${3:-}
[ "$#" -eq 3 ] || die "usage: $0 CONFIG_FILES.tsv SECRETS.tsv OUTPUT_PLAN.tsv"
need_file "$config_manifest"
need_file "$secret_manifest"
safe_report_path "$output"
printf 'staged_relative_path\ttarget_path\taction\towner_uid\towner_gid\tmode\tcomponent\n' > "$output"
awk -F'\t' -v OFS='\t' '
  NR==FNR {if(FNR>1) secret[$1]=1; next}
  FNR==1 {next}
  {
    path=$1; type=$2; action="merge"; component="config"
    if(path in secret) {action="omit"; component="secret-handled-separately"}
    else if(type=="l") {action="omit"; component="symlink-handled-by-file-sync"}
    else if(path ~ /^\/etc\/systemd\/system\//) {action="install"; component="systemd"}
    else if(path ~ /^\/etc\/cron\.(d|daily|weekly|monthly)\// || path=="/etc/crontab") {action="install"; component="cron"}
    else if(path ~ /^\/etc\/(apache2|php|mysql|postfix|dovecot|opendkim|roundcube|postfixadmin)\//) {action="merge"; component="service-config"}
    else if(path ~ /^\/etc\/(ssh|ufw|wireguard|fail2ban)\//) {action="merge"; component="security-config"}
    print substr(path,2),path,action,$3,$4,$5,component
  }
' "$secret_manifest" "$config_manifest" >> "$output"
note "config plan generated: $output"
