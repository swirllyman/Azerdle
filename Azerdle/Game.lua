-- Game logic: daily word, guess validation, scoring, game state, stats, share text.
-- No UI and no networking: UI.lua draws it, and the leaderboards will hook ns.onGameFinished.
-- Everything here is plain Lua so tools/test_game.py can drive it directly.

local _, ns = ...

ns.WORD_LENGTH = 5
ns.MAX_GUESSES = 6

-- Puzzle #1 is the UTC day starting at this server timestamp (2026-09-28 00:00 UTC). Every client derives the
-- puzzle number from GetServerTime() (UTC epoch seconds), so time zones and realm clocks can't split players.
-- Changing it re-numbers every puzzle and shifts which word falls on which day.
ns.EPOCH = 1790553600
local DAY = 86400

-- Letter results.
local ABSENT, PRESENT, CORRECT = 0, 1, 2
ns.ABSENT, ns.PRESENT, ns.CORRECT = ABSENT, PRESENT, CORRECT

ns.onGameFinished = {}   -- functions(game), called once when any game ends (daily or practice)

---------------------------------------------------------------------------
-- Days and words
---------------------------------------------------------------------------

function ns.serverTime()
    return (type(GetServerTime) == "function" and GetServerTime()) or time()
end

-- Puzzle number for a UTC timestamp. Before the epoch (wrong clock), clamp to #1.
function ns.puzzleNumber(t)
    return math.max(1, math.floor((t - ns.EPOCH) / DAY) + 1)
end

function ns.todayPuzzle()
    return ns.puzzleNumber(ns.serverTime())
end

function ns.secondsUntilNextPuzzle(t)
    t = t or ns.serverTime()
    return DAY - ((t - ns.EPOCH) % DAY)
end

-- ns.ANSWERS (Words.lua) is already in daily order and append-only, so puzzle n is the n-th word for every
-- version of the list that has at least n words. Only after the list runs out does it wrap around.
function ns.dailyWord(puzzle)
    local n = #ns.ANSWERS
    return ns.ANSWERS[((puzzle - 1) % n) + 1]
end

function ns.randomAnswer(exclude)
    local n = #ns.ANSWERS
    local word
    repeat word = ns.ANSWERS[math.random(1, n)] until word ~= exclude or n == 1
    return word
end

local validSet
-- True if word (any case) is an accepted guess: an answer or in the guess list.
function ns.isValidGuess(word)
    if not validSet then
        validSet = {}
        for _, w in ipairs(ns.ANSWERS) do validSet[w] = true end
        for w in ns.GUESSES:gmatch("%a+") do validSet[w] = true end
    end
    return validSet[word:upper()] == true
end

---------------------------------------------------------------------------
-- Scoring
---------------------------------------------------------------------------

-- Standard Wordle scoring: returns a list of CORRECT/PRESENT/ABSENT per letter. Greens are taken first; each
-- remaining answer letter can then turn at most one guessed letter yellow, left to right, so repeated letters in
-- the guess only light up as often as they occur in the answer.
function ns.score(guess, answer)
    guess, answer = guess:upper(), answer:upper()
    local result, remaining = {}, {}
    for i = 1, #answer do
        local a, g = answer:sub(i, i), guess:sub(i, i)
        if g == a then
            result[i] = CORRECT
        else
            result[i] = ABSENT
            remaining[a] = (remaining[a] or 0) + 1
        end
    end
    for i = 1, #guess do
        if result[i] ~= CORRECT then
            local g = guess:sub(i, i)
            if (remaining[g] or 0) > 0 then
                result[i] = PRESENT
                remaining[g] = remaining[g] - 1
            end
        end
    end
    return result
end

-- Best known state of each letter across a game's guesses, for colouring the keyboard: letter -> state.
function ns.letterStates(game)
    local states = {}
    for gi, guess in ipairs(game.guesses) do
        local result = game.results[gi]
        for i = 1, #guess do
            local l = guess:sub(i, i)
            if (states[l] or -1) < result[i] then states[l] = result[i] end
        end
    end
    return states
end

local ORDINAL = { "1st", "2nd", "3rd", "4th", "5th", "6th", "7th" }

-- Hard mode: every revealed hint must be used in later guesses. Greens must stay in place, and each yellow or
-- green letter must appear at least as often as that guess showed it. Returns nil if word is allowed, else the
-- message to show the player.
function ns.hardModeError(game, word)
    word = word:upper()
    for gi, guess in ipairs(game.guesses) do
        local result = game.results[gi]
        for i = 1, #guess do
            local l = guess:sub(i, i)
            if result[i] == CORRECT and word:sub(i, i) ~= l then
                return ORDINAL[i] .. " letter must be " .. l
            end
        end
    end
    for gi, guess in ipairs(game.guesses) do
        local result, need = game.results[gi], {}
        for i = 1, #guess do
            local l = guess:sub(i, i)
            if result[i] ~= ABSENT then need[l] = (need[l] or 0) + 1 end
        end
        for i = 1, #guess do
            local l = guess:sub(i, i)
            if need[l] then
                local _, have = word:gsub(l, "")
                if have < need[l] then return "Guess must contain " .. l end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Games
---------------------------------------------------------------------------

