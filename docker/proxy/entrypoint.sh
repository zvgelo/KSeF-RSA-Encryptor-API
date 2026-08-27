#!/bin/sh
# TLS certificate provisioning for the KSeF Integration API proxy.
#
# Reuses whatever is already in the certificate directory and only generates a
# self-signed CA plus server certificate when there is nothing usable there.
# The directory is a mounted volume, so the material — in particular ca.crt,
# which clients need in order to trust this service — is readable from the host
# and survives redeploys.
set -eu

CERT_DIR="${KSEF_SSL_CERT_DIR:-/etc/nginx/certs}"
DOMAIN="${KSEF_SSL_DOMAIN:-localhost}"
ALT_DNS="${KSEF_SSL_DNS:-}"
ALT_IPS="${KSEF_SSL_IPS:-127.0.0.1}"
CA_DAYS="${KSEF_SSL_CA_DAYS:-3650}"
CERT_DAYS="${KSEF_SSL_CERT_DAYS:-825}"

CA_KEY="${CERT_DIR}/ca.key"
CA_CRT="${CERT_DIR}/ca.crt"
SRV_KEY="${CERT_DIR}/server.key"
SRV_CRT="${CERT_DIR}/server.crt"

log() { echo "[ssl-proxy] $*"; }

# ── helpers ───────────────────────────────────────────────────────────────────

# Subject Alternative Name list: the domain always, plus any extra DNS names and
# IP addresses. Clients validate against this, so a missing entry here is the
# usual cause of a hostname-mismatch error.
build_san() {
    san="DNS:${DOMAIN}"

    for name in $(echo "${ALT_DNS}" | tr ',' ' '); do
        [ -n "${name}" ] && [ "${name}" != "${DOMAIN}" ] && san="${san},DNS:${name}"
    done

    for ip in $(echo "${ALT_IPS}" | tr ',' ' '); do
        [ -n "${ip}" ] && san="${san},IP:${ip}"
    done

    echo "${san}"
}

# A certificate and key belong together only if their public keys match.
# Catches a half-copied bring-your-own pair before nginx fails to start.
key_matches_cert() {
    _c=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null) || return 1
    _k=$(openssl pkey -in "$2" -pubout 2>/dev/null | openssl sha256 2>/dev/null) || return 1
    [ -n "${_c}" ] && [ "${_c}" = "${_k}" ]
}

# True when the certificate was issued by the CA in this directory, i.e. we
# generated it ourselves and may replace it. A bring-your-own certificate is
# never overwritten.
issued_by_our_ca() {
    [ -f "${CA_CRT}" ] || return 1
    _issuer=$(openssl x509 -in "${SRV_CRT}" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    _subject=$(openssl x509 -in "${CA_CRT}" -noout -subject 2>/dev/null | sed 's/^subject=//')
    [ -n "${_issuer}" ] && [ "${_issuer}" = "${_subject}" ]
}

describe_cert() {
    log "  subject : $(openssl x509 -in "$1" -noout -subject | sed 's/^subject=//')"
    log "  issuer  : $(openssl x509 -in "$1" -noout -issuer  | sed 's/^issuer=//')"
    log "  expires : $(openssl x509 -in "$1" -noout -enddate | sed 's/^notAfter=//')"
    log "  SAN     : $(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')"
    log "  SHA-256 : $(openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^.*=//')"
}

generate_ca() {
    if [ -f "${CA_KEY}" ] && [ -f "${CA_CRT}" ]; then
        log "Reusing existing CA: ${CA_CRT}"
        return
    fi

    log "Generating self-signed CA (valid ${CA_DAYS} days)"
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
        -keyout "${CA_KEY}" -out "${CA_CRT}" -days "${CA_DAYS}" \
        -subj "/C=PL/O=KSeF Integration API/CN=KSeF Integration API Local CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

    chmod 600 "${CA_KEY}"
    chmod 644 "${CA_CRT}"
}

generate_server_cert() {
    san=$(build_san)

    log "Generating server certificate (valid ${CERT_DAYS} days)"
    log "  CN  : ${DOMAIN}"
    log "  SAN : ${san}"

    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "${SRV_KEY}" -out "${CERT_DIR}/server.csr" \
        -subj "/C=PL/O=KSeF Integration API/CN=${DOMAIN}" 2>/dev/null

    openssl x509 -req -in "${CERT_DIR}/server.csr" \
        -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
        -out "${SRV_CRT}" -days "${CERT_DAYS}" -sha256 \
        -extfile - <<EOF 2>/dev/null
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san}
EOF

    rm -f "${CERT_DIR}/server.csr"
    chmod 600 "${SRV_KEY}"
    chmod 644 "${SRV_CRT}"
}

