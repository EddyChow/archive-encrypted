#!/usr/bin/env bash
# Create a gzip-compressed, AES-256 encrypted archive of a project folder.
# The archive includes the folder itself (preserves folder name inside tarball).
#
# Usage:
#   ./scripts/archive-encrypted.sh [output-file]
#
# Password: set ARCHIVE_PASSWORD, or you will be prompted twice by gpg.
#
# Examples:
#   ./scripts/archive-encrypted.sh
#   ./scripts/archive-encrypted.sh /tmp/my-backup.tar.gz.gpg
#   ARCHIVE_PASSWORD='secret' ./scripts/archive-encrypted.sh
#
# Decrypt:
#   gpg -d backup.tar.gz.gpg | tar -xzf - -C /destination/parent/dir

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
PARENT_DIR="$(dirname "$PROJECT_DIR")"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DEFAULT_OUTPUT="${PARENT_DIR}/${PROJECT_NAME}-${TIMESTAMP}.tar.gz.gpg"
OUTPUT_FILE="${1:-$DEFAULT_OUTPUT}"

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

if ! command -v gpg >/dev/null 2>&1; then
  echo "Error: gpg is required but not installed." >&2
  exit 1
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

# GPG encryption parameters (AES-256, SHA-512, high iteration count)
gpg_args=(
  --symmetric
  --cipher-algo AES256
  --compress-algo none
  --s2k-mode 3
  --s2k-digest-algo SHA512
  --s2k-count 65011712
  --batch
  --yes
  --pinentry-mode loopback
  --output "$OUTPUT_FILE"
)

if [[ -n "${ARCHIVE_PASSWORD:-}" ]]; then
  # Non-interactive: password from environment variable
  gpg_args+=(--passphrase "$ARCHIVE_PASSWORD")
  tar -czf - "${EXCLUDES[@]}" "$PROJECT_NAME" | gpg "${gpg_args[@]}"
else
  # Interactive: prompt user for passphrase
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

  # FIX: Use --passphrase directly instead of --passphrase-fd 0 via pipe.
  # The original script had: printf '%s' "$pass1" | tar -czf - ... | gpg --passphrase-fd 0
  # This was broken because gpg's stdin (fd 0) was connected to tar's binary output,
  # NOT to printf's passphrase. The passphrase never reached gpg.
  gpg_args+=(--passphrase "$pass1")
  tar -czf - "${EXCLUDES[@]}" "$PROJECT_NAME" | gpg "${gpg_args[@]}"
  unset pass1 pass2
fi

echo
echo "Done: $OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"
