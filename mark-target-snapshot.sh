#!/usr/bin/env bash
# Writes local target/snapshot attestations. It does not contact the provider.
set -Eeuo pipefail

snapshot_reference=${1:?usage: mark-target-snapshot.sh PROVIDER_SNAPSHOT_REFERENCE}
case "$snapshot_reference" in
  *$'\n'* | '') printf 'STOP: invalid provider snapshot reference\n' >&2; exit 64 ;;
esac
test "$(id -u)" -eq 0 || { printf 'STOP: run as root on the target\n' >&2; exit 1; }
test ! -e /etc/vps-migration-source || { printf 'STOP: source marker exists on target\n' >&2; exit 1; }

hostname_value=$(hostname -f)
machine_id=$(cat /etc/machine-id)
target_tmp=$(mktemp /etc/.vps-migration-target.XXXXXX)
snapshot_tmp=$(mktemp /run/.vps-migration-snapshot.XXXXXX)
trap 'rm -f "$target_tmp" "$snapshot_tmp"' EXIT
printf 'ISOLATED_VPS_MIGRATION_TARGET=YES\nHOSTNAME=%s\nMACHINE_ID=%s\n' "$hostname_value" "$machine_id" > "$target_tmp"
printf 'TARGET_SNAPSHOT_CONFIRMED=YES\nPROVIDER_SNAPSHOT_REFERENCE=%s\nVERIFIED_AT=%s\nTARGET_HOSTNAME=%s\nTARGET_MACHINE_ID=%s\n' "$snapshot_reference" "$(date --iso-8601=seconds)" "$hostname_value" "$machine_id" > "$snapshot_tmp"
install -m 0644 "$target_tmp" /etc/vps-migration-target
install -m 0644 "$snapshot_tmp" /run/vps-migration-snapshot-approved
trap - EXIT
rm -f "$target_tmp" "$snapshot_tmp"
printf 'PASS: target and snapshot markers written for %s\n' "$snapshot_reference"
