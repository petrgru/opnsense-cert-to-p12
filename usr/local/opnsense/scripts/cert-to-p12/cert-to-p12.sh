#!/bin/sh
set -e

OUTDIR="/root/cert-export"
P12_PASSWORD=""
CERT_SPEC=""
USE_LEGACY=0
FORCE=0
QUIET=0

CONFIG_XML="/conf/config.xml"
OPENSSL="/usr/local/bin/openssl"

log() { [ "$QUIET" -eq 0 ] && echo "[cert-to-p12] $*"; }
warn() { echo "[cert-to-p12] WARNING: $*" >&2; }
die() { echo "[cert-to-p12] ERROR: $*" >&2; exit "${2:-1}"; }

usage() {
    cat <<'HELPEOF'
USAGE: cert-to-p12.sh --cert <refid|name> [options]

REQUIRED:
  --cert <refid|name>   Certificate refid (UUID) or substring of the
                        certificate description as shown in the web GUI.
                        ACME certificates on disk are matched by UUID,
                        subject CN, or SAN (case-insensitive).  Exact
                        matches are preferred over substring matches.

OPTIONS:
  --password <pw>       Password to encrypt the .p12 file.
                        Auto-generated (32 chars) if omitted.
  --outdir <dir>        Output directory (default: /root/cert-export).

  --legacy              Add OpenSSL -legacy flag for compatibility with
                        older systems (Windows, Java 8, OpenSSL 1.x).
  --force               Overwrite existing .p12 file silently.
  --quiet               Suppress informational output.
  --help                Show this message.

EXAMPLES:
  cert-to-p12.sh --cert "webgui"
  cert-to-p12.sh --cert "a1b2c3d4e5f6" --password "mySecret"
  cert-to-p12.sh --cert "letsencrypt" --outdir /tmp --legacy
  cert-to-p12.sh --cert "mycert" --force --quiet
  cert-to-p12.sh --cert "example.com"      (match ACME cert by domain)

EXIT CODES:
  0  Success
  1  Certificate not found
  2  Missing dependency
  3  OpenSSL error
  4  Invalid argument
  5  Output exists and --force not given
HELPEOF
    exit 0
}

# -----------------------------------------------
# ACME filesystem fallback search
# Searches /var/etc/acme-client/certs/ for certs
# matching --cert <spec> by UUID, CN, SAN, or domain
# -----------------------------------------------
find_acme_cert_on_disk() {
    _spec="$1"
    _acme_certs="/var/etc/acme-client/certs"
    _acme_keys="/var/etc/acme-client/keys"
    _acme_configs="/var/etc/acme-client/configs"

    [ -d "$_acme_certs" ] || return 1

    _lc_spec=$(echo "$_spec" | tr '[:upper:]' '[:lower:]')

    _exact_match() { _v=$(echo "$1" | tr '[:upper:]' '[:lower:]'); [ "$_v" = "$_lc_spec" ]; }
    _substr_match() { echo "$1" | grep -qiF "$_spec" >/dev/null 2>&1; }

    # Phase 1: exact matches are preferred (avoid ambiguous substring matches)
    for _cert_dir in "$_acme_certs"/*/; do
        [ -f "${_cert_dir}cert.pem" ] || continue
        _uuid="$(basename "$_cert_dir")"

        _subject=$(${OPENSSL} x509 -in "${_cert_dir}cert.pem" -noout -subject 2>/dev/null) || continue
        _cn=$(echo "$_subject" | sed 's/.*CN = //;s/[,/].*//')
        [ -z "$_cn" ] && _cn="(no CN)"

        _sans=$(${OPENSSL} x509 -in "${_cert_dir}cert.pem" -noout -ext subjectAltName 2>/dev/null | \
                grep 'DNS:' | sed 's/DNS://g; s/,/\n/g; s/ //g' 2>/dev/null)

        _domain=""
        [ -f "${_acme_configs}/${_uuid}.conf" ] && \
            _domain=$(grep '^CERT_DOMAIN=' "${_acme_configs}/${_uuid}.conf" 2>/dev/null | cut -d= -f2)

        _home=""
        [ -d "/var/etc/acme-client/home/$_uuid" ] && \
            _home=$(basename "/var/etc/acme-client/home/$_uuid")

        if _exact_match "$_uuid" || _exact_match "$_cn" || \
           _exact_match "$_domain" || _exact_match "$_home"; then
            _select_acme_cert "$_cert_dir" "$_uuid" "$_cn" "$_sans" "$_domain"
            return $?
        fi
        # Exact-match each SAN individually (multi-value field)
        if [ -n "$_sans" ]; then
            _matched=0
            for _san_entry in $_sans; do
                _exact_match "$_san_entry" && { _matched=1; break; }
            done
            [ "$_matched" = "1" ] && {
                _select_acme_cert "$_cert_dir" "$_uuid" "$_cn" "$_sans" "$_domain"
                return $?
            }
        fi
    done

    # Phase 2: substring matches (original fallback behavior)
    for _cert_dir in "$_acme_certs"/*/; do
        [ -f "${_cert_dir}cert.pem" ] || continue
        _uuid="$(basename "$_cert_dir")"

        _subject=$(${OPENSSL} x509 -in "${_cert_dir}cert.pem" -noout -subject 2>/dev/null) || continue
        _cn=$(echo "$_subject" | sed 's/.*CN = //;s/[,/].*//')
        [ -z "$_cn" ] && _cn="(no CN)"

        _sans=$(${OPENSSL} x509 -in "${_cert_dir}cert.pem" -noout -ext subjectAltName 2>/dev/null | \
                grep 'DNS:' | sed 's/DNS://g; s/,/\n/g; s/ //g' 2>/dev/null)

        _domain=""
        [ -f "${_acme_configs}/${_uuid}.conf" ] && \
            _domain=$(grep '^CERT_DOMAIN=' "${_acme_configs}/${_uuid}.conf" 2>/dev/null | cut -d= -f2)

        _home=""
        [ -d "/var/etc/acme-client/home/$_uuid" ] && \
            _home=$(basename "/var/etc/acme-client/home/$_uuid")

        if _substr_match "$_uuid" || _substr_match "$_cn" || \
           _substr_match "$_sans" || _substr_match "$_domain" || \
           _substr_match "$_home"; then
            _select_acme_cert "$_cert_dir" "$_uuid" "$_cn" "$_sans" "$_domain"
            return $?
        fi
    done

    return 1
}

