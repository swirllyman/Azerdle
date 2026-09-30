-- Game window: WoW-styled frame, tile grid, on-screen keyboard, stats and help panels.
-- Builds on Game.lua (not modified here) and never touches the network; leaderboards will hook
-- ns.onGameFinished later. Everything lives on the `ui` table so this file stays well under the
-- 200-local-per-scope limit no matter how many widgets it creates.

local _, ns = ...

local ui = {}

---------------------------------------------------------------------------
-- Look and feel
---------------------------------------------------------------------------

local TILE_SIZE, TILE_GAP, TILE_BORDER = 42, 5, 3
local KEY_W, KEY_WIDE, KEY_H, KEY_GAP = 28, 44, 30, 4
-- The dialog border is ~12px wide, so content stays INSET px inside the frame edge.
local FRAME_W, INSET = 360, 16
local GRID_TOP = -84
local GRID_W = ns.WORD_LENGTH * TILE_SIZE + (ns.WORD_LENGTH - 1) * TILE_GAP
local GRID_H = ns.MAX_GUESSES * TILE_SIZE + (ns.MAX_GUESSES - 1) * TILE_GAP
local KB_W, KB_H = FRAME_W - 2 * INSET, 3 * KEY_H + 2 * KEY_GAP
local FRAME_H = -GRID_TOP + GRID_H + 12 + KB_H + 34
-- Seconds between each tile flipping on a submitted row, per the "revealSpeed" option.
local REVEAL_STAGGER = { off = 0, fast = 0.08, normal = 0.18, slow = 0.32 }
local FONT = "Fonts\\FRIZQT__.TTF"   -- FontStrings and EditBoxes error on SetText until they have a font

local COLOR_CORRECT, COLOR_PRESENT, COLOR_ABSENT = { 0.42, 0.67, 0.39 }, { 0.79, 0.71, 0.35 }, { 0.23, 0.23, 0.24 }
local COLOR_CORRECT_CB, COLOR_PRESENT_CB = { 0.96, 0.47, 0.24 }, { 0.52, 0.75, 0.98 }
local COLOR_EMPTY_FILL, COLOR_EMPTY_BORDER, COLOR_TYPED_BORDER = { 0.06, 0.06, 0.07 }, { 0.25, 0.25, 0.27 },
    { 0.55, 0.55, 0.6 }
local DEFAULT_KEY_COLOR, DEFAULT_BAR_COLOR = { 0.18, 0.18, 0.2 }, { 0.55, 0.5, 0.32 }

-- Item-quality flavoured praise for a win, keyed by guesses used. text .. hex colour code (no leading "cff").
local QUALITY = {
    { "Legendary!", "ff8000" }, { "Epic!", "a335ee" }, { "Rare!", "0070dd" },
    { "Uncommon!", "1eff00" }, { "Common", "ffffff" }, { "Phew... Poor quality", "9d9d9d" },
}

local HELP_LINES = {
    "Guess the 5-letter word in 6 tries.",
    "|cff6ea862Green|r: right letter, right spot.",
    "|cffcab559Yellow|r: right letter, wrong spot.",
    "|cff3a3a3dGrey|r: letter isn't in the word.",
    "Everyone gets the same word each day, new at 00:00 UTC.",
    "Practice games don't count toward your stats.",
}

-- On-screen keyboard layouts ("keyboardLayout" option). Row 3 starts with ENTER and ends with BACK; the
-- "swapEnter" option flips them.
local KEY_LAYOUTS = {
    qwerty = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" },
    azerty = { "AZERTYUIOP", "QSDFGHJKLM", "WXCVBN" },
    qwertz = { "QWERTZUIOP", "ASDFGHJKL", "YXCVBNM" },
}

-- Sound effects: SOUNDKIT name, then the id to use if the SOUNDKIT table is missing.
local SOUNDS = {
    open = { "IG_MAINMENU_OPEN", 850 }, close = { "IG_MAINMENU_CLOSE", 851 },
    key = { "U_CHAT_SCROLL_BUTTON", 1115 }, error = { "IG_MAINMENU_OPTION_CHECKBOX_OFF", 857 },
    win = { "IG_QUEST_LIST_COMPLETE", 878 }, lose = { "IG_QUEST_FAILED", 847 },
}

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

-- Tries CreateFrame with a template, falls back to a plain frame if the template doesn't exist on this
-- client (Forever may be missing some Blizzard templates). Never errors.
local function newFrame(kind, name, parent, template)
    if template then
        local ok, f = pcall(CreateFrame, kind, name, parent, template)
        if ok and f then return f end
    end
    local ok2, f2 = pcall(CreateFrame, kind, name, parent)
    if ok2 and f2 then return f2 end
    return CreateFrame(kind)
end

