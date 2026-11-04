# Hostinger API — ניהול Firewall ל־VPS

מדריך תמציתי לקריאה ולכתיבה של הגדרות Firewall ב־Hostinger דרך API.

## טוקן וכתובת בסיס

צרו טוקן ב־[hPanel → API](https://hpanel.hostinger.com/profile/api). הטוקן יורש את הרשאות המשתמש שיצר אותו, ניתן להגדיר לו תפוגה, ונדרש לפחות VPS אחד בחשבון.

```bash
export HOSTINGER_API_TOKEN='...'
export API_BASE='https://developers.hostinger.com/api/vps/v1'
```

כל בקשה משתמשת בכותרת:

```bash
-H "Authorization: Bearer $HOSTINGER_API_TOKEN"
```

בבקשות עם JSON יש להוסיף גם:

```bash
-H 'Content-Type: application/json'
```

## קריאה

רשימת כל קבוצות ה־Firewall:

```bash
curl "$API_BASE/firewall" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN"
```

פרטי קבוצה מסוימת, כולל החוקים שלה:

```bash
curl "$API_BASE/firewall/$FIREWALL_ID" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN"
```

למציאת מזהה ה־VPS ו־`firewall_group_id` הנוכחי:

```bash
curl "$API_BASE/virtual-machines" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN"
```

## כתיבה

יצירת קבוצת Firewall:

```bash
curl -X POST "$API_BASE/firewall" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"name":"Production Firewall"}'
```

הוספת כלל, למשל HTTPS פתוח לכל העולם:

```bash
curl -X POST "$API_BASE/firewall/$FIREWALL_ID/rules" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{
    "protocol":"TCP",
    "port":"443",
    "source":"any",
    "source_detail":"any"
  }'
```

עריכת כלל קיים:

```bash
curl -X PUT "$API_BASE/firewall/$FIREWALL_ID/rules/$RULE_ID" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{
    "protocol":"TCP",
    "port":"443",
    "source":"any",
    "source_detail":"any"
  }'
```

החלפה אטומית של כל החוקים וסנכרון מיידי:

```bash
curl -X PUT "$API_BASE/firewall/$FIREWALL_ID/rules" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{
    "rules":[
      {"protocol":"TCP","port":"22","source":"custom","source_detail":"203.0.113.5"},
      {"protocol":"TCP","port":"443","source":"any","source_detail":"any"}
    ],
    "sync":true
  }'
```

הפעלת קבוצה על VPS (אפשר להפעיל קבוצה אחת בלבד לכל VPS):

```bash
curl -X POST "$API_BASE/firewall/$FIREWALL_ID/activate/$VIRTUAL_MACHINE_ID" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN"
```

סנכרון ידני לאחר שינוי כללים:

```bash
curl -X POST "$API_BASE/firewall/$FIREWALL_ID/sync" \
  -H "Authorization: Bearer $HOSTINGER_API_TOKEN"
```

פעולות נוספות זמינות: `DELETE /firewall/{firewallId}`,‏ `DELETE /firewall/{firewallId}/rules/{ruleId}`, וכן `POST /firewall/{firewallId}/deactivate/{virtualMachineId}`.

## אזהרות תפעוליות

- Firewall חדש חוסם כברירת מחדל את כל התעבורה הנכנסת. יש להגדיר ולאמת כלל SSH מתאים לפני ההפעלה, כדי לא לאבד גישה לשרת.
- סדר העבודה בהעברה זו: בשלב הבידוד משנים רק UFW ביעד, לאחר Console וחיבור SSH חלופי; Hostinger Firewall נשאר ללא שינוי וללא שיוך. לקראת חשיפה של Apache או שירות ציבורי אחר יוצרים **קבוצה חדשה ונפרדת** ליעד, מתאימים אותה לכללי UFW המאושרים, מריצים dry-run, ורק באישור נפרד משייכים אותה. אין למחזר קבוצות או כללים היסטוריים ללא צורך מוכח.
- לאחר הוספה, עדכון או מחיקה של כלל, VPS המשויך לקבוצה עשוי לצאת מסנכרון. הפעילו `sync`, או השתמשו ב־`"sync": true` בעת החלפת כל החוקים.
- יש לשלוח `Content-Type: application/json` בבקשות `POST` ו־`PUT` עם גוף JSON.
- קצב הבקשות המוגדר הוא 90 בדקה למשתמש מאומת; חריגה מחזירה `429 Too Many Requests`.
- אין לשמור את הטוקן בקוד, ב־Git או בצ'אט. השתמשו במשתנה סביבה או במנהל סודות.

## סקריפטי הערכה: export ו־apply

הטוקן מקבל תוקף בעת יצירתו ב־hPanel; משתנה סביבה אינו מוסיף או אוכף תוקף. צור token קצר־תוקף בממשק, ואז באותה session בלבד:

```bash
read -rs -p 'Hostinger API token: ' HOSTINGER_API_TOKEN; echo
export HOSTINGER_API_TOKEN
```

כך הטוקן אינו נשמר ב־history ואינו מודפס. בסיום session מוחקים אותו מהסביבה:

```bash
unset HOSTINGER_API_TOKEN
```

### קריאה בלבד

```bash
./hostinger-firewall-export.sh \
  --json /tmp/hostinger-firewalls-snapshot.json \
  --csv /tmp/hostinger-firewalls-rules.csv
```

הסקריפט מבצע רק `GET /virtual-machines` ו־`GET /firewall`. JSON הוא snapshot כולל קבוצות, rules ושיוכי VPS כפי שה־API מחזיר; CSV הוא רשימת rules קריאה לאדם. הטוקן לעולם אינו נכתב לקבצים או לפלט.

### כתיבה מבוקרת

תחילה מריצים dry-run. יש לציין במפורש כל VPS שמותר לגעת בו:

```bash
./hostinger-firewall-apply.sh --dry-run target-firewall-policy.json firewall-plan.tsv \
  --allow-vm 2119375 \
  --management-source 213.137.0.0/16 \
  --management-source 147.234.0.0/16 \
  --management-source 46.31.0.0/16 \
  --management-source 185.24.0.0/16 \
  --management-source 72.61.138.158/32
```

רק לאחר סקירת `firewall-plan.tsv`, אישור מפורש, Console זמין ובדיקת SSH חלופית:

```bash
MIGRATION_APPROVAL=APPLY_HOSTINGER_FIREWALL \
MIGRATION_APPROVAL_FILE='<0400_OR_0600_ACTION_AND_SERVER_APPROVAL>' \
  ./hostinger-firewall-apply.sh --apply target-firewall-policy.json firewall-apply.tsv \
  --allow-vm 2119375 \
  --management-source 213.137.0.0/16 \
  --management-source 147.234.0.0/16 \
  --management-source 46.31.0.0/16 \
  --management-source 185.24.0.0/16 \
  --management-source 72.61.138.158/32
```

Apply יוצר קבוצה חסרה או מחליף atomically את rules של קבוצה בעלת שם תואם, מפעיל אותה רק על ה־VPS שאושר, ואז מבצע sync. הוא מסרב אם שם קבוצה או מזהה VPS מופיעים פעמיים במדיניות, אם קבוצה קיימת משויכת ל־VPS אחר, או אם מזהה VPS אינו ברשימת `--allow-vm`. CSV מקובץ לפי הזוג `(firewall_name, virtual_machine_id)`, לכן כל VPS מקבל רק את הכללים שלו ואין ערבוב בין המקור ליעד.

`TCP/22` לבדו אינו מספיק. במדיניות היעד כל כלל SSH חייב להיות `custom`, וה־CIDR הקנוני שלו חייב להתאים בדיוק לאחד הערכים שנמסרו ב־`--management-source`; ובמקביל כל מקור שנמסר חייב להיות מכוסה בכלל SSH. אין להשתמש ב־`any` לגישת ניהול. כתובת בודדת מנורמלת ל־`/32` או `/128`; CIDR עם host bits או מסכה לא חוקית נדחה. לדוגמה, למדיניות SSH מוגבלת:

```bash
./hostinger-firewall-apply.sh --dry-run target-firewall-policy.json firewall-plan.tsv \
  --allow-vm 2119375 \
  --management-source 213.137.0.0/16 \
  --management-source 147.234.0.0/16 \
  --management-source 46.31.0.0/16 \
  --management-source 185.24.0.0/16 \
  --management-source 72.61.138.158/32
```

לפני Apply נשמרים אוטומטית `<report>.before.json` ו־`<report>.recovery.json`; לאחר כל `sync` הסקריפט ממתין עד 30 שניות (ברירת־מחדל) ל־`is_synced=true`, ואז מאמתים מחדש שיוך VPS ו־rules ונשמר `<report>.after.json`. אפשר לכוונן את ההמתנה בבדיקות בלבד באמצעות `HOSTINGER_SYNC_WAIT_SECONDS` ו־`HOSTINGER_SYNC_POLL_SECONDS`. במקרה כשל חלקי הסקריפט מוסיף `PARTIAL_FAILURE` לדוח ומשאיר recovery journal. אין rollback אוטומטי: עוצרים, משווים ל־`before.json` ומשחזרים ידנית רק לאחר review, כדי לא לדרוס שינוי חיצוני.

פורמט JSON הוא מערך `firewalls` מתוך snapshot ה־export, עם `name`,‏ `virtual_machine_ids` ו־`rules`. CSV לעריכה חייב לכלול בדיוק את הכותרת הבאה ושישה שדות ללא פסיקים מצוטטים:

```text
firewall_name,virtual_machine_id,protocol,port,source,source_detail
```

Export שומר ב־JSON גם את תגובות ה־API הגולמיות, לצד קבוצות שאינן משויכות ל־VPS, IDs, מצב `is_synced`, כל rules וכל מכונה שה־API החזיר. ב־CSV של קבוצה לא משויכת מזהה ה־VPS נשאר ריק כדי לשמר את הכללים לתיעוד; CSV כזה אינו קלט Apply עד שמוסיפים מזהה VPS מאושר.

## בדיקות מקומיות

`tests/test-hostinger-firewall.sh` משתמש ב־API מדומה בלבד ובודק: Apply מוצלח, הרצה חוזרת idempotent, הפרדת CSV בין מקור ליעד, export של קבוצה לא משויכת, כפילויות, כיסוי קשיח של מקורות ניהול (כולל דחיית `any` לא מאושר ו־CIDR רחב מדי), polling אסינכרוני של sync, ניתוק API וכשל באמצע עם recovery journal. אין צורך בטוקן ואין תעבורת Hostinger בבדיקות אלה.

## מקור

[Hostinger API Reference — Overview](https://docs.hostinger.com/api-reference/overview) ו־[רפרנס Firewall](https://developers.hostinger.com/).
