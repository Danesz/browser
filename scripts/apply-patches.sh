#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Applying curl-impersonate patches..."

# Apply curl patch (requires curl 8.15.0)
CURL_VERSION="curl-8_15_0"
echo "Patching vendor/curl..."
cd "$ROOT_DIR/vendor/curl"

# Checkout the correct curl version for the patch
CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")
if [ "$CURRENT_TAG" != "$CURL_VERSION" ]; then
    echo "  Checking out $CURL_VERSION..."
    git fetch --tags 2>/dev/null || true
    git checkout "$CURL_VERSION"
fi

if git apply --check "$ROOT_DIR/patches/curl-impersonate.patch" 2>/dev/null; then
    git apply "$ROOT_DIR/patches/curl-impersonate.patch"
    echo "  Applied curl-impersonate.patch"
else
    echo "  Curl patch already applied or conflicts exist -- skipping"
fi

# Set up boringssl source for patching
# boringssl-zig fetches boringssl via Zig's package manager, but we need
# the source locally to apply patches. Clone it directly.
BORINGSSL_DIR="$ROOT_DIR/vendor/boringssl-zig/boringssl"
BORINGSSL_COMMIT="673e61fc215b178a90c0e67858bbf162c8158993"

if [ ! -d "$BORINGSSL_DIR/.git" ]; then
    echo "Cloning boringssl into vendor/boringssl-zig/boringssl..."
    git clone https://github.com/google/boringssl.git "$BORINGSSL_DIR"
fi

cd "$BORINGSSL_DIR"
CURRENT_COMMIT=$(git rev-parse HEAD)
if [ "$CURRENT_COMMIT" != "$BORINGSSL_COMMIT" ]; then
    echo "  Checking out boringssl $BORINGSSL_COMMIT..."
    git checkout "$BORINGSSL_COMMIT"
fi

# Update boringssl-zig's build.zig.zon to use local path
BSSL_ZIG_ZON="$ROOT_DIR/vendor/boringssl-zig/build.zig.zon"
if grep -q '"git+https://github.com/google/boringssl' "$BSSL_ZIG_ZON" 2>/dev/null; then
    echo "Updating boringssl-zig/build.zig.zon to use local boringssl path..."
    # Replace the URL-based dependency with a local path dependency
    sed -i.bak 's|\.url = "git+https://github.com/google/boringssl#[^"]*",||; s|\.hash = "[^"]*",||' "$BSSL_ZIG_ZON"
    # Now replace with path
    python3 -c "
import re
with open('$BSSL_ZIG_ZON', 'r') as f:
    content = f.read()
# Replace the ssl dependency block
content = re.sub(
    r'\.ssl = \.\{[^}]*\}',
    '.ssl = .{\n            .path = \"boringssl\",\n        }',
    content,
    flags=re.DOTALL
)
# Add boringssl to .paths so Zig includes the source directory
content = content.replace(
    '\"build.zig.zon\",\n    },',
    '\"build.zig.zon\",\n        \"boringssl\",\n    },'
)
with open('$BSSL_ZIG_ZON', 'w') as f:
    f.write(content)
"
    rm -f "$BSSL_ZIG_ZON.bak"
    echo "  Updated build.zig.zon"
else
    echo "  boringssl-zig/build.zig.zon already updated"
fi

# Apply boringssl patch
echo "Patching vendor/boringssl-zig/boringssl..."
cd "$BORINGSSL_DIR"
if git apply --check "$ROOT_DIR/patches/boringssl-impersonate.patch" 2>/dev/null; then
    git apply "$ROOT_DIR/patches/boringssl-impersonate.patch"
    echo "  Applied boringssl-impersonate.patch"
else
    echo "  BoringSSL patch already applied or conflicts exist -- skipping"
fi

# Adapt boringssl-zig build.zig source lists for the boringssl version
# used by curl-impersonate (some files were added/removed between versions)
BSSL_BUILD_ZIG="$ROOT_DIR/vendor/boringssl-zig/build.zig"
if grep -q '"crypto/aes/aes.cc"' "$BSSL_BUILD_ZIG" 2>/dev/null; then
    echo "Adapting boringssl-zig/build.zig for boringssl $BORINGSSL_COMMIT..."
    # Remove source files that don't exist in the target boringssl version
    # and add AVX-10 assembly files required by gcm.cc
    sed -i.bak \
        -e '/"crypto\/aes\/aes.cc",/d' \
        -e '/"crypto\/bn\/div.cc",/d' \
        -e '/"crypto\/bn\/exponentiation.cc",/d' \
        -e '/"crypto\/bn\/sqrt.cc",/d' \
        -e '/"crypto\/cipher\/e_aeseax.cc",/d' \
        -e '/"crypto\/cms\/cms.cc",/d' \
        -e '/"crypto\/ecdsa\/ecdsa_p1363.cc",/d' \
        -e '/"crypto\/fuzzer_mode.cc",/d' \
        -e '/"crypto\/xwing\/xwing.cc",/d' \
        -e '/"gen\/bcm\/aes-gcm-avx512-x86_64-apple.S",/d' \
        -e '/"gen\/bcm\/aes-gcm-avx512-x86_64-linux.S",/d' \
        "$BSSL_BUILD_ZIG"
    # Add AVX-10 assembly files (required by gcm.cc in this boringssl version)
    sed -i.bak \
        -e '/"gen\/bcm\/aes-gcm-avx2-x86_64-linux.S",/a\    "gen/bcm/aes-gcm-avx10-x86_64-apple.S",\n    "gen/bcm/aes-gcm-avx10-x86_64-linux.S",' \
        "$BSSL_BUILD_ZIG"
    rm -f "$BSSL_BUILD_ZIG.bak"
    echo "  Adapted build.zig source lists"
else
    echo "  boringssl-zig/build.zig already adapted"
fi

echo "Done!"