-- Best-effort WoW dialog look; falls back to a flat texture if BackdropTemplate/SetBackdrop aren't available.
local function styleAsPanel(f)
    local ok = pcall(f.SetBackdrop, f, {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    if not ok then
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints(f)
        f.bg:SetColorTexture(0.05, 0.04, 0.02, 0.96)
    end
end

local function colorFor(state)
    local cb = ns.opt("colorblind")
    if state == ns.CORRECT then return cb and COLOR_CORRECT_CB or COLOR_CORRECT end
    if state == ns.PRESENT then return cb and COLOR_PRESENT_CB or COLOR_PRESENT end
    return COLOR_ABSENT
end

local function fmtHMS(seconds)
    seconds = math.max(0, math.floor(seconds))
    local h, m, s = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

-- kind is a SOUNDS key. "key" (typing clicks) has its own option on top of the main sound switch.
function ui.playSound(kind)
    if not ns.opt("sounds") or (kind == "key" and not ns.opt("keySounds")) then return end
    local s = SOUNDS[kind]
    if not s or type(PlaySound) ~= "function" then return end
    local id = (type(SOUNDKIT) == "table") and SOUNDKIT[s[1]] or s[2]
    if id then pcall(PlaySound, id) end
end

---------------------------------------------------------------------------
-- Frame, header, grid, keyboard (built once at load; state is filled in by ns.onLoaded)
---------------------------------------------------------------------------

function ui.buildFrame()
    local f = newFrame("Frame", "AzerdleFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    pcall(f.SetMovable, f, true)
    pcall(f.SetClampedToScreen, f, true)
    f:EnableMouse(true)
    styleAsPanel(f)
    f:SetScript("OnMouseDown", function() ui.editBox:SetFocus() end)
    f:SetScript("OnHide", function()
        ui.statsPanel:Hide()
        ui.helpPanel:Hide()
        ui.editBox:ClearFocus()
        ui.savePosition()
        if ns.db then ui.playSound("close") end   -- not for the hide at load
    end)
    f:SetScript("OnShow", function()
        ui.checkRollover()
        if ns.opt("captureKeys") then ui.editBox:SetFocus() end
        ui.playSound("open")
    end)
    table.insert(UISpecialFrames, "AzerdleFrame")
    ui.frame = f

    -- Draggable title strip.
    local bar = newFrame("Frame", nil, f)
    bar:SetSize(FRAME_W - 70, 24)
    bar:SetPoint("TOP", f, "TOP", 0, -14)
    bar:EnableMouse(true)
    pcall(bar.RegisterForDrag, bar, "LeftButton")
    bar:SetScript("OnDragStart", function()
        if not ns.opt("lockWindow") then pcall(f.StartMoving, f) end
    end)
    bar:SetScript("OnDragStop", function() pcall(f.StopMovingOrSizing, f); ui.savePosition() end)
    ui.titleText = bar:CreateFontString(nil, "OVERLAY")
    ui.titleText:SetPoint("CENTER")
    ui.titleText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    ui.titleText:SetText("Azerdle")

    ui.closeBtn = newFrame("Button", nil, f)
    ui.closeBtn:SetSize(20, 20)
    ui.closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -14)
    ui.closeBtn.label = ui.closeBtn:CreateFontString(nil, "OVERLAY")
    ui.closeBtn.label:SetPoint("CENTER")
    ui.closeBtn.label:SetFont(FONT, 14, "OUTLINE")
    ui.closeBtn.label:SetText("X")
    ui.closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Gear in the top-left corner, mirroring the close button: opens the options window (Options.lua).
    ui.optionsBtn = newFrame("Button", nil, f)
    ui.optionsBtn:SetSize(18, 18)
    ui.optionsBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -15)
    ui.optionsBtn.icon = ui.optionsBtn:CreateTexture(nil, "ARTWORK")
    ui.optionsBtn.icon:SetAllPoints(ui.optionsBtn)
    ui.optionsBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
    ui.optionsBtn:SetScript("OnClick", function() if ns.toggleOptions then ns.toggleOptions() end end)

    ui.statsBtn = ui.makeHeaderButton(f, "Stats", function() ui.toggleStats() end)
    ui.helpBtn = ui.makeHeaderButton(f, "?", function() ui.toggleHelp() end)
    ui.practiceBtn = ui.makeHeaderButton(f, "Practice", function() ui.switchToPractice() end)
    ui.dailyBtn = ui.makeHeaderButton(f, "Back to Daily", function() ui.switchToDaily() end)
    ui.statsBtn:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, -40)
    ui.practiceBtn:SetPoint("LEFT", ui.statsBtn, "RIGHT", 4, 0)
    ui.dailyBtn:SetPoint("LEFT", ui.practiceBtn, "RIGHT", 4, 0)
    ui.helpBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -INSET, -40)

    ui.messageText = f:CreateFontString(nil, "OVERLAY")
    ui.messageText:SetPoint("TOP", f, "TOP", 0, -66)
    ui.messageText:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    ui.messageText:SetText("")

    ui.hintText = f:CreateFontString(nil, "OVERLAY")
    ui.hintText:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    ui.hintText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    ui.hintText:SetText("")
    ui.hintText:Hide()
end

-- The hint line under the keyboard, shown while the game has the keyboard (if the "typingHint" option allows).
function ui.updateHint()
    local focused = ui.editBox:HasFocus()
    if focused and ns.opt("typingHint") then
        ui.hintText:SetText(ns.opt("captureKeys") and "Typing captured - Esc to close"
            or "Typing captured - Esc to release the keyboard")
        ui.hintText:Show()
    else
        ui.hintText:Hide()
    end
end

-- Small text button; the caller positions it. Its width follows the label (see ui.setButtonText).
function ui.makeHeaderButton(parent, text, onClick)
    local btn = newFrame("Button", nil, parent)
    btn:SetSize(20, 20)
    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints(btn)
    btn.bg:SetColorTexture(0.15, 0.13, 0.08, 0.9)
    btn.label = btn:CreateFontString(nil, "OVERLAY")
    btn.label:SetPoint("CENTER")
    btn.label:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    ui.setButtonText(btn, text)
    btn:SetScript("OnClick", onClick)
    return btn
