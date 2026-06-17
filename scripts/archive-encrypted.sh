#!/usr/bin/env bash
# Create a gzip-compressed, AES-256 encrypted archive of payment-hub-v6.
# The archive includes the payment-hub-v6/ folder itself.
#
# Usage:
#   ./scripts/archive-encrypted.sh [output-file]              # encrypt (default)
#   ./scripts/archive-encrypted.sh encrypt [output-file]
#   ./scripts/archive-encrypted.sh decrypt <file.gpg> [dest]
#   ./scripts/archive-encrypted.sh upload <file.gpg>
#
# Password: set ARCHIVE_PASSWORD for encrypt/decrypt, or you will be prompted.
# Upload does not require a passphrase (file is already encrypted).
#
# Examples:
#   ./scripts/archive-encrypted.sh
#   ./scripts/archive-encrypted.sh /tmp/payment-hub-v6-backup.tar.gz.gpg
#   ARCHIVE_PASSWORD='secret' ./scripts/archive-encrypted.sh encrypt
#   ./scripts/archive-encrypted.sh decrypt backup.tar.gz.gpg /tmp/restore
#   ./scripts/archive-encrypted.sh upload backup.tar.gz.gpg

set -euo pipefail

timestamp_now() {
  date +%Y%m%d-%H%M%S
}

human_size() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1} bytes"
}

file_size() {
  local path="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f%z "$path"
  else
    stat -c%s "$path"
  fi
}

log_step() {
  echo "→ $*"
}

check_deps() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: required commands not found: ${missing[*]}" >&2
    exit 1
  fi
}

# Exclusion patterns (fnmatch on path components; see tar --exclude).
EXCLUDES=(
  --exclude='*.log'
  --exclude='journal*.log'
  --exclude='log'
  --exclude='logs'
  --exclude='*.db'
  --exclude='*.sqlite'
  --exclude='*.sqlite3'
  --exclude='db'
  --exclude='*.bak'
  --exclude='*.bak.*'
  --exclude='*backup*'
  --exclude='*.backup*'
  --exclude='db.bak*'
  --exclude='db_backup'
  --exclude='log_backup'
  --exclude='*.gz'
  --exclude='*.zip'
  --exclude='*.tar'
  --exclude='*.tgz'
  --exclude='node_modules'
  --exclude='__pycache__'
  --exclude='*.pyc'
  --exclude='.venv'
  --exclude='venv'
  --exclude='bin'
  --exclude='obj'
  --exclude='.vs'
)

GPG_CIPHER_ARGS=(
  --symmetric
  --cipher-algo AES256
  --compress-algo none
  --s2k-mode 3
  --s2k-digest-algo SHA512
  --s2k-count 65011712
  --batch
  --yes
  --pinentry-mode loopback
)

run_encrypt_pipeline() {
  local -a gpg_args=("$@")
  local file_count source_bytes start_ts elapsed

  file_count="$(find "$PROJECT_NAME" -type f 2>/dev/null | wc -l | tr -d ' ')"
  source_bytes="$(du -sb "$PROJECT_NAME" 2>/dev/null | cut -f1 || echo 0)"

  echo "Source:    ${file_count} files, ~$(human_size "$source_bytes") on disk (before exclusions)"
  echo

  start_ts=$(date +%s)
  log_step "Packing, compressing, and encrypting..."

  if command -v pv >/dev/null 2>&1; then
    # Stream size is unknown after exclusions/compression; show throughput and elapsed time.
    tar -czf - "${EXCLUDES[@]}" "$PROJECT_NAME" \
      | pv -ptebar -N "archive" \
      | gpg "${gpg_args[@]}"
  else
    echo "  (install pv for a live progress bar)"
    tar -czf - "${EXCLUDES[@]}" "$PROJECT_NAME" | gpg "${gpg_args[@]}"
  fi

  elapsed=$(( $(date +%s) - start_ts ))
  echo
  log_step "Finished in ${elapsed}s"
}

