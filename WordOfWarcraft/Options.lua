-- Options: the list of settings (defaults, labels, tooltips), the options window, its page in the game's
-- Settings > AddOns panel, and /wow options, /wow set. Values live in WordOfWarcraftDB.options through
-- ns.opt / ns.setOpt (Core.lua); UI.lua applies the ones that change something on screen.

local _, ns = ...
local ui = ns.ui

local opt = { widgets = {} }

local function pct(v) return math.floor(v * 100 + 0.5) .. "%" end

-- Declarative list, drawn top to bottom in two columns. kind: "toggle", "choice" (choices = { {value, label} })
-- or "range" (min, max, step, fmt). needs = another toggle this one only matters with (dims the row when off).
local SPEC = {
    { section = "Appearance", col = 1 },
    { key = "colorblind", kind = "toggle", default = false, label = "Colourblind mode",
        desc = "High-contrast tiles: orange for the right spot, blue for the wrong spot." },
    { key = "scale", kind = "range", default = 1, min = 0.5, max = 1.5, step = 0.05, fmt = pct,
        label = "Window scale", desc = "Size of the game window." },
    { key = "opacity", kind = "range", default = 1, min = 0.2, max = 1, step = 0.1, fmt = pct,
        label = "Background opacity", desc = "How see-through the game window's background is." },
    { key = "revealSpeed", kind = "choice", default = "normal", label = "Tile reveal",
        desc = "How fast the tiles of a guess flip over.",
        choices = { { "off", "Instant" }, { "fast", "Fast" }, { "normal", "Normal" }, { "slow", "Slow" } } },
    { key = "lockWindow", kind = "toggle", default = false, label = "Lock window position",
        desc = "Stop the game window from being dragged by its title." },
    { key = "minimapButton", kind = "toggle", default = true, label = "Minimap button",
        desc = "Left-click to play, right-click for options, drag to move it around the minimap." },

    { section = "Keyboard", col = 1 },
    { key = "keyboardLayout", kind = "choice", default = "qwerty", label = "On-screen layout",
        desc = "Letter layout of the on-screen keyboard.",
        choices = { { "qwerty", "QWERTY" }, { "azerty", "AZERTY" }, { "qwertz", "QWERTZ" } } },
    { key = "swapEnter", kind = "toggle", default = false, label = "Swap Enter and Backspace",
        desc = "Put Backspace on the left of the bottom row and Enter on the right." },
    { key = "captureKeys", kind = "toggle", default = true, label = "Type as soon as it opens",
        desc = "The window takes the keyboard when it opens, including your movement keys. Off: click the "
            .. "window to type, and Esc hands the keyboard back." },
    { key = "typingHint", kind = "toggle", default = true, label = "Show typing hint",
        desc = "The reminder line under the keyboard while the game has the keyboard." },

    { section = "Gameplay", col = 2 },
    { key = "hardMode", kind = "toggle", default = false, label = "Hard mode",
        desc = "Hints you find must be used: green letters stay in place, yellow letters must be in every later "
            .. "guess. Starts with your next game; shared results get a *." },
    { key = "autoStats", kind = "toggle", default = true, label = "Show stats after the daily word",
        desc = "Open the stats panel when you finish today's word." },
    { key = "sounds", kind = "toggle", default = true, label = "Sound effects",
        desc = "Sounds for opening the window, wins, losses and rejected guesses." },
    { key = "keySounds", kind = "toggle", default = false, label = "Key click sounds", needs = "sounds",
        desc = "A soft click for every letter typed. Needs Sound effects." },

    { section = "Reminders", col = 2 },
    { key = "loginReminder", kind = "toggle", default = true, label = "Remind me at login",
        desc = "Say in chat when you log in and today's word is still waiting." },
    { key = "newWordReminder", kind = "toggle", default = true, label = "Announce each new word",
        desc = "Say in chat when a new word comes out (00:00 UTC) while you're logged in." },

    { section = "Sharing", col = 2 },
    { key = "postChannel", kind = "choice", default = "auto", label = "Post results to",
        desc = "Where \"Post to chat\" sends your result. Never /say.",
        choices = { { "auto", "Guild, else party" }, { "guild", "Guild" }, { "party", "Party" } } },
    { key = "autoPost", kind = "toggle", default = false, label = "Post the daily result for me",
        desc = "Post your result to chat as soon as you finish today's word." },
}

local byKey = {}
for _, s in ipairs(SPEC) do
    if s.key then
        ns.optionDefaults[s.key] = s.default
        byKey[s.key:lower()] = s
    end
end

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------

local function choiceIndex(s, value)
    for i, c in ipairs(s.choices) do if c[1] == value then return i end end
    return 1
end