end

function ui.setButtonText(btn, text)
    btn.label:SetText(text)
    local ok, w = pcall(btn.label.GetStringWidth, btn.label)
    btn:SetWidth(math.max(20, ((ok and type(w) == "number") and w or #text * 7) + 14))
end

function ui.buildGrid()
    ui.tiles = {}
    local grid = newFrame("Frame", nil, ui.frame)
    grid:SetSize(GRID_W, GRID_H)
    grid:SetPoint("TOP", ui.frame, "TOP", 0, GRID_TOP)
    ui.grid = grid
    for row = 1, ns.MAX_GUESSES do
        ui.tiles[row] = {}
        for col = 1, ns.WORD_LENGTH do
            local tile = newFrame("Frame", nil, grid)
            tile:SetSize(TILE_SIZE, TILE_SIZE)
            tile:SetPoint("TOPLEFT", grid, "TOPLEFT", (col - 1) * (TILE_SIZE + TILE_GAP),
                -(row - 1) * (TILE_SIZE + TILE_GAP))
            tile.border = tile:CreateTexture(nil, "BACKGROUND")
            tile.border:SetAllPoints(tile)
            tile.fill = tile:CreateTexture(nil, "ARTWORK")
            tile.fill:SetPoint("TOPLEFT", tile, "TOPLEFT", TILE_BORDER, -TILE_BORDER)
            tile.fill:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -TILE_BORDER, TILE_BORDER)
            tile.text = tile:CreateFontString(nil, "OVERLAY")
            tile.text:SetPoint("CENTER")
            tile.text:SetFont("Fonts\\FRIZQT__.TTF", 26, "OUTLINE")
            ui.setTileEmpty(tile)
            ui.tiles[row][col] = tile
        end
    end
end

-- The rows of labels for a layout, e.g. { {"Q", ...}, {"A", ...}, {"ENTER", "Z", ..., "BACK"} }.
local function keyRows(layout, swapEnter)
    local src = KEY_LAYOUTS[layout] or KEY_LAYOUTS.qwerty
    local rows = {}
    for r, letters in ipairs(src) do
        local row = {}
        for i = 1, #letters do row[i] = letters:sub(i, i) end
        rows[r] = row
    end
    local first, last = "ENTER", "BACK"
    if swapEnter then first, last = "BACK", "ENTER" end
    table.insert(rows[3], 1, first)
    table.insert(rows[3], last)
    return rows
end

-- One keyboard frame per layout/swap combination, built on first use and kept; only the active one is shown.
-- ui.keyButtons always points at the active keyboard's letter keys.
function ui.applyKeyboardLayout()
    local layout, swap = ns.opt("keyboardLayout") or "qwerty", ns.opt("swapEnter") and true or false
    local id = layout .. (swap and "-swap" or "")
    ui.keyboards = ui.keyboards or {}
    if not ui.keyboards[id] then ui.keyboards[id] = ui.buildKeyboard(keyRows(layout, swap)) end
    for otherId, kb in pairs(ui.keyboards) do
        if otherId ~= id then kb.frame:Hide() end
    end
    ui.keyboards[id].frame:Show()
    ui.keyButtons = ui.keyboards[id].buttons
    ui.resetKeyboardColors()
    if ui.dailyGame then ui.updateKeyboard(ui.activeGame()) end
end

function ui.buildKeyboard(rows)
    local buttons = {}
    local kb = newFrame("Frame", nil, ui.frame)
    kb:SetPoint("TOP", ui.grid, "BOTTOM", 0, -12)
    kb:SetSize(KB_W, KB_H)
    for r, row in ipairs(rows) do
        local rowWidth = -KEY_GAP
        for _, label in ipairs(row) do rowWidth = rowWidth + (#label > 1 and KEY_WIDE or KEY_W) + KEY_GAP end
        local prevBtn
        for _, label in ipairs(row) do
            local wide = #label > 1
            local btn = newFrame("Button", nil, kb)
            btn:SetSize(wide and KEY_WIDE or KEY_W, KEY_H)
            btn.bg = btn:CreateTexture(nil, "BACKGROUND")
            btn.bg:SetAllPoints(btn)
            btn.bg:SetColorTexture(DEFAULT_KEY_COLOR[1], DEFAULT_KEY_COLOR[2], DEFAULT_KEY_COLOR[3], 1)
            btn.label = btn:CreateFontString(nil, "OVERLAY")
            btn.label:SetPoint("CENTER")
            btn.label:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
            btn.label:SetText(label)
            if prevBtn then
                btn:SetPoint("LEFT", prevBtn, "RIGHT", KEY_GAP, 0)
            else
                btn:SetPoint("TOPLEFT", kb, "TOPLEFT", (KB_W - rowWidth) / 2, -(r - 1) * (KEY_H + KEY_GAP))
            end
            btn:SetScript("OnClick", function()
                if label == "ENTER" then ui.submitCurrent()
                elseif label == "BACK" then ui.backspace()
                else ui.typeLetter(label) end
            end)
            if #label == 1 then buttons[label] = btn end
            prevBtn = btn
        end
    end
    return { frame = kb, buttons = buttons }
end

-- Invisible capture box: the real source of keyboard input, focused whenever the window is open or clicked.
function ui.buildEditBox()
    local eb = newFrame("EditBox", nil, ui.frame)
    eb:SetSize(2, 2)
    eb:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 0, 0)
    eb:SetAutoFocus(false)
    eb:SetFont(FONT, 12, "")
    pcall(eb.SetMultiLine, eb, false)
    eb:SetAlpha(0)
    eb:SetScript("OnChar", function(self, c)
        local up = (type(c) == "string") and c:upper() or ""
        if up:match("^[A-Z]$") then ui.typeLetter(up) end
        self:SetText("")
    end)
    eb:SetScript("OnKeyDown", function(_, key) if key == "BACKSPACE" then ui.backspace() end end)
    eb:SetScript("OnEnterPressed", function() ui.submitCurrent() end)
    -- Without auto-capture, Esc first hands the keyboard back; a second Esc closes the window (UISpecialFrames).
    eb:SetScript("OnEscapePressed", function(self)
        if ns.opt("captureKeys") then ui.frame:Hide() else self:ClearFocus() end
    end)
    eb:SetScript("OnEditFocusGained", function() ui.updateHint() end)
    eb:SetScript("OnEditFocusLost", function() ui.updateHint() end)
    ui.editBox = eb
end

---------------------------------------------------------------------------
-- Game state and drawing
---------------------------------------------------------------------------

function ui.activeGame()
    return (ui.mode == "practice") and ui.practiceGame or ui.dailyGame
end

function ui.setTileEmpty(tile)
    tile.fill:SetColorTexture(COLOR_EMPTY_FILL[1], COLOR_EMPTY_FILL[2], COLOR_EMPTY_FILL[3], 1)
    tile.border:SetColorTexture(COLOR_EMPTY_BORDER[1], COLOR_EMPTY_BORDER[2], COLOR_EMPTY_BORDER[3], 1)
    tile.text:SetText("")
end

function ui.setTileTyped(tile, letter)
    tile.fill:SetColorTexture(COLOR_EMPTY_FILL[1], COLOR_EMPTY_FILL[2], COLOR_EMPTY_FILL[3], 1)
    tile.border:SetColorTexture(COLOR_TYPED_BORDER[1], COLOR_TYPED_BORDER[2], COLOR_TYPED_BORDER[3], 1)
    tile.text:SetText(letter)
end

function ui.setTileResult(tile, letter, state)
    local c = colorFor(state)
    tile.fill:SetColorTexture(c[1], c[2], c[3], 1)
    tile.border:SetColorTexture(c[1], c[2], c[3], 1)
    tile.text:SetText(letter)
    tile.text:SetTextColor(1, 1, 1, 1)
end

function ui.refreshCurrentRowTiles()
    local rowN = #ui.activeGame().guesses + 1
    if rowN > ns.MAX_GUESSES then return end
    for col = 1, ns.WORD_LENGTH do
        local letter = ui.curText:sub(col, col)
        if letter == "" then ui.setTileEmpty(ui.tiles[rowN][col]) else ui.setTileTyped(ui.tiles[rowN][col], letter) end
    end
end

function ui.resetKeyboardColors()
    for _, btn in pairs(ui.keyButtons) do
        btn.bg:SetColorTexture(DEFAULT_KEY_COLOR[1], DEFAULT_KEY_COLOR[2], DEFAULT_KEY_COLOR[3], 1)
    end
end

-- Keys never downgrade: ns.letterStates already keeps the best (highest) state seen per letter.
function ui.updateKeyboard(game)
    local states = ns.letterStates(game)
    for letter, btn in pairs(ui.keyButtons) do
        local st = states[letter]
        if st ~= nil then
            local c = colorFor(st)
            btn.bg:SetColorTexture(c[1], c[2], c[3], 1)
        end
    end
end

function ui.showFinishMessage(game)
    if not game.done then
        ui.messageText:SetText("")
        return
    end
    if game.won then
        local q = QUALITY[#game.guesses] or QUALITY[6]
        ui.messageText:SetText("|cff" .. q[2] .. q[1] .. "|r")
    else
        ui.messageText:SetText("The word was " .. game.answer)
    end
end

function ui.showToast(text)
    ui.messageText:SetText(text)
end

-- Redraws every tile and the keyboard from scratch (restore, mode switch, colorblind toggle). No animation.
function ui.paintFullGame()
    ui.paintGen = (ui.paintGen or 0) + 1
    local game = ui.activeGame()
    for r = 1, ns.MAX_GUESSES do
        for c = 1, ns.WORD_LENGTH do
            local tile = ui.tiles[r][c]
            if game.guesses[r] then
                ui.setTileResult(tile, game.guesses[r]:sub(c, c), game.results[r][c])
            else
                ui.setTileEmpty(tile)
            end
        end
    end
    ui.curText = ""
    ui.resetKeyboardColors()
    ui.updateKeyboard(game)
    ui.updateTitle()
    ui.updateHeaderButtons()
    ui.showFinishMessage(game)
end

-- True if the active game is (or, not started yet, will be) played in hard mode.
function ui.isHard(game)
    game = game or ui.activeGame()
    if #game.guesses == 0 and not game.done then return ns.opt("hardMode") and true or false end
    return game.hard and true or false
end

function ui.updateTitle()
    local hard = ui.isHard() and " |cffff5050(Hard)|r" or ""
    if ui.mode == "daily" then
        ui.titleText:SetText("Azerdle #" .. ui.dailyGame.puzzle .. hard)
    else
        ui.titleText:SetText("Azerdle - Practice" .. hard)
    end
end

-- Hard mode starts with a game's first guess and can't be switched on mid-game, like Wordle; switching it off
-- takes effect at once (and drops the * from the share text).
function ui.onHardModeChanged(on)
    local game = ui.activeGame()
    if not on then
        for _, g in ipairs({ ui.dailyGame, ui.practiceGame }) do
            if g and not g.done then g.hard = nil end
        end
        if ui.dailyGame and not ui.dailyGame.done then ns.cdb.daily = ns.saveDaily(ui.dailyGame) end
    elseif #game.guesses > 0 and not game.done then
        ui.showToast("Hard mode starts with your next game")
    end
    ui.updateTitle()
end

function ui.updateHeaderButtons()
    if ui.mode == "daily" then
        ui.setButtonText(ui.practiceBtn, "Practice")
        ui.dailyBtn:Hide()
    else
        ui.setButtonText(ui.practiceBtn, "New practice word")
        ui.dailyBtn:Show()
    end
end

---------------------------------------------------------------------------
-- Typing and submitting
---------------------------------------------------------------------------

function ui.typeLetter(letter)
    local game = ui.activeGame()
    if game.done or #ui.curText >= ns.WORD_LENGTH then return end
    ui.curText = ui.curText .. letter
    ui.refreshCurrentRowTiles()
    ui.playSound("key")
end

function ui.backspace()
    if #ui.curText > 0 then
        ui.curText = ui.curText:sub(1, #ui.curText - 1)
        ui.playSound("key")
    end
    ui.refreshCurrentRowTiles()
end

-- Runs after the last tile of a submitted row finishes revealing: colour the keyboard, show the win/loss
-- message, and (for a finished daily game) pop the stats panel after a short pause.
function ui.onRowRevealed(game)
    ui.updateKeyboard(game)
    ui.showFinishMessage(game)
    if game.done then ui.playSound(game.won and "win" or "lose") end
    if game.done and game.mode == "daily" then
        if ns.opt("autoPost") then ui.postToChat(true) end
        if ns.opt("autoStats") then C_Timer.After(1.5, function() ui.openStats() end) end
    end
end

-- ui.paintGen changes whenever the whole board is repainted (mode switch, new day, colourblind toggle), so a
-- reveal still in flight from the previous board stops instead of painting over the new one.
function ui.revealRow(rowN, guess, result, game)
    local n = ns.WORD_LENGTH
    local gen = ui.paintGen
    local stagger = REVEAL_STAGGER[ns.opt("revealSpeed")] or REVEAL_STAGGER.normal
    if stagger == 0 then
        for i = 1, n do ui.setTileResult(ui.tiles[rowN][i], guess:sub(i, i), result[i]) end
        ui.onRowRevealed(game)
        return
    end
    for i = 1, n do
        C_Timer.After((i - 1) * stagger, function()
            if ui.paintGen ~= gen or ui.activeGame() ~= game then return end
            ui.setTileResult(ui.tiles[rowN][i], guess:sub(i, i), result[i])
            if i == n then ui.onRowRevealed(game) end
        end)
    end
end

function ui.submitCurrent()
    local game = ui.activeGame()
    if game.done then return end
    if #ui.curText < ns.WORD_LENGTH then
        ui.showToast("Not enough letters")
        ui.playSound("error")
        return
    end
    -- Hard mode is fixed for the whole game when its first guess goes in.
    if #game.guesses == 0 then game.hard = ns.opt("hardMode") and true or nil end
    local ok, resultOrReason, message = ns.submitGuess(game, ui.curText)
    if not ok then
        if resultOrReason == "invalid" then ui.showToast("Not in word list") end
        if resultOrReason == "hard" then ui.showToast(message) end
        ui.playSound("error")
        return
    end
    ui.curText = ""
    if game.mode == "daily" then ns.cdb.daily = ns.saveDaily(game) end
    local rowN = #game.guesses
    ui.revealRow(rowN, game.guesses[rowN], game.results[rowN], game)
    ui.updateTitle()
end

---------------------------------------------------------------------------
-- Mode switching, rollover, position
---------------------------------------------------------------------------

function ui.switchToPractice()
    ui.mode = "practice"
    ui.practiceGame = ns.newGame("practice")
    ui.paintFullGame()
end

function ui.switchToDaily()
    ui.mode = "daily"
    ui.paintFullGame()
end

-- Loads a fresh daily game if UTC midnight passed since the current one was created.
function ui.checkRollover()
    if not ui.dailyGame then return end
    if ui.dailyGame.puzzle ~= ns.todayPuzzle() then
        ui.dailyGame = ns.newGame("daily")
        ns.cdb.daily = ns.saveDaily(ui.dailyGame)
        if ui.mode == "daily" then ui.paintFullGame() end
    end
end

-- Also runs from OnHide when the file hides the new window at load, before saved variables exist.
function ui.savePosition()
    if not ns.db then return end
    local ok, point, _, relPoint, x, y = pcall(ui.frame.GetPoint, ui.frame)
    if ok and point then ns.db.framePos = { point = point, relPoint = relPoint, x = x, y = y } end
end

function ui.restorePosition()
    local p = ns.db and ns.db.framePos
    if not (p and p.point) then return end
    ui.frame:ClearAllPoints()
    local ok = pcall(ui.frame.SetPoint, ui.frame, p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
    if not ok then ui.frame:SetPoint("CENTER") end
end

function ui.resetPosition()
    if ns.db then ns.db.framePos = nil end
    ui.frame:ClearAllPoints()
    ui.frame:SetPoint("CENTER")
end

function ui.applyScale()
    pcall(ui.frame.SetScale, ui.frame, ns.opt("scale") or 1)
end

-- Window background opacity; overlays (stats, help) stay opaque so they remain readable.
function ui.applyOpacity()
    local a = ns.opt("opacity") or 1
    local f = ui.frame
    if f.bg then
        f.bg:SetColorTexture(0.05, 0.04, 0.02, 0.96 * a)
    else
        pcall(f.SetBackdropColor, f, 1, 1, 1, a)
    end
end

function ui.toggle()
    if ui.frame:IsShown() then ui.frame:Hide() else ui.frame:Show() end
end

---------------------------------------------------------------------------
-- Stats panel
---------------------------------------------------------------------------

-- Overlays cover the grid and keyboard inside the window border: opaque (the dialog background texture is
-- translucent), raised above the tiles, and swallowing clicks so keys underneath can't be pressed.
function ui.raiseOverlay(p)
    p:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", INSET - 4, -62)
    p:SetPoint("BOTTOMRIGHT", ui.frame, "BOTTOMRIGHT", -(INSET - 4), INSET - 4)
    pcall(p.SetFrameLevel, p, (ui.frame:GetFrameLevel() or 1) + 20)
    p:EnableMouse(true)
    p.solid = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    p.solid:SetAllPoints(p)
    p.solid:SetColorTexture(0.04, 0.035, 0.03, 0.97)
end

function ui.buildStatsPanel()
    local p = newFrame("Frame", nil, ui.frame, "BackdropTemplate")
    ui.raiseOverlay(p)
    p:Hide()
    ui.statsPanel = p

    local function line(dy)
        local fs = p:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("TOPLEFT", p, "TOPLEFT", 14, dy)
        fs:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
        return fs
    end
    ui.playedText = line(-14)
    ui.winPctText = line(-32)
    ui.streakText = line(-50)
    ui.maxStreakText = line(-68)

    ui.bars = {}
    for i = 1, 6 do
        local row = newFrame("Frame", nil, p)
        row:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -92 - (i - 1) * 18)
        row:SetSize(260, 16)
        local label = row:CreateFontString(nil, "OVERLAY")
        label:SetPoint("LEFT", row, "LEFT", 0, 0)
        label:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        label:SetText(tostring(i))
        local tex = row:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("LEFT", label, "RIGHT", 4, 0)
        tex:SetHeight(14)
        tex:SetColorTexture(DEFAULT_BAR_COLOR[1], DEFAULT_BAR_COLOR[2], DEFAULT_BAR_COLOR[3], 1)
        local countText = row:CreateFontString(nil, "OVERLAY")
        countText:SetPoint("LEFT", tex, "RIGHT", 4, 0)
        countText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        ui.bars[i] = { tex = tex, countText = countText }
    end

    ui.countdownText = line(-92 - 6 * 18 - 10)

    ui.copyBtn = ui.makeHeaderButton(p, "Copy result", function() ui.showShareBox("emoji") end)
    ui.copyBtn:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 14, 14)
    ui.postBtn = ui.makeHeaderButton(p, "Post to chat", function() ui.postToChat() end)
    ui.postBtn:SetPoint("LEFT", ui.copyBtn, "RIGHT", 8, 0)

    ui.shareBox = newFrame("EditBox", nil, p)
    ui.shareBox:SetSize(260, 60)
    ui.shareBox:SetPoint("BOTTOM", ui.copyBtn, "TOP", 0, 24)
    pcall(ui.shareBox.SetMultiLine, ui.shareBox, true)
    ui.shareBox:SetFont(FONT, 12, "")
    ui.shareBox:SetAutoFocus(false)
    ui.shareBox.bg = ui.shareBox:CreateTexture(nil, "BACKGROUND")
    ui.shareBox.bg:SetAllPoints(ui.shareBox)
    ui.shareBox.bg:SetColorTexture(0, 0, 0, 0.6)
    -- Read-only: typing restores the text; Esc hands the keyboard back to the game.
    ui.shareBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self.shareText then
            self:SetText(self.shareText)
            self:HighlightText()
        end
    end)
    ui.shareBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:Hide()
        ui.shareLabel:Hide()
        ui.editBox:SetFocus()
    end)
    ui.shareBox:Hide()
    ui.shareLabel = p:CreateFontString(nil, "OVERLAY")
    ui.shareLabel:SetPoint("BOTTOM", ui.shareBox, "TOP", 0, 2)
    ui.shareLabel:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    ui.shareLabel:Hide()

    p:SetScript("OnShow", function()
        ui.refreshStats()
        ui.countdownTicker = C_Timer.NewTicker(1, ui.updateCountdown)
        ui.updateCountdown()
    end)
    p:SetScript("OnHide", function()
        if ui.countdownTicker then ui.countdownTicker:Cancel(); ui.countdownTicker = nil end
    end)
end

function ui.updateCountdown()
    ui.countdownText:SetText("Next word in " .. fmtHMS(ns.secondsUntilNextPuzzle()))
end

function ui.refreshStats()
    local stats = ns.cdb.stats
    ui.playedText:SetText("Played: " .. stats.played)
    ui.winPctText:SetText("Win %: " .. ns.winPercent(stats))
    ui.streakText:SetText("Current streak: " .. ns.currentStreak(stats))
    ui.maxStreakText:SetText("Max streak: " .. stats.maxStreak)

    local maxD = 1
    for i = 1, 6 do if (stats.dist[i] or 0) > maxD then maxD = stats.dist[i] end end
    local game = ui.dailyGame
    local winRow = (game and game.mode == "daily" and game.done and game.won) and #game.guesses or nil
    for i = 1, 6 do
        local n = stats.dist[i] or 0
        local w = math.max(2, 200 * n / maxD)
        ui.bars[i].tex:SetWidth(w)
        ui.bars[i].countText:SetText(tostring(n))
        local c = (i == winRow) and colorFor(ns.CORRECT) or DEFAULT_BAR_COLOR
        ui.bars[i].tex:SetColorTexture(c[1], c[2], c[3], 1)
    end

    local done = game and game.mode == "daily" and game.done
    if done then ui.copyBtn:Show(); ui.postBtn:Show() else ui.copyBtn:Hide(); ui.postBtn:Hide() end
    ui.shareBox:Hide()
    ui.shareLabel:Hide()
end

function ui.showShareBox(style)
    if not ui.dailyGame then return end
    ui.shareBox.shareText = ns.shareText(ui.dailyGame, style)
    ui.shareBox:SetText(ui.shareBox.shareText)
    ui.shareBox:Show()
    ui.shareLabel:SetText("Ctrl+C to copy, Esc when done")
    ui.shareLabel:Show()
    pcall(ui.shareBox.SetFocus, ui.shareBox)
    pcall(ui.shareBox.HighlightText, ui.shareBox)
end

-- Where "Post to chat" goes, per the "postChannel" option. Never SAY. "auto": GUILD if we're in a guild, else
-- PARTY if grouped. Returns nil if there's nowhere to post.
function ui.postChannel()
    local inGuild = type(IsInGuild) == "function" and IsInGuild()
    local inGroup = type(IsInGroup) == "function" and IsInGroup()
    local pref = ns.opt("postChannel")
    if pref == "guild" then return inGuild and "GUILD" or nil end
    if pref == "party" then return inGroup and "PARTY" or nil end
    if inGuild then return "GUILD" end
    if inGroup then return "PARTY" end
end

-- quiet=true (auto-post) doesn't complain when there's nowhere to post.
function ui.postToChat(quiet)
    if not ui.dailyGame then return end
    local channel = ui.postChannel()
    if not channel then
        if not quiet then
            local where = ({ guild = "guild", party = "group" })[ns.opt("postChannel")] or "guild or group"
            ns.print("No " .. where .. " to post your result to.")
        end
        return
    end
    -- Newer clients moved it to C_ChatInfo; keep the global as a fallback.
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    local ok, err = pcall(send, ns.shareText(ui.dailyGame, "chat"), channel)
    if not ok then ns.log("post to chat: ERROR " .. tostring(err), true) end
end

function ui.toggleStats()
    if ui.statsPanel:IsShown() then ui.statsPanel:Hide() else ui.helpPanel:Hide(); ui.statsPanel:Show() end
end

function ui.openStats()
    ui.helpPanel:Hide()
    ui.statsPanel:Show()
end

---------------------------------------------------------------------------
-- Help panel
---------------------------------------------------------------------------

function ui.buildHelpPanel()
    local p = newFrame("Frame", nil, ui.frame, "BackdropTemplate")
    ui.raiseOverlay(p)
    p:Hide()
    ui.helpPanel = p
    local prev
    for _, text in ipairs(HELP_LINES) do
        local fs = p:CreateFontString(nil, "OVERLAY")
        if prev then
            fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -8)
        else
            fs:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -14)
        end
        fs:SetWidth(FRAME_W - 2 * INSET - 20)   -- wraps instead of running past the border
        fs:SetJustifyH("LEFT")
        fs:SetFont(FONT, 12, "")
        fs:SetText(text)
        prev = fs
    end
