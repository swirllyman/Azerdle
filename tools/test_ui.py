"""Smoke test for WordOfWarcraft/UI.lua: drives the fake client like a player (typing through the invisible
EditBox's scripts and clicking on-screen keyboard buttons), and checks the tile grid, keyboard colouring, toasts,
win/loss flavour text, stats recording, sharing, and save/restore across a simulated reload.

    pip install lupa
    python tools/test_ui.py
"""
import sys

from fakewow import Client

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)]


def lua_dict(t):
    return dict(t.items()) if t is not None else {}


def to_python(v):
    """Recursively converts a Lua table (array- or map-shaped) into plain Python, so it can be compared or
    copied into another Client's separate Lua runtime (table_from can't mix objects across runtimes)."""
    if hasattr(v, "items"):
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_python(v[i]) for i in range(1, len(keys) + 1)]
        return {k: to_python(val) for k, val in v.items()}
    return v


def all_errors(c):
    """Broader than Client.errors(): safe here since this test never runs the probe's API-discovery
    (which deliberately logs "ERROR" for missing APIs as normal output)."""
    return [l for l in c.log() if "ERROR" in l]


def type_word(ui, word):
    eb = ui.editBox
    for ch in word:
        eb.scripts["OnChar"](eb, ch.lower())
    eb.scripts["OnEnterPressed"](eb)


def backspace(ui):
    eb = ui.editBox
    eb.scripts["OnKeyDown"](eb, "BACKSPACE")


def clear_row(ui):
    """Backspaces out whatever's typed but unsubmitted (e.g. after a rejected invalid guess), the way a
    player would before retyping."""
    while ui.curText:
        backspace(ui)


def click(btn):
    btn.scripts["OnClick"](btn)


def tile_fill(ui, row, col):
    t = ui.tiles[row][col]
    return list(t.fill.color.values()) if t.fill.color else None


def tile_text(ui, row, col):
    return ui.tiles[row][col].text.text or ""


def new_client():
    c = Client()
    return c, c.ns, c.ns._ui


def test_open_close_and_typing():
    c, ns, ui = new_client()
    check(not ui.frame.IsShown(ui.frame), "window starts closed")
    c.slash("")
    check(ui.frame.IsShown(ui.frame), "/wow opens the window")
    check(ui.editBox.focused, "editbox focused on open")
    check(ui.hintText.shownFlag, "typing hint shown while focused")

    answer = ui.dailyGame.answer
    wrong = "STARE" if answer != "STARE" else "CRANE"
    type_word(ui, wrong)
    c.advance(2)
    check(lua_list(ui.dailyGame.guesses) == [wrong], "typed guess accepted and submitted")
    for i in range(1, 6):
        check(tile_text(ui, 1, i) == wrong[i - 1], "row 1 tile %d shows %s" % (i, wrong[i - 1]))
    check(not any(ns.isSecret(v) for v in []), "sanity: isSecret available")

    # Backspace + retype before submitting a fresh row.
    for ch in "AB":
        ui.editBox.scripts["OnChar"](ui.editBox, ch.lower())
    backspace(ui)
    check(ui.curText == "A", "backspace removes the last typed letter")
    check(not c.errors() and not all_errors(c), "no Lua errors so far")


