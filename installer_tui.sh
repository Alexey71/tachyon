#!/bin/sh
# shellcheck shell=dash
# ─── TUI helpers for Tachyon installer ───────────────────────────────────────
# POSIX-compatible, works with dash/bash/mksh on OpenWrt.
# Degrades gracefully when TERM is dumb or stdout is not a terminal.

# ─── Color detection ──────────────────────────────────────────────────────────
_tui_colors=0
if [ -t 1 ] 2>/dev/null; then
    case "${TERM:-dumb}" in
        dumb) _tui_colors=0 ;;
        *)    _tui_colors=1 ;;
    esac
fi

if [ "$_tui_colors" -eq 1 ]; then
    _c_reset='\033[0m'
    _c_bold='\033[1m'
    _c_dim='\033[2m'
    _c_red='\033[31;1m'
    _c_green='\033[32;1m'
    _c_yellow='\033[33;1m'
    _c_blue='\033[34;1m'
    _c_cyan='\033[36;1m'
    _c_magenta='\033[35;1m'
    _c_white='\033[37;1m'
    _c_bg_blue='\033[44m'
    _c_bg_green='\033[42m'
    _c_bg_red='\033[41m'
    _c_bg_yellow='\033[43m'
    _c_underline='\033[4m'
else
    _c_reset=''
    _c_bold=''
    _c_dim=''
    _c_red=''
    _c_green=''
    _c_yellow=''
    _c_blue=''
    _c_cyan=''
    _c_magenta=''
    _c_white=''
    _c_bg_blue=''
    _c_bg_green=''
    _c_bg_red=''
    _c_bg_yellow=''
    _c_underline=''
fi

# ─── Terminal width ──────────────────────────────────────────────────────────
_tui_width() {
    if [ -t 1 ] 2>/dev/null && command -v stty >/dev/null 2>&1; then
        w="$(stty size 2>/dev/null | awk '{print $2}')"
        [ -n "$w" ] && [ "$w" -gt 0 ] 2>/dev/null && printf '%s' "$w" && return 0
    fi
    printf '72'
}

# ─── Horizontal line ─────────────────────────────────────────────────────────
_tui_hline() {
    _w="$(_tui_width)"
    _char="${1:--}"
    _i=0
    while [ "$_i" -lt "$_w" ]; do
        printf '%s' "$_char"
        _i=$((_i + 1))
    done
}

