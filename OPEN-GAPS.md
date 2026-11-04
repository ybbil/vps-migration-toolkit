# פערי כיסוי שנותרו

עודכן לאחר השלמת שלבים 1–7 והעתקת roots היישומים שאושרו בשלב 8. רשימה זו מתארת את מצב ההגירה הנוכחי, ולא מגבלות כלליות של הערכה.

## חסמים פתוחים

1. **MariaDB — חוסם:** טרם בוצעו preflight אמיתי, physical backup,‏ Restore trial ואימות source/target. לפני כל גיבוי יש לאמת `mariadb-backup` תואם לגרסת השרת, option file בהרשאות מאושרות, credentials, נפח יעד וחלון עומס. גיבוי כשיר רק עם archive,‏ checksum וקובץ COMPLETE תואם שפורסם אחרון. אין להשתמש ב־`rsync` עבור `/var/lib/mysql`.
2. **DB logical audit — חוסם:** users/roles/grants/views/routines/triggers/events ונתוני Roundcube/PostfixAdmin עדיין תלויים בגישת DBA ובהשוואה בין מקור ליעד.
3. **דואר — חוסם לסנכרון סופי בלבד:** ההעתקה הראשונית של `/var/mail` הושלמה בכיוון יעד←מקור: `rsync_exit=0`,‏ 1,070 פריטים, 17,685,793 בתים, אפס מחיקות וללא נתיבים חריגים בזמן 2.430 שניות. checksum מיד לאחריה עבר עם `checksum_exit=0`, אפס העברות ואפס הבדלים בזמן 1.748 שניות. הרשאת ה־pull והמפתח הזמניים הוסרו. נותרו סנכרון סופי תחת עצירת מסירה, בדיקות subscriptions/ACLs, אסטרטגיית queue ו־TLS.
4. **Mail hook — נדחה עד ליציבות היעד:** המסלול המוכח הוא Sieve אישי של `kolelerev` שמפעיל `pipe "mail_to_json.sh"` ולאחריו `keep`; הוא מגיע אל `/etc/dovecot/sieve-pipe/mail_to_json.sh` ומשם ל־`/usr/bin/php /var/www/mail-hooks/process_incoming.php`. checksum, lint ו־mock מבודד עברו, אך ה־wrapper ונתיבי runtime עדיין לא הותקנו ביעד וה־PHP האמיתי לא הורץ מול DB/דואר. אין להפעיל דואר או להתקין את המועמד עד Restore trial ו־review של idempotency/sinks. פירוט מלא: [`STAGE-9-MAIL-HOOK-REPORT.md`](STAGE-9-MAIL-HOOK-REPORT.md).
5. **Firewall ספק ו־WireGuard — חוסם הפעלה חיצונית בלבד:** המקור נשאר ללא שינוי. WireGuard בו מאזין על UDP/443, שהותר בפועל ב־IPv4 וב־IPv6; UDP/51820 הוא כלל ישן עם מונים אפסיים ואינו נמחק. ביעד הותקנה תצורה עצמאית עם מפתחות חדשים, subnet ‏`10.201.0.0/24`, UDP/443 ו־peer אחד ללא מפתח פרטי מועתק; UFW פותח UDP/443 ב־IPv4 וב־IPv6. `wg-quick@wg0` עדיין inactive/disabled. אין export/API מאומת של Firewall הספק, ולכן חובה להוסיף ולאמת שם כלל inbound UDP/443 לפני הפעלה. SSH ביעד נשאר זמנית מ־Anywhere; CIDR‑ים של המקור לא הועתקו כדי לא לנעול גישה, ונדרש review נפרד לפני צמצום. לאחר פתיחת Firewall הספק חובה בדיקת לקוח יחיד לפני צירוף יתר ה־peers.
6. **סודות — חוסם:** לא אושר allowlist/recipient מלא ולא בוצע rotation לפריטים החשופים. כלי Export/Restore האוטומטיים נוטרלו; ההעברה תהיה ידנית, מוצפנת ומ־tmpfs, קובץ אחד בכל פעם.
7. **Configs מסוג merge — חוסם להפעלת שירותים:** Apache, PHP, MariaDB, Postfix, Dovecot, OpenDKIM, SSH, units ו־cron דורשים staging,‏ diff,‏ lint ואישור ידני. כלי השחזור האוטומטיים מסומנים `RETIRED`.
8. **Roots ואוטומציות:** החלטות ה־keep/omit אושרו: `/opt/git-auto-push`,‏ `/opt/git` וכל `/home` לא יועברו; `/opt/mail-hook` יישאר staging בלבד. אין להפעיל automation לפני בדיקת single execution owner בשלב 11.
9. **יישומי Apache שהוחרגו מנתיבים:** לפני התקנה פעילה של ה־vhost יש לבדוק במקור את `kesef_beseder` (מופנה מ־`/opt/asterisk-projects/kesef_beseder`) ואת `shabat` (מופנה מ־`/home/tools_dev/projects/YEMOT_tools/kav_shabat`). שני הנתיבים אינם קיימים ביעד ולכן הושמטו זמנית מה־candidate; יש לקבוע בנפרד אם להעתיקם, להגדיר נתיב חלופי או להשאירם מושבתים.
10. **Monarx Protect — נסגר להגדרה:** חבילות Monarx ביעד תואמות למקור. הוגדרו symlink של PHP 8.4 וה־INI של `monarxprotect` ל־PHP‑FPM בלבד; טעינה מבודדת ו־`php-fpm8.4 -t` עברו. Apache ו־PHP‑FPM נשארים כבויים, ולכן נדרשת רק בדיקת תפקוד רגילה אחרי הפעלת היישומים המבודדת.
11. **סודות דואר, Dovecot ו־OpenDKIM:** Postfix candidate עבר lint, אך הפעלה נשארת חסומה עד להעברה מוצפנת ומבוקרת של קובץ משתמשי Dovecot, פרטי SQL של PostfixAdmin, מפתח TLS ותצורת OpenDKIM. לפי החלטת המפעיל, OpenDKIM יוגדר רק בשלב הסיום של הגדרת הדואר וה־hook. אין להתקין `vmailbox`/DB או להפעיל SMTP/IMAP לפני בדיקת Sieve/mailhook והגדרת Firewall/PTR/DNS בשלב 11.
12. **תוכן משתנה וסנכרון סופי:** checksums הושלמו עבור roots היישומים שכבר הועתקו, אך Maildir וכל root שמשתנה עד ה־cutover דורשים benchmark, חלון freeze או קריאה־בלבד, rsync סופי ללא `--delete` ו־checksum חוזר.
13. **Restore/rollback ושירותים:** Snapshot ראשוני אומת, אך טרם בוצעו Provider Snapshot restore trial,‏ MariaDB Restore trial, הפעלת שירותים מבודדת, reconciliation של נתונים חדשים או מדידת RPO/RTO.
14. **sudo main policy:** זהויות הועברו ללא התקנת sudo אוטומטית. `/etc/sudoers` ו־fragments דורשים merge מצומצם, `visudo -cf`,‏ `visudo -c` וחיבור ניהול חלופי לפני שינוי.
15. **בדיקות תפעוליות:** חסרים Restore trial מלא, בדיקות HTTP/SMTP/IMAP/TLS חיצוניות, בדיקות IPv6, בדיקות כתיבה אפליקטיביות ותרגיל rollback/reconciliation.
16. **ShellCheck:** אינו מותקן. `validate-toolkit.sh` ו־fixture tests עברו, אך בדיקת ShellCheck נשארה `SKIP`; לא בוצעה התקנה או הורדה.
17. **חידוש TLS ידני:** תעודת Google Trust Services (issuer ‏`WR1`) החדשה עבור `yeshivatrabenu.site` ו־`www.yeshivatrabenu.site` הונפקה ב־DNS-01 ידני ותוקפה עד 2027-02-01. לפני המועד יש לבצע הנפקה מחדש ידנית, עם EAB חדש מ־Google Cloud Public CA, או לתכנן בנפרד DNS API מצומצם ו־`manual-auth-hook`; `certbot.timer` נשאר disabled ואסור להפעילו לפני review של מסלול החידוש.

