local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RenderText      = require("ui/rendertext")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local MenuHelper = require("menu_helper")
local ScreenBase = require("screen_base")

local Board   = lrequire("board")
local AI      = lrequire("ai")
local DiceRow = lrequire("dice_widget")
local Players = lrequire("players")

local DeviceScreen = Device.screen

local BOT_DELAY = 1.5   -- seconds between computer moves, to read them

-- ---------------------------------------------------------------------------
-- Text helpers (Font:getFace() scales by DPI: pixel sizes are divided back)
-- ---------------------------------------------------------------------------

local DPI_SCALE = DeviceScreen:scaleBySize(1000) / 1000

local function pxFace(px, bold)
    return Font:getFace(bold and "smallinfofontbold" or "cfont", math.max(8, math.floor(px / DPI_SCALE)))
end

local function fitLine(text, px, max_w, bold)
    local face = pxFace(px, bold)
    while px > 12 do
        local m = RenderText:sizeUtf8Text(0, max_w * 10, face, text, true, bold)
        if m.x <= max_w then break end
        px   = math.floor(px * 0.9)
        face = pxFace(px, bold)
    end
    return TextWidget:new{ text = text, face = face, max_width = max_w, bold = bold }
end

local function wrap(text, px, width)
    return TextBoxWidget:new{ text = text, face = pxFace(px), width = width, alignment = "center" }
end

local function vspan(h) return VerticalSpan:new{ width = math.floor(h) } end
local function hspan(w) return HorizontalSpan:new{ width = math.floor(w) } end

-- A tappable area (the hand-over card, the player's own dice).
local TapArea = InputContainer:extend{ callback = nil }

function TapArea:init()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function TapArea:onTap()
    if self.callback then self.callback() end
    return true
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = [[
Liar's Dice — Rules

Each player starts with 5 dice hidden under a cup. Everybody rolls, then looks at their own dice only.

On your turn, either:
• Bid: announce that there are at least Q dice showing face F among ALL the dice on the table ("4 × 5": at least four fives). Each bid must be higher than the previous one: more dice (any face), or the same number of dice with a higher face.
• Liar!: you think the last bid is false. All dice are revealed and counted. If there are fewer than Q, the bidder loses a die; otherwise you do.
• Exact! (optional): you think the last bid is exactly right. If it is, you win a die back (up to 5); otherwise you lose one.

Wild ones (optional, on by default): 1s count as any face. You cannot open on 1s. Going from a face to 1s, the number of dice may be halved (rounded up); going back from 1s to a face, it must be at least double plus one.

The player who lost (or won back) a die starts the next round. A player with no dice left is out; the last player standing wins.

On the reader: when it's your turn, the game asks to pass the reader to you; tap Ready to see your dice (tap them to hide them again). Pick a face and a quantity, then Bid, Liar! or Exact!. Computer players (up to 5) play on their own. With a single human player no hand-over is needed. At the reveal, the dice that count for the bid are drawn in black.
]]

local GAME_RULES_FR = [[
Dés menteurs — Règles

Chaque joueur commence avec 5 dés cachés sous un gobelet. Tout le monde lance, puis ne regarde que ses propres dés.

À votre tour, au choix :
• Enchérir : annoncez qu'il y a au moins Q dés montrant la face F parmi TOUS les dés de la table (« 4 × 5 » : au moins quatre cinq). Chaque enchère doit dépasser la précédente : plus de dés (n'importe quelle face), ou autant de dés avec une face plus haute.
• Menteur ! : vous pensez que la dernière enchère est fausse. On révèle et on compte tous les dés. S'il y en a moins que Q, l'enchérisseur perd un dé ; sinon, c'est vous.
• Pile ! (facultatif) : vous pensez que la dernière enchère est exacte. Si c'est le cas, vous regagnez un dé (jusqu'à 5) ; sinon vous en perdez un.

As jokers (facultatif, activé par défaut) : les 1 (les « pacos ») comptent pour n'importe quelle face. On ne peut pas ouvrir sur les 1. Pour passer d'une face aux 1, le nombre de dés peut être divisé par deux (arrondi au supérieur) ; pour revenir des 1 à une face, il faut au moins le double plus un.

Le joueur qui a perdu (ou regagné) un dé commence la manche suivante. Un joueur qui n'a plus de dés est éliminé ; le dernier en lice gagne.

Sur la liseuse : à votre tour, le jeu demande de vous passer la liseuse ; touchez Prêt pour voir vos dés (touchez-les pour les cacher à nouveau). Choisissez une face et une quantité, puis Enchérir, Menteur ! ou Pile !. Les joueurs ordinateur (jusqu'à 5) jouent seuls. Avec un seul joueur humain, pas besoin de passer la liseuse. À la révélation, les dés qui comptent pour l'enchère sont dessinés en noir.
]]

