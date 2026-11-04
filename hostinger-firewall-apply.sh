#!/bin/bash
# Safe Hostinger Firewall writer: dry-run first, explicit apply, recovery journal.
set -euo pipefail
set +x
umask 077
toolkit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$toolkit/lib/common.sh"
usage(){ cat >&2 <<'EOF'
Usage: hostinger-firewall-apply.sh --dry-run|--apply POLICY.{json,csv} REPORT.tsv --allow-vm ID --management-source CIDR|any [...]
Apply additionally requires MIGRATION_APPROVAL=APPLY_HOSTINGER_FIREWALL.
CSV: firewall_name,virtual_machine_id,protocol,port,source,source_detail
EOF
exit 64; }
mode=dry-run; input=; report=; allowed=(); management=()
while [ "$#" -gt 0 ]; do case "$1" in
--dry-run) mode=dry-run;shift;; --apply) mode=apply;shift;; --allow-vm) allowed+=("${2:-}");shift 2;; --management-source) management+=("${2:-}");shift 2;; -*) usage;; *) if [ -z "$input" ];then input=$1;elif [ -z "$report" ];then report=$1;else usage;fi;shift;; esac;done
[ -n "$input" ] && [ -n "$report" ] && [ "${#allowed[@]}" -gt 0 ] && [ "${#management[@]}" -gt 0 ] || usage
[ -r "$input" ] || die "policy is not readable: $input"
[ -n "${HOSTINGER_API_TOKEN:-}" ] || die 'HOSTINGER_API_TOKEN is required'
need_cmd curl; need_cmd jq; need_cmd python3; safe_report_path "$report"; [ ! -e "$report" ] || die "refusing to overwrite: $report"
for x in "${allowed[@]}";do [[ $x =~ ^[0-9]+$ ]]||die "invalid VM: $x";done
canonical_cidr(){ python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=True).with_prefixlen)' "$1"; }
management_canon=()
for x in "${management[@]}";do if [ "$x" = any ];then management_canon+=(any);else management_canon+=("$(canonical_cidr "$x")")||die "invalid management CIDR: $x";fi;done
[ "$mode" != apply ] || require_approval APPLY_HOSTINGER_FIREWALL
tmpdir=$(mktemp -d "$(dirname -- "$report")/.hostinger-firewall.XXXXXX")
before="${report}.before.json"; after="${report}.after.json"; recovery="${report}.recovery.json"; partial=0
on_exit(){ local rc=$?; if [ "$rc" -ne 0 ] && [ "$partial" -eq 1 ];then printf 'PARTIAL_FAILURE\tinspect=%s\trestore_from=%s\n' "$recovery" "$before" >>"$report" 2>/dev/null||true;fi; find "$tmpdir" -depth -delete; exit "$rc";};trap on_exit EXIT
allowed_json=$(printf '%s\n' "${allowed[@]}"|jq -R .|jq -s 'map(tonumber)|unique'); management_json=$(printf '%s\n' "${management_canon[@]}"|jq -R .|jq -s unique)
policies="$tmpdir/policies.json"
case "$input" in
*.json) jq '[.firewalls[]? | {name,virtual_machine_ids:(.virtual_machine_ids//[]),rules:(.rules//[])}]' "$input">"$policies"||die 'invalid JSON';;
*.csv) head -n1 "$input"|grep -Fxq 'firewall_name,virtual_machine_id,protocol,port,source,source_detail'||die 'invalid CSV header'; tail -n +2 "$input"|awk -F, 'NF!=6||/"/||$1==""||$2!~/^[0-9]+$/{bad=1}END{exit bad}'||die 'invalid CSV'; tail -n +2 "$input"|jq -Rsc 'split("\n")|map(select(length>0)|split(",")|{name:.[0],vm:(.[1]|tonumber),rule:{protocol:.[2],port:.[3],source:.[4],source_detail:.[5]}})|group_by([.name,.vm])|map({name:.[0].name,virtual_machine_ids:[.[0].vm],rules:(map(.rule)|unique)})'>"$policies";;
*) die 'policy must end in .json or .csv';;esac
jq -e --argjson a "$allowed_json" --argjson m "$management_json" '
def ruleok:(.protocol as $p|["TCP","UDP","ICMP","GRE","any"]|index($p)!=null)and(.port|type=="string"and test("^(any|[0-9]+(:[0-9]+)?)$"))and(.source as $s|["any","custom"]|index($s)!=null)and(.source_detail|type=="string"and test("^[^[:space:]]+$"));
def managementok:.protocol=="TCP"and.port=="22"and((.source=="any"and.source_detail=="any")or(.source=="custom"));
(type=="array"and length>0)and([.[].name]|(length==(unique|length)))and([.[].virtual_machine_ids[]]|(length==(unique|length)))and all(.[];(.name|type=="string"and test("^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$"))and(.virtual_machine_ids|length==1)and all(.virtual_machine_ids[];(. as $v|$a|index($v))!=null)and(.rules|length>0)and all(.rules[];ruleok)and any(.rules[];managementok))' "$policies">/dev/null||die 'policy failed: duplicate group/VM, invalid rule, or no management rule'
policy_lines="$tmpdir/policies.ndjson"; jq -c '.[]' "$policies" >"$policy_lines" || die 'could not enumerate policies'
validate_management(){
  local policy=$1 src detail canonical has_any=0 matched checks x
  local -a seen=()
  local checks="$tmpdir/management.$RANDOM"
  for x in "${management_canon[@]}"; do [ "$x" = any ] && has_any=1; done
  jq -r '.rules[]|select(.protocol=="TCP" and .port=="22")|[.source,.source_detail]|@tsv' <<<"$policy" >"$checks" || die 'could not inspect management rules'
  if [ "$has_any" -eq 1 ]; then
    while IFS=$'\t' read -r src detail; do
      [ "$src" = any ] && [ "$detail" = any ] && { find "$checks" -delete; return 0; }
    done <"$checks"
    find "$checks" -delete; die 'management-source any requires an explicit TCP/22 any rule'
  fi
  while IFS=$'\t' read -r src detail; do
    [ "$src" = custom ] || { find "$checks" -delete; die 'TCP/22 any is not approved by --management-source'; }
    canonical=$(canonical_cidr "$detail") || { find "$checks" -delete; die "invalid management rule CIDR: $detail"; }
    matched=0
    for x in "${management_canon[@]}"; do [ "$canonical" = "$x" ] && matched=1; done
    [ "$matched" -eq 1 ] || { find "$checks" -delete; die "unapproved or broader management CIDR: $canonical"; }
    seen+=("$canonical")
  done <"$checks"
  find "$checks" -delete
  for x in "${management_canon[@]}"; do
    matched=0; for canonical in "${seen[@]}"; do [ "$canonical" = "$x" ] && matched=1; done
    [ "$matched" -eq 1 ] || die "management source is not covered by TCP/22 rule: $x"
  done
}
api_base=${HOSTINGER_API_BASE:-https://developers.hostinger.com/api/vps/v1}; [[ $api_base == https://* ]]||die 'HOSTINGER_API_BASE must use https'
api(){ local method=$1 path=$2 body=${3:-};if [ -n "$body" ];then curl --fail --silent --show-error --proto '=https' --tlsv1.2 -X "$method" -H "Authorization: Bearer $HOSTINGER_API_TOKEN" -H 'Content-Type: application/json' --data "$body" "$api_base$path";else curl --fail --silent --show-error --proto '=https' --tlsv1.2 -X "$method" -H "Authorization: Bearer $HOSTINGER_API_TOKEN" "$api_base$path";fi;}
snapshot(){ api GET /virtual-machines >"$1.v";api GET /firewall >"$1.f";jq -e 'if type=="array" then . else .data end|type=="array"' "$1.v">/dev/null;jq -e 'if type=="array" then . else .data end|type=="array"' "$1.f">/dev/null;jq -n --slurpfile v "$1.v" --slurpfile f "$1.f" '{virtual_machines:($v[0]|if type=="array" then . else .data end),firewalls:($f[0]|if type=="array" then . else .data end)}';}
snapshot "$tmpdir/live">"$before"; printf 'MODE\t%s\nBEFORE\t%s\nRECOVERY\t%s\n' "$mode" "$before" "$recovery">"$report"; jq -n --slurpfile b "$before" '{schema_version:1,before:$b[0],operations:[]}' >"$recovery"
while IFS= read -r policy;do
validate_management "$policy"
name=$(jq -r .name<<<"$policy");vm=$(jq -r '.virtual_machine_ids[0]'<<<"$policy");rules=$(jq -c .rules<<<"$policy");matches=$(jq -r --arg n "$name" '[.firewalls[]|select(.name==$n)]|length' "$before");[ "$matches" -le 1 ]||die "duplicate live name: $name";id=$(jq -r --arg n "$name" '.firewalls[]|select(.name==$n)|.id' "$before")
if [ -n "$id" ];then attached=$(jq -r --argjson id "$id" '[.virtual_machines[]|select((.firewall_group_id//null)==$id)|.id]|sort|join(",")' "$before");[ "$attached" = "$vm" ]||die "unexpected existing attachment for $name";action=update;else action=create;fi
printf 'PLAN\t%s\tgroup=%s\tvm=%s\trules=%s\n' "$action" "$name" "$vm" "$(jq length<<<"$rules")" >>"$report";[ "$mode" = apply ]||continue;partial=1
if [ "$action" = create ];then id=$(api POST /firewall "$(jq -nc --arg n "$name" '{name:$n}')"|jq -r '.id//.data.id//empty');[[ $id =~ ^[0-9]+$ ]]||die 'create returned no ID';fi
op=$(jq -nc --arg name "$name" --argjson id "$id" --argjson vm "$vm" --arg action "$action" '{name:$name,id:$id,vm:$vm,action:$action}');jq --argjson op "$op" '.operations+=[$op]' "$recovery">"$tmpdir/r"&&mv "$tmpdir/r" "$recovery"
api PUT "/firewall/$id/rules" "$(jq -nc --argjson r "$rules" '{rules:$r,sync:true}')">/dev/null;api POST "/firewall/$id/activate/$vm">/dev/null;api POST "/firewall/$id/sync">/dev/null
deadline=$((SECONDS + ${HOSTINGER_SYNC_WAIT_SECONDS:-30})); synced=0; while [ "$SECONDS" -le "$deadline" ];do current=$(api GET /firewall)||die 'could not poll firewall sync'; if jq -e --argjson fid "$id" '.data[]|select(.id==$fid and .is_synced==true)' <<<"$current">/dev/null;then synced=1;break;fi; sleep "${HOSTINGER_SYNC_POLL_SECONDS:-2}";done; [ "$synced" -eq 1 ]||die "firewall $name did not reach is_synced=true before timeout";printf 'APPLIED\tgroup=%s\tid=%s\tvm=%s\tsynced=true\n' "$name" "$id" "$vm">>"$report"
done <"$policy_lines"
[ "$mode" = apply ]||{ printf 'PASS\tdry-run\treport=%s\n' "$report";exit 0;}
snapshot "$tmpdir/after">"$after"
while IFS= read -r policy;do name=$(jq -r .name<<<"$policy");vm=$(jq -r '.virtual_machine_ids[0]'<<<"$policy");rules=$(jq -cS .rules<<<"$policy");id=$(jq -r --arg n "$name" '.firewalls[]|select(.name==$n)|.id' "$after");[ -n "$id" ]||die "verify missing $name";jq -e --argjson id "$id" --argjson vm "$vm" '.virtual_machines[]|select(.id==$vm and (.firewall_group_id//null)==$id)' "$after">/dev/null||die "verify attachment $name";got=$(jq -cS --argjson id "$id" '.firewalls[]|select(.id==$id)|(.rules//[])' "$after");[ "$got" = "$rules" ]||die "verify rules $name";done <"$policy_lines"
printf 'AFTER\t%s\nPASS\tapply-verified\treport=%s\n' "$after" "$report" >>"$report"
