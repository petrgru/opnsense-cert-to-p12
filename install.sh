#!/bin/sh
# install.sh — One-command installer for OPNsense Certificate-to-P12 Exporter
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/petrgru/opnsense-cert-to-p12/master/install.sh | sh
#
# This script downloads the cert-to-p12 exporter files from GitHub and
# installs them into the correct OPNsense paths.

set -e

REPO="petrgru/opnsense-cert-to-p12"
BRANCH="master"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

if [ ! -d /usr/local/opnsense ]; then
    echo "WARNING: /usr/local/opnsense not found — this doesn't look like OPNsense."
    echo "         The files will still be installed but may not work correctly."
fi

SCRIPT_DST="/usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh"
PHP_DST="/usr/local/opnsense/scripts/cert-to-p12/cert-export.php"
CONFIGD_DST="/usr/local/opnsense/service/conf/actions.d/actions_cert-to-p12.conf"
PHP_WWW_DST="/usr/local/www/cert-export/index.php"

download() {
    url="$1"
    dest="$2"
    echo "  ↓ $url"
    mkdir -p "$(dirname "$dest")"
    # Use --fail so curl returns non-zero on HTTP 404/500 (not just network errors)
    curl -sSL --fail "$url" -o "$dest" || {
        echo "ERROR: Failed to download $url (HTTP error)" >&2
        exit 1
    }
    # Verify the file starts with the expected shebang (detect corrupted downloads)
    if [ "$(head -c 2 "$dest" 2>/dev/null)" != "#!" ] && [ "$(head -c 5 "$dest" 2>/dev/null)" != "<?php" ]; then
        echo "ERROR: Downloaded file $dest does not look valid (wrong content)" >&2
        exit 1
    fi
    echo "    → $dest ($(wc -c < "$dest") bytes)"
}

echo "=========================================="
echo " OPNsense Certificate-to-P12 Exporter"
echo " Installer"
echo "=========================================="
echo ""
echo "Repository: ${REPO} (${BRANCH})"
echo ""

echo "[1/4] Installing main export script..."
download "${BASE_URL}/usr/local/opnsense/scripts/cert-to-p12/cert-to-p12.sh" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"
echo "       ✓ Executable"
echo ""

echo "[2/4] Installing PHP API handler..."
download "${BASE_URL}/usr/local/opnsense/scripts/cert-to-p12/cert-export.php" "$PHP_DST"
download "${BASE_URL}/usr/local/opnsense/scripts/cert-to-p12/cert-export.php" "$PHP_WWW_DST"
echo ""

echo "[3/4] Installing configd action..."
download "${BASE_URL}/usr/local/opnsense/service/conf/actions.d/actions_cert-to-p12.conf" "$CONFIGD_DST"
echo ""

echo "[4/4] Registering configd action..."
if service configd restart 2>/dev/null; then
    echo "       ✓ configd restarted"
else
    echo "       ! configd restart failed (will be picked up on next boot)"
fi
echo ""

echo "=========================================="
echo " Verification"
echo "=========================================="
echo ""

check_file() {
    path="$1"
    if [ -f "$path" ]; then
        size=$(wc -c < "$path")
        echo "  ✓ $path ($size bytes)"
    else
        echo "  ✗ $path — MISSING!"
    fi
}

check_file "$SCRIPT_DST"
check_file "$PHP_DST"
check_file "$CONFIGD_DST"
check_file "$PHP_WWW_DST"

echo ""

if command -v configctl >/dev/null 2>&1; then
    echo "Configd actions registered:"
    configctl cert-to-p12 describe 2>&1 || echo "  (not yet — try service configd restart)"
fi

echo ""
echo "=========================================="
echo " Installation complete!"
echo ""
echo " Quick test:"
echo "   cert-to-p12.sh --cert webgui"
echo ""
echo " For ACME automations:"
echo "   System → Access → Users → API keys"
echo "   Services → ACME Client → Certificates → Automations"
echo ""
echo " Documentation:"
echo "   https://github.com/${REPO}#readme"
echo "=========================================="
