# OPNsense Certificate-to-P12 Exporter

Automate the export of OPNsense certificates into PKCS#12 (.p12/.pfx) format.
Designed to run daily via cron AND as an ACME client deploy hook — with the
resulting .p12 file accessible through the OPNsense HTTP API.

## Problem

OPNsense stores certificates in its configuration file (`/conf/config.xml`) as
base64-encoded PEM entries. Many applications (Windows servers, Java keystores,
OpenVPN, Wi-Fi RADIUS servers, load balancers, etc.) require PKCS#12 format.
The web GUI allows manual .p12 download, but there is no built-in mechanism to:

- Export .p12 on a schedule (daily refresh)
- Automatically regenerate .p12 after ACME/LetsEncrypt renewal
- Serve the .p12 file via HTTP API for remote consumers

This project solves all three.

## How Certificate Lookup Works

The script searches for certificates in three phases:

1. **ACME deploy-hook context** — If `CERT_PATH` and `KEY_PATH` environment
   variables are set (as during ACME client automation runs), those files are
   used directly.

2. **OPNsense config.xml** — Parses `/conf/config.xml` for `<cert>` entries.
   Matches against `--cert` by exact refid or case-insensitive substring of the
   description. This covers built-in OPNsense certificates and ACME certificates
   that were imported into the trust store.

3. **ACME filesystem fallback** — If not found in config.xml, the script scans
   `/var/etc/acme-client/certs/` on disk, extracting the subject CN and SANs
   from each certificate via OpenSSL, and matches against the `--cert` value.
   Matching is two-phase: **exact matches** (case-insensitive) are checked
   first to avoid ambiguity, then **substring matches** as fallback.
   Additional match sources include the ACME config file `CERT_DOMAIN`, the
   home directory name, and the certificate UUID.
   This covers ACME/LetsEncrypt certificates that were **never imported** into
   the OPNsense trust store.

---

## Architecture

```
                             ┌──────────────────────────────┐
                             │        OPNsense Firewall       │
                             │                                │
  cron (daily) ─────────────▶│  cert-to-p12.sh               │
                             │    │                           │
  ACME client (on renew) ───▶│    │  ┌───► /root/cert-export/ │
                             │    │  │     *.p12              │
                             │    │  │     *.password         │
                             │    └──┘                        │
                             │                                │
  curl/wget ◀────────────────│  cert-export.php (API)         │
  (HTTP API)                 │    (auth via API keys)         │
                             └──────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh` | Main export script |
| `usr/local/opnsense/scripts/cert-to-p12/cert-export.php` | HTTP API download handler |
| `usr/local/opnsense/service/conf/actions.d/actions_cert-to-p12.conf` | Configd action definition |
| `scripts/windows/install-cert.ps1` | PowerShell client for Windows certificate import |
| `scripts/windows/.env.example` | Configuration template for the Windows client |

---

## Quick Install (one-liner)

Run this directly on your OPNsense firewall (as root or via `sudo`):

```bash
curl -sSL https://raw.githubusercontent.com/petrgru/opnsense-cert-to-p12/master/install.sh | sh
```

