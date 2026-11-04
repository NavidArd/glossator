--[[--
A small TeX math typesetter, in Lua, for Claude's notes: it parses a subset of
LaTeX math and lays it out in boxes the way TeX does (scripts, fractions,
roots, big operators, stretchy delimiters, matrices, accents), drawn with
KaTeX's fonts (OFL, bundled in fonts/). Everything happens on the device,
offline.

    local box = Math.layout("\\frac{\\partial L}{\\partial \\dot q}", 40)
    Math.paint(box, bb, x, baseline, color)

A box is { w, h, d, items }: its width, height above the baseline and depth
below it, in pixels. Inside a box y grows upwards from the baseline, as in TeX.
Items are glyph runs, rules, lines and nested boxes.

Unknown commands are shown by name rather than failing, so a note always
renders.
]]

local RenderText = require("ui/rendertext")
local logger = require("logger")
local Fonts = require("glossator/fonts")

local Math = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

------------------------------------------------------------------------------
-- Symbols
------------------------------------------------------------------------------

-- command -> { char, font, class }. Classes are TeX's: ord, op, bin, rel,
-- open, close, punct.
local S = {}
local function def(class, font, list)
    for name, ch in pairs(list) do S[name] = { ch, font, class } end
end

def("ord", "italic", {
    alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ϵ", varepsilon = "ε",
    zeta = "ζ", eta = "η", theta = "θ", vartheta = "ϑ", iota = "ι", kappa = "κ",
    lambda = "λ", mu = "μ", nu = "ν", xi = "ξ", pi = "π", varpi = "ϖ", rho = "ρ",
    varrho = "ϱ", sigma = "σ", varsigma = "ς", tau = "τ", upsilon = "υ", phi = "ϕ",
    varphi = "φ", chi = "χ", psi = "ψ", omega = "ω",
})
def("ord", "main", {
    Gamma = "Γ", Delta = "Δ", Theta = "Θ", Lambda = "Λ", Xi = "Ξ", Pi = "Π",
    Sigma = "Σ", Upsilon = "Υ", Phi = "Φ", Psi = "Ψ", Omega = "Ω",
    hbar = "ℏ", ell = "ℓ", nabla = "∇", partial = "∂", infty = "∞", prime = "′",
    emptyset = "∅", varnothing = "∅", forall = "∀", exists = "∃", neg = "¬", lnot = "¬",
    dagger = "†", ddagger = "‡", ldots = "…", dots = "…", cdots = "⋯", vdots = "⋮",
    ddots = "⋱", aleph = "ℵ", Re = "ℜ", Im = "ℑ", angle = "∠", triangle = "△",
    top = "⊤", bot = "⊥", wp = "℘", flat = "♭", sharp = "♯", natural = "♮",
    clubsuit = "♣", checkmark = "✓", degree = "°", S = "§", P = "¶",
    ["#"] = "#", ["%"] = "%", ["&"] = "&", ["_"] = "_", ["$"] = "$",
})
def("ord", "ams", { Box = "□", square = "□", hslash = "ℏ", varkappa = "ϰ", digamma = "ϝ" })
def("bin", "main", {
    pm = "±", mp = "∓", times = "×", div = "÷", cdot = "⋅", ast = "∗", star = "⋆",
    circ = "∘", bullet = "∙", oplus = "⊕", otimes = "⊗", ominus = "⊖", odot = "⊙",
    cup = "∪", cap = "∩", wedge = "∧", land = "∧", vee = "∨", lor = "∨",
    setminus = "∖", sqcup = "⊔", sqcap = "⊓", uplus = "⊎", amalg = "⨿", diamond = "⋄",
    bigtriangleup = "△", bigtriangledown = "▽", wr = "≀",
})
def("rel", "main", {
    leq = "≤", le = "≤", geq = "≥", ge = "≥", neq = "≠", ne = "≠", approx = "≈",
    equiv = "≡", sim = "∼", simeq = "≃", cong = "≅", propto = "∝", ll = "≪", gg = "≫",
    ["in"] = "∈", notin = "∉", ni = "∋", subset = "⊂", supset = "⊃", subseteq = "⊆",
    supseteq = "⊇", to = "→", rightarrow = "→", leftarrow = "←", gets = "←",
    Rightarrow = "⇒", Leftarrow = "⇐", Leftrightarrow = "⇔", leftrightarrow = "↔",
    iff = "⇔", implies = "⇒", impliedby = "⇐", mapsto = "↦", longrightarrow = "⟶",
    longleftarrow = "⟵", Longrightarrow = "⟹", longmapsto = "⟼", uparrow = "↑",
    downarrow = "↓", updownarrow = "↕", nearrow = "↗", searrow = "↘",
    rightleftharpoons = "⇌", hookrightarrow = "↪", perp = "⊥", parallel = "∥", mid = "∣",
    doteq = "≐", asymp = "≍", prec = "≺", succ = "≻", preceq = "⪯", succeq = "⪰",
    vdash = "⊢", models = "⊨", bowtie = "⋈", smile = "⌣", frown = "⌢",
})
def("rel", "ams", { lesssim = "≲", gtrsim = "≳", coloneqq = "≔", triangleq = "≜", leqslant = "⩽", geqslant = "⩾" })
def("op", "size1", {
    sum = "∑", prod = "∏", coprod = "∐", int = "∫", iint = "∬", iiint = "∭",
    oint = "∮", bigcup = "⋃", bigcap = "⋂", bigoplus = "⨁", bigotimes = "⨂",
    bigodot = "⨀", bigvee = "⋁", bigwedge = "⋀", bigsqcup = "⨆",
})
def("open", "main", { langle = "⟨", lbrace = "{", ["{"] = "{", lfloor = "⌊", lceil = "⌈", lvert = "|", lVert = "‖" })
def("close", "main", { rangle = "⟩", rbrace = "}", ["}"] = "}", rfloor = "⌋", rceil = "⌉", rvert = "|", rVert = "‖" })
def("ord", "main", { vert = "|", Vert = "‖", ["|"] = "‖", backslash = "\\" })

