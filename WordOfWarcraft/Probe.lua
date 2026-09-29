-- Communication probe (/wow probe). Answers, before any leaderboard code exists:
--   * which of the player's names (Forever shows two, e.g. "John Doe") addon messages use as sender / target
--   * which addon-message distributions work on Forever: GUILD, custom CHANNEL, WHISPER, PARTY/RAID/INSTANCE_CHAT,
--     Battle.net game data; in the open world, in combat, in dungeons and boss encounters
--   * which values are secret, and what the friends / guild roster / time APIs return
-- Everything is pcalled and written to WordOfWarcraftDB.log. Any client with the addon answers pings automatically,
-- so the second player doesn't have to type anything (though their log is useful too).

local _, ns = ...

local PREFIX = "WoWordProbe"        -- addon message prefix, max 16 chars
local CHANNEL = "WordOfWarcraftProbe"    -- hidden custom channel for the "global" test
local BURST, RATE = 6, 1           -- send queue: burst of 6, then 1 message per second
local AUTO_INTERVAL = 60           -- seconds between automatic ping rounds in auto mode
local MAX_CHAT_SENDER_LOGS = 30    -- normal chat events logged per session (sender fields only, never text)
local MAX_LIST = 15                -- friends / guild members dumped per list

local show, showS, isSecret = ns.show, ns.showS, ns.isSecret
local function log(msg, echo) ns.log("[probe] " .. msg, echo) end

local myGuid          -- UnitGUID("player"), if readable
local roundCounter = 0
local chatSenderLogs = 0
local systemLogUntil = 0      -- log CHAT_MSG_SYSTEM until this GetTime() (after sending whispers)
local variantsSentTo = {}     -- round .. guid -> true: whisper-variant test done for that pinger this round
local rosterDumpPending = false

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function fn(path)
    -- Returns the function at a dotted global path ("C_ChatInfo.SendAddonMessage"), or nil.
    local v = _G
    for part in path:gmatch("[^%.]+") do
        if type(v) ~= "table" then return nil end
        v = v[part]
    end
    return type(v) == "function" and v or nil
end