_select_acme_cert() {
    _cert_dir="$1"
    _uuid="$2"
    _cn="$3"
    _sans="$4"
    _domain="$5"

    # Locate certificate file — prefer fullchain.pem (includes intermediates)
    PEM_CERT="${_cert_dir}fullchain.pem"
    [ -f "$PEM_CERT" ] || PEM_CERT="${_cert_dir}cert.pem"
    [ -f "$PEM_CERT" ] || return 1

    # Locate private key
    PEM_KEY="${_acme_keys}/${_uuid}/private.key"
    [ -f "$PEM_KEY" ] || PEM_KEY="${_cert_dir}privkey.key"
    [ -f "$PEM_KEY" ] || return 1

    # Locate CA chain file (optional)
    CHAIN_FILE="${_cert_dir}chain.pem"
    [ -f "$CHAIN_FILE" ] || CHAIN_FILE=""

    CERT_NAME="$_uuid"
    CERT_REFID="$_uuid"

    log "Found ACME certificate: $_uuid"
    log "  CN:        $_cn"
    log "  SANs:      $(echo "$_sans" | tr '\n' ' ')"
    [ -n "$_domain" ] && log "  Domain:    $_domain"
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cert)
            [ -z "$2" ] && die "Missing value for --cert" 4
            CERT_SPEC="$2"; shift 2 ;;
        --password)
            [ -z "$2" ] && die "Missing value for --password" 4
            P12_PASSWORD="$2"; shift 2 ;;
        --outdir)
            [ -z "$2" ] && die "Missing value for --outdir" 4
            OUTDIR="$2"; shift 2 ;;
        --legacy)    USE_LEGACY=1; shift ;;
        --force)     FORCE=1; shift ;;
        --quiet)     QUIET=1; shift ;;
        --help|-h)   usage ;;
        *) die "Unknown option: $1. Use --help." 4 ;;
    esac
done

[ -z "$CERT_SPEC" ] && die "Missing --cert <refid|name>" 4
[ -f "$CONFIG_XML" ] || die "config.xml not found: $CONFIG_XML" 1

PEM_CERT=""
PEM_KEY=""
CERT_NAME=""
CERT_REFID=""

