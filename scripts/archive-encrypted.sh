#!/usr/bin/env bash
# archive-encrypted.sh — Encrypt, decrypt, and upload project archives.
#
# Modes:
#   ./scripts/archive-encrypted.sh encrypt [output-file]   # (default mode)
#   ./scripts/archive-encrypted.sh decrypt <file.gpg> [dest]
#   ./scripts/archive-encrypted.sh upload <file.gpg>
#
# Password: set ARCHIVE_PASSWORD, or you will be prompted.
#
# Examples:
#   ./scripts/archive-encrypted.sh                              # encrypt current project
#   ./scripts/archive-encrypted.sh encrypt                      # same as above
#   ARCHIVE_PASSWORD='secret' ./scripts/archive-encrypted.sh    # non-interactive encrypt
#   ./scripts/archive-encrypted.sh decrypt backup.tar.gz.gpg /tmp/restore
#   ./scripts/archive-encrypted.sh upload backup.tar.gz.gpg     # upload to GoFile
#
# Cross-platform: works on macOS (BSD) and Ubuntu (GNU).

set -euo pipefail

# ─── Cross-platform helpers ───────────────────────────────────────────────────

realpath_compat() {
  # macOS lacks realpath; fall back to python3 or manual resolution
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"
  else
    # Best-effort with cd + pwd
    local dir base
    dir="$(cd "$(dirname "$1")" && pwd)"
    base="$(basename "$1")"
    echo "${dir}/${base}"
  fi
}

timestamp_now() {
  # macOS date doesn't support +%N; just use seconds
  date +%Y%m%d-%H%M%S
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
    echo "Install:" >&2
    echo "  macOS:   brew install ${missing[*]}" >&2
    echo "  Ubuntu:  sudo apt install ${missing[*]}" >&2
    exit 1
  fi
}

# ─── GPG encryption parameters ────────────────────────────────────────────────

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

# ─── Exclusion patterns ──────────────────────────────────────────────────────

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

# ─── Prompt for passphrase ───────────────────────────────────────────────────

prompt_passphrase() {
  local prompt_label="${1:-Enter encryption passphrase}"
  local pass1 pass2

  echo "${prompt_label} (input visible):"
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

  PASSPHRASE="$pass1"
  unset pass1 pass2
}

get_passphrase() {
  if [[ -n "${ARCHIVE_PASSWORD:-}" ]]; then
    PASSPHRASE="$ARCHIVE_PASSWORD"
  else
    prompt_passphrase "Enter encryption passphrase"
  fi
}

get_decrypt_passphrase() {
  if [[ -n "${ARCHIVE_PASSWORD:-}" ]]; then
    PASSPHRASE="$ARCHIVE_PASSWORD"
  else
    echo "Enter decryption passphrase:"
    read -r -p "> " PASSPHRASE
    echo
  fi
}

# ─── Mode: encrypt ───────────────────────────────────────────────────────────

do_encrypt() {
  check_deps gpg tar

  local SCRIPT_DIR PROJECT_DIR PROJECT_NAME PARENT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  PROJECT_NAME="$(basename "$PROJECT_DIR")"
  PARENT_DIR="$(dirname "$PROJECT_DIR")"

  local TIMESTAMP OUTPUT_FILE
  TIMESTAMP="$(timestamp_now)"
  DEFAULT_OUTPUT="${PARENT_DIR}/${PROJECT_NAME}-${TIMESTAMP}.tar.gz.gpg"
  OUTPUT_FILE="${1:-$DEFAULT_OUTPUT}"

  if [[ -e "$OUTPUT_FILE" ]]; then
    echo "Error: output file already exists: $OUTPUT_FILE" >&2
    exit 1
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Encrypt mode"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Project:  ${PROJECT_NAME}"
  echo "  Source:   ${PROJECT_DIR}"
  echo "  Output:   ${OUTPUT_FILE}"
  echo "  Excludes: logs, databases, backups, archives, build artifacts"
  echo "  Cipher:   AES-256 / SHA-512 / s2k-count 65011712"
  echo

  get_passphrase

  cd "$PARENT_DIR"

  gpg_args=("${GPG_CIPHER_ARGS[@]}" --passphrase "$PASSPHRASE" --output "$OUTPUT_FILE")
  tar -czf - "${EXCLUDES[@]}" "$PROJECT_NAME" | gpg "${gpg_args[@]}"

  echo
  echo "✓ Encrypted: $OUTPUT_FILE"
  ls -lh "$OUTPUT_FILE"

  # Offer to upload
  echo
  read -r -p "Upload to GoFile? [y/N] " upload_choice
  if [[ "$upload_choice" =~ ^[Yy]$ ]]; then
    do_upload "$OUTPUT_FILE"
  fi
}

# ─── Mode: decrypt ───────────────────────────────────────────────────────────

do_decrypt() {
  check_deps gpg tar

  local INPUT_FILE DEST_DIR
  INPUT_FILE="${1:?Usage: archive-encrypted.sh decrypt <file.gpg> [destination]}"
  DEST_DIR="${2:-.}"

  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: file not found: $INPUT_FILE" >&2
    exit 1
  fi

  # Create destination if it doesn't exist
  mkdir -p "$DEST_DIR"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Decrypt mode"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Input:  ${INPUT_FILE}"
  echo "  Output: ${DEST_DIR}"
  echo

  get_decrypt_passphrase

  gpg --batch --yes --pinentry-mode loopback --passphrase "$PASSPHRASE" \
    -d "$INPUT_FILE" | tar -xzf - -C "$DEST_DIR"

  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo
    echo "✓ Decrypted to: $DEST_DIR"
    ls -lh "$DEST_DIR"
  else
    echo "Error: decryption failed. Wrong passphrase?" >&2
    exit 1
  fi
}

