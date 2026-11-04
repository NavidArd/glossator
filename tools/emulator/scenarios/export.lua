-- Glossator's AI notes in KOReader's Export highlights: from the open book,
-- from a closed book's saved notes (also one with no other highlights), and
-- through the Markdown target to a file.
local DataStorage = require("datastorage")
local dir = DataStorage:getDataDir()
local MOCK = [[<transcription>why is this conserved?</transcription><note>Because the action is invariant: $\delta S = 0 \Rightarrow \dot Q = 0$.</note><more>Noether's theorem pairs each continuous symmetry with a conserved current.</more>]]
local log = {}
local function check(name, cond) table.insert(log, (cond and "PASS " or "FAIL ") .. name) end
local function ink(api) return api.plugin("inkai") end
local function aiEntries(book)
  local n, e = 0, nil
  for _i, c in ipairs(book or {}) do
    if c[1].glossator then n = n + 1; e = c[1] end
  end
  return n, e
end
return {
  { wait = 2, function(api)
      local f = io.open(dir .. "/inkai_mock.txt", "w"); f:write(MOCK); f:close()
      api.pen(api.circle(930, 1022, 350, 74))
  end },
  { wait = 1.2, function(api)
      local c = ink(api).chip
      api.tap(c.rect.x + 20, c.rect.y + c.rect.h / 2)
  end },
  { wait = 3, function(api)
      local g
      for _i, o in ipairs(ink(api).data.groups) do if o.note then g = o end end
      check("answered, page saved with the note", g ~= nil and g.pageno == api.ui():getCurrentPage())
      g.replies = { { question = "and for SU(2)?", note = "Same, with $J_i = \\tfrac12\\sigma_i$." } }
      local ex = api.ui().exporter
      check("KOReader's Exporter is there", ex ~= nil and ex.parser ~= nil)
      -- 1. the open book, no other highlights
      local clippings = ex.parser:parseCurrentDoc()
      local _t, book = next(clippings)
      local n, e = aiEntries(book)
      check("open book: the AI note is exported", n == 1)
      check("open book: what was asked is the highlight", e and e.text == "why is this conserved?")
      check("open book: answer, more and follow-up are the note", e and e.note:find("invariant", 1, true) and e.note:find("Noether", 1, true) and e.note:find("Q: and for SU(2)?", 1, true))
      check("open book: page and time", e and e.page == g.pageno and type(e.time) == "number")
      -- 2. a closed book with only AI notes: the Exporter alone skips it
      ink(api):save()
      api.ui():saveSettings()
      local file = api.ui().document.file
      local Hook = require("glossator/exporthook")
      local live = Hook.live[file]
      Hook.live[file] = nil
      local cl = {}
      ex.parser:getClippingsFromBook(cl, file)
      local _t2, b2 = next(cl)
      n = aiEntries(b2)
      check("closed book with only AI notes: exported from its saved notes", n == 1 and b2.file == file)
      Hook.live[file] = live
      -- 3. with an ordinary highlight too: both, in page order
      local ann = api.ui().annotation
      table.insert(ann.annotations, { page = 1, pageno = 1, pos0 = { page = 1, x = 0, y = 0 }, pos1 = { page = 1, x = 10, y = 10 },
        text = "A symmetry is a transformation", drawer = "lighten", datetime = "2026-11-04 10:00:00", chapter = "Symmetry" })
      clippings = ex.parser:parseCurrentDoc()
      _t, book = next(clippings)
      n = aiEntries(book)
      check("with a highlight: both exported", #book == 2 and n == 1)
      -- 4. turned off
      G_reader_settings:saveSetting("glossator_export_notes", false)
      clippings = ex.parser:parseCurrentDoc()
      _t, book = next(clippings)
      check("turned off: only the highlight", #book == 1 and aiEntries(book) == 0)
      G_reader_settings:delSetting("glossator_export_notes")
      -- 5. through the Markdown target
      clippings = ex.parser:parseCurrentDoc()
      _t, book = next(clippings)
      local md = ex.targets and ex.targets.markdown
      local out = os.getenv("INKAI_SHOTS") .. "/export-test"
      if md then
        md.filepath = out
        md.timestamp = os.time()
        local okx, errx = pcall(md.export, md, { book })
        if not okx then table.insert(log, "  markdown error: " .. tostring(errx)) end
      end
      local f = io.open(out .. ".md")
      local text = f and f:read("*a") or ""
      if f then f:close() end
      check("Markdown file has the note", text:find("why is this conserved?", 1, true) and text:find("Noether", 1, true))
      check("Markdown file has the highlight", text:find("A symmetry is a transformation", 1, true) ~= nil)
      table.remove(ann.annotations)
      os.remove(dir .. "/inkai_mock.txt")
      local lf = io.open(os.getenv("INKAI_SHOTS") .. "/export.txt", "w"); lf:write(table.concat(log, "\n") .. "\n"); lf:close()
  end },
}
