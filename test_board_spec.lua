-- Bidding legality (with and without wild ones), counting, the outcome of
-- Liar!/Exact!, elimination, save/restore -- and the computer player, which
-- must never bid illegally whatever the table looks like.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

-- An rng returning queued dice faces (then 2s).
local function queue(faces)
    local q = {}
    for i, f in ipairs(faces) do q[i] = f end
    return function(n)
        if n == 6 then return table.remove(q, 1) or 2 end
        return 1
    end
end

local function players(n)
    local t = {}
    for i = 1, n do t[i] = { name = "P" .. i, ai = false } end
    return t
end

describe("Liar's Dice board", function()
    local Board, AI
    setup(function()
        Board = require("board")
        AI = require("ai")
    end)

    describe("legality without wilds", function()
        local function legal(prev, q, f) return Board.isLegal(prev, q, f, false, 20) end
        it("opens on any face, 1s included", function()
            assert.is_true(legal(nil, 1, 1))
            assert.is_true(legal(nil, 3, 6))
            assert.is_false(legal(nil, 0, 3))
            assert.is_false(legal(nil, 21, 3))
            assert.is_false(legal(nil, 2, 7))
            assert.is_false(legal(nil, 1.5, 3))
        end)
        it("raises quantity or face", function()
            local prev = { q = 3, f = 4 }
            assert.is_true(legal(prev, 3, 5))
            assert.is_true(legal(prev, 4, 1))
            assert.is_false(legal(prev, 3, 4))
            assert.is_false(legal(prev, 3, 2))
            assert.is_false(legal(prev, 2, 6))
        end)
    end)

    describe("legality with wild ones (Paco rule)", function()
        local function legal(prev, q, f) return Board.isLegal(prev, q, f, true, 20) end
        it("cannot open on 1s", function()
            assert.is_false(legal(nil, 1, 1))
            assert.is_true(legal(nil, 1, 2))
        end)
        it("halves (rounded up) to go to 1s", function()
            assert.is_true(legal({ q = 5, f = 4 }, 3, 1))
            assert.is_false(legal({ q = 5, f = 4 }, 2, 1))
            assert.is_true(legal({ q = 6, f = 6 }, 3, 1))
            assert.is_true(legal({ q = 1, f = 3 }, 1, 1))
        end)
        it("doubles plus one to leave 1s", function()
            assert.is_true(legal({ q = 3, f = 1 }, 7, 2))
            assert.is_false(legal({ q = 3, f = 1 }, 6, 6))
            assert.is_true(legal({ q = 3, f = 1 }, 4, 1))
            assert.is_false(legal({ q = 3, f = 1 }, 3, 1))
        end)
        it("raises normally between other faces", function()
            assert.is_true(legal({ q = 3, f = 4 }, 3, 5))
            assert.is_false(legal({ q = 3, f = 4 }, 3, 3))
        end)
        it("finds the minimum quantity per face", function()
            assert.are.equal(3, Board.minQuantity({ q = 5, f = 4 }, 1, true, 20))
            assert.are.equal(5, Board.minQuantity({ q = 5, f = 4 }, 6, true, 20))
            assert.are.equal(6, Board.minQuantity({ q = 5, f = 4 }, 2, true, 20))
            assert.are.equal(7, Board.minQuantity({ q = 3, f = 1 }, 5, true, 20))
            assert.is_nil(Board.minQuantity({ q = 10, f = 1 }, 5, true, 20))
        end)
    end)

    describe("counting", function()
        it("counts 1s as wild except on a bid on 1s", function()
            local dice = { 1, 1, 3, 4, 4 }
            assert.are.equal(4, Board.matches(dice, 4, true))
            assert.are.equal(2, Board.matches(dice, 4, false))
            assert.are.equal(2, Board.matches(dice, 1, true))
            assert.are.equal(2, Board.matches(dice, 6, true))
        end)
    end)

    describe("a round", function()
        local function rigged(wild, faces, n)
            return Board.new{ players = players(n or 2), wild = wild, exact = true, rng = queue(faces) }
        end

        it("rolls dice for every player and starts with the starter", function()
            local b = rigged(true, { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 })
            assert.are.same({ 1, 2, 3, 4, 5 }, b.players[1].dice)
            assert.are.same({ 6, 6, 6, 6, 6 }, b.players[2].dice)
            assert.are.equal(10, b:totalDice())
            assert.are.equal("bidding", b.phase)
            assert.are.equal(1, b.current)
        end)

        it("refuses illegal bids and passes the turn on legal ones", function()
            local b = rigged(true, { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 })
            assert.is_false(b:placeBid(1, 1))       -- no opening on 1s
            assert.is_true(b:placeBid(3, 6))
            assert.are.equal(2, b.current)
            assert.is_false(b:placeBid(3, 5))
            assert.is_true(b:placeBid(2, 1))        -- ceil(3/2) = 2
            assert.are.equal(1, b.current)
        end)

        it("Liar! on a true bid costs the caller a die", function()
            local b = rigged(true, { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 })
            b:placeBid(6, 6)                        -- 5 sixes + one wild 1 = 6
            assert.is_true(b:callLiar())
            assert.are.equal("reveal", b.phase)
            assert.are.equal(6, b.result.count)
            assert.is_true(b.result.truth)
            assert.are.equal(2, b.result.loser)
            assert.are.equal(4, b.players[2].count)
            assert.are.equal(2, b.starter)
        end)

        it("Liar! on a false bid costs the bidder a die", function()
            local b = rigged(false, { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 })
            b:placeBid(6, 6)                        -- no wilds: only 5 sixes
            b:callLiar()
            assert.is_false(b.result.truth)
            assert.are.equal(1, b.result.loser)
            assert.are.equal(4, b.players[1].count)
        end)

        it("Exact! right gives a die back (up to 5), wrong costs one", function()
            local b = rigged(true, { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 })
            b.players[2].count = 4
            b.players[2].dice = { 6, 6, 6, 6 }
            b:placeBid(5, 6)                        -- 4 sixes + one 1 = 5
            assert.is_true(b:callExact())
            assert.is_true(b.result.right)
            assert.are.equal(2, b.result.gainer)
            assert.are.equal(5, b.players[2].count)

            b = rigged(true, { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 })
            b:placeBid(5, 6)                        -- actually 6
            b:callExact()
            assert.is_false(b.result.right)
            assert.are.equal(4, b.players[2].count)

            b = rigged(true, { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 })
            b:placeBid(6, 6)
            b:callExact()                           -- right, but already 5 dice
            assert.is_true(b.result.right)
            assert.is_nil(b.result.gainer)
            assert.are.equal(5, b.players[2].count)
        end)

        it("Exact! can be switched off", function()
            local b = Board.new{ players = players(2), exact = false, rng = queue({}) }
            b:placeBid(2, 3)
            assert.is_false(b:canCallExact())
            assert.is_false(b:callExact())
        end)

        it("eliminates players and ends with a winner", function()
            local b = rigged(false, { 6, 6, 6, 6, 6, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3 }, 3)
            b.players[2].count = 1
            b.players[2].dice = { 2 }
            b.current = 2
            b:placeBid(3, 6)                        -- P2 bids, P3 calls: true -> P3 loses
            b:callLiar()
            assert.are.equal(3, b.result.loser)
            b:newRound()
            assert.are.equal(3, b.current)          -- loser starts
            b.players[3].dice = { 3, 3, 3, 3 }
            b:placeBid(10, 3)                       -- false: P3 bidder loses
            assert.are.equal(1, b.current)
            b.players[1].count = 1
            b.players[1].dice = { 6 }
            b.players[3].count = 1
            b.players[3].dice = { 3 }
            -- P1 calls Liar on P3's false bid: P3 eliminated
            b:callLiar()
            assert.are.equal(0, b.players[3].count)
            assert.are.equal("reveal", b.phase)
            assert.are.equal(1, b.starter)          -- P3 is out: next living seat
            b.players[2].count = 0
            b:callLiar()                            -- nothing to call in reveal
            b:newRound()
            assert.are.equal("over", b.phase)
            assert.are.equal(1, b:winner())
        end)

        it("skips eliminated players in turn order", function()
            local b = rigged(false, {}, 4)
            b.players[2].count = 0
            b.players[2].dice = {}
            b.current = 1
            b:placeBid(1, 3)
            assert.are.equal(3, b.current)
            assert.are.equal(1, b:nextAlive(4))
        end)

        it("round-trips through serialize/load", function()
            local b = rigged(true, { 1, 2, 3, 4, 5, 6, 6, 6, 6, 6 })
            b:placeBid(3, 4)
            local t = b:serialize()
            local c = Board.load(t)
            assert.are.same(t, c:serialize())
            assert.is_true(c:canBid(3, 5))
            assert.is_nil(Board.load({ players = {} }))
            assert.is_nil(Board.load("junk"))
        end)
    end)

    describe("probabilities", function()
        it("binomial tails add up", function()
            assert.are.near(1, AI.probAtLeast(10, 1 / 6, 0), 1e-9)
            assert.are.near(1 - (5 / 6) ^ 10, AI.probAtLeast(10, 1 / 6, 1), 1e-9)
            assert.are.equal(0, AI.probAtLeast(3, 0.5, 4))
            local s = 0
            for k = 0, 8 do s = s + AI.probExactly(8, 1 / 3, k) end
            assert.are.near(1, s, 1e-9)
        end)
    end)

    describe("computer player", function()
        it("never bids illegally (random tables, both rule sets)", function()
            math.randomseed(42)
            for trial = 1, 1500 do
                local n = math.random(2, 6)
                local wild = trial % 2 == 0
                local b = Board.new{ players = players(n), wild = wild, exact = trial % 3 ~= 0 }
                for i = 1, n do
                    local p = b.players[i]
                    p.count = math.random(0, 5)
                    p.dice = {}
                    for k = 1, p.count do p.dice[k] = math.random(6) end
                end
                if b:aliveCount() < 2 then
                    b.players[1].count, b.players[1].dice = 1, { 3 }
                    b.players[2].count, b.players[2].dice = 2, { 1, 6 }
                end
                b.current = b:nextAlive(n)
                -- Play a whole bidding round with the AI on every seat.
                local steps = 0
                while b.phase == "bidding" and steps < 200 do
                    steps = steps + 1
                    local prev = b.bid
                    local d = AI.decide(Board, b)
                    if d.action == "bid" then
                        assert.is_true(Board.isLegal(prev, d.q, d.f, b.wild, b:totalDice()),
                            string.format("illegal %s×%s after %s", d.q, d.f,
                                prev and (prev.q .. "×" .. prev.f) or "nothing"))
                        assert.is_true(b:placeBid(d.q, d.f))
                    elseif d.action == "exact" then
                        assert.is_true(b.exact and prev ~= nil)
                        assert.is_true(b:callExact())
                    else
                        assert.are.equal("liar", d.action)
                        assert.is_not_nil(prev, "Liar! with no bid")
                        assert.is_true(b:callLiar())
                    end
                end
                assert.are_not.equal("bidding", b.phase, "a round never ended")
            end
        end)

        it("calls Liar! when no raise is left", function()
            local b = Board.new{ players = players(2), wild = false, rng = queue({}) }
            b:placeBid(10, 6)
            assert.are.equal("liar", AI.decide(Board, b, function() return 0.5 end).action)
        end)

        it("calls an obviously false bid", function()
            local b = Board.new{ players = players(2), wild = false, exact = false,
                                 rng = queue({ 2, 2, 2, 2, 2, 3, 3, 3, 3, 3 }) }
            b:placeBid(9, 5)       -- P2 holds no 5; needs 9 of P1's 5 dice
            assert.are.equal("liar", AI.decide(Board, b, function() return 0.5 end).action)
        end)

        it("raises rather than calls a cautious bid it can back", function()
            local b = Board.new{ players = players(2), wild = false, exact = false,
                                 rng = queue({ 2, 3, 4, 5, 6, 6, 6, 6, 6, 6 }) }
            b:placeBid(2, 6)       -- P2 holds five 6s
            local d = AI.decide(Board, b, function() return 0.5 end)
            assert.are.equal("bid", d.action)
            assert.are.equal(6, d.f)
        end)
    end)
end)
