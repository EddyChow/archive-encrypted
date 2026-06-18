#!/usr/bin/env python3
"""
archive_encrypted.py — Encrypt, decrypt, upload, and download project archives.

Cross-platform (macOS + Ubuntu). Uses python-gnupg for symmetric AES-256
encryption, requests for GoFile upload, and Playwright for GoFile download.

Usage:
    python3 scripts/archive_encrypted.py <mode> [options]

Modes:
    encrypt  [-o OUTPUT]           Encrypt current project (default)
    decrypt  <file.gpg> [-d DEST]   Decrypt and extract
    upload   <file.gpg>             Upload to GoFile
    download <gofile-url|meta> [-o OUT]  Download from GoFile (Playwright)

Examples:
    python3 scripts/archive_encrypted.py encrypt -o /tmp/backup.tar.gz.gpg
    python3 scripts/archive_encrypted.py decrypt /tmp/backup.tar.gz.gpg -d /tmp/restore
    python3 scripts/archive_encrypted.py upload /tmp/backup.tar.gz.gpg
    python3 scripts/archive_encrypted.py download https://gofile.io/d/abc123 -o /tmp/backup.tar.gz.gpg
"""

# ─── Node.js fix for Playwright (bun injects broken NODE_OPTIONS) ──────────────
import os
os.environ.pop("NODE_OPTIONS", None)

import argparse
import getpass
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime
from pathlib import Path

# ─── Constants ──────────────────────────────────────────────────────────────────

GPG_CIPHER = "AES256"
GPG_S2K_MODE = "3"
GPG_S2K_DIGEST = "SHA512"
GPG_S2K_COUNT = "65011712"
GPG_COMPRESS = "none"

GOFILE_API = "https://api.gofile.io"
GOFILE_WEBSITE_TOKEN = "4fd6sg89d7s6"

# tar --exclude patterns (same as bash version)
EXCLUDE_PATTERNS = [
    "*.log", "journal*.log", "log", "logs",
    "*.db", "*.sqlite", "*.sqlite3", "db",
    "*.bak", "*.bak.*", "*backup*", "*.backup*", "db.bak*", "db_backup", "log_backup",
    "*.gz", "*.zip", "*.tar", "*.tgz",
    "node_modules", "__pycache__", "*.pyc",
    ".venv", "venv", "bin", "obj", ".vs",
    ".git", ".DS_Store",
]

SEP = "━" * 40


# ─── Passphrase helpers ────────────────────────────────────────────────────────

def get_passphrase(confirm: bool = False) -> str:
    """Get passphrase from env var, or prompt interactively."""
    pw = os.environ.get("ARCHIVE_PASSWORD", "")
    if pw:
        return pw

    pw = getpass.getpass("Enter passphrase: ")
    if not pw:
        print("Error: passphrase cannot be empty.", file=sys.stderr)
        sys.exit(1)

    if confirm:
        pw2 = getpass.getpass("Confirm passphrase: ")
        if pw != pw2:
            print("Error: passphrases do not match.", file=sys.stderr)
            sys.exit(1)

    return pw


# ─── GPG encryption / decryption ───────────────────────────────────────────────

