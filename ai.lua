-- Liar's Dice -- computer player.
--
-- A simple probabilistic bidder. It sees only its own dice and the number of
-- dice the others hold. For any bid it works out the chance that the bid is
-- true, from its own matching dice plus a binomial guess on the unknown ones
-- (p = 1/6, or 1/3 for a face other than 1 when 1s are wild). Then:
--   * Liar! when the current bid is more likely false than its best raise is
--     true (or when no raise is left);
--   * Exact when the exact count is unusually likely;
--   * otherwise the raise with the best chance, preferring faces it holds,
--     with a little noise so it is not predictable.
-- Every bid it returns is checked with Board.isLegal; it never bids illegally.

local AI = {}

local function binom(n, k)
    if k < 0 or k > n then return 0 end
    local r = 1
    for i = 1, math.min(k, n - k) do
        r = r * (n - i + 1) / i
    end
    return r
end

-- P(X = k), X ~ Binomial(n, p)
function AI.probExactly(n, p, k)
    if k < 0 or k > n then return 0 end
    return binom(n, k) * p ^ k * (1 - p) ^ (n - k)
end

-- P(X >= k)
function AI.probAtLeast(n, p, k)
    if k <= 0 then return 1 end
    if k > n then return 0 end
    local s = 0
    for j = k, n do s = s + AI.probExactly(n, p, j) end
    return math.min(1, s)
end

local function faceProb(f, wild)
    return (wild and f ~= 1) and (1 / 3) or (1 / 6)
end

-- Chance that "q dice show f" is true, seen from `dice`.
function AI.chanceTrue(Board, dice, unknown, q, f, wild)
    local need = q - Board.matches(dice, f, wild)
    return AI.probAtLeast(unknown, faceProb(f, wild), need)
end

function AI.chanceExact(Board, dice, unknown, q, f, wild)
    local need = q - Board.matches(dice, f, wild)
    return AI.probExactly(unknown, faceProb(f, wild), need)
end

-- Decide for the board's current player. Returns
--   { action = "bid", q = Q, f = F } | { action = "liar" } | { action = "exact" }
function AI.decide(Board, board, rng)
    rng = rng or math.random
    local function noise(a) return (rng() - 0.5) * 2 * a end
    local me    = board.players[board.current]
    local dice  = me.dice
    local total = board:totalDice()
    local unknown = total - #dice
    local wild  = board.wild
    local prev  = board.bid

    -- Candidate raises: for each face, the smallest legal quantity and one more.
    local best
    for f = 1, Board.FACES do
        local q0 = Board.minQuantity(prev, f, wild, total)
        if q0 then
            for q = q0, math.min(q0 + 1, total) do
                if Board.isLegal(prev, q, f, wild, total) then
                    local p = AI.chanceTrue(Board, dice, unknown, q, f, wild)
                    -- Holding the face makes the bid feel safer and steers the
                    -- table towards it; jumping a step costs a little.
                    local score = p + 0.03 * Board.matches(dice, f, wild)
                                  - 0.04 * (q - q0) + noise(0.06)
                    if not best or score > best.score then
                        best = { q = q, f = f, p = p, score = score }
                    end
                end
            end
        end
    end

    if not prev then
        -- Open on the face it holds most of, a little under the expected count.
        local face, held = nil, -1
        for f = 1, Board.FACES do
            if Board.isLegal(nil, 1, f, wild, total) then
                local m = Board.matches(dice, f, wild) + noise(0.5)
                if m > held then face, held = f, m end
            end
        end
        local q = Board.matches(dice, face, wild)
                  + math.floor(unknown * faceProb(face, wild) * (0.6 + 0.3 * rng()))
        q = math.max(1, math.min(q, total))
        if Board.isLegal(nil, q, face, wild, total) then
            return { action = "bid", q = q, f = face }
        end
        return { action = "bid", q = best.q, f = best.f }
    end

    local p_true = AI.chanceTrue(Board, dice, unknown, prev.q, prev.f, wild)

    if board:canCallExact() then
        local pe = AI.chanceExact(Board, dice, unknown, prev.q, prev.f, wild)
        -- Exact rarely pays; only when it is about as likely as anything.
        if pe > 0.33 + noise(0.04) and (not best or pe >= best.p - 0.1) then
            return { action = "exact" }
        end
    end

    if not best then return { action = "liar" } end
    if (1 - p_true) + noise(0.08) > best.p then
        return { action = "liar" }
    end
    return { action = "bid", q = best.q, f = best.f }
end

return AI
