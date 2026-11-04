# מסלול מינימלי להעברת VPS חד־פעמית

המסלול משתמש בשישה סקריפטי ליבה בלבד. יתר הפעולות הן פקודות Linux סטנדרטיות או Gate ידני. אין להריץ `--apply` או `--execute` ללא אישור נפרד, Snapshot ו־Restore trial.

## 1. תחנת בקרה — ללא שינוי שרת

```bash
bash /root/vps-migration-toolkit/validate-toolkit.sh
bash /root/vps-migration-toolkit/tests/run-fixture-tests.sh
```

**STOP:** כל `FAIL`, ‏`SKIP` לא מוסבר או שינוי קוד לא מאושר.

## 2. יעד — בידוד ו־Snapshot

לאחר אישור תשתית בלבד: מקימים VPS מבודד, מאמתים Console וחיבור SSH חלופי, ומגבילים ב־UFW את SSH ל־CIDR ניהול (עם deny incoming, allow outgoing ו־deny routed). Hostinger Firewall נשאר ללא שינוי וללא שיוך בשלב זה; לפני חשיפה ציבורית מכינים קבוצה חדשה ונפרדת שתשקף את מדיניות ה־UFW המאושרת. מבצעים Snapshot ומשאירים cron, timers, Apache, MariaDB ושירותי הדואר כבויים.

