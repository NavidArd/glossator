--[[--
Editing ink: the lasso (which strokes a loop takes in), the eraser (whole
strokes, or precisely where it passes, splitting the rest), and undo/redo.

Undo works on the groups shown on the screen: before an edit their state is
copied, after it the new state, and undo puts the old copies back by id. A
note and its ink come back together.
]]

local util = require("util")

local abs, floor = math.abs, math.floor

local Edit = {}

-- Is (x, y) inside the closed polygon `poly` (flat x, y list)?
function Edit.inside(poly, x, y)
    local n = #poly / 2
    local c = false
    local j = n
    for i = 1, n do
        local xi, yi = poly[2 * i - 1], poly[2 * i]
        local xj, yj = poly[2 * j - 1], poly[2 * j]
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
            c = not c
        end
        j = i
    end
    return c
end

-- Does the lasso take a stroke? Most of its points inside.
function Edit.lassoTakes(poly, st)
    local n, hit = 0, 0
    for i = 1, #st, 2 do
        n = n + 1
        if Edit.inside(poly, st[i], st[i + 1]) then hit = hit + 1 end
    end
    return n > 0 and hit / n >= 0.6
end

-- Is any point of `st` within `reach` of a point of `path`?
function Edit.touches(st, path, reach)
    for i = 1, #st, 2 do
        local x, y = st[i], st[i + 1]
        for j = 1, #path, 2 do
            if abs(x - path[j]) < reach and abs(y - path[j + 1]) < reach then return true end
        end
    end
    return false
end

-- Densify a path so a fast eraser stroke leaves no gaps between its samples.
function Edit.densify(path, step)
    if #path < 4 then return path end
    local out = { path[1], path[2] }
    for i = 3, #path, 2 do
        local x0, y0, x1, y1 = path[i - 2], path[i - 1], path[i], path[i + 1]
        local d = math.max(abs(x1 - x0), abs(y1 - y0))
        local n = math.max(1, floor(d / step))
        for k = 1, n do
            out[#out + 1] = x0 + (x1 - x0) * k / n
            out[#out + 1] = y0 + (y1 - y0) * k / n
        end
    end
    return out
end

--[[--
The precise eraser: the points of `st` within `reach` of `path` go, and what
is left is split into the runs between them.
@return list of strokes (may be empty), changed
]]
function Edit.cut(st, path, reach)
    local runs, cur = {}, nil
    local changed = false
    local p = st.q or st.p
    local pk = st.q and "q" or "p"
    for i = 1, #st, 2 do
        local x, y = st[i], st[i + 1]
        local gone = false
        for j = 1, #path, 2 do
            if abs(x - path[j]) < reach and abs(y - path[j + 1]) < reach then gone = true break end
        end
        if gone then
            changed = true
            cur = nil
        else
            if not cur then
                cur = { w = st.w, kind = st.kind }
                if p then cur[pk] = {} end
                runs[#runs + 1] = cur
            end
            cur[#cur + 1], cur[#cur + 2] = x, y
            if p then cur[pk][#cur[pk] + 1] = p[(i + 1) / 2] end
        end
    end
    return runs, changed
end

------------------------------------------------------------------------------
-- Undo
------------------------------------------------------------------------------

local History = {}
History.__index = History
Edit.History = History

function History.new(max)
    return setmetatable({ undo = {}, redo = {}, max = max or 40 }, History)
end

local function snapshot(groups)
    local out = {}
    for _i, g in ipairs(groups) do
        if g.id then out[#out + 1] = util.tableDeepCopy(g) end
    end
    return out
end

-- Copy the given groups before an edit; returns a token for `commit`.
function History:begin(groups)
    return { before = snapshot(groups) }
end

-- Record the edit: `groups` are the ones it concerns, after it.
function History:commit(token, groups)
    if not token then return end
    token.after = snapshot(groups)
    table.insert(self.undo, token)
    if #self.undo > self.max then table.remove(self.undo, 1) end
    self.redo = {}
end

-- Replace in `list` every group named in `from` or `to` by the copies in `to`.
local function swap(list, from, to)
    local ids = {}
    for _i, g in ipairs(from) do ids[g.id] = true end
    for _i, g in ipairs(to) do ids[g.id] = true end
    for i = #list, 1, -1 do
        if ids[list[i].id] then table.remove(list, i) end
    end
    for _i, g in ipairs(to) do list[#list + 1] = util.tableDeepCopy(g) end
    table.sort(list, function(a, b)
        if (a.created or 0) ~= (b.created or 0) then return (a.created or 0) < (b.created or 0) end
        return tostring(a.id) < tostring(b.id)
    end)
end

function History:canUndo() return #self.undo > 0 end
function History:canRedo() return #self.redo > 0 end

function History:doUndo(list)
    local t = table.remove(self.undo)
    if not t then return false end
    swap(list, t.after, t.before)
    table.insert(self.redo, t)
    return true
end

function History:doRedo(list)
    local t = table.remove(self.redo)
    if not t then return false end
    swap(list, t.before, t.after)
    table.insert(self.undo, t)
    return true
end

return Edit
