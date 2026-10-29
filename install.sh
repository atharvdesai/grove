#!/usr/bin/env bash
#
# Grove installer — builds from source and installs the app and the CLI.
#
#   curl -fsSL https://raw.githubusercontent.com/atharvdesai/grove/main/install.sh | bash
#
# Building locally is not a workaround, it is the point: an app compiled on your
# own machine never carries a quarantine flag, so there is no Gatekeeper wall and
# nothing to strip. It also means the binary you run is the source you can read.
#
# Re-running updates an existing install. `--uninstall` removes everything.
#
# Overrides, mostly for testing:
#   GROVE_SRC      where the checkout lives      (default ~/.grove/src)
#   GROVE_APP_DIR  where Grove.app is installed   (default /Applications)
#   GROVE_BIN_DIR  where the grove CLI is linked  (default /usr/local/bin)
set -euo pipefail

REPO="${GROVE_REPO:-https://github.com/atharvdesai/grove.git}"
SRC="${GROVE_SRC:-$HOME/.grove/src}"
APP_DIR="${GROVE_APP_DIR:-/Applications}"
BIN_DIR="${GROVE_BIN_DIR:-/usr/local/bin}"

if [ -t 1 ]; then
    bold=$(tput bold); dim=$(tput dim); red=$(tput setaf 1); green=$(tput setaf 2); reset=$(tput sgr0)
else
    bold=""; dim=""; red=""; green=""; reset=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
warn() { printf '%swarning:%s %s\n' "$red" "$reset" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

uninstall() {
    step "Removing Grove"
    for app in "$APP_DIR/Grove.app" "$HOME/Applications/Grove.app"; do
        [ -e "$app" ] && rm -rf "$app" && say "  removed $app"
    done
    for cli in "$BIN_DIR/grove" "$HOME/.local/bin/grove"; do
        [ -L "$cli" ] || [ -f "$cli" ] && rm -f "$cli" && say "  removed $cli"
    done

    # Only ever the checkout itself. Deleting its parent would be correct for
    # the default ~/.grove/src and catastrophic for anyone who pointed GROVE_SRC
    # at, say, ~/code/grove — that would take ~/code with it. The parent is
    # cleaned up only if removing the checkout left it empty.
    if [ -d "$SRC" ]; then
        rm -rf "$SRC" && say "  removed $SRC"
        rmdir "$(dirname "$SRC")" 2>/dev/null && say "  removed $(dirname "$SRC")"
    fi
    say ""
    say "Your meetings in ~/Documents/Grove were left alone. They are plain"
    say "Markdown and JSON, and they are yours."
    exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# ── Preflight ────────────────────────────────────────────────────────────────
# Checked up front and explained, because every one of these fails confusingly
# later: a wrong macOS gives screenfuls of missing-symbol errors, and a missing
# toolchain gives "swift: command not found" halfway through a build.

[ "$(uname -s)" = "Darwin" ] || die "Grove is macOS only."

if [ "$(uname -m)" != "arm64" ]; then
    die "Grove needs Apple Silicon. This Mac reports $(uname -m)."
fi

macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$macos_major" -lt 26 ]; then
    die "Grove needs macOS 26 or newer; this is $(sw_vers -productVersion).
       The on-device speech and language models it depends on do not exist
       on earlier versions, so there is no fallback to offer."
fi

if ! command -v git >/dev/null 2>&1; then
    die "git not found. Run: xcode-select --install"
fi

if ! command -v swift >/dev/null 2>&1; then
    die "The Swift toolchain was not found. Install the Command Line Tools:
           xcode-select --install
       then run this again."
fi

# ── Source ───────────────────────────────────────────────────────────────────
if [ -d "$SRC/.git" ]; then
    step "Updating $SRC"
    git -C "$SRC" fetch --quiet origin
    git -C "$SRC" reset --hard --quiet origin/main
else
    step "Cloning into $SRC"
    mkdir -p "$(dirname "$SRC")"
    rm -rf "$SRC"
    git clone --quiet --depth 1 "$REPO" "$SRC"
fi

# ── Build ────────────────────────────────────────────────────────────────────
step "Building the engine and CLI (first build takes a minute or two)"
swift build -c release --package-path "$SRC/GroveKit"

step "Building Grove.app"
( cd "$SRC/GroveApp" && ./scripts/bundle.sh release >/dev/null )

# ── Install ──────────────────────────────────────────────────────────────────
install_app() {
    local target="$1"
    rm -rf "$target/Grove.app"
    # ditto rather than cp: it preserves the bundle's metadata and the ad-hoc
    # signature, which a plain recursive copy can disturb.
    ditto "$SRC/GroveApp/build/Grove.app" "$target/Grove.app"
}

step "Installing"
if [ -w "$APP_DIR" ] || [ "$(id -u)" = "0" ]; then
    install_app "$APP_DIR"
    installed_app="$APP_DIR/Grove.app"
else
    mkdir -p "$HOME/Applications"
    install_app "$HOME/Applications"
    installed_app="$HOME/Applications/Grove.app"
    warn "$APP_DIR is not writable, so Grove went to ~/Applications instead."
fi
say "  $installed_app"

cli_note=""
if [ -w "$BIN_DIR" ]; then
    ln -sf "$SRC/GroveKit/.build/release/grove" "$BIN_DIR/grove"
    say "  $BIN_DIR/grove"
else
    mkdir -p "$HOME/.local/bin"
    ln -sf "$SRC/GroveKit/.build/release/grove" "$HOME/.local/bin/grove"
    say "  $HOME/.local/bin/grove"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) cli_note="Add ~/.local/bin to your PATH to use the 'grove' command." ;;
    esac
fi

# ── Done ─────────────────────────────────────────────────────────────────────
say ""
printf '%sGrove is installed.%s\n' "$green" "$reset"
say ""
say "  open -a Grove            start the app"
say "  grove doctor             check permissions and models"
say ""
say "${dim}On first run macOS will ask for microphone and system-audio access;"
say "both are needed to hear the two sides of a call. Note enhancement also"
say "needs Apple Intelligence enabled in System Settings — without it you"
say "still get transcripts, just not written-up notes. 'grove doctor' will"
say "tell you either way.${reset}"
[ -n "$cli_note" ] && { say ""; warn "$cli_note"; }
say ""
say "${dim}Update: re-run this installer.  Remove: install.sh --uninstall${reset}"