do_encrypt() {
  check_deps gpg tar

  local SCRIPT_DIR PROJECT_DIR PROJECT_NAME PARENT_DIR OUTPUT_ARG OUTPUT_FILE
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  PROJECT_NAME="$(basename "$PROJECT_DIR")"
  PARENT_DIR="$(dirname "$PROJECT_DIR")"
  OUTPUT_ARG="${1:-}"

  if [[ -n "$OUTPUT_ARG" ]]; then
    OUTPUT_FILE="$OUTPUT_ARG"
  else
    OUTPUT_FILE="${PARENT_DIR}/${PROJECT_NAME}-$(timestamp_now).tar.gz.gpg"
  fi

  if [[ -e "$OUTPUT_FILE" ]]; then
    echo "Error: output file already exists: $OUTPUT_FILE" >&2
    exit 1
  fi

  echo "Archiving: ${PROJECT_DIR}"
  echo "Output:    ${OUTPUT_FILE}"
  echo "Excluding: logs, databases, backups, archives, build artifacts"
  echo

  cd "$PARENT_DIR"

  local gpg_args pass1 pass2
  gpg_args=("${GPG_CIPHER_ARGS[@]}" --output "$OUTPUT_FILE")

  if [[ -n "${ARCHIVE_PASSWORD:-}" ]]; then
    gpg_args+=(--passphrase "$ARCHIVE_PASSWORD")
    run_encrypt_pipeline "${gpg_args[@]}"
  else
    echo "Enter encryption passphrase (input visible):"
    read -r -p "> " pass1
    echo
    read -r -p "Confirm passphrase: " pass2
    echo
    if [[ "$pass1" != "$pass2" ]]; then
      echo "Error: passphrases do not match." >&2
      exit 1
    fi
    if [[ -z "$pass1" ]]; then
      echo "Error: passphrase cannot be empty." >&2
      exit 1
    fi
    gpg_args+=(--passphrase "$pass1")
    run_encrypt_pipeline "${gpg_args[@]}"
    unset pass1 pass2
  fi

  echo
  echo "Done: $OUTPUT_FILE ($(human_size "$(file_size "$OUTPUT_FILE")"))"
  ls -lh "$OUTPUT_FILE"
}

do_decrypt() {
  check_deps gpg tar

  local INPUT_FILE DEST_DIR PASSPHRASE
  INPUT_FILE="${1:?Usage: archive-encrypted.sh decrypt <file.gpg> [destination]}"
  DEST_DIR="${2:-.}"

  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: file not found: $INPUT_FILE" >&2
    exit 1
  fi

  mkdir -p "$DEST_DIR"

  echo "Decrypting: ${INPUT_FILE}"
  echo "Output:     ${DEST_DIR}"
  echo

  if [[ -n "${ARCHIVE_PASSWORD:-}" ]]; then
    PASSPHRASE="$ARCHIVE_PASSWORD"
  else
    echo "Enter decryption passphrase:"
    read -r -p "> " PASSPHRASE
    echo
  fi

  if gpg --batch --yes --pinentry-mode loopback --passphrase "$PASSPHRASE" \
    -d "$INPUT_FILE" | tar -xzf - -C "$DEST_DIR"; then
    echo
    echo "Done: $DEST_DIR"
    ls -lh "$DEST_DIR"
  else
    echo "Error: decryption failed. Wrong passphrase?" >&2
    exit 1
  fi
}