def test_toasts_and_win():
    c, ns, ui = new_client()
    c.slash("")
    answer = ui.dailyGame.answer

    type_word(ui, "AB")
    check(ui.messageText.text == "Not enough letters", "short guess toasts")

    type_word(ui, "ZZZZZ")
    check(ui.messageText.text == "Not in word list", "gibberish guess toasts (invalid word)")
    check(len(lua_list(ui.dailyGame.guesses)) == 0, "rejected guesses use no row")
    clear_row(ui)   # a rejected guess stays typed (like real Wordle) until backspaced or overwritten

    # Win on the first guess for a deterministic "Legendary!" quality message.
    type_word(ui, answer)
    c.advance(2)
    game = ui.dailyGame
    check(game.done and game.won, "typing the answer wins the game")
    check("Legendary" in (ui.messageText.text or ""), "1-guess win shows Legendary praise: %r" % ui.messageText.text)
    check("ff8000" in ui.messageText.text, "Legendary praise uses the orange legendary colour")
    for i in range(1, 6):
        check(tile_fill(ui, 1, i)[:3] == [0.42, 0.67, 0.39], "winning row tile %d is green" % i)
    states = lua_dict(ns.letterStates(game))
    for i, ch in enumerate(answer):
        btn = ui.keyButtons[ch]
        c_ = list(btn.bg.color.values())[:3]
        check(c_ == [0.42, 0.67, 0.39], "keyboard key %s coloured green after the win" % ch)
    check(not c.errors() and not all_errors(c), "no Lua errors after a win")


def test_loss_message():
    c, ns, ui = new_client()
    c.slash("")
    answer = ui.dailyGame.answer
    wrong = "CRANE" if answer != "CRANE" else "STARE"
    for _ in range(6):
        type_word(ui, wrong)
        c.advance(2)
    game = ui.dailyGame
    check(game.done and not game.won, "six misses lose the game")
    check(ui.messageText.text == "The word was " + answer, "loss message reveals the answer")
    check(not c.errors() and not all_errors(c), "no Lua errors after a loss")


def test_keyboard_never_downgrades():
    c, ns, ui = new_client()
    c.slash("")
    answer = ui.dailyGame.answer
    other = "CRANE" if answer != "CRANE" else "STARE"
    # Guess something sharing a letter with the answer at a wrong spot first (present/absent), then win, and
    # make sure the letter ends up green, never falling back to yellow/grey.
    type_word(ui, other)
    c.advance(2)
    type_word(ui, answer)
    c.advance(2)
    for ch in answer:
        c_ = list(ui.keyButtons[ch].bg.color.values())[:3]
        check(c_ == [0.42, 0.67, 0.39], "key %s is green (never downgraded) after winning" % ch)


def test_practice_mode_no_stats():
    c, ns, ui = new_client()
    c.slash("")
    stats_before = to_python(ns.cdb.stats)
    c.slash("practice")
    check(ui.mode == "practice", "/wow practice switches to practice mode")
    check(ui.frame.IsShown(ui.frame), "/wow practice opens the window")
    practice_answer = ui.practiceGame.answer
    type_word(ui, practice_answer)
    c.advance(2)
    check(ui.practiceGame.done and ui.practiceGame.won, "practice game can be won")
    check(to_python(ns.cdb.stats) == stats_before, "practice games never touch stats")
    check(ui.dailyGame.done is False or ui.dailyGame.mode == "daily", "daily game untouched by practice")

    click(ui.dailyBtn)
    check(ui.mode == "daily", "Back to Daily button returns to daily mode")
    click(ui.practiceBtn)
    check(ui.mode == "practice", "Practice button switches back to practice with a new word")
    check(not c.errors() and not all_errors(c), "no Lua errors in practice flow")


