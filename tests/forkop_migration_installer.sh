#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$INSTALLER" ] || fail "install.sh is missing"

# 1. Extract embedded ucode helper and verify its syntax
helper="$WORK_DIR/install-json.uc"
awk '
  /cat > "\$helper_path" <<'\''EOF'\''/ { capture = 1; next }
  capture && /^EOF$/ { exit }
  capture { print }
' "$INSTALLER" > "$helper"
[ -s "$helper" ] || fail "failed to extract embedded installer ucode helper"

if command -v ucode >/dev/null 2>&1; then
  ucode -c -o /dev/null "$helper" || fail "embedded ucode helper failed syntax check"
fi

# 2. Test installer_cleanup_legacy with mock Forkop environment
MOCK_ROOT="$WORK_DIR/rootfs"
mkdir -p "$MOCK_ROOT/etc/config"
mkdir -p "$MOCK_ROOT/etc/init.d"
mkdir -p "$MOCK_ROOT/usr/bin"
mkdir -p "$MOCK_ROOT/usr/lib/forkop"
mkdir -p "$MOCK_ROOT/tmp"
mkdir -p "$MOCK_ROOT/var/run/forkop"

cat >"$MOCK_ROOT/etc/config/forkop" <<'EOF'
config settings 'settings'
	option enabled '1'
EOF

cat >"$MOCK_ROOT/etc/init.d/forkop" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  enabled) exit 0 ;;
  running) exit 0 ;;
  stop|disable) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$MOCK_ROOT/etc/init.d/forkop"

cat >"$MOCK_ROOT/usr/bin/forkop" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  get_status) printf '{"running":1}\n' ;;
  restore_dnsmasq) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$MOCK_ROOT/usr/bin/forkop"

# Mock opkg
MOCK_BIN="$WORK_DIR/bin"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/opkg" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  list-installed)
    printf '%s\n' \
      'forkop - 1.0.4' \
      'luci-app-forkop - 1.0.4' \
      'luci-i18n-forkop-ru - 1.0.4'
    ;;
  remove)
    shift
    [ "$1" = "--force-depends" ] && shift
    printf 'removed: %s\n' "$1" >> "$TMP_DIR/opkg-removed.log"
    ;;
esac
exit 0
EOF
chmod 0755 "$MOCK_BIN/opkg"

