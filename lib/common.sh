#!/bin/bash

# מטרה: ספריית פונקציות משותפת לכלי ההעברה; הקובץ אינו מיועד להרצה ישירה.
# בטיחות: כל מצב שינוי חייב לזהות בוודאות מקור או יעד לפי hostname ו-machine-id,
# לדרוש אסימון אישור ייחודי, ולהשתמש ב-tmpfs עבור חומר רגיש.
# תוצאה רצויה: עצירה מוקדמת לפני פעולה על השרת הלא נכון או עם קלט חסר.

set -euo pipefail
set +x
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need_file() { [ -f "$1" ] || die "required file not found: $1"; }
need_dir() { [ -d "$1" ] || die "required directory not found: $1"; }
need_root() { [ "$(id -u)" -eq 0 ] || die 'root privileges are required'; }

require_target_marker() {
  local marker=${MIGRATION_TARGET_MARKER:-/etc/vps-migration-target}
  local current_hostname current_machine_id
  # שלב בטיחות: מאמתים שה-marker שייך למכונה הנוכחית ולא הועתק משרת אחר.
  [ -f "$marker" ] || die "target marker missing: $marker"
  grep -Fxq 'ISOLATED_VPS_MIGRATION_TARGET=YES' "$marker" || die "invalid target marker: $marker"
  current_hostname=$(hostname -f)
  current_machine_id=$(cat /etc/machine-id)
  grep -Fxq "HOSTNAME=$current_hostname" "$marker" || die "target marker hostname mismatch: $marker"
  grep -Fxq "MACHINE_ID=$current_machine_id" "$marker" || die "target marker machine-id mismatch: $marker"
  reject_dual_role_identity target
  # תוצאה רצויה: הפעולה מורשית רק ב-VPS היעד המבודד שסומן במפורש.
}

require_source_marker() {
  local marker=${MIGRATION_SOURCE_MARKER:-/etc/vps-migration-source}
  local current_hostname current_machine_id
  # שלב בטיחות: פעולת export כבדה מאומתת מול זהות שרת המקור.
  [ -f "$marker" ] || die "source marker missing: $marker"
  grep -Fxq 'ACTIVE_VPS_MIGRATION_SOURCE=YES' "$marker" || die "invalid source marker: $marker"
  current_hostname=$(hostname -f)
  current_machine_id=$(cat /etc/machine-id)
  grep -Fxq "HOSTNAME=$current_hostname" "$marker" || die "source marker hostname mismatch: $marker"
  grep -Fxq "MACHINE_ID=$current_machine_id" "$marker" || die "source marker machine-id mismatch: $marker"
  reject_dual_role_identity source
  # תוצאה רצויה: אין אפשרות להפעיל export רגיש על מכונה אחרת בטעות.
}

marker_matches_current_identity() {
  local marker=$1 role_line=$2 current_hostname current_machine_id
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  current_hostname=$(hostname -f)
  current_machine_id=$(cat /etc/machine-id)
  grep -Fxq "$role_line" "$marker" &&
    grep -Fxq "HOSTNAME=$current_hostname" "$marker" &&
    grep -Fxq "MACHINE_ID=$current_machine_id" "$marker"
}

reject_dual_role_identity() {
  local requested_role=$1
  local source_marker=${MIGRATION_SOURCE_MARKER:-/etc/vps-migration-source}
  local target_marker=${MIGRATION_TARGET_MARKER:-/etc/vps-migration-target}
  if marker_matches_current_identity "$source_marker" 'ACTIVE_VPS_MIGRATION_SOURCE=YES' &&
     marker_matches_current_identity "$target_marker" 'ISOLATED_VPS_MIGRATION_TARGET=YES'; then
    die "refusing $requested_role mutation: this server is marked as both source and target"
  fi
}

require_approval() {
  local expected=$1 actual=${MIGRATION_APPROVAL:-} approval_file=${MIGRATION_APPROVAL_FILE:-}
  local current_hostname current_machine_id mode
  [ "$actual" = "$expected" ] || die "set MIGRATION_APPROVAL=$expected for this apply operation"
  [ -n "$approval_file" ] || die 'MIGRATION_APPROVAL_FILE is required in addition to MIGRATION_APPROVAL'
  [ "${approval_file:0:1}" = / ] || die 'approval file path must be absolute'
  require_no_symlink_components "$approval_file"
  [ -f "$approval_file" ] && [ ! -L "$approval_file" ] || die "approval file missing or unsafe: $approval_file"
  mode=$(stat -c %a -- "$approval_file")
  case $mode in 400|600) ;; *) die "approval file must have mode 0400 or 0600: $approval_file" ;; esac
  current_hostname=$(hostname -f)
  current_machine_id=$(cat /etc/machine-id)
  [ "$(awk 'NF {count++} END {print count+0}' "$approval_file")" -eq 4 ] || die 'approval file must contain exactly four records'
  grep -Fxq 'APPROVED=YES' "$approval_file" || die 'approval file lacks APPROVED=YES'
  grep -Fxq "ACTION=$expected" "$approval_file" || die "approval file is not scoped to action $expected"
  grep -Fxq "HOSTNAME=$current_hostname" "$approval_file" || die 'approval file hostname mismatch'
  grep -Fxq "MACHINE_ID=$current_machine_id" "$approval_file" || die 'approval file machine-id mismatch'
}