def test_stats_panel_and_share():
    c, ns, ui = new_client()
    c.slash("")
    answer = ui.dailyGame.answer
    type_word(ui, answer)
    c.advance(0.3)   # tile reveal only, before the 1.5s auto-open
    check(not ui.statsPanel.IsShown(ui.statsPanel), "stats panel not yet auto-opened right after winning")
    c.advance(2)
    check(ui.statsPanel.IsShown(ui.statsPanel), "stats panel auto-opens ~1.5s after a finished daily game")
    check(ui.copyBtn.IsShown(ui.copyBtn) and ui.postBtn.IsShown(ui.postBtn),
          "copy/post buttons show once today's daily game is done")

    click(ui.copyBtn)
    check(ui.shareBox.IsShown(ui.shareBox), "Copy result reveals the share box")
    check(ui.shareBox.text == ns.shareText(ui.dailyGame, "emoji"), "share box holds the emoji share text")

    c.set_guild(True)
    c.set_group(False)
    click(ui.postBtn)
    sent = c.sent_chat()
    check(len(sent) == 1 and sent[0]["channel"] == "GUILD", "Post to chat sends once to GUILD when in a guild")
    check("{rt4}" in sent[0]["text"], "chat share text uses raid-icon markup")

    c.set_guild(False)
    c.set_group(True)
    click(ui.postBtn)
    sent = c.sent_chat()
    check(len(sent) == 1 and sent[0]["channel"] == "PARTY", "falls back to PARTY when not in a guild")

    c.set_guild(False)
    c.set_group(False)
    click(ui.postBtn)
    check(not c.sent_chat(), "no message sent with no guild or group")
    check(any("No guild or group" in l for l in c.chat()), "prints a message when there's nowhere to post")

    stats = lua_dict(ns.cdb.stats)
    check(stats["played"] == 1 and stats["wins"] == 1, "stats recorded once for the finished daily game")
    click(ui.statsBtn)   # toggles the panel closed
    check(not ui.statsPanel.IsShown(ui.statsPanel), "Stats header button toggles the panel")
    check(not c.errors() and not all_errors(c), "no Lua errors in the stats/share flow")


def test_colorblind_toggle():
    c, ns, ui = new_client()
    c.slash("")
    answer = ui.dailyGame.answer
    type_word(ui, answer)
    c.advance(2)
    green_before = tile_fill(ui, 1, 1)[:3]
    check(green_before == [0.42, 0.67, 0.39], "normal correct colour before toggling colourblind mode")

    c.slash("colorblind")
    check(ns.opt("colorblind") is True and ns.db.options.colorblind is True, "/wow colorblind toggles the saved option")
    check(tile_fill(ui, 1, 1)[:3] == [0.96, 0.47, 0.24], "colourblind mode recolours correct tiles orange")
    for ch in answer:
        c_ = list(ui.keyButtons[ch].bg.color.values())[:3]
        check(c_ == [0.96, 0.47, 0.24], "colourblind mode recolours the keyboard too")

    c.slash("colorblind")
    check(ns.opt("colorblind") is False and ns.db.options.colorblind is None, "toggling again reverts (default not stored)")
    check(not c.errors() and not all_errors(c), "no Lua errors while toggling colourblind mode")


def test_reload_restores_daily_progress():
    c1, ns1, ui1 = new_client()
    c1.slash("")
    answer = ui1.dailyGame.answer
    wrong = "STARE" if answer != "STARE" else "CRANE"
    type_word(ui1, wrong)
    c1.advance(2)
    saved_char_db = to_python(c1.lua.globals().WordOfWarcraftCharDB)

    c2 = Client()
    c2.lua.globals().WordOfWarcraftCharDB = c2.lua.table_from(saved_char_db, recursive=True)
    # Re-run the ADDON_LOADED handlers so ui.onLoaded restores from the (now pre-populated) char DB.
    c2.fire("ADDON_LOADED", "WordOfWarcraft")
    ns2, ui2 = c2.ns, c2.ns._ui
    check(lua_list(ui2.dailyGame.guesses) == [wrong], "reload restores today's saved guess")
    check(tile_text(ui2, 1, 1) == wrong[0], "restored guess is painted into the grid without opening the window")
    check(not c2.errors() and not all_errors(c2), "no Lua errors restoring from a reload")


def test_day_rollover_gives_a_new_game():
    c, ns, ui = new_client()
    # The fake's default clock is before ns.EPOCH (puzzle numbers clamp to 1 until then); move it just past
    # the epoch so a one-day advance lands on a real puzzle #2 instead of clamping back to #1.
    c.lua.globals().serverNow = ns.EPOCH + 100
    c.slash("")
    puzzle1 = ui.dailyGame.puzzle
    type_word(ui, "STARE" if ui.dailyGame.answer != "STARE" else "CRANE")
    c.advance(2)
    frame = c.frame("WordOfWarcraftFrame")
    frame.Hide(frame)

    c.advance(86400 + 5)   # past UTC midnight
    c.slash("")   # reopening re-checks rollover
    check(ui.dailyGame.puzzle == puzzle1 + 1, "a new day gives a new puzzle number")
    check(len(lua_list(ui.dailyGame.guesses)) == 0, "the new day's game starts fresh")
    check(tile_text(ui, 1, 1) == "", "grid is cleared for the new day")
    check(not c.errors() and not all_errors(c), "no Lua errors across day rollover")