יצירת markers של יעד ו־Snapshot אינה מופיעה במסלול המקוצר: יש לבצע אותה רק לפי [התהליך המלא ב־EXECUTION-GUIDE, סעיף 2](EXECUTION-GUIDE.md#2-הכנת-יעד-מבודד--יעד-שינוי-המחייב-אישור), לאחר אימות Snapshot אמיתי. אסור ליצור markers אלה במקור.

**STOP:** אין Console, Snapshot, CIDR ניהול או זיהוי מכונה חד־משמעי.

## 3. מקור — מלאי חבילות

```bash
bash ./export-package-inventory.sh '<NEW_INVENTORY_DIRECTORY>'
```

APT repositories מוגדרים ידנית ביעד לפי גרסת ה־OS; אין להעתיק `auth.conf`.

## 4. יעד — חבילות

```bash
bash ./restore-packages.sh --dry-run '<INVENTORY>' package-plan.tsv
```

לאחר סקירת כל `PLAN`, סימולציית APT ו־Snapshot:

```bash
MIGRATION_APPROVAL=APPLY_PACKAGES \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./restore-packages.sh --apply '<INVENTORY>' package-apply.tsv
```

Apply דורש שכל השירותים הקריטיים כבויים ומשתמש זמנית ב־`policy-rc.d` לחסימת service starts.

**STOP:** package חסר, downgrade לא מוסבר, service פעיל או policy blocker לא תקין.

## 5. מקור ויעד — זהויות Linux

על המקור, לאחר אישור נפרד, יוצרים marker מזוהה:

```bash
{
  printf '%s\n' 'ACTIVE_VPS_MIGRATION_SOURCE=YES'
  printf 'HOSTNAME=%s\n' "$(hostname -f)"
  printf 'MACHINE_ID=%s\n' "$(cat /etc/machine-id)"
} > /etc/vps-migration-source
```

```bash
bash ./export-linux-identities.sh --preflight identity-allowlist.tsv 'gpg:<40_HEX_FINGERPRINT>' identities.tar.enc
MIGRATION_APPROVAL=EXPORT_LINUX_IDENTITIES \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./export-linux-identities.sh --execute identity-allowlist.tsv 'gpg:<40_HEX_FINGERPRINT>' identities.tar.enc
```

בַּיעד מאמתים checksum חיצוני ומפענחים ל־`/dev/shm`:

```bash
bash ./validate-identity-payload.sh '<TMPFS_STAGE>'
bash ./import-linux-identities.sh --dry-run '<TMPFS_STAGE>' identity-plan.tsv
MIGRATION_APPROVAL=APPLY_LINUX_IDENTITIES \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./import-linux-identities.sh --apply '<TMPFS_STAGE>' identity-apply.tsv '<TMPFS_JOURNAL>'
```

`package-verify` לעולם אינו משתנה. `sudo-review.tsv` מיועד ל־merge ידני בלבד.

**STOP:** collision, ‏STOP בדוח, sudo שלא עבר review או שאין session SSH חלופי.

## 6. קבצים — rsync ישיר

מריצים מהיעד, root אחר root. תצורות נמשכות ל־staging בלבד; נתוני יישום לנתיב הסופי רק אחרי Snapshot.

```bash
rsync -aHAXn --numeric-ids --relative --itemize-changes --protect-args \
  --rsync-path='sudo -n rsync' '<SOURCE_ALIAS>:/./var/www/' '/var/www/'
```

Apply מאושר מסיר רק `-n`. אין `--delete`, אין `/var/lib/mysql`, ואין Postfix queue בזמן שירות פעיל. מבצעים מעבר ראשוני וסופי לאחר עצירת כתיבות.

**STOP:** host key לא מוכר, UID/GID חסר, ACL/xattrs לא נתמכים, path רחב מדי או writer פעיל.

## 7. תצורות, סודות ואוטומציה — ידני

1. מעתיקים configs ל־staging ומבצעים `diff -ruN` מול package defaults.
2. מריצים lint: `sshd -t`,‏ `apache2ctl configtest`,‏ `postfix check`,‏ `doveconf -n`,‏ `visudo -c`,‏ `systemd-analyze verify`.
3. מעבירים secrets מתוך allowlist מצומצם ב־`tar` המוצפן עם age/GPG ומפענחים רק ל־tmpfs.
4. מתקינים secret אחד בכל פעם ובודקים owner/mode.
5. Cron, timers, hooks ו־Sieve נשארים כבויים עד cutover.

**STOP:** merge לא מאושר, secret מחוץ ל־allowlist, lint שנכשל או automation פעיל.

## 8. MariaDB — Restore trial

במקור:

```bash
bash ./mariadb-backup-stream.sh --preflight '<0600_OPTION_FILE>' '<TARGET_ALIAS>' '<NEW_REMOTE.xbstream>' mariadb-preflight.tsv
MIGRATION_APPROVAL=STREAM_MARIADB_BACKUP \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./mariadb-backup-stream.sh --execute '<0600_OPTION_FILE>' '<TARGET_ALIAS>' '<NEW_REMOTE.xbstream>' mariadb-backup.tsv
```

בַּיעד:

```bash
bash ./mariadb-restore.sh --dry-run '<ARCHIVE.xbstream>' '/var/tmp/mariadb-restore.TRIAL' /var/lib/mysql mariadb-plan.tsv
MIGRATION_APPROVAL=RESTORE_MARIADB \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  bash ./mariadb-restore.sh --apply '<ARCHIVE.xbstream>' '/var/tmp/mariadb-restore.TRIAL' /var/lib/mysql mariadb-restore.tsv
```

MariaDB נשאר כבוי אחרי copy-back. מפעילים רק ברשת מבודדת לצורך `verify-mariadb.sh`, grants, application tests ו־rollback trial.
השחזור דורש לצד ה־archive גם `.sha256` ו־`.COMPLETE`;‏ COMPLETE מפורסם אחרון וקושר את הנתיב, הגודל וה־SHA-256. אין לשחזר archive ללא COMPLETE תקין. בדיקת הבטיחות האוטומטית אינה מפעילה `--apply`, אינה מדמה `find`/`chown` ואינה ניגשת ל־`/var/lib/mysql`.

לבדיקת היישומים ביעד: ברירת המחדל היא MariaDB המשוחזר והמבודד ביעד. מעדכנים **רק ביעד** את `NewAPI` ו־`NewAPI_DEV` ל־`localhost` או ל־socket המקומי המאושר, ומתעדים host וקובץ בלבד, ללא סודות. אין לפתוח grant או Firewall במקור ואין להפנות את היישומים למסד המקור לצורך Restore trial רגיל.

חיבור חריג וזמני אל DB המקור דורש צורך מתועד ואישור מפורש ונפרד, grant מצומצם לפי משתמש/מסד, IP יעד קבוע וכלל Firewall תואם; הוא אינו מחליף בדיקת read/write מול ה־DB המשוחזר ביעד.

**STOP:** version mismatch, נפח חסר, datadir לא ריק, checksum שגוי או trial שלא הושלם.

### עיקרי ההקשחה לפי סקריפט

- `lib/common.sh`: פעולת שינוי נחסמת כאשר אותה זהות מסומנת כמקור וכיעד; אישור מחייב גם token סביבתי וגם קובץ 0400/0600 הקשור לפעולה, hostname ו־machine-id; נתיבי דוחות אינם דורסים קיים ואינם עוברים symlink; ניקוי מוגבל לעץ canonical תחת prefix מפורש.
- `mariadb-backup-stream.sh`: הרשאות MariaDB 11.8 מצומצמות ומאומתות, גודל datadir נקרא לצורך אומדן בלבד, tmpdir מקומי ונפח יעד נבדקים, אין archive מקומי, והפרסום בפועל הוא archive ואז checksum ואז COMPLETE.
- `mariadb-restore.sh`: COMPLETE הוא gate מחייב; `/var/lib/mysql` נבדק נגד symlinks; מעבר לבדיקת systemd נחסמים תהליך שרת או כל process המחזיק ב־datadir; חישוב המקום לאחר extract אינו סופר שוב את הנתונים שחולצו.
- `verify-mariadb.sh`: `--source-light` אינו מריץ `COUNT(*)` מלא או `mariadb-check`;‏ `--source-heavy` דורש אישור נפרד; ביעד הבדיקה מלאה. `SHOW CREATE USER` ו־grants מומרים ל־fingerprints ולא נשמר בהם חומר אימות גולמי.
- `tests/test-mariadb-safety.sh`: מפעיל את רצף הפרסום על filesystem זמני אמיתי ומאמת סדר ותוכן, בלי `--apply`, בלי datadir אמיתי ובלי כתיבה מחוץ ל־`/tmp` שלו.

## 9. Cutover סופי

1. Snapshot חדש ו־Snapshot marker חדש.
2. עצירת כתיבות, cron, timers, hooks ו־mail delivery במקור.
3. rsync סופי ללא `--delete`.
4. MariaDB backup/restore סופי.
5. מעדכנים ביעד את חיבורי `NewAPI` ו־`NewAPI_DEV` אל `localhost` (או socket מקומי מאושר), ובודקים חיבור ו־read/write מול ה־DB המשוחזר.
6. Maildir סופי; queue בנפרד ורק כששני Postfix כבויים.
7. checksums, DB metrics, config lint ובדיקות HTTP/SMTP/IMAP/TLS מבחוץ.
8. הפעלת שירות אחד בכל פעם; automation ודואר אחרונים.
9. DNS רק לאחר מעבר כל ה־Gates; לאחר שאין צורך ב־fallback, מסירים במקור את ה־grant וכלל ה־Firewall הזמניים ל־IP היעד.

**ROLLBACK:** עוצרים כתיבות ביעד, שומרים נתונים חדשים ל־reconciliation, מחזירים routing למקור ורק אז שירות. אין reverse-rsync עיוור.

## 10. סקריפטים מנוטרלים

הבאים מסומנים `RETIRED`, יוצאים מיד בקוד 64 ואינם חלק מהמסלול: `build-config-plan.sh`, `export-secrets.sh`, `mail-migration.sh`, `restore-apt-sources.sh`, `restore-automation.sh`, `restore-configs.sh`, `restore-files.sh`, `restore-project-dependencies.sh`, `restore-secrets.sh`, `restore-security-policy.sh`, `sync-files.sh`.