-- Text shown for an option's current value.
function opt.valueText(s, v)
    if v == nil then v = ns.opt(s.key) end
    if s.kind == "toggle" then return v and "on" or "off" end
    if s.kind == "choice" then return s.choices[choiceIndex(s, v)][2] end
    return s.fmt and s.fmt(v) or tostring(v)
end

-- Steps a choice or range by dir (+1 / -1). Choices wrap around; ranges stop at their ends.
function opt.step(s, dir)
    local v = ns.opt(s.key)
    if s.kind == "toggle" then
        ns.setOpt(s.key, not v)
    elseif s.kind == "choice" then
        local i = (choiceIndex(s, v) - 1 + dir) % #s.choices + 1
        ns.setOpt(s.key, s.choices[i][1])
    else
        local n = math.floor(((v or s.default) + dir * s.step) / s.step + 0.5) * s.step
        n = math.max(s.min, math.min(s.max, n))
        ns.setOpt(s.key, tonumber(string.format("%.2f", n)))
    end
end

-- Parses typed text (/wow set) into a value for s. Returns value or nil, error.
function opt.parse(s, text)
    text = (text or ""):lower()
    if s.kind == "toggle" then
        if text == "" then return not ns.opt(s.key) end
        if text == "on" or text == "true" or text == "1" or text == "yes" then return true end
        if text == "off" or text == "false" or text == "0" or text == "no" then return false end
        return nil, "use on or off"
    elseif s.kind == "choice" then
        local names = {}
        for _, c in ipairs(s.choices) do
            if text == c[1] or text == c[2]:lower() then return c[1] end
            names[#names + 1] = c[1]
        end
        return nil, "use one of: " .. table.concat(names, ", ")
    end
    local n = tonumber((text:gsub("%%$", "")))
    if not n then return nil, "use a number from " .. s.min .. " to " .. s.max end
    if text:find("%%$") or n > s.max * 2 then n = n / 100 end   -- "80%" or "80" both mean 0.8 for percentages
    return math.max(s.min, math.min(s.max, n))
end

---------------------------------------------------------------------------
-- Widgets (plain frames and textures, no Blizzard templates: those may differ on Forever)
---------------------------------------------------------------------------

local FONT = ui.FONT
local COL_W, ROW_H, HEADER_H, COL_GAP = 250, 24, 24, 20
local CONTENT_W = 2 * COL_W + COL_GAP
local GOLD = { 1, 0.82, 0 }

local function fontString(parent, size, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size, flags or "")
    return fs
end

local function showTooltip(owner, title, text)
    if not GameTooltip then return end
    pcall(function()
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, GOLD[1], GOLD[2], GOLD[3])
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
end

local function hideTooltip()
    if GameTooltip then pcall(GameTooltip.Hide, GameTooltip) end
end

local function tooltipFor(frame, s)
    frame:SetScript("OnEnter", function(self) showTooltip(self, s.label, s.desc) end)
    frame:SetScript("OnLeave", hideTooltip)
end

-- A tiny "<" / ">" button.
local function arrowButton(parent, text, onClick)
    local b = ui.newFrame("Button", nil, parent)
    b:SetSize(18, 18)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints(b)
    b.bg:SetColorTexture(0.15, 0.13, 0.08, 0.9)
    b.label = fontString(b, 12, "OUTLINE")
    b.label:SetPoint("CENTER")
    b.label:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- Checkbox row: a box that fills gold when on, and the label. The whole row is clickable.
local function buildToggle(parent, s)
    local row = ui.newFrame("Button", nil, parent)
    row:SetSize(COL_W, ROW_H - 4)
    row.box = row:CreateTexture(nil, "BACKGROUND")
    row.box:SetSize(14, 14)
    row.box:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.box:SetColorTexture(0.35, 0.33, 0.28, 1)
    row.inner = row:CreateTexture(nil, "ARTWORK")
    row.inner:SetSize(10, 10)
    row.inner:SetPoint("CENTER", row.box, "CENTER", 0, 0)
    row.check = row:CreateTexture(nil, "OVERLAY")
    row.check:SetSize(8, 8)
    row.check:SetPoint("CENTER", row.box, "CENTER", 0, 0)
    row.check:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    row.inner:SetColorTexture(0.05, 0.05, 0.05, 1)
    row.label = fontString(row, 12)
    row.label:SetPoint("LEFT", row.box, "RIGHT", 8, 0)
    row.label:SetText(s.label)
    row:SetScript("OnClick", function() opt.step(s, 1) end)
    tooltipFor(row, s)
    function row.refresh()
        if ns.opt(s.key) then row.check:Show() else row.check:Hide() end
        local dim = s.needs and not ns.opt(s.needs)
        row.label:SetTextColor(dim and 0.5 or 1, dim and 0.5 or 1, dim and 0.5 or 1, 1)
    end
    return row
end

-- Stepper row: label on the left, "< value >" on the right. Clicking the value steps forward too.
local function buildStepper(parent, s)
    local row = ui.newFrame("Frame", nil, parent)
    row:SetSize(COL_W, ROW_H - 4)
    row:EnableMouse(true)
    row.label = fontString(row, 12)
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label:SetText(s.label)
    row.right = arrowButton(row, ">", function() opt.step(s, 1) end)
    row.right:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.value = ui.newFrame("Button", nil, row)
    row.value:SetSize(96, 18)
    row.value:SetPoint("RIGHT", row.right, "LEFT", -2, 0)
    row.value.bg = row.value:CreateTexture(nil, "BACKGROUND")
    row.value.bg:SetAllPoints(row.value)
    row.value.bg:SetColorTexture(0, 0, 0, 0.5)
    row.value.text = fontString(row.value, 11)
    row.value.text:SetPoint("CENTER")
    row.value.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 1)
    row.value:SetScript("OnClick", function() opt.step(s, 1) end)
    row.left = arrowButton(row, "<", function() opt.step(s, -1) end)
    row.left:SetPoint("RIGHT", row.value, "LEFT", -2, 0)
    tooltipFor(row, s)
    tooltipFor(row.value, s)
    function row.refresh() row.value.text:SetText(opt.valueText(s)) end
    return row
