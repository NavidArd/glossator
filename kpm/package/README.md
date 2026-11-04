# Glossator

A KOReader plugin for pen e-readers (made on a Kindle Scribe). Write or circle on the
page with the pen, tap **Ask AI**, and the answer is handwritten into the margin next to
your ink, with real math.

- Needs KOReader in `/mnt/us/koreader` (`;kpm install koreader`).
- Installs to `/mnt/us/koreader/plugins/glossator.koplugin`. Restart KOReader, then
  open **Tools → Glossator**.
- Put your API key (Anthropic `sk-ant-…` or OpenRouter `sk-or-…`) in
  `/mnt/us/koreader/glossator_key.txt`.
- Uninstalling keeps your notes, ink and key file.

Source, screenshots and full instructions: https://github.com/NavidArd/glossator

License: MIT (see LICENSE). Includes code from Ink Away (MIT) and fonts under the SIL
Open Font License 1.1; see `glossator.koplugin/NOTICE.md`.
