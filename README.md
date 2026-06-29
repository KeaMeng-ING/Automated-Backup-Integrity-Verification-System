# backup_guard.sh — Automated Backup & Integrity Verification System

**Course:** CYBR 352 — Bash Scripting Project
**Author:** Ing Kea Meng (KeaMeng)

---

## Overview

`backup_guard.sh` automates the full backup lifecycle so that backups are never
"discovered broken" at restore time:

1. **Backup** — compresses the configured source directories with `tar`/`gzip`,
   encrypts the archive with **AES-256-CBC (PBKDF2)** via `openssl`, and writes a
   **SHA-256** checksum next to it. Old backups beyond a retention count are
   rotated out automatically.
2. **Verify** — recomputes the SHA-256 of an existing backup and compares it to the
   stored checksum to detect corruption or tampering.
3. **Restore test (dry run)** — decrypts and extracts a backup into a disposable
   `mktemp -d` sandbox, confirms files were recovered, then cleans up — without
   touching live data.
4. **Restore** — decrypts and extracts a backup into a real destination directory
   (default `./restored`) so the original files can actually be recovered.
5. **Schedule** — prints a ready-to-paste `cron` line for unattended daily backups.

Sources are archived **relative to their parent directory** (a backup of
`…/test_data` stores `test_data/...`), so restores don't recreate the full absolute
path tree.

