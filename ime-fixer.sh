#!/usr/bin/env bash
#
# Cold War Keyboard Fix
#
# As Steam Launch Option:
#   /path/to/ime-fixer.sh --endcomp %command%
#
# Standalone (game already running):
#   ./ime-fixer.sh --run-helper           # one-shot
#   ./ime-fixer.sh --run-helper --hotkey  # F12 to send
#   ./ime-fixer.sh --run-helper --periodic # auto every 2s
#   ./ime-fixer.sh --info                 # show status
#
set -euo pipefail

APPID="1985810"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX_EXE="$SCRIPT_DIR/codcoldwar-ime-fixer.exe"

STEAM_ROOTS=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.steam/root"
)

FALLBACK_LIBRARIES=(
    "$HOME/.local/share/Steam/steamapps"
    "$HOME/.steam/steam/steamapps"
    "$HOME/.steam/root/steamapps"
)

# --------------------------------------------------------------------------
# Helper: run sed on the first VDF file found across STEAM_ROOTS
# --------------------------------------------------------------------------
vdf_extract() {
    local relpath="$1"   # path relative to steam root, e.g. steamapps/libraryfolders.vdf
    local pattern="$2"   # sed pattern to apply
    for root in "${STEAM_ROOTS[@]}"; do
        local f="$root/$relpath"
        if [[ -f "$f" ]]; then
            sed -n "$pattern" "$f"
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------------------
# Read library paths from Steam's libraryfolders.vdf.
# The VDF format has entries like:
#   "0" { "path" "/some/dir" ... }
# --------------------------------------------------------------------------
read_steam_libraries() {
    vdf_extract "steamapps/libraryfolders.vdf" '/"path"/s/.*"path"[[:space:]]*"\(.*\)"/\1/p'
}

# --------------------------------------------------------------------------
# Read the Proton name configured for APPID from Steam's config.vdf.
# Section looks like:
#   "CompatToolMapping" { "1985810" { "name" "proton_experimental" ... } }
# --------------------------------------------------------------------------
read_proton_for_app() {
    vdf_extract "config/config.vdf" \
        '/"'$APPID'"/,/\}/{/"name"/s/.*"name"[[:space:]]*"\(.*\)"/\1/p}'
}

# --------------------------------------------------------------------------
# Map a Proton codename to its install directory name.
# Official Proton codenames from Steam:
#   proton_experimental  → "Proton - Experimental"
#   proton_8             → "Proton 8.0"
#   proton_9             → "Proton 9.0"
#   proton_10            → "Proton 10.0"
# Custom tools (GE-Proton, etc.) use the name as-is.
# --------------------------------------------------------------------------
proton_codename_to_dir() {
    local name="$1"
    case "$name" in
        proton_experimental) echo "Proton - Experimental" ;;
        proton_8)            echo "Proton 8.0" ;;
        proton_9)            echo "Proton 9.0" ;;
        proton_10)           echo "Proton 10.0" ;;
        proton_11)           echo "Proton 11.0" ;;
        proton_*)            echo "$name" ;;  # unknown future codename
        *)                   echo "$name" ;;  # custom tool (GE-Proton, etc.)
    esac
}