-- Upright operator names; `true` takes limits under/over in display style.
local FUNCS = {
    sin = false, cos = false, tan = false, cot = false, sec = false, csc = false,
    sinh = false, cosh = false, tanh = false, coth = false, arcsin = false, arccos = false,
    arctan = false, exp = false, log = false, ln = false, lg = false, det = true, tr = false,
    Tr = false, dim = false, ker = false, deg = false, arg = false, hom = false, lim = true,
    max = true, min = true, sup = true, inf = true, limsup = true, liminf = true,
    gcd = true, Pr = true, mod = false, bmod = false, sgn = false, rank = false,
    span = false, diag = false, Res = false, Var = false, Cov = false,
}

-- Spaces, in em.
local SPACES = {
    [","] = 3 / 18, [":"] = 4 / 18, [">"] = 4 / 18, [";"] = 5 / 18, ["!"] = -3 / 18,
    [" "] = 0.3, quad = 1, qquad = 2, thinspace = 3 / 18, medspace = 4 / 18,
    thickspace = 5 / 18, enspace = 0.5, negthinspace = -3 / 18,
}

local DELIMS = {
    ["("] = "(", [")"] = ")", ["["] = "[", ["]"] = "]", ["|"] = "|", ["."] = "",
    ["\\{"] = "{", ["\\}"] = "}", ["\\lbrace"] = "{", ["\\rbrace"] = "}",
    ["\\langle"] = "⟨", ["\\rangle"] = "⟩", ["\\|"] = "‖", ["\\Vert"] = "‖",
    ["\\vert"] = "|", ["\\lvert"] = "|", ["\\rvert"] = "|", ["\\lVert"] = "‖",
    ["\\rVert"] = "‖", ["\\lfloor"] = "⌊", ["\\rfloor"] = "⌋", ["\\lceil"] = "⌈",
    ["\\rceil"] = "⌉", ["<"] = "⟨", [">"] = "⟩", ["/"] = "/",
}

-- Single characters: their font and class.
local CHAR_CLASS = {
    ["+"] = "bin", ["-"] = "bin", ["*"] = "bin", ["="] = "rel", ["<"] = "rel",
    [">"] = "rel", [":"] = "rel", [","] = "punct", [";"] = "punct", ["("] = "open",
    ["["] = "open", [")"] = "close", ["]"] = "close", ["!"] = "close", ["?"] = "close",
    ["."] = "ord", ["/"] = "ord", ["'"] = "ord", ["|"] = "ord",
}
local UNI_CLASS = {
    ["±"] = "bin", ["∓"] = "bin", ["×"] = "bin", ["÷"] = "bin", ["·"] = "bin", ["⋅"] = "bin",
    ["∘"] = "bin", ["⊗"] = "bin", ["⊕"] = "bin", ["∪"] = "bin", ["∩"] = "bin", ["−"] = "bin",
    ["≤"] = "rel", ["≥"] = "rel", ["≠"] = "rel", ["≈"] = "rel", ["≡"] = "rel", ["∼"] = "rel",
    ["∝"] = "rel", ["→"] = "rel", ["←"] = "rel", ["⇒"] = "rel", ["⇔"] = "rel", ["↔"] = "rel",
    ["∈"] = "rel", ["⊂"] = "rel", ["⊆"] = "rel", ["↦"] = "rel", ["≃"] = "rel", ["≅"] = "rel",
    ["∑"] = "op", ["∏"] = "op", ["∫"] = "op", ["∮"] = "op", ["∬"] = "op",
    ["⟨"] = "open", ["⟩"] = "close",
}

------------------------------------------------------------------------------
-- Tokenizer and parser
------------------------------------------------------------------------------

-- The code point of one UTF-8 character.
local function codepoint(ch)
    local b1, b2, b3, b4 = ch:byte(1, 4)
    if not b1 then return 0 end
    if b1 < 0x80 then return b1 end
    if b1 < 0xE0 then return (b1 % 0x20) * 0x40 + (b2 or 0) % 0x40 end
    if b1 < 0xF0 then return ((b1 % 0x10) * 0x40 + (b2 or 0) % 0x40) * 0x40 + (b3 or 0) % 0x40 end
    return (((b1 % 0x08) * 0x40 + (b2 or 0) % 0x40) * 0x40 + (b3 or 0) % 0x40) * 0x40 + (b4 or 0) % 0x40
end
Math.codepoint = codepoint

local function utf8chars(s)
    local out = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
    return out
end

