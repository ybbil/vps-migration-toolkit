# VPS migration toolkit

> **מתחילים ב־[`START-HERE.md`](START-HERE.md).** זהו המדריך הראשי מרכישת ה־VPS ועד Cutover ו־Rollback. אין להתחיל מפקודות בודדות מתוך מסמך אחר.

המסלול פושט לשישה סקריפטי ליבה. סקריפטים המסומנים `RETIRED` אינם מיועדים להרצה ויוצאים בקוד 64. `EXECUTION-GUIDE.md` ו־`OPERATIONS.md` הם מסמכי הביצוע הטכניים תחת סדר העבודה של `START-HERE.md`.

ערכת סקריפטים שמרנית להעברת ה־VPS לפי `server-migration-readiness.md`. ברירת המחדל היא preflight/Dry-run; פעולות שינוי דורשות marker מתאים, `MIGRATION_APPROVAL` ייחודי וקובץ אישור 0400/0600 הקשור במפורש לפעולה, hostname ו־machine-id. זהות שמסומנת גם כמקור וגם כיעד נחסמת.

- [`START-HERE.md`](START-HERE.md) — נקודת הכניסה הראשית, החלטות רכישה וסדר ההעברה המלא.
- [`coverage-matrix.tsv`](coverage-matrix.tsv) — מקור, Export, Restore, אימות, סטטוס ו־Gate לכל רכיב.
- [`OPERATIONS.md`](OPERATIONS.md) — מדריך יחיד, קצר וממוספר, המפריד מקור ויעד.
- [`EXECUTION-GUIDE.md`](EXECUTION-GUIDE.md) — מדריך הרצה מפורט: פקודות, תוצאה רצויה, תנאי המשך ו־STOP בכל שלב.
- [`OPEN-GAPS.md`](OPEN-GAPS.md) — חסמים ופערים שלא נכון להסתיר באוטומציה.
- [`toolkit-validation.txt`](toolkit-validation.txt) — בדיקת מבנה ותחביר.
- [`test-results.txt`](test-results.txt) — ניסויי fixtures חיוביים ושליליים, ללא סודות אמיתיים.

הערכה אינה מבצעת cutover אוטומטי, אינה מפעילה Firewall חי, אינה יוצרת marker יעד ואינה מסנכרנת חזרה למקור.
