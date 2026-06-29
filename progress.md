# Progress — backup_guard.sh (CYBR 352)

Author: Ing Kea Meng · Deadline: 2026-06-30

## Feature / Function Checklist

### Header

- [x] `#!/bin/bash` shebang
- [x] `set -euo pipefail`
- [x] Global config vars (BACKUP_DIR, SOURCE_DIRS array, ENCRYPTION, RETENTION_COUNT, LOG_FILE)

### Functions

- [x] `check_deps()`
- [x] `log_msg()`
- [x] `log_error()`
- [x] `validate_source_dirs()`
- [x] `check_disk_space()`
- [x] `do_backup()`
- [x] `rotate_backups()`
- [x] `verify_backup()`
- [x] `restore_test()`
- [x] `generate_cron_line()`
- [x] `usage()`
- [x] `main()` (CLI arg parsing)

### Supporting deliverables

- [x] `test_data/` with dummy files (fake .sql dump + config + extra)
- [x] Tested `--backup` end-to-end
- [x] Tested `--verify` (match + tamper/mismatch case)
- [x] Tested `--restore-test` (pass + wrong-passphrase fail case)
- [x] Tested `--schedule` and `--help`
- [x] `README.md` written with real example output

## Decisions & Notes

- **Portable size measurement.** Requirement specifies `du -sb` / byte-accurate disk math, which
  is GNU-only. To keep the script runnable on both the Linux grader and my macOS dev machine I
  wrote `dir_size_bytes()` that tries `du -sb` first and falls back to `du -sk * 1024`. Same for
  free space: `df -Pk` (POSIX, works everywhere) \* 1024. Net behaviour matches the spec on Linux.
- **Passphrase never logged / never on the command line.** Read with `read -r -s -p`, kept only in
  a `local` variable, and piped to `openssl ... -pass stdin` via `printf %s`. It is never passed as
  a CLI arg (would leak via `ps`) and never echoed or written to the log.
- **mktemp -d for restore sandbox** instead of a fixed `/tmp/...` path — avoids collisions and
  predictable-path symlink attacks. Cleaned up via a `trap ... EXIT` so the sandbox is removed even
  if the script aborts mid-restore.
- **Backup naming `backup_YYYY-MM-DD_HHMMSS.tar.gz.enc`** sorts chronologically as plain text, so
  rotation can sort lexicographically (glob order) with no date parsing.
- **Rotation uses a nullglob array**, not `ls` parsing (avoids the classic `ls`-in-pipe pitfall and
  is shellcheck-clean).
- **Disk-space check adds a 20% safety margin** over the raw source size to account for tar/gzip
  metadata and the temporary co-existence of the `.tar.gz` and `.tar.gz.enc` files.
- Exit codes: `0` success · `1` general failure · `2` misuse/bad args (per spec).

## Known Issues / TODO

- `du -sb` accuracy: on macOS the fallback measures in KiB granularity, so the estimate is slightly
  coarser locally than on the Linux grader. No functional impact.
- Compression ratio is not predicted — disk check is intentionally conservative (estimates the
  encrypted output at roughly the uncompressed source size + margin), which can over-reserve space
  for highly compressible inputs. Acceptable trade-off (fail-safe).