end

function ui.toggleHelp()
    if ui.helpPanel:IsShown() then ui.helpPanel:Hide() else ui.statsPanel:Hide(); ui.helpPanel:Show() end
end

---------------------------------------------------------------------------
-- Build the widgets now; fill in state once saved variables exist.
---------------------------------------------------------------------------

ui.buildFrame()
ui.buildGrid()
ui.buildEditBox()
ui.applyKeyboardLayout()
ui.buildStatsPanel()
ui.buildHelpPanel()
ui.frame:Hide()
ui.curText = ""
ui.mode = "daily"

-- Records a finished daily game into stats. Practice games never touch stats or get saved.
table.insert(ns.onGameFinished, function(game)
    if not ns.cdb or game.mode ~= "daily" then return end
    ns.recordResult(ns.cdb.stats, game)
    ns.cdb.daily = ns.saveDaily(game)
end)

table.insert(ns.onLoaded, function()
    ns.cdb.stats = ns.cdb.stats or ns.newStats()
    local defaults = ns.newStats()
    for k, v in pairs(defaults) do
        if ns.cdb.stats[k] == nil then ns.cdb.stats[k] = v end
    end
    if type(ns.cdb.stats.dist) ~= "table" then ns.cdb.stats.dist = { 0, 0, 0, 0, 0, 0 } end

    ui.dailyGame = ns.restoreDaily(ns.cdb.daily)
    ui.mode = "daily"
    ui.restorePosition()
    ui.applyScale()
    ui.applyOpacity()
    ui.applyKeyboardLayout()
    ui.paintFullGame()
end)