def test_reveal_does_not_paint_over_a_new_board():
    c, ns, ui = new_client()
    c.slash("")
    answer = ui.dailyGame.answer
    wrong = next(w for w in ("CRANE", "STARE", "DRUID") if w != answer and ns.isValidGuess(w))
    type_word(ui, wrong)
    c.advance(0.2)                 # first tiles revealed, the rest still pending
    click(ui.practiceBtn)          # switch boards mid-reveal
    c.advance(3)
    check(tile_text(ui, 1, 5) == "", "pending reveal doesn't paint the daily guess onto the practice board")
    check(not ui.statsPanel.IsShown(ui.statsPanel), "no stats pop-up from a stale reveal")
    click(ui.dailyBtn)
    check(tile_text(ui, 1, 5) == wrong[4], "daily board still shows the guess when switching back")
    check(not c.errors() and not all_errors(c), "no Lua errors switching mid-reveal")


def test_share_box_gives_keyboard_back():
    c, ns, ui = new_client()
    c.slash("")
    type_word(ui, ui.dailyGame.answer)
    c.advance(3)
    click(ui.copyBtn)
    box = ui.shareBox
    check(box.IsShown(box) and box.text.startswith("Word of Warcraft #"), "copy box shows the share text")
    box.scripts["OnTextChanged"](box, True)
    box.text = "edited"
    box.scripts["OnTextChanged"](box, True)
    check(box.text.startswith("Word of Warcraft #"), "copy box is read-only")
    box.scripts["OnEscapePressed"](box)
    check(not box.IsShown(box) and ui.editBox.focused, "Esc in the copy box hands the keyboard back to the game")
    check(not c.errors() and not all_errors(c), "no Lua errors in the copy box")


def same(c, a, b):
    """Lua identity: lupa hands out a new proxy per access, so Python's `is` / `==` can't compare tables."""
    return c.lua.eval("rawequal")(a, b)


def opt_widget(c, key):
    return c.ns._options.widgets[key]


