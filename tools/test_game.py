"""Unit tests for the game logic in Azerdle/Game.lua (scoring, repeated letters, daily word pick, stats,
save/restore, share text), run in real Lua via lupa, plus sanity checks on the generated Words.lua.

    pip install lupa
    python tools/test_game.py
"""
import os
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "Azerdle")
EPOCH = 1790553600
DAY = 86400

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


def load(words_lua=None):
    """Lua runtime with Game.lua loaded. words_lua: Lua source defining ns.ANSWERS / ns.GUESSES."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("serverNow = %d; function GetServerTime() return serverNow end" % EPOCH)
    ns = lua.table()
    loader = lua.eval("function(src, name, ns) local f = assert(load(src, name)); f('Azerdle', ns) end")
    if words_lua is None:
        words_lua = ('local _, ns = ...\nns.ANSWERS = {"DRUID", "GHOUL", "TOTEM", "ABBEY", "SPEED"}\n'
                     'ns.GUESSES = [[CRANE KEBAB EERIE HELLO LEVEL FLOOR ROBOT STARE]]')
    loader(words_lua, "@Words.lua", ns)
    with open(os.path.join(ADDON, "Game.lua"), encoding="utf-8") as fh:
        loader(fh.read(), "@Game.lua", ns)
    return lua, ns


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)]


def score(ns, guess, answer):
    names = {0: "-", 1: "Y", 2: "G"}
    return "".join(names[v] for v in lua_list(ns.score(guess, answer)))


def test_scoring():
    lua, ns = load()
    cases = [
        ("CRANE", "CRANE", "GGGGG"),
        ("STARE", "DRUID", "---Y-"),
        # Repeated letters in the guess, fewer in the answer.
        ("EERIE", "SPEED", "YY---"),   # two E's in the answer, three in the guess: the third stays grey
        ("KEBAB", "ABBEY", "-YGYY"),   # the green B uses one B, the other B is yellow
        ("FLOOR", "ROBOT", "--YGY"),   # green O first, then one yellow O
        ("HELLO", "LEVEL", "-GYY-"),
        # Green takes priority even when the yellow copy comes first.
        ("EERIE", "THEME", "Y---G"),   # answer's 2nd E is green at the end; the 1st E makes only one yellow
        ("LLAMA", "HELLO", "YY---"),
        ("SPEED", "ABIDE", "--Y-Y"),
        ("ALLOY", "LOYAL", "YYYYY"),
        ("ABBBB", "BABBB", "YYGGG"),
        ("BBBBB", "ABBEY", "-GG--"),
        ("crane", "CRANE", "GGGGG"),   # case-insensitive
    ]
    for guess, answer, want in cases:
        got = score(ns, guess, answer)
        check(got == want, "score %s vs %s = %s (want %s)" % (guess, answer, got, want))


def test_days():
    lua, ns = load()
    check(ns.puzzleNumber(EPOCH) == 1, "epoch is puzzle #1")
    check(ns.puzzleNumber(EPOCH + DAY - 1) == 1, "last second of day 1 is still #1")
    check(ns.puzzleNumber(EPOCH + DAY) == 2, "UTC midnight starts #2")
    check(ns.puzzleNumber(EPOCH - 5 * DAY) == 1, "clock before the epoch clamps to #1")
    check(ns.puzzleNumber(EPOCH + 400 * DAY + 3600) == 401, "day 401")
    check(ns.secondsUntilNextPuzzle(EPOCH + DAY - 10) == 10, "countdown to next puzzle")
    check(ns.secondsUntilNextPuzzle(EPOCH) == DAY, "countdown at midnight is a full day")
    words = [ns.dailyWord(n) for n in range(1, 8)]
    check(words == ["DRUID", "GHOUL", "TOTEM", "ABBEY", "SPEED", "DRUID", "GHOUL"],
          "daily word follows list order and wraps: %s" % words)
    # Appending answers must not change any earlier day.
    lua2, ns2 = load('local _, ns = ...\nns.ANSWERS = {"DRUID", "GHOUL", "TOTEM", "ABBEY", "SPEED", "FLASK"}\n'
                     'ns.GUESSES = ""')
    check(all(ns.dailyWord(n) == ns2.dailyWord(n) for n in range(1, 6)), "appending answers keeps earlier days")
    lua.execute("serverNow = %d" % (EPOCH + 2 * DAY + 5))
    check(ns.todayPuzzle() == 3 and ns.newGame("daily").answer == "TOTEM", "today's game uses GetServerTime")


def test_game_flow():
    lua, ns = load()
    finished = []
    ns.onGameFinished[1] = lambda game: finished.append(game.won)
    game = ns.newGame("daily", 1)   # DRUID
    ok, reason = ns.submitGuess(game, "CRAN")
    check(not ok and reason == "short", "4 letters rejected as short")
    ok, reason = ns.submitGuess(game, "XQZVW")
    check(not ok and reason == "invalid", "non-word rejected as invalid")
    ok, reason = ns.submitGuess(game, "CR4NE")
    check(not ok and reason == "short", "non-letters rejected")
    check(len(game.guesses) == 0, "rejected guesses don't use a row")
    ok, _ = ns.submitGuess(game, "crane")
    check(ok and game.guesses[1] == "CRANE", "valid guess accepted and upper-cased")
    ok, _ = ns.submitGuess(game, "ghoul")
    check(ok, "answers are valid guesses")
    states = ns.letterStates(game)
    check(states["R"] == 2 and states["U"] == 1 and states["C"] == 0, "keyboard letter states")
    ok, _ = ns.submitGuess(game, "DRUID")
    check(ok and game.done and game.won and finished == [True], "winning guess ends the game, hook fires once")
    ok, reason = ns.submitGuess(game, "CRANE")
    check(not ok and reason == "done", "no guesses after the end")

    lost = ns.newGame("daily", 2)   # GHOUL
    for _ in range(6):
        ns.submitGuess(lost, "CRANE")
    check(lost.done and not lost.won and len(lost.guesses) == 6, "six misses lose")
    check(finished == [True, False], "hook fires on a loss too")

    practice = ns.newGame("practice")
    check(practice.answer != ns.dailyWord(ns.todayPuzzle()), "practice word differs from today's")


def test_hard_mode():
    lua, ns = load('local _, ns = ...\nns.ANSWERS = {"SPEED"}\nns.GUESSES = [[STARE SLOTH SHEEP EERIE DRUID]]')
    game = ns.newGame("daily", 1)   # SPEED
    game.hard = True
    ok, _ = ns.submitGuess(game, "STARE")   # S green, E yellow
    check(ok, "hard mode: first guess is free")
    ok, reason, msg = ns.submitGuess(game, "DRUID")
    check(not ok and reason == "hard" and msg == "1st letter must be S", "hard mode keeps greens: %s" % msg)
    ok, reason, msg = ns.submitGuess(game, "SLOTH")
    check(not ok and reason == "hard" and msg == "Guess must contain E", "hard mode needs yellows: %s" % msg)
    check(len(game.guesses) == 1, "hard-mode rejections use no row")
    ok, _ = ns.submitGuess(game, "SHEEP")
    check(ok, "a guess using every hint is accepted")

    # Two yellow E's mean the next guess needs two E's.
    game = ns.newGame("daily", 1)
    game.hard = True
    ns.submitGuess(game, "EERIE")   # YY--- : two E's hinted, the third grey
    ok, reason, msg = ns.submitGuess(game, "STARE")
    check(not ok and msg == "Guess must contain E", "hard mode counts repeated hints")
    ok, _ = ns.submitGuess(game, "SHEEP")
    check(ok, "two E's satisfy two E hints")

    easy = ns.newGame("daily", 1)
    ns.submitGuess(easy, "STARE")
    ok, _ = ns.submitGuess(easy, "DRUID")
    check(ok, "without hard mode anything valid goes")

    # Saved and restored with the flag; replay never re-checks the rules.
    hard = ns.newGame("daily", 1)
    hard.hard = True
    ns.submitGuess(hard, "STARE")
    saved = ns.saveDaily(hard)
    check(saved.hard is True, "hard flag saved")
    saved.guesses[2] = "DRUID"   # would break the rules if checked
    restored = ns.restoreDaily(saved)
    check(restored.hard is True and len(restored.guesses) == 2, "restore keeps hard mode and skips its checks")
    ns.submitGuess(restored, "SPEED")
    check(ns.shareText(restored, "chat").startswith("Azerdle #1 3/6*"), "hard-mode share text ends in *")
    check(ns.saveDaily(easy).hard is None, "normal games don't save a hard flag")


def test_stats():
    lua, ns = load()
    stats = ns.newStats()

    def play(puzzle, guesses_to_win):
        game = ns.newGame("daily", puzzle)
        wrong = "CRANE" if game.answer != "CRANE" else "STARE"
        for _ in range((guesses_to_win or 6 + 1) - 1):
            if not game.done:
                ns.submitGuess(game, wrong)
        if guesses_to_win and not game.done:
            ns.submitGuess(game, game.answer)
        return ns.recordResult(stats, game)

    play(1, 3)
    play(2, 1)
    check(stats.streak == 2 and stats.maxStreak == 2 and stats.wins == 2, "consecutive wins build a streak")
    check(not play(2, 4), "the same puzzle only counts once")
    check(stats.played == 2, "played unchanged by a repeat")
    play(4, 2)
    check(stats.streak == 1 and stats.maxStreak == 2, "skipping a day restarts the streak")
    play(5, None)
    check(stats.streak == 0 and stats.played == 4 and stats.wins == 3, "a loss breaks the streak")
    check(stats.dist[1] == 1 and stats.dist[2] == 1 and stats.dist[3] == 1, "guess distribution")
    check(ns.winPercent(stats) == 75, "win percent")
    play(6, 5)
    check(ns.currentStreak(stats, 7) == 1, "streak still alive the next day")
    check(ns.currentStreak(stats, 8) == 0, "streak shown as broken after a missed day")
    practice = ns.newGame("practice")
    ns.submitGuess(practice, practice.answer)
    check(not ns.recordResult(stats, practice), "practice games don't count")


def test_save_restore():
    lua, ns = load()
    lua.execute("serverNow = %d" % (EPOCH + 3 * DAY))   # puzzle 4: ABBEY
    game = ns.newGame("daily")
    ns.submitGuess(game, "KEBAB")
    ns.submitGuess(game, "CRANE")
    saved = ns.saveDaily(game)
    fired = []
    ns.onGameFinished[1] = lambda g: fired.append(1)
    back = ns.restoreDaily(saved)
    check(lua_list(back.guesses) == ["KEBAB", "CRANE"] and back.puzzle == 4, "restore replays saved guesses")
    check(score(ns, "KEBAB", "ABBEY") == "".join({0: "-", 1: "Y", 2: "G"}[v] for v in lua_list(back.results[1])),
          "restored results recomputed")
    ns.submitGuess(back, "ABBEY")
    check(back.won and fired == [1], "restored game continues and fires the hook on finishing")
    finished = ns.saveDaily(back)
    again = ns.restoreDaily(finished)
    check(again.done and again.won and fired == [1], "restoring a finished game doesn't fire the hook again")
    lua.execute("serverNow = %d" % (EPOCH + 4 * DAY))
    fresh = ns.restoreDaily(finished)
    check(len(fresh.guesses) == 0 and fresh.puzzle == 5, "yesterday's save gives a fresh game")
    check(len(ns.restoreDaily(None).guesses) == 0, "no save gives a fresh game")
    lua.execute("serverNow = %d" % (EPOCH + 3 * DAY))
    odd = ns.restoreDaily(lua.eval('{ puzzle = 4, guesses = { "ZZZZZ" } }'))
    check(len(odd.guesses) == 1, "saved guesses replay even if no longer in the word list")


def test_share():
    lua, ns = load()
    game = ns.newGame("daily", 4)   # ABBEY
    ns.submitGuess(game, "KEBAB")
    ns.submitGuess(game, "ABBEY")
    emoji = ns.shareText(game, "emoji")
    check(emoji == "Azerdle #4 2/6\n\n⬛\U0001f7e8\U0001f7e9\U0001f7e8\U0001f7e8\n" + "\U0001f7e9" * 5,
          "emoji share text: %r" % emoji)
    chat = ns.shareText(game, "chat")
    check(chat == "Azerdle #4 2/6: {rt5}{rt1}{rt4}{rt1}{rt1} " + "{rt4}" * 5, "chat share text")
    lost = ns.newGame("daily", 5)
    for _ in range(6):
        ns.submitGuess(lost, "CRANE")
    chat = ns.shareText(lost, "chat")
    check(chat.startswith("Azerdle #5 X/6") and len(chat.encode()) <= 255, "loss share fits chat limit")
    check("SPEED" not in ns.shareText(lost, "emoji"), "share text never contains the answer")


def test_real_words():
    path = os.path.join(ADDON, "Words.lua")
    if not os.path.exists(path):
        print("skip real Words.lua checks (not generated yet)")
        return
    with open(path, encoding="utf-8") as fh:
        lua, ns = load(fh.read())
    answers = lua_list(ns.ANSWERS)
    check(len(answers) >= 200, "enough answers to launch (%d)" % len(answers))
    check(len(set(answers)) == len(answers), "no duplicate answers")
    check(all(len(w) == 5 and w.isalpha() and w.isupper() for w in answers), "answers are 5 letters A-Z")
    check(all(ns.isValidGuess(w) for w in answers), "every answer is a valid guess")
    for w in ("CRANE", "stare", "Adieu", "ARISE"):
        check(ns.isValidGuess(w), "common English guess %s accepted" % w)
    check(not ns.isValidGuess("XQZVW") and not ns.isValidGuess("AEIOU"), "gibberish rejected")
    blocklist = os.path.join(HERE, "data", "blocklist.txt")
    if os.path.exists(blocklist):
        with open(blocklist, encoding="utf-8") as fh:
            blocked = [l.split("#")[0].strip() for l in fh if l.split("#")[0].strip()]
        check(not any(ns.isValidGuess(w) for w in blocked), "blocklisted words rejected")
    check(max(ns.puzzleNumber(EPOCH + d * DAY) for d in range(0, 3)) == 3, "puzzle numbers advance")


if __name__ == "__main__":
    test_scoring()
    test_days()
    test_game_flow()
    test_hard_mode()
    test_stats()
    test_save_restore()
    test_share()
    test_real_words()
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all game tests passed")
