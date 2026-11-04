--[[--
The fonts Ink AI bundles in its own `fonts/` folder, as faces KOReader's
RenderText can draw with.

KOReader's Font:getFace only finds fonts in its font folders, so faces are
made here straight from the files, with the fields RenderText uses (ftsize,
hash, orig_size). A glyph a face lacks still falls back to KOReader's own
fallback fonts.

Sizes are in screen pixels (the em size), not points.
]]

local Device = require("device")
local Freetype = require("ffi/freetype")
local logger = require("logger")
local Screen = Device.screen

local Fonts = {}

-- This plugin's folder, wherever it was installed.
Fonts.dir = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*/[^/]*$") or ".") .. "/fonts"

Fonts.HANDS = {
    kalam = { file = "Kalam-Regular.ttf", label = "Kalam", scale = 1.08 },
    caveat = { file = "Caveat.ttf", label = "Caveat", scale = 1.22 },
    patrick = { file = "PatrickHand-Regular.ttf", label = "Patrick Hand", scale = 1.08 },
}

-- KaTeX's fonts (OFL), TeX's look, for math.
Fonts.MATH = {
    main = "KaTeX_Main-Regular.ttf",
    bold = "KaTeX_Main-Bold.ttf",
    textit = "KaTeX_Main-Italic.ttf",
    italic = "KaTeX_Math-Italic.ttf",
    bolditalic = "KaTeX_Math-BoldItalic.ttf",
    size1 = "KaTeX_Size1-Regular.ttf",
    size2 = "KaTeX_Size2-Regular.ttf",
    ams = "KaTeX_AMS-Regular.ttf",
    cal = "KaTeX_Caligraphic-Regular.ttf",
    frak = "KaTeX_Fraktur-Regular.ttf",
}

local cache = {}

local function dpiScale()
    local ok, s = pcall(Screen.scaleBySize, Screen, 1000)
    return (ok and s and s > 0) and s / 1000 or 1
end

--[[--
A face for `file` (a name in fonts/) at `px` pixels, or nil if it can't load.
]]
function Fonts.face(file, px)
    px = math.max(6, math.floor(px + 0.5))
    local key = file .. "@" .. px
    local f = cache[key]
    if f then return f end
    local path = Fonts.dir .. "/" .. file
    local ok, ftsize = pcall(Freetype.newFaceSize, path, px)
    if not ok then
        logger.warn("InkAI: cannot load font", path, ftsize)
        return nil
    end
    f = {
        orig_font = path,
        realname = path,
        size = px,
        -- RenderText asks the fallback fonts for this size, which Font scales by DPI again
        orig_size = math.max(4, math.floor(px / dpiScale() + 0.5)),
        ftsize = ftsize,
        hash = "inkai:" .. key,
        is_real_bold = file:find("Bold") ~= nil,
        hb_features = { "+kern", "+liga" },
    }
    cache[key] = f
    return f
end

function Fonts.math(kind, px)
    return Fonts.face(Fonts.MATH[kind] or Fonts.MATH.main, px)
end

-- The handwriting face chosen in the menu, at `px`, with its tuned scale.
function Fonts.hand(name, px)
    local h = Fonts.HANDS[name] or Fonts.HANDS.kalam
    return Fonts.face(h.file, px * h.scale) or Fonts.math("main", px)
end

function Fonts.has(face, charcode)
    if not face then return false end
    local ok, r = pcall(face.ftsize.hasGlyph, face.ftsize, charcode)
    return ok and r
end

return Fonts
