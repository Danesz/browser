# TLS Impersonation -- Future Improvements

## High priority

### 1. Enable ECH (Encrypted Client Hello) support

**Current state:** ECH is disabled (`USE_ECH` not defined). The impersonate
profile's `.ech = "grease"` is silently skipped.

**Why it matters:** Chrome has shipped ECH GREASE since v105. Sophisticated
fingerprinters can detect its absence. Cloudflare in particular deploys ECH
on their sites -- a client that doesn't even GREASE the ECH extension stands
out.

**What to do:**
- Define `USE_ECH` in the curl build flags in `build.zig`
- BoringSSL supports ECH; verify the patched version exposes the needed APIs
- Test that ECH GREASE appears in the ClientHello
- Remove the `CURLE_UNKNOWN_OPTION` tolerance for ECH once it's properly enabled

### 2. Enable zstd decompression

**Current state:** We skip the profile's `Accept-Encoding` header because it
includes `zstd`, which curl can't decompress without libzstd linked in. This
is why we pass `default_headers=0`.

**Why it matters:** Chrome advertises `Accept-Encoding: gzip, deflate, br, zstd`
since v123. Missing `zstd` from Accept-Encoding is a fingerprint signal. Some
CDNs may also prefer zstd for better compression ratios.

**What to do:**
- Add libzstd as a build dependency (or vendor it)
- Enable `HAVE_ZSTD` / `USE_ZSTD` in curl build flags
- Once zstd works, consider switching `default_headers` back to `1` (and remove
  the `curl_impersonate_useragent()` workaround) or keep the current approach
  for cleaner header control

### 3. Rotate / randomize impersonate profiles

**Current state:** Fixed to chrome131 by default. Every Lightpanda instance
produces the same JA3/JA4.

**Why it matters:** If a detection system sees thousands of requests with
identical JA4 hashes from different IPs, it can cluster and flag them. Real
Chrome users have slight variations across versions.

**What to do:**
- Add a `--tls_impersonate random_chrome` mode that picks randomly from
  recent Chrome profiles (e.g. chrome131, chrome133a, chrome136, chrome142)
- Or a `--tls_impersonate latest` that always uses the newest profile
- Consider per-connection rotation vs per-session consistency (a single
  "browsing session" should keep the same profile)

### 4. HTTP/2 SETTINGS frame validation

**Current state:** The impersonate profile sets HTTP/2 SETTINGS values, but
we haven't verified they actually appear on the wire.

**What to do:**
- Capture traffic with Wireshark / tshark and verify the HTTP/2 SETTINGS
  frame matches Chrome's: `HEADER_TABLE_SIZE=65536, ENABLE_PUSH=0,
  INITIAL_WINDOW_SIZE=6291456, MAX_HEADER_LIST_SIZE=262144`
- Verify WINDOW_UPDATE is sent with the expected value (15663105)
- Verify stream weight (256) and exclusive flag

## Medium priority

### 5. TLS extension ordering verification

**Current state:** The BoringSSL patch enables custom extension ordering, but
we rely on the profile's `.tls_extension_order = NULL` (which means "use
BoringSSL default with permutation enabled").

**What to do:**
- Verify with a packet capture that TLS extensions appear in a Chrome-like
  order
- If the order doesn't match, consider setting explicit extension orders
  in the profiles

### 6. Certificate compression (brotli)

**Current state:** The profile sets `.cert_compression = "brotli"`. This tells
the server the client supports brotli-compressed certificates (TLS extension 27).
Unclear if BoringSSL's brotli support is linked in.

**What to do:**
- Verify brotli certificate compression is actually enabled in the TLS handshake
- If not, link brotli and enable it in BoringSSL build flags

### 7. Keep patches up to date with lexiforest

**Current state:** Patches are from a specific point in time. lexiforest
regularly adds new Chrome/Firefox versions.

**What to do:**
- Periodically check https://github.com/lexiforest/curl-impersonate for
  new releases
- When updating: download new patches, check if they still apply to our pinned
  curl/boringssl versions, regenerate if needed
- Consider automating this with a CI job that checks for upstream changes

### 8. Idempotent patch script

**Current state:** `scripts/apply-patches.sh` uses `git apply --check` to skip
already-applied patches, but the boringssl-zig/build.zig adaptations use a
fragile grep check (`"crypto/aes/aes.cc"`) to detect if they've already run.

**What to do:**
- Use a marker file (e.g. `.patched`) or git notes to track patch state
- Or check the actual git diff against expected state
- Make the script safe to run multiple times without side effects

## Low priority

### 9. Per-page profile override via CDP

**Current state:** The impersonate profile is set globally at startup. All
connections use the same profile.

**What to do:**
- Allow CDP clients to specify a profile per browser context or page
- This enables testing different profiles without restarting the server
- Requires passing the profile down through the Page -> Http -> Connection chain

### 10. Profile auto-detection from User-Agent

**Current state:** `--tls_impersonate` and `--user_agent` are independent. A
user could set `--user_agent "Firefox/144"` but `--tls_impersonate chrome131`,
creating a mismatch.

**What to do:**
- If `--user_agent` is set but `--tls_impersonate` is not, try to infer the
  right profile from the UA string
- Or at least warn when the UA and profile don't match

### 11. HTTP/3 (QUIC) fingerprinting

**Current state:** curl-impersonate has HTTP/3 support, but Lightpanda doesn't
use HTTP/3 yet.

**Why it matters:** HTTP/3 has its own fingerprinting vectors (QUIC transport
parameters, initial flow control values). As HTTP/3 adoption grows, detection
systems will fingerprint it too.

**What to do:**
- Future work when Lightpanda adds HTTP/3 support
- The curl-impersonate patches already include QUIC fingerprint options
  (`lib/vquic/` modifications)

### 12. Canvas / WebGL fingerprint consistency

**Not related to TLS**, but worth noting: advanced bot detection also
fingerprints the rendering engine (canvas hashes, WebGL renderer strings).
Since Lightpanda doesn't render, these are absent, which is itself a signal.
This is outside the scope of TLS impersonation but relevant to overall
detection evasion.
