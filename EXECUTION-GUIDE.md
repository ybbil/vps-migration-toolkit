# מדריך הרצה מפורט — העברת VPS

מדריך זה הוא סדר ההפעלה המחייב של ערכת ההעברה. הוא אינו אישור לבצע מעבר. פקודות המסומנות **שינוי** דורשות אישור נפרד, Snapshot תקף ו־Provider Console זמין.

## מוסכמות

- **מקור** — ה־VPS הפעיל שממנו מעבירים.
- **יעד** — ה־VPS החדש והמבודד.
- **תחנת בקרה** — המקום שבו נשמרים הדוחות ומשווים תוצאות.
- `<...>` — ערך שחובה להחליף בערך בדוק; אין להדביק פקודה עם placeholder.
- `PASS` אינו מספיק אם בדוח קיים גם `STOP`, ‏`FAIL`, ‏`MISSING` או mismatch לא מוסבר.
- אין להריץ סקריפט שמסומן `RETIRED`; הוא יוצא בקוד 64 בכוונה.

## 1. אימות ערכת הכלים — תחנת בקרה

### 1.1 `validate-toolkit.sh`

מה הוא עושה: בודק תחביר Bash, מבנה מטריצת הכיסוי, קיום תוצרים ו־guard של כל הסקריפטים המנוטרלים. אינו בודק Restore אמיתי.

```bash
bash /root/vps-migration-toolkit/validate-toolkit.sh
```

תוצאה רצויה:

```text
SUMMARY failures=0
```

מתי ממשיכים: רק כאשר אין שורת `FAIL`. ‏`SKIP ShellCheck` מותר זמנית רק אם הוא מתועד כחסם.

### 1.2 `tests/run-fixture-tests.sh`

מה הוא עושה: מריץ נתונים סינתטיים ב־`/tmp` וב־`/dev/shm`; בודק payload של זהויות, collisions, checksums, guards, סקריפטים מנוטרלים ו־MariaDB מדומה. אינו משנה חשבונות או מסד אמיתי.

```bash
bash /root/vps-migration-toolkit/tests/run-fixture-tests.sh
```

תוצאה רצויה:

```text
SUMMARY all PASS
```

מתי ממשיכים: רק כאשר כל בדיקות הבטיחות הן `PASS`. יש לקרוא את `test-results.txt`, לא להסתפק בקוד היציאה.

**STOP:** כשל תחביר, fixture שנכשל, retired script שהצליח לרוץ, או שינוי לא מוסבר בתוצאות.

## 2. הכנת יעד מבודד — יעד, שינוי המחייב אישור

### 2.1 פעולות ספק שאינן פקודות Shell

1. לפתוח ולבדוק Provider Console בפועל; עצם קיומו של קישור לממשק אינו מספיק.
2. לפני כל שינוי Firewall, לוודא Console פעיל וחיבור SSH חלופי. בשלב הבידוד מגבילים ב־UFW של היעד ל־CIDR ניהול; אין ליצור או לשייך עדיין קבוצת Hostinger.
3. להשאיר Apache, MariaDB, cron, timers, Postfix, Dovecot ו־OpenDKIM כבויים.
4. לבצע Snapshot ספק, להמתין לסטטוס `completed/ready`, ולאמת בממשק הספק שמזהה ה־VPS, זמן היצירה ומזהה ה־Snapshot נכונים.
5. לוודא שה־hostname ו־machine-id שונים מאלה של המקור.

`/run/vps-migration-snapshot-approved` הוא הצהרת מפעיל מקומית בלבד. הוא אינו מתקשר ל־API של הספק, אינו בודק שה־Snapshot קיים ואינו מוכיח שניתן לשחזר אותו. אסור ליצור אותו לפני אימות ידני בממשק הספק.

### 2.2 בדיקות Preflight לקריאה בלבד

מריצים את הבלוק הבא ב־Shell אחד. `set -Eeuo pipefail` ו־trap מרכזי מבטיחים שכל פקודה קריטית שנכשלת מדפיסה `STOP` ומפסיקה מיד; אין בדיקות `test` שיכולות להיכשל בשקט:

