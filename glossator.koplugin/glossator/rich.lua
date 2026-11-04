--[[--
A teacher's note: words in a handwriting font and LaTeX math ($...$ inline,
$$...$$ or \[...\] on its own line) typeset with inkai_math, wrapped to a
width.

    local L = Rich.layout(text, { width = 500, px = 40, hand = "kalam" })
    Rich.paint(L, bb, x, y, color)   -- (x, y) is the top-left corner

A character the handwriting font lacks (an arrow, a Greek letter typed
outside $...$) is drawn from the math fonts instead, so nothing comes out
as a box.
]]

local RenderText = require("ui/rendertext")
local Fonts = require("glossator/fonts")
local Math = require("glossator/math")

local Rich = {}

local max, floor = math.max, math.floor

-- Split `text` into text and math segments.
function Rich.segments(text)
    local segs = {}
    local i, n = 1, #text
    local buf = {}
    local function flush()
        if #buf > 0 then
            segs[#segs + 1] = { kind = "text", s = table.concat(buf) }
            buf = {}
        end
    end
    while i <= n do
        local c = text:sub(i, i)
        local two = text:sub(i, i + 1)
        local close, display, skip
        if two == "$$" then close, display, skip = "$$", true, 2
        elseif two == "\\[" then close, display, skip = "\\]", true, 2
        elseif two == "\\(" then close, display, skip = "\\)", false, 2
        elseif c == "$" then close, display, skip = "$", false, 1
        elseif two == "\\$" then
            buf[#buf + 1] = "$"
            i = i + 2
        end
        if close then
            local j = text:find(close, i + skip, true)
            -- a lone $ (a price) stays text
            if j and (close ~= "$" or not text:sub(i + 1, i + 1):match("%s")) then
                flush()
                segs[#segs + 1] = { kind = display and "display" or "math", s = text:sub(i + skip, j - 1) }
                i = j + #close
            else
                buf[#buf + 1] = text:sub(i, i + skip - 1)
                i = i + skip
            end
        elseif two ~= "\\$" then
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    flush()
    return segs
end

-- Light markdown clean-up: Claude is asked for none, but just in case.
local function plain(s)
    s = s:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1"):gsub("`([^`]*)`", "%1")
    s = s:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
    return s
end

-- A word of text as runs in the handwriting face, or the math faces for
-- characters it lacks.
local function wordItem(word, hand, px)
    local runs, cur_face, cur = {}, nil, {}
    local function flush()
        if #cur > 0 then
            local s = table.concat(cur)
            local m = RenderText:sizeUtf8Text(0, nil, cur_face, s, true)
            runs[#runs + 1] = { face = cur_face, s = s, w = m.x, h = m.y_top, d = m.y_bottom }
            cur = {}
        end
    end
    for _i, ch in ipairs(Math.utf8chars(word)) do
        local cp = Math.codepoint(ch)
        local face = hand
        if not Fonts.has(hand, cp) then
            local alt
            if cp >= 0x3B1 and cp <= 0x3C9 then alt = Fonts.math("italic", px)
            else
                for _i, f in ipairs({ "main", "ams", "italic" }) do
                    local ff = Fonts.math(f, px)
                    if Fonts.has(ff, cp) then alt = ff break end
                end
            end
            face = alt or hand
        end
        if face ~= cur_face then flush() cur_face = face end
        cur[#cur + 1] = ch
    end
    flush()
    local item = { kind = "word", runs = runs, w = 0, h = 0, d = 0 }
    for _i, r in ipairs(runs) do
        item.w = item.w + r.w
        item.h = max(item.h, r.h)
        item.d = max(item.d, r.d)
    end
    return item
end

-- The pieces of `text`: words, math boxes, paragraph breaks and display math,
-- each with `space` (whether a space comes before it).
local function items(text, opts)
    local px = opts.px
    local hand = Fonts.hand(opts.hand, px)
    local mpx = px * (opts.math_scale or 0.86)
    local out = {}
    local pending_space = false
    for _i, seg in ipairs(Rich.segments(plain(text))) do
        if seg.kind == "text" then
            local s = seg.s
            local pos = 1
            while pos <= #s do
                local a, b = s:find("%s+", pos)
                if a == pos then
                    if s:sub(a, b):find("\n%s*\n") or (s:sub(a, b):find("\n") and opts.keep_newlines) then
                        out[#out + 1] = { kind = "break" }
                        pending_space = false
                    else
                        pending_space = true
                    end
                    pos = b + 1
                else
                    local e = a and a - 1 or #s
                    local w = wordItem(s:sub(pos, e), hand, px)
                    w.space = pending_space
                    out[#out + 1] = w
                    pending_space = false
                    pos = e + 1
                end
            end
        elseif seg.kind == "math" then
            local box = Math.layout(seg.s, mpx, false)
            out[#out + 1] = { kind = "math", box = box, src = seg.s, w = box.w, h = box.h, d = box.d, space = pending_space }
            pending_space = false
        else
            local box = Math.layout(seg.s, mpx, true)
            out[#out + 1] = { kind = "display", box = box, src = seg.s, w = box.w, h = box.h, d = box.d }
            pending_space = true
        end
    end
    return out, hand
end

--[[--
Lay `text` out to `opts.width` pixels.
opts: width, px (handwriting em size), hand (font key), max_lines (optional:
cut there, with an ellipsis), math_scale.
@return { w, h, lines, truncated }
]]
function Rich.layout(text, opts)
    local width = opts.width
    local px = opts.px
    local list, hand = items(text or "", opts)
    local m = RenderText:sizeUtf8Text(0, nil, hand, "Hdgjy", true)
    local hand_h, hand_d = m.y_top, m.y_bottom
    local space_w = RenderText:sizeUtf8Text(0, nil, hand, " ", true).x
    local leading = floor(px * (opts.leading or 0.16))

    local lines = {}
    local line = { items = {}, w = 0, h = hand_h, d = hand_d }
    local function push()
        lines[#lines + 1] = line
        line = { items = {}, w = 0, h = hand_h, d = hand_d }
    end
    for _i, it in ipairs(list) do
        if it.kind == "break" then
            if #line.items > 0 then push() end
            line.para = true
        elseif it.kind == "display" then
            if #line.items > 0 then push() end
            local box = it.box
            if box.w > width then
                box = Math.layout(it.src, px * (opts.math_scale or 0.86) * max(0.6, width / box.w), true)
            end
            lines[#lines + 1] = { items = { { x = max(0, floor((width - box.w) / 2)), it = { kind = "math", box = box } } },
                w = math.min(width, box.w), h = box.h + floor(px * 0.12), d = box.d + floor(px * 0.12), display = true }
        else
            if it.kind == "math" and it.w > width then
                local box = Math.layout(it.src, px * (opts.math_scale or 0.86) * max(0.6, width / it.w), false)
                it = { kind = "math", box = box, w = box.w, h = box.h, d = box.d, space = it.space }
            end
            local gap = (#line.items > 0 and it.space) and space_w or 0
            if #line.items > 0 and line.w + gap + it.w > width then
                -- a word glued to the one before (punctuation after math) goes
                -- to the next line with it
                local carry
                if not it.space and #line.items > 1 then
                    carry = table.remove(line.items)
                    local prev = line.items[#line.items]
                    line.w = prev.x + prev.it.w
                end
                push()
                gap = 0
                if carry then
                    carry.x = 0
                    line.items[1] = carry
                    line.w = carry.it.w
                    line.h = max(line.h, carry.it.h or 0)
                    line.d = max(line.d, carry.it.d or 0)
                end
            end
            line.items[#line.items + 1] = { x = line.w + gap, it = it }
            line.w = line.w + gap + it.w
            line.h = max(line.h, it.h)
            line.d = max(line.d, it.d)
        end
    end
    if #line.items > 0 then push() end

    local truncated = false
    if opts.max_lines and #lines > opts.max_lines then
        truncated = true
        for i = #lines, opts.max_lines + 1, -1 do lines[i] = nil end
        -- an ellipsis at the end of the last line, making room for it
        local last = lines[#lines]
        local ell = wordItem("\u{2026}", hand, px)
        while #last.items > 1 and last.w + space_w + ell.w > width do
            local removed = table.remove(last.items)
            last.w = removed.x
        end
        last.items[#last.items + 1] = { x = last.w + space_w * 0.5, it = ell }
        last.w = last.w + space_w * 0.5 + ell.w
    end

    local y, w = 0, 0
    for i, ln in ipairs(lines) do
        if i > 1 then y = y + leading + (ln.para and floor(px * 0.35) or 0) end
        ln.base = y + ln.h
        y = ln.base + ln.d
        w = max(w, ln.w)
    end
    return { w = math.ceil(w), h = math.ceil(y), lines = lines, truncated = truncated, px = px, line_count = #lines }
end

local function paintItem(it, bb, x, base, color)
    if it.kind == "word" then
        local rx = x
        for _i, r in ipairs(it.runs) do
            RenderText:renderUtf8Text(bb, floor(rx + 0.5), floor(base + 0.5), r.face, r.s, true, false, color)
            rx = rx + r.w
        end
    elseif it.kind == "math" then
        Math.paint(it.box, bb, x, base, color)
    end
end

function Rich.paint(L, bb, x, y, color)
    for _i, ln in ipairs(L.lines) do
        for _i, e in ipairs(ln.items) do
            paintItem(e.it, bb, x + e.x, y + ln.base, color)
        end
    end
end

return Rich