# --------------------------------------------------------------------------
# Search for a Proton installation directory across all known locations.
# --------------------------------------------------------------------------
search_proton_dir() {
    local dirname="$1"
    local locations=(
        "$HOME/.local/share/Steam/steamapps/common/$dirname"
        "$HOME/.local/share/Steam/compatibilitytools.d/$dirname"
        "$HOME/.steam/steam/steamapps/common/$dirname"
        "$HOME/.steam/steam/compatibilitytools.d/$dirname"
        "$HOME/.steam/root/steamapps/common/$dirname"
        "$HOME/.steam/root/compatibilitytools.d/$dirname"
    )
    for loc in "${locations[@]}"; do
        if [[ -f "$loc/proton" ]]; then
            echo "$loc"
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------------------
# Find the compatdata prefix for APPID across all Steam library paths.
# --------------------------------------------------------------------------
find_prefix() {
    if [[ -n "${WINEPREFIX:-}" && -d "$WINEPREFIX" ]]; then
        echo "$WINEPREFIX"
        return 0
    fi

    local libs=()
    local vdf_libs

    vdf_libs="$(read_steam_libraries 2>/dev/null)" || true
    if [[ -n "$vdf_libs" ]]; then
        while IFS= read -r lib; do
            libs+=("$lib/steamapps")
        done <<< "$vdf_libs"
    fi

    if [[ ${#libs[@]} -eq 0 ]]; then
        libs=("${FALLBACK_LIBRARIES[@]}")
    fi

    for lib in "${libs[@]}"; do
        local pfx="$lib/compatdata/$APPID/pfx"
        if [[ -d "$pfx" ]]; then
            echo "$pfx"
            return 0
        fi
    done

    echo "ERROR: Could not find Wine prefix for AppID $APPID" >&2
    echo "Searched in:" >&2
    for lib in "${libs[@]}"; do
        echo "  $lib/compatdata/$APPID/pfx" >&2
    done
    echo "Set WINEPREFIX=/path/to/pfx to override." >&2
    return 1
}

PREFIX="$(find_prefix)" || exit 1

# --------------------------------------------------------------------------
# Find Proton directory.
# Priority:
#   1. PROTON_DIR env var
#   2. %command% argument containing */proton
#   3. Proton name from Steam config.vdf for this AppID
#   4. Wildcard search for GE-Proton (newest)
#   5. Known official Proton versions
# --------------------------------------------------------------------------
find_proton_dir() {
    if [[ -n "${PROTON_DIR:-}" && -f "$PROTON_DIR/proton" ]]; then
        echo "$PROTON_DIR"
        return
    fi

    for arg in "$@"; do
        case "$arg" in
            */proton)
                echo "$(dirname "$arg")"
                return ;;
        esac
    done

    # Read the configured Proton version from Steam's config
    local configured
    configured="$(read_proton_for_app 2>/dev/null)" || true
    if [[ -n "$configured" ]]; then
        local dirname
        dirname="$(proton_codename_to_dir "$configured")"
        local found
        found="$(search_proton_dir "$dirname")" && {
            echo "$found"
            return
        }
    fi

    # Wildcard: try GE-Proton (newest installation)
    local ge
    ge="$(ls -1d \
        "$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton"* \
        "$HOME/.steam/steam/steamapps/common/GE-Proton"* \
        "$HOME/.steam/root/compatibilitytools.d/GE-Proton"* \
        2>/dev/null | tail -1 || true)"
    if [[ -n "$ge" && -f "$ge/proton" ]]; then
        echo "$ge"
        return
    fi

    # Known official Proton versions
    local d
    for d in \
        "$HOME/.local/share/Steam/steamapps/common/Proton - Experimental" \
        "$HOME/.local/share/Steam/steamapps/common/Proton 11.0" \
        "$HOME/.local/share/Steam/steamapps/common/Proton 10.0" \
        "$HOME/.local/share/Steam/steamapps/common/Proton 9.0" \
        "$HOME/.local/share/Steam/steamapps/common/Proton 8.0" \
        "$HOME/.steam/steam/steamapps/common/Proton - Experimental" \
        "$HOME/.steam/steam/steamapps/common/Proton 11.0" \
        "$HOME/.steam/steam/steamapps/common/Proton 10.0" \
        "$HOME/.steam/steam/steamapps/common/Proton 9.0" \
        "$HOME/.steam/steam/steamapps/common/Proton 8.0"; do
        if [[ -f "$d/proton" ]]; then
            echo "$d"
            return
        fi
    done

    echo ""
}

# --------------------------------------------------------------------------
# Check that the helper binary exists; suggest make if not.
# --------------------------------------------------------------------------
require_fix_exe() {
    if [[ ! -f "$FIX_EXE" ]]; then
        echo "Helper not built.  Run:"
        echo "  make -C \"$SCRIPT_DIR\""
        exit 1
    fi
}

# --------------------------------------------------------------------------
# --endcomp : Steam launch option — launches game alongside the helper
# --------------------------------------------------------------------------
cmd_endcomp() {
    echo "── WM_IME_ENDCOMPOSITION injection ──"
    require_fix_exe

    local proton_dir
    proton_dir="$(find_proton_dir "$@")"
    if [[ -z "$proton_dir" ]]; then
        echo "WARNING: could not find Proton directory"
        echo "Launching game without helper."
        exec "$@"
    fi

    local wine="$proton_dir/files/bin/wine64"
    if [[ ! -x "$wine" ]]; then
        echo "WARNING: wine64 not found at $wine"
        echo "Launching game without helper."
        exec "$@"
    fi

    echo "Proton : $proton_dir"
    echo "Wine   : $wine"
    echo "Helper : $FIX_EXE"
    echo "Mode   : periodic (2 s)"
    echo ""
    echo "Launching game..."

    "$@" &
    local game_pid=$!

    echo "Game PID: $game_pid"
    echo "Waiting 30 s for game to initialise..."
    sleep 30

    echo "Starting IME fix helper..."
    WINEFSYNC=1 WINEPREFIX="$PREFIX" "$wine" "$FIX_EXE" --periodic 500 --quiet &
    local helper_pid=$!
    echo "Helper PID: $helper_pid"

    cleanup() {
        if [[ -n "${helper_pid:-}" ]]; then
            kill -9 "$helper_pid" 2>/dev/null || true
            pkill -9 -P "$helper_pid" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT

    while kill -0 "$game_pid" 2>/dev/null; do
        sleep 1
    done

    echo "Game exited."
}

# --------------------------------------------------------------------------
# --run-helper : standalone, game already running
# --------------------------------------------------------------------------
cmd_run_helper() {
    require_fix_exe

    local proton_dir
    proton_dir="$(find_proton_dir)"
    if [[ -z "$proton_dir" ]]; then
        echo "Could not find Proton.  Set PROTON_DIR manually:"
        echo "  PROTON_DIR=/path/to/Proton $0 --run-helper [args]"
        exit 1
    fi

    local wine="$proton_dir/files/bin/wine64"
    if [[ ! -x "$wine" ]]; then
        echo "wine64 not found: $wine"
        exit 1
    fi

    echo "Proton : $proton_dir"
    echo "Prefix : $PREFIX"
    echo ""

    WINEFSYNC=1 WINEPREFIX="$PREFIX" "$wine" "$FIX_EXE" "$@"
}

# --------------------------------------------------------------------------
# --info : show status and available commands
# --------------------------------------------------------------------------
cmd_info() {
    echo "=== Cold War Keyboard Fix — Status ==="
    echo ""
    echo "AppID       : $APPID"
    echo "Prefix      : $PREFIX"

    if [[ -f "$FIX_EXE" ]]; then
        echo "Helper exe  : $FIX_EXE  (BUILT)"
    else
        echo "Helper exe  : NOT BUILT — run: make -C \"$SCRIPT_DIR\""
    fi

    local pd
    pd="$(find_proton_dir)"
    if [[ -n "$pd" ]]; then
        echo "Proton      : $pd"
    else
        echo "Proton      : not found"
    fi

    echo ""
    echo "=== Usage ==="
    echo ""
    echo "Steam Launch Option:"
    echo "  $0 --endcomp %command%"
    echo ""
    echo "Standalone (game already running):"
    echo "  $0 --run-helper --once       # fire once (test)"
    echo "  $0 --run-helper --hotkey     # press F12 to fire"
    echo "  $0 --run-helper --periodic   # auto every 2 s"
    echo ""
    echo "Build:"
    echo "  make -C \"$SCRIPT_DIR\""
}

# --------------------------------------------------------------------------
# Main dispatch
# --------------------------------------------------------------------------
case "${1:---info}" in
    --endcomp)
        shift
        cmd_endcomp "$@"
        ;;
    --run-helper)
        shift
        cmd_run_helper "$@"
        ;;
    --info)
        cmd_info
        ;;
    -h|--help)
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Steam Launch Option (append %command%):"
        echo "  --endcomp %command%    Inject WM_IME_ENDCOMPOSITION"
        echo ""
        echo "Standalone (game already running):"
        echo "  --run-helper [--once|--hotkey|--periodic]"
        echo ""
        echo "Info:"
        echo "  --info                 Show status and usage"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run: $0 --help"
        exit 1
        ;;
esac
