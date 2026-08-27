# Deployment

## Local (development)

```bash
git clone https://github.com/tech-dra-kbj/KSeF-RSA-Encryptor-API.git
cd KSeF-RSA-Encryptor-API

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

python encrypt_service.py
```

Service: `http://localhost:5000`  
Swagger UI: `http://localhost:5000/apidocs`

Node.js 20+ must be installed and `pdf-generator/dist/` must contain the visualizer bundle.

---

## Gunicorn (production)

```bash
gunicorn --workers 3 --threads 2 --bind 0.0.0.0:5000 encrypt_service:app
```

---

## systemd

```bash
sudo nano /etc/systemd/system/ksef-encryptor.service
```

```ini
[Unit]
Description=KSeF Integration API
After=network.target

[Service]
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/KSeF-RSA-Encryptor-API

# Required if Node.js is installed via nvm
Environment="KSEF_NODE_BIN=/home/ubuntu/.nvm/versions/node/v20.20.2/bin/node"
Environment="PATH=/home/ubuntu/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin"

Environment="PORT=5000"
Environment="WORKERS=3"
Environment="THREADS=2"
ExecStart=/home/ubuntu/KSeF-RSA-Encryptor-API/.venv/bin/gunicorn --workers ${WORKERS} --threads ${THREADS} --bind 0.0.0.0:${PORT} encrypt_service:app
Restart=always
RestartSec=5
StandardOutput=append:/var/log/encrypt_service.log
StandardError=append:/var/log/encrypt_service.err

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable ksef-encryptor.service
sudo systemctl start ksef-encryptor.service
sudo systemctl status ksef-encryptor.service
```

---

## Docker Compose

The recommended setup runs **two services simultaneously** on the same machine:

| Service | Port | Image tag | Workers |
|---|---|---|---|
| Production | `5000` | `ksef-integration-api:stable` | 3 |
| Development | `5001` | `ksef-integration-api:latest` | 2 |

Use `-p` (project name) so each stack gets its own network and container namespace and they do not overwrite each other.

### Start both services

```bash
# Production
docker compose -p ksef-prod -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d

# Development
docker compose -p ksef-dev -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d
```

Verify both are running:
```bash
docker ps --filter name=ksef
```

Expected:
```
ksef-encryptor      ksef-integration-api:stable   0.0.0.0:5000->5000/tcp
ksef-encryptor-dev  ksef-integration-api:latest   0.0.0.0:5001->5000/tcp
```

### Build images before starting

```bash
# Stable image for prod
docker build -t ksef-integration-api:stable .

# Latest image for dev (or use --build flag)
docker build -t ksef-integration-api:latest .
```

Or let compose build on the fly with `--build`:
```bash
docker compose -p ksef-prod -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d --build
docker compose -p ksef-dev  -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d --build
```

### Stop

```bash
docker compose -p ksef-prod down
docker compose -p ksef-dev down
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `5000` | Internal container port |
| `WORKERS` | `3` | Gunicorn worker processes |
| `THREADS` | `2` | Threads per worker |
| `KEY_DB_PATH` | `instance/keys.db` | SQLite key database path |
| `KEY_TTL_SECONDS` | `86400` | Key TTL in seconds (24h) |
| `KSEF_NODE_BIN` | `node` | Path to Node.js binary |
| `KSEF_PDF_BRIDGE_PATH` | `./pdf_generator_bridge.mjs` | Node.js PDF bridge path |
| `KSEF_PDF_MODULE_PATH` | `./pdf-generator/dist/ksef-fe-invoice-converter.js` | PDF generator module path |
| `KSEF_PDF_TIMEOUT_SECONDS` | `60` | PDF generation timeout (seconds) |

---

## Docker — offline deployment (no repo access)

Build and export image as a tar archive:

```bash
# produces ksef-integration-api_stable.tar
./docker/build-image.sh stable
```

Transfer to target machine and load:

```bash
docker load -i ksef-integration-api_stable.tar
docker compose -p ksef-prod -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d
```


---

## TLS (production)

An optional third container terminates TLS in front of the API. It is an
**additive overlay** — it changes nothing in the existing compose files, and the
application container keeps publishing port 5000 on the host exactly as before.

```bash
docker compose -p ksef-prod \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.prod.yml \
  -f docker/docker-compose.ssl.yml up -d