## פערים שנסגרו או צומצמו

1. **חבילות:** היעד הוקם, inventory אומת, מאגר NodeSource הוגדר, Dry-run עבר והחבילות המאושרות הותקנו כאשר שירותי היישום נשארו inactive וגם disabled. רק `packages-microsoft-prod`,‏ `dotnet-sdk-10.0`,‏ `aspnetcore-runtime-10.0` ו־`google-cloud-cli` נשארו `DEFER` בהחלטת מפעיל.
2. **זהויות Linux:** allowlist, export מוצפן, validation,‏ Dry-run ו־Apply הושלמו ללא התנגשויות. תשעת החשבונות שאושרו אומתו ביעד; sudo נשאר Gate ידני כמפורט למעלה.
3. **Remote rsync ונתיבים:** target-pull מאומת בוצע עם מפתחות מוגבלים ל־IP ול־root, ללא shell, forwarding או כתיבה למקור. לא נמצא קינון כפול של נתיבים ולא נעשה שימוש ב־`--delete`.
4. **קובצי יישומים:** `/var/www`,‏ `/opt/radio`,‏ `/opt/flyway-12.7.0` ו־`/srv/finance` עברו Dry-run, העתקה ובדיקת checksum ללא הבדלים. `/var/www/aspnet`,‏ `node_modules` ו־`/opt/docker` הוחרגו בהחלטה מפורשת.
5. **שלמות תוכן האתרים:** בדיקת checksum מלאה ל־`/var/www` הסתיימה ב־`rsync_exit=0`, עם אפס קבצים להעברה ואפס מחיקות. החסם הכללי של “checksum אתרים לא נוסה” סגור; הוא נשאר פתוח רק לנתונים משתנים ול־roots שטרם הועברו.
6. **Snapshot ו־Apply בסיסי:** Snapshot ראשוני הופיע כ־Ready/Completed ואומת; התקנת APT, שינוי חשבונות ו־remote rsync נוסו בפועל וקיבלו `PASS`. עדיין נדרש Restore trial של Snapshot ושירותים כמפורט בחסמים הפתוחים.
7. **TLS ל־`yeshivatrabenu.site`:** תעודת Google Trust Services חדשה (issuer ‏`WR1`) הונפקה ביעד עבור `yeshivatrabenu.site` ו־`www.yeshivatrabenu.site`, לצד תעודת Let’s Encrypt חלופית. ה־VHost המוצע מפנה לתעודת GTS החדשה ועבר `apache2ctl -t` ב־staging. הוא עדיין לא הותקן ב־`/etc` ולא הופעל.

## Gate נוכחי

ההעתקה הראשונית וה־checksum של `/var/mail` הושלמו בהצלחה, וההרשאות הזמניות הוסרו. שלב 8 הראשוני נסגר. עוברים לשלב 9 — staging/diff/lint של תצורות וסודות; הסנכרון הסופי נשמר לשלב 11, תחת עצירת מסירת דואר וטיפול נפרד ב־queue.