# Run installer-cleanup-legacy in mock environment
if command -v ucode >/dev/null 2>&1; then
  export PATH="$MOCK_BIN:$PATH"
  export TMP_DIR="$WORK_DIR"

  state_output="$(
    TACHYON_LEGACY_DETECTED=1 \
    TACHYON_INSTALLER_OPKG_BIN="$MOCK_BIN/opkg" \
    TACHYON_INSTALLER_TACHYON_INIT="$WORK_DIR/no-init" \
    TACHYON_INSTALLER_TACHYON_BIN="$WORK_DIR/no-bin" \
    TACHYON_INSTALLER_TACHYON_LIB="$WORK_DIR/no-lib" \
    TACHYON_INSTALLER_TACHYON_UCI_DEFAULTS="$WORK_DIR/no-defaults" \
    TACHYON_INSTALLER_TACHYON_LUCI_VIEW="$WORK_DIR/no-view" \
    TACHYON_INSTALLER_MENU_JSON="$WORK_DIR/no-menu" \
    TACHYON_INSTALLER_ACL_JSON="$WORK_DIR/no-acl" \
    TACHYON_INSTALLER_RU_LMO="$WORK_DIR/no-ru-lmo" \
    TACHYON_INSTALLER_EN_LMO="$WORK_DIR/no-en-lmo" \
    TACHYON_INSTALLER_RU_LUA="$WORK_DIR/no-ru-lua" \
    TACHYON_INSTALLER_EN_LUA="$WORK_DIR/no-en-lua" \
    TACHYON_INSTALLER_LEGACY_INIT="$WORK_DIR/no-leg-init" \
    TACHYON_INSTALLER_LEGACY_BIN="$WORK_DIR/no-leg-bin" \
    TACHYON_INSTALLER_LEGACY_LIB="$WORK_DIR/no-leg-lib" \
    TACHYON_INSTALLER_LEGACY_UCI_DEFAULTS="$WORK_DIR/no-leg-defaults" \
    TACHYON_INSTALLER_LEGACY_LUCI_VIEW="$WORK_DIR/no-leg-view" \
    TACHYON_INSTALLER_LEGACY_MENU_JSON="$WORK_DIR/no-leg-menu" \
    TACHYON_INSTALLER_LEGACY_ACL_JSON="$WORK_DIR/no-leg-acl" \
    TACHYON_INSTALLER_LEGACY_BASE_INIT="$WORK_DIR/no-base-init" \
    TACHYON_INSTALLER_LEGACY_BASE_BIN="$WORK_DIR/no-base-bin" \
    TACHYON_INSTALLER_LEGACY_BASE_LIB="$WORK_DIR/no-base-lib" \
    TACHYON_INSTALLER_LEGACY_BASE_UCI_DEFAULTS="$WORK_DIR/no-base-defaults" \
    TACHYON_INSTALLER_LEGACY_BASE_LUCI_VIEW="$WORK_DIR/no-base-view" \
    TACHYON_INSTALLER_LEGACY_BASE_MENU_JSON="$WORK_DIR/no-base-menu" \
    TACHYON_INSTALLER_LEGACY_BASE_ACL_JSON="$WORK_DIR/no-base-acl" \
    TACHYON_INSTALLER_LEGACY_BASE_I18N="$WORK_DIR/no-base-i18n" \
    TACHYON_INSTALLER_LEGACY_BRAND="podkop" \
    TACHYON_INSTALLER_LEGACY_BACKEND="podkop-plus" \
    ucode "$helper" installer-cleanup-legacy
  )"

  printf '%s\n' "$state_output" | grep -Fxq 'TACHYON_LEGACY_DETECTED=1' ||
    fail "installer_cleanup_legacy must report TACHYON_LEGACY_DETECTED=1 when Forkop is installed"

  # 3. Test post-install when TACHYON_LEGACY_DETECTED=1
  # reset_settings must NOT be executed
  cat >"$WORK_DIR/mock-tachyon-bin" <<'EOF'
#!/usr/bin/env sh
if [ "$1" = "reset_settings" ]; then
  echo "CALLED_RESET_SETTINGS" >> "$TMP_DIR/reset_settings.called"
fi
exit 0
EOF
  chmod 0755 "$WORK_DIR/mock-tachyon-bin"

  TACHYON_WAS_INSTALLED=0 \
  TACHYON_LEGACY_DETECTED=1 \
  TACHYON_WAS_ENABLED=1 \
  TACHYON_WAS_RUNNING=1 \
  TACHYON_INSTALLER_TACHYON_BIN="$WORK_DIR/mock-tachyon-bin" \
  TACHYON_INSTALLER_TACHYON_INIT="$WORK_DIR/mock-tachyon-bin" \
    ucode "$helper" installer-post-install

  if [ -f "$WORK_DIR/reset_settings.called" ]; then
    fail "installer_post_install must not invoke reset_settings when legacy migration is active"
  fi
fi

# 4. Static checks on install.sh to ensure Forkop / Netshift migration contracts
grep -Fq 'TACHYON_FORKOP_MIGRATION=1' "$INSTALLER" ||
  fail "install.sh must set TACHYON_FORKOP_MIGRATION flag"

grep -Fq 'TACHYON_NETSHIFT_MIGRATION=1' "$INSTALLER" ||
  fail "install.sh must set TACHYON_NETSHIFT_MIGRATION flag"

grep -Fq 'legacy_detected_before="$TACHYON_LEGACY_DETECTED"' "$INSTALLER" ||
  fail "cleanup_legacy_installation must guard TACHYON_LEGACY_DETECTED against being overwritten to 0"

grep -Fq 'installer_package_installed("forkop")' "$INSTALLER" ||
  fail "installer_cleanup_legacy must detect forkop packages"

grep -Fq 'installer_package_installed("netshift")' "$INSTALLER" ||
  fail "installer_cleanup_legacy must detect netshift packages"

grep -Fq '"/etc/config/forkop"' "$INSTALLER" ||
  fail "installer must reference /etc/config/forkop for migration and cleanup"

printf 'Forkop migration installer tests passed successfully.\n'
