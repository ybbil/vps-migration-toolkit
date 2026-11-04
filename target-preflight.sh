#!/usr/bin/env bash
# Read-only target preflight. Run as root on the new VPS only.
set -Eeuo pipefail
trap 'rc=$?; printf "STOP: preflight failed (rc=%s) at: %s\n" "$rc" "$BASH_COMMAND" >&2' ERR
stop() { printf 'STOP: %s\n' "$*" >&2; return 1; }
pass() { printf 'PASS: %s\n' "$*"; }

source_fqdn=${SOURCE_FQDN:-srv1119587.hstgr.cloud}
source_machine_id=${SOURCE_MACHINE_ID:-9567a60107aa03267d9316fd75393c62}
require_ipv6=${REQUIRE_IPV6:-no}

test "$(id -u)" -eq 0 || stop 'run preflight as root on the target'
test -r /etc/os-release || stop '/etc/os-release is missing or unreadable'
test -s /etc/machine-id || stop '/etc/machine-id is missing or empty'
target_fqdn=$(hostname -f)
target_machine_id=$(cat /etc/machine-id)
test "$target_fqdn" != "$source_fqdn" || stop 'target FQDN equals source FQDN'
test "$target_machine_id" != "$source_machine_id" || stop 'target machine-id equals source machine-id'
test ! -e /etc/vps-migration-source || stop 'source marker exists on target'
pass 'target identity differs from source'

cat /etc/os-release
printf 'TARGET_FQDN=%s\nTARGET_MACHINE_ID=%s\n' "$target_fqdn" "$target_machine_id"
uname -m
df -hT / /var /var/tmp
free -h

check_free_gib() {
  local path=$1 minimum_gib=$2 available_kib required_kib
  available_kib=$(df -Pk "$path" | awk 'NR==2 {print $4}')
  required_kib=$((minimum_gib * 1024 * 1024))
  test "$available_kib" -ge "$required_kib" || stop "insufficient free space on $path: need at least ${minimum_gib} GiB"
  pass "free space on $path is at least ${minimum_gib} GiB"
}
check_free_gib / "${MIN_ROOT_FREE_GIB:-10}"
check_free_gib /var "${MIN_VAR_FREE_GIB:-20}"
check_free_gib /var/tmp "${MIN_VARTMP_FREE_GIB:-10}"

ip -br address
ip route show
ip -6 route show
ip route show default | grep -q . || stop 'no IPv4 default route'
case "$require_ipv6" in
  yes) ip -6 route show default | grep -q . || stop 'IPv6 was required but no IPv6 default route exists'; pass 'IPv6 default route is available' ;;
  no) pass 'IPv6 was explicitly marked not required for this migration' ;;
  *) stop 'REQUIRE_IPV6 must be yes or no' ;;
esac
getent hosts deb.debian.org >/dev/null || stop 'DNS resolution failed'
pass 'IPv4 default route and DNS resolution are available'
ss -H -lntup

for command in ssh rsync sha256sum gpg systemctl ip ss getent awk df; do
  command -v "$command" >/dev/null 2>&1 || stop "required command missing: $command"
done
pass 'required preflight commands are installed'
rsync_features=$(rsync --version)
grep -q 'no ACLs' <<< "$rsync_features" && stop 'rsync reports no ACL support'
grep -q 'no xattrs' <<< "$rsync_features" && stop 'rsync reports no xattr support'
grep -q 'ACLs' <<< "$rsync_features" || stop 'rsync lacks ACL support'
grep -q 'xattrs' <<< "$rsync_features" || stop 'rsync lacks xattr support'
pass 'rsync supports ACLs and xattrs'
sshd -t || stop 'sshd configuration validation failed'
pass 'sshd configuration is valid'

blocked_units=(cron.service crond.service anacron.service atd.service apache2.service nginx.service php8.2-fpm.service php8.3-fpm.service php8.4-fpm.service mariadb.service mysql.service postfix.service dovecot.service opendkim.service docker.service docker.socket containerd.service podman.service podman.socket unattended-upgrades.service)
systemctl list-units --no-pager >/dev/null || stop 'cannot query systemd manager'
for unit in "${blocked_units[@]}"; do
  load_state=$(systemctl show "$unit" -p LoadState --value 2>/dev/null) || stop "cannot query systemd unit: $unit"
  test "$load_state" != loaded && continue
  active_state=$(systemctl is-active "$unit" 2>/dev/null || true)
  enabled_state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
  case "$active_state" in inactive|unknown) ;; *) stop "$unit is active or activating: $active_state" ;; esac
  case "$enabled_state" in disabled|masked|not-found|'') ;; *) stop "$unit can start automatically: $enabled_state" ;; esac
  pass "$unit is inactive and not enabled"
done

systemctl list-timers --all --no-pager
enabled_timers=$(systemctl list-unit-files --type=timer --no-legend --no-pager | awk '$2 == "enabled" {print $1}') || stop 'cannot enumerate systemd timers'
test -z "$enabled_timers" || stop "enabled systemd timers require disable/review before migration: $(tr '\n' ' ' <<< "$enabled_timers")"
pass 'no enabled systemd timers remain'
enabled_paths=$(systemctl list-unit-files --type=path --no-legend --no-pager | awk '$2 == "enabled" {print $1}') || stop 'cannot enumerate systemd path units'
test -z "$enabled_paths" || stop "enabled systemd path units may trigger automation: $(tr '\n' ' ' <<< "$enabled_paths")"
pass 'no enabled systemd path units remain'
printf '%s\n' 'Cron definitions found; review is mandatory even while cron is disabled:'
find /etc/cron.d /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron -xdev -type f -print 2>/dev/null | sort || true
pass 'target preflight completed without a critical failure'