# ─── Center text ──────────────────────────────────────────────────────────────
_tui_center() {
    _text="$1"
    _w="$(_tui_width)"
    _len=${#_text}
    _pad=$((_w - _len))
    [ "$_pad" -lt 0 ] 2>/dev/null && _pad=0
    _left=$((_pad / 2))
    _right=$((_pad - _left))
    _i=0
    while [ "$_i" -lt "$_left" ]; do
        printf ' '
        _i=$((_i + 1))
    done
    printf '%s' "$_text"
    _i=0
    while [ "$_i" -lt "$_right" ]; do
        printf ' '
        _i=$((_i + 1))
    done
}

# ─── Pad/truncate to width ──────────────────────────────────────────────────
_tui_pad() {
    _text="$1"
    _target="${2:-0}"
    _len=${#_text}
    _i=$_len
    while [ "$_i" -lt "$_target" ]; do
        printf ' '
        _i=$((_i + 1))
    done
}

# ─── Print banner ────────────────────────────────────────────────────────────
tui_banner() {
    printf '\n'
    printf '  %s%sTachyon Installer%s v%s%s\n' "$_c_cyan" "$_c_bold" "$_c_reset" "$_c_bold" "$INSTALLER_VERSION"
    printf '%s\n' ""
    printf '%s%s%s\n' "$_c_dim" "$(_tui_hline '─')" "$_c_reset"
}

# ─── Print step header ──────────────────────────────────────────────────────
tui_step() {
    _step_no="$1"
    _step_total="$2"
    _step_text="$3"
    _step_icon=""

    printf '\n'
    printf '  %s%s[ %s/%s ]%s %s%s%s\n' \
        "$_c_blue" "$_c_bold" \
        "$_step_no" "$_step_total" \
        "$_c_reset" \
        "$_c_bold" "$_step_text" "$_c_reset"
    printf '  %s%s\n' "$_c_dim" "$(_tui_hline '·')"
    printf '%s' "$_c_reset"
}

# ─── Success message ─────────────────────────────────────────────────────────
tui_ok() {
    printf '  %s%s✓%s %s\n' "$_c_green" "$_c_bold" "$_c_reset" "$1"
}

# ─── Warning message ─────────────────────────────────────────────────────────
tui_warn() {
    printf '  %s%s⚠%s %s%s\n' "$_c_yellow" "$_c_bold" "$_c_reset" "$1" "$_c_reset" >&2
}

# ─── Error message ───────────────────────────────────────────────────────────
tui_err() {
    printf '  %s%s✗%s %s%s\n' "$_c_red" "$_c_bold" "$_c_reset" "$1" "$_c_reset" >&2
    printf '  %s%s   Log: %s%s\n' "$_c_dim" "$_c_reset" "$LOG_FILE" "$_c_reset" >&2
}

# ─── Info message ────────────────────────────────────────────────────────────
tui_info() {
    printf '  %s▸%s %s\n' "$_c_cyan" "$_c_reset" "$1"
}

# ─── Download progress ───────────────────────────────────────────────────────
tui_download() {
    _label="$1"
    _attempt="${2:-1}"
    _max="${3:-3}"
    printf '  %s%s↓%s %s %s(%s/%s)%s\n' \
        "$_c_cyan" "$_c_bold" "$_c_reset" \
        "$_label" \
        "$_c_dim" "$_attempt" "$_max" "$_c_reset"
}

# ─── Progress bar ────────────────────────────────────────────────────────────
tui_progress() {
    _current="$1"
    _total="$2"
    _label="${3:-}"
    _w=$((_tui_width() - 8))
    [ "$_w" -lt 10 ] 2>/dev/null && _w=10

    _pct=0
    [ "$_total" -gt 0 ] 2>/dev/null && _pct=$((_current * 100 / _total))

    _filled=$((_pct * _w / 100))
    [ "$_filled" -gt "$_w" ] 2>/dev/null && _filled=$_w
    _empty=$((_w - _filled))

    printf '\r  %s' "$_c_dim"
    _i=0
    while [ "$_i" -lt "$_filled" ]; do
        printf '━'
        _i=$((_i + 1))
    done
    _i=0
    while [ "$_i" -lt "$_empty" ]; do
        printf '─'
        _i=$((_i + 1))
    done
    printf '%s' "$_c_reset"
    printf ' %s%3d%%%s' "$_c_bold" "$_pct" "$_c_reset"
    [ -n "$_label" ] && printf '  %s' "$_label"
}

# ─── Spinner (call in background, kill when done) ───────────────────────────
tui_spinner_start() {
    _spinner_text="${1:-Working...}"
    _spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    _spinner_pid=""

    # Only spin on real terminals
    [ -t 1 ] 2>/dev/null || { printf '  %s\n' "$_spinner_text"; return 0; }

    (
        while true; do
            for _ch in $_spinner_chars; do
                printf '\r  %s%s%s %s' "$_c_cyan" "$_ch" "$_c_reset" "$_spinner_text"
                sleep 0.1 2>/dev/null || sleep 1
            done
        done
    ) &
    _spinner_pid=$!
    printf '%s' "$_spinner_pid"
}

tui_spinner_stop() {
    _pid="$1"
    _text="${2:-}"
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        kill "$_pid" 2>/dev/null
        wait "$_pid" 2>/dev/null
    fi
    # Clear spinner line
    printf '\r%s' "$(_tui_hline ' ')"
    printf '\r'
    [ -n "$_text" ] && tui_ok "$_text"
}

# ─── Boxed section ───────────────────────────────────────────────────────────
tui_box_start() {
    _w="$(_tui_width)"
    _w=$((_w - 4))
    [ "$_w" -lt 10 ] 2>/dev/null && _w=10
    printf '\n'
    printf '  %s╔' "$_c_blue"
    _i=0; while [ "$_i" -lt "$_w" ]; do printf '═'; _i=$((_i + 1)); done
    printf '╗%s\n' "$_c_reset"
}

tui_box_line() {
    _text="$1"
    _w="$(_tui_width)"
    _w=$((_w - 4))
    _len=${#_text}
    _pad=$((_w - _len - 2))
    [ "$_pad" -lt 0 ] 2>/dev/null && _pad=0
    printf '  %s║%s %s' "$_c_blue" "$_c_reset" "$_text"
    _i=0; while [ "$_i" -lt "$_pad" ]; do printf ' '; _i=$((_i + 1)); done
    printf '%s║%s\n' "$_c_blue" "$_c_reset"
}

tui_box_line_color() {
    _text="$1"
    _color="$2"
    _w="$(_tui_width)"
    _w=$((_w - 4))
    _len=${#_text}
    _pad=$((_w - _len - 2))
    [ "$_pad" -lt 0 ] 2>/dev/null && _pad=0
    printf '  %s║%s %s%s' "$_c_blue" "$_c_reset" "$_color" "$_text"
    _i=0; while [ "$_i" -lt "$_pad" ]; do printf ' '; _i=$((_i + 1)); done
    printf '%s║%s\n' "$_c_reset" "$_c_blue"
}

tui_box_end() {
    _w="$(_tui_width)"
    _w=$((_w - 4))
    [ "$_w" -lt 10 ] 2>/dev/null && _w=10
    printf '  %s╚' "$_c_blue"
    _i=0; while [ "$_i" -lt "$_w" ]; do printf '═'; _i=$((_i + 1)); done
    printf '╝%s\n' "$_c_reset"
}

# ─── Section divider ─────────────────────────────────────────────────────────
tui_divider() {
    printf '\n  %s%s%s\n' "$_c_dim" "$(_tui_hline '─')" "$_c_reset"
}

tui_box_divider() {
    _w="$(_tui_width)"
    _w=$((_w - 4))
    [ "$_w" -lt 10 ] 2>/dev/null && _w=10
    printf '  %s║%s' "$_c_blue" "$_c_reset"
    _i=0; while [ "$_i" -lt "$_w" ]; do printf '─'; _i=$((_i + 1)); done
    printf '%s║%s\n' "$_c_blue" "$_c_reset"
}

# ─── Interactive menu (returns choice) ──────────────────────────────────────
tui_menu() {
    _prompt="$1"
    shift
    _options="$@"

    printf '\n  %s%s%s\n' "$_c_bold" "$_prompt" "$_c_reset"
    _i=1
    for _opt in $_options; do
        printf '    %s%s)%s %s\n' "$_c_cyan" "$_c_bold" "$_c_reset" "$_opt"
        _i=$((_i + 1))
    done
    printf '\n'
    printf '  %s▸%s ' "$_c_cyan" "$_c_reset"
}

# ─── Confirmation prompt ────────────────────────────────────────────────────
tui_confirm() {
    _prompt="$1"
    printf '  %s%s?%s %s %s' "$_c_yellow" "$_c_bold" "$_c_reset" "$_prompt" "$_c_dim"
    printf '(%s/%s)%s ' "y" "n" "$_c_reset"
}