end

---------------------------------------------------------------------------
-- The content (every row and the action buttons). It lives in the options window, or in the game's Settings
-- panel while that page is open: opt.attach moves it between the two.
---------------------------------------------------------------------------

function opt.buildContent()
    local c = ui.newFrame("Frame", nil, UIParent)
    opt.content = c
    local y = { 0, 0 }            -- next free offset (negative) in each column
    local started = { false, false }
    local col = 1
    for _, s in ipairs(SPEC) do
        if s.section then
            col = s.col
            if started[col] then y[col] = y[col] - 10 end
            started[col] = true
            local h = fontString(c, 13, "OUTLINE")
            h:SetPoint("TOPLEFT", c, "TOPLEFT", (col - 1) * (COL_W + COL_GAP), y[col])
            h:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 1)
            h:SetText(s.section)
            local line = c:CreateTexture(nil, "ARTWORK")
            line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.25)
            line:SetSize(COL_W, 1)
            line:SetPoint("TOPLEFT", c, "TOPLEFT", (col - 1) * (COL_W + COL_GAP), y[col] - 17)
            y[col] = y[col] - HEADER_H
        else
            local w = (s.kind == "toggle") and buildToggle(c, s) or buildStepper(c, s)
            w:SetPoint("TOPLEFT", c, "TOPLEFT", (col - 1) * (COL_W + COL_GAP), y[col])
            y[col] = y[col] - ROW_H
            opt.widgets[s.key] = w
        end
    end

    local bottom = math.min(y[1], y[2]) - 14
    opt.resetPosBtn = ui.makeHeaderButton(c, "Reset window position", function() ui.resetPosition() end)
    opt.resetPosBtn:SetPoint("TOPLEFT", c, "TOPLEFT", 0, bottom)
    opt.resetStatsBtn = ui.makeHeaderButton(c, "Reset statistics", function() opt.confirmResetStats() end)
    opt.resetStatsBtn:SetPoint("LEFT", opt.resetPosBtn, "RIGHT", 8, 0)
    opt.defaultsBtn = ui.makeHeaderButton(c, "Restore defaults", function() opt.restoreDefaults() end)
    opt.defaultsBtn:SetPoint("LEFT", opt.resetStatsBtn, "RIGHT", 8, 0)
    c:SetSize(CONTENT_W, -bottom + 22)
    c:Hide()   -- shown by opt.attach once it has a home
    opt.refresh()
end

function opt.refresh()
    for _, w in pairs(opt.widgets) do w.refresh() end
end

-- Resetting stats wipes streaks, so it takes a second click within a few seconds.
function opt.confirmResetStats()
    local btn = opt.resetStatsBtn
    if btn.armed then
        btn.armed = nil
        ui.resetStats()
        ui.setButtonText(btn, "Reset statistics")
        ns.print("statistics reset for this character.")
        return
    end
    opt.armGen = (opt.armGen or 0) + 1
    local gen = opt.armGen
    btn.armed = true
    ui.setButtonText(btn, "|cffff5050Click again to reset|r")
    C_Timer.After(4, function()
        if btn.armed and opt.armGen == gen then
            btn.armed = nil
            ui.setButtonText(btn, "Reset statistics")
        end
    end)
end

function opt.restoreDefaults()
    for _, s in ipairs(SPEC) do
        if s.key and ns.opt(s.key) ~= s.default then ns.setOpt(s.key, s.default) end
    end
    ns.print("options restored to their defaults.")
end

function opt.attach(host, x, y)
    local c = opt.content
    c:SetParent(host)
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
    c:Show()
    opt.refresh()