def test_options_window_and_set():
    c, ns, ui = new_client()
    opts = ns._options
    dialog = c.frame("WordOfWarcraftOptionsFrame")
    check(not dialog.IsShown(dialog), "options window starts closed")
    c.slash("options")
    check(dialog.IsShown(dialog) and opts.content.IsShown(opts.content), "/wow options opens the options window")
    check(same(c, opts.content.GetPoint(opts.content)[1], dialog), "option rows live in the options window")
    for s in lua_list(opts.SPEC):
        if s.key:
            check(opts.widgets[s.key] is not None, "widget for option %s" % s.key)
    cats = lua_list(c.lua.globals().settingsCategories)
    check(len(cats) == 1 and cats[0].name == "Word of Warcraft", "page registered in Settings > AddOns")

    # The Settings page borrows the same rows.
    canvas = cats[0].frame
    canvas.shownFlag = False
    canvas.Show(canvas)
    check(same(c, opts.content.GetPoint(opts.content)[1], canvas) and not dialog.IsShown(dialog),
          "opening the Settings page moves the rows there")
    click(ui.optionsBtn)
    check(dialog.IsShown(dialog) and same(c, opts.content.GetPoint(opts.content)[1], dialog),
          "the gear button opens the options window and takes the rows back")

    # Clicking widgets.
    w = opt_widget(c, "colorblind")
    click(w)
    check(ns.opt("colorblind") is True and w.check.shownFlag, "clicking a toggle row flips it and ticks the box")
    w = opt_widget(c, "scale")
    click(w.right)
    check(ns.opt("scale") == 1.05 and w.value.text.text == "105%", "scale stepper goes up by 5%")
    for _ in range(30):
        click(w.right)
    check(ns.opt("scale") == 1.5, "scale stops at 150%")
    w = opt_widget(c, "revealSpeed")
    click(w.value)
    check(ns.opt("revealSpeed") == "slow", "clicking a choice's value steps it: %s" % ns.opt("revealSpeed"))
    click(w.right)
    check(ns.opt("revealSpeed") == "off", "choices wrap around")
    w = opt_widget(c, "keySounds")
    check(w.label.textColor[1] == 1, "key sounds row bright while sounds are on")
    click(opt_widget(c, "sounds"))
    check(w.label.textColor[1] == 0.5, "key sounds row dims when sounds are off")

    # /wow set
    c.slash("set")
    check(any("scale = 150%" in l for l in c.chat()), "/wow set lists options with values")
    c.slash("set scale 0.8")
    check(ns.opt("scale") == 0.8, "/wow set scale 0.8")
    c.slash("set opacity 50%")
    check(ns.opt("opacity") == 0.5, "/wow set opacity 50%")
    c.slash("set keyboardlayout azerty")
    check(ns.opt("keyboardLayout") == "azerty", "/wow set is case-insensitive for names")
    c.slash("set hardMode")
    check(ns.opt("hardMode") is True, "/wow set <toggle> flips it")
    c.slash("set postChannel nowhere")
    check(ns.opt("postChannel") == "auto" and any("use one of" in l for l in c.chat()), "bad choice rejected")
    c.slash("set nonsense 1")
    check(any("no option called nonsense" in l for l in c.chat()), "unknown option reported")

    click(opts.defaultsBtn)
    check(len(dict(ns.db.options.items())) == 0 and ns.opt("scale") == 1, "Restore defaults clears every option")
    check(not c.errors() and not all_errors(c), "no Lua errors in the options window")


def test_instant_reveal_and_sounds():
    c, ns, ui = new_client()
    g = c.lua.globals()
    ns.setOpt("revealSpeed", "off")
    c.slash("")
    check(850 in lua_list(g.sounds), "opening plays a sound")
    answer = ui.dailyGame.answer
    wrong = "STARE" if answer != "STARE" else "CRANE"
    type_word(ui, wrong)
    check(tile_text(ui, 1, 5) == wrong[4], "instant reveal paints the whole row at once")
    check(1115 not in lua_list(g.sounds), "no key clicks by default")
    type_word(ui, "ZZZZZ")
    check(857 in lua_list(g.sounds), "rejected guess plays the error sound")
    clear_row(ui)
    ns.setOpt("keySounds", True)
    type_word(ui, answer)
    check(1115 in lua_list(g.sounds) and 878 in lua_list(g.sounds), "key clicks and win sound")

    ns.setOpt("sounds", False)
    g.sounds = c.lua.table()
    c.frame("WordOfWarcraftFrame").Hide(c.frame("WordOfWarcraftFrame"))
    check(len(g.sounds) == 0, "sounds off silences everything")
    check(not c.errors() and not all_errors(c), "no Lua errors with instant reveal and sounds")


