#!/bin/bash
#
# backup_guard.sh — Automated Backup & Integrity Verification System
# CYBR 352 University Project — Ing Kea Meng (KeaMeng)
#
# Creates timestamped, gzip-compressed, AES-256-CBC encrypted backups of a set of
# source directories, fingerprints them with SHA-256, rotates out old backups, and
# can verify integrity or perform a sandboxed restore dry-run on demand.
#
# Exit codes:
#   0  success
#   1  general failure (verification mismatch, decryption failure, etc.)
#   2  misuse / bad arguments / insufficient disk space
#
# Usage: see usage() or run `./backup_guard.sh --help`

set -euo pipefail

# ----------------------------------------------------------------------------
# GLOBAL CONFIGURATION
# Everything operational lives here — no hardcoded paths buried in functions.
# ----------------------------------------------------------------------------

# Absolute path to the directory containing this script (the project folder).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Directory where encrypted backups + checksums are stored.
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"

# Directories whose contents get backed up. Edit this array for your system.
SOURCE_DIRS=(
    "$SCRIPT_DIR/test_data"
)

# Whether to encrypt the archive (true/false). When false the .tar.gz is kept as-is.
ENCRYPTION="${ENCRYPTION:-true}"

# How many of the most recent backups to keep; older ones are deleted on rotation.
RETENTION_COUNT="${RETENTION_COUNT:-5}"

# Central log file (info + errors are appended here, with timestamps).
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/backup_guard.log}"

# ----------------------------------------------------------------------------
# LOGGING
# ----------------------------------------------------------------------------

# log_msg — print a timestamped INFO message to stdout and append it to LOG_FILE.
# Input:  message string ($*)
# Output: "<timestamp> [INFO] <message>" on stdout and in LOG_FILE.
log_msg() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    # Ensure the log directory exists before writing.
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "${timestamp} [INFO] $*" | tee -a "$LOG_FILE"
}

# log_error — print a timestamped ERROR message to stderr and append it to LOG_FILE.
# Input:  message string ($*)
# Output: "<timestamp> [ERROR] <message>" on stderr and in LOG_FILE.
log_error() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "${timestamp} [ERROR] $*" | tee -a "$LOG_FILE" >&2
}

# ----------------------------------------------------------------------------
# DEPENDENCY & INPUT VALIDATION
# ----------------------------------------------------------------------------

# check_deps — verify all required external tools are installed.
# Input:  none
# Output: nothing on success; on failure prints the missing tools to stderr and exit 1.
check_deps() {
    local -a required=(tar gzip openssl sha256sum)
    local -a missing=()
    local tool

    for tool in "${required[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Install them and re-run (see README for apt commands)."
        exit 1
    fi
    log_msg "All dependencies present: ${required[*]}"
}

