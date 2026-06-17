#!/usr/bin/env bash
# Create a gzip-compressed, AES-256 encrypted archive of payment-hub-v6.
# The archive includes the payment-hub-v6/ folder itself.
#
# Usage:
#   ./scripts/archive-encrypted.sh help
#   ./scripts/archive-encrypted.sh encrypt [output-file]      # default action
#   ./scripts/archive-encrypted.sh decrypt <file.gpg> [dest]
#   ./scripts/archive-encrypted.sh upload [file.gpg]          # encrypt+upload if no file
#   ./scripts/archive-encrypted.sh download <gofile-url-or-code> [output-file]
#
# Password: set ARCHIVE_PASSWORD for encrypt/decrypt, or you will be prompted.
# Upload does not require a passphrase (file is already encrypted).
# Download: set GOFILE_TOKEN to the guest accountToken printed at upload time.
#
# Examples:
#   ./scripts/archive-encrypted.sh
#   ./scripts/archive-encrypted.sh /tmp/payment-hub-v6-backup.tar.gz.gpg
#   ARCHIVE_PASSWORD='secret' ./scripts/archive-encrypted.sh encrypt
#   ./scripts/archive-encrypted.sh decrypt backup.tar.gz.gpg /tmp/restore
#   ./scripts/archive-encrypted.sh upload backup.tar.gz.gpg
#   GOFILE_TOKEN='...' ./scripts/archive-encrypted.sh download https://gofile.io/d/abc123 backup.tar.gz.gpg

set -euo pipefail

GOFILE_WEBSITE_TOKEN="${GOFILE_WEBSITE_TOKEN:-4fd6sg89d7s6}"
ENCRYPT_OUTPUT_FILE=""
GOFILE_UPLOAD_HOST_USED=""
GOFILE_UPLOAD_HOSTS=(
  upload-na-phx.gofile.io
  upload-eu-par.gofile.io
  upload-ap-sgp.gofile.io
  upload-ap-hkg.gofile.io
  upload-ap-tyo.gofile.io
  upload-sa-sao.gofile.io
  upload.gofile.io
)

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

init_project_paths() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  PROJECT_NAME="$(basename "$PROJECT_DIR")"
  PARENT_DIR="$(dirname "$PROJECT_DIR")"
}

encrypt_project() {
  local OUTPUT_ARG="${1:-}"
  local OUTPUT_FILE gpg_args pass1 pass2

  check_deps gpg tar
  init_project_paths

  if [[ -n "$OUTPUT_ARG" ]]; then
    OUTPUT_FILE="$OUTPUT_ARG"
  else
    OUTPUT_FILE="${PARENT_DIR}/${PROJECT_NAME}-$(timestamp_now).tar.gz.gpg"
  fi

  if [[ -e "$OUTPUT_FILE" ]]; then
    echo "Error: output file already exists: $OUTPUT_FILE" >&2
    return 1
  fi

  echo "Archiving: ${PROJECT_DIR}"
  echo "Output:    ${OUTPUT_FILE}"
  echo "Excluding: logs, databases, backups, archives, build artifacts"
  echo

  cd "$PARENT_DIR"

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
      return 1
    fi
    if [[ -z "$pass1" ]]; then
      echo "Error: passphrase cannot be empty." >&2
      return 1
    fi
    gpg_args+=(--passphrase "$pass1")
    run_encrypt_pipeline "${gpg_args[@]}"
    unset pass1 pass2
  fi

  ENCRYPT_OUTPUT_FILE="$OUTPUT_FILE"
}

