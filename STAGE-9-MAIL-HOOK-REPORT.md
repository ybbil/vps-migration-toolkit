# דוח שלב 9 — Mail hook אישי

עודכן: 2026-11-03  
סטטוס: **PASS לניתוח, staging ובדיקת mock מבודדת; DEFER להתקנה/הפעלה עד שהיעד יציב.**

## גבולות העבודה

- לא הופעלו Dovecot, Postfix, OpenDKIM או שירות דואר אחר.
- לא הותקנה תצורה פעילה תחת `/etc`, לא הועברו סודות, ולא נשלחה הודעה אמיתית.
- כל בדיקות ההרצה השתמשו בהודעת RFC822 סינתטית וב־tmpfs; קבצי הבדיקה נמחקו בסיום.

## המסלול הפעיל שהוכח במקור

המסלול אינו ה־global Sieve candidate הישן `mailhook`. המסלול המוכח הוא אישי עבור תיבת `kolelerev`:

```text
Dovecot LMTP
  -> /var/mail/vhosts/yeshivatrabenu.site/kolelerev/.dovecot.sieve
  -> pipe "mail_to_json.sh"
  -> /etc/dovecot/sieve-pipe/mail_to_json.sh
  -> /usr/bin/php /var/www/mail-hooks/process_incoming.php
  -> keep
```

- הגדרת Dovecot הפעילה תומכת ב־personal Sieve (`active_path = ~/.dovecot.sieve`) וב־`vnd.dovecot.pipe`/`sieve_extprograms`.
- הכלל האישי הוא `vmail:vmail`, הרשאה `0600`; הוא מפעיל `mail_to_json.sh` ולאחריו `keep`.
- ה־wrapper הפעיל המתאים במקור הוא `root:root`, הרשאה `0755`, ומפעיל במדויק את PHP לעיל.
- הקובץ הישן `mailhook` הוא בעלים `nobody:nogroup` ואינו במסלול שהוכח; אין לשנות את בעלותו או להפעיל אותו על סמך השערה.

## התאמה ליעד ומועמד staging

ב־VPS היעד נבדק checksum של הכלל האישי ושל `mail_to_json.sh`; שניהם זהים למקור.

המועמד הלא־פעיל נמצא ביעד:

```text
/root/vps-migration-stage/stage-9-20261102T224900Z/proposed/
```

וה־manifest שלו הוא:

```text
mailhook-personal-candidate.tsv
```

החלטות המועמד:

| פריט | החלטה | בעלות/הרשאה |
| --- | --- | --- |
| `.dovecot.sieve` של `kolelerev` | `KEEP`: כבר זהה למקור; לא לדרוס | `vmail:vmail`, `0600` |
| `/etc/dovecot/sieve-pipe/mail_to_json.sh` | `INSTALL` רק אחרי PASS אינטגרציה ואישור נפרד | `root:root`, `0755` |
| `/etc/dovecot/sieve-pipe` | `CREATE` רק אחרי PASS ואישור | `root:root`, `0755` |
| `/var/mail-hooks-data/{tmp,json,attachments}` | `CREATE` רק אחרי PASS ואישור | `vmail:vmail`, `0775` |

בעת הבדיקה הנתיבים האחרונים וה־wrapper הפעיל עדיין לא קיימים ביעד; הם לא נוצרו. PHP והרחבת `mailparse` קיימים ביעד, ו־`vmail` הוא UID/GID ‏`5000` וחבר בקבוצת `mailhooks`.

## בדיקות שבוצעו

| בדיקה | תוצאה | הערה |
| --- | --- | --- |
| `postfix check` על staging | PASS | ללא התחלת Postfix |
| `doveconf -c <staging>/etc/dovecot/dovecot.conf -n` | PASS | תצורת Dovecot staged תקפה |
| `sievec -c <staging-dovecot.conf> 00-mailhook.sieve` | PASS | נדרש `-c`; קומפילציה ישירה בלי התצורה אינה טוענת את הרחבת `pipe` |
| `sievec -c <staging-dovecot.conf> <personal .dovecot.sieve>` | PASS | הכלל האישי המוכח מתקמפל |
| `php -l /var/www/mail-hooks/process_incoming.php` | PASS | תחביר PHP תקין |
| checksum אישי/Wrapper מקור↔יעד | PASS | התאמה byte-for-byte |
| `sieve-test -e` מבודד | PASS | פירוט להלן |

