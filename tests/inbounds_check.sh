#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
DIAGNOSTICS_RUNTIME="$TACHYON_LIB/diagnostics/runtime.uc"
STATUS_UC="$TACHYON_LIB/diagnostics/status.uc"
LEAK_CHECK="$TACHYON_LIB/diagnostics/leak_check.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Syntax check
ucode -L "$TACHYON_LIB" -c "$DIAGNOSTICS_RUNTIME" || fail "runtime.uc syntax error"
ucode -S -L "$TACHYON_LIB" -c "$DIAGNOSTICS_RUNTIME" || fail "runtime.uc strict syntax error"
ucode -L "$TACHYON_LIB" -c "$STATUS_UC" || fail "status.uc syntax error"
ucode -S -L "$TACHYON_LIB" -c "$STATUS_UC" || fail "status.uc strict syntax error"
ucode -L "$TACHYON_LIB" -c "$LEAK_CHECK" || fail "leak_check.uc syntax error"
ucode -S -L "$TACHYON_LIB" -c "$LEAK_CHECK" || fail "leak_check.uc strict syntax error"

# 2. Test check-inbounds runtime mode
check_out="$(ucode -L "$TACHYON_LIB" "$DIAGNOSTICS_RUNTIME" check-inbounds 2>/dev/null || true)"
[ -n "$check_out" ] || fail "check-inbounds should return JSON output"

JSON_VAL="$check_out" node - <<'NODE'
const data = JSON.parse(process.env.JSON_VAL);
if (typeof data.enabled_count !== 'number' || typeof data.requires_public_wan !== 'number') {
  console.error("Invalid check-inbounds response:", data);
  process.exit(1);
}
NODE

# 3. Test render_global_inbounds_check in status.uc for Tailscale
cat >"$WORK_DIR/test_tailscale.json" <<'EOF'
{
  "enabled_count": 1,
  "wan_ip": "192.168.1.60",
  "wan_public": 0,
  "requires_public_wan": 0,
  "items": [
    {
      "label": "Head",
      "protocol": "tailscale",
      "tag": "server-Head-in",
      "runtime_ok": 1,
      "routes_configured": 1
    }
  ]
}
EOF

render_out="$(ucode -L "$TACHYON_LIB" "$STATUS_UC" global-inbounds-check < "$WORK_DIR/test_tailscale.json")"
if echo "$render_out" | grep -Fq "[WARN] WAN IP is not public"; then
  fail "Tailscale with private WAN IP should not produce [WARN] in render_global_inbounds_check: $render_out"
fi
if ! echo "$render_out" | grep -Fq "[OK] WAN IP: 192.168.1.60 (Tailscale does not require public WAN)"; then
  fail "Expected Tailscale exemption message in render_global_inbounds_check: $render_out"
fi

# 4. Test render_global_inbounds_check for public inbound (VLESS) with private WAN
cat >"$WORK_DIR/test_vless.json" <<'EOF'
{
  "enabled_count": 1,
  "wan_ip": "192.168.1.60",
  "wan_public": 0,
  "requires_public_wan": 1,
  "items": [
    {
      "label": "Vless",
      "protocol": "vless",
      "tag": "server-vless-in",
      "runtime_ok": 1,
      "routes_configured": 1,
      "listening": 1,
      "firewall_required": 1,
      "firewall_open": 1,
      "port_conflict": 0
    }
  ]
}
EOF

render_vless_out="$(ucode -L "$TACHYON_LIB" "$STATUS_UC" global-inbounds-check < "$WORK_DIR/test_vless.json")"
if ! echo "$render_vless_out" | grep -Fq "[WARN] WAN IP is not public"; then
  fail "VLESS with private WAN IP should produce [WARN] in render_global_inbounds_check: $render_vless_out"
fi

printf 'inbounds check diagnostics tests passed\n'
