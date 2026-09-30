-- Minimap button: left-click plays, right-click opens the options, drag moves it around the minimap's edge.
-- The tooltip shows today's progress and streak. Shown or hidden by the "minimapButton" option; the angle is
-- saved in AzerdleDB.minimapAngle.

local _, ns = ...
local ui = ns.ui

local mm = {}
local ICON = "Interface\\Icons\\INV_Scroll_03"
local DEFAULT_ANGLE = 200   -- degrees, 0 = right of the minimap, counter-clockwise

function mm.place()
    local angle = math.rad((ns.db and ns.db.minimapAngle) or DEFAULT_ANGLE)
    local ok, w = pcall(Minimap.GetWidth, Minimap)
    local r = ((ok and type(w) == "number" and w > 0) and w / 2 or 70) + 10
    mm.button:ClearAllPoints()
    mm.button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

-- While dragging: angle from the minimap's centre to the cursor.
function mm.onDragUpdate()
    local ok, mx, my = pcall(Minimap.GetCenter, Minimap)
    local ok2, cx, cy = pcall(GetCursorPosition)
    if not (ok and ok2 and mx and cx) then return end
    local scale = Minimap:GetEffectiveScale() or 1
    local atan2 = math.atan2 or math.atan
    ns.db.minimapAngle = math.floor(math.deg(atan2(cy / scale - my, cx / scale - mx)) + 0.5) % 360
    mm.place()
end

function mm.tooltip(owner)
    if not GameTooltip then return end
    pcall(function()
        GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
        GameTooltip:SetText("Azerdle", 1, 0.82, 0)
        local game = ui.dailyGame
        if game then
            local status
            if game.done and game.won then
                status = "|cff6ea862solved in " .. #game.guesses .. "/" .. ns.MAX_GUESSES .. "|r"
            elseif game.done then
                status = "|cffff5050missed|r"
            elseif #game.guesses > 0 then
                status = #game.guesses .. "/" .. ns.MAX_GUESSES .. " guesses so far"
            else
                status = "|cffffffffready to play|r"
            end
            GameTooltip:AddLine("Today (#" .. game.puzzle .. "): " .. status, 0.9, 0.9, 0.9)
        end
        if ns.cdb and ns.cdb.stats then
            GameTooltip:AddLine("Streak: " .. ns.currentStreak(ns.cdb.stats), 0.9, 0.9, 0.9)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: play   Right-click: options", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Drag: move", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
end

function mm.build()
    local b = ui.newFrame("Button", "AzerdleMinimapButton", Minimap)
    b:SetSize(31, 31)
    pcall(b.SetFrameStrata, b, "MEDIUM")
    pcall(b.SetFrameLevel, b, 8)
    pcall(b.RegisterForClicks, b, "LeftButtonUp", "RightButtonUp")
    pcall(b.RegisterForDrag, b, "LeftButton")
    pcall(b.SetHighlightTexture, b, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    b.background = b:CreateTexture(nil, "BACKGROUND")
    b.background:SetSize(20, 20)
    b.background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    b.background:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -5)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetTexture(ICON)
    pcall(b.icon.SetTexCoord, b.icon, 0.07, 0.93, 0.07, 0.93)
    b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -6)
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetSize(53, 53)
    b.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b.border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ns.toggleOptions() else ui.toggle() end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", mm.onDragUpdate)
        if GameTooltip then pcall(GameTooltip.Hide, GameTooltip) end
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self) mm.tooltip(self) end)
    b:SetScript("OnLeave", function() if GameTooltip then pcall(GameTooltip.Hide, GameTooltip) end end)
    mm.button = b
end

function mm.update()
    if not mm.button then return end
    if ns.opt("minimapButton") then
        mm.place()
        mm.button:Show()
    else
        mm.button:Hide()
    end
end

-- Some UIs (or a future Forever build) may have no Minimap frame; then there's simply no button.
if Minimap then
    mm.build()
    mm.button:Hide()
    table.insert(ns.onLoaded, mm.update)
    table.insert(ns.optionHooks, function(key) if key == "minimapButton" then mm.update() end end)
end

ns._minimap = mm   -- for tools/test_ui.py
