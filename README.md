# archive-encrypted

Encrypt, decrypt, upload, and download project archives — cross-platform (macOS + Ubuntu).

## Quick Start

```bash
# Create venv and install dependencies
python3 -m venv .venv
source .venv/bin/activate          # macOS/Linux
pip install -r requirements.txt
playwright install chromium

# Encrypt current project
python3 scripts/archive_encrypted.py encrypt -o /tmp/backup.tar.gz.gpg

# Decrypt
python3 scripts/archive_encrypted.py decrypt /tmp/backup.tar.gz.gpg -d /tmp/restore

# Upload to GoFile
python3 scripts/archive_encrypted.py upload /tmp/backup.tar.gz.gpg

# Download from GoFile (Playwright browser automation)
python3 scripts/archive_encrypted.py download https://gofile.io/d/abc123 -o /tmp/backup.tar.gz.gpg
```

## Features

- **AES-256 symmetric encryption** with SHA-512 key derivation and high iteration count (65011712)
- **Four modes**: encrypt, decrypt, upload, download — all in one script
- **GoFile upload** via REST API — free, no account required
- **GoFile download** via Playwright — bypasses API premium restrictions by automating browser
- **Configurable exclusions** — skips logs, databases, backups, archives, and build artifacts
- **Cross-platform** — works on macOS and Ubuntu (Python native, no BSD/GNU compat issues)
- **Interactive or non-interactive** — passphrase prompt or `ARCHIVE_PASSWORD` env var
- **Meta files** — upload creates a `.meta` JSON file for easy download later

## Modes

### Encrypt

```bash
# Interactive (prompts for passphrase with confirmation)
python3 scripts/archive_encrypted.py encrypt

# Non-interactive
ARCHIVE_PASSWORD='secret' python3 scripts/archive_encrypted.py encrypt -o /tmp/backup.tar.gz.gpg
# Or
python3 scripts/archive_encrypted.py encrypt -o /tmp/backup.tar.gz.gpg --password 'secret'
```

After encryption, you'll be prompted to upload to GoFile (use `--no-upload` to skip).

### Decrypt

```bash
# Interactive passphrase
python3 scripts/archive_encrypted.py decrypt backup.tar.gz.gpg -d /tmp/restore

# Non-interactive
ARCHIVE_PASSWORD='secret' python3 scripts/archive_encrypted.py decrypt backup.tar.gz.gpg -d /tmp/restore
```

### Upload to GoFile

```bash
python3 scripts/archive_encrypted.py upload backup.tar.gz.gpg
```

Creates a `.meta` JSON file alongside the encrypted file with all GoFile credentials for later download.

### Download from GoFile

```bash
# From GoFile URL
python3 scripts/archive_encrypted.py download https://gofile.io/d/abc123 -o /tmp/backup.tar.gz.gpg

# From .meta file (created during upload)
python3 scripts/archive_encrypted.py download backup.tar.gz.gpg.meta
```

Uses **Playwright** headless Chromium to automate the download — bypasses GoFile's premium-only API restriction.

## Exclusion Patterns

| Category   | Patterns                                                    |
|------------|-------------------------------------------------------------|
| Logs       | `*.log`, `journal*.log`, `log/`, `logs/`                  |
| Databases  | `*.db`, `*.sqlite`, `*.sqlite3`, `db/`                     |
| Backups    | `*.bak`, `*backup*`, `db_backup/`, `log_backup/`          |
| Archives   | `*.gz`, `*.zip`, `*.tar`, `*.tgz`                         |
| Build junk | `node_modules/`, `__pycache__/`, `bin/`, `obj/`, `.vs/`    |
| Venvs      | `.venv/`, `venv/`                                           |
| VCS        | `.git/`, `.DS_Store`                                       |

## Environment Variables

| Variable            | Description                          |
|---------------------|--------------------------------------|
| `ARCHIVE_PASSWORD`  | Passphrase for encrypt/decrypt       |
| `GOFILE_TOKEN`      | GoFile account token for download    |

## Legacy Bash Script

The original bash script is preserved in [`archive/archive-encrypted.sh`](archive/archive-encrypted.sh). The Python version is now the default.

## Tech Stack

| Component    | Technology          |
|--------------|---------------------|
| GPG crypto   | python-gnupg        |
| Upload       | requests + GoFile API |
| Download     | Playwright (Chromium) |
| CLI          | argparse            |
| Tar          | subprocess + tar    |

## License

MIT
