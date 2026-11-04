# Emulator toolkit

Runs KOReader's prebuilt Linux build headless (Xvfb) at the Kindle Scribe's size
(1860x2480, 300 dpi) with Glossator, opens a book and plays a
scenario: pen strokes go through KOReader's real stylus callback (as the Scribe's
Wacom pen does), finger taps through the gesture path, and screenshots are
written with `Screen:shot`.

```bash
curl -O https://ota.koreader.rocks/koreader-linux-x86_64-v2026.07.2.tar.xz
```

```bash
tar xf koreader-linux-x86_64-v2026.07.2.tar.xz
```

```bash
KO=$PWD/lib/koreader tools/emulator/run.sh book.pdf tools/emulator/scenarios/final.lua docs/screenshots
```

* `scenarios/final.lua`: circle a formula, write "why?", Ask AI, the teacher's note, open it, the Kindle bars and the AI menu.
* `scenarios/flows.lua` then `scenarios/reopen.lua` (with `KEEP_SETTINGS=1`): missing key, follow-up thread, eraser, delete, and persistence after a restart. Writes PASS/FAIL lines to `flows.txt`.
* `scenarios/fixes.lua` (with `EMULATE_BB_TYPE=BB8 EXTRA_PLUGINS=/path/to/ink-away.koplugin` to match the Kindle): pen taps and long-presses, the follow-up card and its pad, Reset. Writes `fixes.txt`.
* `scenarios/chiptiming.lua` (with `CHIP_DELAY=1.6`, the plugin's own delay; other scenarios use 0.5 s to run quicker): the Ask AI chip waits while the pen hovers, sits away from where you'd write next, and hides when you write again. Writes `chip.txt`.
* `scenarios/tools.lua`: the writing toolbar (pen widths, marker to highlight, precise eraser, lasso move/delete, undo/redo), Ask AI on selected text, Markdown export, the top bar's pen button. Writes `tools.txt`.
* `scenarios/scroll.lua` and `scenarios/scrollstable.lua` (with `PAGE_SCROLL=1 EXTRA_SETTINGS='["kindleui_full_page"] = false,'`, since the Kindle look otherwise turns PDFs to one page per screen): continuous scroll, and a note keeping its place on the page while scrolling (`scroll.txt`).
* `scenarios/palmkeys.lua` (with `EXTRA_SETTINGS='["virtual_keyboard_enabled"] = true,'`): the palm guard, the key file choosing Anthropic or OpenRouter, and the follow-up's on-screen keyboard staying up. Writes `palmkeys.txt`.
* `scenarios/scribepalm.lua`: a hand resting on a Kindle Scribe's glass while the pen writes, as evdev frames from the pen and the touch panel through KOReader's real Input (after Ink Away's `tests/scribe` harness), with and without the pen bridge. Writes `scribepalm.txt`.
* `scenarios/export.lua`: AI notes in KOReader's Export highlights, from the open book and closed books, and through the Markdown target. Writes `export.txt`.
* `scenarios/readme.lua` (with the on-screen keyboard on): the README's conversation, keyboard and model-menu screenshots.
* `scenarios/epub.lua`: an EPUB, then a bigger font (the ink follows its word).
* `scenarios/library.lua` (with `DEVICE_LAYOUT=1 EXTRA_PLUGINS=/path/to/projecttitle.koplugin` and `["plugins_disabled"]={["coverbrowser"]=true}` in `EXTRA_SETTINGS`): Project: Title's cover grid. Run it twice: Project: Title installs its fonts and restarts KOReader the first time.

No API key is used: the scenarios put a canned reply in `inkai_mock.txt` (or `glossator_mock.txt`) in
KOReader's data folder, which Glossator uses instead of the network when present.

`testbook/` makes the test PDF (`node mk.js $PWD/book.html out.pdf`, with
Playwright and KaTeX's `dist/` next to it) and the EPUB (`pandoc notes.md -o notes.epub`).
The text is original.