-- Stats reset from the options window: today's game stays, the history goes.
function ui.resetStats()
    ns.cdb.stats = ns.newStats()
    if ui.statsPanel:IsShown() then ui.refreshStats() end
end

---------------------------------------------------------------------------
-- Options that change something already on screen (Options.lua declares them and draws the panel).
---------------------------------------------------------------------------

local OPTION_APPLY = {
    colorblind = function()
        ui.paintFullGame()
        if ui.statsPanel:IsShown() then ui.refreshStats() end
    end,
    scale = function() ui.applyScale() end,
    opacity = function() ui.applyOpacity() end,
    keyboardLayout = function() ui.applyKeyboardLayout() end,
    swapEnter = function() ui.applyKeyboardLayout() end,
    hardMode = function(v) ui.onHardModeChanged(v) end,
    typingHint = function() ui.updateHint() end,
    captureKeys = function(v)
        if v and ui.frame:IsShown() then ui.editBox:SetFocus() end
        ui.updateHint()
    end,
}
table.insert(ns.optionHooks, function(key, value)
    if OPTION_APPLY[key] and ui.dailyGame then OPTION_APPLY[key](value) end
end)

---------------------------------------------------------------------------
-- Reminders: once per login "today's word is ready" a few seconds after entering the world, and (while logged
-- in) "a new word is out" right after 00:00 UTC.
---------------------------------------------------------------------------

