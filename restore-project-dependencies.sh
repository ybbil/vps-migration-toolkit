#!/bin/bash
# RETIRED — לא להרצה. מטרה היסטורית: שחזור Composer/npm/pip.
# בטיחות: יציאה בקוד 64 מונעת package scripts ויציאות רשת לא מאושרות.
# תוצאה רצויה: שחזור ידני לכל פרויקט רק לאחר העתקת הקוד.
printf 'RETIRED: restore-project-dependencies.sh must not be run; restore per project manually.\n' >&2
exit 64
set -euo pipefail
set +x
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib/common.sh"

mode=${1:-}
plan=${2:-}
report=${3:-}
case $mode in --dry-run|--apply) ;; *) die "usage: $0 --dry-run|--apply PROJECT_DEPENDENCIES.tsv REPORT" ;; esac
[ "$#" -eq 3 ] || die "usage: $0 --dry-run|--apply PLAN.tsv REPORT"
need_file "$plan"
safe_report_path "$report"
[ "$(head -n1 "$plan")" = $'project_path\tmanager\tinstall_mode\taction' ] || die 'invalid project dependency plan header'
if [ "$mode" = --apply ]; then require_target_marker; require_approval RESTORE_PROJECT_DEPENDENCIES; fi
printf 'status\tproject\tmanager\taction\tdetail\n' > "$report"

while IFS=$'\t' read -r project manager install_mode action; do
  [ "$project" = project_path ] && continue
  case $project in /var/www/*|/home/*/projects/*|/opt/*|/srv/*) ;; *) die "unsafe project path: $project" ;; esac
  case $action in install|omit) ;; *) die "invalid action: $action" ;; esac
  [ "$action" = install ] || { printf 'PASS\t%s\t%s\tomit\tapproved omission\n' "$project" "$manager" >> "$report"; continue; }
  need_dir "$project"
  case $manager in
    composer)
      need_cmd composer; need_file "$project/composer.lock"
      (cd "$project" && composer validate --no-check-publish >/dev/null)
      if [ "$mode" = --apply ]; then
        args=(install --no-interaction --prefer-dist --optimize-autoloader)
        [ "$install_mode" != production ] || args+=(--no-dev)
        (cd "$project" && composer "${args[@]}")
      fi
      ;;
    npm)
      need_cmd npm; need_file "$project/package-lock.json"
      (cd "$project" && npm pkg get name >/dev/null)
      if [ "$mode" = --apply ]; then
        if [ "$install_mode" = production ]; then (cd "$project" && npm ci --omit=dev); else (cd "$project" && npm ci); fi
      fi
      ;;
    pip)
      need_cmd python3; need_file "$project/requirements.txt"
      [ "$mode" = --dry-run ] || die 'pip apply requires a separately approved virtualenv path; automatic global pip install is forbidden'
      ;;
    *) die "unsupported dependency manager: $manager" ;;
  esac
  printf 'PASS\t%s\t%s\t%s\tlockfile validated; mode=%s\n' "$project" "$manager" "$action" "$mode" >> "$report"
done < "$plan"
printf 'SUMMARY\t-\t-\t%s\tcomplete\n' "$mode" >> "$report"
note 'rollback: restore the target snapshot or remove only dependency directories created from the reviewed lockfile; never modify source projects'