do_upload() {
  local INPUT_FILE
  INPUT_FILE="${1:?Usage: archive-encrypted.sh upload <file.gpg>}"

  check_deps curl python3

  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: file not found: $INPUT_FILE" >&2
    exit 1
  fi

  local FILE_SIZE
  FILE_SIZE="$(file_size "$INPUT_FILE")"

  echo "Uploading: ${INPUT_FILE}"
  echo "Size:      $(human_size "$FILE_SIZE")"
  echo "Target:    GoFile"
  echo

  local upload_start_ts upload_elapsed resp_file
  upload_start_ts=$(date +%s)

  log_step "[1/4] Creating GoFile guest session..."
  local ACCOUNT_RESP STATUS ACCOUNT_TOKEN ROOT_FOLDER
  ACCOUNT_RESP=$(curl -sS -X POST "https://api.gofile.io/accounts")
  STATUS=$(echo "$ACCOUNT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)

  if [[ "$STATUS" != "ok" ]]; then
    echo "Error: failed to create GoFile guest account" >&2
    echo "$ACCOUNT_RESP" >&2
    exit 1
  fi

  ACCOUNT_TOKEN=$(echo "$ACCOUNT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")
  ROOT_FOLDER=$(echo "$ACCOUNT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['rootFolder'])")

  log_step "[2/4] Creating upload folder..."
  local FOLDER_RESP FOLDER_ID
  FOLDER_RESP=$(curl -sS -X POST "https://api.gofile.io/contents/createFolder" \
    -H "Authorization: Bearer ${ACCOUNT_TOKEN}" \
    -d "parentFolderId=${ROOT_FOLDER}" \
    -d "folderName=backup-$(timestamp_now)")

  FOLDER_ID=$(echo "$FOLDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)

  if [[ -z "$FOLDER_ID" ]]; then
    echo "Warning: could not create named folder, using root folder" >&2
    FOLDER_ID="$ROOT_FOLDER"
  fi

  log_step "[3/4] Finding upload server..."
  local SERVER_RESP SERVER_HOST
  SERVER_RESP=$(curl -sS "https://api.gofile.io/servers")
  SERVER_HOST=$(echo "$SERVER_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
servers = d.get('data', {}).get('servers', [])
if servers:
    print(servers[0].get('name', 'store1'))
else:
    print('store1')
" 2>/dev/null)

  if [[ -z "$SERVER_HOST" ]]; then
    SERVER_HOST="store1"
  fi

  log_step "[4/4] Uploading to ${SERVER_HOST}.gofile.io ($(human_size "$FILE_SIZE"))..."
  echo
  local UPLOAD_RESP UPLOAD_STATUS DOWNLOAD_PAGE FILE_NAME FILE_MD5
  resp_file="$(mktemp)"
  trap 'rm -f "$resp_file"' RETURN
  curl --fail --progress-bar -X POST "https://${SERVER_HOST}.gofile.io/contents/uploadfile" \
    -F "token=${ACCOUNT_TOKEN}" \
    -F "folderId=${FOLDER_ID}" \
    -F "file=@${INPUT_FILE}" \
    -o "$resp_file"
  echo
  UPLOAD_RESP="$(cat "$resp_file")"
  rm -f "$resp_file"
  trap - RETURN

  UPLOAD_STATUS=$(echo "$UPLOAD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)

  if [[ "$UPLOAD_STATUS" != "ok" ]]; then
    echo "Error: upload failed" >&2
    echo "$UPLOAD_RESP" >&2
    exit 1
  fi

  DOWNLOAD_PAGE=$(echo "$UPLOAD_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(d.get('downloadPage', ''))
" 2>/dev/null)

  FILE_NAME=$(echo "$UPLOAD_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(d.get('name', ''))
" 2>/dev/null)

  FILE_MD5=$(echo "$UPLOAD_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(d.get('md5', ''))
" 2>/dev/null)

  upload_elapsed=$(( $(date +%s) - upload_start_ts ))
  echo
  echo "Upload complete! (${upload_elapsed}s total)"
  echo "  Download page: ${DOWNLOAD_PAGE}"
  echo "  File:          ${FILE_NAME}"
  echo "  Size:          $(human_size "$FILE_SIZE")"
  echo "  MD5:           ${FILE_MD5}"
  echo
  echo "  Save these credentials to manage/delete the file:"
  echo "  accountToken:  ${ACCOUNT_TOKEN}"
  echo "  folderId:      ${FOLDER_ID}"
}

show_help() {
  echo "Usage: archive-encrypted.sh [mode] [options]"
  echo
  echo "Modes:"
  echo "  encrypt [output-file]    Create encrypted archive (default)"
  echo "  decrypt <file.gpg> [dst] Decrypt and extract archive"
  echo "  upload <file.gpg>        Upload encrypted file to GoFile (no passphrase)"
  echo
  echo "Environment:"
  echo "  ARCHIVE_PASSWORD         Passphrase for encrypt/decrypt"
  echo
  echo "Examples:"
  echo "  ./scripts/archive-encrypted.sh"
  echo "  ./scripts/archive-encrypted.sh /tmp/backup.tar.gz.gpg"
  echo "  ./scripts/archive-encrypted.sh upload backup.tar.gz.gpg"
}

if [[ $# -eq 0 ]]; then
  MODE=encrypt
elif [[ "$1" =~ ^(encrypt|e|decrypt|d|upload|u|help|--help|-h)$ ]]; then
  MODE="$1"
  shift
else
  MODE=encrypt
fi

case "$MODE" in
  encrypt|e)
    do_encrypt "$@"
    ;;
  decrypt|d)
    do_decrypt "$@"
    ;;
  upload|u)
    do_upload "$@"
    ;;
  help|--help|-h)
    show_help
    ;;
  *)
    echo "Error: unknown mode '${MODE}'. Use: encrypt, decrypt, upload, or help" >&2
    exit 1
    ;;
esac
