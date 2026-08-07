#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG_UC="$ROOT_DIR/tachyon/files/usr/lib/service/watchdog.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

extract() {
  ucode "$WATCHDOG_UC" smart-detect-extract-domain "$1" 2>/dev/null || true
}

# Asserts the line yields exactly the expected domain.
assert_extracts() {
  local line="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(extract "$line")"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# Asserts the line yields no domain (exit 1, empty stdout).
assert_rejects() {
  local line="$1"
  local label="$2"
  local actual
  actual="$(extract "$line")"
  [ -z "$actual" ] || fail "$label: expected no domain, got '$actual'"
}

# --- quoted-host form (primary sing-box log shape) ---
assert_extracts 'outbound/direct: failed to connect to "example.com:443"' \
  example.com "quoted host with port"
assert_extracts 'direct connection failed: "sub.domain.example.org"' \
  sub.domain.example.org "quoted host without port, multi-label"
assert_extracts 'DIRECT timeout "xn--80ak6aa92e.com:443"' \
  xn--80ak6aa92e.com "punycode host"
assert_extracts 'direct reset "a-b-c.example.co.uk:8443"' \
  a-b-c.example.co.uk "internal hyphens and multi-part TLD"

# --- target= form (fallback pattern) ---
assert_extracts 'direct failed target=blocked.example.net' \
  blocked.example.net "target= form"
assert_extracts 'direct failed target blocked2.example.net' \
  blocked2.example.net "target<space> form"

# --- rejections: nothing usable on the line ---
assert_rejects 'direct failed to connect to 192.168.1.1:443' "bare IPv4 is not a domain"
assert_rejects 'direct connection failed, no host in line' "no host present"
assert_rejects 'direct failed "localhost"' "single-label host has no TLD"
assert_rejects 'direct failed "a.co"' "below 5-char minimum"

# --- rejections: wildcards must never reach the probe ---
assert_rejects 'direct failed "*.example.com"' "wildcard star rejected"
assert_rejects 'direct failed "?.example.com"' "wildcard question mark rejected"

# --- rejections: malformed labels ---
assert_rejects 'direct failed "example..com"' "consecutive dots rejected"
assert_rejects 'direct failed "-example.com"' "leading hyphen rejected"

# --- shell metacharacters must be returned inert, never executed ---
# The extractor is the boundary that keeps log text out of the probe command;
# a hostile log line must either be rejected or come back as a plain string.
SENTINEL="$ROOT_DIR/tmp_smart_detect_injection_sentinel"
rm -f "$SENTINEL"
for hostile in \
  'direct failed "example.com; touch '"$SENTINEL"'"' \
  'direct failed "example.com$(touch '"$SENTINEL"')"' \
  'direct failed "example.com`touch '"$SENTINEL"'`"' \
  'direct failed "example.com | touch '"$SENTINEL"'"'
do
  out="$(extract "$hostile")"
  case "$out" in
    *';'*|*'$('*|*'`'*|*'|'*|*' '*)
      fail "injection: metacharacters survived extraction: '$out'"
      ;;
  esac
  [ ! -e "$SENTINEL" ] || fail "injection: command executed during extraction of '$hostile'"
done
rm -f "$SENTINEL"

printf 'smart_detect_domain_extraction checks passed\n'