if [ -n "$CERT_PATH" ] && [ -n "$KEY_PATH" ] && [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
    log "ACME deploy-hook context via CERT_PATH/KEY_PATH"
    PEM_CERT="$CERT_PATH"
    PEM_KEY="$KEY_PATH"
    CERT_NAME="$(basename "$(dirname "$CERT_PATH")")"
fi

if [ -z "$PEM_CERT" ]; then
    log "Searching config.xml for: $CERT_SPEC"

    AWK_SCRIPT='
    BEGIN { in_cert=0; found=0; refid=""; descr=""; crt=""; prv=""; spec=spec_arg; }
    /<cert>/ { in_cert=1; refid=""; descr=""; crt=""; prv=""; }
    /<\/cert>/ {
        in_cert=0;
        if (found) {
            print "REFID=" refid;
            print "DESCR=" descr;
            print "CRT=" crt;
            print "PRV=" prv;
            exit;
        }
    }
    in_cert {
        if (/<refid>/) { gsub(/.*<refid>/, ""); gsub(/<\/refid>.*/, ""); refid=$0; if (refid==spec) found=1; }
        if (/<descr>/) { gsub(/.*<descr>/, ""); gsub(/<\/descr>.*/, ""); descr=$0; if (!found && index(tolower($0), tolower(spec)) > 0) found=1; }
        if (/<crt>/)   { gsub(/.*<crt>/, "");   gsub(/<\/crt>.*/, "");   crt=$0; }
        if (/<prv>/)   { gsub(/.*<prv>/, "");   gsub(/<\/prv>.*/, "");   prv=$0; }
    }
    END { if (!found) exit 1; }
    '

    CERT_DATA=$(awk -v spec_arg="$CERT_SPEC" "$AWK_SCRIPT" "$CONFIG_XML") || \
        CONFIG_NOT_FOUND=1

    if [ -z "$CONFIG_NOT_FOUND" ]; then
        eval "$CERT_DATA"
        if [ -n "$CRT" ] && [ -n "$PRV" ]; then
            CERT_NAME="${DESCR:-$REFID}"
            CERT_REFID="$REFID"
            log "Found: '$DESCR' (refid: $REFID)"

            WORKDIR=$(mktemp -d /tmp/cert-to-p12.XXXXXX)
            trap "rm -rf ${WORKDIR}" EXIT

            crt_clean=$(echo "$CRT" | sed 's/[[:space:]]//g')
            prv_clean=$(echo "$PRV" | sed 's/[[:space:]]//g')

            { echo "-----BEGIN CERTIFICATE-----"
              echo "$crt_clean" | sed 's/.\{64\}/&\n/g'
              echo ""; echo "-----END CERTIFICATE-----"
            } > "${WORKDIR}/cert.pem"

            { echo "-----BEGIN PRIVATE KEY-----"
              echo "$prv_clean" | sed 's/.\{64\}/&\n/g'
              echo ""; echo "-----END PRIVATE KEY-----"
            } > "${WORKDIR}/key.pem"

            PEM_CERT="${WORKDIR}/cert.pem"
            PEM_KEY="${WORKDIR}/key.pem"
        else
            CONFIG_NOT_FOUND=1
        fi
    fi
fi

# --- Path 3: ACME filesystem fallback ---
if [ -z "$PEM_CERT" ]; then
    log "Searching ACME certificates on filesystem..."
    find_acme_cert_on_disk "$CERT_SPEC" || \
        die "Certificate matching '$CERT_SPEC' not found in config.xml or ACME filesystem" 1
fi

${OPENSSL} x509 -in "$PEM_CERT" -noout -subject -dates >/dev/null 2>&1 || die "Invalid cert PEM" 3
${OPENSSL} pkey -in "$PEM_KEY" -noout >/dev/null 2>&1 || \
    ${OPENSSL} rsa -in "$PEM_KEY" -noout >/dev/null 2>&1 || die "Invalid key PEM" 3

# Verify certificate and private key match by comparing their public keys.
# This works for both RSA and EC keys (unlike modulus comparison which only
# works for RSA and compares hex strings against PEM hashes).
cert_pubkey=$(${OPENSSL} x509 -in "$PEM_CERT" -noout -pubkey 2>/dev/null) || \
    die "Unable to read certificate public key" 3
key_pubkey=$(${OPENSSL} pkey -in "$PEM_KEY" -pubout 2>/dev/null) || \
    die "Unable to read private key public key" 3
if [ "$cert_pubkey" != "$key_pubkey" ]; then
    warn "Certificate and private key do not match!"
    [ "$FORCE" -eq 0 ] && die "Use --force to override." 3
fi

if [ -z "$P12_PASSWORD" ]; then
    P12_PASSWORD=$(${OPENSSL} rand -base64 32 | tr -d '=+/' | head -c 32)
    [ -z "$P12_PASSWORD" ] && P12_PASSWORD=$(date +%s | ${OPENSSL} sha256 | head -c 32)
fi

mkdir -p "$OUTDIR"
sanitized_name=$(echo "$CERT_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g; s/^_//; s/_$//')
[ -z "$sanitized_name" ] && sanitized_name="certificate"
P12_FILE="${OUTDIR}/${sanitized_name}.p12"
PASSWORD_FILE="${OUTDIR}/${sanitized_name}.password"

[ -f "$P12_FILE" ] && [ "$FORCE" -eq 0 ] && die "Output exists: $P12_FILE (use --force)" 5

# Only look up issuing CA from config.xml when cert came from config.xml
# (ACME filesystem certs already provide chain via fullchain.pem or chain.pem)
if [ -z "$CONFIG_NOT_FOUND" ]; then
    CHAIN_FILE=""
    if [ -n "$CERT_REFID" ]; then
        caref=$(awk -v refid="$CERT_REFID" '
        BEGIN { in_c=0; }
        /<cert>/,/<\/cert>/ {
            if (/<cert>/) { in_c=1; c_ref=""; ca=""; }
            if (/<\/cert>/) { in_c=0; }
            in_c {
                if (/<refid>/)  { gsub(/.*<refid>/, ""); gsub(/<\/refid>.*/, ""); c_ref=$0; }
                if (/<caref>/)  { gsub(/.*<caref>/, ""); gsub(/<\/caref>.*/, ""); ca=$0; }
            }
            if (c_ref==refid && ca!="") { print ca; exit; }
        }' "$CONFIG_XML" 2>/dev/null)

        if [ -n "$caref" ]; then
            log "Including issuing CA (refid: $caref)..."
            ca_crt=$(awk -v refid="$caref" '
            BEGIN { in_c=0; }
            /<ca>/,/<\/ca>/ {
                if (/<ca>/) { in_c=1; c=""; cr=""; }
                if (/<\/ca>/) { in_c=0; }
                in_c {
                    if (/<refid>/) { gsub(/.*<refid>/, ""); gsub(/<\/refid>.*/, ""); c=$0; }
                    if (/<crt>/)   { gsub(/.*<crt>/, "");   gsub(/<\/crt>.*/, "");   cr=$0; }
                }
                if (c==refid && cr!="") { print cr; exit; }
            }' "$CONFIG_XML" 2>/dev/null)

            if [ -n "$ca_crt" ]; then
                CHAIN_FILE="${WORKDIR}/chain.pem"
                ca_clean=$(echo "$ca_crt" | sed 's/[[:space:]]//g')
                { echo "-----BEGIN CERTIFICATE-----"
                  echo "$ca_clean" | sed 's/.\{64\}/&\n/g'
                  echo ""; echo "-----END CERTIFICATE-----"
                } > "$CHAIN_FILE"
            fi
        fi
    fi
fi

log "Generating: $P12_FILE"
legacy_flag=""; [ "$USE_LEGACY" -eq 1 ] && legacy_flag="-legacy"

openssl_cmd="${OPENSSL} pkcs12 -export ${legacy_flag}"
openssl_cmd="${openssl_cmd} -in \"${PEM_CERT}\" -inkey \"${PEM_KEY}\""
[ -n "$CHAIN_FILE" ] && openssl_cmd="${openssl_cmd} -certfile \"${CHAIN_FILE}\""
openssl_cmd="${openssl_cmd} -name \"${sanitized_name}\""
openssl_cmd="${openssl_cmd} -passout pass:\"${P12_PASSWORD}\""
openssl_cmd="${openssl_cmd} -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg SHA256"
openssl_cmd="${openssl_cmd} -out \"${P12_FILE}\""

eval "$openssl_cmd" 2>/dev/null || {
    log "Falling back to default encryption..."
    fallback="${OPENSSL} pkcs12 -export ${legacy_flag}"
    fallback="${fallback} -in \"${PEM_CERT}\" -inkey \"${PEM_KEY}\""
    [ -n "$CHAIN_FILE" ] && fallback="${fallback} -certfile \"${CHAIN_FILE}\""
    fallback="${fallback} -name \"${sanitized_name}\""
    fallback="${fallback} -passout pass:\"${P12_PASSWORD}\""
    fallback="${fallback} -out \"${P12_FILE}\""
    eval "$fallback" 2>/dev/null || die "OpenSSL pkcs12 export failed" 3
}

${OPENSSL} pkcs12 -in "$P12_FILE" -passin pass:"$P12_PASSWORD" -noout >/dev/null 2>&1 || \
    warn "Generated .p12 failed verification"

echo "$P12_PASSWORD" > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE" "$P12_FILE" 2>/dev/null || true

subject=$(${OPENSSL} x509 -in "$PEM_CERT" -noout -subject)
valid_from=$(${OPENSSL} x509 -in "$PEM_CERT" -noout -startdate | sed 's/notBefore=//')
valid_to=$(${OPENSSL} x509 -in "$PEM_CERT" -noout -enddate | sed 's/notAfter=//')

log "============================================================"
log "Certificate exported successfully!"
log "  Name:     ${CERT_NAME}"
log "  Ref ID:   ${CERT_REFID:-N/A}"
log "  Subject:  ${subject}"
log "  Valid:    ${valid_from}  ->  ${valid_to}"
log "  P12:      ${P12_FILE}"
log "  Pass:     ${P12_PASSWORD}"
log "  (file:    ${PASSWORD_FILE})"
log "============================================================"

echo "CERT_P12_FILE=${P12_FILE}"
echo "CERT_P12_PASSWORD=${P12_PASSWORD}"
exit 0
