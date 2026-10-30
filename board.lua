-- Liar's Dice -- game logic (pure Lua, no UI, so it can be unit-tested).
--
-- Every player has dice under a cup. In turn, each player either raises the
-- bid ("there are at least Q dice showing F on the whole table"), calls
-- Liar! on the previous bid, or (optional) calls Exact.
--
-- Bidding (classic rules, `wild` off): a raise has a higher quantity (any
-- face), or the same quantity with a higher face. 1 is the lowest face.
--
-- With wild ones (`wild` on, the "Paco" rule): 1s count as every face, and
-- bidding on 1s follows its own scale:
--   * the opening bid cannot be on 1s;
--   * from a face F>1 to 1s: quantity at least ceil(Q / 2);
--   * from 1s to a face F>1: quantity at least 2Q + 1;
--   * 1s to 1s: a higher quantity; F>1 to F>1: as without wilds.
--
-- Liar!: the dice are revealed and counted (1s included when wild and the
-- bid is not on 1s). Bid true (count >= Q): the caller loses a die; false:
-- the bidder does.
-- Exact: right (count == Q): the caller gets a die back (up to the starting
-- number); wrong: the caller loses one.
-- The player who lost (or won back) a die starts the next round; a player
-- with no dice left is out; the last one standing wins.

local Board = {}
Board.__index = Board

Board.START_DICE  = 5
Board.FACES       = 6
Board.MIN_PLAYERS = 2
Board.MAX_PLAYERS = 6

-- players: { { name = "Alice", ai = false }, ... }
function Board.new(opts)
    local self = setmetatable({}, Board)
    self.rng     = opts.rng or math.random
    self.wild    = opts.wild ~= false
    self.exact   = opts.exact ~= false
    self.players = {}
    for i, p in ipairs(opts.players) do
        self.players[i] = { name = p.name, ai = p.ai and true or false, count = Board.START_DICE, dice = {} }
    end
    self.starter = 1
    self.round   = 0
    self:newRound()
    return self
end

-- ---------------------------------------------------------------------------
-- Rules (static, so the AI and the tests can use them without a board)
-- ---------------------------------------------------------------------------

-- Is (q, f) a legal bid after `prev` ({ q, f } or nil for the opening bid)?
function Board.isLegal(prev, q, f, wild, total)
    if type(q) ~= "number" or type(f) ~= "number" then return false end
    if q ~= math.floor(q) or f ~= math.floor(f) then return false end
    if f < 1 or f > Board.FACES or q < 1 or q > total then return false end
    if not prev then
        return not (wild and f == 1)
    end
    if not wild then
        return q > prev.q or (q == prev.q and f > prev.f)
    end
    if prev.f == 1 and f == 1 then return q > prev.q end
    if prev.f ~= 1 and f == 1 then return q >= math.ceil(prev.q / 2) end
    if prev.f == 1 and f ~= 1 then return q >= 2 * prev.q + 1 end
    return q > prev.q or (q == prev.q and f > prev.f)
end

-- Smallest legal quantity for face f, or nil when there is none.
function Board.minQuantity(prev, f, wild, total)
    for q = 1, total do
        if Board.isLegal(prev, q, f, wild, total) then return q end
    end
    return nil
end

-- How many of `dice` count towards a bid on face f.
function Board.matches(dice, f, wild)
    local n = 0
    for _i, d in ipairs(dice) do
        if d == f or (wild and f ~= 1 and d == 1) then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- State queries
-- ---------------------------------------------------------------------------

function Board:isAlive(i)
    return self.players[i].count > 0
end

function Board:aliveCount()
    local n = 0
    for i = 1, #self.players do
        if self:isAlive(i) then n = n + 1 end
    end
    return n
end

function Board:totalDice()
    local n = 0
    for _i, p in ipairs(self.players) do n = n + p.count end
    return n
end

-- Next living seat after i (wrapping).
function Board:nextAlive(i)
    local n = #self.players
    for k = 1, n do
        local j = (i - 1 + k) % n + 1
        if self:isAlive(j) then return j end
    end
    return i
end

function Board:winner()
    if self:aliveCount() ~= 1 then return nil end
    for i = 1, #self.players do
        if self:isAlive(i) then return i end
    end
end

function Board:countFace(f)
    local n = 0
    for _i, p in ipairs(self.players) do n = n + Board.matches(p.dice, f, self.wild) end
    return n