# validate_source_dirs — confirm each SOURCE_DIRS entry exists and is readable.
# Non-existent / unreadable dirs are warned about and SKIPPED (no hard exit), so a
# single bad path doesn't abort the whole backup.
# Input:  reads global SOURCE_DIRS
# Output: populates global VALID_SOURCES array; exit 1 only if NOTHING is valid.
validate_source_dirs() {
    local dir
    VALID_SOURCES=()   # global: consumed by check_disk_space and do_backup

    for dir in "${SOURCE_DIRS[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Source directory does not exist, skipping: $dir"
            continue
        fi
        if [[ ! -r "$dir" ]]; then
            log_error "Source directory not readable, skipping: $dir"
            continue
        fi
        VALID_SOURCES+=("$dir")
        log_msg "Source directory OK: $dir"
    done

    if [[ ${#VALID_SOURCES[@]} -eq 0 ]]; then
        log_error "No valid, readable source directories — nothing to back up."
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# SIZE / DISK-SPACE HELPERS
# ----------------------------------------------------------------------------

# dir_size_bytes — size of a directory tree in bytes.
# Prefers GNU `du -sb` (byte-accurate, per spec); falls back to portable
# `du -sk` * 1024 on systems without -b (e.g. macOS), so the script is portable.
# Input:  $1 = directory path
# Output: prints the size in bytes to stdout.
dir_size_bytes() {
    local dir="$1" size
    if size="$(du -sb "$dir" 2>/dev/null | awk '{print $1}')" && [[ -n "$size" ]]; then
        echo "$size"
    else
        # Portable fallback: kilobytes -> bytes.
        size="$(du -sk "$dir" | awk '{print $1}')"
        echo $(( size * 1024 ))
    fi
}

# avail_bytes — free space (bytes) on the filesystem holding a given path.
# Uses POSIX `df -Pk` (works on Linux and macOS) and converts KiB -> bytes.
# Input:  $1 = path
# Output: prints available bytes to stdout.
avail_bytes() {
    local path="$1" kib
    kib="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
    echo $(( kib * 1024 ))
}

# check_disk_space — make sure BACKUP_DIR's filesystem can hold the new backup.
# Estimates required space as (sum of source sizes) + 20% margin to cover archive
# metadata and the brief moment the .tar.gz and .tar.gz.enc both exist.
# Input:  reads VALID_SOURCES and BACKUP_DIR
# Output: nothing on success; exit 2 if there is not enough free space.
check_disk_space() {
    local dir total=0 sz required available
    mkdir -p "$BACKUP_DIR"

    for dir in "${VALID_SOURCES[@]}"; do
        sz="$(dir_size_bytes "$dir")"
        total=$(( total + sz ))
    done

    # Add a 20% safety margin.
    required=$(( total + total / 5 ))
    available="$(avail_bytes "$BACKUP_DIR")"

    log_msg "Estimated space required: ${required} bytes; available: ${available} bytes."

    if [[ "$available" -lt "$required" ]]; then
        log_error "Insufficient disk space in $BACKUP_DIR (need ~${required}B, have ${available}B)."
        exit 2
    fi
    log_msg "Disk space check passed."
}

# ----------------------------------------------------------------------------
# BACKUP
# ----------------------------------------------------------------------------

# do_backup — create a compressed, optionally-encrypted, checksummed backup.
# Steps: tar+gzip sources -> prompt passphrase -> openssl encrypt -> drop plaintext
#        tarball -> sha256sum the .enc -> rotate old backups.
# Input:  reads VALID_SOURCES, BACKUP_DIR, ENCRYPTION
# Output: <BACKUP_DIR>/backup_<ts>.tar.gz[.enc] + matching .sha256; exit 1 on failure.
do_backup() {
    local timestamp tarball target checksum_file passphrase src
    local tar_args=()
    timestamp="$(date '+%Y-%m-%d_%H%M%S')"
    tarball="${BACKUP_DIR}/backup_${timestamp}.tar.gz"

    mkdir -p "$BACKUP_DIR"

    # Store each source relative to its parent dir (e.g. "test_data/...") instead of
    # its full absolute path, so restores don't recreate the whole Users/.../ tree.
    for src in "${VALID_SOURCES[@]}"; do
        tar_args+=( -C "$(dirname "$src")" "$(basename "$src")" )
    done

    log_msg "Creating archive from: ${VALID_SOURCES[*]}"
    if ! tar -czf "$tarball" "${tar_args[@]}" 2>/dev/null; then
        log_error "Failed to create tar archive: $tarball"
        rm -f "$tarball"
        exit 1
    fi
    log_msg "Archive created: $tarball"

    if [[ "$ENCRYPTION" == "true" ]]; then
        target="${tarball}.enc"

        # Read passphrase securely: silent (-s), raw (-r), prompted. Stored only in a
        # local var, never logged, never passed on the command line.
        read -r -s -p "Enter encryption passphrase: " passphrase
        echo    # newline after the silent prompt

        # Pipe the passphrase to openssl via stdin (NOT as a CLI arg -> not visible in `ps`).
        if ! printf '%s' "$passphrase" | \
            openssl enc -aes-256-cbc -pbkdf2 -salt \
                -in "$tarball" -out "$target" -pass stdin; then
            log_error "Encryption failed for: $tarball"
            rm -f "$tarball" "$target"
            unset passphrase
            exit 1
        fi
        unset passphrase   # clear secret from memory ASAP

        # Remove the unencrypted intermediate tarball.
        rm -f "$tarball"
        log_msg "Encrypted backup created: $target"
    else
        target="$tarball"
        log_msg "Encryption disabled; keeping plain archive: $target"
    fi

    # SHA-256 fingerprint of the final artifact, stored alongside it.
    checksum_file="${target}.sha256"
    ( cd "$BACKUP_DIR" && sha256sum "$(basename "$target")" > "$(basename "$checksum_file")" )
    log_msg "Checksum written: $checksum_file"

    rotate_backups
    log_msg "Backup completed successfully: $target"
}

# rotate_backups — keep only the RETENTION_COUNT most recent backups.
# Backups sort chronologically by name, so a sorted glob is enough.
# Input:  reads BACKUP_DIR, RETENTION_COUNT
# Output: deletes old .enc/.tar.gz + their .sha256 files and logs each deletion.
rotate_backups() {
    local -a backups=()
    local count remove i base

    shopt -s nullglob
    # Match both encrypted and plain backups; glob expands in sorted (chronological) order.
    backups=( "$BACKUP_DIR"/backup_*.tar.gz.enc "$BACKUP_DIR"/backup_*.tar.gz )
    shopt -u nullglob

    count=${#backups[@]}
    if [[ "$count" -le "$RETENTION_COUNT" ]]; then
        log_msg "Rotation: ${count} backup(s) present, retention is ${RETENTION_COUNT}; nothing to remove."
        return 0
    fi

    remove=$(( count - RETENTION_COUNT ))
    log_msg "Rotation: ${count} backups exceed retention ${RETENTION_COUNT}; removing ${remove} oldest."

    for (( i = 0; i < remove; i++ )); do
        base="${backups[i]}"
        rm -f "$base" "${base}.sha256"
        log_msg "Rotated out old backup: $base"
    done
}

# ----------------------------------------------------------------------------
# VERIFY
# ----------------------------------------------------------------------------

# verify_backup — recompute the SHA-256 of a backup and compare to its stored value.
# Input:  $1 = backup filename (path or bare name resolved against BACKUP_DIR)
# Output: MATCH -> log success, exit 0; MISMATCH -> log_error, exit 1.
verify_backup() {
    local target="$1" checksum_file expected actual result base

    # Allow either an absolute/relative path or a bare filename inside BACKUP_DIR.
    if [[ ! -f "$target" && -f "${BACKUP_DIR}/${target}" ]]; then
        target="${BACKUP_DIR}/${target}"
    fi
    checksum_file="${target}.sha256"

    if [[ ! -f "$target" ]]; then
        log_error "Backup file not found: $target"
        exit 1
    fi
    if [[ ! -f "$checksum_file" ]]; then
        log_error "Checksum file not found: $checksum_file"
        exit 1
    fi

    # Stored checksum is "<hash>  <basename>" — take the hash field only.
    expected="$(awk '{print $1}' "$checksum_file")"
    base="$(basename "$target")"
    actual="$( cd "$(dirname "$target")" && sha256sum "$base" | awk '{print $1}' )"

    log_msg "Verifying integrity of: $target"

    # Branch on the comparison result, per spec.
    if [[ "$expected" == "$actual" ]]; then
        result="MATCH"
    else
        result="MISMATCH"
    fi

    case "$result" in
        MATCH)
            log_msg "Integrity OK — checksum MATCH for $base"
            exit 0
            ;;
        MISMATCH)
            log_error "Integrity FAILED — checksum MISMATCH for $base"
            log_error "  expected: $expected"
            log_error "  actual:   $actual"
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# RESTORE DRY-RUN
# ----------------------------------------------------------------------------

# SANDBOX holds the temp restore dir so the EXIT trap can clean it up globally.
SANDBOX=""

# cleanup_sandbox — remove the restore sandbox; registered on EXIT by restore_test.
cleanup_sandbox() {
    if [[ -n "$SANDBOX" && -d "$SANDBOX" ]]; then
        rm -rf "$SANDBOX"
        log_msg "Cleaned up restore sandbox: $SANDBOX"
    fi
}

# restore_test — sandboxed decrypt + extract dry-run to prove a backup is restorable.
# Input:  $1 = backup filename (path or bare name resolved against BACKUP_DIR)
# Output: PASS -> exit 0; FAIL (decrypt/extract/empty) -> log_error, exit 1.
#         The sandbox is always removed via the EXIT trap, even on mid-run errors.
restore_test() {
    local target="$1" passphrase tarball file_count

    if [[ ! -f "$target" && -f "${BACKUP_DIR}/${target}" ]]; then
        target="${BACKUP_DIR}/${target}"
    fi
    if [[ ! -f "$target" ]]; then
        log_error "Backup file not found: $target"
        exit 1
    fi

    # Create an isolated, unpredictable sandbox; trap guarantees cleanup.
    SANDBOX="$(mktemp -d)"
    trap cleanup_sandbox EXIT
    log_msg "Restore dry-run for $target in sandbox $SANDBOX"

    tarball="${SANDBOX}/restore.tar.gz"

    if [[ "$ENCRYPTION" == "true" || "$target" == *.enc ]]; then
        read -r -s -p "Enter decryption passphrase: " passphrase
        echo

        # Decrypt into the sandbox. A wrong passphrase or corrupt file -> non-zero exit.
        if ! printf '%s' "$passphrase" | \
            openssl enc -d -aes-256-cbc -pbkdf2 \
                -in "$target" -out "$tarball" -pass stdin 2>/dev/null; then
            unset passphrase
            log_error "Decryption failed - wrong passphrase or corrupted file"
            exit 1
        fi
        unset passphrase
        log_msg "Decryption succeeded."
    else
        cp "$target" "$tarball"
    fi

    # Extract the archive inside the sandbox.
    if ! tar -xzf "$tarball" -C "$SANDBOX" 2>/dev/null; then
        log_error "Extraction failed - archive is not a valid tar.gz or is corrupted."
        exit 1
    fi

    # Basic sanity check: at least one regular file must have been extracted
    # (exclude the decrypted tarball itself from the count).
    file_count="$(find "$SANDBOX" -type f ! -name 'restore.tar.gz' | wc -l | tr -d ' ')"

    if [[ "$file_count" -gt 0 ]]; then
        log_msg "Restore test PASS — extracted ${file_count} file(s) successfully."
        exit 0
    else
        log_error "Restore test FAIL — archive extracted but contained no files."
        exit 1
    fi
}

# restore_backup — decrypt + extract a backup into a real destination directory.
# Input:  $1 = backup filename (path or bare name resolved against BACKUP_DIR)
#         $2 = destination directory (optional; defaults to ./restored).
# Output: files extracted under <dest>; exit 0 on success, exit 1 on failure.
restore_backup() {
    local target="$1" dest="${2:-}" passphrase tarball file_count
    dest="${dest:-$SCRIPT_DIR/restored}"   # empty or unset -> default destination

    if [[ ! -f "$target" && -f "${BACKUP_DIR}/${target}" ]]; then
        target="${BACKUP_DIR}/${target}"
    fi
    if [[ ! -f "$target" ]]; then
        log_error "Backup file not found: $target"
        exit 1
    fi

    mkdir -p "$dest"
    log_msg "Restoring $target into $dest"

    # Decrypt (if needed) into a temp tarball alongside the destination.
    tarball="$(mktemp "${TMPDIR:-/tmp}/backup_guard_restore.XXXXXX.tar.gz")"

    if [[ "$ENCRYPTION" == "true" || "$target" == *.enc ]]; then
        read -r -s -p "Enter decryption passphrase: " passphrase
        echo

        if ! printf '%s' "$passphrase" | \
            openssl enc -d -aes-256-cbc -pbkdf2 \
                -in "$target" -out "$tarball" -pass stdin 2>/dev/null; then
            unset passphrase
            rm -f "$tarball"
            log_error "Decryption failed - wrong passphrase or corrupted file"
            exit 1
        fi
        unset passphrase
        log_msg "Decryption succeeded."
    else
        cp "$target" "$tarball"
    fi

    # Extract into the destination directory.
    if ! tar -xzf "$tarball" -C "$dest" 2>/dev/null; then
        rm -f "$tarball"
        log_error "Extraction failed - archive is not a valid tar.gz or is corrupted."
        exit 1
    fi
    rm -f "$tarball"   # remove the decrypted intermediate

    file_count="$(find "$dest" -type f | wc -l | tr -d ' ')"
    log_msg "Restore complete — ${file_count} file(s) restored under $dest"
    exit 0
}

# ----------------------------------------------------------------------------
# CRON HELPER + USAGE
# ----------------------------------------------------------------------------

# generate_cron_line — print a ready-to-paste cron entry (daily at 02:00).
# Input:  none (uses $0 for the absolute script path)
# Output: the cron line plus install instructions on stdout.
generate_cron_line() {
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    echo "# Add the following line via 'crontab -e' to run a backup daily at 2:00 AM:"
    echo ""
    echo "0 2 * * * ${script_path} --backup >> ${LOG_FILE} 2>&1"
    echo ""
    echo "# Notes:"
    echo "#  - Encrypted backups prompt for a passphrase; for unattended cron runs set"
    echo "#    ENCRYPTION=false, or supply the passphrase via a secured mechanism."
    echo "#  - Run 'crontab -l' to confirm the entry was added."
}

# usage — print help text and exit with code 2 (misuse).
usage() {
    cat <<EOF
backup_guard.sh — Automated Backup & Integrity Verification System

USAGE:
    $(basename "$0") <command> [argument]

COMMANDS:
    --backup                 Create a new encrypted, checksummed backup.
    --verify <file>          Verify a backup's SHA-256 integrity.
    --restore-test <file>    Decrypt + extract a backup in a sandbox (dry run).
    --restore <file> [dest]  Decrypt + extract a backup into dest (default ./restored).
    --schedule               Print a ready-to-paste cron entry for daily backups.
    --help                   Show this help text.

EXAMPLES:
    $(basename "$0") --backup
    $(basename "$0") --verify backup_2026-06-25_143000.tar.gz.enc
    $(basename "$0") --restore-test backup_2026-06-25_143000.tar.gz.enc
    $(basename "$0") --restore backup_2026-06-25_143000.tar.gz.enc ./restored
    $(basename "$0") --schedule

EXIT CODES:
    0 success · 1 general failure · 2 misuse / bad arguments

Config (BACKUP_DIR, SOURCE_DIRS, RETENTION_COUNT, etc.) lives at the top of the script.
EOF
    exit 2
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

# main — parse CLI arguments and dispatch to the right workflow.
# Input:  the script's positional arguments ("$@")
# Output: depends on the command; exit codes propagate from the called function.
main() {
    local command="${1:-}"

    case "$command" in
        --backup)
            check_deps
            validate_source_dirs
            check_disk_space
            do_backup
            ;;
        --verify)
            if [[ $# -lt 2 ]]; then
                log_error "--verify requires a backup filename argument."
                usage
            fi
            check_deps
            verify_backup "$2"
            ;;
        --restore-test)
            if [[ $# -lt 2 ]]; then
                log_error "--restore-test requires a backup filename argument."
                usage
            fi
            check_deps
            restore_test "$2"
            ;;
        --restore)
            if [[ $# -lt 2 ]]; then
                log_error "--restore requires a backup filename argument."
                usage
            fi
            check_deps
            restore_backup "$2" "${3:-}"
            ;;
        --schedule)
            generate_cron_line
            ;;
        --help|"")
            usage
            ;;
        *)
            log_error "Unknown argument: $command"
            usage
            ;;
    esac
}

main "$@"
