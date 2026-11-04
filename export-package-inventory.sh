#!/bin/bash
# מטרה: להפיק מלאי reproducible של חבילות Debian, holds, repositories וכלים חיצוניים.
# בטיחות: קריאה בלבד במערכת; נכתב רק OUTPUT_DIRECTORY חדש בהרשאות 0700.
# תוצאה רצויה: מלאי חתום ב-SHA256 ללא diagnostics מוסתרים.
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

out=${1:-}
[ "$#" -eq 1 ] || die "usage: $0 OUTPUT_DIRECTORY"
[ ! -e "$out" ] || die "output already exists: $out"
for command in dpkg-query apt-mark apt-cache find sha256sum timeout; do need_cmd "$command"; done
install -d -m 0700 "$out"
# שלב 1: אוספים את מצב dpkg ואת הבחירה הידנית; לא מתקינים דבר.
diagnostics="$out/diagnostics.log"
: > "$diagnostics"

printf 'package\tversion\tarchitecture\tstatus\n' > "$out/dpkg-packages.tsv"
dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n' 2>>"$diagnostics" |
  sort >> "$out/dpkg-packages.tsv"
apt-mark showmanual 2>>"$diagnostics" | sort > "$out/apt-manual.txt"
apt-mark showhold 2>>"$diagnostics" | sort > "$out/apt-holds.txt"

printf 'path\ttype\tuid\tgid\tmode\tsize\tmtime\tsymlink_target\n' > "$out/manual-installations.tsv"
# שלב 2: מתעדים התקנות ידניות בלבד; התוצאה היא inventory ולא backup.
for root in /usr/local /opt; do
  if [ -e "$root" ]; then
    find "$root" -xdev -maxdepth 4 -printf '%p\t%y\t%U\t%G\t%m\t%s\t%T@\t%l\n' 2>>"$diagnostics" >> "$out/manual-installations.tsv"
  fi
done

{
  printf 'os_release\t'; tr '\n' ';' < /etc/os-release; printf '\n'
  printf 'kernel\t%s\n' "$(uname -r)"
  printf 'architecture\t%s\n' "$(dpkg --print-architecture)"
  printf 'foreign_architectures\t%s\n' "$(dpkg --print-foreign-architectures | paste -sd, -)"
} > "$out/platform.tsv"

printf 'tool\tpath\tversion_line\n' > "$out/external-tools.tsv"
# שלב 3: בודקים גרסאות כלים בלי לשנות את התקנתם.
: > "$out/version-probe-diagnostics.log"
probe_version() {
  local command=$1 option=$2 probe_file rc
  probe_file=$(mktemp)
  # A broken vendor tool must not keep the inventory blocked or fill its diagnostics.
  if (ulimit -f 128; timeout --foreground -k 3s 12s "$command" "$option" >"$probe_file" 2>>"$out/version-probe-diagnostics.log"); then
    head -n 1 "$probe_file"
    rm -f "$probe_file"
    return 0
  fi
  rc=$?
  rm -f "$probe_file"
  printf 'probe failed: %s %s (rc=%s)\n' "$command" "$option" "$rc" >> "$out/version-probe-diagnostics.log"
  return 1
}

for command in php composer node npm python3 pip3 java dotnet mariadb apache2 postfix dovecot wg; do
  if command -v "$command" >/dev/null 2>&1; then
    printf 'INFO: probing version for %s\n' "$command" >&2
    path=$(command -v "$command")
    if version=$(probe_version "$command" --version); then
      :
    elif version=$(probe_version "$command" -version); then
      :
    else
      version=UNAVAILABLE
    fi
    printf '%s\t%s\t%s\n' "$command" "$path" "$version"
  fi
done >> "$out/external-tools.tsv"

# שלב 4: מעתיקים metadata ציבורי של APT; auth.conf אינו נכלל.
for path in /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/preferences /etc/apt/preferences.d /etc/apt/keyrings /etc/apt/trusted.gpg /etc/apt/trusted.gpg.d; do
  if [ -e "$path" ]; then cp -a --parents "$path" "$out"; fi
done

(
  # שלב 5: חותמים את כל התוצרים; תוצאה רצויה היא STATUS=COMPLETE.
  cd "$out"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
if [ -s "$diagnostics" ]; then
  printf 'INCOMPLETE\tdiagnostics.log is non-empty\n' > "$out/STATUS"
  die "package inventory emitted diagnostics: $diagnostics"
fi
printf 'COMPLETE\tpackage inventory generated without diagnostics\n' > "$out/STATUS"
note "package inventory created: $out"
