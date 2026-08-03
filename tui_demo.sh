#!/bin/sh
. /tachyon/installer_tui.sh
INSTALLER_VERSION="1.2.56"

tui_banner

tui_step 1 10 "Updating package lists"
tui_ok "Package lists updated"

tui_step 2 10 "Resolving latest Tachyon release version"
tui_info "Fetching release metadata..."
tui_ok "Resolved: 1.2.56"

tui_step 3 10 "Downloading Tachyon release packages"
tui_download "tachyon_1.2.56.apk" 1 3
tui_download "luci-app-tachyon_1.2.56.apk" 2 3
tui_download "sha256sums.txt" 3 3
tui_ok "All packages downloaded"

tui_step 4 10 "Installing Tachyon backend package"
tui_info "Ensuring optional kernel module dependencies..."
tui_warn "Could not install kmod-inet-diag (built-in)"
tui_ok "tachyon 1.2.56 installed"

tui_step 5 10 "Done"

tui_box_start
tui_box_line_color "Tachyon 1.2.56 installed successfully (42s)" "$_c_green"
tui_box_line "Release: Dushnilin/tachyon@1.2.56"
tui_box_line "Log: /tmp/tachyon-install.log"
tui_box_divider
tui_box_line_color "Open LuCI and review your rules before enabling Tachyon" "$_c_yellow"
tui_box_end
