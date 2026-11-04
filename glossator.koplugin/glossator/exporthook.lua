--[[--
Glossator's AI notes in KOReader's own Exporter (Tools → Export highlights).

The Exporter sends highlights to Markdown, HTML, JSON, text, Joplin, Readwise,
Nextcloud Notes, XMNote and My Clippings. Glossator adds its notes there as
extra entries: what you asked (the selected text, or your handwriting as the
model read it) as the highlight, and the answer, its longer explanation and any
follow-ups as the note. Nothing is added to the book itself.

It hooks the two places the Exporter reads a book: the open one
(MyClipping:parseCurrentDoc) and closed ones from the history or a file
selection (MyClipping:getClippingsFromBook). The hook goes on the Exporter's
class once per KOReader session, so it works from the file browser too, and a
change in the Exporter can only leave the AI notes out: every step is guarded.
]]

local DocSettings = require("docsettings")
local logger = require("logger")

local ExportHook = {
    SETTINGS = { "glossator_ink", "inkai_ink" }, -- where Glossator keeps a book's ink and notes
    live = setmetatable({}, { __mode = "v" }),    -- open book's file -> its Ink (fresher than the sidecar)
}

function ExportHook.enabled()
    return G_reader_settings:readSetting("glossator_export_notes") ~= false
end

-- "Q: …\n\nA: …" for the follow-ups after the first answer.
local function noteText(g)
    local parts = { g.note }
    if g.more and g.more ~= "" then table.insert(parts, g.more) end
    for _i, r in ipairs(g.replies or {}) do
        table.insert(parts, "Q: " .. (r.question or "?"))
        table.insert(parts, "A: " .. (r.note or "") .. ((r.more and r.more ~= "") and ("\n\n" .. r.more) or ""))
    end
    return table.concat(parts, "\n\n")
end

local function askedText(g)
    if g.selected_text and g.selected_text ~= "" then return g.selected_text end
    if g.question and g.question ~= "" and g.question ~= "?" then return g.question end
    return "(handwritten note)"
end

--[[--
The Exporter's clippings for a book's answered notes. `pageOf(g)` and
`chapterOf(page)` give the page and chapter while the book is open; for a
closed book the page and chapter saved with the note are used.
]]
function ExportHook.clippings(data, pageOf, chapterOf)
    local out = {}
    for _i, g in ipairs(data and data.groups or {}) do
        if g.note and not g.transient then
            local page = (pageOf and pageOf(g)) or g.pageno or (g.a and tonumber(g.a.page)) or 0
            local chapter = g.chapter
            if chapterOf then chapter = chapterOf(page) or chapter end
            table.insert(out, { {
                sort = "highlight",
                page = page,
                time = g.created or os.time(),
                text = askedText(g),
                note = noteText(g),
                chapter = chapter,
                drawer = "lighten",
                glossator = true,
            } })
        end
    end
    return out
end

-- Add `extra` to a book's clippings and keep them in page order.
local function merge(book, extra)
    if #extra == 0 then return end
    for _i, e in ipairs(extra) do table.insert(book, e) end
    local order = {}
    for i, e in ipairs(book) do order[e] = i end
    table.sort(book, function(a, b)
        local pa, pb = tonumber(a[1].page) or 0, tonumber(b[1].page) or 0
        if pa ~= pb then return pa < pb end
        return order[a] < order[b]
    end)
    -- A note without a chapter (a book without a table of contents, or a
    -- note saved before chapters were) takes its neighbour's: the Exporter's
    -- templates start a new chapter heading whenever it changes, and a missing
    -- one after a named one breaks the Markdown template.
    for i, e in ipairs(book) do
        local c = e[1]
        if c.glossator and c.chapter == nil then
            for j = i - 1, 1, -1 do
                if book[j][1].chapter ~= nil then c.chapter = book[j][1].chapter break end
            end
            if c.chapter == nil then
                for j = i + 1, #book do
                    if book[j][1].chapter ~= nil then c.chapter = book[j][1].chapter break end
                end
            end
        end
    end
end

local function savedData(doc_path)
    local ok, ds = pcall(DocSettings.open, DocSettings, doc_path)
    if not ok or not ds then return nil end
    for _i, key in ipairs(ExportHook.SETTINGS) do
        local d = ds:readSetting(key)
        if d then return d end
    end
end

-- The open book's notes, with pages and chapters worked out now.
local function liveClippings(ink)
    local function pageOf(g)
        local p = tonumber(ink:pageLabel(g))
        if p then g.pageno = p end
        return p
    end
    local function chapterOf(page)
        local toc = ink.ui.toc
        if not (toc and page) then return nil end
        local ok, title = pcall(toc.getTocTitleByPage, toc, page)
        return ok and title ~= "" and title or nil
    end
    return ExportHook.clippings(ink.data, pageOf, chapterOf)
end

function ExportHook.install()
    if ExportHook.installed then return true end
    local MyClipping = package.loaded["clip"]
    if type(MyClipping) ~= "table" or type(MyClipping.parseCurrentDoc) ~= "function"
            or type(MyClipping.getClippingsFromBook) ~= "function" then
        return false
    end
    ExportHook.installed = true

    local parseCurrentDoc = MyClipping.parseCurrentDoc
    MyClipping.parseCurrentDoc = function(self, ...)
        local clippings = parseCurrentDoc(self, ...)
        if not ExportHook.enabled() then return clippings end
        local ok, err = pcall(function()
            local file = self.ui and self.ui.document and self.ui.document.file
            local ink = file and ExportHook.live[file]
            if not ink then return end
            local extra = liveClippings(ink)
            local _t, book = next(clippings)
            if book then merge(book, extra) end
        end)
        if not ok then logger.warn("Glossator: export hook:", err) end
        return clippings
    end

    local getClippingsFromBook = MyClipping.getClippingsFromBook
    MyClipping.getClippingsFromBook = function(self, clippings, doc_path, ...)
        local before = {}
        for title in pairs(clippings) do before[title] = true end
        local r = getClippingsFromBook(self, clippings, doc_path, ...)
        if not ExportHook.enabled() then return r end
        local ok, err = pcall(function()
            local ink = ExportHook.live[doc_path]
            local extra = ink and liveClippings(ink) or ExportHook.clippings(savedData(doc_path))
            if #extra == 0 then return end
            -- the book's entry: the one just made, or (a book with only AI
            -- notes, which the Exporter skips) a new one like it
            local book
            for title, b in pairs(clippings) do
                if not before[title] or (type(b) == "table" and b.file == doc_path) then book = b end
            end
            if not book then
                local ds = DocSettings:open(doc_path)
                local props = ds:readSetting("doc_props") or {}
                if self.ui and self.ui.bookinfo and self.ui.bookinfo.extendProps then
                    props = self.ui.bookinfo.extendProps(props, doc_path)
                end
                local title, author = self:getTitleAuthor(doc_path, props)
                book = { file = doc_path, title = title, author = author, number_of_pages = ds:readSetting("doc_pages") }
                clippings[title] = book
            end
            merge(book, extra)
        end)
        if not ok then logger.warn("Glossator: export hook:", err) end
        return r
    end
    return true
end

return ExportHook
