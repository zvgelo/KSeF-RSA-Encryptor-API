# Changelog

All notable changes to the KSeF Integration API project will be documented in this file.

---

## [1.3.2] - 2026-08-27

### Fixed
- English PDF labels. Upstream ships `en.json` filled with `ExampleText` placeholders, so the 1.1.31 rebuild in 1.3.1 produced English invoices in which every label read `ExampleText` — 80 occurrences in a single generated PDF. The generator was rebuilt with a translation reviewed and corrected by a consultant; a regenerated EN invoice now contains none.

### Added
- `pdf-generator/i18n/en.json` — the maintained English translation, kept in the repository as the source of truth and reapplied on every generator rebuild. `docs/architecture.md` documents the procedure and the `grep -c ExampleText` check that catches a skipped reapplication.
- Optional TLS termination for production via `docker/docker-compose.ssl.yml` — an additive overlay that stacks onto the existing compose files and changes nothing in them; the application container keeps publishing port 5000 on the host. Adds `ksef-ssl-proxy` (nginx-alpine, ~85 MB) on 443, with 80 redirecting to it.
- The proxy provisions its own TLS material on first start and writes it to `docker/certs/` on the host, so it survives redeploys and `ca.crt` can be handed to clients. An existing `server.crt`/`server.key` pair is always reused, so a certificate from your own PKI is picked up and never overwritten; a locally issued certificate that has expired is renewed automatically, anything else is left alone with a warning. A mismatched certificate/key pair aborts startup with an explicit error.
- TLS 1.2 is the primary target, with 1.3 available for clients that support it and 1.0/1.1 refused. The TLS 1.2 cipher list is ECDHE-only and includes CBC-SHA suites for older Java/SAP stacks. Protocols, ciphers, SAN entries, body limit and certificate validity are configurable per deployment — see docs/deployment.md.