```bash
set -Eeuo pipefail
trap 'rc=$?; printf "STOP: preflight failed (rc=%s) at: %s\n" "$rc" "$BASH_COMMAND" >&2' ERR
stop() { printf 'STOP: %s\n' "$*" >&2; return 1; }
pass() { printf 'PASS: %s\n' "$*"; }

read -r -p 'Source FQDN: ' SOURCE_FQDN
read -r -p 'Source machine-id: ' SOURCE_MACHINE_ID
test -n "$SOURCE_FQDN" || stop 'source FQDN is empty'
test -n "$SOURCE_MACHINE_ID" || stop 'source machine-id is empty'
test "$(id -u)" -eq 0 || stop 'run preflight as root on the target'
test -r /etc/os-release || stop '/etc/os-release is missing or unreadable'
test -s /etc/machine-id || stop '/etc/machine-id is missing or empty'
TARGET_FQDN=$(hostname -f)
TARGET_MACHINE_ID=$(cat /etc/machine-id)
test -n "$TARGET_FQDN" || stop 'target FQDN is empty'
test -n "$TARGET_MACHINE_ID" || stop 'target machine-id is empty'
test "$TARGET_FQDN" != "$SOURCE_FQDN" || stop 'target FQDN equals source FQDN'
test "$TARGET_MACHINE_ID" != "$SOURCE_MACHINE_ID" || stop 'target machine-id equals source machine-id'
test ! -e /etc/vps-migration-source || stop 'source marker exists on target'
pass 'target identity differs from source'

cat /etc/os-release
printf 'TARGET_FQDN=%s\nTARGET_MACHINE_ID=%s\n' "$TARGET_FQDN" "$TARGET_MACHINE_ID"
uname -m
df -hT / /var /var/tmp
free -h

MIN_ROOT_FREE_GIB=${MIN_ROOT_FREE_GIB:-10}
MIN_VAR_FREE_GIB=${MIN_VAR_FREE_GIB:-20}
MIN_VARTMP_FREE_GIB=${MIN_VARTMP_FREE_GIB:-10}
check_free_gib() { path=$1; minimum_gib=$2; available_kib=$(df -Pk "$path" | awk 'NR==2 {print $4}'); required_kib=$((minimum_gib * 1024 * 1024)); test "$available_kib" -ge "$required_kib" || stop "insufficient free space on $path: need at least ${minimum_gib} GiB"; pass "free space on $path is at least ${minimum_gib} GiB"; }
check_free_gib / "$MIN_ROOT_FREE_GIB"
check_free_gib /var "$MIN_VAR_FREE_GIB"
check_free_gib /var/tmp "$MIN_VARTMP_FREE_GIB"

ip -br address
ip route show
ip -6 route show
ip route show default | grep -q . || stop 'no IPv4 default route'
read -r -p 'Is IPv6 required on the new VPS? [yes/no]: ' REQUIRE_IPV6
case "$REQUIRE_IPV6" in
  yes) ip -6 route show default | grep -q . || stop 'IPv6 was required but no IPv6 default route exists'; pass 'IPv6 default route is available' ;;
  no) pass 'IPv6 was explicitly marked not required for this migration' ;;
  *) stop 'answer yes or no for IPv6 requirement' ;;
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

if command -v sshd >/dev/null 2>&1; then
  sshd -t || stop 'sshd configuration validation failed'
  pass 'sshd configuration is valid'
else
  stop 'sshd command is missing'
fi

blocked_units=(
  cron.service crond.service anacron.service atd.service
  apache2.service nginx.service php8.2-fpm.service php8.3-fpm.service php8.4-fpm.service
  mariadb.service mysql.service
  postfix.service dovecot.service opendkim.service
  docker.service docker.socket containerd.service podman.service podman.socket
  unattended-upgrades.service
)
systemctl list-units --no-pager >/dev/null || stop 'cannot query systemd manager'
for unit in "${blocked_units[@]}"; do
  load_state=$(systemctl show "$unit" -p LoadState --value 2>/dev/null) || stop "cannot query systemd unit: $unit"
  test "$load_state" != loaded || {
    active_state=$(systemctl is-active "$unit" 2>/dev/null || true)
    enabled_state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    case "$active_state" in inactive|unknown) ;; *) stop "$unit is active or activating: $active_state" ;; esac
    case "$enabled_state" in disabled|masked|not-found|'') ;; *) stop "$unit can start automatically: $enabled_state" ;; esac
    pass "$unit is inactive and not enabled"
  }
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
```

תוצאה רצויה: השורה האחרונה היא `PASS: target preflight completed without a critical failure`. זהות היעד שונה מהמקור, ספי הדיסק עברו, DNS ו־route קיימים, `rsync` תומך ACL/xattrs, SSH תקין, כל השירותים הרלוונטיים inactive וגם disabled/masked, ואין timers או path units מאופשרים.

מתי ממשיכים: רק לאחר בדיקת כל הפלט, review של קובצי cron שנמצאו, התחברות SSH נוספת מחלון נפרד ואימות Console אצל הספק. אם מתקבל `STOP`, מטפלים בגורם באישור נפרד ומריצים את כל ה־Preflight מחדש מתחילתו.

### 2.3 יצירת markers — שינוי, רק אחרי Snapshot מאושר

ה־marker אינו הוכחה ל־Snapshot. לפני יצירתו פותחים את ממשק הספק ומוודאים שה־Snapshot נמצא בסטטוס מוכן ושייך ל־VPS הנכון. לאחר מכן מזינים את מזהה ה־Snapshot ומאשרים ידנית:

```bash
set -Eeuo pipefail
stop() { printf 'STOP: %s\n' "$*" >&2; return 1; }
read -r -p 'Verified provider snapshot ID or visible reference: ' PROVIDER_SNAPSHOT_REFERENCE
read -r -p 'Type SNAPSHOT-VERIFIED-IN-PROVIDER-CONSOLE: ' SNAPSHOT_CONFIRMATION
test -n "$PROVIDER_SNAPSHOT_REFERENCE" || stop 'provider snapshot reference is empty'
test "$SNAPSHOT_CONFIRMATION" = 'SNAPSHOT-VERIFIED-IN-PROVIDER-CONSOLE' || stop 'provider snapshot was not explicitly confirmed'

{
  printf '%s\n' 'ISOLATED_VPS_MIGRATION_TARGET=YES'
  printf 'HOSTNAME=%s\n' "$(hostname -f)"
  printf 'MACHINE_ID=%s\n' "$(cat /etc/machine-id)"
} > /etc/vps-migration-target

{
  printf '%s\n' 'TARGET_SNAPSHOT_CONFIRMED=YES'
  printf 'PROVIDER_SNAPSHOT_REFERENCE=%s\n' "$PROVIDER_SNAPSHOT_REFERENCE"
  printf 'VERIFIED_AT=%s\n' "$(date --iso-8601=seconds)"
  printf 'TARGET_HOSTNAME=%s\n' "$(hostname -f)"
  printf 'TARGET_MACHINE_ID=%s\n' "$(cat /etc/machine-id)"
} > /run/vps-migration-snapshot-approved
```

מה הפעולה עושה: marker היעד קושר פעולות Apply לזהות המכונה. Snapshot marker מתעד את הצהרת המפעיל, מזהה ה־Snapshot וזמן הבדיקה בלבד; הוא עדיין אינו מאמת מול הספק שה־Snapshot קיים או ניתן לשחזור.

תוצאה רצויה:

```bash
grep -Fx 'ISOLATED_VPS_MIGRATION_TARGET=YES' /etc/vps-migration-target
grep -Fx "HOSTNAME=$(hostname -f)" /etc/vps-migration-target
grep -Fx "MACHINE_ID=$(cat /etc/machine-id)" /etc/vps-migration-target
grep -Fx 'TARGET_SNAPSHOT_CONFIRMED=YES' /run/vps-migration-snapshot-approved
grep -Fx "PROVIDER_SNAPSHOT_REFERENCE=$PROVIDER_SNAPSHOT_REFERENCE" /run/vps-migration-snapshot-approved
grep -Fx "TARGET_MACHINE_ID=$(cat /etc/machine-id)" /run/vps-migration-snapshot-approved
```

