# Word length: 5 letters

Decided 2026-09-28. The code is length-agnostic (`ns.WORD_LENGTH`, grid built from it), so this can be revisited.

## Pool sizes

| Length | Valid English guesses (wordfreq, Zipf >= 2.0) | Strong Warcraft answers (estimate) | Examples |
|---|---|---|---|
| 4 | 7,642 | ~60, mostly generic | WISP, BOAR, OGRE, LICH, MANA, RUNE, NAGA |
| 5 | 10,640 | ~230 curated (answers.txt), ~40% WoW-specific | DRUID, ROGUE, GNOME, UTHER, JAINA, GHOUL, TOTEM, GNOLL, NINJA, GREED |
| 6 | 13,199 | ~120-160, the most iconic names | THRALL, ARTHAS, MURLOC, TAUREN, SHAMAN, ONYXIA, HOGGER, KOBOLD |
| 7 | 13,480 | ~60-90 | WARLOCK, PALADIN, ILLIDAN, DUROTAR, TANARIS, ALTERAC |

Every length from 5 up has plenty of valid guesses, so the guess list doesn't decide it. The answer pool does.

## Why 5

- **It's the game people know.** 6 tries at 5 letters is the difficulty players already have a feel for, and
  share grids look familiar.
- **Biggest answer pool at our quality bar.** 5-letter answers mix WoW-specific words (classes, races, lore
  names, spells, player slang) with generic fantasy words that have an obvious WoW meaning (FROST, TOTEM, FLASK).
  That gives ~230 answers after hand-curation, about 7-8 months of dailies, and room to append more.
- **6 letters has the best names but runs out faster**, and most of its WoW-specific pool is proper nouns, which
  makes puzzles depend on lore knowledge more than word-solving.
- Every daily puzzle has the same length for everyone, so leaderboards stay fair either way.

Trade-off: THRALL, ARTHAS, MURLOC, TAUREN and SHAMAN can't be answers. A later "six-letter weekend" mode could
use them without changing the daily format.
