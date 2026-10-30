-- A row of six-sided dice drawn as vectors (rounded square + pips), crisp on
-- e-ink at any size. Same pip layout as dice.koplugin.
--   values  -- faces to draw, or nil with `count` for hidden dice (under the cup)
--   size    -- side of one die, in pixels
--   mark    -- optional function(face) -> true to draw that die inverted
--              (black die, white pips): the dice that count for a bid

local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")

local PIP_LAYOUT = {
    [1] = { {0.5,  0.5 } },
    [2] = { {0.25, 0.25}, {0.75, 0.75} },
    [3] = { {0.25, 0.25}, {0.5,  0.5 }, {0.75, 0.75} },
    [4] = { {0.25, 0.25}, {0.75, 0.25}, {0.25, 0.75}, {0.75, 0.75} },
    [5] = { {0.25, 0.25}, {0.75, 0.25}, {0.5, 0.5 }, {0.25, 0.75}, {0.75, 0.75} },
    [6] = { {0.25, 0.25}, {0.75, 0.25}, {0.25, 0.5}, {0.75, 0.5}, {0.25, 0.75}, {0.75, 0.75} },
}

local DiceRow = Widget:extend{
    values = nil,
    count  = nil,
    size   = 40,
    gap    = nil,
    mark   = nil,
}

function DiceRow:init()
    self.size = math.max(8, math.floor(self.size))
    self.gap  = self.gap or math.max(2, math.floor(self.size * 0.18))
    local n = self.values and #self.values or (self.count or 0)
    self.n = n
    self.dimen = Geom:new{
        w = n > 0 and (n * self.size + (n - 1) * self.gap) or 0,
        h = self.size,
    }
end

function DiceRow:getSize()
    return self.dimen
end

-- Width of n dice of side s with the default gap, to size a row from a budget.
function DiceRow.widthFor(n, s)
    s = math.floor(s)
    local gap = math.max(2, math.floor(s * 0.18))
    return n * s + math.max(0, n - 1) * gap
end

-- Largest side such that n dice fit in w.
function DiceRow.sizeFor(n, w)
    if n <= 0 then return w end
    local s = math.floor(w / (n + 0.18 * (n - 1)))
    while s > 8 and DiceRow.widthFor(n, s) > w do s = s - 1 end
    return s
end

function DiceRow:_drawDie(bb, x, y, face)
    local s = self.size
    local radius = math.max(2, math.floor(s * 0.16))
    local border = math.max(1, math.floor(s * 0.05))
    if not face then
        -- Hidden die: a grey tile.
        bb:paintRoundedRect(x, y, s, s, Blitbuffer.COLOR_LIGHT_GRAY, radius)
        bb:paintBorder(x, y, s, s, border, Blitbuffer.COLOR_DARK_GRAY, radius)
        return
    end
    local inverted = self.mark and self.mark(face)
    local bg  = inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local pip = inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:paintRoundedRect(x, y, s, s, bg, radius)
    bb:paintBorder(x, y, s, s, border, Blitbuffer.COLOR_BLACK, radius)
    local pr = math.max(2, math.floor(s * 0.09))
    for _i, p in ipairs(PIP_LAYOUT[face] or {}) do
        bb:paintCircle(x + math.floor(s * p[1]), y + math.floor(s * p[2]), pr, pip)
    end
end

function DiceRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    for i = 1, self.n do
        local dx = x + (i - 1) * (self.size + self.gap)
        self:_drawDie(bb, dx, y, self.values and self.values[i] or nil)
    end
end

return DiceRow