מתי ממשיכים: רק אחרי שכל שש הבדיקות מחזירות שורה אחת, מזהה ה־Snapshot תואם לממשק הספק, וה־Snapshot מסומן שם כ־ready/completed. בדיקת Restore של ה־Snapshot נשארת Gate נפרד לפני שינוי קריטי.

**STOP:** אין Console, אין Snapshot, או marker שנוצר בטעות במקור.

## 3. מלאי חבילות — מקור, קריאה בלבד

### 3.1 `export-package-inventory.sh`

מה הוא עושה: אוסף חבילות dpkg, חבילות שסומנו manual, holds, ארכיטקטורות, גרסאות כלים ו־APT sources ציבוריים. הוא אינו מתקין דבר ואינו מעתיק APT credentials.

```bash
bash ./export-package-inventory.sh '<NEW_OUTPUT_DIRECTORY>'
```

דרישות:

- ספריית הפלט אינה קיימת.
- יש די מקום ל־inventory.
- הפלט נשמר בהרשאות 0700.

תוצאה רצויה:

- `STATUS` מכיל `COMPLETE`.
- `diagnostics.log` ריק.
- `SHA256SUMS` קיים ועובר אימות.
- קיימים `dpkg-packages.tsv`,‏ `apt-manual.txt`,‏ `apt-holds.txt` ו־`platform.tsv`.

בדיקה:

```bash
cd '<NEW_OUTPUT_DIRECTORY>'
sha256sum -c SHA256SUMS
cat STATUS
```

מתי ממשיכים: רק כאשר כל checksums תקינים ואין diagnostics. מעבירים את ה־inventory ליעד בערוץ מאושר; אין בו password hashes, אך עדיין יש להגן על מידע תשתיתי.

## 4. Repositories וחבילות — יעד

### 4.1 Repositories — ידני

אין להריץ `restore-apt-sources.sh`; הוא `RETIRED`.

מה עושים: מגדירים ידנית repositories שמתאימים ל־distribution ול־codename של היעד. משווים ל־inventory רק לצורך זיהוי vendor repositories.

בדיקות:

```bash
apt-get update
apt-cache policy
```

מתי ממשיכים: רק כאשר אין repository שגוי, unsigned repository או credential חסר.

### 4.2 `restore-packages.sh --dry-run`

מה הוא עושה: משווה את החבילות המותקנות ל־inventory, דורש גרסאות מדויקות עבור manual packages ומריץ `apt-get -s`. אינו מתקין דבר ב־Dry-run.

```bash
bash ./restore-packages.sh --dry-run '<INVENTORY_DIRECTORY>' package-plan.tsv
```

תוצאה רצויה:

- אין `STOP`.
- כל package להתקנה מופיע כ־`PLAN`.
- סימולציית APT מסתיימת בהצלחה.
- אין הסרה או downgrade בלתי צפויים בפלט הסימולציה.

מתי ממשיכים: לאחר review ידני של `package-plan.tsv` ושל פלט APT.

### 4.3 `restore-packages.sh --apply` — שינוי

מה הוא עושה: מתקין רק manual packages שאושרו. יוצר זמנית `policy-rc.d` אם אינו קיים, דורש שהשירותים הקריטיים כבויים ובודק שלא הופעלו לאחר ההתקנה.

```bash
MIGRATION_APPROVAL=APPLY_PACKAGES \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./restore-packages.sh --apply '<INVENTORY_DIRECTORY>' package-apply.tsv
```

תוצאה רצויה:

- `stop_conditions=0`.
- השירותים `cron`,‏ `apache2`,‏ `mariadb`,‏ `postfix`,‏ `dovecot` ו־`opendkim` נשארו כבויים.
- `policy-rc.d` זמני הוסר; policy קיים מראש לא שונה.
- כל hold מתייחס לחבילה מותקנת.

אימות:

```bash
for unit in cron apache2 mariadb postfix dovecot opendkim; do
  systemctl is-active "$unit"
done
bash ./export-package-inventory.sh '<NEW_TARGET_INVENTORY>'
bash ./compare-package-inventory.sh \
  '<SOURCE_INVENTORY>' '<NEW_TARGET_INVENTORY>' package-compare.tsv
```

מתי ממשיכים: רק כאשר אין service פעיל ואין package חסר. Target-only packages עוברים review ואינם מוסרים אוטומטית.

**ROLLBACK:** Snapshot ספק. הסקריפט אינו מבצע downgrade/removal אוטומטי.

## 5. זהויות Linux — מקור ואז יעד

### 5.1 Marker מקור — שינוי חד־פעמי המחייב אישור

```bash
{
  printf '%s\n' 'ACTIVE_VPS_MIGRATION_SOURCE=YES'
  printf 'HOSTNAME=%s\n' "$(hostname -f)"
  printf 'MACHINE_ID=%s\n' "$(cat /etc/machine-id)"
} > /etc/vps-migration-source
```

מה הפעולה עושה: מאפשרת רק ל־Export המאושר לפעול על המכונה שסומנה כמקור. אין ליצור marker יעד במקור.

### 5.2 `export-linux-identities.sh --preflight` — מקור

מה הוא עושה: מאמת את allowlist, UID/GID, recipient ונתיב פלט חדש. אינו קורא shadow ואינו יוצר archive. שמות Linux קיימים עם אותיות גדולות מותרים; קבוצות שמסומנות `omit` לא ישוחזרו כחברות משלימה של משתמש.

```bash
bash ./export-linux-identities.sh --preflight \
  identity-allowlist.tsv \
  'gpg:<40_HEX_FINGERPRINT>' \
  linux-identities.tar.enc
```

תוצאה רצויה:

```text
PASS: identity allowlist, IDs, encryption recipient and output path are valid
```

מתי ממשיכים: לאחר review שכל משתמש/קבוצה הוא `custom-create`,‏ `package-verify` או `omit` כראוי.

### 5.3 `export-linux-identities.sh --execute` — מקור, Export רגיש

מה הוא עושה: קורא passwd/shadow/group/gshadow, memberships ו־authorized_keys של `custom-create`; מייצר fingerprints של sudo לביקורת בלבד; מצפין הכול. אינו מייצא private keys או קובצי sudo. עבור GPG ההצפנה משתמשת רק בטביעת אצבע מלאה שנבדקה מראש; אין להחליף אותה בשם או ב־key ID מקוצר.

