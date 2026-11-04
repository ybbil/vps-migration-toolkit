#!/bin/bash
# Read-only Hostinger VPS Firewall inventory export. Never prints the API token.
set -euo pipefail
set +x
umask 077

toolkit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$toolkit/lib/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: HOSTINGER_API_TOKEN=... hostinger-firewall-export.sh --json SNAPSHOT.json --csv RULES.csv

Reads /virtual-machines and /firewall only. JSON is also accepted by
hostinger-firewall-apply.sh after review; CSV is a human-editable policy format.
EOF
  exit 64
}

json_out= csv_out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json_out=${2:-}; shift 2 ;;
    --csv) csv_out=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$json_out" ] && [ -n "$csv_out" ] || usage
[ -n "${HOSTINGER_API_TOKEN:-}" ] || die 'HOSTINGER_API_TOKEN is required (do not put it in a file or chat)'
need_cmd curl; need_cmd jq
safe_report_path "$json_out"; safe_report_path "$csv_out"
[ ! -e "$json_out" ] || die "refusing to overwrite: $json_out"
[ ! -e "$csv_out" ] || die "refusing to overwrite: $csv_out"

api_base=https://developers.hostinger.com/api/vps/v1
api_get() {
  curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
    -H "Authorization: Bearer ${HOSTINGER_API_TOKEN}" "$api_base$1"
}

tmpdir=$(mktemp -d "$(dirname -- "$json_out")/.hostinger-firewall-export.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT
api_get /virtual-machines >"$tmpdir/virtual-machines.json"
api_get /firewall >"$tmpdir/firewalls.json"
jq -e 'if type == "array" then . else .data end | type == "array"' "$tmpdir/virtual-machines.json" >/dev/null || die 'unexpected virtual-machines response'
jq -e 'if type == "array" then . else .data end | type == "array"' "$tmpdir/firewalls.json" >/dev/null || die 'unexpected firewall response'

jq -n \
  --arg exported_at "$(date --iso-8601=seconds)" \
  --arg api_base "$api_base" \
  --slurpfile virtual_machines "$tmpdir/virtual-machines.json" \
  --slurpfile firewall_response "$tmpdir/firewalls.json" \
  '{schema_version:1, kind:"hostinger-firewall-snapshot", exported_at:$exported_at, api_base:$api_base,
    api_responses:{virtual_machines:$virtual_machines[0],firewalls:$firewall_response[0]},
    virtual_machines:($virtual_machines[0] | if type == "array" then . else .data end),
    firewalls:(($firewall_response[0] | if type == "array" then . else .data end) | map({name, id, is_synced, rules:(.rules // []),
      virtual_machine_ids: [. as $f | ($virtual_machines[0] | if type == "array" then . else .data end)[]? | select((.firewall_group_id // null) == $f.id) | .id]}))}' \
  >"$tmpdir/snapshot.json"

{
  printf '%s\n' 'firewall_name,virtual_machine_id,protocol,port,source,source_detail'
  jq -r '.firewalls[] as $f | (($f.virtual_machine_ids | if length == 0 then [""] else . end)[]) as $vm | $f.rules[]? |
    [$f.name, $vm, .protocol, .port, .source, .source_detail] | @csv' "$tmpdir/snapshot.json"
} >"$tmpdir/rules.csv"

mv -- "$tmpdir/snapshot.json" "$json_out"
mv -- "$tmpdir/rules.csv" "$csv_out"
trap - EXIT
find "$tmpdir" -depth -delete
printf 'PASS\tread-only export\tjson=%s\tcsv=%s\n' "$json_out" "$csv_out"
