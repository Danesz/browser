# TLS Impersonation (curl-impersonate)

## Overview

Lightpanda integrates [curl-impersonate](https://github.com/lexiforest/curl-impersonate)
patches to produce browser-identical TLS fingerprints (JA3/JA4). This prevents
detection by bot protection systems (Cloudflare, Akamai, DataDome, etc.) that
compare the TLS ClientHello against known browser fingerprints.

Without impersonation, a headless browser using default libcurl settings
produces a distinctive TLS fingerprint that is trivially blocked.

## What gets fingerprinted

Bot detection inspects several layers of the TLS and HTTP/2 handshake:

| Signal | What it is | Controlled by |
|--------|-----------|---------------|
| **JA3/JA3N** | Hash of TLS cipher suites, extensions, curves, point formats | BoringSSL + curl |
| **JA4** | Improved JA3 with extension ordering, ALPN, TLS version | BoringSSL + curl |
| **Akamai hash** | HTTP/2 SETTINGS frame values, window update, stream weight | curl (nghttp2) |
| **User-Agent** | HTTP header identifying the client | Lightpanda |

curl-impersonate patches control all of these except User-Agent, which
Lightpanda sets automatically from the impersonate profile.

## Architecture

### Patch strategy

Two patches are stored in `patches/` and applied to vendor submodules after clone:

```
patches/curl-impersonate.patch    # Patches vendor/curl (targets curl 8.15.0)
patches/boringssl-impersonate.patch  # Patches vendor/boringssl-zig/boringssl (targets 673e61fc)
```

The patches originate from the [lexiforest/curl-impersonate](https://github.com/lexiforest/curl-impersonate)
fork, with one modification: the ECH `CURLOPT_ECH` setopt call is made
non-fatal (see "Design decisions" below).

### What the curl patch adds

- `curl_easy_impersonate(CURL *curl, const char *target, int default_headers)` --
  applies all TLS/HTTP2 settings for a browser profile in one call
- `curl_impersonate_useragent(const char *target)` -- returns the User-Agent
  string for a profile (added by us, not upstream)
- `lib/impersonate.c` / `lib/impersonate.h` -- 35 browser profile definitions
- 20+ new `CURLOPT_*` options: `CURLOPT_SSL_ENABLE_ALPS`, `CURLOPT_TLS_GREASE`,
  `CURLOPT_HTTP2_SETTINGS`, `CURLOPT_HTTP2_PSEUDO_HEADERS_ORDER`,
  `CURLOPT_SSL_PERMUTE_EXTENSIONS`, `CURLOPT_SSL_CERT_COMPRESSION`, etc.

### What the BoringSSL patch adds

- Custom TLS extension ordering via `ssl_set_extension_order()`
- DHE key exchange support
- Key share configuration
- Delegated credentials support
- Disables signature algorithm uniqueness check (Safari compatibility)

### Code flow

```
main.zig
  --tls_impersonate chrome131    # CLI option (default: chrome131)
  --user_agent "..."             # Optional override
       |
       v
App.zig  (passes tls_impersonate + user_agent through Config)
       |
       v
Http.zig::init()
  1. If curl_impersonate_useragent exists and user didn't set --user_agent:
     -> Look up profile UA via curl_impersonate_useragent("chrome131")
     -> Override user_agent with Chrome 131 UA string
       |
       v
Http.zig::Connection::init()
  2. If curl_easy_impersonate exists and target != "none":
     -> curl_easy_impersonate(easy, "chrome131", 0)
        (0 = TLS/HTTP2 settings only, no HTTP headers)
  3. Else:
     -> Fallback to lightweight cipher/curve/version settings
  4. CURLOPT_ACCEPT_ENCODING = "" (use what curl supports)
```

## Usage

```bash
# Default: Chrome 131 fingerprint
lightpanda fetch --dump https://example.com

# Specific profile
lightpanda fetch --tls_impersonate chrome142 --dump https://example.com

# Disable impersonation
lightpanda fetch --tls_impersonate none --dump https://example.com

# Custom User-Agent (overrides profile UA)
lightpanda fetch --user_agent "MyBot/1.0" --dump https://example.com
```

### Available profiles

**Chrome:** chrome99, chrome99_android, chrome100, chrome101, chrome104,
chrome107, chrome110, chrome116, chrome119, chrome120, chrome123, chrome124,
chrome131, chrome131_android, chrome133a, chrome136, chrome142

**Firefox:** firefox133, firefox135, firefox144

**Safari:** safari153, safari155, safari170, safari172_ios, safari180,
safari180_ios, safari184, safari184_ios, safari260, safari2601, safari260_ios

**Edge:** edge99, edge101

**Other:** tor145, okhttp4_android

### Verify fingerprint

```bash
./zig-out/bin/lightpanda fetch --dump https://tls.browserleaks.com/json 2>/dev/null
```

Compare `ja3_hash` and `ja4` against known Chrome fingerprints at
https://tls.browserleaks.com/ or https://ja3er.com/.

## Setup

### Prerequisites

After cloning and initializing submodules:

```bash
git submodule update --init --recursive
./scripts/apply-patches.sh
```

The script:
1. Checks out `curl-8_15_0` tag in `vendor/curl`
2. Applies `patches/curl-impersonate.patch`
3. Clones BoringSSL at commit `673e61fc` into `vendor/boringssl-zig/boringssl`
4. Updates `vendor/boringssl-zig/build.zig.zon` to use local BoringSSL path
5. Applies `patches/boringssl-impersonate.patch`
6. Adapts `vendor/boringssl-zig/build.zig` source lists (removes files not in
   the target BoringSSL version, adds AVX-10 assembly files)

### Build

```bash
zig build
```

The build detects impersonation support at compile time via `@hasDecl`. If the
patches weren't applied, it falls back to lightweight TLS options automatically.

## Design decisions

### default_headers = 0

We call `curl_easy_impersonate(easy, target, 0)` -- the `0` skips applying the
profile's default HTTP headers. This is necessary because:

1. The chrome131 profile includes `Accept-Encoding: gzip, deflate, br, zstd`
2. These headers are set via `CURLOPT_HTTPBASEHEADER` which feeds into
   `merged_headers`
3. `Curl_checkheaders()` in `http.c:2868` checks `merged_headers` -- if it
   finds an `Accept-Encoding`, it skips the auto-generated one from
   `CURLOPT_ACCEPT_ENCODING`
4. Our `CURLOPT_ACCEPT_ENCODING = ""` (which means "advertise only what curl
   can decompress") gets ignored
5. The server sends zstd-encoded content, curl can't decompress it ->
   `BadContentEncoding`

Instead, we apply only TLS/HTTP2 settings (ciphers, extensions, GREASE, HTTP/2
SETTINGS, etc.) and let Lightpanda manage HTTP headers separately. The matching
User-Agent is extracted via `curl_impersonate_useragent()`.

### ECH tolerance

The chrome131 profile sets `.ech = "grease"` (Encrypted Client Hello). But
`CURLOPT_ECH` is guarded by `#ifdef USE_ECH` in `setopt.c`, which is not
enabled in our build. Without the fix, `_do_impersonate()` would return
`CURLE_UNKNOWN_OPTION` and abort the entire setup. The patch tolerates
`CURLE_UNKNOWN_OPTION` for ECH specifically since GREASE is optional.

### Compile-time fallback

The Zig code uses `@hasDecl(c, "curl_easy_impersonate")` to detect whether the
patched curl is available. If not (e.g. building without patches), it falls back
to setting basic cipher/curve/version options directly. This means the project
builds and runs with or without the patches applied.

### Pinned versions

The patches target specific versions:
- curl: `curl-8_15_0` (the patch modifies ~44 files across curl)
- BoringSSL: `673e61fc` (Chrome 135 era, ~15 files modified)

These must stay in sync. Updating either requires regenerating or rebasing the
patches.
