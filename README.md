# archive-encrypted

A bash script for **encrypt, decrypt, and upload** project archives — cross-platform (macOS + Ubuntu).

## Features

- **AES-256 encryption** with SHA-512 key derivation and high iteration count (65011712)
- **Three modes**: encrypt, decrypt, upload — all in one script
- **GoFile upload** — free, no account required, unlimited file size
- **Configurable exclusions** — skips logs, databases, backups, archives, and build artifacts
- **Folder name preserved** inside the tarball
- **Cross-platform** — works on macOS (BSD) and Ubuntu (GNU)
- **Interactive or non-interactive** — passphrase prompt or `ARCHIVE_PASSWORD` env var

## Usage

### Encrypt (interactive)

```bash
cd /path/to/your-project
./scripts/archive-encrypted.sh encrypt
```

You will be prompted for a passphrase. After encryption, you'll be offered to upload to GoFile.

### Encrypt (non-interactive)

```bash
ARCHIVE_PASSWORD='your-secret' ./scripts/archive-encrypted.sh encrypt /tmp/backup.tar.gz.gpg
```

### Decrypt

```bash
./scripts/archive-encrypted.sh decrypt backup.tar.gz.gpg /tmp/restore
```

Or non-interactive:
```bash
ARCHIVE_PASSWORD='your-secret' ./scripts/archive-encrypted.sh decrypt backup.tar.gz.gpg /tmp/restore
```

Or manually:
```bash
gpg -d backup.tar.gz.gpg | tar -xzf - -C /destination/parent/dir
```

### Upload to GoFile

```bash
./scripts/archive-encrypted.sh upload backup.tar.gz.gpg
```

Output includes download page, file name, MD5, and credentials for managing the upload.

### Help

```bash
./scripts/archive-encrypted.sh help
```

## Exclusion Patterns

| Category   | Patterns                                        |
|------------|-------------------------------------------------|
| Logs       | `*.log`, `journal*.log`, `log/`, `logs/`        |
| Databases  | `*.db`, `*.sqlite`, `*.sqlite3`, `db/`          |
| Backups    | `*.bak`, `*backup*`, `db_backup/`, `log_backup/`|
| Archives   | `*.gz`, `*.zip`, `*.tar`, `*.tgz`              |
| Build junk | `node_modules/`, `__pycache__/`, `bin/`, `obj/`, `.vs/`, `.venv/`, `venv/` |

## Cross-Platform Compatibility

| Feature       | macOS (BSD)                  | Ubuntu (GNU)           |
|---------------|------------------------------|------------------------|
| `realpath`    | Fallback via python3         | Native                 |
| `stat`        | `stat -f%z`                  | `stat -c%s`           |
| `date`        | `date +%Y%m%d-%H%M%S`        | Same                   |
| `read -r -p`  | Supported                    | Supported              |
| `numfmt`      | Not available (fallback)     | Native                 |
| `gpg`         | `brew install gnupg`         | `apt install gnupg`   |

## Bug Fix

This repo contains a fix for the original script's critical bug in the interactive passphrase branch:

**Original (broken):**
```bash
printf '%s' "$pass1" | tar -czf - "${EXCLUDES[@]}" "$PROJECT_NAME" | gpg --passphrase-fd 0 ...
```

In this pipeline, `gpg --passphrase-fd 0` reads from stdin (fd 0), which is connected to `tar`'s binary output — **not** the passphrase from `printf`. The passphrase never reaches GPG, making the encrypted file undecryptable.

**Fixed:**
```bash
gpg_args+=(--passphrase "$pass1")
tar -czf - "${EXCLUDES[@]}" "$PROJECT_NAME" | gpg "${gpg_args[@]}"
```

The passphrase is passed directly via `--passphrase`, while `tar`'s output flows through the pipe to `gpg`'s stdin as the data to encrypt.

## License

MIT
