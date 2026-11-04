#!/bin/bash
# Synthetic Hostinger API contract tests; never contacts the network.
set -euo pipefail; set +x; umask 077
toolkit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d /tmp/hostinger-firewall-test.XXXXXX); trap 'rm -rf -- "$t"' EXIT
mkdir "$t/bin" "$t/state"
cat >"$t/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
method=GET; body=; url=
while [ $# -gt 0 ]; do case "$1" in -X) method=$2;shift 2;; --data) body=$2;shift 2;; *) url=$1;shift;; esac; done
path=${url#*v1}; key="$method:$path"; [ "${FAIL_ON:-}" != "$key" ] || exit 28
s=${MOCK_STATE:?}; f="$s/firewalls.json"; v="$s/vms.json"
case "$key" in
GET:/virtual-machines) cat "$v";; GET:/firewall) if [ "${SYNC_DELAY_ONCE:-}" = 1 ] && [ -e "$s/sync-triggered" ] && [ ! -e "$s/sync-polled" ];then : >"$s/sync-polled";jq '.data|=map(.is_synced=false)' "$f";else cat "$f";fi;;
POST:/firewall) id=$(jq '[.data[].id]|max//100|.+1' "$f"); jq --argjson id "$id" --arg n "$(jq -r .name <<<"$body")" '.data += [{id:$id,name:$n,is_synced:true,rules:[]}]' "$f">"$f.n";mv "$f.n" "$f";jq -n --argjson id "$id" '{id:$id}';;
PUT:/firewall/*/rules) id=${path#/firewall/};id=${id%/rules};jq --argjson id "$id" --argjson r "$(jq .rules <<<"$body")" '(.data[]|select(.id==$id)).rules=$r' "$f">"$f.n";mv "$f.n" "$f";echo '{}';;
POST:/firewall/*/activate/*) z=${path#/firewall/};id=${z%%/*};vm=${z##*/};jq --argjson id "$id" --argjson vm "$vm" '(.data[]|select(.id==$vm)).firewall_group_id=$id' "$v">"$v.n";mv "$v.n" "$v";echo '{}';;
POST:/firewall/*/sync) [ "${SYNC_DELAY_ONCE:-}" != 1 ] || : >"$s/sync-triggered"; echo '{}';; *) echo "unsupported $key" >&2;exit 22;; esac
EOF
chmod 755 "$t/bin/curl"
printf '%s\n' '{"data":[{"id":1,"name":"source","firewall_group_id":null},{"id":2,"name":"target","firewall_group_id":null}]}' >"$t/state/vms.json"
printf '%s\n' '{"data":[{"id":99,"name":"unassigned","is_synced":true,"rules":[{"protocol":"TCP","port":"22","source":"any","source_detail":"any"}]}]}' >"$t/state/firewalls.json"
cat >"$t/policy.json" <<'EOF'
{"firewalls":[{"name":"source-fw","virtual_machine_ids":[1],"rules":[{"protocol":"TCP","port":"22","source":"any","source_detail":"any"},{"protocol":"UDP","port":"443","source":"any","source_detail":"any"}]},{"name":"target-fw","virtual_machine_ids":[2],"rules":[{"protocol":"TCP","port":"22","source":"any","source_detail":"any"}]}]}
EOF
printf 'APPROVED=YES\nACTION=APPLY_HOSTINGER_FIREWALL\nHOSTNAME=%s\nMACHINE_ID=%s\n' "$(hostname -f)" "$(cat /etc/machine-id)" > "$t/approval"
chmod 0600 "$t/approval"
run(){ PATH="$t/bin:$PATH" MOCK_STATE="$t/state" HOSTINGER_API_TOKEN=synthetic MIGRATION_APPROVAL=APPLY_HOSTINGER_FIREWALL MIGRATION_APPROVAL_FILE="$t/approval" "$@"; }
run "$toolkit/hostinger-firewall-apply.sh" --apply "$t/policy.json" "$t/one.tsv" --allow-vm 1 --allow-vm 2 --management-source any >/dev/null
grep -q 'PASS.apply-verified' "$t/one.tsv"; run "$toolkit/hostinger-firewall-apply.sh" --apply "$t/policy.json" "$t/two.tsv" --allow-vm 1 --allow-vm 2 --management-source any >/dev/null
grep -q 'PASS.apply-verified' "$t/two.tsv"
SYNC_DELAY_ONCE=1 HOSTINGER_SYNC_POLL_SECONDS=0 run "$toolkit/hostinger-firewall-apply.sh" --apply "$t/policy.json" "$t/sync.tsv" --allow-vm 1 --allow-vm 2 --management-source any >/dev/null
grep -q 'synced=true' "$t/sync.tsv"
PATH="$t/bin:$PATH" MOCK_STATE="$t/state" HOSTINGER_API_TOKEN=synthetic "$toolkit/hostinger-firewall-export.sh" --json "$t/out.json" --csv "$t/out.csv" >/dev/null
jq -e '.firewalls[]|select(.name=="unassigned" and (.virtual_machine_ids|length==0))' "$t/out.json" >/dev/null; grep -q 'unassigned.*TCP.*22' "$t/out.csv"
cp "$t/policy.json" "$t/bad.json"; jq '.firewalls += [.firewalls[0]]' "$t/bad.json">"$t/x";mv "$t/x" "$t/bad.json"
if run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/bad.json" "$t/bad.tsv" --allow-vm 1 --allow-vm 2 --management-source any >/dev/null 2>&1;then exit 1;fi
if FAIL_ON='GET:/firewall' run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/policy.json" "$t/net.tsv" --allow-vm 1 --allow-vm 2 --management-source any >/dev/null 2>&1;then exit 1;fi
cat >"$t/policy.csv" <<'EOF'
firewall_name,virtual_machine_id,protocol,port,source,source_detail
csv-source,1,TCP,22,any,any
csv-target,2,TCP,22,any,any
csv-target,2,UDP,443,any,any
EOF
run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/policy.csv" "$t/csv.tsv" --allow-vm 1 --allow-vm 2 --management-source any >/dev/null
grep -q 'group=csv-source.*rules=1' "$t/csv.tsv"; grep -q 'group=csv-target.*rules=2' "$t/csv.tsv"
jq '.firewalls[0].rules[0].source_detail="198.51.100.0/24"' "$t/policy.json">"$t/manage.json"
if run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/manage.json" "$t/manage.tsv" --allow-vm 1 --allow-vm 2 --management-source 203.0.113.0/24 >/dev/null 2>&1;then exit 1;fi
jq '.firewalls[].rules[0]={"protocol":"TCP","port":"22","source":"custom","source_detail":"203.0.113.7"}' "$t/policy.json">"$t/cidr.json"
run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/cidr.json" "$t/cidr.tsv" --allow-vm 1 --allow-vm 2 --management-source 203.0.113.7 >/dev/null
if run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/cidr.json" "$t/invalid-cidr.tsv" --allow-vm 1 --allow-vm 2 --management-source 999.0.0.1 >/dev/null 2>&1;then exit 1;fi
# "any" is valid only when the operator explicitly authorizes it.  A fixed
# management source must never silently accept a world-open SSH rule.
if run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/policy.json" "$t/unapproved-any.tsv" --allow-vm 1 --allow-vm 2 --management-source 203.0.113.7 >/dev/null 2>&1;then exit 1;fi
# Every supplied source must be covered, and no wider CIDR may stand in for a
# specifically authorized address.
jq '.firewalls[].rules[0]={"protocol":"TCP","port":"22","source":"custom","source_detail":"203.0.113.7"} | .firewalls[].rules += [{"protocol":"TCP","port":"22","source":"custom","source_detail":"203.0.113.8"}]' "$t/policy.json">"$t/two-management.json"
run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/two-management.json" "$t/two-management.tsv" --allow-vm 1 --allow-vm 2 --management-source 203.0.113.7 --management-source 203.0.113.8 >/dev/null
if run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/two-management.json" "$t/missing-management.tsv" --allow-vm 1 --allow-vm 2 --management-source 203.0.113.7 --management-source 203.0.113.9 >/dev/null 2>&1;then exit 1;fi
jq '.firewalls[].rules[0]={"protocol":"TCP","port":"22","source":"custom","source_detail":"203.0.113.0/24"}' "$t/policy.json">"$t/broader-management.json"
if run "$toolkit/hostinger-firewall-apply.sh" --dry-run "$t/broader-management.json" "$t/broader-management.tsv" --allow-vm 1 --allow-vm 2 --management-source 203.0.113.7 >/dev/null 2>&1;then exit 1;fi
mkdir "$t/failstate"; cp "$t/state/vms.json" "$t/failstate/vms.json"; cp "$t/state/firewalls.json" "$t/failstate/firewalls.json"
if FAIL_ON='POST:/firewall/100/activate/1' PATH="$t/bin:$PATH" MOCK_STATE="$t/failstate" HOSTINGER_API_TOKEN=synthetic MIGRATION_APPROVAL=APPLY_HOSTINGER_FIREWALL MIGRATION_APPROVAL_FILE="$t/approval" "$toolkit/hostinger-firewall-apply.sh" --apply "$t/policy.json" "$t/mid.tsv" --allow-vm 1 --allow-vm 2 --management-source any >/dev/null 2>&1;then exit 1;fi
grep -q PARTIAL_FAILURE "$t/mid.tsv"; test -s "$t/mid.tsv.before.json"; test -s "$t/mid.tsv.recovery.json"
printf 'PASS\thostinger-firewall\tsuccess, rerun, CSV isolation, export, duplicate, strict management coverage/anti-any, sync polling, disconnect and partial-failure guards\n'