-- Calls a global function by dotted path; returns a printable summary of every return value.
local function call(path, ...)
    local f = fn(path)
    if not f then return "MISSING" end
    local r = { n = 0 }
    local function pack(ok, ...)
        r.n = select("#", ...)
        r.ok = ok
        for i = 1, r.n do r[i] = (select(i, ...)) end
    end
    pack(pcall(f, ...))
    if not r.ok then return "ERROR " .. show(r[1]) end
    local parts = {}
    for i = 1, r.n do parts[#parts + 1] = showS(r[i]) end
    if #parts == 0 then return "(no returns)" end
    return table.concat(parts, ", ")
end

-- One-line dump of a table: "k=v k2=v2 ...", nested tables one level deep.
local function dump(t, depth)
    if isSecret(t) then return "<secret table>" end
    if type(t) ~= "table" then return showS(t) end
    depth = depth or 1
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "table" and not isSecret(v) and depth > 0 then
            parts[#parts + 1] = tostring(k) .. "={" .. dump(v, depth - 1) .. "}"
        elseif type(v) ~= "function" then
            parts[#parts + 1] = tostring(k) .. "=" .. (isSecret(v) and "<secret>" or show(v))
        end
    end
    return table.concat(parts, " ")
end

local function split(s)
    local out = {}
    for field in (s .. ";"):gmatch("([^;]*);") do out[#out + 1] = field end
    return out
end

local function serverTime()
    return (fn("GetServerTime") and GetServerTime()) or time()
end

-- Current situation, attached to every send/receive line.
local function ctx()
    local parts = {}
    local ok, v = pcall(InCombatLockdown)
    parts[#parts + 1] = "combat=" .. (ok and show(v) or "?")
    local okI, inInst, instType = pcall(IsInInstance)
    parts[#parts + 1] = "inst=" .. (okI and (show(inInst) .. "/" .. show(instType)) or "?")
    if fn("GetInstanceInfo") then
        local okG, name, _, difficultyID = pcall(GetInstanceInfo)
        if okG then parts[#parts + 1] = "zone=" .. show(name) .. "/diff" .. show(difficultyID) end
    end
    if fn("IsEncounterInProgress") then parts[#parts + 1] = "enc=" .. call("IsEncounterInProgress") end
    if fn("C_ChatInfo.InChatMessagingLockdown") then
        parts[#parts + 1] = "chatLockdown=" .. call("C_ChatInfo.InChatMessagingLockdown")
    end
    if fn("C_ChatInfo.AreOutgoingAddonChatMessagesRestricted") then
        parts[#parts + 1] = "addonRestricted=" .. call("C_ChatInfo.AreOutgoingAddonChatMessagesRestricted")
    end
    return table.concat(parts, " ")
end

local resultNames
local function resultName(r)
    if isSecret(r) then return "<secret>" end
    if not resultNames then
        resultNames = {}
        if type(Enum) == "table" and type(Enum.SendAddonMessageResult) == "table" then
            for k, v in pairs(Enum.SendAddonMessageResult) do resultNames[v] = k end
        end
    end
    return show(r) .. (resultNames[r] and ("(" .. resultNames[r] .. ")") or "")
end

local function channelId()
    if not fn("GetChannelName") then return 0 end
    local ok, id = pcall(GetChannelName, CHANNEL)
    if ok and type(id) == "number" and not isSecret(id) then return id end
    return 0
end

---------------------------------------------------------------------------
-- Send queue (token bucket: BURST messages at once, then RATE per second)
---------------------------------------------------------------------------

local queue = {}
local tokens = BURST
local lastRefill = GetTime()

local function dispatch(item)
    local ok, res
    if item.bn then
        local f = fn("BNSendGameData") or fn("C_BattleNet.SendGameData")
        if not f then
            log("SEND " .. item.label .. " BN: no BNSendGameData")
            return
        end
        ok, res = pcall(f, item.target, PREFIX, item.text)
    else
        local target = item.target
        if item.dist == "CHANNEL" then
            target = channelId()
            if target == 0 then
                log("SEND " .. item.label .. " CHANNEL: not in channel " .. CHANNEL .. " " .. ctx())
                return
            end
        end
        ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, item.dist, target)
        if item.dist == "WHISPER" then systemLogUntil = GetTime() + 5 end
    end
    log(string.format("SEND %s dist=%s target=%s -> %s %s | %s", item.label, item.bn and "BN" or item.dist,
        showS(item.target), ok and "ok" or "ERROR", ok and resultName(res) or show(res), ctx()))
end

local function pump()
    local now = GetTime()
    tokens = math.min(BURST, tokens + (now - lastRefill) * RATE)
    lastRefill = now
    while tokens >= 1 and #queue > 0 do
        tokens = tokens - 1
        dispatch(table.remove(queue, 1))
    end
end

local function enqueue(item)
    queue[#queue + 1] = item
    pump()
end

C_Timer.NewTicker(0.2, pump)

---------------------------------------------------------------------------
-- Identity, APIs, friends, guild, time
---------------------------------------------------------------------------

local function snapshotIdentity()
    log("=== identity ===")
    log("build GetBuildInfo: " .. call("GetBuildInfo") .. " WOW_PROJECT_ID=" .. show(WOW_PROJECT_ID))
    log("UnitName(player): " .. call("UnitName", "player"))
    log("UnitFullName(player): " .. call("UnitFullName", "player"))
    log("UnitNameUnmodified(player): " .. call("UnitNameUnmodified", "player"))
    log("GetUnitName(player,true): " .. call("GetUnitName", "player", true))
    log("GetUnitName(player,false): " .. call("GetUnitName", "player", false))
    log("UnitPVPName(player): " .. call("UnitPVPName", "player"))
    log("GetRealmName: " .. call("GetRealmName") .. " | GetNormalizedRealmName: " .. call("GetNormalizedRealmName"))
    local ok, guid = pcall(UnitGUID, "player")
    log("UnitGUID(player): " .. (ok and showS(guid) or "ERROR"))
    if ok and guid and not isSecret(guid) then
        myGuid = guid
        log("GetPlayerInfoByGUID(own): " .. call("GetPlayerInfoByGUID", guid))
        if fn("C_BattleNet.GetGameAccountInfoByGUID") then
            local okB, info = pcall(C_BattleNet.GetGameAccountInfoByGUID, guid)
            log("C_BattleNet.GetGameAccountInfoByGUID(own): " .. (okB and dump(info) or ("ERROR " .. show(info))))
        end
    end
    if type(PlayerLocation) == "table" and fn("C_PlayerInfo.GetName") then
        local okL, loc = pcall(PlayerLocation.CreateFromUnit, PlayerLocation, "player")
        if okL then log("C_PlayerInfo.GetName(player loc): " .. call("C_PlayerInfo.GetName", loc)) end
    end
    -- Forever's surname APIs (found by API discovery, 2026-09-28).
    log("C_PlayerInfo.ShouldDisplaySurname(): " .. call("C_PlayerInfo.ShouldDisplaySurname") ..
        " | (player): " .. call("C_PlayerInfo.ShouldDisplaySurname", "player"))
    local okF, full = pcall(GetUnitName, "player", true)
    if okF and full and not isSecret(full) then
        log("C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator(" .. full .. "): " ..
            call("C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator", full))
    end
    if okF and full and not isSecret(full) then
        for _, mode in ipairs({ "none", "short", "guild", "all" }) do
            log("Ambiguate(" .. full .. "," .. mode .. "): " .. call("Ambiguate", full, mode))
        end
    end
    if fn("BNGetInfo") then
        local okB, _, battleTag, toonID = pcall(BNGetInfo)
        log("BNGetInfo: " .. (okB and ("battleTag=" .. (battleTag and "<set>" or "nil") .. " toonID=" .. showS(toonID))
            or "ERROR"))
    end
    log("IsInGuild: " .. call("IsInGuild") .. " | GetGuildInfo(player): " .. call("GetGuildInfo", "player"))
end

local function snapshotTime()
    log("=== time ===")
    log("GetServerTime: " .. call("GetServerTime") .. " | time(): " .. show(time()) ..
        " | UTC now: " .. date("!%Y-%m-%d %H:%M:%S", serverTime()))
    log("GetGameTime (realm h,m): " .. call("GetGameTime"))
    log("C_DateAndTime.GetServerTimeLocal: " .. call("C_DateAndTime.GetServerTimeLocal"))
    log("C_DateAndTime.GetSecondsUntilDailyReset: " .. call("C_DateAndTime.GetSecondsUntilDailyReset"))
    if fn("C_DateAndTime.GetCurrentCalendarTime") then
        local ok, t = pcall(C_DateAndTime.GetCurrentCalendarTime)
        log("C_DateAndTime.GetCurrentCalendarTime: " .. (ok and dump(t) or "ERROR"))
    end
end

-- Lists every function in the namespaces we care about, and global functions that look name-related,
-- to discover Forever-specific name APIs (e.g. for the second "surname" part).
local function snapshotApis()
    log("=== API discovery ===")
    for _, nsName in ipairs({ "C_ChatInfo", "C_FriendList", "C_BattleNet", "C_GuildInfo", "C_Club",
        "C_PlayerInfo", "C_DateAndTime", "C_AddOns", "C_NameUtil", "C_RecentAllies" }) do
        local t = _G[nsName]
        if type(t) == "table" then
            local names = {}
            for k, v in pairs(t) do if type(v) == "function" then names[#names + 1] = tostring(k) end end
            table.sort(names)
            log(nsName .. ": " .. table.concat(names, ","))
        else
            log(nsName .. ": MISSING")
        end
    end
    local globals = {}
    for _, name in ipairs({ "JoinChannelByName", "JoinTemporaryChannel", "JoinPermanentChannel", "LeaveChannelByName",
        "GetChannelName", "GetChannelList", "BNSendGameData", "BNGetFriendInfo", "BNGetNumFriends", "BNGetInfo",
        "GetNumGuildMembers", "GetGuildRosterInfo", "Ambiguate", "ChatFrame_RemoveChannel",
        "ChatFrame_AddMessageEventFilter", "issecretvalue", "GetPlayerInfoByGUID", "RegisterAddonMessagePrefix",
        "SendAddonMessage" }) do
        globals[#globals + 1] = name .. "=" .. (fn(name) and "y" or "n")
    end
    log("globals: " .. table.concat(globals, " "))
    local found = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and (k:find("Surname") or k:find("FirstName") or k:find("LastName")
            or k:find("DisplayName") or k:find("Nickname") or k:find("FamilyName")) then
            found[#found + 1] = k .. "(" .. type(v) .. ")"
        elseif type(k) == "string" and k:sub(1, 2) == "C_" and type(v) == "table" then
            for fk, fv in pairs(v) do
                if type(fk) == "string" and type(fv) == "function" and (fk:find("Surname") or fk:find("FirstName")
                    or fk:find("LastName") or fk:find("DisplayName") or fk:find("Nickname") or fk:find("FamilyName")
                    or fk:find("FullName")) then
                    found[#found + 1] = k .. "." .. fk
                end
            end
        end
        if #found >= 80 then break end
    end
    table.sort(found)
    log("name-like APIs: " .. (#found > 0 and table.concat(found, ",") or "none"))
end

-- Online WoW game accounts of Battle.net friends: list of { id = gameAccountID, desc = "..." }.
local function bnWowAccounts()
    local out = {}
    if not (fn("BNGetNumFriends") and fn("C_BattleNet.GetFriendAccountInfo")) then return out end
    local ok, total = pcall(BNGetNumFriends)
    if not ok or type(total) ~= "number" or isSecret(total) then return out end
    for i = 1, total do
        local okA, acc = pcall(C_BattleNet.GetFriendAccountInfo, i)
        local g = okA and type(acc) == "table" and acc.gameAccountInfo
        if type(g) == "table" and g.isOnline and g.gameAccountID and g.clientProgram == (BNET_CLIENT_WOW or "WoW") then
            out[#out + 1] = { id = g.gameAccountID, desc = string.format("%s-%s project=%s",
                show(g.characterName), show(g.realmName), show(g.wowProjectID)) }
        end
    end
    return out
end

local function snapshotFriends()
    log("=== character friends (C_FriendList) ===")
    log("GetNumFriends: " .. call("C_FriendList.GetNumFriends") ..
        " | GetNumOnlineFriends: " .. call("C_FriendList.GetNumOnlineFriends"))
    local ok, n = pcall(C_FriendList.GetNumFriends)
    if ok and type(n) == "number" and not isSecret(n) then
        for i = 1, math.min(n, MAX_LIST) do
            local okI, info = pcall(C_FriendList.GetFriendInfoByIndex, i)
            log("friend " .. i .. ": " .. (okI and dump(info) or ("ERROR " .. show(info))))
        end
    end

    log("=== Battle.net friends ===")
    log("BNGetNumFriends: " .. call("BNGetNumFriends"))
    local okB, total = pcall(BNGetNumFriends)
    if okB and type(total) == "number" and not isSecret(total) then
        for i = 1, math.min(total, MAX_LIST) do
            local okA, acc = pcall(C_BattleNet.GetFriendAccountInfo, i)
            if okA and type(acc) == "table" then
                -- Skip notes/broadcasts; keep what identifies the game account.
                local g = acc.gameAccountInfo
                log(string.format("bnfriend %d: bnetAccountID=%s isFriend=%s gameAccountInfo={%s}", i,
                    showS(acc.bnetAccountID), show(acc.isFriend), type(g) == "table" and dump(g, 0) or "nil"))
            else
                log("bnfriend " .. i .. ": ERROR " .. show(acc))
            end
        end
        if fn("BNGetFriendInfo") then log("BNGetFriendInfo(1) (legacy): " .. call("BNGetFriendInfo", 1)) end
    end
end

local function dumpGuildRoster()
    log("=== guild roster ===")
    log("GetNumGuildMembers (total, online): " .. call("GetNumGuildMembers"))
    local ok, n = pcall(GetNumGuildMembers)
    if not ok or type(n) ~= "number" or isSecret(n) then return end
    for i = 1, math.min(n, MAX_LIST) do
        local okI, name, _, _, _, _, _, _, _, online, _, _, _, _, isMobile, _, _, guid = pcall(GetGuildRosterInfo, i)
        if okI then
            log(string.format("member %d: name=%s online=%s mobile=%s guid=%s", i, showS(name), show(online),
                show(isMobile), showS(guid)))
        else
            log("member " .. i .. ": ERROR " .. show(name))
        end
    end
end

local function requestGuildRoster()
    if not (fn("IsInGuild") and IsInGuild()) then
        log("guild roster: not in a guild")
        return
    end
    rosterDumpPending = true
    log("C_GuildInfo.GuildRoster(): " .. call("C_GuildInfo.GuildRoster"))
    C_Timer.After(5, function()
        if rosterDumpPending then
            rosterDumpPending = false
            log("no GUILD_ROSTER_UPDATE within 5s, dumping anyway")
            dumpGuildRoster()
        end
    end)
end

ns.on("GUILD_ROSTER_UPDATE", function()
    if not rosterDumpPending then return end
    rosterDumpPending = false
    dumpGuildRoster()
end)

---------------------------------------------------------------------------
-- Hidden custom channel
---------------------------------------------------------------------------

local function hideChannelFromChat()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then
            if fn("ChatFrame_RemoveChannel") then
                pcall(ChatFrame_RemoveChannel, frame, CHANNEL)
            elseif fn("ChatFrameUtil.RemoveChannel") then
                pcall(ChatFrameUtil.RemoveChannel, frame, CHANNEL)
            end
        end
    end
end

local function joinChannel(why)
    local id = channelId()
    if id > 0 then
        log("channel " .. CHANNEL .. " already joined as #" .. id .. " (" .. why .. ")")
        hideChannelFromChat()
        return
    end
    local joiner = (fn("JoinTemporaryChannel") and "JoinTemporaryChannel") or
        (fn("JoinChannelByName") and "JoinChannelByName") or (fn("C_ChatInfo.JoinChannel") and "C_ChatInfo.JoinChannel")
    if not joiner then
        log("channel: no join API found", true)
        return
    end
    log("channel join via " .. joiner .. " (" .. why .. "): " .. call(joiner, CHANNEL))
    C_Timer.After(3, function()
        log("channel after join: GetChannelName=" .. call("GetChannelName", CHANNEL) ..
            " | GetChannelList=" .. call("GetChannelList"))
        hideChannelFromChat()
    end)
end

-- Hide our channel's join/leave notices from chat.
local function channelNoticeFilter(_, _, _, _, _, _, _, _, _, _, baseName)
    if baseName and not isSecret(baseName) and baseName == CHANNEL then return true end
    return false
end
if fn("ChatFrame_AddMessageEventFilter") then
    pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_CHANNEL_NOTICE", channelNoticeFilter)
elseif fn("ChatFrameUtil.AddMessageEventFilter") then
    pcall(ChatFrameUtil.AddMessageEventFilter, "CHAT_MSG_CHANNEL_NOTICE", channelNoticeFilter)
end

ns.on("CHAT_MSG_CHANNEL_NOTICE", function(notice, _, _, channelString, _, _, _, channelNumber, baseName)
    if isSecret(baseName) or baseName == CHANNEL then
        log(string.format("channel notice: %s channel=%s number=%s base=%s", showS(notice), show(channelString),
            show(channelNumber), showS(baseName)))
    end
end)

---------------------------------------------------------------------------
-- Pings
---------------------------------------------------------------------------

-- On Forever, UnitName returns the character's two names as name + "realm" ("Bear", "Joegre"), and the real realm
-- only comes from GetRealmName (seen in the login snapshots, 2026-09-28). So both are sent, separately.
local function myFields()
    local okN, name, surname = pcall(UnitName, "player")
    local okR, realm = pcall(GetNormalizedRealmName)
    name = (okN and name and not isSecret(name)) and name or "?"
    surname = (okN and surname and not isSecret(surname)) and surname or ""
    realm = (okR and realm and not isSecret(realm)) and realm or ""
    return myGuid or "?", name, surname, realm
end

-- PING;round;how;guid;name;surname;realm;serverTime
local function pingText(round, how)
    local guid, name, surname, realm = myFields()
    return table.concat({ "PING", round, how, guid, name, surname, realm, tostring(serverTime()) }, ";")
end

local function newRound()
    roundCounter = roundCounter + 1
    return string.format("%04x%d", math.random(0, 65535), roundCounter)
end

-- Sends a PING on every distribution that applies right now.
local function pingRound(label)
    local round = newRound()
    log(string.format("--- ping round %s (%s) | %s", round, label, ctx()), true)
    if fn("IsInGuild") and IsInGuild() then
        enqueue({ label = round, dist = "GUILD", text = pingText(round, "GUILD") })
    else
        log("skip GUILD: not in guild")
    end
    enqueue({ label = round, dist = "CHANNEL", text = pingText(round, "CHANNEL") })
    local inInstanceGroup = fn("IsInGroup") and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    if fn("IsInRaid") and IsInRaid() then
        enqueue({ label = round, dist = "RAID", text = pingText(round, "RAID") })
    elseif fn("IsInGroup") and IsInGroup() then
        enqueue({ label = round, dist = "PARTY", text = pingText(round, "PARTY") })
    else
        log("skip PARTY/RAID: not grouped")
    end
    if inInstanceGroup then
        enqueue({ label = round, dist = "INSTANCE_CHAT", text = pingText(round, "INSTANCE_CHAT") })
    end
    local accounts = bnWowAccounts()
    if #accounts == 0 then log("skip BN: no Battle.net friends online in WoW") end
    for _, a in ipairs(accounts) do
        log("BN target " .. a.desc)
        enqueue({ label = round, bn = true, target = a.id, text = pingText(round, "BN") })
    end
    return round
end

local function whisperPing(target, how)
    local round = newRound()
    enqueue({ label = round .. "/" .. how, dist = "WHISPER", target = target, text = pingText(round, "W-" .. how) })
end

-- Whisper-pings the current target under every name form we can build for them.
local function pingTarget()
    local ok, exists = pcall(UnitIsPlayer, "target")
    if not ok or not exists then
        log("probe target: target a player first", true)
        return
    end
    local forms = {}
    local function add(label, v)
        if v == nil then return end
        if isSecret(v) then
            log("target name form " .. label .. " is secret; trying it anyway")
        elseif v == "" then
            return
        end
        forms[#forms + 1] = { label = label, name = v }
    end
    local okN, name, realm = pcall(UnitName, "target")
    log("target UnitName: " .. (okN and (showS(name) .. " realm=" .. showS(realm)) or "ERROR"), true)
    if okN then add("UnitName", name) end
    local okG, full = pcall(GetUnitName, "target", true)
    log("target GetUnitName(true): " .. (okG and showS(full) or "ERROR"), true)
    if okG and full ~= name and full ~= (name and realm and (name .. " " .. realm)) then add("GetUnitName", full) end
    if okG and full and not isSecret(full) and fn("C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator") then
        local okL, link = pcall(C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator, full)
        if okL and link ~= full then add("LinkName", link) end
    end
    -- UnitName's second return is the surname on Forever (the realm on other clients).
    if okN and name and realm and realm ~= "" and not isSecret(name) and not isSecret(realm) then
        add("Name-Surname", name .. "-" .. realm)
        add("Name Surname", name .. " " .. realm)
    end
    local okR, nrealm = pcall(GetNormalizedRealmName)
    if okN and okR and name and nrealm and not isSecret(name) and not isSecret(nrealm) then
        add("Name-Realm", name .. "-" .. nrealm)
    end
    local okU, guid = pcall(UnitGUID, "target")
    if okU and guid and not isSecret(guid) then
        local okP, _, _, _, _, _, gName, gRealm = pcall(GetPlayerInfoByGUID, guid)
        log("target GetPlayerInfoByGUID: " .. (okP and (showS(gName) .. " realm=" .. showS(gRealm)) or "ERROR"), true)
        if okP and gName and gName ~= name then add("ByGUID", gName) end
    end
    for _, f in ipairs(forms) do whisperPing(f.name, f.label) end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- Answers a PING: an ACK whispered to the exact sender string, an ACKB on the same broadcast distribution
-- (so the pinger learns about it even if whispers fail), and once per pinger per round a whisper to every
-- name form we can build for them (WV), so the pinger's log shows which forms reach them.
local function answerPing(f, dist, sender)
    local round, how, guid, name, surname, realm = f[2], f[3], f[4], f[5], f[6], f[7]
    local seen = isSecret(sender) and "<secret>" or tostring(sender)
    enqueue({ label = "ack " .. round, dist = "WHISPER", target = sender,
        text = table.concat({ "ACK", round, how, seen }, ";") })
    if dist ~= "WHISPER" then
        enqueue({ label = "ackb " .. round, dist = dist,
            text = table.concat({ "ACKB", round, how, guid, seen }, ";") })
    end
    local key = round .. guid
    if variantsSentTo[key] then return end
    variantsSentTo[key] = true
    local forms, seenForms = {}, {}
    -- Identical strings are whispered once, with all their labels ("sender+Name-Surname").
    local function add(label, v)
        if v == nil or v == "" then return end
        if not isSecret(v) then
            if seenForms[v] then
                seenForms[v].label = seenForms[v].label .. "+" .. label
                return
            end
        end
        local form = { label = label, name = v }
        forms[#forms + 1] = form
        if not isSecret(v) then seenForms[v] = form end
    end
    add("sender", sender)
    if not isSecret(sender) and fn("Ambiguate") then
        local ok, s = pcall(Ambiguate, sender, "none")
        if ok then add("Ambiguate-none", s) end
        ok, s = pcall(Ambiguate, sender, "short")
        if ok then add("Ambiguate-short", s) end
    end
    if name ~= "?" then
        add("UnitName", name)
        if surname ~= "" then
            add("Name-Surname", name .. "-" .. surname)
            add("Name Surname", name .. " " .. surname)
        end
        if realm ~= "" then add("Name-Realm", name .. "-" .. realm) end
        if surname ~= "" and realm ~= "" then add("Name Surname-Realm", name .. " " .. surname .. "-" .. realm) end
        if surname ~= "" and fn("C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator") then
            local ok, link = pcall(C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator, name .. " " .. surname)
            if ok then add("LinkName", link) end
        end
    end
    if guid ~= "?" and fn("GetPlayerInfoByGUID") then
        local ok, _, _, _, _, _, gName, gRealm = pcall(GetPlayerInfoByGUID, guid)
        log("pinger GetPlayerInfoByGUID: " .. (ok and (showS(gName) .. " realm=" .. showS(gRealm)) or "ERROR"))
        if ok then
            add("ByGUID", gName)
            if gName and gRealm and gRealm ~= "" and not isSecret(gName) and not isSecret(gRealm) then
                add("ByGUID-Realm", gName .. "-" .. gRealm)
            end
        end
    end
    for _, form in ipairs(forms) do
        enqueue({ label = "wv " .. round .. "/" .. form.label, dist = "WHISPER", target = form.name,
            text = table.concat({ "WV", round, form.label, isSecret(form.name) and "<secret>" or form.name }, ";") })
    end
end

local function describeArgs(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[#parts + 1] = showS((select(i, ...))) end
    return table.concat(parts, " | ")
end

ns.on("CHAT_MSG_ADDON", function(prefix, text, dist, sender, ...)
    if isSecret(prefix) then
        log("CHAT_MSG_ADDON with secret prefix: " .. describeArgs(prefix, text, dist, sender, ...))
        return
    end
    if prefix ~= PREFIX then return end
    log("RECV raw: " .. describeArgs(text, dist, sender, ...) .. " | " .. ctx())
    if isSecret(text) or isSecret(dist) then
        log("RECV text or distribution is secret; can't parse", true)
        return
    end
    local f = split(text)
    local kind = f[1]
    local seen = showS(sender)
    if kind == "PING" then
        local sentAt = tonumber(f[8])
        local delay = sentAt and (serverTime() - sentAt) or "?"
        if myGuid and f[4] == myGuid then
            log(string.format("self echo of PING %s via %s: sender=%s delay=%ss", f[2], dist, seen, delay), true)
            return
        end
        log(string.format("got PING %s via %s (%s) from %s | their UnitName=%s surname=%s realm=%s guid=%s delay=%ss",
            f[2], dist, f[3], seen, f[5], f[6], f[7], f[4], delay), true)
        answerPing(f, dist, sender)
    elseif kind == "ACK" then
        log(string.format("got ACK for %s (%s) via %s from %s; they saw me as '%s'", f[2], f[3], dist, seen, f[4]), true)
    elseif kind == "ACKB" then
        if myGuid and f[4] ~= myGuid then return end
        log(string.format("got ACKB for %s (%s) via %s from %s; they saw me as '%s'", f[2], f[3], dist, seen, f[5]), true)
    elseif kind == "WV" then
        log(string.format("got WV %s: whisper addressed by form '%s' = '%s' ARRIVED (from %s)", f[2], f[3], f[4], seen),
            true)
    else
        log("RECV unknown kind " .. tostring(kind))
    end
end)

ns.on("BN_CHAT_MSG_ADDON", function(prefix, text, channel, senderID, ...)
    if isSecret(prefix) or prefix ~= PREFIX then return end
    log("BN RECV raw: " .. describeArgs(text, channel, senderID, ...) .. " | " .. ctx(), true)
    if isSecret(text) then return end
    local f = split(text)
    if f[1] == "PING" then
        local seen = isSecret(senderID) and "<secret>" or tostring(senderID)
        enqueue({ label = "bnack " .. f[2], bn = true, target = senderID,
            text = table.concat({ "ACK", f[2], f[3], seen }, ";") })
    end
end)

-- Sender fields of ordinary chat, to compare with CHAT_MSG_ADDON's sender. Message text is never logged.
for _, event in ipairs({ "CHAT_MSG_WHISPER", "CHAT_MSG_GUILD", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_SAY", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_CHANNEL" }) do
    ns.on(event, function(_, author, _, _, author2, _, _, _, channelBase, _, _, guid, bnSenderID)
        if chatSenderLogs >= MAX_CHAT_SENDER_LOGS then return end
        if event == "CHAT_MSG_CHANNEL" and not isSecret(channelBase) and channelBase ~= CHANNEL then return end
        chatSenderLogs = chatSenderLogs + 1
        log(string.format("%s sender: author=%s playerName2=%s guid=%s bnSenderID=%s", event, showS(author),
            showS(author2), showS(guid), showS(bnSenderID)))
    end)
end

-- "No player named X is currently playing" and similar, right after we whisper.
ns.on("CHAT_MSG_SYSTEM", function(text)
    if GetTime() <= systemLogUntil then log("system message after whisper: " .. showS(text), true) end
end)

---------------------------------------------------------------------------
-- Prefix, auto mode, commands
---------------------------------------------------------------------------

local okP, prefixResult = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
ns.log("[probe] RegisterAddonMessagePrefix(" .. PREFIX .. "): " .. (okP and showS(prefixResult) or
    ("ERROR " .. show(prefixResult))))

local function probeDB()
    ns.db.probe = ns.db.probe or {}
    return ns.db.probe
end

local autoTicker
local function setAuto(on)
    probeDB().auto = on
    if autoTicker then autoTicker:Cancel() autoTicker = nil end
    if on then autoTicker = C_Timer.NewTicker(AUTO_INTERVAL, function() pingRound("auto timer") end) end
end

ns.on("PLAYER_REGEN_DISABLED", function()
    if probeDB().auto then C_Timer.After(1.5, function() pingRound("combat start") end) end
end)
ns.on("ENCOUNTER_START", function(encounterID, encounterName)
    log("ENCOUNTER_START " .. showS(encounterID) .. " " .. showS(encounterName))
    if probeDB().auto then C_Timer.After(2, function() pingRound("boss encounter") end) end
end)
ns.on("ENCOUNTER_END", function(encounterID, _, _, _, success)
    log("ENCOUNTER_END " .. showS(encounterID) .. " success=" .. showS(success))
end)

local firstWorld = true
ns.on("PLAYER_ENTERING_WORLD", function()
    log("PLAYER_ENTERING_WORLD | " .. ctx())
    if firstWorld then
        firstWorld = false
        snapshotIdentity()   -- also sets myGuid so we can recognise our own echoes
        C_Timer.After(5, function() joinChannel("login") end)
    else
        C_Timer.After(5, function() joinChannel("zone change") end)
    end
    if probeDB().auto then C_Timer.After(10, function() pingRound("entered world/zone") end) end
end)

table.insert(ns.onLoaded, function()
    if probeDB().auto then setAuto(true) end
end)

local sub = {}
sub[""] = function()
    log("===== /wow probe (full) =====", true)
    snapshotIdentity()
    snapshotTime()
    snapshotApis()
    snapshotFriends()
    requestGuildRoster()
    -- Ping right away when the channel is already joined (it is, 5s after login), so a quick /reload can't cut
    -- the round off; otherwise give the join a few seconds.
    local delay = channelId() > 0 and 0 or 4
    joinChannel("probe")
    C_Timer.After(delay, function()
        pingRound("manual")
        C_Timer.After(12, function() log("probe round sent; replies arrive over the next ~20s", true) end)
    end)
end
sub.ping = function() pingRound("manual ping") end
sub.target = pingTarget
sub.whisper = function(arg)
    if arg == "" then
        log("usage: /wow probe whisper <name>", true)
        return
    end
    log("whisper ping to '" .. arg .. "'", true)
    whisperPing(arg, "typed")
end
sub.auto = function()
    setAuto(not probeDB().auto)
    log("auto mode: " .. tostring(probeDB().auto) .. " (ping every " .. AUTO_INTERVAL ..
        "s, on combat start, boss pull and zoning)", true)
end
sub.note = function(arg)
    log("NOTE: " .. arg, true)
end
sub.status = function()
    log("status: channel #" .. channelId() .. " queue=" .. #queue .. " auto=" .. tostring(probeDB().auto) ..
        " | " .. ctx(), true)
end

ns.commands.probe = function(arg)
    local cmd, rest = arg:match("^(%S*)%s*(.-)$")
    local f = sub[(cmd or ""):lower()]
    if not f then
        ns.print("probe: /wow probe [ping | target | whisper <name> | auto | note <text> | status]")
        return
    end
    f(rest or "")
end
table.insert(ns.help, "/wow probe - full comms probe (identity, APIs, friends, guild, ping every channel)")
table.insert(ns.help, "/wow probe ping | target | whisper <name> | auto | note <text> | status")
