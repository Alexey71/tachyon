#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
UPDATER_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updater.uc"
PACKAGES_UC="$ROOT_DIR/tachyon/files/usr/lib/core/packages.uc"
FPTN_RUNTIME_UC="$ROOT_DIR/tachyon/files/usr/lib/providers/fptn/runtime.uc"
STATE_UC="$ROOT_DIR/tachyon/files/usr/lib/service/state.uc"
DIAGNOSTICS_UC="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/runtime.uc"

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

ucode_run() {
  ucode -L "$TACHYON_LIB" "$@"
}

# 1. Test updater.uc asset selection for FPTN
cat >"$WORK_DIR/releases.json" <<'EOF_JSON'
[
  {
    "tag_name": "v0.4.5",
    "name": "0.4.5",
    "html_url": "https://github.com/fptn-project/fptn/releases/tag/v0.4.5",
    "assets": [
      {
        "name": "fptn-client-0.4.5-openwrt-23.05.x-x86_64.ipk",
        "browser_download_url": "https://github.com/fptn-project/fptn/releases/download/v0.4.5/fptn-client-0.4.5-openwrt-23.05.x-x86_64.ipk"
      },
      {
        "name": "fptn-client-0.4.5-openwrt-24.10.x-x86_64.apk",
        "browser_download_url": "https://github.com/fptn-project/fptn/releases/download/v0.4.5/fptn-client-0.4.5-openwrt-24.10.x-x86_64.apk"
      },
      {
        "name": "fptn-client-0.4.5-openwrt-24.10.x-aarch64_cortex-a53.apk",
        "browser_download_url": "https://github.com/fptn-project/fptn/releases/download/v0.4.5/fptn-client-0.4.5-openwrt-24.10.x-aarch64_cortex-a53.apk"
      }
    ]
  }
]
EOF_JSON

SELECTED_APK="$(cat "$WORK_DIR/releases.json" | ucode_run "$UPDATER_UC" fptn-select-asset "24.10" "apk" "aarch64_cortex-a53 aarch64_generic")"
ARCH_MATCH="$(echo "$SELECTED_APK" | awk '{print $1}')"
NAME_MATCH="$(echo "$SELECTED_APK" | awk '{print $2}')"
assert_eq "aarch64_cortex-a53" "$ARCH_MATCH" "fptn asset arch match"
assert_eq "fptn-client-0.4.5-openwrt-24.10.x-aarch64_cortex-a53.apk" "$NAME_MATCH" "fptn asset name match"

# 2. Test package version extraction
PARSED_VER="$(ucode_run "$UPDATER_UC" updates-arch-package-version "fptn-client-0.4.5-openwrt-24.10.x-x86_64.ipk" "x86_64")"
assert_eq "0.4.5-openwrt-24.10.x" "$PARSED_VER" "fptn package version strip"

# 3. Test packages.uc binary detection and version
MOCK_BIN="$WORK_DIR/fptn-client-cli"
cat >"$MOCK_BIN" <<'EOF_BIN'
#!/usr/bin/env sh
echo "fptn-client 0.4.5"
EOF_BIN
chmod 0755 "$MOCK_BIN"

export TACHYON_FPTN_BIN="$MOCK_BIN"
FPTN_VER="$(TACHYON_LIB_DIR="$TACHYON_LIB" ucode_run "$FPTN_RUNTIME_UC" version)"
assert_eq "0.4.5" "$FPTN_VER" "fptn runtime version command"

FPTN_INSTALLED="$(TACHYON_LIB_DIR="$TACHYON_LIB" ucode_run "$FPTN_RUNTIME_UC" installed && echo "1" || echo "0")"
assert_eq "1" "$FPTN_INSTALLED" "fptn runtime installed check"

# 4. Test state.uc fptn runtime signature fixture
cat >"$WORK_DIR/state_fixture.json" <<'EOF_FIXTURE'
{
  "section": [
    {
      ".name": "sec1",
      "enabled": "1",
      "action": "fptn",
      "access_token": "secret_token_123",
      "sni": "my.domain.com"
    }
  ]
}
EOF_FIXTURE

SIG_1="$(ucode_run "$STATE_UC" fptn-runtime-signature-fixture "$WORK_DIR/state_fixture.json")"
[ -n "$SIG_1" ] || fail "fptn signature should not be empty"

cat >"$WORK_DIR/state_fixture2.json" <<'EOF_FIXTURE2'
{
  "section": [
    {
      ".name": "sec1",
      "enabled": "1",
      "action": "fptn",
      "access_token": "secret_token_diff",
      "sni": "my.domain.com"
    }
  ]
}
EOF_FIXTURE2

SIG_2="$(ucode_run "$STATE_UC" fptn-runtime-signature-fixture "$WORK_DIR/state_fixture2.json")"
[ "$SIG_1" != "$SIG_2" ] || fail "fptn signature should differ when token changes"

# 5. Test diagnostics runtime dispatch for get-fptn-status
STATUS_OUT="$(TACHYON_LIB="$TACHYON_LIB" ucode_run "$DIAGNOSTICS_UC" get-fptn-status)"
echo "$STATUS_OUT" | grep -q '"ready":' || fail "get-fptn-status should return status json"

echo "fptn component tests passed"