```

This adds `ksef-ssl-proxy` (nginx-alpine, ~85 MB) listening on 443, with 80
redirecting to it. Traffic is forwarded to `ksef-encryptor:5000` over the
compose network.

### Certificates

The proxy provisions its own material on first start and writes it to
`docker/certs/` on the host, so it survives redeploys and can be collected:

```
docker/certs/
├── ca.crt        <- give this to clients so they trust the service
├── ca.key        <- 0600, keep on the server
├── server.crt    <- issued by the CA above, SAN covers domain + IPs
└── server.key    <- 0600
```

On every subsequent start an existing `server.crt`/`server.key` pair is
**reused**, never regenerated. To use a certificate from your own PKI instead,
place it in that directory before the first start — the proxy detects it, leaves
it alone, and does not create a CA. An expired certificate is renewed
automatically only when the local CA issued it; anything else is left untouched
with a warning, so a bring-your-own certificate is never silently replaced.

A certificate and key that do not belong to the same pair abort startup with an
explicit error rather than letting nginx fail obscurely.

### Configuration

Set these before `up`, e.g. in a `.env` file next to the compose files:

| Variable | Default | Description |
|---|---|---|
| `KSEF_SSL_DOMAIN` | `localhost` | Certificate CN and nginx `server_name`. Must match the name clients use. |
| `KSEF_SSL_DNS` | — | Extra DNS names for the SAN, comma-separated |
| `KSEF_SSL_IPS` | `127.0.0.1` | IP addresses for the SAN, comma-separated |
| `KSEF_SSL_PROTOCOLS` | `TLSv1.2 TLSv1.3` | Set to `TLSv1.2` to pin that version exclusively |
| `KSEF_SSL_CIPHERS` | see below | TLS 1.2 cipher list; empty means the built-in default |
| `KSEF_SSL_MAX_BODY` | `15m` | Request body limit |
| `KSEF_SSL_CERT_DAYS` | `825` | Validity of a generated server certificate |

The certificate is bound to `KSEF_SSL_DOMAIN` and the SAN entries, so set them
before the first start:

```bash
KSEF_SSL_DOMAIN=api.example.com KSEF_SSL_IPS=10.0.0.5,127.0.0.1 \
  docker compose -p ksef-prod \
    -f docker/docker-compose.yml \
    -f docker/docker-compose.prod.yml \
    -f docker/docker-compose.ssl.yml up -d
```

Changing the domain later requires deleting `docker/certs/server.crt` and
`server.key` so a new pair is issued; keeping `ca.crt` and `ca.key` means
clients that already trust the CA need no update.

### TLS versions and ciphers

TLS 1.2 is the primary target. TLS 1.3 stays enabled because a 1.2-only client
simply negotiates down; TLS 1.0 and 1.1 are refused. `ssl_ciphers` applies to
**TLS 1.2 and below only** — TLS 1.3 suites are fixed by OpenSSL and cannot be
configured there. The default list is ECDHE-only (forward secrecy throughout)
and ends with CBC-SHA suites for older Java/SAP stacks that offer no AEAD suite:

```
ECDHE-ECDSA-AES256-GCM-SHA384   ECDHE-RSA-AES256-GCM-SHA384
ECDHE-ECDSA-AES128-GCM-SHA256   ECDHE-RSA-AES128-GCM-SHA256
ECDHE-ECDSA-CHACHA20-POLY1305   ECDHE-RSA-CHACHA20-POLY1305
ECDHE-ECDSA-AES256-SHA384       ECDHE-RSA-AES256-SHA384
ECDHE-ECDSA-AES128-SHA256       ECDHE-RSA-AES128-SHA256
```

DHE suites are deliberately absent: nginx disables them unless `ssl_dhparam` is
configured, so listing them would advertise something the server never offers.
A client that genuinely needs DHE requires generated DH parameters and an
`ssl_dhparam` directive in `docker/proxy/nginx.conf.template`.

Verify what a client actually negotiates:

```bash
openssl s_client -connect api.example.com:443 -tls1_2 -CAfile docker/certs/ca.crt
```

### Distributing the CA

Clients must trust `docker/certs/ca.crt`. For example:

```bash
# Linux (Debian/Ubuntu)
sudo cp ca.crt /usr/local/share/ca-certificates/ksef-api.crt && sudo update-ca-certificates

# curl, ad hoc
curl --cacert ca.crt https://api.example.com/health
```

> This is separate from `setup-ssl.sh`, which puts Nginx and a Let's Encrypt
> certificate on the **host** and needs a public domain. Use that when the
> service is publicly reachable and clients should not install anything; use the
> proxy container for internal deployments.