### Changed
- Documentation no longer describes English as a GPT-generated test feature.
- Updated PDF generator to **v1.1.31** (`ksef-fe-invoice-converter`, built from [CIRFMF/ksef-pdf-generator](https://github.com/CIRFMF/ksef-pdf-generator) tag `1.1.31`).
- Updated `pdf_generator_bridge.mjs`: replaced the locally patched `generateInvoiceFromXml` with upstream `generateInvoice` + a `FileReader` polyfill for Node.js compatibility; redirected module console output to stderr so i18next debug logs no longer corrupt the stdout JSON.
- Added `additional_data.watermark` — optional watermark text printed on every page of the generated PDF.
- Added `additional_data.language` — PDF label language (`pl` / `en`, default `pl`, case-insensitive).
- Added `additional_data.ac_date` — date the KSeF number was assigned (upstream 1.1.25).
- `/generatePDF` error responses now carry the generator's actual error instead of i18next debug output; the bridge marks its own failure on stderr and `core/pdf_service.py` extracts it.
- Added `.dockerignore` — the upstream generator source clone (`ksef-pdf-generator/`, ~229 MB with `node_modules`) and other non-runtime files no longer enter the Docker build context, which shrinks it to ~5.5 MB.
- Moved every Docker artifact into `docker/`: `Dockerfile`, the three compose files, `build-image.sh`, and the build-context excludes (now `docker/Dockerfile.dockerignore`, which BuildKit resolves from the Dockerfile's path). Compose builds with `context: ..` and pins `name: ksef-integration-api` so the project keeps one identity regardless of the invoking directory. `setup-ssl.sh` stays at the repository root — it also covers systemd deployments. Commands gain a `docker/` prefix, e.g. `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d`.
- Documentation audit against the code. `/consume` now documents the structure of the encrypted plaintext (`target` / `payload`) that clients must produce — previously only the outer envelope was described, which left the endpoint unusable from the docs alone — and states that `/encrypt` is its only supported target. `/sign_link` documents the plaintext `key_password` field it accepts. Swagger response codes were reconciled with the handlers: 500 added to `/get_pub_cert` and `/consume`, removed from `/sign_xml` and `/sign_link`, whose catch-all returns 400. Corrected the CMS key transport algorithm in `docs/architecture.md` from RSAES-OAEP to RSAES-PKCS1-v1_5, which is what `openssl cms -encrypt` actually produces. Refreshed stale 1.3.0 `/health` samples.
- Updated `tests/test_routes.py` version assertions and stopped pytest from collecting `tests/test_consume_manual.py`, a manual script that needs a live service and the non-dependency `requests`.

### Upstream PDF generator changes included (1.1.19 → 1.1.31)
- All line items of an invoice position are now rendered in a collective correction (1.1.31).
- Field `P_15` is always visualized (1.1.31).
- Added `configureFonts()` for registering custom fonts; unified decimal separators for OSS and ZZP tax rates; corrected `UU_IDZ` description and date formatting in annotations (1.1.30).
- Added KSeF number assignment date; removed a spurious blank page at the end of the invoice; added currency code to order/prepayment summaries (1.1.25).

---

## [1.3.1] - 2026-06-25

Released from `de5be91`. Superseded by 1.3.2 — the items originally drafted under this
heading were never part of the published v1.3.1 and have been moved to 1.3.2.

### Changed
- Updated PDF generator to v1.1.19 (`ksef-fe-invoice-converter`).
- Updated `pdf_generator_bridge.mjs`: replaced removed `generateInvoiceFromXml` with `generateInvoice` + `FileReader` polyfill for Node.js compatibility; redirected module console output to stderr.
- Added `additional_data.watermark` — optional watermark text printed on every page of the generated PDF.
- Added `additional_data.language` — PDF label language (`pl` / `en`, default `pl`, case-insensitive).
- Fixed gunicorn `--preload` to prevent a SQLite lock during worker init.

---

## [1.3.0] - 2026-06-25

### Added
- Added `/consume` endpoint — secure CMS encrypted RPC tunnel:
  - Accepts AES session key wrapped in CMS EnvelopedData and AES-256-CBC encrypted payload.
  - Dispatches decrypted inner request to a local endpoint (e.g. `/encrypt`).
  - Returns result as plaintext or re-encrypted with an optional client reply certificate.
- Added `/get_pub_cert` endpoint — internal RSA keypair and X.509 certificate provisioning per SID.
- Added internal key management (`core/key_manager.py`): RSA-2048 keypair generation, TTL-based expiry, automatic cleanup.
- Added SQLite database layer (`core/database.py`) with WAL mode for persistent key storage.
- Added Docker Compose dev/prod split (`docker-compose.dev.yml`, `docker-compose.prod.yml`).
- Added `build-image.sh` — builds and exports Docker image as a tar archive for offline deployment.
- Added `docs/` directory with split documentation: API reference, deployment, operations, architecture.

### Changed
- Refactored route structure into blueprints by responsibility (`routes/legacy_encrypt.py`, `routes/sign_xml.py`, `routes/sign_link.py`, `routes/pdf.py`, `routes/internal_keys.py`, `routes/consume.py`).
- Rebranded service to **KSeF Integration API**.
- Updated Swagger/OpenAPI definition to v1.3.0 with full English descriptions and new endpoints.

---

## [1.2.0] - 2026-04-01

### Added
- Added `/generatePDF` endpoint for generating invoice PDF visualizations from KSeF XML:
  - Supports FA(1), FA(2), FA(3), FA_RR invoice formats.
  - Input: `xml_b64` (Base64-encoded XML).
  - Response modes: `base64` (JSON with `pdf_b64`) or `binary` (`application/pdf`).
  - Optional `additional_data` passthrough to the PDF generator (`nrKSeF`, `qrCode`, `qr2Code`, `isMobile`).
  - Managed by [routes/pdf.py](routes/pdf.py) and [core/pdf_service.py](core/pdf_service.py).
- Added Node.js bridge [pdf_generator_bridge.mjs](pdf_generator_bridge.mjs) for PDF generation runtime.

### Changed
- Renamed input field from `xml_content` to `xml_b64` for consistency with other endpoints.
- Updated systemd service configuration to support Node.js installed via nvm (`KSEF_NODE_BIN` and `PATH` environment variables).
- Updated [swaggerapi.yaml](swaggerapi.yaml) with full `/generatePDF` schema including curl examples.

---

## [1.1.0] - 2026-01-19

### Added
- Added `/sign_link` endpoint for generating KSeF KOD II verification links with a cryptographic signature:
  - Supported algorithms:
    - RSA-PSS (SHA-256, MGF1(SHA-256), salt=32, minimum key size 2048)
    - ECDSA P-256 (SHA-256) with output formats:
      - IEEE P1363 (R||S, 64 bytes)
      - ASN.1 DER (RFC 3279)
  - Accepts links with or without `https://` scheme and normalizes trailing `/`.
  - Validates that certificate public key matches the provided private key.
  - Returns a ready-to-use link with signature appended as the last path segment.
  - Implemented in [routes/sign_link.py](routes/sign_link.py).
- Added `/sign_xml` endpoint for XAdES (enveloped) signing of XML payloads used in KSeF authentication flows.
  - Accepts input only as Base64 (`xml_b64`, `cert_pem_b64`, `key_pem_b64`).
  - Supports algorithm selection via `alg`: `rsa_sha256` or `ecdsa_sha256` (with P-256/secp256r1 curve enforcement).
  - Implemented in [routes/sign_xml.py](routes/sign_xml.py).

### Changed
- Standardized password handling across signing endpoints:
  - `key_password_b64` (Base64-encoded UTF-8 string) used for encrypted private keys.
- Updated [swaggerapi.yaml](swaggerapi.yaml) to include:
  - `/sign_link` and `/sign_xml` endpoints.
  - Full request/response schemas.
  - Algorithm selection and ECDSA formatting options.

---

## [1.0.3] - 2025-10-17

### Changed
- Disabled pretty print in JSON responses to improve integration with external systems.
- Adjusted JSON output formatting (compact mode) for cleaner API responses.

---

## [1.0.2] - 2025-10-17

### Fixed
- Improved error handling and response consistency for `/encrypt` endpoint.

---

## [1.0.1] - 2025-10-16

### Added
- Added Swagger / OpenAPI documentation [swaggerapi.yaml](swaggerapi.yaml).
- Added project documentation for external security audits (README, API specs, etc.).

---

## [1.0.0] - 2025-10-15

### Initial release
- Implemented core RSA encryption API:
  - `/encrypt` endpoint using RSAES-OAEP (MGF1 + SHA-256).
  - `/health` endpoint for monitoring.
- Added input validation and structured JSON error codes.
- Added Flask app structure with CORS and Swagger integration.
- Added [Dockerfile](Dockerfile) for containerized deployment.
- Initial repository setup and dependency list [requirements.txt](requirements.txt).

---

### Author
**KBJ DRA**  
GitHub: [tech-dra-kbj](https://github.com/tech-dra-kbj)