#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
TUNE_MODULE="$ROOT_DIR/tachyon/files/usr/lib/providers/zapret2/tune.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

json_field() {
  local json="$1"
  local field="$2"

  JSON_VALUE="$json" node - "$field" <<'NODE'
const field = process.argv[2];
const value = JSON.parse(process.env.JSON_VALUE);
const actual = value[field];
if (Array.isArray(actual)) {
  console.log(actual.join("\n"));
} else {
  console.log(String(actual));
}
NODE
}

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  local actual

  actual="$(json_field "$json" "$field")"
  [ "$actual" = "$expected" ] || fail "expected $field=$expected, got $actual"
}

# 1. Test tuning run on test domain
tune_result="$(ucode -L "$TACHYON_LIB" "$TUNE_MODULE" tune "" "example.com" express)"
assert_json_field "$tune_result" success true
assert_json_field "$tune_result" target_domain "example.com"

printf 'zapret2 tuner tests passed successfully\n'