require_tmpfs_path() {
  local path=$1 fs
  need_dir "$path"
  fs=$(stat -f -c %T -- "$path")
  [ "$fs" = tmpfs ] || die "sensitive staging must be on tmpfs, got $fs: $path"
}

safe_report_path() {
  local path=$1 parent canonical_parent base lexical_parent
  [ -n "$path" ] || die 'empty report path'
  parent=$(dirname -- "$path")
  [ -d "$parent" ] || die "report parent does not exist: $parent"
  if [ "${parent:0:1}" = / ]; then lexical_parent=$parent; else lexical_parent=$PWD/$parent; fi
  lexical_parent=$(realpath -ms -- "$lexical_parent")
  require_no_symlink_components "$lexical_parent"
  canonical_parent=$(realpath -e -- "$parent") || die "cannot canonicalize report parent: $parent"
  require_no_symlink_components "$canonical_parent"
  base=$(basename -- "$path")
  case $base in ''|.|..|*/*) die "unsafe report basename: $base" ;; esac
  [ ! -e "$canonical_parent/$base" ] && [ ! -L "$canonical_parent/$base" ] || die "refusing to overwrite report path: $canonical_parent/$base"
}

canonical_existing_path() {
  local path=$1 canonical
  need_cmd realpath
  canonical=$(realpath -e -- "$path") || die "cannot canonicalize existing path: $path"
  [ "$canonical" = "$path" ] || die "path must already be canonical: $path (resolved: $canonical)"
  printf '%s\n' "$canonical"
}

require_no_symlink_components() {
  local path=$1 current=/ component
  path=${path#/}
  [ -n "$path" ] || die 'root is not an allowed operation path'
  IFS=/ read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [ -n "$component" ] || continue
    current=${current%/}/$component
    [ ! -L "$current" ] || die "symlink component is not allowed: $current"
  done
}

require_fresh_snapshot_marker() {
  local marker=$1 max_age_seconds=${2:-86400}
  local current_hostname current_machine_id verified_at verified_epoch now_epoch age
  [ "${marker:0:1}" = / ] || die "snapshot marker path must be absolute: $marker"
  [ -f "$marker" ] && [ ! -L "$marker" ] || die "snapshot approval marker missing or unsafe: $marker"
  require_no_symlink_components "$marker"
  grep -Fxq 'TARGET_SNAPSHOT_CONFIRMED=YES' "$marker" || die "invalid snapshot approval marker: $marker"
  current_hostname=$(hostname -f)
  current_machine_id=$(cat /etc/machine-id)
  grep -Fxq "TARGET_HOSTNAME=$current_hostname" "$marker" || die "snapshot marker hostname mismatch: $marker"
  grep -Fxq "TARGET_MACHINE_ID=$current_machine_id" "$marker" || die "snapshot marker machine-id mismatch: $marker"
  verified_at=$(sed -n 's/^VERIFIED_AT=//p' "$marker")
  [ -n "$verified_at" ] || die "snapshot marker lacks VERIFIED_AT: $marker"
  verified_epoch=$(date -d "$verified_at" +%s 2>/dev/null) || die "invalid snapshot VERIFIED_AT: $verified_at"
  now_epoch=$(date +%s)
  age=$((now_epoch - verified_epoch))
  [ "$age" -ge 0 ] && [ "$age" -le "$max_age_seconds" ] || die "snapshot verification is stale or future-dated: age=${age}s maximum=${max_age_seconds}s"
}

write_status() {
  local report=$1 status=$2 detail=$3
  printf '%s\t%s\t%s\n' "$(date --iso-8601=seconds)" "$status" "$detail" >> "$report"
}

cleanup_tree() {
  local path=$1 prefix=$2 canonical parent
  [ "${path:0:1}" = / ] && [ "${prefix:0:1}" = / ] || die 'cleanup path and prefix must be absolute'
  [ -d "$path" ] && [ ! -L "$path" ] || die "cleanup root must be a real directory: $path"
  require_no_symlink_components "$path"
  canonical=$(realpath -e -- "$path") || die "cannot canonicalize cleanup root: $path"
  [ "$canonical" = "$path" ] || die "cleanup root must be canonical: $path"
  parent=$(dirname -- "$path")
  case $path in "$prefix"?*) ;; *) die "refusing cleanup outside scoped prefix $prefix: $path" ;; esac
  [ "$parent" != / ] || die 'refusing cleanup directly below filesystem root'
  find -P "$path" -xdev -depth -delete
}