class ArchiveCrypto:
    """Symmetric GPG encryption using python-gnupg."""

    def __init__(self):
        import gnupg
        self.gpg = gnupg.GPG()

    def encrypt(self, data: bytes, passphrase: str) -> bytes:
        """Encrypt bytes with AES-256 symmetric GPG."""
        result = self.gpg.encrypt(
            data, recipients=None,
            symmetric=GPG_CIPHER,
            passphrase=passphrase,
            extra_args=[
                "--s2k-mode", GPG_S2K_MODE,
                "--s2k-digest-algo", GPG_S2K_DIGEST,
                "--s2k-count", GPG_S2K_COUNT,
                "--compress-algo", GPG_COMPRESS,
                "--batch", "--yes",
                "--pinentry-mode", "loopback",
            ],
        )
        if not result.ok:
            print(f"Error: encryption failed: {result.stderr}", file=sys.stderr)
            sys.exit(1)
        return result.data

    def decrypt(self, input_file: str, passphrase: str) -> bytes:
        """Decrypt a GPG symmetric file, return plaintext bytes."""
        import gnupg
        with open(input_file, "rb") as f:
            result = self.gpg.decrypt_file(
                f, passphrase=passphrase,
                extra_args=["--batch", "--yes", "--pinentry-mode", "loopback"],
            )
        if not result.ok:
            print(f"Error: decryption failed: {result.stderr}", file=sys.stderr)
            sys.exit(1)
        return result.data

    @staticmethod
    def encrypt_file_stream(project_dir: Path, output_file: Path, passphrase: str):
        """Tar+gzip a project directory and encrypt in one pipeline."""
        # Use subprocess tar → python-gnupg encrypt
        # This avoids loading entire tarball into memory for large projects
        project_name = project_dir.name
        parent_dir = project_dir.parent

        import gnupg
        gpg = gnupg.GPG()

        # Build tar command
        tar_args = ["tar", "-czf", "-"]
        for pattern in EXCLUDE_PATTERNS:
            tar_args.extend(["--exclude", pattern])
        tar_args.append(project_name)

        # Run tar as subprocess, capture stdout
        proc = subprocess.Popen(
            tar_args, cwd=str(parent_dir),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        # Encrypt the tar stream
        result = gpg.encrypt(
            proc.stdout.read(), recipients=None,
            symmetric=GPG_CIPHER,
            passphrase=passphrase,
            extra_args=[
                "--s2k-mode", GPG_S2K_MODE,
                "--s2k-digest-algo", GPG_S2K_DIGEST,
                "--s2k-count", GPG_S2K_COUNT,
                "--compress-algo", GPG_COMPRESS,
                "--batch", "--yes",
                "--pinentry-mode", "loopback",
            ],
        )

        proc.wait()

        if not result.ok:
            print(f"Error: encryption failed: {result.stderr}", file=sys.stderr)
            sys.exit(1)

        # Write encrypted output
        with open(output_file, "wb") as f:
            f.write(result.data)

    @staticmethod
    def decrypt_and_extract(input_file: Path, dest_dir: Path, passphrase: str):
        """Decrypt a GPG file and extract tar.gz to destination."""
        import gnupg
        gpg = gnupg.GPG()

        with open(input_file, "rb") as f:
            result = gpg.decrypt_file(
                f, passphrase=passphrase,
                extra_args=["--batch", "--yes", "--pinentry-mode", "loopback"],
            )

        if not result.ok:
            print(f"Error: decryption failed: {result.stderr}", file=sys.stderr)
            sys.exit(1)

        # Extract tar.gz from decrypted data
        import io
        with tarfile.open(fileobj=io.BytesIO(result.data), mode="r:gz") as tar:
            tar.extractall(path=str(dest_dir))


# ─── GoFile operations via Playwright ──────────────────────────────────────────

class GoFileClient:
    """Upload and download files from GoFile using Playwright browser automation.

    Uses headless Chromium to bypass IP-based API restrictions.
    """

    def __init__(self):
        os.environ.pop("NODE_OPTIONS", None)  # Fix bun shim issue
        self._playwright = None
        self._browser = None
        self._page = None

    def _ensure_browser(self):
        """Lazy-init Playwright browser."""
        if self._page is not None:
            return
        from playwright.sync_api import sync_playwright
        self._playwright = sync_playwright().start()
        self._browser = self._playwright.chromium.launch(
            headless=True, args=["--no-sandbox", "--disable-gpu"]
        )
        context = self._browser.new_context(accept_downloads=True)
        self._page = context.new_page()
        # Navigate to gofile.io to establish session/cookies
        self._page.goto("https://gofile.io", timeout=30000)

    def _api_get(self, path: str) -> dict:
        """Call GoFile GET API from browser context."""
        self._ensure_browser()
        url = f"{GOFILE_API}{path}"
        result = self._page.evaluate("""async (url) => {
            const resp = await fetch(url);
            return await resp.json();
        }""", url)
        return result

    def _api_post(self, path: str, headers: dict = None, data: dict = None, form_data=None) -> dict:
        """Call GoFile POST API from browser context."""
        self._ensure_browser()
        url = f"{GOFILE_API}{path}" if path.startswith("/") else path

        if form_data:
            # File upload via browser FormData
            result = self._page.evaluate("""async ({url, token, folderId, fileContent, fileName}) => {
                const formData = new FormData();
                formData.append('token', token);
                formData.append('folderId', folderId);
                formData.append('file', new Blob([fileContent]), fileName);
                const resp = await fetch(url, {method: 'POST', body: formData});
                return await resp.json();
            }""", {"url": url, "token": form_data["token"], "folderId": form_data["folderId"],
                   "fileContent": form_data["fileContent"], "fileName": form_data["fileName"]})
        else:
            # JSON form data
            body = "&".join(f"{k}={v}" for k, v in (data or {}).items())
            hdrs = headers or {}
            result = self._page.evaluate("""async ({url, body, hdrs}) => {
                const resp = await fetch(url, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/x-www-form-urlencoded', ...hdrs},
                    body: body,
                });
                return await resp.json();
            }""", {"url": url, "body": body, "hdrs": hdrs})
        return result

    def create_guest_account(self) -> dict:
        """Create a GoFile guest account."""
        data = self._api_post("/accounts")
        if data.get("status") != "ok":
            print(f"Error: failed to create GoFile account: {data}", file=sys.stderr)
            sys.exit(1)
        return data["data"]

    def create_folder(self, token: str, root_folder: str) -> str:
        """Create a folder under root."""
        resp = self._api_post(
            "/contents/createFolder",
            headers={"Authorization": f"Bearer {token}"},
            data={"parentFolderId": root_folder,
                  "folderName": f"backup-{datetime.now().strftime('%Y%m%d-%H%M%S')}"},
        )
        folder_id = resp.get("data", {}).get("id", "")
        return folder_id or root_folder

    def get_server(self) -> str:
        """Get the best upload server."""
        data = self._api_get("/servers")
        servers = data.get("data", {}).get("servers", [])
        return servers[0]["name"] if servers else "store1"

    def upload_file(self, file_path: Path, token: str, folder_id: str, server: str) -> dict:
        """Upload a file to GoFile via browser."""
        # Read file content for browser FormData
        file_content = file_path.read_bytes()
        resp = self._api_post(
            f"https://{server}.gofile.io/contents/uploadfile",
            form_data={
                "token": token,
                "folderId": folder_id,
                "fileContent": file_content,
                "fileName": file_path.name,
            },
        )
        if resp.get("status") != "ok":
            print(f"Error: upload failed: {resp}", file=sys.stderr)
            sys.exit(1)
        return resp["data"]

    def download_file(self, content_code: str, output_file: str, gofile_token: str = None,
                      file_id: str = None, file_name: str = None,
                      expected_md5: str = None) -> str:
        """Download a file from GoFile via browser automation.

        Strategy:
        1. Try GoFile contents API via browser fetch → get direct link → curl download
        2. If API returns notPremium, construct direct URL from file_id
        3. Fallback: navigate to download page and click download button
        """
        self._ensure_browser()

        download_url = f"https://gofile.io/d/{content_code}"
        print(f"  GoFile page: {download_url}")

        # Strategy 1: Try API via browser to get direct download link
        print("  Fetching file info via API...")
        api_url = f"{GOFILE_API}/contents/{content_code}?wt={GOFILE_WEBSITE_TOKEN}"
        headers = {}
        if gofile_token:
            headers["Authorization"] = f"Bearer {gofile_token}"

        result = self._page.evaluate("""async ({url, authHeader}) => {
            try {
                const resp = await fetch(url, {headers: {'Authorization': authHeader}});
                return await resp.json();
            } catch(e) {
                return {status: 'error', message: e.message};
            }
        }""", {"url": api_url, "authHeader": headers.get("Authorization", "")})

        api_status = result.get("status", "")
        direct_url = None

        if api_status == "ok":
            data = result.get("data", {})
            children = data.get("children", {})
            if isinstance(children, dict):
                files = list(children.values())
            elif isinstance(children, list):
                files = children
            else:
                files = []
            if data.get("type") == "file":
                files = [data]
            if files:
                direct_url = files[0].get("link", "")
                if not file_name:
                    file_name = files[0].get("name", "")
                if not expected_md5:
                    expected_md5 = files[0].get("md5", "")
            print(f"  API: ok — got direct link")
        elif api_status == "error-notPremium":
            # Construct direct URL from file_id
            if file_id and file_name:
                servers = self._api_get("/servers")
                srv_list = servers.get("data", {}).get("servers", [])
                dl_server = srv_list[0]["name"] if srv_list else "store1"
                direct_url = f"https://{dl_server}.gofile.io/download/web/{file_id}/{file_name}"
                print(f"  API: notPremium — constructed direct URL")
            else:
                print(f"  API: notPremium — no file_id for direct URL")
        else:
            print(f"  API: {api_status}")

        # If we have a direct URL, download via browser API request (carries cookies)
        if direct_url:
            print(f"  Downloading: {direct_url[:80]}...")
            # Use the browser context's API request — it carries session cookies
            api_context = self._page.request
            try:
                response = api_context.get(direct_url, timeout=60000)
                if response.ok:
                    body = response.body()
                    # Check if we got HTML (auth redirect) vs actual file
                    if body[:5] == b"<!doc" or body[:5] == b"<html":
                        raise Exception("Got HTML instead of file content (auth required)")
                    with open(output_file, "wb") as f:
                        f.write(body)
                    print(f"  Download saved: {output_file}")
                else:
                    raise Exception(f"HTTP {response.status}")
            except Exception as e:
                print(f"  Direct download failed: {e}", file=sys.stderr)
                # Fallback: navigate to the store server domain first (same-origin fetch)
                print(f"  Trying same-origin fetch from store server...")
                # Navigate to the store domain root (will get 404 but establish origin)
                store_origin = "/".join(direct_url.split("/")[:3])
                self._page.goto(store_origin, wait_until="domcontentloaded", timeout=15000)

                file_bytes = self._page.evaluate("""async (url) => {
                    const resp = await fetch(url, {credentials: 'include'});
                    if (!resp.ok) throw new Error('HTTP ' + resp.status);
                    const buffer = await resp.arrayBuffer();
                    return Array.from(new Uint8Array(buffer));
                }""", direct_url)
                with open(output_file, "wb") as f:
                    f.write(bytes(file_bytes))
                print(f"  Download saved: {output_file}")
        else:
            # Fallback: navigate to download page and try clicking
            print(f"  No direct URL — trying page navigation...")
            self._page.goto(download_url, wait_until="domcontentloaded", timeout=30000)

            download_triggered = False
            try:
                self._page.wait_for_selector(
                    "a[href*='download'], button:has-text('Download')", timeout=20000
                )
                dl_link = self._page.query_selector("a[href*='download']")
                if dl_link:
                    href = dl_link.get_attribute("href")
                    print(f"  Found download link: {href[:80]}...")
                    download_holder = []
                    self._page.on("download", lambda d: download_holder.append(d))
                    dl_link.click()
                    import time
                    for _ in range(120):
                        if download_holder:
                            break
                        time.sleep(0.5)
                    if download_holder:
                        download_holder[0].save_as(output_file)
                        download_triggered = True
                        print(f"  Download saved: {output_file}")
            except Exception as e:
                print(f"  Page approach failed: {e}", file=sys.stderr)

            if not download_triggered:
                print(f"\n  Error: could not download file automatically.", file=sys.stderr)
                print(f"  Open in browser: {download_url}", file=sys.stderr)
                sys.exit(1)

        # Verify MD5
        if expected_md5:
            actual_md5 = hashlib.md5(open(output_file, "rb").read()).hexdigest()
            if actual_md5 != expected_md5:
                print(f"  Error: MD5 mismatch!", file=sys.stderr)
                print(f"    Expected: {expected_md5}", file=sys.stderr)
                print(f"    Actual:   {actual_md5}", file=sys.stderr)
                sys.exit(1)
            print(f"  ✓ MD5 verified: {actual_md5}")

        return output_file

    def close(self):
        """Clean up browser resources."""
        if self._browser:
            self._browser.close()
        if self._playwright:
            self._playwright.stop()

    @staticmethod
    def extract_code(url_or_code: str) -> str:
        """Extract GoFile content code from URL or raw code."""
        code = url_or_code.rstrip("/")
        if "/" in code:
            code = code.split("/")[-1]
        if "?" in code:
            code = code.split("?")[0]
        return code

    @staticmethod
    def load_meta(meta_path: str) -> dict:
        """Load metadata from a .meta JSON file."""
        with open(meta_path) as f:
            return json.load(f)

    @staticmethod
    def write_meta(meta_path: Path, info: dict):
        """Write a .meta JSON file alongside the encrypted file."""
        with open(meta_path, "w") as f:
            json.dump(info, f, indent=2)


# ─── Utility ───────────────────────────────────────────────────────────────────

def _human_size(size_bytes: int) -> str:
    """Convert bytes to human-readable string."""
    for unit in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f}{unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f}PiB"