end

function Board:canBid(q, f)
    return self.phase == "bidding" and Board.isLegal(self.bid, q, f, self.wild, self:totalDice())
end

-- Can the current player bid at all? (Not when the bid is already maxed out.)
function Board:hasLegalBid()
    for f = 1, Board.FACES do
        if Board.minQuantity(self.bid, f, self.wild, self:totalDice()) then return true end
    end
    return false
end

function Board:canCallExact()
    return self.phase == "bidding" and self.exact and self.bid ~= nil
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local function sortDice(t)
    table.sort(t)
    return t
end

function Board:newRound()
    if self:aliveCount() <= 1 then
        self.phase = "over"
        return
    end
    self.round = self.round + 1
    for _i, p in ipairs(self.players) do
        p.dice = {}
        for k = 1, p.count do p.dice[k] = self.rng(Board.FACES) end
        sortDice(p.dice)
    end
    if not self:isAlive(self.starter) then self.starter = self:nextAlive(self.starter) end
    self.current = self.starter
    self.bid     = nil
    self.history = {}
    self.result  = nil
    self.phase   = "bidding"
end

function Board:placeBid(q, f)
    if not self:canBid(q, f) then return false end
    self.bid = { q = q, f = f, by = self.current }
    self.history[#self.history + 1] = { p = self.current, q = q, f = f }
    self.current = self:nextAlive(self.current)
    return true
end

local function loseDie(self, i)
    local p = self.players[i]
    p.count = math.max(0, p.count - 1)
end

-- Shared end of a challenge: record the result and decide who starts next.
function Board:_settle(result, starter)
    self.result = result
    self.phase  = "reveal"
    self.starter = self:isAlive(starter) and starter or self:nextAlive(starter)
    if self:aliveCount() <= 1 then self.phase = "over" end
end

function Board:callLiar()
    if self.phase ~= "bidding" or not self.bid then return false end
    local caller, bid = self.current, self.bid
    local count = self:countFace(bid.f)
    local loser = count >= bid.q and caller or bid.by
    loseDie(self, loser)
    self:_settle({ kind = "liar", caller = caller, bidder = bid.by, q = bid.q, f = bid.f,
                   count = count, loser = loser, truth = count >= bid.q }, loser)
    return true
end

function Board:callExact()
    if not self:canCallExact() then return false end
    local caller, bid = self.current, self.bid
    local count = self:countFace(bid.f)
    local right = count == bid.q
    local res = { kind = "exact", caller = caller, bidder = bid.by, q = bid.q, f = bid.f,
                  count = count, right = right }
    if right then
        local p = self.players[caller]
        if p.count < Board.START_DICE then
            p.count = p.count + 1
            res.gainer = caller
        end
    else
        loseDie(self, caller)
        res.loser = caller
    end
    self:_settle(res, caller)
    return true
end

-- ---------------------------------------------------------------------------
-- Save / restore
-- ---------------------------------------------------------------------------

function Board:serialize()
    local players = {}
    for i, p in ipairs(self.players) do
        players[i] = { name = p.name, ai = p.ai, count = p.count, dice = p.dice }
    end
    return {
        players = players, wild = self.wild, exact = self.exact,
        starter = self.starter, current = self.current, round = self.round,
        bid = self.bid, history = self.history, result = self.result, phase = self.phase,
    }
end

function Board.load(t, rng)
    if type(t) ~= "table" or type(t.players) ~= "table" or #t.players < Board.MIN_PLAYERS then
        return nil
    end
    local self = setmetatable({}, Board)
    self.rng     = rng or math.random
    self.wild    = t.wild and true or false
    self.exact   = t.exact and true or false
    self.players = {}
    for i, p in ipairs(t.players) do
        if type(p.count) ~= "number" or type(p.dice) ~= "table" or #p.dice ~= p.count then
            return nil
        end
        self.players[i] = { name = p.name, ai = p.ai and true or false, count = p.count, dice = p.dice }
    end
    self.starter = t.starter or 1
    self.current = t.current or 1
    self.round   = t.round or 1
    self.bid     = t.bid
    self.history = t.history or {}
    self.result  = t.result
    self.phase   = t.phase
    if self.phase ~= "bidding" and self.phase ~= "reveal" and self.phase ~= "over" then
        return nil
    end
    return self
end

return Board
