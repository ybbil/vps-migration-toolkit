#!/bin/bash
# מטרה: לבצע config lint ולתעד listeners ביעד לפני פתיחת תעבורה.
# בטיחות: target marker נדרש; אין start/reload של שירותים.
# תוצאה רצויה: failures=0, ולאחר מכן עדיין נדרשות בדיקות אפליקטיביות חיצוניות.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

report=${1:-}
[ "$#" -eq 1 ] || die "usage: $0 REPORT.tsv"
require_target_marker
safe_report_path "$report"
printf 'status\tcomponent\tcheck\tdetail\n' > "$report"
failures=0

run_check() {
  local component=$1 check=$2
  shift 2
  if "$@" >/dev/null 2>&1; then
    printf 'PASS\t%s\t%s\tok\n' "$component" "$check" >> "$report"
  else
    printf 'FAIL\t%s\t%s\tcommand failed\n' "$component" "$check" >> "$report"
    failures=$((failures + 1))
  fi
}

command -v sshd >/dev/null && run_check ssh sshd-config sshd -t
command -v apache2ctl >/dev/null && run_check apache apache-config apache2ctl configtest
command -v postfix >/dev/null && run_check postfix postfix-config postfix check
command -v doveconf >/dev/null && run_check dovecot dovecot-config doveconf -n
command -v visudo >/dev/null && run_check sudo sudoers visudo -c
if command -v wg-quick >/dev/null && [ -f /etc/wireguard/wg0.conf ]; then run_check wireguard config-strip wg-quick strip wg0; fi
if command -v mariadb-admin >/dev/null && systemctl is-active --quiet mariadb; then run_check mariadb ping mariadb-admin ping; fi

printf 'INFO\tnetwork\tlisteners\tsee-following-lines\n' >> "$report"
ss -H -lntup >> "$report"
printf 'SUMMARY\tall\tchecks\tfailures=%d\n' "$failures" >> "$report"
if [ "$failures" -gt 0 ]; then exit 1; fi
