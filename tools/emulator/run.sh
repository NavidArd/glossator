#!/usr/bin/env bash
# Run KOReader's Linux build headless (Xvfb) at the Kindle Scribe's size, with
# this repo's plugins, open a book and play a scenario (see drive.lua).
#
#   KO=/path/to/koreader-linux/lib/koreader ./tools/emulator/run.sh book.pdf scenario.lua [shots_dir]
#
# KOReader's prebuilt Linux build: https://ota.koreader.rocks/ (koreader-linux-x86_64-*.tar.xz)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KO="${KO:?set KO to the koreader folder of a KOReader Linux build}"
BOOK="$(realpath "$1")"; SCEN="$(realpath "$2")"; SHOTS="$(realpath -m "${3:-$REPO/docs/screenshots}")"
HOME_DIR="${KOEMU_HOME:-/tmp/inkai-emu-home}"
# DEVICE_LAYOUT=1: data in KOReader's own folder, as on a Kindle (Project: Title expects it)
[ -n "${DEVICE_LAYOUT:-}" ] && HOME_DIR="$KO"
mkdir -p "$HOME_DIR/plugins" "$HOME_DIR/patches" "$HOME_DIR/settings" "$SHOTS"
for p in glossator.koplugin; do
    [ -d "$REPO/$p" ] && ln -sfn "$REPO/$p" "$HOME_DIR/plugins/$p"
done
# other plugins to try alongside (e.g. Project: Title): EXTRA_PLUGINS="/path/a.koplugin:/path/b.koplugin"
IFS=: read -r -a extra <<<"${EXTRA_PLUGINS:-}"
for p in "${extra[@]}"; do [ -n "$p" ] && ln -sfn "$(realpath "$p")" "$HOME_DIR/plugins/$(basename "$p")"; done
for f in "$REPO"/patches/*.lua; do [ -e "$f" ] && ln -sfn "$f" "$HOME_DIR/patches/$(basename "$f")"; done
cp "$HERE/drive.lua" "$HOME_DIR/patches/2-zz-inkai-drive.lua"
# a fresh start each run: Scribe DPI, grey screen, no first-run popups
if [ -z "${KEEP_SETTINGS:-}" ]; then
rm -f "$HOME_DIR/settings.reader.lua"* ; rm -rf "$HOME_DIR/docsettings" "$HOME_DIR/history"
[ -f "$BOOK" ] && rm -rf "${BOOK%.*}.sdr"
cat > "$HOME_DIR/settings.reader.lua" <<SET
return {
    ["screen_dpi"] = 300,
    ["color_rendering"] = false,
    ["quickstart_shown_version"] = 999999999,
    ["kopt_page_scroll"] = ${PAGE_SCROLL:-0},
    ["lastfile"] = "$BOOK",
    ["glossator_chip_delay"] = ${CHIP_DELAY:-0.5},
    ["home_dir"] = "$(dirname "$BOOK")",
    ["lastdir"] = "$( [ -d "$BOOK" ] && echo "$BOOK" || dirname "$BOOK")",
    ${EXTRA_SETTINGS:-}
}
SET
fi
rm -rf "$HOME_DIR/cache/fontlist"
# a virtual screen: start one if none is running for $DISPLAY
export DISPLAY="${DISPLAY:-:97}"
if ! pgrep -f "Xvfb ${DISPLAY}( |$)" >/dev/null 2>&1; then
    (Xvfb "$DISPLAY" -screen 0 1860x2480x24 >/dev/null 2>&1 &) ; sleep 1
fi
cd "$KO"
KO_HOME="$( [ -n "${DEVICE_LAYOUT:-}" ] && echo . || echo "$HOME_DIR")" INKAI_SCENARIO="$SCEN" INKAI_SHOTS="$SHOTS" \
EMULATE_READER_W=1860 EMULATE_READER_H=2480 SDL_AUDIODRIVER=dummy \
    timeout "${TIMEOUT:-120}" ./reader.lua "$BOOK"
