#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: הפקת תוכנית Firewall/WireGuard.
# בטיחות: יציאה בקוד 64; snapshot ישן אינו מופעל כ-ruleset.
# תוצאה רצויה: שחזור ידני דרך console לפי policy מאושר.
printf 'RETIRED: restore-security-policy.sh is documentation-only. Follow OPERATIONS.md from provider console.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

matrix=${1:-}
firewall_snapshot=${2:-}
report=${3:-}
[ "$#" -eq 3 ] || die "usage: $0 NETWORK_MATRIX.tsv FIREWALL_SNAPSHOT.txt REPORT.tsv"
need_file "$matrix"
need_file "$firewall_snapshot"
safe_report_path "$report"
for section in 'UFW STATUS VERBOSE' 'UFW STATUS NUMBERED' 'IPTABLES-SAVE IPv4' 'IP6TABLES-SAVE IPv6' 'NFTABLES RULESET' 'WIREGUARD CONFIG, SECRETS REDACTED'; do
  grep -Fq "$section" "$firewall_snapshot" || die "firewall snapshot missing section: $section"
done
printf 'status\tcomponent\taction\tdetail\n' > "$report"
printf 'PLAN\tprovider-firewall\tmanual-gate\tallow management CIDR first; prove console access\n' >> "$report"
printf 'PLAN\tSSH\tpreserve-first\tapply/test management rule before default deny\n' >> "$report"
printf 'PLAN\tUFW\trebuild-policy\tderive approved rules from network matrix; do not replay numbered rules\n' >> "$report"
printf 'PLAN\tIPv6\tseparate-validation\ttest management and public services independently\n' >> "$report"
printf 'PLAN\tWireGuard\tsecret-restore\trestore encrypted config as 0600; run wg-quick strip; update endpoint/interface/NAT\n' >> "$report"
printf 'PLAN\trollback\tconsole-required\trestore last tested ruleset; never use persistent allow-all\n' >> "$report"
awk -F'\t' 'NR>1 {printf "POLICY\t%s\treview\tport=%s listen=%s source=%s target=%s gap=%s\n",$1,$2,$3,$5,$8,$9}' "$matrix" >> "$report"
printf 'SUMMARY\tsecurity\tplan-only\tlive firewall apply intentionally not automated\n' >> "$report"
