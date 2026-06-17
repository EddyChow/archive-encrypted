# archive-encrypted

A bash script to create gzip-compressed, AES-256 encrypted archives of project folders with configurable exclusion patterns.

## Features

- **AES-256 encryption** with SHA-512 key derivation and high iteration count (65011712)
- **Configurable exclusions** — skips logs, databases, backups, archives, and build artifacts
- **Folder name preserved** inside the tarball
- **Two modes**: interactive passphrase prompt or `ARCHIVE_PASSWORD` environment variable

## Usage

### Encrypt (interactive)

```bash
cd /path/to/your-project
./scripts/archive-encrypted.sh
```

You will be prompted for a passphrase twice.

### Encrypt (non-interactive)

```bash
ARCHIVE_PASSWORD='your-secret' ./scripts/archive-encrypted.sh
```

### Encrypt with custom output path

```bash
./scripts/archive-encrypted.sh /tmp/my-backup.tar.gz.gpg
```

### Decrypt

```bash
gpg -d backup.tar.gz.gpg | tar -xzf - -C /destination/parent/dir
```

### Decrypt with passphrase on command line

```bash
gpg --batch --yes --pinentry-mode loopback --passphrase 'your-secret' -d backup.tar.gz.gpg | tar -xzf - -C /destination/parent/dir
```

## Exclusion Patterns

| Category   | Patterns                                        |
|------------|-------------------------------------------------|
| Logs       | `*.log`, `journal*.log`, `log/`, `logs/`        |
| Databases  | `*.db`, `*.sqlite`, `*.sqlite3`, `db/`          |
| Backups    | `*.bak`, `*backup*`, `db_backup/`, `log_backup/`|
| Archives   | `*.gz`, `*.zip`, `*.tar`, `*.tgz`              |
| Build junk | `node_modules/`, `__pycache__/`, `bin/`, `obj/`, `.vs/`, `.venv/`, `venv/` |

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
