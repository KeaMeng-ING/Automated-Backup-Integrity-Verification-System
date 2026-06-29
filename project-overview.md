# Project Overview

**Project Title:** Automated Backup & Integrity Verification System (`backup_guard.sh`)
**Course:** CYBR 352 — Bash Scripting Project
**Team Size:** 1
**Team Member:** Ing Kea Meng (KeaMeng)
**Deadline:** June 30, 2026

---

## Problem Statement

Manual backups are error-prone and rarely verified — administrators often discover a backup is
corrupted or incomplete only when they actually need to restore it, which is too late. This
project automates the entire backup lifecycle: creating encrypted backups, verifying their
integrity, and testing restorability, without any manual intervention beyond initial setup and
passphrase entry.

---

## Core Functional Sections

1. **Backup Phase**
   Compresses and encrypts target directories/databases (e.g. a PostgreSQL dump or web app
   config) into timestamped, AES-256-CBC encrypted archives. Old backups beyond a configured
   retention count are automatically rotated out.

2. **Integrity Verification**
   Generates and stores a SHA-256 checksum at backup time. On demand, the script decrypts and
   re-hashes the archive to confirm it hasn't been corrupted or tampered with since creation.

3. **Restore Simulation (Dry Run)**
   Extracts a backup into a sandboxed temporary directory, validates that expected contents
   exist, and cleans up afterward — without touching the live system or production data.

4. **Restore**
   Decrypts and extracts a backup into a real destination directory (default `./restored`),
   recovering the original files. Archives store paths relative to each source's parent
   directory, so restores don't recreate the full absolute-path tree.

5. **Cron Scheduling Helper** _(stretch goal)_
   Generates a ready-to-install cron entry so the backup process can run unattended on a
   schedule.

---

## Real-World Relevance

This tool is directly applicable to systems I currently maintain — for example, ShopiLink's
PostgreSQL database or a Supabase-backed project deployment — making it a genuinely reusable
utility rather than a one-off class exercise.

---

## Tools & Technologies

| Tool                                            | Purpose                                 |
| ----------------------------------------------- | --------------------------------------- |
| `tar` / `gzip`                                  | Archive and compress backup sources     |
| `openssl` (AES-256-CBC, PBKDF2)                 | Encrypt/decrypt backup archives         |
| `sha256sum`                                     | Generate and verify integrity checksums |
| `pg_dump` _(optional)_                          | Database-specific backup support        |
| Core Bash (`find`, `date`, `read -s`, `mktemp`) | Scripting, secure input, sandboxing     |

---

## Error Handling Covered

- Missing or unreadable source directories
- Insufficient disk space before starting a backup
- Decryption failures (wrong passphrase or corrupted archive)
- Checksum mismatches (tampering/corruption detection)
- Missing dependencies (tools not installed)
- Invalid or missing CLI arguments

---

## Deliverables

```
CYBR352_Project_KeaMeng/
├── backup_guard.sh          # Main script
├── README.md                # Documentation
├── project-overview.md      # This file
└── assets/
    ├── screenshots/         # Example run screenshots
    └── test_data/           # Sample files used as backup source
```

---

## Grading Alignment

| Rubric Area                 | How This Project Addresses It                                                                                               |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **Functionality (30 pts)**  | Backup, verify, restore-test, and restore all run end-to-end via CLI flags                                                  |
| **Error Handling (20 pts)** | `set -euo pipefail`, dependency checks, input validation, disk space checks, meaningful stderr messages, defined exit codes |
| **Code Quality (20 pts)**   | Modular functions, inline comments, no hardcoded paths, shellcheck-clean                                                    |
| **Documentation (30 pts)**  | README covers overview, dependencies, usage, example output, functions, references                                          |