end

---------------------------------------------------------------------------
-- The options window
---------------------------------------------------------------------------

local PAD = 22

function opt.buildDialog()
    local f = ui.newFrame("Frame", "WordOfWarcraftOptionsFrame", UIParent, "BackdropTemplate")
    f:SetSize(CONTENT_W + 2 * PAD, (opt.content:GetHeight() or 400) + 58 + PAD)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    pcall(f.SetMovable, f, true)
    pcall(f.SetClampedToScreen, f, true)
    pcall(f.RegisterForDrag, f, "LeftButton")
    f:SetScript("OnDragStart", function() pcall(f.StartMoving, f) end)
    f:SetScript("OnDragStop", function() pcall(f.StopMovingOrSizing, f) end)
    ui.styleAsPanel(f)
    table.insert(UISpecialFrames, "WordOfWarcraftOptionsFrame")

    f.title = fontString(f, 14, "OUTLINE")
    f.title:SetPoint("TOP", f, "TOP", 0, -18)
    f.title:SetText("Word of Warcraft Options")
    f.close = ui.newFrame("Button", nil, f)
    f.close:SetSize(20, 20)
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -14)
    f.close.label = fontString(f.close, 14, "OUTLINE")
    f.close.label:SetPoint("CENTER")
    f.close.label:SetText("X")
    f.close:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnShow", function() opt.attach(f, PAD, -48) end)
    f:SetScript("OnHide", hideTooltip)
    opt.dialog = f
end

function ns.toggleOptions()
    if opt.dialog:IsShown() then opt.dialog:Hide() else opt.dialog:Show() end
end

---------------------------------------------------------------------------
-- A page in the game's own options (Settings > AddOns, or Interface Options on older clients). Best effort:
-- if neither API exists, the gear button, minimap button and /wow options still work.
---------------------------------------------------------------------------

function opt.registerBlizzard()
    local canvas = ui.newFrame("Frame", nil, UIParent)
    canvas.name = "Word of Warcraft"   -- the legacy Interface Options panel reads the name from here
    canvas.title = fontString(canvas, 16, "OUTLINE")
    canvas.title:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, -16)
    canvas.title:SetText("Word of Warcraft")
    canvas.sub = fontString(canvas, 11)
    canvas.sub:SetPoint("TOPLEFT", canvas.title, "BOTTOMLEFT", 0, -6)
    canvas.sub:SetTextColor(0.8, 0.8, 0.8, 1)
    canvas.sub:SetText("A daily Azeroth word puzzle. Type /wow to play. Hover an option for details.")
    canvas:SetScript("OnShow", function()
        opt.dialog:Hide()
        opt.attach(canvas, 16, -64)
    end)

    if type(Settings) == "table" and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, canvas, "Word of Warcraft")
        if ok and cat then
            pcall(Settings.RegisterAddOnCategory, cat)
            opt.category = cat
            return "settings"
        end
        ns.log("options: Settings registration failed: " .. tostring(cat))
    end
    if type(InterfaceOptions_AddCategory) == "function" then
        pcall(InterfaceOptions_AddCategory, canvas)
        return "interface options"
    end
    return nil
end

---------------------------------------------------------------------------
-- Build, keep in sync, slash commands
---------------------------------------------------------------------------

opt.buildContent()
opt.buildDialog()
opt.dialog:Hide()
opt.blizzard = opt.registerBlizzard()

table.insert(ns.optionHooks, function() opt.refresh() end)
table.insert(ns.onLoaded, function() opt.refresh() end)

ns.commands.options = function() ns.toggleOptions() end
ns.commands.config = ns.commands.options
ns.commands.settings = ns.commands.options

-- /wow set lists every option; /wow set <option> <value> changes one (a bare toggle name flips it).
ns.commands.set = function(arg)
    local key, value = (arg or ""):match("^(%S*)%s*(.-)$")
    if not key or key == "" then
        ns.print("options (/wow set <option> <value>):")
        for _, s in ipairs(SPEC) do
            if s.key then
                local changed = ns.opt(s.key) ~= s.default and " |cffffd100*|r" or ""
                ns.print("  " .. s.key .. " = " .. opt.valueText(s) .. changed)
            end
        end
        return
    end
    local s = byKey[key:lower()]
    if not s then
        ns.print("no option called " .. key .. " - /wow set lists them")
        return
    end
    local v, err = opt.parse(s, value)
    if v == nil then
        ns.print(s.key .. ": " .. err)
        return
    end
    ns.setOpt(s.key, v)
    ns.print(s.label .. ": " .. opt.valueText(s))
end

table.insert(ns.help, "/wow options - open the options window")
table.insert(ns.help, "/wow set [option] [value] - list or change options from chat")

opt.SPEC = SPEC
ns._options = opt   -- for tools/test_ui.py