local announcedThisLogin = false
ns.on("PLAYER_ENTERING_WORLD", function()
    if announcedThisLogin then return end
    announcedThisLogin = true
    C_Timer.After(3, function()
        if not ns.cdb or not ns.opt("loginReminder") then return end
        local today = ns.todayPuzzle()
        if ns.cdb.lastAnnounced == today then return end
        ns.cdb.lastAnnounced = today
        local game = ui.dailyGame or ns.restoreDaily(ns.cdb.daily)
        if not game.done then
            ns.print("Azerdle #" .. today .. " is ready - type /azerdle to play.")
        end
    end)
end)

-- Timers and the server clock can drift apart, so it only announces once the puzzle number has really moved on
-- (otherwise it just waits for the next midnight again).
function ui.scheduleNewWordNotice()
    local puzzle = ns.todayPuzzle()
    C_Timer.After(ns.secondsUntilNextPuzzle() + 2, function()
        local today = ns.todayPuzzle()
        if today > puzzle then ui.checkRollover() end
        if today > puzzle and ns.cdb and ns.opt("newWordReminder") then
            ns.cdb.lastAnnounced = today
            ns.print("A new word is out: Azerdle #" .. today .. " - type /azerdle to play.")
        end
        ui.scheduleNewWordNotice()
    end)