Security choices: the passphrase is read with `read -r -s` (never echoed), kept only
in a `local` variable, **piped to `openssl` over stdin** (never passed as a CLI
argument, so it can't leak via `ps`), and `unset` immediately after use. It is never
written to the log.

---

## Dependencies

| Tool | Purpose |
|---|---|
| `tar`, `gzip` | Archive + compress source directories |
| `openssl` | AES-256-CBC / PBKDF2 encryption + decryption |
| `sha256sum` | Integrity checksums (part of GNU coreutils) |
| core Bash (`date`, `read -s`, `mktemp`, `find`, `du`, `df`) | Scripting, secure input, sandboxing |

Install on Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y tar gzip openssl coreutils
# Optional, to lint the script:
sudo apt install -y shellcheck
```

`tar`, `gzip`, `openssl` and `coreutils` (which provides `sha256sum`) are present by
default on virtually all Linux distributions.

---

## Configuration

All settings live at the top of `backup_guard.sh` (and can be overridden by
environment variables — no hardcoded paths):

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_DIR` | `<script dir>/backups` | Where encrypted backups + checksums are stored |
| `SOURCE_DIRS` | `(<script dir>/test_data)` | Bash array of directories to back up |
| `ENCRYPTION` | `true` | Encrypt the archive (`true`) or keep plain `.tar.gz` (`false`) |
| `RETENTION_COUNT` | `5` | Number of most-recent backups to keep |
| `LOG_FILE` | `<script dir>/backup_guard.log` | Timestamped info + error log |

Paths are anchored to the script's own directory (`SCRIPT_DIR`), so backups stay
inside the project folder regardless of where the script is invoked from.

---

## Usage

```bash
./backup_guard.sh --backup                 # create a new encrypted backup
./backup_guard.sh --verify <file>          # check a backup's SHA-256 integrity
./backup_guard.sh --restore-test <file>    # sandboxed decrypt + extract dry run
./backup_guard.sh --restore <file> [dest]  # decrypt + extract into dest (default ./restored)
./backup_guard.sh --schedule               # print a cron entry for daily backups
./backup_guard.sh --help                   # show help
```

`<file>` may be a full path or a bare filename resolved against `BACKUP_DIR`.

**Examples**

```bash
# Make a backup (prompts for an encryption passphrase)
./backup_guard.sh --backup

# Verify the backup just created
./backup_guard.sh --verify backup_2026-06-25_185723.tar.gz.enc

# Prove it's restorable (prompts for the decryption passphrase)
./backup_guard.sh --restore-test backup_2026-06-25_185723.tar.gz.enc

# Actually recover the files into ./restored (or a directory you name)
./backup_guard.sh --restore backup_2026-06-25_185723.tar.gz.enc
./backup_guard.sh --restore backup_2026-06-25_185723.tar.gz.enc ~/Desktop/recovered
```

**Exit codes:** `0` success · `1` general failure (mismatch, decryption failure,
missing dependency/file) · `2` misuse / bad arguments / insufficient disk space.

---

## Example Output

### `--backup` (success)

```
$ ./backup_guard.sh --backup
2026-06-25 18:57:23 [INFO] All dependencies present: tar gzip openssl sha256sum
2026-06-25 18:57:23 [INFO] Source directory OK: ./test_data
2026-06-25 18:57:23 [INFO] Estimated space required: 14745 bytes; available: 53783134208 bytes.
2026-06-25 18:57:23 [INFO] Disk space check passed.
2026-06-25 18:57:23 [INFO] Creating archive from: ./test_data
2026-06-25 18:57:23 [INFO] Archive created: .../backup_2026-06-25_185723.tar.gz
Enter encryption passphrase:
2026-06-25 18:57:24 [INFO] Encrypted backup created: .../backup_2026-06-25_185723.tar.gz.enc
2026-06-25 18:57:24 [INFO] Checksum written: .../backup_2026-06-25_185723.tar.gz.enc.sha256
2026-06-25 18:57:24 [INFO] Rotation: 1 backup(s) present, retention is 5; nothing to remove.
2026-06-25 18:57:24 [INFO] Backup completed successfully: .../backup_2026-06-25_185723.tar.gz.enc
```

### `--verify` (integrity OK)

```
$ ./backup_guard.sh --verify backup_2026-06-25_185723.tar.gz.enc
2026-06-25 18:57:33 [INFO] All dependencies present: tar gzip openssl sha256sum
2026-06-25 18:57:33 [INFO] Verifying integrity of: .../backup_2026-06-25_185723.tar.gz.enc
2026-06-25 18:57:33 [INFO] Integrity OK — checksum MATCH for backup_2026-06-25_185723.tar.gz.enc
$ echo $?
0
```

### `--restore-test` (success)

```
$ ./backup_guard.sh --restore-test backup_2026-06-25_185723.tar.gz.enc
2026-06-25 18:57:33 [INFO] Restore dry-run for .../backup_2026-06-25_185723.tar.gz.enc in sandbox /var/folders/.../tmp.C1m1XTaqL5
Enter decryption passphrase:
2026-06-25 18:57:33 [INFO] Decryption succeeded.
2026-06-25 18:57:33 [INFO] Restore test PASS — extracted 3 file(s) successfully.
2026-06-25 18:57:33 [INFO] Cleaned up restore sandbox: /var/folders/.../tmp.C1m1XTaqL5
```

### `--restore` (success)

```
$ ./backup_guard.sh --restore backup_2026-06-25_185723.tar.gz.enc
2026-06-25 18:57:33 [INFO] All dependencies present: tar gzip openssl sha256sum
2026-06-25 18:57:33 [INFO] Restoring .../backup_2026-06-25_185723.tar.gz.enc into .../restored
Enter decryption passphrase:
2026-06-25 18:57:33 [INFO] Decryption succeeded.
2026-06-25 18:57:33 [INFO] Restore complete — 3 file(s) restored under .../restored
```

### Failure case 1 — checksum MISMATCH (tampering / corruption detected)

```
$ ./backup_guard.sh --verify tamper_copy.tar.gz.enc
2026-06-25 18:57:33 [INFO] Verifying integrity of: .../tamper_copy.tar.gz.enc
2026-06-25 18:57:33 [ERROR] Integrity FAILED — checksum MISMATCH for tamper_copy.tar.gz.enc
2026-06-25 18:57:33 [ERROR]   expected: 66c37f04a3ebd6a37d0bcb5b42bbacf28e0e73b6c14ac14969da4f19329c9837
2026-06-25 18:57:33 [ERROR]   actual:   ebc2b427bb5ad497a441da7a38254002acf517835ea376a373ee7141b1ec8bd0
$ echo $?
1
```

### Failure case 2 — wrong passphrase on restore

```
$ ./backup_guard.sh --restore-test backup_2026-06-25_185723.tar.gz.enc
2026-06-25 18:57:33 [INFO] Restore dry-run for ... in sandbox /var/folders/.../tmp.QaYFmURtQr
Enter decryption passphrase:
2026-06-25 18:57:33 [ERROR] Decryption failed - wrong passphrase or corrupted file
2026-06-25 18:57:33 [INFO] Cleaned up restore sandbox: /var/folders/.../tmp.QaYFmURtQr
$ echo $?
1
```

### Failure case 3 — missing dependency

```
$ ./backup_guard.sh --backup     # (run with openssl/sha256sum unavailable)
2026-06-25 18:58:12 [ERROR] Missing required dependencies: openssl sha256sum
2026-06-25 18:58:12 [ERROR] Install them and re-run (see README for apt commands).
$ echo $?
1
```

### `--schedule`

```
$ ./backup_guard.sh --schedule
# Add the following line via 'crontab -e' to run a backup daily at 2:00 AM:

0 2 * * * /Users/keameng/Desktop/linuxFinal/backup_guard.sh --backup >> .../backup_guard.log 2>&1

# Notes:
#  - Encrypted backups prompt for a passphrase; for unattended cron runs set
#    ENCRYPTION=false, or supply the passphrase via a secured mechanism.
#  - Run 'crontab -l' to confirm the entry was added.
```

---

## Functions

| Function | Purpose |
|---|---|
| `check_deps()` | Verifies `tar`, `gzip`, `openssl`, `sha256sum` are installed; lists any missing on stderr and exits `1`. |
| `log_msg()` | Prints a timestamped `[INFO]` message to stdout and appends it to `LOG_FILE`. |
| `log_error()` | Prints a timestamped `[ERROR]` message to stderr and appends it to `LOG_FILE`. |
| `validate_source_dirs()` | Confirms each `SOURCE_DIRS` entry exists and is readable; warns and **skips** bad ones; exits `1` only if none are valid. |
| `dir_size_bytes()` / `avail_bytes()` | Portable size helpers — `du -sb` (with a `du -sk`×1024 fallback) and `df -Pk`×1024. |
| `check_disk_space()` | Estimates required space (source size + 20% margin) vs. free space in `BACKUP_DIR`; exits `2` if insufficient. |
| `do_backup()` | tar+gzip (each source stored relative to its parent dir) → prompt passphrase → `openssl` AES-256-CBC encrypt → delete plaintext tarball → SHA-256 checksum → rotate. |
| `rotate_backups()` | Keeps the `RETENTION_COUNT` newest backups (sorted by timestamped name), deletes older ones plus their `.sha256`, logs each removal. |
| `verify_backup(file)` | Checks the backup and its `.sha256` exist, recomputes the hash, and `case`-branches on `MATCH` (exit 0) / `MISMATCH` (exit 1). |
| `restore_test(file)` | `mktemp -d` sandbox → decrypt (`openssl -d`) → extract → non-empty sanity check → PASS/FAIL; cleans up via `trap ... EXIT`. |
| `restore_backup(file, [dest])` | Decrypt (`openssl -d`) → extract into `dest` (default `./restored`) → report file count; recovers files for real (not a dry run). |
| `generate_cron_line()` | Prints a ready-to-paste daily `cron` entry running `"$0" --backup`. |
| `usage()` | Prints help and exits `2`. |
| `main()` | Parses `--backup` / `--verify` / `--restore-test` / `--restore` / `--schedule` / `--help` and dispatches; unknown args → `usage` (exit 2). |

---

## Testing

```bash
# Syntax check
bash -n backup_guard.sh

# Lint (if shellcheck installed) — designed to pass cleanly
shellcheck backup_guard.sh

# Full run against the bundled sample data
./backup_guard.sh --backup
./backup_guard.sh --verify <generated-file>.tar.gz.enc
./backup_guard.sh --restore-test <generated-file>.tar.gz.enc
./backup_guard.sh --restore <generated-file>.tar.gz.enc ./restored
```

A `test_data/` directory ships with a fake SQL dump (`database_dump.sql`), an app
config (`app_config.conf`), and a `notes.txt`, used as the default backup source.

---

## References

- `openssl-enc(1)` — symmetric cipher encryption:
  <https://www.openssl.org/docs/man3.0/man1/openssl-enc.html>
- PBKDF2 key derivation — `openssl` `-pbkdf2` flag (RFC 8018):
  <https://datatracker.ietf.org/doc/html/rfc8018>
- `sha256sum(1)` (GNU coreutils):
  <https://www.gnu.org/software/coreutils/manual/html_node/sha2-utilities.html>
- `tar(1)`: <https://www.gnu.org/software/tar/manual/tar.html>
- `crontab(5)`: <https://man7.org/linux/man-pages/man5/crontab.5.html>
- Bash Reference Manual: <https://www.gnu.org/software/bash/manual/bash.html>
- ShellCheck: <https://www.shellcheck.net/>
