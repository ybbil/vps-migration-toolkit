# MariaDB — Preflight status

Updated: 2026-11-03
Status: **PARTIAL PASS — backup utility installed and version-matched; replacement backup credential connection verified. No further action authorized.**

## Read-only checks completed

| Check | Source (`srv1119587`) | Target (`srv2119375`) |
| --- | --- | --- |
| MariaDB server/client version | 11.8.6 | client 11.8.6 |
| `mariadb-backup` installed | yes, `1:11.8.6-0+deb13u1` | yes, `1:11.8.6-0+deb13u1` |
| Available `mariadb-backup` candidate | `1:11.8.6-0+deb13u1` | `1:11.8.6-0+deb13u1` |
| Service state | active / enabled | inactive / disabled |

The installed `mariadb-backup` version matches the installed MariaDB
major/minor on both servers.

## Approved installation and verification

APT simulation completed on both servers before installation. Each simulation
reported exactly `0 upgraded, 1 newly installed, 0 to remove`; the sole new
package was `mariadb-backup=1:11.8.6-0+deb13u1`. No downgrade, removal, or
other package change was simulated or installed.

The exact package was then installed on both servers with
`--no-install-recommends`. On the source, MariaDB retained `MainPID=794` and
the same `ActiveEnterTimestampMonotonic=13351761` before and after install;
there was no MariaDB restart. On the target, MariaDB remained `inactive`,
`dead`, and `disabled`.

The source option file `/etc/mysql/debian.cnf` was checked by metadata only:
`root:root`, mode `0600`. Its contents were neither displayed nor copied.

## Paths and capacity checked

| Item | Result |
| --- | --- |
| Proposed target archive | `/var/tmp/mariadb-restore-trial-20261103.xbstream` |
| Archive and `.partial` existence | both absent; path is new |
| Target free space at `/var/tmp` | 84 GiB |
| Source free space at `/var/tmp` (same root filesystem) | 4.4 GiB |

The eventual streaming backup requires no source archive file, but the limited
source free space remains a monitoring constraint. Capacity is not accepted as
a final backup/restore PASS until authentication succeeds and the restore
plan measures the prepared-copy requirement on the target.

## Preflight result

`mariadb-backup-stream.sh --preflight` was run exactly once. It confirmed the
tool/version path up to the local source connection, then stopped with
`ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: NO)`.
No backup stream, archive, partial file, restore, database write, or service
start occurred. The report contains the same error only; it contains no
credential value.

## Replacement backup credential — connection check

After the failed historical check above, the operator created
`/etc/mysql/migration-backup.cnf`. Its contents were not read, copied, or
recorded. Metadata verified `root:root`, mode `0600`.

A single read-only connection query through that file returned `1` for
`SELECT 1`. This proves that the supplied client option file can authenticate
to the source MariaDB server. It does **not** prove physical-backup privileges,
target/archive readiness, backup success, or restore compatibility.

Per the operator instruction, no second script preflight, backup, restore,
target operation, privilege inspection, or database change was performed.

## Actions deliberately not taken

- No backup was started and no archive path was created.
- No target datadir was touched and MariaDB remains stopped there.
- No credentials or option-file contents were read or recorded.

## Blocking condition and required approval

The original `/etc/mysql/debian.cnf` does not authenticate the backup client.
The replacement file passes a basic connection test, but no privilege test has
been performed. The next action, only after a new approval, is a second
`mariadb-backup-stream.sh --preflight` using `/etc/mysql/migration-backup.cnf`.
Backup streaming and restore remain separate approvals.
