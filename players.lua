-- Player names: typed by the players, remembered in the plugin's settings.
-- (Vendored: estimation.koplugin carries the same file.)

local InputDialog = require("ui/widget/inputdialog")
local MenuHelper  = require("menu_helper")
local UIManager   = require("ui/uimanager")
local _           = require("i18n")
local T           = require("ffi/util").template

local Players = {}

local MAX_LEN = 16

function Players.defaultName(i)
    return T(_("Player %1"), i)
end

-- The first n names: the remembered ones, then "Player k" defaults.
function Players.load(plugin, n)
    local saved = plugin:getSetting("player_names", {}) or {}
    local out = {}
    for i = 1, n do
        local s = saved[i]
        out[i] = (type(s) == "string" and s ~= "") and s or Players.defaultName(i)
    end
    return out
end

-- Remember names[i] for seat i, keeping names typed for seats beyond #names.
function Players.save(plugin, names)
    local saved = plugin:getSetting("player_names", {}) or {}
    for i, s in ipairs(names) do saved[i] = s end
    plugin:saveSetting("player_names", saved)
end

local function clean(s)
    s = (s or ""):gsub("[\r\n\t]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    -- Cut on a character boundary, not in the middle of a UTF-8 sequence.
    local count, cut = 0, #s
    for pos in s:gmatch("()[^\128-\191]") do
        count = count + 1
        if count > MAX_LEN then cut = pos - 1; break end
    end
    return s:sub(1, cut)
end
Players.clean = clean

-- Rename one seat: an InputDialog prefilled with the current name.
function Players.rename(plugin, names, i, on_done)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Name of player %1"), i),
        input = names[i],
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                if on_done then on_done(false) end
            end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local s = clean(dialog:getInputText())
                UIManager:close(dialog)
                if s == "" then s = Players.defaultName(i) end
                names[i] = s
                Players.save(plugin, names)
                if on_done then on_done(true) end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- The list of seats; picking one renames it, then the list comes back.
-- `names` is edited in place; on_change() runs after every rename.
function Players.openEditor(plugin, names, on_change, parent)
    local items = {}
    for i, s in ipairs(names) do items[#items + 1] = { id = i, text = s } end
    MenuHelper.openPickerMenu{
        title     = _("Player names"),
        items     = items,
        parent    = parent,
        on_select = function(i)
            Players.rename(plugin, names, i, function(changed)
                if changed and on_change then on_change() end
                Players.openEditor(plugin, names, on_change, parent)
            end)
        end,
    }
end

return Players