-- mode is "daily" or "practice". Daily games take today's puzzle unless one is given.
function ns.newGame(mode, puzzle)
    local game = { mode = mode, guesses = {}, results = {}, done = false, won = false }
    if mode == "daily" then
        game.puzzle = puzzle or ns.todayPuzzle()
        game.answer = ns.dailyWord(game.puzzle)
    else
        game.answer = ns.randomAnswer(ns.dailyWord(ns.todayPuzzle()))
    end
    return game
end

-- Tries a guess. Returns true, result on success, or false, reason[, message]: "done", "short" (not enough
-- letters), "invalid" (not in the word list) or "hard" (breaks a hard-mode rule; message says which).
-- replay=true skips both checks (restoring a saved game). game.hard turns hard mode on for that game.
function ns.submitGuess(game, word, replay)
    if game.done then return false, "done" end
    word = (word or ""):upper()
    if #word ~= ns.WORD_LENGTH or word:find("[^A-Z]") then return false, "short" end
    if not replay and not ns.isValidGuess(word) then return false, "invalid" end
    if not replay and game.hard then
        local err = ns.hardModeError(game, word)
        if err then return false, "hard", err end
    end
    local result = ns.score(word, game.answer)
    table.insert(game.guesses, word)
    table.insert(game.results, result)
    if word == game.answer then
        game.done, game.won = true, true
    elseif #game.guesses >= ns.MAX_GUESSES then
        game.done = true
    end
    if game.done then
        for _, fn in ipairs(ns.onGameFinished) do
            local ok, err = pcall(fn, game)
            if not ok and ns.log then ns.log("onGameFinished: ERROR " .. tostring(err)) end
        end
    end
    return true, result
end

---------------------------------------------------------------------------
-- Stats (per character; `stats` is a saved table, see ns.newStats)
---------------------------------------------------------------------------

function ns.newStats()
    return { played = 0, wins = 0, streak = 0, maxStreak = 0, dist = { 0, 0, 0, 0, 0, 0 },
        lastPuzzle = 0, lastWonPuzzle = 0 }
end

-- Records a finished daily game. Each puzzle counts once; a win extends the streak only if the previous
-- puzzle was won too.
function ns.recordResult(stats, game)
    if game.mode ~= "daily" or not game.done or game.puzzle <= stats.lastPuzzle then return false end
    stats.played = stats.played + 1
    stats.lastPuzzle = game.puzzle
    if game.won then
        stats.wins = stats.wins + 1
        local n = #game.guesses
        stats.dist[n] = (stats.dist[n] or 0) + 1
        if stats.lastWonPuzzle == game.puzzle - 1 then
            stats.streak = stats.streak + 1
        else
            stats.streak = 1
        end
        stats.lastWonPuzzle = game.puzzle
        stats.maxStreak = math.max(stats.maxStreak, stats.streak)
    else
        stats.streak = 0
    end
    return true
end

-- The streak as it stands today: a streak whose last win was before yesterday is already broken.
function ns.currentStreak(stats, today)
    today = today or ns.todayPuzzle()
    if stats.lastWonPuzzle >= today - 1 then return stats.streak end
    return 0
end

function ns.winPercent(stats)
    if stats.played == 0 then return 0 end
    return math.floor(stats.wins * 100 / stats.played + 0.5)
end

-- Saved form of today's daily game (just the guesses; results are recomputed), and back.
function ns.saveDaily(game)
    local guesses = {}
    for i, g in ipairs(game.guesses) do guesses[i] = g end
    return { puzzle = game.puzzle, guesses = guesses, hard = game.hard or nil }
end

-- Rebuilds today's game from saved guesses. Returns a fresh game if the save is from another day.
-- Replaying doesn't fire ns.onGameFinished (the game already finished before the reload).
function ns.restoreDaily(saved)
    local hooks = ns.onGameFinished
    ns.onGameFinished = {}
    local game = ns.newGame("daily")
    if saved and saved.puzzle == game.puzzle and type(saved.guesses) == "table" then
        game.hard = saved.hard and true or nil
        for _, g in ipairs(saved.guesses) do ns.submitGuess(game, g, true) end
    end
    ns.onGameFinished = hooks
    return game
end

---------------------------------------------------------------------------
-- Share text
---------------------------------------------------------------------------

local EMOJI = { [CORRECT] = "\240\159\159\169", [PRESENT] = "\240\159\159\168", [ABSENT] = "\226\172\155" }
-- Raid target icons render in chat: green triangle, yellow star, silver moon.
local RAID_ICON = { [CORRECT] = "{rt4}", [PRESENT] = "{rt1}", [ABSENT] = "{rt5}" }

local function header(game)
    local title = game.mode == "daily" and ("Azerdle #" .. game.puzzle) or "Azerdle (practice)"
    -- Wordle's convention: a trailing * marks a hard-mode game.
    return title .. " " .. (game.won and #game.guesses or "X") .. "/" .. ns.MAX_GUESSES .. (game.hard and "*" or "")
end

-- style "emoji": multi-line grid for pasting outside the game (Discord etc.).
-- style "chat": one line with raid icons for WoW chat (fits the 255-character chat limit).
function ns.shareText(game, style)
    local rows = {}
    local map = style == "chat" and RAID_ICON or EMOJI
    for gi, result in ipairs(game.results) do
        local cells = {}
        for i = 1, #result do cells[i] = map[result[i]] end
        rows[gi] = table.concat(cells)
    end
    if style == "chat" then return header(game) .. ": " .. table.concat(rows, " ") end
    return header(game) .. "\n\n" .. table.concat(rows, "\n")
end
