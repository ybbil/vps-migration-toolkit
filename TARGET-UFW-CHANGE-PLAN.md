# תוכנית שינוי UFW — יעד `2119375`

## מצב שנמדד בקריאה בלבד

ב־`srv2119375.hstgr.cloud` UFW פעיל עם `deny incoming`,‏ `allow outgoing` ו־`disabled (routed)`. הכללים הקיימים הם:

- `22/tcp` מ־Anywhere ב־IPv4 וב־IPv6.
- `443/udp` מ־Anywhere ב־IPv4 וב־IPv6, בהערה `wireguard-target-staged`.

UDP/443 כבר תואם למדיניות המתוכננת. בהחלה העתידית מגדירים במפורש גם `deny routed` (במקום המצב הנוכחי המדווח כ־`disabled (routed)`) ומאשרים שוב את שתי ברירות המחדל האחרות. לאחר מכן מצמצמים SSH לארבע רשתות ניהול בלבד:

- `213.137.0.0/16`
- `147.234.0.0/16`
- `46.31.0.0/16`
- `185.24.0.0/16`
- `72.61.138.158/32` — שרת המקור, לחיבור SSH תפעולי/חירום אל היעד

## חסם בטיחות לפני Apply

בזמן המדידה היה חיבור SSH פעיל יחיד, מ־`72.61.138.158`. כתובת זו אינה מכוסה באף אחת מארבע רשתות הניהול. חיבור SSH קיים בדרך כלל יישאר פעיל בזכות conntrack, אבל login חדש מאותו מקור ייחסם לאחר מחיקת כלל `Anywhere`; לכן זה אינו נתיב חזרה מספיק.

לפני כל שינוי נדרשים יחד:

1. Console פעיל ונבדק ידנית ב־Hostinger.
2. שתי התחברויות SSH נפרדות ליעד, שלפחות אחת מהן מגיעה מאחת מארבע רשתות הניהול המאושרות.
3. בדיקת login חדש מאותה רשת ניהול לאחר הוספת כללי ה־CIDR ולפני מחיקת כלל `Anywhere`.

אין לבצע את הפקודות הבאות עד שכל שלושת התנאים עברו.

## פקודות מוכנות לביצוע עתידי

ב־session הראשון, לאחר קיום תנאי הבטיחות:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw allow from 213.137.0.0/16 to any port 22 proto tcp
ufw allow from 147.234.0.0/16 to any port 22 proto tcp
ufw allow from 46.31.0.0/16 to any port 22 proto tcp
ufw allow from 185.24.0.0/16 to any port 22 proto tcp
ufw allow from 72.61.138.158 to any port 22 proto tcp
ufw status numbered
```

לאחר מכן פותחים login חדש מרשת ניהול מאושרת ובודקים שהוא עובד. רק לאחר PASS ו־Console זמין, מציגים מחדש את `ufw status numbered` ומסירים ידנית ובסדר יורד את שני כללי SSH הרחבים `22/tcp ALLOW IN Anywhere` ו־`22/tcp (v6) ALLOW IN Anywhere (v6)` לפי המספרים שיופיעו באותו רגע:

```bash
ufw --force delete <NUMBER_OF_IPV6_ANYWHERE_SSH_RULE>
ufw --force delete <NUMBER_OF_IPV4_ANYWHERE_SSH_RULE>
ufw status verbose
ufw status numbered
```

אין למחוק את UDP/443, ואין להוסיף שירותים נוספים במסגרת שינוי זה. לאחר Apply יש להפעיל login חדש נוסף מכל מקור ניהול נדרש, ולאמת גם שה־Console עדיין זמין.