def test_hard_mode_in_window():
    c, ns, ui = new_client()
    ns.setOpt("hardMode", True)
    c.slash("")
    check("(Hard)" in ui.titleText.text, "title shows hard mode before the first guess")
    game = ui.dailyGame
    answers = lua_list(ns.ANSWERS)
    answer = game.answer
    # A first guess that reveals something, then a guess that ignores it.
    first = next(w for w in answers if w != answer and set(w) & set(answer))
    type_word(ui, first)
    c.advance(2)
    check(game.hard is True, "hard mode fixed on the game at its first guess")
    bad = next(w for w in answers if ns.hardModeError(game, w))
    type_word(ui, bad)
    check(ui.messageText.text == ns.hardModeError(game, bad), "breaking a hint toasts why: %s" % ui.messageText.text)
    check(len(lua_list(game.guesses)) == 1, "the rule-breaking guess uses no row")
    clear_row(ui)
    type_word(ui, answer)
    c.advance(3)
    check(ns.shareText(game, "chat").split(":")[0].endswith("*"), "hard-mode win shares with a *")
    check(ns.cdb.daily.hard is True, "hard flag saved with today's game")

    # Switching it on mid-game waits for the next game; switching it off applies at once.
    c2, ns2, ui2 = new_client()
    c2.slash("")
    type_word(ui2, first if first != ui2.dailyGame.answer else "STARE")
    c2.advance(2)
    ns2.setOpt("hardMode", True)
    check(not ui2.dailyGame.hard and "next game" in ui2.messageText.text, "hard mode waits for the next game")
    click(ui2.practiceBtn)
    check("(Hard)" in ui2.titleText.text, "a new practice game picks hard mode up")
    type_word(ui2, "STARE" if ui2.practiceGame.answer != "STARE" else "CRANE")
    ns2.setOpt("hardMode", False)
    check(not ui2.practiceGame.hard and "(Hard)" not in ui2.titleText.text, "switching off applies at once")
    check(not c.errors() and not all_errors(c) and not all_errors(c2), "no Lua errors in hard mode")


def test_keyboard_options():
    c, ns, ui = new_client()
    c.slash("")
    qwerty = ui.keyButtons
    answer = ui.dailyGame.answer
    type_word(ui, answer)
    c.advance(2)
    ns.setOpt("keyboardLayout", "azerty")
    check(not same(c, ui.keyButtons, qwerty) and len(dict(ui.keyButtons.items())) == 26, "AZERTY keyboard has 26 keys")
    check(not ui.keyboards["qwerty"].frame.shownFlag and ui.keyboards["azerty"].frame.shownFlag,
          "only the active keyboard is shown")
    check(list(ui.keyButtons[answer[0]].bg.color.values())[:3] == [0.42, 0.67, 0.39],
          "the new layout keeps the letter colours")
    ns.setOpt("swapEnter", True)
    check(ui.keyboards["azerty-swap"] is not None and ui.keyboards["azerty-swap"].frame.shownFlag,
          "swapping Enter/Backspace builds its own keyboard")
    ns.setOpt("keyboardLayout", "qwerty")
    ns.setOpt("swapEnter", False)
    check(same(c, ui.keyButtons, qwerty), "switching back reuses the first keyboard")
    check(not c.errors() and not all_errors(c), "no Lua errors switching keyboards")


def test_capture_and_hint_options():
    c, ns, ui = new_client()
    ns.setOpt("captureKeys", False)
    c.slash("")
    check(not ui.editBox.focused, "without auto-capture the window opens without taking the keyboard")
    ui.frame.scripts["OnMouseDown"](ui.frame)
    check(ui.editBox.focused and "release" in ui.hintText.text, "clicking the window takes the keyboard")
    ui.editBox.scripts["OnEscapePressed"](ui.editBox)
    check(ui.frame.shownFlag and not ui.editBox.focused, "Esc hands the keyboard back without closing")
    ns.setOpt("typingHint", False)
    ui.editBox.SetFocus(ui.editBox)
    check(not ui.hintText.shownFlag, "typing hint can be hidden")
    ns.setOpt("lockWindow", True)
    check(not c.errors() and not all_errors(c), "no Lua errors in capture options")


def test_post_and_stats_options():
    c, ns, ui = new_client()
    ns.setOpt("autoPost", True)
    ns.setOpt("autoStats", False)
    ns.setOpt("postChannel", "party")
    c.set_guild(True)
    c.set_group(True)
    c.slash("")
    type_word(ui, ui.dailyGame.answer)
    c.advance(3)
    sent = c.sent_chat()
    check(len(sent) == 1 and sent[0]["channel"] == "PARTY", "auto-post uses the chosen channel: %s" % sent)
    check(not ui.statsPanel.shownFlag, "stats panel stays closed with autoStats off")
    ns.setOpt("postChannel", "guild")
    c.set_guild(False)
    click(ui.postBtn)
    check(not c.sent_chat() and any("No guild to post" in l for l in c.chat()), "guild-only with no guild says so")
    check(not c.errors() and not all_errors(c), "no Lua errors posting")


