# Lightweight TLS Fingerprint Mitigation

## Goal
Add Chrome-like TLS options to curl configuration to reduce TLS fingerprint distinctiveness, without patching curl or BoringSSL.

## Changes

### File: `src/http/Http.zig` — `Connection.init()`

Add the following `curl_easy_setopt` calls in the TLS section (after line 162, before the compression block):

```zig
// TLS fingerprint: use Chrome-like cipher suites and curves
try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSLVERSION, @as(c_long, c.CURL_SSLVERSION_TLSv1_2 | c.CURL_SSLVERSION_MAX_DEFAULT)));
try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_CIPHER_LIST, "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA"));
try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_EC_CURVES, "X25519:P-256:P-384"));
try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_2TLS)));
```

These values match Chrome 120+'s TLS configuration:
- **Cipher list**: Chrome's cipher suite ordering (TLS 1.3 suites first, then TLS 1.2 ECDHE suites, then fallbacks)
- **EC curves**: X25519, P-256, P-384 in Chrome's preferred order
- **TLS version**: TLS 1.2 minimum (Chrome dropped TLS 1.0/1.1)
- **HTTP version**: Prefer HTTP/2 over TLS (ALPN will negotiate h2)

## What this covers
- Cipher suite list and ordering
- Elliptic curve preferences
- TLS version range
- HTTP/2 via ALPN

## What this does NOT cover
- TLS extension ordering (controlled by BoringSSL, needs patches)
- GREASE values
- HTTP/2 SETTINGS frame values

## Verification
Build and run against a TLS fingerprint checker:
```bash
./lightpanda fetch --dump https://tls.browserleaks.com/json 2>/dev/null
```
Or check JA3 hash at similar services.