```bash
MIGRATION_APPROVAL=EXPORT_LINUX_IDENTITIES \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./export-linux-identities.sh --execute \
  identity-allowlist.tsv \
  'gpg:<40_HEX_FINGERPRINT>' \
  linux-identities.tar.enc
```

תוצאה רצויה:

- `linux-identities.tar.enc` קיים ואינו ריק.
- `linux-identities.tar.enc.sha256` תקין.
- אין plaintext payload מחוץ ל־tmpfs.

מתי ממשיכים: רק לאחר העברה מוצפנת ליעד ואימות checksum לפני הפענוח.

### 5.4 `validate-identity-payload.sh` — יעד

מפענחים ידנית לנתיב חדש תחת `/dev/shm`, ואז:

```bash
bash ./validate-identity-payload.sh '<DECRYPTED_TMPFS_STAGE>'
```

מה הוא עושה: בודק schemas, checksums, קבצים עודפים, private keys, sudo payload ושייכות authorized_keys ל־`custom-create`.

תוצאה רצויה:

```text
PASS: identity payload contract and checksums are valid
```

מתי ממשיכים: רק לאחר PASS. אין לתקן ידנית payload שנכשל; מפיקים אותו מחדש מהמקור.

### 5.5 `import-linux-identities.sh --dry-run` — יעד

```bash
bash ./import-linux-identities.sh --dry-run \
  '<DECRYPTED_TMPFS_STAGE>' identity-plan.tsv
```

מה הוא עושה: מפעיל את `plan-linux-identity-import.sh`, בודק name/UID/GID collision, home, shell, memberships ומצב hash. אינו משנה חשבונות.

תוצאה רצויה:

- `STOP_COUNT=0`.
- כל `package-verify` הוא `VERIFY` בלבד.
- כל חשבון חדש מופיע כ־`CREATE` צפוי.
- sudo מופיע כ־`REVIEW` בלבד.

מתי ממשיכים: אחרי Snapshot חדש, session SSH חלופי ו־review של כל שורה.

### 5.6 `import-linux-identities.sh --apply` — יעד, שינוי רגיש

```bash
MIGRATION_APPROVAL=APPLY_LINUX_IDENTITIES \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./import-linux-identities.sh --apply \
  '<DECRYPTED_TMPFS_STAGE>' \
  identity-apply.tsv \
  '<NEW_TMPFS_JOURNAL_DIRECTORY>'
```

מה הוא עושה: יוצר רק קבוצות ומשתמשי `custom-create`, משחזר hash/account aging, memberships ו־authorized_keys. אינו משנה `package-verify` ואינו מתקין sudo.

תוצאה רצויה:

- `APPLY_COMPLETED` קיים ב־journal.
- UID/GID/home/shell תואמים.
- fingerprints של authorized_keys תואמים.
- session הניהול הקיים והחלופי נשארים פתוחים.

מתי ממשיכים: רק לאחר login test בחיבור SSH חדש. את sudo ממזגים ידנית ל־fragment מצומצם ומריצים `visudo -cf` לפני install ו־`visudo -c` אחריו.

**ROLLBACK:** Snapshot ספק מועדף. `rollback-linux-identities.sh` הוא כלי חירום בלבד, כשהיעד אינו משרת תעבורה.

## 6. העתקת קבצים — יעד מושך מהמקור

אין להריץ `sync-files.sh` או `restore-files.sh`; שניהם `RETIRED`.

### 6.1 Dry-run לכל root

כאשר המקור והיעד צריכים להיות אותו נתיב, אין להשתמש ב־`--relative` ואין להשתמש ב־`/./`. ה־trailing slash בשני הצדדים מעתיק את תוכן הספרייה בדיוק לתוך הספרייה המקבילה:

```bash
rsync -aHAXn --numeric-ids --itemize-changes --protect-args \
  --rsync-path='sudo -n rsync' \
  '<SOURCE_ALIAS>:/var/www/' '/var/www/'
```

מה הפקודה עושה: משווה ומציג מה יועתק תוך שמירת ownership מספרי, ACL, xattrs, hardlinks ו־symlinks. `-n` מונע כתיבה.

#### גישת source מוגבלת עבור ההעברה הנוכחית

במקרה זה הוגדר בשרת המקור מפתח ייעודי של היעד שמוגבל ל־`rrsync -ro -absolute /var/www`,‏ לכתובת `168.231.113.72` בלבד וללא shell או forwarding. לכן ה־root הראשון משתמש ב־root של המקור ישירות ואינו מעביר `--rsync-path='sudo -n rsync'` (פקודה כזו תידחה בכוונה על ידי ה־forced command). לאחר אימות host key של המקור, פקודת ה־Dry-run היא:

```bash
rsync -aHAXn --numeric-ids --itemize-changes --old-args \
  --exclude='aspnet/' --exclude='**/node_modules/***' \
  -e 'ssh -4 -i /root/.ssh/id_vps_migration_pull_ed25519 -o IdentitiesOnly=yes' \
  'root@srv1119587.hstgr.cloud:/var/www/' '/var/www/'
```

פקודה זו אינה מעתיקה דבר. אין להרחיב את הרשאת המפתח ל־roots נוספים בלי אישור מפורש, ואסור להחליף את ה־IP או את ה־forced command בלי בדיקת host key מחדש.

מיפוי שנבדק ב־fixture עם `rsync --dry-run --out-format='%n'`:

| מקור | יעד | מיקום קובץ צפוי |
|---|---|---|
| `/var/www/` | `/var/www/` | `/var/www/site/index.php` |
| `/var/mail/` | `/var/mail/` | `/var/mail/example/Maildir/cur/msg` |
| `/var/mail-hooks-data/` | `/var/mail-hooks-data/` | `/var/mail-hooks-data/state/one` |

בכל שלושת המקרים ה־fixture אישר שאין קינון כגון `/var/www/var/www`.

מריצים פקודה נפרדת לכל root מאושר:

```bash
rsync -aHAXn --numeric-ids --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/var/www/' '/var/www/'
rsync -aHAXn --numeric-ids --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/var/mail/' '/var/mail/'
rsync -aHAXn --numeric-ids --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/var/mail-hooks-data/' '/var/mail-hooks-data/'
rsync -aHAXn --numeric-ids --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/opt/radio/' '/opt/radio/'
rsync -aHAXn --numeric-ids --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/home/tools_dev/projects/' '/home/tools_dev/projects/'
```

תוצאה רצויה: הפלט מכיל paths יחסיים לתוך ה־root בלבד. אין prefix כפול, `/var/lib/mysql`, private keys לא מאושרים, cache מיותר או נתיב יעד רחב.

### 6.2 סנכרון ראשוני — שינוי

לאחר Snapshot ואישור משתמשים בדיוק באותה פקודה של ה־root המאושר ומסירים רק את `n` מ־`-aHAXn`. אין להוסיף `--relative`,‏ `/./` או `--delete`.

תוצאה רצויה: הנתונים הראשוניים קיימים ביעד עם UID/GID/ACL/xattrs תקינים. שירותים נשארים כבויים.

### 6.3 בדיקת תוכן

```bash
bash ./generate-content-manifest.sh \
  '<SOURCE_ROOTS.tsv>' source-content.tsv '<SECRETS.tsv>'
bash ./generate-content-manifest.sh \
  '<TARGET_ROOTS.tsv>' target-content.tsv '<SECRETS.tsv>'
bash ./compare-content-manifests.sh \
  source-content.tsv target-content.tsv content-compare.tsv
```

תוצאה רצויה: `failures=0` עבור roots קפואים. קבצים mutable דורשים חלון עצירת כתיבות לפני ההשוואה הסופית.

מתי ממשיכים: לאחר בדיקת בעלויות, ACL ו־checksums, ולפני התקנת configs או הפעלת שירותים.

### 6.4 המסלול המדויק להעברה הראשונית של `/var/mail`

המסלול הזה מופעל רק לאחר אישור מפורש של החלטות ה־keep/omit ב־`START-HERE.md`. אין להעתיק את Postfix queue (`/var/spool/postfix`) ואין להשתמש במפתח של root אחר.

1. ביעד יוצרים מפתח ייעודי ללא passphrase ושומרים את הציבורי לצורך התקנה מבוקרת במקור:

   ```bash
   ssh-keygen -t ed25519 -f /root/.ssh/id_vps_migration_pull_var_mail_ed25519 -N '' -C 'migration-pull-var-mail'
   ssh-keygen -lf /root/.ssh/id_vps_migration_pull_var_mail_ed25519.pub
   ```

2. במקור מוסיפים ל־`/root/.ssh/authorized_keys` שורה אחת בלבד, לאחר החלפת `<PUBLIC_KEY>` בתוכן המפתח הציבורי ובדיקה שאין שבירת שורה:

   ```text
   from="168.231.113.72",restrict,command="/usr/bin/rrsync -ro -absolute /var/mail" ssh-ed25519 <PUBLIC_KEY> migration-pull-var-mail
   ```

   לפני ההוספה מאמתים ש־`/usr/bin/rrsync` קיים ושכלל ה־UFW הזמני מתיר TCP/22 רק מ־`168.231.113.72`. אין לתת shell, forwarding, כתיבה או root נוסף.

3. ביעד מאמתים תנאי התחלה: host key של המקור הוא ED25519 fingerprint ‏`SHA256:mJ+N913ychV/xcv1GAdm4cHFF+VyEb1a/Stn7SMvC4k`; יש מקום פנוי; `getent passwd vmail` ו־`getent group vmail` מחזירים UID/GID ‏5000; ו־`systemctl is-active` וגם `systemctl is-enabled` עבור `postfix`,‏ `dovecot` ו־`cron` אינם מצביעים על שירות פעיל/מופעל.

4. ביעד מריצים Dry-run ומודדים זמן. `--old-args` נדרש כי forced `rrsync` במקור חוסם בכוונה את `-s` של `--protect-args`; הנתיבים כאן קבועים ואינם מקבלים קלט משתמש:

   ```bash
   time rsync -aHAXn --numeric-ids --itemize-changes --old-args --stats \
     -e 'ssh -4 -i /root/.ssh/id_vps_migration_pull_var_mail_ed25519 -o IdentitiesOnly=yes' \
     'root@srv1119587.hstgr.cloud:/var/mail/' '/var/mail/'
   ```

   חייבים לראות רק paths יחסיים תחת `/var/mail/`, לרבות `vhosts/yeshivatrabenu.site/...`, העץ המילולי `vhosts/%d/%n/...` וקובצי ה־mbox הישירים. עוצרים על `deleting`,‏ `/var/spool/postfix`, root אחר, קינון כפול, שגיאת host key או הרשאה.

5. לאחר review ו־אישור כתיבה נפרד מריצים את פקודת ההעתקה; ההבדל היחיד מפקודת ה־Dry-run הוא הסרת `n`:

   ```bash
   time rsync -aHAX --numeric-ids --itemize-changes --old-args --stats \
     -e 'ssh -4 -i /root/.ssh/id_vps_migration_pull_var_mail_ed25519 -o IdentitiesOnly=yes' \
     'root@srv1119587.hstgr.cloud:/var/mail/' '/var/mail/'
   ```

6. ביעד מריצים בדיקת checksum לקריאה בלבד:

   ```bash
   time rsync -aHAXnc --numeric-ids --itemize-changes --old-args --stats \
     -e 'ssh -4 -i /root/.ssh/id_vps_migration_pull_var_mail_ed25519 -o IdentitiesOnly=yes' \
     'root@srv1119587.hstgr.cloud:/var/mail/' '/var/mail/'
   ```

   מתעדים זמן, exit code,‏ `Number of regular files transferred`,‏ `Total transferred file size` וכל path שהשתנה. אפס הבדלים הוא `PASS` לרגע המדידה בלבד. הבדל שנובע מהודעה שנמסרה בזמן הבדיקה הוא `MUTABLE`, לא כשל שמצדיק מחיקה; הוא דורש סנכרון נוסף ובדיקה סופית תחת freeze.