do_encrypt() {
  encrypt_project "${1:-}"

  echo
  echo "Done: $ENCRYPT_OUTPUT_FILE ($(human_size "$(file_size "$ENCRYPT_OUTPUT_FILE")"))"
  ls -lh "$ENCRYPT_OUTPUT_FILE"
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

gofile_extract_code() {
  local url="$1"
  if [[ "$url" =~ ^https?:// ]]; then
    basename "${url%/}"
  else
    echo "$url"
  fi
}

gofile_pick_upload_host() {
  local host

  if [[ -n "${GOFILE_UPLOAD_HOST:-}" ]]; then
    echo "$GOFILE_UPLOAD_HOST"
    return 0
  fi

  log_step "Finding reachable GoFile upload endpoint..."
  for host in "${GOFILE_UPLOAD_HOSTS[@]}"; do
    if curl -sS --connect-timeout 8 --max-time 15 -o /dev/null "https://${host}/" 2>/dev/null; then
      echo "$host"
      return 0
    fi
    echo "  skipped (unreachable): ${host}" >&2
  done

  echo "Error: no GoFile upload endpoint is reachable from this host." >&2
  echo "Set GOFILE_UPLOAD_HOST to force one, e.g. upload-na-phx.gofile.io" >&2
  return 1
}

gofile_upload_file() {
  local input_file="$1" resp_file="$2"
  local host hosts=()

  if [[ -n "${GOFILE_UPLOAD_HOST:-}" ]]; then
    hosts=("$GOFILE_UPLOAD_HOST")
  else
    hosts=("${GOFILE_UPLOAD_HOSTS[@]}")
  fi

  for host in "${hosts[@]}"; do
    log_step "Uploading via ${host}..."
    if curl --fail --progress-bar --connect-timeout 30 --max-time 0 \
      -X POST "https://${host}/uploadfile" \
      -F "file=@${input_file}" \
      -o "$resp_file"; then
      GOFILE_UPLOAD_HOST_USED="$host"
      return 0
    fi
    echo "  upload failed on ${host}, trying next endpoint..." >&2
  done

  echo "Error: upload failed on all GoFile endpoints." >&2
  return 1
}

gofile_download_file() {
  local content_code="$1" guest_token="$2" output_file="$3"
  check_deps curl python3

  log_step "Fetching download link from GoFile..."
  python3 - "$content_code" "$guest_token" "$output_file" "$GOFILE_WEBSITE_TOKEN" <<'PY'
import json
import sys
import urllib.error
import urllib.request

content_code, guest_token, output_file, website_token = sys.argv[1:5]
url = (
    f"https://api.gofile.io/contents/{content_code}"
    f"?wt={website_token}&cache=true"
)
req = urllib.request.Request(
    url,
    headers={
        "Authorization": f"Bearer {guest_token}",
        "X-Website-Token": website_token,
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (compatible; archive-encrypted.sh)",
    },
)
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = json.load(resp)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(f"Error: GoFile API HTTP {exc.code}: {body}", file=sys.stderr)
    sys.exit(1)

status = payload.get("status")
if status != "ok":
    print(f"Error: GoFile API returned {status!r}", file=sys.stderr)
    if status == "error-notPremium":
        print(
            "GoFile now restricts content listing to premium accounts.\n"
            "Open the download page in a browser, or re-upload with the latest script\n"
            "and use GOFILE_TOKEN from that upload output.",
            file=sys.stderr,
        )
    elif status == "error-rateLimit":
        print("GoFile rate-limited this IP. Wait a few minutes and retry.", file=sys.stderr)
    sys.exit(1)

data = payload.get("data") or {}
children = data.get("children") or {}

if data.get("type") == "file":
    files = [data]
elif children:
    files = list(children.values())
else:
    print("Error: no files found at that GoFile link.", file=sys.stderr)
    sys.exit(1)

if len(files) != 1:
    names = ", ".join(f.get("name", "?") for f in files)
    print(f"Error: expected one file, found {len(files)}: {names}", file=sys.stderr)
    sys.exit(1)

file_info = files[0]
link = file_info.get("link")
if not link:
    print("Error: GoFile did not return a direct download link.", file=sys.stderr)
    sys.exit(1)

print(file_info.get("name", "download"))
print(file_info.get("md5", ""))
print(link)
print(output_file)
PY
}

do_download() {
  local INPUT_URL="${1:?Usage: archive-encrypted.sh download <gofile-url-or-code> [output-file]}"
  local OUTPUT_FILE="${2:-}"
  local CONTENT_CODE GUEST_TOKEN META_FILE FILE_NAME EXPECTED_MD5 DOWNLOAD_URL

  CONTENT_CODE="$(gofile_extract_code "$INPUT_URL")"
  GUEST_TOKEN="${GOFILE_TOKEN:-}"

  if [[ -z "$GUEST_TOKEN" ]]; then
    echo "Error: GOFILE_TOKEN is required (use the accountToken printed during upload)." >&2
    exit 1
  fi

  if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$(mktemp --suffix=.gpg)"
    echo "No output path given; writing to ${OUTPUT_FILE}"
  fi

  echo "Downloading from GoFile"
  echo "  Code:   ${CONTENT_CODE}"
  echo "  Output: ${OUTPUT_FILE}"
  echo

  META_FILE="$(mktemp)"
  trap 'rm -f "$META_FILE"' RETURN
  if ! gofile_download_file "$CONTENT_CODE" "$GUEST_TOKEN" "$OUTPUT_FILE" >"$META_FILE"; then
    rm -f "$META_FILE"
    trap - RETURN
    exit 1
  fi

  FILE_NAME="$(sed -n '1p' "$META_FILE")"
  EXPECTED_MD5="$(sed -n '2p' "$META_FILE")"
  DOWNLOAD_URL="$(sed -n '3p' "$META_FILE")"
  rm -f "$META_FILE"
  trap - RETURN

  log_step "Downloading ${FILE_NAME}..."
  echo
  curl --fail --progress-bar -L "$DOWNLOAD_URL" -o "$OUTPUT_FILE"
  echo

  if [[ -n "$EXPECTED_MD5" ]]; then
    local ACTUAL_MD5
    ACTUAL_MD5="$(md5sum "$OUTPUT_FILE" | awk '{print $1}')"
    if [[ "$ACTUAL_MD5" != "$EXPECTED_MD5" ]]; then
      echo "Error: MD5 mismatch (expected ${EXPECTED_MD5}, got ${ACTUAL_MD5})" >&2
      exit 1
    fi
    log_step "MD5 verified: ${ACTUAL_MD5}"
  fi

  echo
  echo "Done: ${OUTPUT_FILE} ($(human_size "$(file_size "$OUTPUT_FILE")"))"
  ls -lh "$OUTPUT_FILE"
}

do_upload() {
  local INPUT_FILE="${1:-}"

  if [[ -z "$INPUT_FILE" ]]; then
    echo "No file given — encrypting project first, then uploading."
    echo
    encrypt_project ""
    INPUT_FILE="$ENCRYPT_OUTPUT_FILE"
    echo
    echo "Encrypted: ${INPUT_FILE} ($(human_size "$(file_size "$INPUT_FILE")"))"
    echo
  elif [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: file not found: $INPUT_FILE" >&2
    exit 1
  fi

  check_deps curl python3

  local FILE_SIZE
  FILE_SIZE="$(file_size "$INPUT_FILE")"

  echo "Uploading: ${INPUT_FILE}"
  echo "Size:      $(human_size "$FILE_SIZE")"
  echo "Target:    GoFile"
  echo

  local upload_start_ts upload_elapsed resp_file upload_host
  upload_start_ts=$(date +%s)

  upload_host="$(gofile_pick_upload_host)"
  echo "Endpoint:  ${upload_host}"
  echo

  log_step "[1/2] Uploading file..."
  echo
  resp_file="$(mktemp)"
  trap 'rm -f "$resp_file"' RETURN
  GOFILE_UPLOAD_HOST_USED=""
  if ! gofile_upload_file "$INPUT_FILE" "$resp_file"; then
    rm -f "$resp_file"
    trap - RETURN
    exit 1
  fi
  echo
  local UPLOAD_RESP
  UPLOAD_RESP="$(cat "$resp_file")"
  rm -f "$resp_file"
  trap - RETURN

  local UPLOAD_STATUS DOWNLOAD_PAGE FILE_NAME FILE_MD5 GUEST_TOKEN CONTENT_CODE VERIFY_FILE
  UPLOAD_STATUS=$(echo "$UPLOAD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)

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

  GUEST_TOKEN=$(echo "$UPLOAD_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(d.get('guestToken', ''))
" 2>/dev/null)

  CONTENT_CODE=$(echo "$UPLOAD_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(d.get('parentFolderCode', ''))
" 2>/dev/null)

  log_step "[2/2] Verifying download link..."
  VERIFY_FILE="$(mktemp)"
  if gofile_download_file "$CONTENT_CODE" "$GUEST_TOKEN" "$VERIFY_FILE" >"$VERIFY_FILE.meta" 2>/dev/null; then
    rm -f "$VERIFY_FILE" "$VERIFY_FILE.meta"
    log_step "Download link verified"
  else
    rm -f "$VERIFY_FILE" "$VERIFY_FILE.meta" 2>/dev/null || true
    echo "Warning: could not verify download link via API (GoFile may require browser download)." >&2
  fi

  upload_elapsed=$(( $(date +%s) - upload_start_ts ))
  echo
  echo "Upload complete! (${upload_elapsed}s total)"
  echo "  Endpoint:      ${GOFILE_UPLOAD_HOST_USED:-$upload_host}"
  echo "  Download page: ${DOWNLOAD_PAGE}"
  echo "  File:          ${FILE_NAME}"
  echo "  Size:          $(human_size "$FILE_SIZE")"
  echo "  MD5:           ${FILE_MD5}"
  echo
  echo "  Save these to download later from CLI:"
  echo "  GOFILE_TOKEN=${GUEST_TOKEN}"
  echo "  contentCode:   ${CONTENT_CODE}"
  echo
  echo "  Download command:"
  echo "    GOFILE_TOKEN='${GUEST_TOKEN}' ./scripts/archive-encrypted.sh download ${DOWNLOAD_PAGE} ./${FILE_NAME}"
}

show_help() {
  echo "archive-encrypted.sh — encrypt, decrypt, upload, and download project archives"
  echo
  echo "Usage: archive-encrypted.sh <mode> [options]"
  echo
  echo "Modes:"
  echo "  encrypt [output-file]    Create encrypted archive"
  echo "  decrypt <file.gpg> [dst] Decrypt and extract archive"
  echo "  upload [file.gpg]        Upload to GoFile (encrypt first if no file)"
  echo "  download <url> [out]     Download from GoFile (needs GOFILE_TOKEN)"
  echo "  help                     Show this help"
  echo
  echo "Environment:"
  echo "  ARCHIVE_PASSWORD         Passphrase for encrypt/decrypt"
  echo "  GOFILE_TOKEN             Guest token from upload output (for download)"
  echo "  GOFILE_UPLOAD_HOST       Force upload endpoint (e.g. upload-na-phx.gofile.io)"
  echo
  echo "Examples:"
  echo "  ./scripts/archive-encrypted.sh encrypt"
  echo "  ./scripts/archive-encrypted.sh encrypt /tmp/backup.tar.gz.gpg"
  echo "  ./scripts/archive-encrypted.sh decrypt backup.tar.gz.gpg /tmp/restore"
  echo "  ./scripts/archive-encrypted.sh upload"
  echo "  ./scripts/archive-encrypted.sh upload backup.tar.gz.gpg"
  echo "  GOFILE_TOKEN='...' ./scripts/archive-encrypted.sh download https://gofile.io/d/abc123 ./backup.tar.gz.gpg"
}

if [[ $# -eq 0 ]]; then
  show_help
  exit 0
elif [[ "$1" =~ ^(encrypt|e|decrypt|d|upload|u|download|dl|help|--help|-h)$ ]]; then
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
  download|dl)
    do_download "$@"
    ;;
  help|--help|-h)
    show_help
    ;;
  *)
    echo "Error: unknown mode '${MODE}'. Use: encrypt, decrypt, upload, or help" >&2
    exit 1
    ;;
esac
