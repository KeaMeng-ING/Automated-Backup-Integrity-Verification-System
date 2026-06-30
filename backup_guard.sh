#!/bin/bash
#
# backup_guard.sh — Automated Backup & Integrity Verification System
# CYBR 352 University Project
#

set -euo pipefail

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
SOURCE_DIRS=("$SCRIPT_DIR/test_data")
RETENTION_COUNT=3
LOG_FILE="$SCRIPT_DIR/backup_guard.log"

# --- LOGGING SYSTEM ---
log() {
    local type="$1"; shift
    printf "%s [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$type" "$*" | tee -a "$LOG_FILE"
}

# --- PRE-FLIGHT CHECKS ---
check_env() {
    local missing=()
    for tool in tar gzip openssl sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log "ERROR" "Missing system tools: ${missing[*]}"
        exit 1
    fi

    # Verify source data exists
    if [ ! -d "${SOURCE_DIRS[0]}" ]; then
        log "ERROR" "Source directory folder '${SOURCE_DIRS[0]}' not found. Create it first."
        exit 1
    fi

    # Quick disk space validation (Requires at least 10MB free for safety)
    local free_space
    free_space=$(df -m "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 10 ]; then
        log "ERROR" "Low disk space. Execution halted."
        exit 2
    fi
}

# --- CORE FUNCTIONS ---
do_backup() {
    mkdir -p "$BACKUP_DIR"
    local ts; ts="$(date '+%Y-%m-%d_%H%M%S')"
    local target="${BACKUP_DIR}/backup_${ts}.tar.gz.enc"
    local tmp_tar="${BACKUP_DIR}/tmp_${ts}.tar.gz"

    log "INFO" "Archiving source folders..."
    tar -czf "$tmp_tar" -C "$(dirname "${SOURCE_DIRS[0]}")" "$(basename "${SOURCE_DIRS[0]}")"

    # Secure interactive password handling
    echo -n "Set a strong encryption passphrase: "
    read -r -s passwd
    echo

    if ! printf "%s" "$passwd" | openssl enc -aes-256-cbc -pbkdf2 -salt -in "$tmp_tar" -out "$target" -pass stdin 2>/dev/null; then
        log "ERROR" "Encryption failed."
        rm -f "$tmp_tar" "$target"
        exit 1
    fi
    rm -f "$tmp_tar"

    # Generate integrity fingerprint
    (cd "$BACKUP_DIR" && sha256sum "$(basename "$target")" > "$(basename "$target").sha256")
    log "INFO" "Backup created and fingerprinted successfully: $(basename "$target")"

    # Housekeeping: Rotate old records
    local old_backups
    old_backups=$(ls -1tr "$BACKUP_DIR"/backup_*.tar.gz.enc 2>/dev/null || true)
    if [ "$(echo "$old_backups" | wc -l)" -gt "$RETENTION_COUNT" ]; then
        local to_remove; to_remove=$(echo "$old_backups" | head -n 1)
        rm -f "$to_remove" "${to_remove}.sha256"
        log "INFO" "Rotated out old backup file: $(basename "$to_remove")"
    fi
}

verify_backup() {
    local file="$1"
    [ -f "$file" ] || file="${BACKUP_DIR}/$file"
    
    if [ ! -f "$file" ] || [ ! -f "${file}.sha256" ]; then
        log "ERROR" "Target backup file or its tracking .sha256 fingerprint missing."
        exit 1
    fi

    log "INFO" "Validating file signatures..."
    if (cd "$(dirname "$file")" && sha256sum --status -c "$(basename "$file").sha256"); then
        log "INFO" "INTEGRITY PASSED: Backup file matches original fingerprint perfectly."
    else
        log "ERROR" "INTEGRITY CRITICAL CORRUPTION: Signatures do not match!"
        exit 1
    fi
}

restore_sandbox() {
    local file="$1"
    [ -f "$file" ] || file="${BACKUP_DIR}/$file"
    
    local sandbox; sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"; log "INFO" "Sandbox clean up complete."' EXIT

    echo -n "Enter decryption passphrase: "
    read -r -s passwd; echo

    if ! printf "%s" "$passwd" | openssl enc -d -aes-256-cbc -pbkdf2 -in "$file" -out "$sandbox/test.tar.gz" -pass stdin 2>/dev/null; then
        log "ERROR" "Decryption simulation failed. Incorrect password or broken file data."
        exit 1
    fi

    tar -xzf "$sandbox/test.tar.gz" -C "$sandbox"
    local count; count=$(find "$sandbox" -type f ! -name "test.tar.gz" | wc -l)
    
    log "INFO" "DRY-RUN SUCCESS: Successfully decrypted and verified $count files inside isolation sandbox."
}

restore_live() {
    local file="$1" dest="${2:-$SCRIPT_DIR/restored}"
    [ -f "$file" ] || file="${BACKUP_DIR}/$file"

    mkdir -p "$dest"
    echo -n "Enter decryption passphrase: "
    read -r -s passwd; echo

    if ! printf "%s" "$passwd" | openssl enc -d -aes-256-cbc -pbkdf2 -in "$file" -pass stdin 2>/dev/null | tar -xzf - -C "$dest"; then
        log "ERROR" "Live system restoration broke down. Check your password."
        exit 1
    fi

    log "INFO" "SUCCESS: Data fully restored to path: $dest"
}

usage() {
    cat << EOF
Usage: $0 [COMMAND] [FILE]
Commands:
  --backup                 Build an encrypted, timestamped archive
  --verify <file>          Run cryptographic signature check
  --restore-test <file>    Simulate restoration in a temporary sandbox
  --restore <file> [dest]  Extract backup files directly to production path
EOF
    exit 2
}

# --- CONTROL HUB ---
main() {
    local cmd="${1:-}"
    case "$cmd" in
        --backup) check_env; do_backup ;;
        --verify) [ $# -eq 2 ] || usage; check_env; verify_backup "$2" ;;
        --restore-test) [ $# -eq 2 ] || usage; check_env; restore_sandbox "$2" ;;
        --restore) [ $# -ge 2 ] || usage; check_env; restore_live "$2" "${3:-}" ;;
        *) usage ;;
    esac
}

main "$@"