-- ---------------------------------------------------------------------------
-- LiarsDiceScreen
-- ---------------------------------------------------------------------------

local LiarsDiceScreen = ScreenBase:extend{}

function LiarsDiceScreen:init()
    self.board = Board.load(self.plugin:loadState())
    if not self.board then self:_newBoard() end
    self:_advance()
    ScreenBase.init(self)
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function LiarsDiceScreen:_humans()
    return math.max(1, math.min(Board.MAX_PLAYERS, self.plugin:getSetting("humans", 1)))
end

-- Two to six players in all: a lone human always gets a computer.
function LiarsDiceScreen:_bots()
    local h = self:_humans()
    local b = self.plugin:getSetting("bots", 2)
    return math.max(Board.MIN_PLAYERS - h, math.min(b, Board.MAX_PLAYERS - h))
end

function LiarsDiceScreen:_wild()
    return self.plugin:getSetting("wild", true)
end

function LiarsDiceScreen:_exact()
    return self.plugin:getSetting("exact", true)
end

function LiarsDiceScreen:_newBoard()
    local list = {}
    for _i, s in ipairs(Players.load(self.plugin, self:_humans())) do
        list[#list + 1] = { name = s, ai = false }
    end
    local nb = self:_bots()
    for i = 1, nb do
        list[#list + 1] = { name = nb == 1 and _("Computer") or T(_("Computer %1"), i), ai = true }
    end
    -- Seats: humans and computers alternate a little so the table feels mixed.
    self.board = Board.new{ players = list, wild = self:_wild(), exact = self:_exact() }
    self.board.starter = math.random(#list)
    self.board.current = self.board.starter
    self.last_msg = nil
end

function LiarsDiceScreen:_humanCount()
    local n = 0
    for _i, p in ipairs(self.board.players) do
        if not p.ai and p.count > 0 then n = n + 1 end
    end
    return n
end

function LiarsDiceScreen:serializeState()
    return self.board:serialize()
end

function LiarsDiceScreen:_save()
    self.plugin:saveState(self.board:serialize())
end

function LiarsDiceScreen:closeScreen()
    self.closed = true
    if self._bot_step then UIManager:unschedule(self._bot_step) end
    ScreenBase.closeScreen(self)
end

function LiarsDiceScreen:isRoundOver()
    return self.board.phase == "over"
end

-- ---------------------------------------------------------------------------
-- Flow
--
-- ui: "handover" (pass the reader), "turn" (a human bids, dice shown),
--     "table" (a computer is playing), "reveal" (dice shown after a call).
-- ---------------------------------------------------------------------------

function LiarsDiceScreen:_advance()
    local b = self.board
    self.dice_hidden = false
    if b.phase ~= "bidding" then
        self.ui = "reveal"
        return
    end
    local p = b.players[b.current]
    if p.ai then
        self.ui = "table"
        self:_scheduleBot()
    elseif self:_humanCount() > 1 then
        self.ui = "handover"
    else
        self:_startTurn()
    end
end

function LiarsDiceScreen:_redraw()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function LiarsDiceScreen:_scheduleBot()
    if self._bot_step or self.closed then return end
    self._bot_step = function()
        self._bot_step = nil
        if self.closed then return end
        self:_botMove()
    end
    UIManager:scheduleIn(BOT_DELAY, self._bot_step)
end

function LiarsDiceScreen:_botMove()
    local b = self.board
    if b.phase ~= "bidding" or not b.players[b.current].ai then return end
    local d = AI.decide(Board, b)
    local name = b.players[b.current].name
    if d.action == "bid" and b:placeBid(d.q, d.f) then
        self.last_msg = T(_("%1 bids %2 × %3"), name, d.q, d.f)
    elseif d.action == "exact" and b:callExact() then
        self.last_msg = nil
    else
        b:callLiar()
        self.last_msg = nil
    end
    self:_save()
    self:_advance()
    self:_redraw()
    self:refreshActionBar()
end

function LiarsDiceScreen:onNewGame()
    if self._bot_step then UIManager:unschedule(self._bot_step) end
    self._bot_step = nil
    self:_newBoard()
    self:_save()
    self:_advance()
    self:_redraw()
end

function LiarsDiceScreen:onReady()
    if self.ui ~= "handover" then return end
    self:_startTurn()
    self:_redraw()
end

-- Preselect the smallest legal raise, on the face the player holds most of.
function LiarsDiceScreen:_startTurn()
    local b = self.board
    self.ui = "turn"
    self.dice_hidden = false
    local total = b:totalDice()
    local dice = b.players[b.current].dice
    local face, best = nil, -1
    for f = Board.FACES, 1, -1 do
        if Board.minQuantity(b.bid, f, b.wild, total) then
            local m = Board.matches(dice, f, b.wild)
            if b.bid and f == b.bid.f then m = m + 0.5 end
            if m > best then face, best = f, m end
        end
    end
    self.sel_f = face or (b.bid and b.bid.f) or 2
    self.sel_q = face and Board.minQuantity(b.bid, face, b.wild, total) or (b.bid and b.bid.q) or 1
end

function LiarsDiceScreen:onFace(f)
    if self.ui ~= "turn" or self.dice_hidden then return end
    local b = self.board
    self.sel_f = f
    local total = b:totalDice()
    if not Board.isLegal(b.bid, self.sel_q, f, b.wild, total) then
        local q = Board.minQuantity(b.bid, f, b.wild, total)
        if q then self.sel_q = q end
    end
    self:_redraw()
end

function LiarsDiceScreen:onQuantity(delta)
    if self.ui ~= "turn" or self.dice_hidden then return end
    local total = self.board:totalDice()
    self.sel_q = math.max(1, math.min(total, self.sel_q + delta))
    self:_redraw()
end

function LiarsDiceScreen:_finishHumanAction()
    self:_save()
    self:_advance()
    self:_redraw()
    self:refreshActionBar()
end

function LiarsDiceScreen:onBid()
    if self.ui ~= "turn" or self.dice_hidden then return end
    local b = self.board
    local q, f = self.sel_q, self.sel_f
    if not b:canBid(q, f) then
        self:updateStatus(self:_whyIllegal(q, f))
        return
    end
    local name = b.players[b.current].name
    b:placeBid(q, f)
    self.last_msg = T(_("%1 bids %2 × %3"), name, q, f)
    self:_finishHumanAction()
end

function LiarsDiceScreen:_whyIllegal(q, f)
    local b = self.board
    if not b.bid and b.wild and f == 1 then
        return _("You cannot open the bidding on 1s.")
    end
    local minq = Board.minQuantity(b.bid, f, b.wild, b:totalDice())
    if not minq then
        return T(_("No higher bid on %1 is possible."), f)
    end
    return T(_("Too low: bid at least %1 × %2."), minq, f)
end

function LiarsDiceScreen:onLiar()
    if self.ui ~= "turn" then return end
    if not self.board.bid then
        self:updateStatus(_("Nobody has bid yet: open the bidding."))
        return
    end
    self.board:callLiar()
    self.last_msg = nil
    self:_finishHumanAction()
end

function LiarsDiceScreen:onExact()
    if self.ui ~= "turn" then return end
    if not self.board.bid then
        self:updateStatus(_("Nobody has bid yet: open the bidding."))
        return
    end
    self.board:callExact()
    self.last_msg = nil
    self:_finishHumanAction()
end

function LiarsDiceScreen:onNextRound()
    if self.board.phase ~= "reveal" then return end
    self.board:newRound()
    self.last_msg = nil
    self:_save()
    self:_advance()
    self:_redraw()
    self:refreshActionBar()
end

function LiarsDiceScreen:onToggleDice()
    if self.ui ~= "turn" then return end
    self.dice_hidden = not self.dice_hidden
    self:_redraw()
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

local function countItems(from, to)
    local items = {}
    for n = from, to do items[#items + 1] = { id = n, text = tostring(n) } end
    return items
end

local function onOff(v) return v and _("On") or _("Off") end

function LiarsDiceScreen:openPlayersMenu()
    MenuHelper.openPickerMenu{
        title      = _("Players"),
        items      = countItems(1, Board.MAX_PLAYERS),
        current_id = self:_humans(),
        parent     = self,
        on_select  = function(n)
            self.plugin:saveSetting("humans", n)
            self:onNewGame()
        end,
    }
end

function LiarsDiceScreen:openBotsMenu()
    local h = self:_humans()
    MenuHelper.openPickerMenu{
        title      = _("Computer players"),
        items      = countItems(math.max(0, Board.MIN_PLAYERS - h), Board.MAX_PLAYERS - h),
        current_id = self:_bots(),
        parent     = self,
        on_select  = function(n)
            self.plugin:saveSetting("bots", n)
            self:onNewGame()
        end,
    }
end

function LiarsDiceScreen:toggleSetting(key)
    local v = not self.plugin:getSetting(key, true)
    self.plugin:saveSetting(key, v)
    self:onNewGame()
end

function LiarsDiceScreen:openNamesMenu()
    local names = Players.load(self.plugin, self:_humans())
    Players.openEditor(self.plugin, names, function()
        -- Rename the humans of the game in progress, in seat order.
        local k = 0
        for _i, p in ipairs(self.board.players) do
            if not p.ai then
                k = k + 1
                if names[k] then p.name = names[k] end
            end
        end
        self:_save()
        self:_redraw()
    end, self)
end

function LiarsDiceScreen:_titleBar()
    return self:buildTitleBar(_("Liar's Dice"), function()
        return {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = T(_("Players: %1"), self:_humans()), callback = function() self:openPlayersMenu() end },
            { text = T(_("Computers: %1"), self:_bots()), callback = function() self:openBotsMenu() end },
            { text = T(_("Wild ones: %1"), onOff(self:_wild())), callback = function() self:toggleSetting("wild") end },
            { text = T(_("Exact call: %1"), onOff(self:_exact())), callback = function() self:toggleSetting("exact") end },
            { text = _("Player names"), callback = function() self:openNamesMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function LiarsDiceScreen:buildLayout()
    local title_bar = self:_titleBar()
    local controls  = self:_buildControls()
    local bw, bh = self:getBoardBudget(title_bar, controls)
    local content
    local scale = 1
    while true do
        content = self:_buildContent(bw, bh, scale)
        if content:getSize().h <= bh or scale < 0.45 then break end
        scale = scale * 0.85
    end
    if self.ui == "handover" then
        content = TapArea:new{ callback = function() self:onReady() end, content }
    end
    if self:isLandscape() then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            CenterContainer:new{ dimen = Geom:new{ w = bw, h = math.min(bh, content:getSize().h) }, content },
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, content,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function LiarsDiceScreen:_buildControls()
    local b = self.board
    local w = self:getControlsWidth()
    self.status_text:setMaxWidth(w)
    local group = VerticalGroup:new{ align = "center", self.status_text,
                                     VerticalSpan:new{ width = Size.span.vertical_large } }
    local rows
    if self.ui == "handover" then
        rows = { { text = _("Ready"), callback = function() self:onReady() end } }
    elseif self.ui == "turn" then
        -- While the dice are hidden, the preselected face and quantity would
        -- tell onlookers what the player holds: show neither, and let only
        -- Liar!/Exact! act until the dice are shown again.
        local hidden = self.dice_hidden
        local land = self:isLandscape()
        local faces = {}
        for f = 1, Board.FACES do
            faces[f] = { text = (f == self.sel_f and not hidden) and ("[" .. f .. "]") or tostring(f),
                         enabled = not hidden,
                         callback = function() self:onFace(f) end }
        end
        if land then
            -- Two rows of three: six keys on one row of the narrow side panel
            -- are too small to hit reliably.
            group[#group + 1] = self:buildNumberPad({ faces[1], faces[2], faces[3] }, w)
            group[#group + 1] = self:buildNumberPad({ faces[4], faces[5], faces[6] }, w)
        else
            group[#group + 1] = self:buildNumberPad(faces, w)
        end
        local qty
        if hidden then qty = "?"
        elseif land then qty = T(_("Dice: %1"), self.sel_q)
        else qty = T(_("Quantity: %1"), self.sel_q) end
        group[#group + 1] = self:buildNumberPad({
            { text = "−", enabled = not hidden, callback = function() self:onQuantity(-1) end },
            { text = qty, callback = function() end },
            { text = "+", enabled = not hidden, callback = function() self:onQuantity(1) end },
        }, w)
        group[#group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
        local bid = { text = hidden and _("Bid") or T(_("Bid %1 × %2"), self.sel_q, self.sel_f),
                      enabled = not hidden, callback = function() self:onBid() end }
        local calls = {}
        if b.bid then
            calls[#calls + 1] = { text = _("Liar!"), callback = function() self:onLiar() end }
            if b.exact then
                calls[#calls + 1] = { text = _("Exact!"), callback = function() self:onExact() end }
            end
        end
        -- The landscape column is narrow: the bid gets a row of its own so
        -- its label isn't squeezed onto two small lines.
        if self:isLandscape() and #calls > 0 then
            rows = { { bid }, calls }
        else
            rows = { bid }
            for _i, c in ipairs(calls) do rows[#rows + 1] = c end
        end
    elseif self.ui == "reveal" then
        rows = { { text = _("Next round"), callback = function() self:onNextRound() end } }
    else
        rows = {}
    end
    group[#group + 1] = self:buildActionBar(rows, w)
    return group
end

-- "4 × [die]" with the face drawn as a die.
function LiarsDiceScreen:_bidWidget(q, f, px, bold)
    local txt = TextWidget:new{ text = q .. " ×", face = pxFace(px, bold), bold = bold }
    local s = math.floor(px * 1.15)
    return HorizontalGroup:new{ align = "center", txt, hspan(px * 0.3), DiceRow:new{ values = { f }, size = s } }
end

-- One line per player: name, dice (hidden or shown), last bid this round.
function LiarsDiceScreen:_playerRows(w, px, show, mark)
    local b = self.board
    local last = {}
    for _i, h in ipairs(b.history or {}) do last[h.p] = h end
    local name_w = math.floor(w * 0.40)
    local bid_w  = show and 0 or math.floor(w * 0.22)
    local dice_w = w - name_w - bid_w
    local die = math.min(math.floor(px * (show and 1.7 or 1.3)), DiceRow.sizeFor(Board.START_DICE, dice_w - Size.padding.default))
    local g = VerticalGroup:new{ align = "left" }
    for i, p in ipairs(b.players) do
        local cur = b.phase == "bidding" and i == b.current
        local label = (cur and "▸ " or "") .. p.name
        local name = TextWidget:new{ text = label, face = pxFace(px, cur), bold = cur,
                                     max_width = name_w - 2 * Size.padding.large }
        local dice
        if p.count == 0 then
            dice = TextWidget:new{ text = _("out"), face = pxFace(px * 0.85) }
        elseif show then
            dice = DiceRow:new{ values = p.dice, size = die, mark = mark }
        else
            dice = DiceRow:new{ count = p.count, size = math.floor(die * 0.7) }
        end
        local rh = math.max(name:getSize().h, die)
        local row = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = name_w, h = rh }, name },
            LeftContainer:new{ dimen = Geom:new{ w = dice_w, h = rh }, dice },
        }
        if bid_w > 0 then
            local lb = last[i]
            local cell = lb and self:_bidWidget(lb.q, lb.f, px * 0.85)
                          or TextWidget:new{ text = "", face = pxFace(px) }
            row[#row + 1] = RightContainer:new{ dimen = Geom:new{ w = bid_w, h = rh }, cell }
        end
        g[#g + 1] = row
        g[#g + 1] = vspan(px * 0.35)
    end
    return g
end

-- The current bid, big, with who made it.
function LiarsDiceScreen:_currentBid(w, px)
    local b = self.board
    local g = VerticalGroup:new{ align = "center" }
    if not b.bid then
        g[#g + 1] = fitLine(_("No bid yet"), px * 0.7, w)
        return g
    end
    g[#g + 1] = fitLine(T(_("Current bid, by %1"), b.players[b.bid.by].name), px * 0.5, w)
    g[#g + 1] = vspan(px * 0.2)
    g[#g + 1] = self:_bidWidget(b.bid.q, b.bid.f, px, true)
    return g
end

function LiarsDiceScreen:_buildContent(bw, bh, k)
    local b = self.board
    local short = math.min(bw, bh, self.dimen.w)
    local vs = Size.span.vertical_large
    local g = VerticalGroup:new{ align = "center" }
    local function add(w) g[#g + 1] = w end
    local row_px = short * 0.05 * k

    if self.ui == "handover" then
        local who = b.players[b.current].name
        add(wrap(T(_("Pass the reader to %1"), who), short * 0.06 * k, bw))
        add(vspan(vs * 2 * k))
        add(fitLine(who, short * 0.13 * k, bw, true))
        add(vspan(vs * 2 * k))
        add(wrap(_("Tap Ready to look at your dice in secret."), short * 0.04 * k, bw))
        add(vspan(vs * 4 * k))
        add(self:_currentBid(bw, short * 0.09 * k))
        add(vspan(vs * 3 * k))
        add(self:_playerRows(bw, row_px, false))
    elseif self.ui == "turn" then
        local me = b.players[b.current]
        add(fitLine(T(_("%1, your dice"), me.name), short * 0.05 * k, bw, true))
        add(vspan(vs * k))
        local die = math.min(DiceRow.sizeFor(Board.START_DICE, bw), math.floor(short * 0.17 * k))
        local mine
        if self.dice_hidden then
            mine = VerticalGroup:new{ align = "center",
                DiceRow:new{ count = me.count, size = die },
                vspan(vs * 0.5),
                fitLine(_("Tap to show your dice"), short * 0.035 * k, bw) }
        else
            local f, wild = self.sel_f, b.wild
            mine = VerticalGroup:new{ align = "center",
                DiceRow:new{ values = me.dice, size = die,
                    mark = function(d) return d == f or (wild and f ~= 1 and d == 1) end },
                vspan(vs * 0.5),
                fitLine(_("Tap your dice to hide them"), short * 0.035 * k, bw) }
        end
        add(TapArea:new{ callback = function() self:onToggleDice() end, mine })
        add(vspan(vs * 3 * k))
        add(self:_currentBid(bw, short * 0.09 * k))
        add(vspan(vs * 3 * k))
        add(self:_playerRows(bw, row_px, false))
    elseif self.ui == "table" then
        add(self:_currentBid(bw, short * 0.11 * k))
        add(vspan(vs * 4 * k))
        add(self:_playerRows(bw, row_px * 1.1, false))
        add(vspan(vs * 2 * k))
        add(fitLine(T(_("%1 is thinking…"), b.players[b.current].name), short * 0.045 * k, bw))
    else
        local r = b.result
        if r then
            local f, wild = r.f, b.wild
            add(fitLine(self:_resultTitle(r), short * 0.06 * k, bw, true))
            add(vspan(vs * k))
            local line = HorizontalGroup:new{ align = "center",
                TextWidget:new{ text = _("Bid:") .. " ", face = pxFace(short * 0.05 * k) },
                self:_bidWidget(r.q, r.f, short * 0.05 * k, true),
                hspan(short * 0.05 * k),
                TextWidget:new{ text = T(_("Count: %1"), r.count), face = pxFace(short * 0.05 * k, true), bold = true },
            }
            add(line)
            add(vspan(vs * k))
            add(wrap(self:_resultText(r), short * 0.04 * k, bw))
            add(vspan(vs * 2 * k))
            add(self:_playerRows(bw, row_px, true,
                function(d) return d == f or (wild and f ~= 1 and d == 1) end))
        end
    end
    return g
end

function LiarsDiceScreen:_resultTitle(r)
    local caller = self.board.players[r.caller].name
    if r.kind == "exact" then return T(_("%1 calls Exact!"), caller) end
    return T(_("%1 calls Liar!"), caller)
end

function LiarsDiceScreen:_resultText(r)
    local b = self.board
    local s
    if r.kind == "liar" then
        local loser = b.players[r.loser].name
        if r.truth then
            s = T(_("The bid was true: %1 loses a die."), loser)
        else
            s = T(_("The bid was false: %1 loses a die."), loser)
        end
    elseif r.right then
        s = r.gainer and T(_("Exactly right: %1 wins a die back."), b.players[r.caller].name)
                     or T(_("Exactly right — but %1 already has 5 dice."), b.players[r.caller].name)
    else
        s = T(_("Not exact: %1 loses a die."), b.players[r.caller].name)
    end
    if r.loser and b.players[r.loser].count == 0 then
        s = s .. " " .. T(_("%1 is out."), b.players[r.loser].name)
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function LiarsDiceScreen:updateStatus(msg)
    if msg then ScreenBase.updateStatus(self, msg); return end
    local b = self.board
    local s
    if b.phase == "over" then
        local w = b:winner()
        s = w and T(_("%1 wins!"), b.players[w].name) or ""
    elseif self.ui == "reveal" then
        s = self:joinStatus(T(_("Round %1"), b.round), T(_("Dice in play: %1"), b:totalDice()))
    elseif self.ui == "turn" then
        s = self:joinStatus(self.last_msg, T(_("Dice in play: %1"), b:totalDice()))
    elseif self.ui == "table" then
        s = self:joinStatus(self.last_msg, T(_("Round %1"), b.round))
    else
        s = self:joinStatus(self.last_msg, T(_("Round %1"), b.round))
    end
    -- Keep "10 × 6" together when the status wraps.
    s = s and (s:gsub(" × ", "\194\160×\194\160")) or s
    ScreenBase.updateStatus(self, s)
end

return LiarsDiceScreen
