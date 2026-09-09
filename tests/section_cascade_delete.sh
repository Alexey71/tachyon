#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Structural checks in CLI and backend ucode
grep -Fq 'delete_section' "$ROOT_DIR/tachyon/files/usr/bin/tachyon" ||
  fail "tachyon CLI must declare delete_section command"

grep -Fq 'cascade_delete_section' "$ROOT_DIR/tachyon/files/usr/lib/config/connections.uc" ||
  fail "connections.uc must implement cascade_delete_section"

grep -Fq 'cli_delete_section' "$ROOT_DIR/tachyon/files/usr/lib/config/connections.uc" ||
  fail "connections.uc must export cli_delete_section"

grep -Fq 'priority_group' "$ROOT_DIR/tachyon/files/usr/lib/config/migration.uc" ||
  fail "migration.uc CHILD_ITEM_TYPES must include priority_group"

grep -Fq 'priority_level' "$ROOT_DIR/tachyon/files/usr/lib/config/migration.uc" ||
  fail "migration.uc CHILD_ITEM_TYPES must include priority_level"

# 2. Structural checks in LuCI JS view
grep -Fq 'cascadeDeleteSection' "$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js" ||
  fail "section.js must implement cascadeDeleteSection"

grep -Fq 'cascadeDeleteSection(section_id)' "$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js" ||
  fail "section.js remove handler must invoke cascadeDeleteSection"

grep -Fq 'cascadeDeleteSection' "$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/tachyon.js" ||
  fail "tachyon.js must invoke cascadeDeleteSection on section remove/add"

# 3. Installer safety checks
grep -Fq 'backup_existing_config' "$ROOT_DIR/install.sh" ||
  fail "install.sh must invoke backup_existing_config"

grep -Fq 'path_exists("/etc/config/tachyon")' "$ROOT_DIR/install.sh" ||
  fail "install.sh must check /etc/config/tachyon before considering installation fresh"

grep -Fq 'path_executable(INSTALLER_TACHYON_BIN)' "$ROOT_DIR/install.sh" ||
  fail "install.sh must check INSTALLER_TACHYON_BIN before considering installation fresh"

printf 'section cascade deletion and installer checks passed\n'
