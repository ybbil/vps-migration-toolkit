# תיקון staging רגיש — שלב 9

עודכן: 2026-11-03
סטטוס: **PASS — עותקי ה־staging הרגישים הוסרו; אין שינוי פעיל**

## סיבת העצירה

בביקורת קריאה בלבד של יעד ההגירה (`srv2119375.hstgr.cloud`) זוהו שני
עותקי staging של תצורת אימות Dovecot מסוג SQL. הם נמצאו תחת `/root`, שאינו
`tmpfs`, ובמצב `0644`. לא נקרא תוכן הקבצים ולא הודפסו ערכי סוד. עצם שם
הקובץ וסוגו מסווגים אותו כקובץ שעשוי להכיל פרטי התחברות.

## גבולות הפעולה שאושרה

- מוסרים רק ארבעה קובצי staging לא־פעילים, בשני עצי staging.
- לא נוגעים ב־`/etc`, בשירותים, בתצורה פעילה, בנתוני דואר או בסודות פעילים.
- אין יצירת עותק גיבוי נוסף של הקבצים ואין ניסיון לקרוא, להעתיק או להציג את תוכנם.
- קבצי secrets עתידיים יועברו רק מתוך allowlist מצומצם, בארכיון מוצפן,
  ויפוענחו רק ב־tmpfs.

## מצב לפני ההסרה

| נתיב יחסי תחת `/root/vps-migration-stage/stage-9-20261102T224900Z/` | מצב | בעלים | גודל |
| --- | --- | --- | --- |
| `etc/dovecot/conf.d/auth-sql.conf.ext` | `0644` | `root:root` | 6544 B |
| `apache-configtest/dovecot/conf.d/auth-sql.conf.ext` | `0644` | `root:root` | 6544 B |
| `etc/dovecot/conf.d/auth-passwdfile.conf.ext` | `0644` | `root:root` | 754 B |
| `apache-configtest/dovecot/conf.d/auth-passwdfile.conf.ext` | `0644` | `root:root` | 754 B |

`auth-sql.conf.ext` הוגדר כמועמד סוד ויוסר. גם `auth-passwdfile.conf.ext`
יוסר כדי שלא יישאר ב־staging מסלול אימות שעשוי לחשוף את מקור ה־passwd-file.
ההסרה אינה טוענת למחיקה פיזית בלתי־הפיכה ממדיית האחסון; היא מסירה את העותקים
מהעץ הנגיש של ה־staging.

## פעולות שבוצעו לפני ההסרה

1. אומתה זהות היעד וה־Snapshot marker; לא נוצר Snapshot ולא השתנה marker.
2. אומת שהשירותים `apache2`, `mariadb`, `postfix`, `dovecot`, `opendkim`
   ו־`wg-quick@wg0` הם `inactive` וגם `disabled`.
3. נסקרו שמות, בעלות, מצבים וגדלים בלבד; לא הוצג תוכן רגיש.
4. התקבל אישור מפורש מהמפעיל להסרת עותקי ה־staging ותיעוד לפני/אחרי.

## תוצאה לאחר ההסרה

ב־2026-11-03 הוסרו בדיוק ארבעת הקבצים המופיעים בטבלה. בדיקת קיום מיד לאחר
הפעולה החזירה `ABSENT` עבור כל ארבעת הנתיבים.

בדיקת post-action הראתה ש־`apache2`, `mariadb`, `postfix`, `dovecot`,
`opendkim` ו־`wg-quick@wg0` נשארו כולם `inactive` וגם `disabled`.

לא נכתב קובץ תחת `/etc`, לא הועבר סוד, לא בוצע reload/start, ולא השתנה
Firewall או WireGuard.

## המשך מותר

לא ממשיכים ב־merge או בהתקנת Dovecot/Postfix/OpenDKIM עד שתהיה allowlist
נפרדת של שמות הסודות, recipient להצפנה, והעברה מוצפנת ל־tmpfs. אין להפעיל
שירותים במסגרת תיקון זה.

## רשימת סודות סגורה והחלטת טיפול