end
ui.scheduleNewWordNotice()

---------------------------------------------------------------------------
-- Slash commands and the addon compartment entry point
---------------------------------------------------------------------------

ns.commands[""] = function() ui.toggle() end
ns.commands.practice = function()
    ui.switchToPractice()
    ui.frame:Show()
end
ns.commands.stats = function()
    ui.frame:Show()
    ui.openStats()
end
ns.commands.scale = function(arg)
    local v = tonumber(arg)
    if not v then
        ns.print("window scale: " .. ns.opt("scale") .. " (/azerdle scale 0.5 - 1.5)")
        return
    end
    ns.setOpt("scale", math.max(0.5, math.min(1.5, v)))
    ns.print("window scale set to " .. ns.opt("scale"))
end
ns.commands.colorblind = function()
    ns.setOpt("colorblind", not ns.opt("colorblind"))
    ns.print("colorblind mode: " .. tostring(ns.opt("colorblind")))
end
ns.commands.hard = function()
    ns.setOpt("hardMode", not ns.opt("hardMode"))
    ns.print("hard mode: " .. tostring(ns.opt("hardMode")))
end
table.insert(ns.help, "/azerdle (or /azd) - open or close the game window")
table.insert(ns.help, "/azerdle practice - start a practice word (doesn't count toward stats)")
table.insert(ns.help, "/azerdle stats - open the stats panel")
table.insert(ns.help, "/azerdle scale <0.5-1.5> - resize the game window")
table.insert(ns.help, "/azerdle colorblind - toggle colourblind-friendly tile colours")
table.insert(ns.help, "/azerdle hard - toggle hard mode (hints you find must be used)")

-- Left-click toggles the game; right-click opens the options.
function Azerdle_OnCompartmentClick(_, button)
    if button == "RightButton" and ns.toggleOptions then ns.toggleOptions() else ui.toggle() end
end

-- Shared with Options.lua and MinimapButton.lua (widget helpers and actions).
ui.newFrame, ui.styleAsPanel, ui.FONT = newFrame, styleAsPanel, FONT
ns.ui = ui
-- Exposed for tools/test_ui.py to read widget/game state directly; not part of the public API.
ns._ui = ui

