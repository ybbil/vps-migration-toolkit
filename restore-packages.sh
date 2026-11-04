#!/bin/bash
# מטרה: להתקין ביעד את החבילות שסומנו manual בגרסאות המקור המדויקות.
# בטיחות: Dry-run ו-APT simulation קודמים ל-Apply; Apply דורש target marker,
# snapshot מאושר וחסימת service starts באמצעות policy-rc.d.
# תוצאה רצויה: החבילות הידניות מותקנות ללא הפעלה מוקדמת של שירותי היישום.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
inventory=${2:-}
report=${3:-}
defer_file=${MIGRATION_DEFER_FILE:-}
case $mode in --dry-run|--apply) ;; *) die "usage: $0 --dry-run|--apply INVENTORY_DIR REPORT.tsv" ;; esac
[ "$#" -eq 3 ] || die "usage: $0 --dry-run|--apply INVENTORY_DIR REPORT.tsv"
need_dir "$inventory"
need_file "$inventory/dpkg-packages.tsv"
need_file "$inventory/SHA256SUMS"
need_file "$inventory/apt-manual.txt"
[ -z "$defer_file" ] || need_file "$defer_file"
for command in apt-get apt-cache dpkg-query awk systemctl; do need_cmd "$command"; done
safe_report_path "$report"
# שלב 1: אימות שלמות inventory לפני חישוב שינוי כלשהו.
(
  cd "$inventory"
  sha256sum -c SHA256SUMS >/dev/null
)

tmp=$(mktemp "${report}.tmp.XXXXXX")
spec_file=$(mktemp /tmp/package-specs.XXXXXX)
trap 'rm -f -- "$tmp" "$spec_file"' EXIT
printf 'status\tpackage\tsource_version\ttarget_version\taction\n' > "$tmp"
: > "$spec_file"
failures=0

while IFS=$'\t' read -r package version architecture status; do
  [ "$package" = package ] && continue
  [[ $status == ii* ]] || continue
  if dpkg-query -s "$package" >/dev/null 2>&1; then target_version=$(dpkg-query -W -f='${Version}' "$package"); else target_version=''; fi
  if [ "$target_version" = "$version" ]; then
    printf 'PASS\t%s\t%s\t%s\tnone\n' "$package" "$version" "$target_version" >> "$tmp"
    continue
  fi
  package_without_arch=${package%%:*}
  if ! grep -Fxq "$package" "$inventory/apt-manual.txt" && ! grep -Fxq "$package_without_arch" "$inventory/apt-manual.txt"; then
    printf 'VERIFY\t%s\t%s\t%s\tdependency-or-base-package-not-forced\n' "$package" "$version" "${target_version:-MISSING}" >> "$tmp"
    continue
  fi
  if [ -n "$defer_file" ] && { grep -Fxq "$package" "$defer_file" || grep -Fxq "$package_without_arch" "$defer_file"; }; then
    printf 'DEFER\t%s\t%s\t%s\toperator-deferred\n' "$package" "$version" "${target_version:-MISSING}" >> "$tmp"
    continue
  fi
  candidate=$(apt-cache policy "$package" | awk '/Candidate:/ {print $2; exit}')
  if apt-cache madison "$package" | awk '{print $3}' | grep -Fxq "$version"; then
    printf '%s=%s\n' "$package" "$version" >> "$spec_file"
    printf 'PLAN\t%s\t%s\t%s\tinstall-exact\n' "$package" "$version" "${target_version:-MISSING}" >> "$tmp"
  else
    printf 'STOP\t%s\t%s\t%s\tunavailable-in-configured-repositories(candidate=%s)\n' "$package" "$version" "${target_version:-MISSING}" "$candidate" >> "$tmp"
    failures=$((failures + 1))
  fi
done < "$inventory/dpkg-packages.tsv"

# שלב 2: כל גרסה חסרה היא STOP; לאחר מכן מורצת סימולציית APT בלבד.
if [ "$failures" -gt 0 ]; then
  printf 'SUMMARY\t-\t-\t-\tstop_conditions=%d\n' "$failures" >> "$tmp"
  mv -- "$tmp" "$report"
  trap - EXIT
  rm -f -- "$spec_file"
  exit 1
fi

mapfile -t specs < "$spec_file"
if [ "${#specs[@]}" -gt 0 ]; then
  apt-get -s --no-install-recommends install "${specs[@]}" >> "$tmp" 2>&1 || die 'APT simulation failed'
fi

if [ "$mode" = --apply ]; then
  # שלב 3: Apply מותר רק ביעד מזוהה ולאחר snapshot חיצוני מאושר.
  need_root
  require_target_marker
  require_approval APPLY_PACKAGES
  snapshot_marker=${MIGRATION_SNAPSHOT_MARKER:-/run/vps-migration-snapshot-approved}
  grep -Fxq 'TARGET_SNAPSHOT_CONFIRMED=YES' "$snapshot_marker" || die "snapshot approval marker missing: $snapshot_marker"

  # שלב 4: מונעים maintainer scripts מלהפעיל שירותים במהלך ההתקנה.
  policy=/usr/sbin/policy-rc.d
  created_policy=0
  cleanup_policy() { [ "$created_policy" -eq 0 ] || rm -f -- "$policy"; }
  trap 'cleanup_policy; rm -f -- "$tmp" "$spec_file"' EXIT
  if [ -e "$policy" ]; then
    [ -x "$policy" ] || die "$policy exists but is not executable"
    set +e
    "$policy" migration-probe start >/dev/null 2>&1
    policy_rc=$?
    set -e
    [ "$policy_rc" -eq 101 ] || die "existing policy-rc.d does not deny service starts (rc=$policy_rc)"
  else
    printf '#!/bin/sh\nexit 101\n' > "$policy"
    chmod 0755 "$policy"
    created_policy=1
  fi

  blocked_units=(cron apache2 mariadb postfix dovecot opendkim)
  for unit in "${blocked_units[@]}"; do
    systemctl is-active --quiet "$unit" && die "service must be inactive before package apply: $unit" || true
  done
  [ "${#specs[@]}" -eq 0 ] || DEBIAN_FRONTEND=noninteractive apt-get --no-install-recommends install "${specs[@]}"

  # שלב 5: מחילים holds רק על חבילות שקיימות ומוודאים שהשירותים נשארו כבויים.
  if [ -s "$inventory/apt-holds.txt" ]; then
    while IFS= read -r held; do
      [ -n "$held" ] || continue
      dpkg-query -s "$held" >/dev/null 2>&1 || die "cannot hold missing package: $held"
      apt-mark hold "$held"
    done < "$inventory/apt-holds.txt"
  fi
  for unit in "${blocked_units[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || die "could not disable forbidden service after package installation: $unit"
    systemctl is-active --quiet "$unit" && die "package installation activated forbidden service: $unit" || true
    enabled_state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    case "$enabled_state" in disabled|masked|not-found|'') ;; *) die "forbidden service remains enabled after package installation: $unit ($enabled_state)" ;; esac
  done
  cleanup_policy
  created_policy=0
fi

# שלב 6: התוצאה הרצויה היא דוח COMPLETE; rollback נשאר snapshot ספק.
printf 'SUMMARY\t-\t-\t-\tstop_conditions=0;mode=%s\n' "$mode" >> "$tmp"
mv -- "$tmp" "$report"
trap - EXIT
rm -f -- "$spec_file"
note "package restore report: $report"
note 'rollback: restore the target snapshot; package downgrades/removals are not automated'