local function tokenize(src)
    local toks = {}
    local chars = utf8chars(src)
    local i, n = 1, #chars
    while i <= n do
        local c = chars[i]
        if c == "\\" then
            local j = i + 1
            if j <= n and chars[j]:match("^%a$") then
                local name = {}
                while j <= n and chars[j]:match("^%a$") do
                    name[#name + 1] = chars[j]
                    j = j + 1
                end
                toks[#toks + 1] = { t = "cmd", v = table.concat(name) }
                -- a space after a command word only ends it
                while j <= n and chars[j]:match("^%s$") do j = j + 1 end
                i = j
            elseif j <= n then
                toks[#toks + 1] = { t = "cmd", v = chars[j] }
                i = j + 1
            else
                i = j
            end
        elseif c:match("^%s$") then
            toks[#toks + 1] = { t = "space" }
            i = i + 1
        elseif c == "{" or c == "}" or c == "^" or c == "_" or c == "&" then
            toks[#toks + 1] = { t = c }
            i = i + 1
        else
            toks[#toks + 1] = { t = "char", v = c }
            i = i + 1
        end
    end
    return toks
end

local Parser = {}
Parser.__index = Parser

local function newParser(src)
    return setmetatable({ toks = tokenize(src), i = 1 }, Parser)
end

function Parser:peek()
    return self.toks[self.i]
end

function Parser:next()
    local t = self.toks[self.i]
    self.i = self.i + 1
    return t
end

function Parser:skipSpaces()
    while self:peek() and self:peek().t == "space" do self.i = self.i + 1 end
end

-- A raw group's text: {abc} -> "abc" (for \text, \begin{...}, \operatorname).
function Parser:rawGroup()
    self:skipSpaces()
    local t = self:peek()
    if not t then return "" end
    if t.t ~= "{" then
        self:next()
        return t.v or ""
    end
    self:next()
    local depth, out = 1, {}
    while true do
        t = self:next()
        if not t then break end
        if t.t == "{" then depth = depth + 1
        elseif t.t == "}" then
            depth = depth - 1
            if depth == 0 then break end
        end
        if t.t == "cmd" then
            local sym = S[t.v]
            if sym then out[#out + 1] = sym[1]
            elseif SPACES[t.v] then out[#out + 1] = " "
            else out[#out + 1] = "\\" .. t.v end
        elseif t.t == "space" then out[#out + 1] = " "
        elseif t.t == "{" or t.t == "}" then -- nested braces vanish
        else out[#out + 1] = t.v or t.t end
    end
    return table.concat(out)
end

-- One argument: a {group} or a single token, as a node list.
function Parser:arg()
    self:skipSpaces()
    local t = self:peek()
    if not t then return { t = "list", items = {} } end
    if t.t == "{" then
        self:next()
        local list = self:list("}")
        return list
    end
    local atom = self:atom()
    return { t = "list", items = { atom } }
end

-- An optional [arg].
function Parser:optArg()
    self:skipSpaces()
    local t = self:peek()
    if t and t.t == "char" and t.v == "[" then
        self:next()
        local list = self:list("]")
        return list
    end
end

function Parser:delimiter()
    self:skipSpaces()
    local t = self:next()
    if not t then return "" end
    local key = t.t == "cmd" and ("\\" .. t.v) or (t.v or t.t)
    return DELIMS[key] or (S[t.v or ""] and S[t.v][1]) or key
end

local function sym(ch, font, class)
    return { t = "sym", ch = ch, font = font, class = class }
end

local STYLE_FONTS = {
    mathrm = "main", textrm = "main", text = "text", textnormal = "text", mbox = "text",
    mathbf = "bold", textbf = "boldtext", mathcal = "cal", mathscr = "cal", mathbb = "ams",
    mathfrak = "frak", mathit = "textit", textit = "textit", emph = "textit",
    boldsymbol = "bolditalic", bm = "bolditalic", mathsf = "main", mathtt = "main",
    operatorname = "op",
}

local ACCENTS = {
    vec = "vec", hat = "hat", widehat = "hat", bar = "bar", overline = "bar",
    dot = "dot", ddot = "ddot", tilde = "tilde", widetilde = "tilde", check = "check",
    breve = "check", underline = "under", overrightarrow = "vec",
}

local BIGS = { big = 1.2, Big = 1.6, bigg = 2.1, Bigg = 2.6, bigl = 1.2, bigr = 1.2,
    Bigl = 1.6, Bigr = 1.6, biggl = 2.1, biggr = 2.1, Biggl = 2.6, Biggr = 2.6 }

local MATRIX_DELIMS = {
    matrix = { "", "" }, pmatrix = { "(", ")" }, bmatrix = { "[", "]" }, Bmatrix = { "{", "}" },
    vmatrix = { "|", "|" }, Vmatrix = { "‖", "‖" }, smallmatrix = { "", "" },
    cases = { "{", "" }, aligned = { "", "" }, align = { "", "" }, ["align*"] = { "", "" },
    array = { "", "" }, gathered = { "", "" }, split = { "", "" }, dcases = { "{", "" },
    psmallmatrix = { "(", ")" }, bsmallmatrix = { "[", "]" },
}

-- One atom (without its scripts).
function Parser:atom()
    local t = self:next()
    if not t then return nil end
    if t.t == "{" then
        return self:list("}")
    elseif t.t == "char" then
        local c = t.v
        if c:match("^%a$") then return sym(c, "italic", "ord") end
        if c:match("^%d$") or c == "." then return sym(c, "main", "ord") end
        if c == "-" then return sym("−", "main", "bin") end
        if c == "'" then return { t = "prime" } end
        if c == "~" then return { t = "space", em = 0.3 } end
        local uc = UNI_CLASS[c]
        if uc == "op" then return sym(c, "size1", "op") end
        local class = CHAR_CLASS[c] or uc or "ord"
        -- Greek letters typed as Unicode are italic, like \alpha
        local cp = codepoint(c)
        if cp >= 0x3B1 and cp <= 0x3C9 then return sym(c, "italic", "ord") end
        return sym(c, "main", class)
    elseif t.t == "cmd" then
        local name = t.v
        if name == "frac" or name == "dfrac" or name == "tfrac" or name == "cfrac" then
            local num = self:arg()
            local den = self:arg()
            return { t = "frac", num = num, den = den, small = name == "tfrac", big = name == "dfrac" }
        elseif name == "binom" or name == "dbinom" or name == "tbinom" or name == "choose" then
            local num = self:arg()
            local den = self:arg()
            return { t = "frac", num = num, den = den, nobar = true, l = "(", r = ")" }
        elseif name == "sqrt" then
            local index = self:optArg()
            return { t = "sqrt", body = self:arg(), index = index }
        elseif ACCENTS[name] then
            return { t = "accent", acc = ACCENTS[name], body = self:arg() }
        elseif STYLE_FONTS[name] then
            local style = STYLE_FONTS[name]
            if style == "text" or style == "boldtext" or style == "op" or (style == "textit" and name ~= "mathit") then
                return { t = "text", s = self:rawGroup(), font = style == "boldtext" and "bold"
                    or style == "textit" and "textit" or "main", op = style == "op" }
            end
            return { t = "font", font = style, body = self:arg() }
        elseif name == "left" then
            local l = self:delimiter()
            local body = self:list("right")
            local r = self:delimiter()
            return { t = "left", l = l, r = r, body = body }
        elseif name == "right" then
            return nil -- handled by list()
        elseif BIGS[name] then
            return { t = "bigdelim", ch = self:delimiter(), scale = BIGS[name] }
        elseif name == "begin" then
            local env = self:rawGroup()
            if env == "array" then self:rawGroup() end -- column spec
            return self:matrix(env)
        elseif name == "end" then
            self:rawGroup()
            return nil
        elseif name == "not" then
            local a = self:atom()
            return { t = "not", body = a }
        elseif name == "overset" or name == "stackrel" then
            local over = self:arg()
            local base = self:arg()
            return { t = "over", over = over, body = base }
        elseif name == "underset" then
            local under = self:arg()
            local base = self:arg()
            return { t = "over", under = under, body = base }
        elseif name == "pmod" then
            return { t = "list", items = {
                { t = "space", em = 0.6 }, sym("(", "main", "open"), { t = "text", s = "mod", font = "main" },
                { t = "space", em = 0.3 }, self:arg(), sym(")", "main", "close") } }
        elseif name == "boxed" or name == "fbox" then
            return { t = "boxed", body = self:arg() }
        elseif name == "color" or name == "textcolor" or name == "label" or name == "tag" then
            self:rawGroup()
            if name == "textcolor" then return self:arg() end
            return { t = "list", items = {} }
        elseif name == "displaystyle" or name == "textstyle" or name == "limits" or name == "nolimits"
            or name == "scriptstyle" or name == "nonumber" or name == "notag" or name == "middle"
            or name == "mathstrut" or name == "strut" or name == "relax" or name == "hline" then
            return { t = "list", items = {} }
        elseif FUNCS[name] ~= nil then
            return { t = "text", s = name == "bmod" and "mod" or name, font = "main", op = true, limits = FUNCS[name] }
        elseif SPACES[name] then
            return { t = "space", em = SPACES[name] }
        elseif S[name] then
            local d = S[name]
            return sym(d[1], d[2], d[3])
        elseif name == "\\" then
            return { t = "newline" }
        elseif name == "{" or name == "}" then
            return sym(name, "main", name == "{" and "open" or "close")
        else
            -- unknown: show its name, upright
            return { t = "text", s = name, font = "main" }
        end
    elseif t.t == "space" then
        return { t = "list", items = {} }
    elseif t.t == "^" or t.t == "_" then
        -- a script with nothing before it
        local s = self:arg()
        return { t = "list", items = {}, [t.t == "^" and "sup" or "sub"] = s }
    elseif t.t == "&" then
        return { t = "list", items = {} }
    elseif t.t == "}" then
        return { t = "list", items = {} }
    end
    return { t = "list", items = {} }
end

-- A list of atoms up to `stop` ("}", "]", "right", "&", "\\", "end" or nil).
function Parser:list(stop, cell)
    local items = {}
    while true do
        local t = self:peek()
        if not t then break end
        if stop == "}" and t.t == "}" then self:next(); break end
        if stop == "]" and t.t == "char" and t.v == "]" then self:next(); break end
        if stop == "right" and t.t == "cmd" and t.v == "right" then self:next(); break end
        if cell then
            if t.t == "&" or (t.t == "cmd" and (t.v == "\\" or t.v == "cr")) then break end
            if t.t == "cmd" and t.v == "end" then break end
        end
        if t.t == "^" or t.t == "_" then
            self:next()
            local last = items[#items]
            if not last or last.t == "space" then
                last = { t = "list", items = {} }
                items[#items + 1] = last
            end
            local s = self:arg()
            if t.t == "^" then
                if last.sup then last = { t = "list", items = {} }; items[#items + 1] = last end
                last.sup = s
            else
                if last.sub then last = { t = "list", items = {} }; items[#items + 1] = last end
                last.sub = s
            end
        elseif t.t == "space" then
            self:next()
        elseif t.t == "char" and t.v == "'" then
            -- primes are superscripts
            self:next()
            local last = items[#items]
            if not last then last = { t = "list", items = {} }; items[#items + 1] = last end
            local p = last.sup or { t = "list", items = {} }
            p.items[#p.items + 1] = sym("′", "main", "ord")
            last.sup = p
        else
            local a = self:atom()
            if a then items[#items + 1] = a end
        end
    end
    return { t = "list", items = items }
end

function Parser:matrix(env)
    local rows, row = {}, {}
    while true do
        local cell = self:list(nil, true)
        row[#row + 1] = cell
        local t = self:next()
        if not t then break end
        if t.t == "&" then -- next cell
        elseif t.t == "cmd" and (t.v == "\\" or t.v == "cr") then
            self:optArg() -- \\[2pt]
            rows[#rows + 1] = row
            row = {}
        elseif t.t == "cmd" and t.v == "end" then
            self:rawGroup()
            break
        end
    end
    if #row > 0 and not (#row == 1 and #row[1].items == 0) then rows[#rows + 1] = row end
    local d = MATRIX_DELIMS[env] or { "", "" }
    return { t = "matrix", rows = rows, env = env, l = d[1], r = d[2],
        small = env:find("small") ~= nil,
        align = (env == "cases" or env == "dcases") and "left"
            or (env:find("align") or env == "split") and "rl" or "center" }
end

Math.utf8chars = utf8chars

function Math.parse(src)
    local p = newParser(src or "")
    local list = p:list(nil)
    -- anything left after a stray closer: parse on
    while p:peek() do
        p:next()
        local more = p:list(nil)
        for _i, it in ipairs(more.items) do list.items[#list.items + 1] = it end
    end
    return list
end

------------------------------------------------------------------------------
-- Boxes
------------------------------------------------------------------------------

local function newBox(w, h, d)
    return { w = w or 0, h = h or 0, d = d or 0, items = {} }
end

-- Put `child` into `box` with its baseline-left at (x, y).
local function place(box, child, x, y)
    box.items[#box.items + 1] = { k = "b", box = child, x = x, y = y }
end

local function textBox(face, s)
    if not face or s == "" then return newBox(0, 0, 0) end
    local ok, m = pcall(RenderText.sizeUtf8Text, RenderText, 0, nil, face, s, true)
    if not ok or not m then return newBox(0, 0, 0) end
    local b = newBox(m.x, m.y_top, m.y_bottom)
    b.items[1] = { k = "g", face = face, s = s, x = 0, y = 0 }
    return b
end

-- A face for `ch` in `font`, falling back to another bundled one that has it.
local FALLBACK = { "main", "italic", "ams", "size1" }
local function faceFor(font, ch, px)
    local face = Fonts.math(font, px)
    local cp = codepoint(ch)
    if face and Fonts.has(face, cp) then return face end
    for _i, f in ipairs(FALLBACK) do
        local alt = Fonts.math(f, px)
        if alt and Fonts.has(alt, cp) then return alt end
    end
    return face -- KOReader's own fallback fonts may have it
end

------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------

-- The context: px (the em size now), level (0 text, 1 script, 2 scriptscript),
-- display (true for $$...$$), font (an override from \mathbf and friends).
local function sub(ctx, extra)
    local c = {}
    for k, v in pairs(ctx) do c[k] = v end
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function scriptCtx(ctx)
    local level = min(2, ctx.level + 1)
    local px = ctx.base * (level == 1 and 0.72 or 0.58)
    return sub(ctx, { level = level, px = px, display = false })
end

local Layout = {}

local function rule(ctx)
    return max(1, floor(ctx.px * 0.045 + 0.5))
end

local function axis(ctx)
    return ctx.px * 0.25
end

local function hpack(boxes)
    local b = newBox(0, 0, 0)
    local x = 0
    for _i, c in ipairs(boxes) do
        place(b, c, x, 0)
        x = x + c.w
        b.h = max(b.h, c.h)
        b.d = max(b.d, c.d)
    end
    b.w = x
    return b
end

local function layoutNode(node, ctx)
    local f = Layout[node.t]
    if not f then return newBox() end
    local ok, b = pcall(f, node, ctx)
    if not ok then
        logger.warn("InkAI math:", b)
        return newBox()
    end
    return b
end

-- A delimiter `ch` at least `need` pixels tall (h + d), centred on the axis.
local function delimiter(ch, need, ctx)
    if not ch or ch == "" then return newBox(ctx.px * 0.1, 0, 0) end
    local px = ctx.px
    local best
    for _i, font in ipairs({ "main", "size1", "size2" }) do
        local face = faceFor(font, ch, px)
        local b = textBox(face, ch)
        best = b
        if b.h + b.d >= need * 0.92 then break end
    end
    if best.h + best.d < need * 0.92 and best.h + best.d > 0 then
        local scale = need / (best.h + best.d)
        best = textBox(faceFor("size2", ch, px * scale), ch)
    end
    -- centre it on the axis
    local a = axis(ctx)
    local shift = a - (best.h - best.d) / 2
    local b = newBox(best.w, best.h + shift, best.d - shift)
    place(b, best, 0, shift)
    return b
end

Layout["sym"] = function(node, ctx)
    local font = node.font
    local over = ctx.font
    local ch = node.ch
    if over and ch:match("^[%a%d]$") then
        if over == "bold" then font = "bold"
        elseif over == "bolditalic" then font = ch:match("%d") and "bold" or "bolditalic"
        elseif over == "cal" then font = ch:match("%u") and "cal" or "main"
        elseif over == "ams" then font = ch:match("%u") and "ams" or "main"
        elseif over == "frak" then font = "frak"
        elseif over == "main" or over == "textit" then font = over end
    end
    if node.class == "op" then
        local b = textBox(faceFor(ctx.display and "size2" or "size1", ch, ctx.px), ch)
        -- big operators sit centred on the axis
        local a = axis(ctx)
        local shift = a - (b.h - b.d) / 2
        local box = newBox(b.w, b.h + shift, b.d - shift)
        place(box, b, 0, shift)
        box.class, box.op = "op", true
        box.limits = ctx.display and (ch == "∑" or ch == "∏" or ch == "⋃" or ch == "⋂" or ch == "∐" or ch == "⨁" or ch == "⨂")
        box.integral = ch == "∫" or ch == "∮" or ch == "∬" or ch == "∭"
        return box
    end
    local b = textBox(faceFor(font, ch, ctx.px), ch)
    b.class = node.class
    -- a little room after an italic letter, which leans over the next glyph
    if font == "italic" and ch:match("^%a$") then b.w = b.w + ctx.px * 0.03 end
    return b
end

Layout["text"] = function(node, ctx)
    local face = Fonts.math(node.font or "main", ctx.px)
    local b = textBox(face, node.s)
    if node.op then
        b.class = "op"
        b.limits = node.limits and ctx.display
        b.opname = true
    else
        b.class = "ord"
    end
    return b
end

Layout["space"] = function(node, ctx)
    local b = newBox(node.em * ctx.px, 0, 0)
    b.class = "space"
    return b
end

Layout["newline"] = function()
    local b = newBox()
    b.class = "space"
    return b
end

Layout["prime"] = function(_, ctx)
    return textBox(Fonts.math("main", ctx.px), "′")
end

local SPACE_TABLE = {
    -- left class -> right class -> em (in text style); TeX's table, simplified
    ord = { op = 3, bin = 4, rel = 5, inner = 3 },
    op = { ord = 3, op = 3, rel = 5, inner = 3 },
    bin = { ord = 4, op = 4, open = 4, inner = 4 },
    rel = { ord = 5, op = 5, open = 5, inner = 5 },
    close = { op = 3, bin = 4, rel = 5, inner = 3 },
    punct = { ord = 3, op = 3, rel = 3, open = 3, close = 3, punct = 3, inner = 3 },
    inner = { ord = 3, op = 3, bin = 4, rel = 5, open = 3, punct = 3, inner = 3 },
}

-- Attach scripts to a laid out nucleus.
local function scripts(nucleus, node, ctx)
    if not node.sup and not node.sub then return nucleus end
    local sctx = scriptCtx(ctx)
    local supb = node.sup and Layout.list(node.sup, sctx)
    local subb = node.sub and Layout.list(node.sub, sctx)
    local px = ctx.px
    if nucleus.limits then
        -- limits over and under (display \sum, \lim)
        local w = max(nucleus.w, supb and supb.w or 0, subb and subb.w or 0)
        local b = newBox(w, nucleus.h, nucleus.d)
        place(b, nucleus, (w - nucleus.w) / 2, 0)
        local gap = px * 0.12
        if supb then
            local y = nucleus.h + gap + supb.d
            place(b, supb, (w - supb.w) / 2, y)
            b.h = y + supb.h
        end
        if subb then
            local y = -(nucleus.d + gap + subb.h)
            place(b, subb, (w - subb.w) / 2, y)
            b.d = -y + subb.d
        end
        b.class = "op"
        return b
    end
    local u, v = 0, 0
    if supb then
        u = max(nucleus.h - px * 0.3, px * 0.38, supb.d + px * 0.11)
        if nucleus.integral then u = max(u, nucleus.h * 0.75) end
    end
    if subb then
        v = max(nucleus.d + px * 0.1, px * 0.18, subb.h - px * 0.35)
    end
    if supb and subb then
        local gap = (u - supb.d) - (subb.h - v)
        local need = px * 0.16
        if gap < need then
            v = v + (need - gap) / 2
            u = u + (need - gap) / 2
        end
    end
    local x = nucleus.w
    if nucleus.integral then x = x - px * 0.08 end
    local sw = max(supb and supb.w or 0, subb and subb.w or 0)
    local b = newBox(x + sw + px * 0.04, nucleus.h, nucleus.d)
    place(b, nucleus, 0, 0)
    if supb then
        place(b, supb, x + (nucleus.integral and px * 0.12 or 0), u)
        b.h = max(b.h, u + supb.h)
    end
    if subb then
        place(b, subb, x, -v)
        b.d = max(b.d, v + subb.d)
    end
    b.class = nucleus.class
    return b
end

Layout["list"] = function(node, ctx)
    local boxes, classes = {}, {}
    for _i, item in ipairs(node.items) do
        local b = layoutNode(item, ctx)
        b = scripts(b, item, ctx)
        local class = b.class or "ord"
        if item.t == "list" or item.t == "font" then class = b.class or "ord" end
        boxes[#boxes + 1] = b
        classes[#classes + 1] = class
    end
    -- a binary operator with nothing on its left is an ordinary symbol
    local prev
    for i, c in ipairs(classes) do
        if c == "bin" and (not prev or prev == "bin" or prev == "rel" or prev == "open" or prev == "punct" or prev == "op" and false) then
            classes[i] = "ord"
        end
        if c ~= "space" then prev = classes[i] end
    end
    for i = #classes, 1, -1 do
        if classes[i] == "bin" then
            local nxt
            for j = i + 1, #classes do
                if classes[j] ~= "space" then nxt = classes[j]; break end
            end
            if not nxt or nxt == "rel" or nxt == "close" or nxt == "punct" then classes[i] = "ord" end
        end
    end
    local out = newBox(0, 0, 0)
    local x = 0
    local last
    for i, b in ipairs(boxes) do
        local c = classes[i]
        if c ~= "space" and last then
            local mu = SPACE_TABLE[last] and SPACE_TABLE[last][c]
            if mu and (ctx.level == 0 or c == "rel" and false) then
                x = x + mu / 18 * ctx.px
            end
        end
        place(out, b, x, 0)
        x = x + b.w
        out.h = max(out.h, b.h)
        out.d = max(out.d, b.d)
        if c ~= "space" then last = c end
    end
    out.w = x
    -- the list's class, as one atom: its only atom's, else ordinary
    local real = {}
    for _i, c in ipairs(classes) do if c ~= "space" then real[#real + 1] = c end end
    out.class = #real == 1 and real[1] or "ord"
    if #real == 1 then
        for _i, b in ipairs(boxes) do
            if b.class == real[1] then
                out.limits, out.integral, out.op = b.limits, b.integral, b.op
            end
        end
    end
    return out
end

Layout["font"] = function(node, ctx)
    return Layout.list(node.body, sub(ctx, { font = node.font }))
end

Layout["frac"] = function(node, ctx)
    local nctx
    if node.small or (ctx.level > 0) then
        nctx = scriptCtx(ctx)
    elseif ctx.display or node.big then
        nctx = sub(ctx, { display = false })
    else
        -- inline fractions: a little smaller, still readable on e-ink
        nctx = sub(ctx, { px = ctx.px * 0.8, base = ctx.base, display = false })
    end
    local num = Layout.list(node.num, nctx)
    local den = Layout.list(node.den, nctx)
    local t = rule(ctx)
    local a = axis(ctx)
    local gap = max(t * 1.5, ctx.px * 0.1)
    local pad = ctx.px * 0.12
    local w = max(num.w, den.w) + 2 * pad
    local b = newBox(w, 0, 0)
    local ny = a + t / 2 + gap + num.d
    local dy = a - t / 2 - gap - den.h
    place(b, num, (w - num.w) / 2, ny)
    place(b, den, (w - den.w) / 2, dy)
    if not node.nobar then
        b.items[#b.items + 1] = { k = "r", x = pad * 0.4, y = a - t / 2, w = w - pad * 0.8, h = t }
    end
    b.h = ny + num.h
    b.d = -dy + den.d
    b.class = "inner"
    if node.l then
        local need = b.h + b.d
        local l = delimiter(node.l, need, ctx)
        local r = delimiter(node.r, need, ctx)
        b = hpack({ l, b, r })
        b.class = "inner"
    end
    return b
end

Layout["sqrt"] = function(node, ctx)
    local body = Layout.list(node.body, ctx)
    local px = ctx.px
    local t = rule(ctx)
    local clear = max(t * 2, px * 0.14)
    local top = max(body.h, px * 0.6) + clear
    local bot = max(body.d, px * 0.12) + px * 0.06
    local H = top + bot
    local rw = min(px * 0.62, px * 0.32 + H * 0.12)
    local b = newBox(0, top + t, bot)
    local x0 = 0
    local index
    if node.index then
        index = Layout.list(node.index, scriptCtx(scriptCtx(ctx)))
        x0 = max(0, index.w - rw * 0.45)
    end
    local function L(xa, ya, xb, yb, th)
        b.items[#b.items + 1] = { k = "l", x0 = x0 + xa, y0 = ya, x1 = x0 + xb, y1 = yb, t = th }
    end
    local ymid = -bot + H * 0.42
    L(0, ymid, rw * 0.25, ymid + H * 0.07, max(1, t * 0.8))
    L(rw * 0.25, ymid + H * 0.07, rw * 0.55, -bot, t * 1.6)
    L(rw * 0.55, -bot, rw, top, t)
    local bx = x0 + rw + px * 0.06
    b.items[#b.items + 1] = { k = "r", x = x0 + rw, y = top - t / 2, w = body.w + px * 0.16, h = t }
    place(b, body, bx, 0)
    b.w = bx + body.w + px * 0.12
    if index then
        place(b, index, 0, ymid + H * 0.12 + index.d)
        b.h = max(b.h, ymid + H * 0.12 + index.d + index.h)
    end
    b.class = "ord"
    return b
end

Layout["accent"] = function(node, ctx)
    local body = Layout.list(node.body, ctx)
    local px = ctx.px
    local t = rule(ctx)
    local acc = node.acc
    if acc == "under" then
        local b = newBox(body.w, body.h, body.d + t * 3)
        place(b, body, 0, 0)
        b.items[#b.items + 1] = { k = "r", x = 0, y = -body.d - t * 2.5, w = body.w, h = t }
        b.class = body.class
        return b
    end
    local single = #node.body.items == 1 and node.body.items[1].t == "sym"
    local skew = single and node.body.items[1].font == "italic" and px * 0.08 or 0
    local base = max(body.h, px * 0.45) + px * 0.08
    local b = newBox(body.w, base, body.d)
    place(b, body, 0, 0)
    local cx = body.w / 2 + skew
    local function L(xa, ya, xb, yb, th)
        b.items[#b.items + 1] = { k = "l", x0 = xa, y0 = ya, x1 = xb, y1 = yb, t = th or t }
    end
    local hgt
    if acc == "bar" then
        local w = single and max(body.w * 0.8, px * 0.4) or body.w
        b.items[#b.items + 1] = { k = "r", x = cx - w / 2, y = base, w = w, h = t }
        hgt = t
    elseif acc == "vec" then
        local w = single and max(body.w * 0.85, px * 0.5) or body.w
        local y = base + px * 0.08
        local x0, x1 = cx - w / 2, cx + w / 2
        L(x0, y, x1, y)
        L(x1 - px * 0.14, y + px * 0.09, x1, y)
        L(x1 - px * 0.14, y - px * 0.09, x1, y)
        hgt = px * 0.18
    elseif acc == "hat" or acc == "check" then
        local w = single and px * 0.42 or max(px * 0.42, body.w)
        local hh = px * 0.14
        if acc == "hat" then
            L(cx - w / 2, base, cx, base + hh)
            L(cx, base + hh, cx + w / 2, base)
        else
            L(cx - w / 2, base + hh, cx, base)
            L(cx, base, cx + w / 2, base + hh)
        end
        hgt = hh + t
    elseif acc == "dot" or acc == "ddot" then
        local s = max(2, floor(px * 0.1 + 0.5))
        if acc == "dot" then
            b.items[#b.items + 1] = { k = "r", x = cx - s / 2, y = base + px * 0.02, w = s, h = s }
        else
            b.items[#b.items + 1] = { k = "r", x = cx - s * 1.6, y = base + px * 0.02, w = s, h = s }
            b.items[#b.items + 1] = { k = "r", x = cx + s * 0.6, y = base + px * 0.02, w = s, h = s }
        end
        hgt = s + px * 0.02
    elseif acc == "tilde" then
        local w = single and px * 0.5 or max(px * 0.5, body.w)
        local x0 = cx - w / 2
        local amp = px * 0.05
        local y = base + amp
        local n = 8
        local px0, py0 = x0, y
        for i = 1, n do
            local xx = x0 + w * i / n
            local yy = y + amp * math.sin(i / n * 2 * math.pi + math.pi)
            L(px0, py0, xx, yy)
            px0, py0 = xx, yy
        end
        hgt = amp * 2 + t
    end
    b.h = base + (hgt or 0) + px * 0.02
    b.class = body.class
    return b
end

Layout["left"] = function(node, ctx)
    local body = Layout.list(node.body, ctx)
    local a = axis(ctx)
    local need = 2 * max(body.h - a, body.d + a)
    local l = delimiter(node.l, need, ctx)
    local r = delimiter(node.r, need, ctx)
    local b = hpack({ l, body, r })
    b.class = "inner"
    return b
end

Layout["bigdelim"] = function(node, ctx)
    local b = delimiter(node.ch, ctx.px * node.scale, ctx)
    local ch = node.ch
    b.class = (ch == "(" or ch == "[" or ch == "{" or ch == "⟨") and "open"
        or (ch == ")" or ch == "]" or ch == "}" or ch == "⟩") and "close" or "ord"
    return b
end

Layout["not"] = function(node, ctx)
    local body = node.body and layoutNode(node.body, ctx) or newBox(ctx.px * 0.5, ctx.px * 0.7, 0)
    local b = newBox(body.w, body.h, body.d)
    place(b, body, 0, 0)
    local t = rule(ctx)
    b.items[#b.items + 1] = { k = "l", x0 = body.w * 0.25, y0 = -body.d - ctx.px * 0.05,
        x1 = body.w * 0.75, y1 = body.h + ctx.px * 0.05, t = t }
    b.class = body.class
    return b
end

Layout["over"] = function(node, ctx)
    local body = Layout.list(node.body, ctx)
    local sctx = scriptCtx(ctx)
    local w = body.w
    local overb = node.over and Layout.list(node.over, sctx)
    local underb = node.under and Layout.list(node.under, sctx)
    w = max(w, overb and overb.w or 0, underb and underb.w or 0)
    local b = newBox(w, body.h, body.d)
    place(b, body, (w - body.w) / 2, 0)
    local gap = ctx.px * 0.08
    if overb then
        local y = body.h + gap + overb.d
        place(b, overb, (w - overb.w) / 2, y)
        b.h = y + overb.h
    end
    if underb then
        local y = -(body.d + gap + underb.h)
        place(b, underb, (w - underb.w) / 2, y)
        b.d = -y + underb.d
    end
    b.class = body.class == "rel" and "rel" or "ord"
    return b
end

Layout["boxed"] = function(node, ctx)
    local body = Layout.list(node.body, ctx)
    local pad = ctx.px * 0.15
    local t = rule(ctx)
    local b = newBox(body.w + 2 * pad, body.h + pad, body.d + pad)
    place(b, body, pad, 0)
    local x1, y0, y1 = b.w, -b.d, b.h
    b.items[#b.items + 1] = { k = "r", x = 0, y = y0, w = x1, h = t }
    b.items[#b.items + 1] = { k = "r", x = 0, y = y1 - t, w = x1, h = t }
    b.items[#b.items + 1] = { k = "r", x = 0, y = y0, w = t, h = y1 - y0 }
    b.items[#b.items + 1] = { k = "r", x = x1 - t, y = y0, w = t, h = y1 - y0 }
    return b
end

Layout["matrix"] = function(node, ctx)
    local cctx = ctx
    if node.small then cctx = scriptCtx(ctx) end
    local px = cctx.px
    local cells, ncols = {}, 0
    for r, row in ipairs(node.rows) do
        cells[r] = {}
        for c, cell in ipairs(row) do
            cells[r][c] = Layout.list(cell, sub(cctx, { display = false }))
            ncols = max(ncols, c)
        end
    end
    local colw = {}
    for c = 1, ncols do colw[c] = 0 end
    local rowh, rowd = {}, {}
    for r, row in ipairs(cells) do
        rowh[r], rowd[r] = px * 0.7, px * 0.25
        for c, b in ipairs(row) do
            colw[c] = max(colw[c], b.w)
            rowh[r] = max(rowh[r], b.h)
            rowd[r] = max(rowd[r], b.d)
        end
    end
    local colgap = node.align == "rl" and 0 or px * (node.small and 0.5 or 0.8)
    local rowgap = px * (node.small and 0.15 or 0.25)
    local total = 0
    for r = 1, #cells do total = total + rowh[r] + rowd[r] + (r > 1 and rowgap or 0) end
    local body = newBox(0, 0, 0)
    local a = axis(ctx)
    local top = a + total / 2
    local y = top
    local width = 0
    for c = 1, ncols do width = width + colw[c] + (c > 1 and colgap or 0) end
    if node.align == "rl" then width = width + px * 0.3 * math.floor((ncols - 1) / 2) end
    for r, row in ipairs(cells) do
        y = y - rowh[r]
        local x = 0
        for c = 1, ncols do
            local b = row[c]
            if b then
                local cx
                local mode = node.align
                if mode == "left" then cx = x
                elseif mode == "rl" then cx = (c % 2 == 1) and (x + colw[c] - b.w) or x
                else cx = x + (colw[c] - b.w) / 2 end
                place(body, b, cx, y)
            end
            x = x + colw[c] + colgap
            if node.align == "rl" and c % 2 == 0 then x = x + px * 0.3 end
        end
        y = y - rowd[r] - rowgap
    end
    body.w = width
    body.h = top
    body.d = total - top
    local need = total + px * 0.1
    local l = delimiter(node.l, need, ctx)
    local rr = delimiter(node.r, need, ctx)
    local pad = newBox(px * 0.1, 0, 0)
    local b = hpack({ l, pad, body, pad, rr })
    b.class = "inner"
    return b
end

--[[--
Lay out LaTeX math `src` at em size `px`.
@param display boolean: display style ($$...$$): big operators, limits above and below
@return box
]]
function Math.layout(src, px, display)
    local ok, tree = pcall(Math.parse, src)
    if not ok then
        logger.warn("InkAI math parse:", tree)
        tree = { t = "list", items = { { t = "text", s = src, font = "main" } } }
    end
    local ctx = { px = px, base = px, level = 0, display = display and true or false }
    local b = layoutNode(tree, ctx)
    return b
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

local function line(bb, x0, y0, x1, y1, t, color)
    t = max(1, floor(t + 0.5))
    local dx, dy = x1 - x0, y1 - y0
    local steps = max(abs(dx), abs(dy), 1)
    local half = t / 2
    if dy == 0 then
        bb:paintRect(floor(min(x0, x1) + 0.5), floor(y0 - half + 0.5), floor(abs(dx) + 0.5) + 1, t, color)
        return
    end
    if dx == 0 then
        bb:paintRect(floor(x0 - half + 0.5), floor(min(y0, y1) + 0.5), t, floor(abs(dy) + 0.5) + 1, color)
        return
    end
    for i = 0, steps do
        local f = i / steps
        bb:paintRect(floor(x0 + dx * f - half + 0.5), floor(y0 + dy * f - half + 0.5), t, t, color)
    end
end
Math.line = line

--[[--
Paint `box` on `bb` with its baseline-left at screen (x, baseline).
]]
function Math.paint(box, bb, x, baseline, color)
    for _i, it in ipairs(box.items) do
        local k = it.k
        if k == "b" then
            Math.paint(it.box, bb, x + it.x, baseline - it.y, color)
        elseif k == "g" then
            RenderText:renderUtf8Text(bb, floor(x + it.x + 0.5), floor(baseline - it.y + 0.5), it.face, it.s, true, false, color)
        elseif k == "r" then
            local rx, ry = floor(x + it.x + 0.5), floor(baseline - it.y - it.h + 0.5)
            bb:paintRect(rx, ry, max(1, floor(it.w + 0.5)), max(1, floor(it.h + 0.5)), color)
        elseif k == "l" then
            line(bb, x + it.x0, baseline - it.y0, x + it.x1, baseline - it.y1, it.t, color)
        end
    end
end

return Math