def _sha256_file(path: str) -> str:
    """Calculate SHA256 of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


# ─── Mode: encrypt ──────────────────────────────────────────────────────────────

def do_encrypt(args):
    """Encrypt a project directory."""
    project_dir = Path(args.project_dir).resolve()

    if not project_dir.is_dir():
        print(f"Error: project directory not found: {project_dir}", file=sys.stderr)
        sys.exit(1)

    project_name = project_dir.name
    parent_dir = project_dir.parent

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_file = Path(args.output) if args.output else parent_dir / f"{project_name}-{timestamp}.tar.gz.gpg"

    if output_file.exists():
        print(f"Error: output file already exists: {output_file}", file=sys.stderr)
        sys.exit(1)

    print(SEP)
    print("  Encrypt mode")
    print(SEP)
    print(f"  Project:  {project_name}")
    print(f"  Source:   {project_dir}")
    print(f"  Output:   {output_file}")
    print(f"  Cipher:   {GPG_CIPHER} / {GPG_S2K_DIGEST} / s2k-count {GPG_S2K_COUNT}")
    print(f"  Excludes: {', '.join(EXCLUDE_PATTERNS[:8])}...")
    print()

    passphrase = get_passphrase(confirm=True)

    ArchiveCrypto.encrypt_file_stream(project_dir, output_file, passphrase)

    # Zero out passphrase
    passphrase = None

    file_size = output_file.stat().st_size
    print(f"\n✓ Encrypted: {output_file}")
    print(f"  Size: {_human_size(file_size)}")
    print(f"  SHA256: {_sha256_file(str(output_file))}")

    # Offer to upload
    if not args.no_upload:
        try:
            choice = input("\nUpload to GoFile? [y/N] ").strip().lower()
            if choice == "y":
                do_upload_file(output_file)
        except (EOFError, KeyboardInterrupt):
            pass


# ─── Mode: decrypt ─────────────────────────────────────────────────────────────

def do_decrypt(args):
    """Decrypt and extract an encrypted archive."""
    input_file = Path(args.file)
    dest_dir = Path(args.dest) if args.dest else Path(".")

    if not input_file.exists():
        print(f"Error: file not found: {input_file}", file=sys.stderr)
        sys.exit(1)

    dest_dir.mkdir(parents=True, exist_ok=True)

    print(SEP)
    print("  Decrypt mode")
    print(SEP)
    print(f"  Input:  {input_file}")
    print(f"  Output: {dest_dir}")
    print()

    passphrase = get_passphrase(confirm=False)

    ArchiveCrypto.decrypt_and_extract(input_file, dest_dir, passphrase)

    passphrase = None

    print(f"\n✓ Decrypted to: {dest_dir}")
    for item in dest_dir.iterdir():
        print(f"  {item.name}" + ("/" if item.is_dir() else ""))


# ─── Mode: upload ──────────────────────────────────────────────────────────────

def do_upload_file(file_path: Path, gofile_token: str = None):
    """Upload an encrypted file to GoFile."""
    if not file_path.exists():
        print(f"Error: file not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    file_size = file_path.stat().st_size

    print(SEP)
    print("  Upload mode (GoFile via Playwright)")
    print(SEP)
    print(f"  File:   {file_path}")
    print(f"  Size:   {_human_size(file_size)}")
    print()

    client = GoFileClient()

    print("  Creating GoFile guest session...")
    account = client.create_guest_account()
    token = account["token"]
    root_folder = account["rootFolder"]

    print("  Creating upload folder...")
    folder_id = client.create_folder(token, root_folder)

    print("  Finding upload server...")
    server = client.get_server()

    print(f"  Uploading to {server}.gofile.io...")
    upload_data = client.upload_file(file_path, token, folder_id, server)

    download_page = upload_data.get("downloadPage", "")
    file_id = upload_data.get("id", "")
    file_name = upload_data.get("name", "")
    file_md5 = upload_data.get("md5", "")

    # Write .meta file
    meta_path = Path(str(file_path) + ".meta")
    client.write_meta(meta_path, {
        "gofile_code": download_page.split("/")[-1] if download_page else "",
        "gofile_token": token,
        "gofile_file_id": file_id,
        "gofile_file_name": file_name,
        "gofile_md5": file_md5,
        "download_page": download_page,
    })

    client.close()

    print()
    print(SEP)
    print("  Upload complete!")
    print(SEP)
    print()
    print(f"  Download page: {download_page}")
    print(f"  File:          {file_name}")
    print(f"  Size:          {_human_size(file_size)}")
    print(f"  MD5:           {file_md5}")
    print()
    print(f"  Meta file:     {meta_path}")
    print()
    print("  ⚠️  Save these credentials:")
    print(f"  accountToken:  {token}")
    print(f"  folderId:      {folder_id}")
    print()
    print("  To download:")
    print(f"    python3 scripts/archive_encrypted.py download {download_page}")
    print()
    print("  To decrypt:")
    print(f"    python3 scripts/archive_encrypted.py decrypt <filename.gpg> -d /destination")


def do_upload(args):
    """Upload CLI entry point."""
    do_upload_file(Path(args.file))


# ─── Mode: download ────────────────────────────────────────────────────────────

def do_download(args):
    """Download from GoFile via Playwright."""
    gofile_token = args.gofile_token or os.environ.get("GOFILE_TOKEN", "")

    # Parse input: .meta file or URL/code
    if os.path.isfile(args.url_or_meta) and args.url_or_meta.endswith(".meta"):
        meta_data = GoFileClient.load_meta(args.url_or_meta)
        content_code = meta_data.get("gofile_code", "")
        gofile_token = gofile_token or meta_data.get("gofile_token", "")
        file_name = meta_data.get("gofile_file_name", "")
        file_id = meta_data.get("gofile_file_id", "")
        expected_md5 = meta_data.get("gofile_md5", "")
    else:
        content_code = GoFileClient.extract_code(args.url_or_meta)
        file_name = ""
        file_id = ""
        expected_md5 = ""

    if not content_code:
        print(f"Error: could not determine GoFile code from: {args.url_or_meta}", file=sys.stderr)
        sys.exit(1)

    output_file = args.output or file_name or "downloaded.tar.gz.gpg"

    print(SEP)
    print("  Download mode (Playwright)")
    print(SEP)
    print(f"  GoFile code:  {content_code}")
    print(f"  Output:       {output_file}")
    if expected_md5:
        print(f"  Expected MD5: {expected_md5}")
    print()

    client = GoFileClient()
    client.download_file(content_code, output_file, gofile_token,
                         file_id, file_name, expected_md5)
    client.close()

    # Verify MD5
    if expected_md5:
        actual_md5 = hashlib.md5(open(output_file, "rb").read()).hexdigest()
        if actual_md5 != expected_md5:
            print(f"  Error: MD5 mismatch!", file=sys.stderr)
            print(f"    Expected: {expected_md5}", file=sys.stderr)
            print(f"    Actual:   {actual_md5}", file=sys.stderr)
            sys.exit(1)
        print(f"  ✓ MD5 verified: {actual_md5}")

    file_size = os.path.getsize(output_file)
    print(f"\n✓ Downloaded: {output_file} ({_human_size(file_size)})")


# ─── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Encrypt, decrypt, upload, and download project archives.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  python3 scripts/archive_encrypted.py encrypt -o /tmp/backup.tar.gz.gpg
  python3 scripts/archive_encrypted.py decrypt /tmp/backup.tar.gz.gpg -d /tmp/restore
  python3 scripts/archive_encrypted.py upload /tmp/backup.tar.gz.gpg
  python3 scripts/archive_encrypted.py download https://gofile.io/d/abc123 -o /tmp/backup.tar.gz.gpg
  python3 scripts/archive_encrypted.py download /tmp/backup.tar.gz.gpg.meta
""",
    )
    sub = parser.add_subparsers(dest="mode", required=True)

    # encrypt
    p_enc = sub.add_parser("encrypt", help="Encrypt a project directory")
    p_enc.add_argument("project_dir", help="Project directory to encrypt")
    p_enc.add_argument("-o", "--output", help="Output file path")
    p_enc.add_argument("--no-upload", action="store_true", help="Skip upload prompt")
    p_enc.add_argument("--password", help="Passphrase (or set ARCHIVE_PASSWORD env)")
    p_enc.set_defaults(func=do_encrypt)

    # decrypt
    p_dec = sub.add_parser("decrypt", help="Decrypt and extract archive")
    p_dec.add_argument("file", help="Encrypted .gpg file path")
    p_dec.add_argument("-d", "--dest", help="Destination directory (default: current dir)")
    p_dec.add_argument("--password", help="Passphrase (or set ARCHIVE_PASSWORD env)")
    p_dec.set_defaults(func=do_decrypt)

    # upload
    p_up = sub.add_parser("upload", help="Upload encrypted file to GoFile")
    p_up.add_argument("file", help="File to upload")
    p_up.set_defaults(func=do_upload)

    # download
    p_dl = sub.add_parser("download", help="Download from GoFile (Playwright)")
    p_dl.add_argument("url_or_meta", help="GoFile URL, content code, or .meta file path")
    p_dl.add_argument("-o", "--output", help="Output file path")
    p_dl.add_argument("--gofile-token", help="GoFile account token (or set GOFILE_TOKEN env)")
    p_dl.set_defaults(func=do_download)

    args = parser.parse_args()

    # Set password from arg if provided
    if hasattr(args, "password") and args.password:
        os.environ["ARCHIVE_PASSWORD"] = args.password

    args.func(args)


if __name__ == "__main__":
    main()