def test_reset_stats_needs_two_clicks():
    c, ns, ui = new_client()
    c.slash("")
    type_word(ui, ui.dailyGame.answer)
    c.advance(3)
    btn = ns._options.resetStatsBtn
    click(btn)
    check(ns.cdb.stats.played == 1 and "Click again" in btn.label.text, "first click only asks for confirmation")
    c.advance(5)
    check(btn.label.text == "Reset statistics", "confirmation times out")
    click(btn)
    click(btn)
    check(ns.cdb.stats.played == 0 and ui.dailyGame.done, "second click resets stats, today's game stays")
    check(not c.errors() and not all_errors(c), "no Lua errors resetting stats")


def test_minimap_button():
    c, ns, ui = new_client()
    b = c.frame("WordOfWarcraftMinimapButton")
    check(b is not None and b.shownFlag, "minimap button shown by default")
    check(same(c, b.GetPoint(b)[1], c.lua.globals().Minimap), "button sits on the minimap")
    b.scripts["OnClick"](b, "LeftButton")
    check(ui.frame.shownFlag, "left-click opens the game")
    b.scripts["OnClick"](b, "RightButton")
    check(c.frame("WordOfWarcraftOptionsFrame").shownFlag, "right-click opens the options")
    ns.setOpt("minimapButton", False)
    check(not b.shownFlag, "minimap button can be hidden")
    c.lua.globals().WordOfWarcraft_OnCompartmentClick("WordOfWarcraft", "RightButton")
    check(not c.frame("WordOfWarcraftOptionsFrame").shownFlag, "addon compartment right-click toggles options")
    check(not c.errors() and not all_errors(c), "no Lua errors with the minimap button")


def test_old_settings_migrate():
    c = Client()
    g = c.lua.globals()
    g.WordOfWarcraftCharDB = c.lua.table_from({"colorblind": True})
    g.WordOfWarcraftDB = c.lua.table_from({"scale": 1.2})
    c.fire("ADDON_LOADED", "WordOfWarcraft")
    ns = c.ns
    check(ns.opt("colorblind") is True and ns.cdb.colorblind is None, "per-character colourblind moves to options")
    check(ns.opt("scale") == 1.2 and ns.db.scale is None, "old window scale moves to options")


def test_reminder_options():
    c, ns, ui = new_client()
    ns.setOpt("loginReminder", False)
    c.advance(4)
    check(not any("is ready" in l for l in c.chat()), "login reminder can be switched off")

    c2, ns2, ui2 = new_client()
    c2.lua.globals().serverNow = ns2.EPOCH + 100
    c2.advance(4)
    check(any("is ready" in l for l in c2.chat()), "login reminder on by default")
    c2.advance(86400)
    check(any("A new word is out" in l for l in c2.chat()) and ui2.dailyGame.puzzle == 2,
          "a new word is announced at midnight and loaded")
    check(not c.errors() and not all_errors(c2), "no Lua errors in reminders")


if __name__ == "__main__":
    test_options_window_and_set()
    test_instant_reveal_and_sounds()
    test_hard_mode_in_window()
    test_keyboard_options()
    test_capture_and_hint_options()
    test_post_and_stats_options()
    test_reset_stats_needs_two_clicks()
    test_minimap_button()
    test_old_settings_migrate()
    test_reminder_options()
    test_reveal_does_not_paint_over_a_new_board()
    test_share_box_gives_keyboard_back()
    test_open_close_and_typing()
    test_toasts_and_win()
    test_loss_message()
    test_keyboard_never_downgrades()
    test_practice_mode_no_stats()
    test_stats_panel_and_share()
    test_colorblind_toggle()
    test_reload_restores_daily_progress()
    test_day_rollover_gives_a_new_game()
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all UI tests passed")