# ── provisioning ──────────────────────────────────────────────────────────────

mkdir -p "${CERT_DIR}"

if [ -f "${SRV_CRT}" ] && [ -f "${SRV_KEY}" ]; then
    if ! key_matches_cert "${SRV_CRT}" "${SRV_KEY}"; then
        log "ERROR: ${SRV_CRT} and ${SRV_KEY} do not belong to the same key pair."
        log "       Remove both to have a new self-signed pair generated, or fix the mount."
        exit 1
    fi

    if openssl x509 -in "${SRV_CRT}" -noout -checkend 0 >/dev/null 2>&1; then
        log "Reusing existing certificate: ${SRV_CRT}"
        describe_cert "${SRV_CRT}"
    elif issued_by_our_ca; then
        log "Existing certificate expired and was issued by the local CA — regenerating."
        generate_ca
        generate_server_cert
        describe_cert "${SRV_CRT}"
    else
        log "WARNING: ${SRV_CRT} has expired and was not issued by the local CA."
        log "         Leaving it untouched — replace it with a valid certificate."
        describe_cert "${SRV_CRT}"
    fi
else
    log "No certificate in ${CERT_DIR} — provisioning a new one."
    generate_ca
    generate_server_cert
    describe_cert "${SRV_CRT}"
fi

if [ -f "${CA_CRT}" ]; then
    log ""
    log "Distribute this CA to clients so they trust the service:"
    log "  ${CERT_DIR}/ca.crt  (mounted on the host, see docker-compose.ssl.yml)"
    log ""
fi

# ── nginx config ──────────────────────────────────────────────────────────────
# Only the listed variables are substituted; nginx's own $host, $remote_addr and
# friends must survive untouched.
export KSEF_SSL_DOMAIN="${DOMAIN}"
export KSEF_SSL_UPSTREAM="${KSEF_SSL_UPSTREAM:-ksef-encryptor:5000}"
export KSEF_SSL_MAX_BODY="${KSEF_SSL_MAX_BODY:-15m}"
export KSEF_SSL_RESOLVER="${KSEF_SSL_RESOLVER:-127.0.0.11}"

# TLS 1.2 is the primary target; 1.3 is left on so it can be negotiated when the
# client supports it. Nothing below 1.2 is offered.
export KSEF_SSL_PROTOCOLS="${KSEF_SSL_PROTOCOLS:-TLSv1.2 TLSv1.3}"

# TLS 1.2 cipher suites, strongest first. Forward secrecy throughout; the
# trailing CBC-SHA entries exist for older clients with no AEAD support.
# ECDHE only: nginx silently disables DHE suites unless ssl_dhparam is set, so
# listing them would advertise something the server never actually offers.
# To support a client that needs DHE, generate DH parameters and add an
# ssl_dhparam directive to the template alongside the DHE suites.
export KSEF_SSL_CIPHERS="${KSEF_SSL_CIPHERS:-\
ECDHE-ECDSA-AES256-GCM-SHA384:\
ECDHE-RSA-AES256-GCM-SHA384:\
ECDHE-ECDSA-AES128-GCM-SHA256:\
ECDHE-RSA-AES128-GCM-SHA256:\
ECDHE-ECDSA-CHACHA20-POLY1305:\
ECDHE-RSA-CHACHA20-POLY1305:\
ECDHE-ECDSA-AES256-SHA384:\
ECDHE-RSA-AES256-SHA384:\
ECDHE-ECDSA-AES128-SHA256:\
ECDHE-RSA-AES128-SHA256}"
export KSEF_SSL_READ_TIMEOUT="${KSEF_SSL_READ_TIMEOUT:-120s}"
export KSEF_SSL_CERT_DIR="${CERT_DIR}"

envsubst '${KSEF_SSL_DOMAIN} ${KSEF_SSL_UPSTREAM} ${KSEF_SSL_MAX_BODY} ${KSEF_SSL_READ_TIMEOUT} ${KSEF_SSL_CERT_DIR} ${KSEF_SSL_PROTOCOLS} ${KSEF_SSL_CIPHERS} ${KSEF_SSL_RESOLVER}' \
    < /etc/nginx/templates/default.conf.template \
    > /etc/nginx/conf.d/default.conf

nginx -t

log "Proxying https://${DOMAIN} -> ${KSEF_SSL_UPSTREAM}"
log "TLS protocols: ${KSEF_SSL_PROTOCOLS}"

exec "$@"
