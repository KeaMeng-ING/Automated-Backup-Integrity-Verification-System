# Automated Backup & Integrity Verification System

## 1. Overview
This project is an automated backup utility built to stop **"Schrödinger's Backup"** issues—where administrators think their system data is backed up safely, only to discover data corruption during an actual infrastructure emergency. 

This script handles the full lifecycle of data safety: compressing files, protecting them with strong industrial encryption, generating cryptographic signatures to catch silent file corruption, and spawning secure virtual sandboxes to safely test data restorations on demand.

* **Course Topic:** Secure System Administration & Scripting Automation
* **Course Code:** CYBR 352 University Project
* **Team Names:** ING Kea Meng, HOEURN Manet, LIM Petnikola

---

## 2. Dependencies
The script relies entirely on standard, lightweight Unix management utilities. Ensure your Linux environment has them configured before running operations:

* **tar & gzip:** For system file compression.
* **openssl:** Handles the military-grade AES-256 symmetric encryption layers.
* **coreutils (sha256sum):** Computes cryptographic file fingerprints.

### Universal Installation Command
Run the following package manager command to prepare your system environment:
```bash
sudo apt update && sudo apt install coreutils tar gzip openssl -y
```

---

## 3. Usage

The script uses distinct execution flags to manage operations cleanly from your command line terminal interface.

### Running a Secure Backup

Creates an archive, prompts your keyboard secretly for a password, and clears standard text data away.

```bash
./backup_guard.sh --backup
```

### Checking File Corruption (Integrity Check)

```bash
./backup_guard.sh --verify backups/backup_2026-06-30_110000.tar.gz.enc
```


### Performing Live Production Restorations

```bash
./backup_guard.sh --restore backups/backup_2026-06-30_110000.tar.gz.enc ./my_restored_files
```

---

## 4. Example Output

Outputs are stored in assets/

## 5. Functions

| Function Name | Inputs | Outputs | Purpose Description |
| --- | --- | --- | --- |
| `log()` | `type` (String), `msg` (String) | Timestamped text in console + file | Keeps a permanent history log trail of backup metrics. |
| `check_env()` | Global Config Paths | Exit code `1` or `2` if unsafe | Validates system storage space and verifies necessary system apps exist. |
| `do_backup()` | Global Arrays | Encrypted `.enc` file + `.sha256` key | Groups targets, requests user keys, locks down files, and clears temp data. |
| `verify_backup()` | Target path filename | Exit code `0` (Valid) or `1` (Corrupted) | Computes a live hash value and verifies it against initial signatures. |
| `restore_sandbox()` | Target path filename | Automated directory wipe on exit | Sets up an isolated sandbox, tries decryption, and validates internal contents. |
| `restore_live()` | Target path + Output Path | Freshly unpacked system directories | Unpacks encrypted data safely back into production folders. |

---

## 6. References

* **OpenSSL Manual Pages:** `man openssl` and `man enc` parameters for secure PBKDF2 hashing workflows.
* **GNU Tar Documentation:** Standard path isolation rules via the `-C` operational execution switch.
* **POSIX Disk Reference Standards:** Field analysis parameters for reading core terminal disk maps using `df`.
