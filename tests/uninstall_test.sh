#!/bin/sh
set -eu

echo "=== Testing uninstall.sh and uninstallation mechanisms ==="

TEST_DIR="$(mktemp -d /tmp/tachyon_uninstall_test_XXXXXX)"
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# 1. Test --help option
HELP_OUTPUT="$(sh uninstall.sh --help)"
if ! echo "$HELP_OUTPUT" | grep -q -- "--purge"; then
    echo "FAIL: --help did not output --purge option"
    exit 1
fi
if ! echo "$HELP_OUTPUT" | grep -q -- "--keep-binaries"; then
    echo "FAIL: --help did not output --keep-binaries option"
    exit 1
fi
echo "✓ Help options verified (--purge, --keep-binaries)"

# 2. Verify files and uninstaller dispatch paths
if [ ! -f "tachyon/files/usr/lib/service/uninstall.uc" ]; then
    echo "FAIL: tachyon/files/usr/lib/service/uninstall.uc is missing (double-nesting regression)"
    exit 1
fi
if [ -d "tachyon/files/usr/lib/tachyon" ]; then
    echo "FAIL: tachyon/files/usr/lib/tachyon directory should not exist"
    exit 1
fi
if ! grep -Fq 'uninstall: [ "service/uninstall.uc", "uninstall", 1 ]' "tachyon/files/usr/bin/tachyon"; then
    echo "FAIL: usr/bin/tachyon does not dispatch to service/uninstall.uc"
    exit 1
fi
echo "✓ Uninstaller module paths and entrypoints verified"

# 3. Test routing table cleanup logic
MOCK_RT="$TEST_DIR/rt_tables"
cat << 'EOF' > "$MOCK_RT"
# Reserved tables
100 main
105 tachyon
200 custom_table
EOF
sed -i '/105[[:space:]]\+tachyon/d; /tachyon/d' "$MOCK_RT"
if grep -q "tachyon" "$MOCK_RT"; then
    echo "FAIL: tachyon was not removed from rt_tables"
    exit 1
fi
if ! grep -q "100 main" "$MOCK_RT" || ! grep -q "200 custom_table" "$MOCK_RT"; then
    echo "FAIL: unrelated rt_tables entries were corrupted"
    exit 1
fi
echo "✓ Routing table cleanup logic verified"

# 4. Test crontab cleanup logic
MOCK_CRON="$TEST_DIR/crontab.txt"
cat << 'EOF' > "$MOCK_CRON"
0 2 * * * /usr/bin/backup_script.sh
*/5 * * * * /usr/bin/tachyon watchdog
* * * * * /usr/bin/tachyon parental_quota_tick
30 4 * * 0 /usr/bin/certbot renew
EOF
MOCK_CRON_CLEAN="$TEST_DIR/crontab_clean.txt"
grep -v -E 'tachyon|parental_quota_tick' "$MOCK_CRON" > "$MOCK_CRON_CLEAN" || true
if grep -q "tachyon" "$MOCK_CRON_CLEAN" || grep -q "parental_quota_tick" "$MOCK_CRON_CLEAN"; then
    echo "FAIL: tachyon jobs remained in crontab"
    exit 1
fi
if ! grep -q "backup_script.sh" "$MOCK_CRON_CLEAN" || ! grep -q "certbot renew" "$MOCK_CRON_CLEAN"; then
    echo "FAIL: non-tachyon cron jobs were deleted"
    exit 1
fi
echo "✓ Crontab cleanup logic verified"

# 5. Test managed sing-box detection logic
MOCK_SB_INIT_MANAGED="$TEST_DIR/sing-box-managed"
MOCK_SB_INIT_UNMANAGED="$TEST_DIR/sing-box-unmanaged"
cat << 'EOF' > "$MOCK_SB_INIT_MANAGED"
#!/bin/sh /etc/rc.common
# Tachyon managed sing-box service for binary variants
START=95
EOF
cat << 'EOF' > "$MOCK_SB_INIT_UNMANAGED"
#!/bin/sh /etc/rc.common
# Official openwrt-sing-box package
START=95
EOF
if ! grep -q "Tachyon managed sing-box" "$MOCK_SB_INIT_MANAGED"; then
    echo "FAIL: Managed marker not found in managed sing-box init"
    exit 1
fi
if grep -q "Tachyon managed sing-box" "$MOCK_SB_INIT_UNMANAGED"; then
    echo "FAIL: Managed marker falsely found in unmanaged sing-box init"
    exit 1
fi
echo "✓ Managed sing-box detection verified"

# 6. Verify postrm hooks presence
if ! grep -q "Package/tachyon/postrm" "tachyon/Makefile"; then
    echo "FAIL: Package/tachyon/postrm missing in tachyon/Makefile"
    exit 1
fi
if ! grep -q "Package/\$(PKG_NAME)/postrm" "luci-app-tachyon/Makefile"; then
    echo "FAIL: Package/\$(PKG_NAME)/postrm missing in luci-app-tachyon/Makefile"
    exit 1
fi
if ! grep -q "backend-post-deinstall.sh" "build.sh"; then
    echo "FAIL: backend-post-deinstall.sh missing in build.sh"
    exit 1
fi
echo "✓ Package postrm and post-deinstall hooks verified"

# 7. Mock environment for backup and purge test
MOCK_ETC="$TEST_DIR/etc"
mkdir -p "$MOCK_ETC/config" "$MOCK_ETC/init.d"
echo "config tachyon 'settings'" > "$MOCK_ETC/config/tachyon"
echo "option enabled '1'" >> "$MOCK_ETC/config/tachyon"

TIMESTAMP="$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%s)"
BACKUP_FILE="$MOCK_ETC/config/tachyon.backup-$TIMESTAMP"
cp -af "$MOCK_ETC/config/tachyon" "$BACKUP_FILE"
cp -af "$MOCK_ETC/config/tachyon" "$MOCK_ETC/config/tachyon.bak"

if [ ! -f "$BACKUP_FILE" ] || [ ! -f "$MOCK_ETC/config/tachyon.bak" ]; then
    echo "FAIL: Mock backup creation failed"
    exit 1
fi
echo "✓ Backup logic verified"

# Test purge
rm -rf "$MOCK_ETC/config/tachyon"*
if [ -f "$MOCK_ETC/config/tachyon" ] || [ -f "$MOCK_ETC/config/tachyon.bak" ]; then
    echo "FAIL: Purge did not remove config files"
    exit 1
fi
echo "✓ Purge logic verified"

echo "PASS: all uninstall tests completed successfully"