7. בתום ההעברה הראשונית מסירים במקור את שורת `migration-pull-var-mail` ואת כלל ה־UFW הזמני, וביעד מסירים את שני קובצי המפתח הייעודי, רק אחרי זיהוי מדויק ותיעוד. לקראת הסנכרון הסופי יוצרים מחדש הרשאה זמנית ומצומצמת באותה שיטה.

8. בסנכרון הסופי עוצרים תחילה Postfix/Dovecot ואת Sieve/hooks במקור, מאמתים queue inventory ומחליטים בנפרד כיצד לרוקן או לשמר אותו. מריצים שוב את שלבים 4–6 ללא `--delete`. שירותי הדואר ביעד נשארים כבויים עד שכל Gates של פרק 9 עברו.

## 7. תצורות, סודות ואוטומציה — ידני

אין להריץ את כלי config/secrets/automation המסומנים `RETIRED`.

סדר עבודה:

1. `rsync` תצורות מהמקור ל־staging נפרד ביעד, לעולם לא ישירות ל־`/etc`. כאן בלבד משתמשים ב־`--relative` וב־`/./`, כשהיעד הוא שורש ה־staging:

   ```bash
   rsync -aHAXn --numeric-ids --relative --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/./etc/apache2/' '<CONFIG_STAGE_ROOT>/'
   rsync -aHAXn --numeric-ids --relative --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/./etc/php/' '<CONFIG_STAGE_ROOT>/'
   rsync -aHAXn --numeric-ids --relative --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/./etc/mysql/' '<CONFIG_STAGE_ROOT>/'
   rsync -aHAXn --numeric-ids --relative --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/./etc/postfix/' '<CONFIG_STAGE_ROOT>/'
   rsync -aHAXn --numeric-ids --relative --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/./etc/dovecot/' '<CONFIG_STAGE_ROOT>/'
   rsync -aHAXn --numeric-ids --relative --itemize-changes --protect-args --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/./etc/opendkim/' '<CONFIG_STAGE_ROOT>/'
   ```

   ה־fixture אישר שהמיפוי הוא `<CONFIG_STAGE_ROOT>/etc/apache2/...` ו־`<CONFIG_STAGE_ROOT>/etc/postfix/...`, ללא prefix כפול. מסירים `-n` רק כדי להעתיק ל־staging המאושר; לעולם לא משנים את יעד הפקודות ל־`/etc/`.
2. `diff -ruN` מול תצורות החבילות ביעד.
3. merge ידני של directive נדרש בלבד.
4. lint מתאים לפני install.
5. secrets מועברים ב־archive מוצפן מ־allowlist, מפוענחים ל־tmpfs ומותקנים אחד־אחד.
6. cron, timers, Sieve ו־hooks מותקנים disabled.

תוצאה רצויה: כל config עבר lint; כל secret קיבל owner/mode צפויים; אין automation פעיל.

מתי ממשיכים: רק לאחר review נפרד ל־SSH, Apache/PHP, MariaDB, Postfix/Dovecot/OpenDKIM, Firewall ו־WireGuard.

## 8. MariaDB — מקור ואז יעד

### 8.1 `mariadb-backup-stream.sh --preflight` — מקור

```bash
bash ./mariadb-backup-stream.sh --preflight \
  '<0600_OPTION_FILE>' '<TARGET_SSH_ALIAS>' \
  '<NEW_ABSOLUTE_REMOTE_ARCHIVE.xbstream>' mariadb-preflight.tsv
```

מה הוא עושה: בודק credentials והרשאות מינימליות ל־MariaDB 11.8 (`SELECT`,‏ `RELOAD`,‏ `PROCESS`,‏ `LOCK TABLES`,‏ `BINLOG MONITOR`) ודוחה `ALL PRIVILEGES` והרשאות שינוי מיותרות. הוא מודד בקריאה בלבד את גודל ה־datadir, בודק tmpdir מקומי ייעודי ואת נפח היעד לפי הגודל הצפוי ומרווח בטיחות, וכן התאמת major.minor,‏ SSH host key, marker יעד ונתיב archive חדש שאינו נעול. אינו מתחיל backup ואינו יוצר archive במקור.

תוצאה רצויה: שלוש בדיקות `PASS` עבור backup version, server version ו־remote path.

מתי ממשיכים: לאחר אישור חלון עומס וניטור I/O/latency במקור.

### 8.2 `mariadb-backup-stream.sh --execute` — מקור, כתיבה ליעד

```bash
MIGRATION_APPROVAL=STREAM_MARIADB_BACKUP \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./mariadb-backup-stream.sh --execute \
  '<0600_OPTION_FILE>' '<TARGET_SSH_ALIAS>' \
  '<NEW_ABSOLUTE_REMOTE_ARCHIVE.xbstream>' mariadb-backup.tsv
```

מה הוא עושה: מפעיל hot physical backup לקריאה בלבד, עם `--tmpdir` ו־target-dir זמני קטן שנמחק בסיום, ומזרים אותו ל־`.partial` ביעד תחת נעילה שבבעלות token ייחודי. לאחר הצלחת הזרם הוא מאמת שוב בעלות ומפרסם ללא דריסה בסדר archive,‏ SHA-256 ולבסוף `<archive>.COMPLETE`. רק COMPLETE תקין מכשיר שחזור.

תוצאה רצויה: `PASS stream complete`, archive,‏ checksum ו־COMPLETE תואמים, ללא `.partial` או lock פעילים. ארכיון ללא COMPLETE אינו כשיר לשחזור.

מתי ממשיכים: לאחר ניטור שהמקור נשאר תקין ואימות checksum ביעד.

### 8.3 `mariadb-restore.sh --dry-run` — יעד

```bash
bash ./mariadb-restore.sh --dry-run \
  '<ARCHIVE.xbstream>' '/var/tmp/mariadb-restore.TRIAL' \
  /var/lib/mysql mariadb-restore-plan.tsv
```

מה הוא עושה: דורש COMPLETE ומאמת את התאמתו לנתיב, לגודל ול־checksum של ה־archive; בודק כלי MariaDB,‏ major.minor, נתיב prepared ונפח מינימלי. אינו מבצע extract ב־Dry-run.

תוצאה רצויה: PASS עבור checksum, backup tool, target server ו־free space.

מתי ממשיכים: רק כאשר MariaDB כבוי, datadir ריק, Snapshot תקף והיעד מבודד.