> **Security note:** Piping `curl` to `sh` is convenient, but you should
> [review the installer script](https://github.com/petrgru/opnsense-cert-to-p12/blob/master/install.sh)
> first if you have any concerns. The script:
> - Verifies it is running as root.
> - Downloads each file from GitHub with HTTP error checking.
> - Validates each downloaded file has the expected content type.
> - Installs files into `/usr/local/opnsense/scripts/cert-to-p12/` and related paths.
> - Restarts `configd` to register the new actions.
>
> After installation, verify with:
>
> ```bash
> cert-to-p12.sh --cert webgui
> configctl cert-to-p12 describe
> ```

---

## Manual Installation

### 1. Copy files to OPNsense

```bash
# From your development machine:
scp -r usr/local/opnsense/scripts/cert-to-p12 root@opnsense:/usr/local/opnsense/scripts/
scp usr/local/opnsense/service/conf/actions.d/actions_cert-to-p12.conf \
    root@opnsense:/usr/local/opnsense/service/conf/actions.d/
```

Or directly on the OPNsense console:

```bash
mkdir -p /usr/local/opnsense/scripts/cert-to-p12
# Then copy or create the files (see code blocks below)
```

### 2. Make the script executable

```bash
chmod +x /usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh
```

### 3. Install the PHP API download handler

```bash
mkdir -p /usr/local/www/cert-export
cp /usr/local/opnsense/scripts/cert-to-p12/cert-export.php \
    /usr/local/www/cert-export/index.php
```

### 4. Register the configd action

```bash
service configd restart
```

Verify it registered:

```bash
configctl cert-to-p12 describe
```

You should see the available actions listed.

### 5. Generate an API key (for HTTP download)

1. Go to **System → Access → Users**
2. Edit your user (e.g., `root`)
3. Scroll to **API keys** and click **Add** (+)
4. Save the displayed **key** and **secret** — they won't be shown again

---

## Usage

### Command-Line Export

```bash
# Export by description substring (e.g., "Web GUI TLS certificate")
/usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh --cert "webgui"

# Export by exact refid (UUID from config.xml)
/usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh --cert "a1b2c3d4e5f6"

# Export with custom password
/usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh \
    --cert "letsencrypt" \
    --password "MySecretPass123"

# Export with legacy mode (for old Java/Windows clients)
/usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh \
    --cert "mycert" \
    --legacy \
    --outdir /tmp

# Force overwrite, quiet mode
/usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh \
    --cert "webgui" \
    --force \
    --quiet
```

#### Output

The script creates two files in the output directory (default: `/root/cert-export/`):

- `<sanitized_name>.p12` — The PKCS#12 file
- `<sanitized_name>.password` — The password (auto-generated or the one you supplied)

The certificate description is sanitized for use as a filename: spaces become
underscores, special characters are removed.

#### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Certificate not found in config.xml or ACME filesystem |
| 3 | OpenSSL error or cert/key mismatch |
| 4 | Invalid or missing argument |
| 5 | Output file exists and `--force` not used |

### HTTP API Download

Once the PHP handler is installed and an API key has been created, download the
.p12 file:

#### With Basic Authentication (recommended)

```bash
curl -u "API_KEY:API_SECRET" \
    "https://opnsense.example.com/cert-export/?cert=webgui" \
    --output webgui.p12
```

#### With Query-String Parameters (HTTPS only)

```bash
curl "https://opnsense.example.com/cert-export/?cert=webgui&apikey=KEY&apisecret=SECRET" \
    --output webgui.p12
```

#### In a script using the API key file

```bash
#!/bin/sh
API_KEY="your-api-key"
API_SECRET="your-api-secret"
CERT_NAME="letsencrypt"
OPNSENSE_URL="https://opnsense.example.com"

curl -u "${API_KEY}:${API_SECRET}" \
    "${OPNSENSE_URL}/cert-export/?cert=${CERT_NAME}" \
    --output "/etc/ssl/${CERT_NAME}.p12"

# Read the password from the OPNsense (requires SSH access)
PASSWORD=$(ssh root@opnsense "cat /root/cert-export/${CERT_NAME}.password")
echo "Password: ${PASSWORD}"
```

#### Expected Response Codes

| Code | Meaning |
|------|---------|
| 200 | .p12 file downloaded |
| 400 | Missing `cert` parameter |
| 401 | Authentication required |
| 403 | Invalid API key or secret |
| 404 | .p12 file not found (run cert-to-p12.sh first) |
| 500 | No API keys configured or server error |
| 200 | .password file downloaded (with `&password=1`) |

---

## Windows Client Setup

Automatically download and install the exported .p12 certificate into the
Windows Local Machine certificate store (so IIS, SQL Server, or any Windows
service can use it).

### Requirements

- **Windows 10 / Windows Server 2016+** (PowerShell 5.1+)
- **Administrator privileges** (required for Local Machine certificate store)
- The **OPNsense cert-export PHP handler** must be installed (see
  [Manual Installation](#manual-installation) steps 3–4)
- An **API key** created in **System → Access → Users** on the OPNsense

### Files

| File | Purpose |
|------|---------|
| `scripts/windows/install-cert.ps1` | PowerShell script that downloads and imports the certificate |
| `scripts/windows/.env.example` | Template for the configuration file |

### Setup

1. Copy `scripts/windows/.env.example` to `scripts/windows/.env` (same
   directory as the script).

2. Edit `.env` with your OPNsense details:

   ```ini
   OPNSENSE_URL=https://192.168.1.1
   API_KEY=your_api_key
   API_SECRET=your_api_secret
   CERT_NAME=webgui
   SKIP_TLS_VERIFY=true
   ```

   > **Note about self-signed certificates:** OPNsense uses its own CA by
   > default. Set `SKIP_TLS_VERIFY=true` to bypass certificate validation.
   > For production, add your OPNsense CA to the Windows Trusted Root store
   > instead.

### Usage

Open PowerShell **as Administrator** and run:

```powershell
.\scripts\windows\install-cert.ps1
```

Or specify a custom config path:

```powershell
.\scripts\windows\install-cert.ps1 -EnvFile C:\Config\my-opnsense.env
```

### What the script does

1. Reads the `.env` configuration file
2. Downloads `<CERT_NAME>.p12` from the OPNsense API via Basic auth
3. Downloads `<CERT_NAME>.password` from the OPNsense API (`?password=1`)
4. Imports the certificate into `Cert:\LocalMachine\My` (Personal store)
5. Verifies the imported certificate matches the downloaded file

The certificate is imported with the `-Exportable` flag so the private key can
be re-exported if needed (e.g., for binding to additional services).

### Re-running

The script **always overwrites** the existing certificate in the store. Run it
on a schedule (e.g., via Task Scheduler) to keep the Windows certificate in
sync with daily OPNsense renewals:

```powershell
# Example Task Scheduler action:
#   Program:   powershell.exe
#   Arguments: -ExecutionPolicy Bypass -File "C:\scripts\install-cert.ps1"
```

### Adding the OPNsense CA to Windows (optional)

If you prefer **not** to skip TLS verification:

1. On OPNsense, go to **System → Trust → Authorities**
2. Export your OPNsense CA certificate
3. On Windows, run `certlm.msc` → Trusted Root Certification Authorities →
   Certificates → right-click → All Tasks → Import
4. Select the exported CA file

Now set `SKIP_TLS_VERIFY=false` (or remove the line) in `.env`.

---

## Cron Setup (Daily Refresh)

### Via the Web GUI

1. Go to **System → Settings → Cron**
2. Click **Add** (+)
3. Set:
   - **Description**: `Export Web GUI cert as P12`
   - **Command**: `Export certificate as PKCS#12 (.p12)`
   - **Parameters**: `webgui` (or your certificate name/refid)
   - **Minutes**: `0` (run at the top of the hour)
   - **Hours**: `3` (run at 3:00 AM)
   - **Days**: `*`
   - **Months**: `*`
   - **Days of Week**: `*`
4. Click **Save**

### Via the CLI

```bash
# The cron entry is stored in config.xml and managed via the web GUI.
# Alternatively, add a crontab entry directly:
echo "0 3 * * * root /usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh \
    --cert webgui --force --quiet" >> /etc/crontab
```

---

## ACME Client Deploy Hook (Post-Renewal)

This is the key integration: the .p12 file is automatically regenerated
immediately after the ACME client renews a certificate.

### Method A: Using configd actions

1. Go to **Services → ACME Client → Certificates**
2. Edit the certificate you want to auto-export
3. Under **Automations**, add one of the following:

   | Automation Name | Action |
   |----------------|--------|
   | `cert-to-p12-export` | Select `Export certificate as PKCS#12 (.p12)` |
   | `cert-to-p12-legacy` | Select `Export certificate as PKCS#12 (.p12) legacy` |

4. In the **Parameters** field, enter the certificate **description** substring
   or **refid** (same value you would pass to `--cert`).
5. Save the certificate.

Now every time this ACME certificate is issued or renewed, the .p12 file will
be regenerated automatically. The `--force` flag is built into the configd
action so it always overwrites the previous export.

### Method B: Custom automation with shell command

If your OPNsense version supports the "Remote command via SSH" automation type,
you can also configure it to run the script directly on localhost:

1. Create an automation of type **Remote command via SSH**
2. Set host to `127.0.0.1` and user to `root`
3. Set the remote command to:
   ```
   /usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh --cert "mycert" --force
   ```
4. Add this automation to the certificate

---

## OpenSSL Legacy Mode

OPNsense uses OpenSSL 3.x which defaults to modern encryption algorithms
(AES-256-CBC, PBKDF2, SHA256) for PKCS#12 files. Some older systems cannot
read these files:

| Symptom | Likely Cause | Solution |
|---------|-------------|----------|
| "Unsupported algorithm" on Windows | OpenVPN 2.6+ or Windows CryptoAPI rejects RC2 | Use `--legacy` flag |
| Java KeyStore import fails | Java 8 does not support PBES2 | Use `--legacy` flag |
| "Error: unsupported PKCS12 algorithm" | OpenSSL 1.x client | Use `--legacy` flag |

The `--legacy` flag adds OpenSSL's `-legacy` option, which uses the older
RC2-40-CBC / PKCS#12 v1.0 algorithms that are widely compatible.

For the configd action, use the **legacy** variant:
`Export certificate as PKCS#12 (.p12) legacy`

---

## File Locations Reference

### Where certificates live on OPNsense

| Path | Description |
|------|-------------|
| `/conf/config.xml` | OPNsense configuration — standard certs stored as base64 PEM |
| `/var/etc/acme-client/certs/<uuid>/` | ACME client certificate files (cert.pem, fullchain.pem, chain.pem) |
| `/var/etc/acme-client/keys/<uuid>/` | ACME client private keys (private.key) |
| `/var/etc/acme-client/home/<uuid_or_domain>/` | ACME client working directory |
| `/var/etc/acme-client/configs/<uuid>.conf` | ACME client config (contains `CERT_DOMAIN`) |
| `/root/cert-export/` | Default .p12 output directory (this project) |
| `/usr/local/www/cert-export/` | HTTP API download endpoint |

### Where this project's files live

| File | Description |
|------|-------------|
| `/usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh` | Main script |
| `/usr/local/opnsense/scripts/cert-to-p12/cert-export.php` | API download handler |
| `/usr/local/opnsense/service/conf/actions.d/actions_cert-to-p12.conf` | Configd action definition |

---

## Security Considerations

### Private Key Exposure

The .p12 file **contains the private key**. Treat it with the same care as
any TLS private key material:

- The output directory (`/root/cert-export/`) is readable only by `root`.
- The password file is `chmod 600`.
- The HTTP API endpoint requires a valid OPNsense API key/secret to access.
- The API endpoint does NOT serve directory listings.
- The PHP handler uses `hash_equals()` for timing-safe secret comparison.
- All PHP responses include `X-Content-Type-Options: nosniff` and
  `X-Frame-Options: DENY` headers.

### Recommendations

1. **Use HTTPS only** — the API key/secret are transmitted in clear text with
   Basic auth. OPNsense should always be accessed over HTTPS.
2. **Use API keys over query-string secrets** — Basic auth is less likely to
   appear in server logs than URL parameters.
3. **Rotate API keys periodically** — System → Access → Users.
4. **Restrict OPNsense API key permissions** — Create a dedicated user with
   minimal privileges if available.
5. **Consider IP whitelisting** — If your consumers have fixed IPs, add a
   firewall rule restricting access to the `/cert-export/` path.

### Known Limitations

- The PHP download handler loads API keys from config.xml on every request.
  This is O(users × keys) and is negligible for typical deployments.
- The password file is stored in plaintext alongside the .p12. If this is
  unacceptable, always provide `--password` explicitly and manage it
  through your own secrets infrastructure.

---

## Troubleshooting

### "Certificate not found in config.xml or ACME filesystem"

The script searches three sources in order:
1. `CERT_PATH`/`KEY_PATH` env vars (ACME deploy-hook)
2. `/conf/config.xml` (OPNsense trust store)
3. `/var/etc/acme-client/certs/` (ACME filesystem fallback)

If the certificate is managed by the ACME client but was never imported into
the OPNsense trust store, it will NOT appear in config.xml. The filesystem
fallback matches by UUID, CN, or SAN — use a domain name or substring that
appears in the certificate:

```bash
# For a Let's Encrypt cert for "first.dpova.cz":
cert-to-p12.sh --cert "first.dpova.cz"
cert-to-p12.sh --cert "dpova"        # substring of domain
```

**To list all ACME certificates on disk:**

```bash
for d in /var/etc/acme-client/certs/*/; do
  uuid=$(basename "$d")
  cn=$(openssl x509 -in "$d/cert.pem" -noout -subject 2>/dev/null | sed 's/.*CN = //;s/[,/].*//')
  echo "$uuid  $cn"
done
```

**To list all certificates in config.xml:**

```bash
awk '/<cert>/,/<\/cert>/ {
    if (/<refid>/)  { gsub(/.*<refid>/, ""); gsub(/<\/refid>.*/, ""); r=$0; }
    if (/<descr>/)  { gsub(/.*<descr>/, ""); gsub(/<\/descr>.*/, ""); d=$0; }
    if (/<\/cert>/) { print "refid: " r "  descr: " d; r=""; d=""; }
}' /conf/config.xml
```

### "openssl: command not found"

```bash
pkg install openssl
```

OpenSSL is typically pre-installed on OPNsense at `/usr/local/bin/openssl`.

### Configd action not showing up

```bash
service configd restart
configctl cert-to-p12 describe
```

If the action still doesn't appear, check the syntax of
`actions_cert-to-p12.conf` and verify it's in the correct directory.

### ACME automation fails silently

Check the ACME client log:

```bash
tail -f /var/log/acmeclient.log
```

Or run the configd action manually:

```bash
configctl cert-to-p12 export "your-cert-name"
```

### PHP download returns 500

Check the web server error log:

```bash
tail -f /var/log/lighttpd/error.log
```

Common issues:
- The PHP script has syntax errors — run `php -l /usr/local/www/cert-export/index.php`
- The `/root/cert-export/` directory doesn't exist or is not readable by the
  web server user (`www`). Note: lighttpd runs as `www` but `/root` is
  typically not accessible. The script uses a workaround by reading via PHP.
- If PHP cannot access `/root/cert-export/`, change the path in
  `cert-export.php` or run cert-to-p12.sh with `--outdir /tmp/cert-export`.

---

## Uninstallation

```bash
# Remove scripts
rm -rf /usr/local/opnsense/scripts/cert-to-p12

# Remove configd action
rm /usr/local/opnsense/service/conf/actions.d/actions_cert-to-p12.conf
service configd restart

# Remove PHP endpoint
rm -rf /usr/local/www/cert-export

# Remove exported files (careful!)
rm -rf /root/cert-export
```

---

## License

BSD-2-Clause. See LICENSE file.

## Support

This is a community project. For issues, please open a GitHub issue or post on
the [OPNsense Forum](https://forum.opnsense.org/).