# ─── Mode: upload ────────────────────────────────────────────────────────────

do_upload() {
  local INPUT_FILE
  INPUT_FILE="${1:?Usage: archive-encrypted.sh upload <file.gpg>}"

  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: file not found: $INPUT_FILE" >&2
    exit 1
  fi

  # Determine upload tool
  if command -v curl >/dev/null 2>&1; then
    UPLOAD_CMD=curl
  else
    echo "Error: curl is required for upload. Install with: apt install curl / brew install curl" >&2
    exit 1
  fi

  local FILE_SIZE
  if [[ "$(uname -s)" == "Darwin" ]]; then
    FILE_SIZE="$(stat -f%z "$INPUT_FILE")"
  else
    FILE_SIZE="$(stat -c%s "$INPUT_FILE")"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Upload mode"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  File:   ${INPUT_FILE}"
  echo "  Size:   $(numfmt --to=iec-i --suffix=B "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes")"
  echo "  Target: GoFile (free, no account required)"
  echo

  # Step 1: Create a guest account
  echo "Creating GoFile guest session..."
  local ACCOUNT_RESP
  ACCOUNT_RESP=$(curl -sS -X POST "https://api.gofile.io/accounts")
  local STATUS
  STATUS=$(echo "$ACCOUNT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)

  if [[ "$STATUS" != "ok" ]]; then
    echo "Error: failed to create GoFile guest account" >&2
    echo "$ACCOUNT_RESP" >&2
    exit 1
  fi

  local ACCOUNT_TOKEN ROOT_FOLDER
  ACCOUNT_TOKEN=$(echo "$ACCOUNT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")
  ROOT_FOLDER=$(echo "$ACCOUNT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['rootFolder'])")

  # Step 2: Create a folder for the upload
  echo "Creating upload folder..."
  local FOLDER_RESP
  FOLDER_RESP=$(curl -sS -X POST "https://api.gofile.io/contents/createFolder" \
    -H "Authorization: Bearer ${ACCOUNT_TOKEN}" \
    -d "parentFolderId=${ROOT_FOLDER}" \
    -d "folderName=backup-$(timestamp_now)")

  local FOLDER_ID
  FOLDER_ID=$(echo "$FOLDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)

  if [[ -z "$FOLDER_ID" ]]; then
    echo "Warning: could not create named folder, using root folder" >&2
    FOLDER_ID="$ROOT_FOLDER"
  fi

  # Step 3: Get the best upload server
  echo "Finding upload server..."
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

  # Step 4: Upload the file
  echo "Uploading to ${SERVER_HOST}.gofile.io... (this may take a while for large files)"
  local UPLOAD_RESP
  UPLOAD_RESP=$(curl -sS -X POST "https://${SERVER_HOST}.gofile.io/contents/uploadfile" \
    -F "token=${ACCOUNT_TOKEN}" \
    -F "folderId=${FOLDER_ID}" \
    -F "file=@${INPUT_FILE}")

  local UPLOAD_STATUS
  UPLOAD_STATUS=$(echo "$UPLOAD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)

  if [[ "$UPLOAD_STATUS" != "ok" ]]; then
    echo "Error: upload failed" >&2
    echo "$UPLOAD_RESP" >&2
    exit 1
  fi

  # Step 5: Extract share link and file info from upload response
  # GoFile upload response has file data directly in 'data' (not nested in 'children')
  local DOWNLOAD_PAGE FILE_ID FILE_NAME FILE_MD5
  DOWNLOAD_PAGE=$(echo "$UPLOAD_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(d.get('downloadPage', ''))
" 2>/dev/null)

  FILE_ID=$(echo "$UPLOAD_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(d.get('id', ''))
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

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Upload complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  echo "  Download page: ${DOWNLOAD_PAGE}"
  echo "  File:          ${FILE_NAME}"
  echo "  Size:          $(numfmt --to=iec-i --suffix=B "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes")"
  echo "  MD5:           ${FILE_MD5}"
  echo
  echo "  ⚠️  Save these credentials to manage/delete the file:"
  echo "  accountToken:  ${ACCOUNT_TOKEN}"
  echo "  folderId:      ${FOLDER_ID}"
  echo
  echo "  Note: Guest uploads are temporary (~10 days if unused)."
  echo "        The file is GPG-encrypted — recipients need your passphrase to open it."
  echo
  echo "  To decrypt:"
  echo "    ARCHIVE_PASSWORD='...' ./scripts/archive-encrypted.sh decrypt <filename.gpg> /destination"
}

# ─── Main ────────────────────────────────────────────────────────────────────

MODE="${1:-encrypt}"
shift 2>/dev/null || true

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
    echo "Usage: archive-encrypted.sh <mode> [options]"
    echo
    echo "Modes:"
    echo "  encrypt [output-file]    Create encrypted archive (default mode)"
    echo "  decrypt <file.gpg> [dst] Decrypt and extract archive"
    echo "  upload <file.gpg>        Upload encrypted file to GoFile"
    echo
    echo "Environment:"
    echo "  ARCHIVE_PASSWORD         Set passphrase (skip interactive prompt)"
    echo
    echo "Examples:"
    echo "  ./scripts/archive-encrypted.sh encrypt"
    echo "  ARCHIVE_PASSWORD='s3cret' ./scripts/archive-encrypted.sh encrypt /tmp/backup.gpg"
    echo "  ./scripts/archive-encrypted.sh decrypt backup.tar.gz.gpg /tmp/restore"
    echo "  ./scripts/archive-encrypted.sh upload backup.tar.gz.gpg"
    ;;
  *)
    echo "Error: unknown mode '${MODE}'. Use: encrypt, decrypt, upload, or help" >&2
    exit 1
    ;;
esac