### 8.4 `mariadb-restore.sh --apply` — יעד, שינוי קריטי

```bash
MIGRATION_APPROVAL=RESTORE_MARIADB \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./mariadb-restore.sh --apply \
  '<ARCHIVE.xbstream>' '/var/tmp/mariadb-restore.TRIAL' \
  /var/lib/mysql mariadb-restore.tsv
```

מה הוא עושה: חוסם symlink בכל רכיב של `/var/lib/mysql`, ודורש שגם systemd, גם שמות התהליכים `mariadbd`/`mysqld` וגם שימוש בפועל ב־datadir יהיו נקיים. לאחר extract הוא בודק metadata ומחשב מקום נוסף בלבד ל־prepare,‏ copy-back ומרווח ביטחון, בלי ספירה כפולה. לאחר מכן הוא מריץ prepare ו־copy-back ומתקן ownership. אינו מפעיל MariaDB.

תוצאה רצויה: `PASS copy-back complete; server remains stopped` ולאחריו `PENDING restore-trial` עד להפעלה מבודדת ואימות מלא.

### 8.5 `verify-mariadb.sh` — בדיקת Restore

מפעילים MariaDB רק ברשת המבודדת, ואז:

```bash
bash ./verify-mariadb.sh --target \
  '<TARGET_0600_OPTION_FILE>' mariadb-target-audit.tsv
```

מה הוא עושה: `--target` מפיק מדדים, `COUNT(*)` מדויק ו־`mariadb-check`. במקור משתמשים תחילה ב־`--source-light`, שמדלג במפורש על שתי הבדיקות הכבדות; `--source-heavy` דורש אישור נפרד `AUDIT_MARIADB_SOURCE_HEAVY`. הגדרות משתמשים ו־grants אינם נשמרים גולמיים: נשמרים fingerprints מסוג SHA-256 בלבד, וכל קובצי הדוח במצב 0600.

כל `require_approval` דורש גם משתנה פעולה וגם קובץ 0400/0600 בן ארבע שורות: `APPROVED=YES`,‏ `ACTION=<ACTION>`,‏ `HOSTNAME=<hostname -f>`,‏ `MACHINE_ID=<machine-id>`. הקובץ קושר את האישור לפעולה ולשרת; שרת שמסומן בו־זמנית כמקור וכיעד נחסם.

תוצאה רצויה: `mariadb-check` ללא שגיאות ומדדים תואמים לדוח מקור שהופק בנפרד.

מתי ממשיכים: לאחר בדיקת grants/roles, Roundcube/PostfixAdmin ובדיקת read/write של כל יישום.

### 8.6 חיבורי `NewAPI` ו־`NewAPI_DEV` בזמן ניסוי ולאחר Cutover

ברירת המחדל המחייבת לניסוי Restore היא בידוד: לאחר Restore הניסוי ביעד, `NewAPI` ו־`NewAPI_DEV` ביעד מתחברים ל־MariaDB המשוחזר המקומי בלבד, דרך `localhost` או socket מקומי מאושר. אין לפתוח MariaDB במקור, אין לשנות grants או Firewall במקור, ואין להפנות את היישומים ביעד אל מסד המקור לצורך הניסוי הרגיל.

מתעדים את הקבצים ששונו ואת ערכי ה־host בלבד (ללא סיסמאות), ומוכיחים לכל אחד משני היישומים חיבור, קריאה וכתיבה מבוקרת מול ה־DB המשוחזר והמבודד. לאחר ה־cutover, אותה מדיניות מקומית נשארת בתוקף.

חריג של חיבור זמני מהיעד אל DB המקור אינו חלק ממסלול זה. הוא דורש צורך מתועד, אישור מפורש ונפרד, IP יעד קבוע ומאומת, grant צר לפי משתמש/מסד בלבד, כלל Firewall מצומצם ותוכנית הסרה. חריג כזה אינו יכול להחליף את בדיקת ה־Restore המבודדת.

**STOP:** היישום מצביע אל המקור ללא אישור חריג, גישת המקור רחבה מהנדרש, אחד הקבצים אינו מצביע אל DB היעד לאחר Restore, או בדיקת חיבור/כתיבה נכשלת.

**ROLLBACK:** לעצור MariaDB ולשחזר Snapshot יעד. אין להפעיל Restore על המקור.

## 9. דואר, Firewall ו־WireGuard — Gates ידניים

אין סקריפט Apply אוטומטי לרכיבים אלה.

לפני המשך חייבים להשלים:

- Postfix/Dovecot/OpenDKIM config lint.
- TLS תקף ל־hostnames הנכונים.
- IMAP/SMTP submission ובדיקת DKIM/SPF/DMARC/PTR.
- queue inventory ותוכנית ownership של delivery יחיד.
- Firewall בשני שלבים: תחילה UFW יעד לפי access matrix (SSH ניהולי לפני הכול, Console וחיבור חלופי); רק לפני חשיפת שירות ציבורי מכינים קבוצת Hostinger חדשה ונפרדת, משווים אותה ל־UFW, מריצים dry-run ומחילים באישור נפרד.
- WireGuard `wg-quick strip`, routing ו־NAT ללא הפעלה מוקדמת.

### 9.1 סדר הבדיקה המדויק של Mail hook

אין להפעיל את `/opt/mail-hook/bin/mailhook.sh`: הוא מפנה ל־`/opt/mail-hook/bin/mail_hook.php`, שאינו קיים. המסלול המועמד היחיד שנמצא הוא Sieve‏ `pipe :copy "mailhook"` →‏ `/etc/dovecot/sieve-pipe/mailhook` →‏ `/usr/bin/php /var/www/mail-hooks/process_incoming.php` → קריאה מ־`php://stdin`. גם מסלול זה אינו מאושר להפעלה עד השלמת כל השלבים הבאים:

1. מעתיקים את תצורות Postfix, Dovecot, Sieve ו־OpenDKIM ל־staging בלבד, ומשווים אותן לברירות המחדל של החבילות ביעד. אין לדרוס `/etc` ואין להעתיק מפתחות TLS פרטיים מהמקור.
2. מאתרים בתצורה את ה־Sieve הגלובלי/`sieve_before`, ומוכיחים שהוא מצביע לקובץ שמכיל בדיוק את `pipe :copy "mailhook"`. אם אין reference פעיל, לא “מתקנים” לפי השערה — מסמנים `STOP`.
3. בודקים שה־wrapper המוצע הוא קובץ root-owned, אינו writable לקבוצות/אחרים, ומפעיל בדיוק `/usr/bin/php /var/www/mail-hooks/process_incoming.php` ללא shell expansion או נתיב חלופי.
4. מריצים lint בלבד: `doveconf -n`,‏ `postfix check`, קומפילציית Sieve באמצעות `sievec` על עותק ה־staging, ו־`php -l /var/www/mail-hooks/process_incoming.php`. כל פקודה נבדקת תחילה כקריאה בלבד או כנגד staging; אין start/reload.
5. סוקרים את קוד ה־PHP וממפים כל side effect: DB, קבצים, HTTP, queue או שליחת דואר. מוודאים קריאה מ־`php://stdin`, טיפול בכשל, idempotency/logging, secret names והרשאות. אין להציג ערכי סודות בתיעוד.
6. מגדירים sink בדיקה מבודד או mock לכל side effect, ומעבירים ל־wrapper הודעת RFC822 סינתטית שאינה מכילה דואר אמיתי. הבדיקה חייבת להוכיח שהודעה אחת יוצרת לכל היותר פעולה אחת וש־`:copy` אינו בולע את המסירה הרגילה.
7. מוודאים single execution owner: המקור והיעד אינם מפעילים את אותו hook במקביל; `/opt/mail-hook` נשאר disabled/staging; ואין cron, timer או pipe שני שמפעיל את אותו PHP.
8. רק לאחר PASS לכל הסעיפים מתקינים את התצורה המאושרת ביעד כשהשירותים עדיין כבויים. לאחר cutover מבצעים בדיקת דואר חיצונית אחת, עוקבים אחר Dovecot/Sieve/PHP/Postfix logs ומוודאים לפי Message-ID פעולה יחידה ומסירה רגילה.

**STOP:** reference חסר, wrapper שונה, PHP חסר/נכשל ב־lint, side effect שאינו מבודד, סוד חסר, הרשאות רחבות, עיבוד כפול או אי־יכולת לקשר פעולה ל־Message-ID.

תוצאה רצויה: שירותי הדואר וה־VPN עדיין כבויים, אך כל התצורות עוברות lint וכל בדיקות הגישה המתוכננות מאושרות.

## 10. אימות מערכת יעד

### 10.1 `verify-restored-system.sh`

```bash
bash ./verify-restored-system.sh operational-checks.tsv
```

מה הוא עושה: config tests עבור רכיבים מותקנים ומתעד listeners. הוא אינו מוכיח שהיישומים עובדים מבחוץ.

תוצאה רצויה: `failures=0` ורק listeners צפויים על כתובות צפויות.

### 10.2 `compare-source-target.sh`

```bash
bash ./compare-source-target.sh \
  '<SOURCE_MANIFEST_DIRECTORY>' \
  '<FRESH_TARGET_MANIFEST_DIRECTORY>' \
  source-target.tsv
```

מה הוא עושה: משווה משתמשים, קבוצות, memberships, permissions, config/mail paths ו־SSH fingerprints.

תוצאה רצויה: `failures=0`, או רשימה קצרה של הבדלים שאושרו במפורש.

מתי ממשיכים: רק לאחר בדיקות HTTP, DB, SMTP, IMAP, TLS, DNS ו־IPv6 מבחוץ.

## 11. סנכרון סופי ו־Cutover

סדר מחייב:

1. Snapshot יעד חדש ועדכון Snapshot marker.
2. עצירת כתיבות ביישומים במקור.
3. השבתת cron, timers, Sieve, hooks ו־mail delivery במקור וביעד.
4. rsync סופי של נתונים mutable באמצעות אותן פקודות direct-path מפרק 6.1, ללא `--relative`,‏ `/./` או `--delete`.
5. MariaDB backup ו־Restore סופיים.
6. אימות שחיבורי `NewAPI` ו־`NewAPI_DEV` ביעד מצביעים ל־`localhost` (או socket מקומי מאושר), ובדיקת read/write מול ה־DB המשוחזר.
7. סנכרון Maildir; queue מטופל בנפרד ורק כאשר שני Postfix כבויים.
8. checksums והשוואות חדשות.
9. הפעלת MariaDB, לאחר מכן יישומים, לאחר מכן דואר, ולבסוף automation — רכיב אחד בכל פעם.
10. שינוי DNS רק לאחר שכל מדדי ההצלחה עברו.

תוצאה רצויה: רכיב אחד בלבד מעבד כל job או הודעת דואר; אין כתיבות במקביל לשני הצדדים.

**STOP:** כל mismatch, שירות שהופעל מוקדם, queue לא מוסבר, listener לא צפוי או בדיקת end-to-end שנכשלה.

## 12. Rollback ו־Reconciliation

1. לעצור מיד כתיבות ו־delivery ביעד.
2. לשמור Snapshot ועותק reconciliation של כל נתון חדש שנוצר ביעד.
3. להחזיר routing/DNS למקור.
4. להפעיל את המקור רק לאחר שהוכח שאין processor מקביל ביעד.
5. למזג ידנית נתונים חדשים לפי מפתח עסקי, Message-ID או content hash.

אין לבצע reverse-rsync עיוור ואין למחוק את נתוני היעד לפני reconciliation.

## 13. סקריפטים שאסור להריץ

הסקריפטים הבאים נשמרו לעיון בלבד ומחזירים exit code ‏64:

- `build-config-plan.sh`
- `export-secrets.sh`
- `mail-migration.sh`
- `restore-apt-sources.sh`
- `restore-automation.sh`
- `restore-configs.sh`
- `restore-files.sh`
- `restore-project-dependencies.sh`
- `restore-secrets.sh`
- `restore-security-policy.sh`
- `sync-files.sh`

שני סקריפטי rollback המקומיים הם **EMERGENCY ONLY** ואינם חלק ממסלול רגיל. Snapshot ספק הוא מנגנון החזרה העיקרי.