הטבלה מבוססת על manifest המקור ועל בדיקת בעלות/הרשאה במקור בלבד. היא אינה
כוללת ערכי סוד, hashes או תוכן קובץ. `DEFER` פירושו שהקובץ **אינו מועבר כעת**;
אם יאושר בהמשך, ההעברה תהיה בארכיון מוצפן ל־tmpfs בלבד, והתקנה תהיה קובץ־קובץ
אחרי בדיקת בעלות/הרשאה ולפני הפעלת השירות המתאים.

| קובץ מקור | בעלים/מצב במקור | שייך ל־ | החלטה בשלב 9 | תנאי לפני טיפול עתידי |
| --- | --- | --- | --- | --- |
| `/etc/dovecot/passwd` | `root:dovecot`, `0640` | אימות Dovecot מסוג passwd-file | DEFER | נדרש רק אם דואר/IMAP יאושרו; אימות Dovecot ו־single delivery owner |
| `/etc/dovecot/dovecot-sql.conf.ext` | `root:dovecot`, `0640` | אימות SQL של Dovecot | DEFER | Restore trial ל־MariaDB, allowlist נפרדת והרשאות DB מצומצמות |
| `/etc/dovecot/private/yeshiva_privkey.pem` | `root:dovecot`, `0640` | TLS של Dovecot | OMIT/REISSUE | להנפיק מפתח ותעודה חדשים ביעד; אין להעתיק מפתח פרטי מן המקור |
| `/etc/opendkim/keys/yeshivatrabenu.site/mail.private` | `root:root`, `0600` | OpenDKIM | DEFER | שלב סיום דואר, selector/DNS מאושר ובדיקת DKIM; לא לפני כן |
| `/etc/postfixadmin/dbconfig.inc.php` | `root:www-data`, `0640` | מסד PostfixAdmin | DEFER | Restore trial של MariaDB וסוד DB מאושר עבור היישום בלבד |
| `/etc/postfixadmin/config.local.php` | `root:root`, `0644` | הגדרות/סודות PostfixAdmin | DEFER | review פרטני של המפתחות הנדרשים והקשחת הרשאות ביעד |
| שני קבצי private key תחת `/etc/ssl/godaddy/yeshivatrabenu.site/` | `root:root`, `0600` ו־`0644` | TLS ישן של GoDaddy | OMIT | הוחלפו במועמד ה־GTS ביעד; אין להעתיק |
| `/etc/mysql/debian.cnf` | `root:root`, `0600` | תחזוקת MariaDB מקומית | OMIT | חבילת MariaDB ביעד יוצרת/מנהלת credential מקומי עצמאי; אין להעתיק |
| חמשת `privkey*.pem` תחת `/etc/letsencrypt/archive/yeshivatrabenu.site/` | `root:root`, `0600` | זהות ACME/TLS ישנה | OMIT | היעד משתמש בתעודה שהונפקה מחדש; אין להעתיק |
| שני `privkey*.pem` תחת `/etc/letsencrypt/archive/yeshivatrabenu-google/` | `root:root`, `0600` | זהות ACME/TLS של המקור | OMIT | אין להעתיק זהות ACME; renewal עתידי יוגדר בנפרד ביעד |
| שלושה `private_key.json` תחת `/etc/letsencrypt/accounts/` | `root:root`, `0400` | חשבונות ACME | OMIT | יש להשאיר accounts/registrations מופרדים בין השרתים |

הערת ספירה: שורות ה־TLS המקובצות מייצגות 12 קבצים (2 GoDaddy, 5 Let’s
Encrypt לאתר, 2 Google ACME ו־3 account keys); יחד עם שמונת הפריטים האחרים
הרשימה הסגורה מכסה 19 קובצי מקור מסווגים.

## התאמה לאירוע ה־staging

שמות הקבצים שנמצאו ב־staging היו `auth-sql.conf.ext` ו־`auth-passwdfile.conf.ext`
מתחת ל־`etc/dovecot/conf.d/`; הם אינם שני נתיבי הסוד המדויקים שב־manifest,
אך הם תצורות אימות ועלולים להכיל או להפנות לפרטי התחברות. לכן טופלו בזהירות
כרגישים והוסרו מארבעה מיקומי staging. מיד לאחר מכן ארבעתם אומתו כ־`ABSENT`.
