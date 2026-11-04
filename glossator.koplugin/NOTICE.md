# Third-party code and fonts

## Code

* `glossator/stylus.lua` and `glossator/penbridge.lua` are copied unchanged from [Ink Away](https://github.com/EmirErtorer/ink-away.koplugin) v4.4.0 (`ink/stylus.lua`, `ink/penbridge.lua`), which credits [Notebook](https://github.com/pierspad/notebook.koplugin) by pierspad (MIT) for the pen bridge approach. The pen bridge is on by default on Wacom-pen devices ("Keep the pen apart from the hand" in the menu); the replay test `tools/emulator/scenarios/scribepalm.lua` follows Ink Away's `tests/scribe` harness (MIT).
* `glossator/paint.lua` follows Ink Away's `ink/raster.lua` and `ink/pens.lua`: filled discs merged into one span per row, widths in millimetres, the speed-to-width curve, the taper ramp and the pencil grain hash.
* `glossator/book.lua` follows Ink Away's `ink/reader/place.lua` and `ink/reader/book.lua`: anchoring ink to the page or to a word, and placing a fixed page on the screen in single-page and continuous-scroll views.
* The live-ink pacing on the Kindle Scribe (one refresh every 20 ms) follows Ink Away's `ink/view/display.lua`.

## Fonts (in `fonts/`, SIL Open Font License 1.1)

* Kalam (Indian Type Foundry), Caveat (The Caveat Project Authors), Patrick Hand (Patrick Wagesreiter): the handwriting of the notes. Licences: `fonts/OFL-kalam.txt`, `fonts/OFL-caveat.txt`, `fonts/OFL-patrickhand.txt`.
* KaTeX fonts (Design Science, Khan Academy): `KaTeX_Main`, `KaTeX_Math`, `KaTeX_Size1/2`, `KaTeX_AMS`, `KaTeX_Caligraphic`, `KaTeX_Fraktur`, for the math. Licence: `fonts/OFL-katex.txt`. Taken from the `katex` npm package (0.16.11); KaTeX's code is not included, only the fonts.

## Ink Away's licence

```
MIT License

Copyright (c) 2026 Emir Devlet Ertörer (@EmirErtorer)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