### בדיקת mock מבודדת

הבדיקה רצה כזהות `vmail` ב־`/dev/shm`, עם:

- עותק הכלל האישי המועמד;
- mock זמני בשם `mail_to_json.sh`, במקום ה־wrapper האמיתי;
- Maildir זמני עבור פעולת `keep`;
- הודעת RFC822 סינתטית בלבד עם Message-ID ייעודי.

תוצאה מאומתת:

```text
uid=5000 (vmail)
pipe invocations=1
Maildir/new messages=1
synthetic Message-ID in pipe capture=1
synthetic Message-ID in kept message=1
services started=none
DB/network/real mail=none
temporary artifacts=deleted from tmpfs
```

ה־trace הראה במפורש פעולת `pipe` אחת ופעולת `keep` אחת. השוואת checksum מול קובץ הקלט הגולמי אינה קריטריון תקף: `sieve-test`/מסלול המסירה יכול לנרמל או להוסיף כותרות. לכן קריטריון הקבלה הוא Message-ID יחיד בכל מסלול ומונה פעולה יחיד.

### תקלות harness שנפתרו

1. קומפילציית Sieve ללא קובץ Dovecot נכשלה כי הרחבת `vnd.dovecot.pipe` לא נטענה; הבדיקה הנכונה עם `-c` עברה.
2. ניסיון mock ראשון נעצר כי תיקיית tmpfs עליונה הייתה `0700`; תוקן ל־`0755` בעוד אזורי הכתיבה נשארו בבעלות `vmail`.
3. ניסיון שני נעצר כי harness מינימלי חסר `dovecot_storage_version`; נוסף הערך `2.4.0` מתצורת היעד.

אף אחת מהתקלות לא שינתה קובץ פעיל, שירות או נתון ייצור.

## ממצאי קוד והגבלות

`process_incoming.php` קורא מ־`php://stdin`, כותב קבצים תחת `/var/mail-hooks-data`, וטוען לוגיקה עסקית שעלולה להשתמש ב־DB ולשלוח הודעת שגיאה. Message-ID נשמר בנתוני העיבוד, אך לא הוכח מנגנון idempotency או מניעת כפילויות. לכן אין להריץ את ה־PHP האמיתי מול DB/דואר לפני בדיקה מבודדת נוספת.

## החלטת דחייה

לפי החלטת המפעיל, ה־Mail hook וה־pipe **אינם חלק מההפעלה הנוכחית**. הם יישארו ב־staging בלבד עד שהיעד וה־DB יהיו יציבים. אין להתקין את המועמד, להפעיל Dovecot או להעביר סודות דואר במסגרת שלב זה.

## צעדים עתידיים לפני הפעלה

1. לאחר Restore trial של MariaDB וייצוב היעד, למפות את כל תופעות הלוואי של הלוגיקה העסקית וליצור sink/mock ל־DB ולדואר.
2. לאשר allowlist מוצפן נפרד לסודות הנדרשים בלבד; אין לרשום ערכים בדוח או בצ'אט.
3. לבצע review ל־idempotency על Message-ID וללוגים לפני קבלת דואר אמיתי.
4. לאחר Snapshot יעד ואישור נפרד: להתקין את פריטי המועמד, כשהשירותים עדיין כבויים, ולבצע lint חוזר.
5. רק לאחר cutover, עם owner יחיד למסירת דואר, לבצע הודעת בדיקה חיצונית אחת ולעקוב אחר Dovecot/Sieve/PHP/Postfix לפי Message-ID.

**STOP:** סוד חסר, פעולה עסקית שאינה מבודדת, עיבוד כפול, שירות פעיל בשני שרתים, או הפעלת `mailhook` הישן במקום המסלול האישי המוכח.
