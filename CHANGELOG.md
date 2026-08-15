## High-Resolution Neon Settings UI Test

- Completely rebuilt Randomizer+ Settings in true window-space rendering.
- New black + neon-green visual theme inspired by late-90s high-energy wrestling aesthetics.
- Fonts are rendered at actual desktop pixel sizes for much sharper text.
- Added tabbed Trainer, Wild, Starter, Traits, and Items & TMs categories.
- Removed the Y / Reset Category control entirely.
- Existing randomizer behavior and saved settings are unchanged.

## First Encounter Trainer Randomizer Test 2

- Fixed battle crash after selecting a move during randomized first trainer/Gym encounters.
- First encounters now use the same post-construction native Gen 2 move normalization as the proven rematch randomizer.

## First Encounter Trainer Randomizer Test

- Added FIRST BATTLE POKEMON and FIRST BATTLE STATS/MOVES options for initial trainer and Gym Leader battles.
- First encounters retain vanilla trainer levels and use the same species/stat/move randomization engine as rematches.


## 2.5.0

- Added Random World Items, including hidden items, with key items, HMs, and unused TERU-SAMA placeholder slots protected.
- Added Randomized TMs with unique move assignments per playthrough.
- Protected TM02 (Headbutt) and TM08 (Rock Smash) and excluded HM moves, Headbutt, and Rock Smash from randomized TM assignments.

# v2.5.0 Test — Random World Items

- Added **RANDOM WORLD ITEMS** to Randomizer+ Settings, OFF by default.
- Randomizes visible Poké Ball pickups and hidden field items.
- Hooks only Gold's extracted `itemball` and `hiddenItem` map records; NPC gifts, scripted rewards, shops, and other item-award scripts are untouched.
- Original KEY_ITEM-pocket pickups remain completely unchanged.
- Key items are excluded from the replacement pool.
- Random replacements can come from normal ITEM, BALL, and TM/HM pockets.
- Each location receives a persistent replacement for that playthrough.
- Item-ball disappearance and hidden-item event flags remain handled by Gold normally.
- Turning the option OFF restores currently projected map records to vanilla.
- New-game creation clears saved world-item assignments so each playthrough can roll differently.
- Existing learnset, trainer, wild, type, starter, rematch, progression, XP, and money systems are otherwise unchanged.

# v2.0.0 — Starter Acquisition Random Learnset Fix

- Fixed Random Learnset not randomizing a starter's initial/current moves when the option was already ON before receiving the starter.
- The Elm starter script hook now also runs when Random Learnset is enabled, even when Random Starters is OFF.
- Removed the obsolete `enrollMonV9` starter-acquisition call left from an earlier experimental learnset implementation.
- After Elm adds the starter to the real party, the mod now uses the confirmed-working `enrollOwnedMon(starter, data, true)` path to build its individual random schedule and current moves.
- Any active native level-up projection is restored before starter enrollment so the personal schedule is derived from the native species learnset.
- The confirmed-working future randomized level-up projection is unchanged.
- No trainer, wild, type, starter-species, rematch, progression, XP, or money behavior was changed.

# v2.0.0 — First Public Gen 2 Randomizer+ Release

- Renamed the internal mod ID from `trainer_rematch_2` to `gen_2_randomizer_plus` so compatible launchers identify the installed mod as Gen 2 Randomizer+ instead of Trainer Rematch 2.
- Public release version reset to 2.0.0.
- Includes the confirmed-working combined Random Learnset behavior from the final test build: randomized current/starting moves and randomized moves learned while leveling.
- No gameplay logic was changed from the confirmed-working v2.0.25 test build.

# v2.0.25 — Combined Proven Random Learnset Paths

- Built from v2.0.23, where randomized moves learned while leveling were confirmed working.
- Keeps the v2.0.23 native `levelMoves` projection unchanged for future level-up moves.
- Restores the v2.0.20/v2.0.14 proven live-party initialization behavior.
- Fixes a persistence edge case: previous builds only rebuilt current moves when a per-Pokémon random schedule was considered "fresh." Existing schedules carried over from earlier test versions could therefore skip the starter/current-move rebuild.
- Turning Random Learnset ON now force-applies that Pokémon's existing personal random schedule to its current `mon.moves`, even if the schedule already existed.
- Any active native learnset projection is restored before this rebuild so schedule generation/reading uses the native species data.
- The level-up projection begins on the following engine frame, keeping initial/current randomization and future level-up randomization isolated from one another.
- No trainer, wild Pokémon, Random Types, Random Starters, rematches, Progressive Levels, XP, or money systems were changed.

# v2.0.23 — Native Learnset Registry Projection

- Built from v2.0.20, the user-confirmed working baseline.
- Does not alter the working initial/current Random Learnset behavior.
- Replaces the failed after-the-fact level-up strategy with the same architecture used by real Gen 2 randomizers: randomize the learnset data Gold reads.
- Pokémon Gold's original `LearnLevelMoves` reads its species Evos/Attacks learnset before calling `LearnMove`.
- The supplied randomizer likewise creates a replacement learnset while preserving the original learn levels.
- v2.0.23 projects the active owned Pokémon's individual persistent random schedule into the live `game.data.pokemon[species].levelMoves` registry BEFORE Gen1Recomp's normal engine step can award EXP.
- Gold therefore sees the randomized move as the native level-up move from the beginning of the learning flow, including its normal learn/forget UI.
- The original species learnset is restored when the active Pokémon changes or battle ends.
- Trainers, wild Pokémon, Random Types, Random Starters, rematches, Progressive Levels, XP, money, and Random Learnset initialization are unchanged.

# v2.0.20 — Restore Proven Random Learnset Initialization

- Restores the proven current/starter move behavior from the successful v2.0.14/v2.0.15 path.
- Enabling Random Learnset now arms initialization when the settings menu closes, then performs the actual live-party move rebuild on the next normal engine step.
- Removes the ineffective v2.0.18 `Mon.gainExperience` monkey-patch and its extra permission.
- Future level-up debugging remains isolated: `pokemon.level_up` only arms that individual's vanilla→random mapping; it does not modify shared species data.
- Reconciliation runs both before and after the normal engine step.
- Starter Moves remains removed because Random Learnset handles current/starter moves.
- No unrelated trainer, wild, type, starter-species, rematch, progression, XP, or money code changed.

# v2.0.18 — Direct Mon.gainExperience Learnset Fix

- Focuses only on Random Learnset level-up moves.
- The v2.0.14/v2.0.15 current-move randomization remains unchanged.
- Instead of timing mutations around events, this build patches Gold's exact Gen 2 `Mon.gainExperience` function.
- Native Gold EXP/stat/level calculations run first and return their normal result.
- Only `result.learned` is replaced with this individual Pokémon's random moves for the exact levels crossed.
- `Battle.lua` then consumes that returned random list through its normal move-learning flow.
- Added `engine_internals` permission for the deliberate Gen 2 engine module patch.
- Removed shared-species `levelMoves` mutation from the `pokemon.level_up` handler.
- No unrelated trainer, wild, type, starter, rematch, progression, XP, or money behavior changed.

# v2.0.17 — Random Learnset Level-Up Injection Fix

- Focuses only on the second half of Random Learnset: moves learned while leveling.
- Keeps the already-working randomized current/initial moves from v2.0.15.
- Removed the v2.0.16 `exp.gain` learnset overlay.
- Uses Gen1Recomp Gold's actual `pokemon.level_up` event, which fires inside `Mon.gainExperience` before its final `def.levelMoves` scan.
- Temporarily replaces only the exact level-up rows being crossed with that individual Pokémon's random move ids.
- `battle.exp_gained` restores the shared species rows only after Gold has copied those random ids into `result.learned`.
- Added a `pokemon.move_learned` safety correction using the proven live `mon.moves` mutation path.
- Added a fixed-step fallback for delayed four-move forget/replace flows.
- Starter Moves remains removed.
- No unrelated trainer, wild, type, starter, rematch, progression, XP, or money behavior was changed.

# v2.0.16 — Native Random Learnset Level-Up Fix

- Focused only on Random Learnset.
- Current/initial randomized moves from v2.0.15 are retained.
- Fixed the future level-up half by feeding Gold a native-format per-Pokémon `levelMoves` overlay during `Mon.gainExperience`.
- Individual schedules are converted from `{ level, vanilla, random }` into the exact `{ level, move }` rows Gold consumes.
- The existing `exp.gain` hook installs the overlay immediately before Gold calculates level-ups.
- `battle.exp_gained` restores the shared species learnset immediately after Gold has copied the random moves into `result.learned`, but before those moves are taught.
- This means Gold itself now handles the randomized move name, PP, duplicate checks, and four-move forget prompt.
- Removed the visible **Starter Moves** option and disabled its old execution path because Random Learnset already supplies randomized starter/current moves.
- No trainer, wild, type, starter-species, rematch, progression, XP, or money behavior was otherwise changed.

# v2.0.15 — Random Learnset Fix

- Replaces the successful v2.0.14 fixed-move probe with the actual Random Learnset system.
- Uses the exact live `game.save.party[i].moves` mutation path proven by v2.0.14.
- Every owned Pokémon gets its own persistent randomized level-up schedule.
- Vanilla learn levels are preserved; only the learned move is randomized.
- Two Pokémon of the same species can have different schedules.
- Current moves are rebuilt from the personal schedule on first enrollment.
- Future vanilla level-up moves are swapped in the live `mon.moves` table after Gold writes them.
- Includes both the `pokemon.move_learned` path and fixed-step fallback.
- TM/HM teaching is not randomized.
- Activation remains deferred until Randomizer+ Settings closes, matching the safe timing proven in v2.0.14.
- No unrelated randomizer/rematch features were changed.

# v2.0.14 — Random Learnset Exit-Path Probe

- Changes only the Random Learnset diagnostic.
- Fixed the missing normal-B exit path: Gen1Recomp's ListMenu pops on B and calls `onCancel`, bypassing the custom BACK-row `onChoose` callback.
- The pending probe now runs after either B or the explicit BACK row closes Randomizer+ Settings.
- For an unmistakable test, party slot #1 receives up to four fixed valid Gold moves (preferentially THUNDERBOLT, FLAMETHROWER, ICE BEAM, PSYCHIC).
- This is diagnostic only; no trainer, wild, type, starter, starter-move, rematch, or progression logic was changed.

# v2.0.13 — Random Learnset Probe RNG Fix

- Changes only the isolated Random Learnset probe.
- Fixed a Lua lexical-scope bug in the previous probes: the probe was defined before the mod's local `rngInt()` declaration, so calls inside the probe could resolve to a nonexistent global instead of the intended helper.
- The probe now uses its own local `probeRandom()` function (`love.math.random`, falling back to `math.random`).
- Turning Random Learnset ON still only arms the test.
- Choosing the settings menu's BACK row still performs one direct assignment to `game.save.party[1].moves`.
- No level-up scheduling, reconciliation, trainer, wild, type, starter, or other feature code was changed.

# v2.0.12 — Deferred Random Learnset Probe

- Changes only the Random Learnset diagnostic timing.
- Turning Random Learnset ON no longer touches any Pokémon while the settings menu is active.
- The toggle only arms a one-time pending probe.
- Selecting the settings menu's **BACK** row first pops the menu, then directly assigns random native Gen 2 moves to party slot #1.
- No learnset schedules, level-up hooks, reconciliation, or unrelated feature changes are active in this probe.
- This specifically tests whether mutating an owned Pokémon is safe only after the ListMenu has been removed from the stack.

# v2.0.11 — Random Learnset Crash Isolation

- Changes only the Random Learnset diagnostic path.
- Removed the old experimental learnset synchronization from the toggle test.
- Removed custom diagnostic fields from the Pokémon.
- Turning Random Learnset ON now performs exactly one action: `game.save.party[1].moves = <fresh random native Gen 2 move array>`.
- Uses the same fresh-table assignment pattern as the already-working Random Starter Moves feature.
- Automatic learnset reconciliation/synchronization is disabled in this diagnostic build so nothing else can cause a crash after the probe.
- All unrelated randomizer/rematch features are unchanged.

# v2.0.10 — Random Learnset Isolated Probe

- No changes to trainer rematches, trainer randomization, wild randomization, Random Types, Random Starters, or Starter Moves.
- Added one isolated Random Learnset diagnostic.
- Turning Random Learnset ON directly replaces the current moves of party slot #1 using the exact `game.save.party[1]` object supplied to the settings menu.
- Move entries use Gold's native `{ id, pp, maxPp }` structure.
- This test is intended only to prove the settings menu can reach and mutate the live owned Gen 2 Pokémon before any further level-up debugging.

# v2.0.9 Test — Clean Learnset Rebuild

- Rebuilt Random Learnset from the clean v2.00 release.
- Discarded every experimental v2.0.1-v2.0.8 implementation instead of patching them forward.
- Fixed a packaging error in v2.0.8 where the ZIP did not contain the implementation it was described as containing.
- Added a new V9 per-Pokémon learnset schema so stale experimental fields in existing saves are ignored.
- Each individual Pokémon receives a complete randomized schedule while preserving the species' original learn levels.
- Current moves are rebuilt from the individual's schedule on first enrollment for immediate visible verification.
- Added fixed-step level reconciliation in addition to `pokemon.move_learned`, so the final learned move is corrected even if a UI/event timing path differs.
- Added post-catch and scripted-gift enrollment.
- Kept Random Starter Moves as a separate option; it remains OFF by default.

# Changelog

## v2.00 — Gen 2 Randomizer+ Release

- Renamed **Trainer Rematch 2** to **Gen 2 Randomizer+** to reflect the expanded scope of the mod.
- Added randomized trainer Pokémon with optional random stats and moves.
- Added randomized wild Pokémon across all 251 species while preserving each area's encounter levels.
- Added randomized wild stats and moves using Gen1Recomp Gold's native Gen 2 battle structures.
- Added randomized Pokémon types with battle typing and type-based TM/HM compatibility.
- Added randomized Elm starters restricted to base-stage and single-stage Pokémon.
- Retained trainer and Gym Leader rematches, Progressive Levels, natural evolution/move progression, trade evolutions at Level 45, customizable rematch XP/money, and persistent settings/progression.
- Renamed the START-menu settings entry to **RANDOMIZER+ SETTINGS**.

## v1.3.1 - Random Starters Test
- Added optional Random Starters setting (OFF by default).
- Elm's three starter balls are replaced with three distinct randomized Pokemon when enabled.
- Starter pool includes only base-stage Pokemon and true single-stage Pokemon; evolved forms are excluded.
- Random starter trio is saved for the current save instead of rerolling every time a ball is inspected.
- Rival starter is synchronized with the randomized Elm trio.
- All v1.3.0 rematch, wild randomizer, random stats/moves, and random type features are retained.

# v1.2.20 Wild Move Active-Game Test

- Rebuilt wild random move injection around the exact `src.core.Game.data` table consumed by `BattleState.newWild` and `Pokemon.new`.
- Random moves are projected during the already-proven encounter hook, copied into the individual wild Pokemon in the same frame, and the shared species record is restored on the following input frame.
- Removed the later battle-stage wild move overrides from this test path.

# Changelog

## v1.2.19 - Wild Move Injection Rebuild

- Rebuilt Wild Random Stats/Moves for the older v0.1.90 runtime path.
- Wild random moves now use only the proven encounter.species / encounter.fishing hooks.
- The encountered species receives four random live Gold moves before Pokemon.new() constructs it.
- The temporary learnset remains installed until the next encounter rather than depending on battle.started.
- Patches both Game.data and src.core.Data registry identities when available.
- Restores the previous species learnset at the next encounter or when Wild Stats/Moves is turned OFF.
- Shortened the menu label to WILD STATS/MOVES so ON/OFF is visible.
- Trainer randomization and rematch logic are unchanged.

## v1.2.23 - Wild Moves Gen 2 Runtime Fix
- Rebuilt Wild Stats/Moves against Gen1Recomp Gold's actual Gen 2 battle model.
- Fixed wild move randomization targeting Gen 1 `level1Moves`/`learnset` fields; Gold uses Gen 2 `levelMoves` and `Mon` objects instead.
- Wild random moves are now installed directly on `battle.enemy.moves` at `battle.started`, before the first turn.
- Random move entries now use Gold's native `{ id, pp, maxPp }` shape.
- Wild DVs are randomized and stats refreshed through `src.battle.gen2.Mon`.
- Random Wild Pokemon still preserves the encounter table's original level.

## 1.3.0 Type Randomizer Test
- Added **Random Types** option to Rematch Settings (OFF by default).
- Each species receives a stable randomized type assignment while enabled.
- Single-type species remain single-type; dual-type species remain dual-type.
- Randomized types are applied to battle Pokémon, including existing party Pokémon.
- TM/HM compatibility keeps vanilla compatibility and additionally allows TM/HM moves matching the Pokémon's randomized type(s).
- Turning Random Types OFF restores the original Gold species types and TM/HM compatibility.

## v2.5.0 Random World Items Test 2
- Fixed overworld and hidden-item replacements using string item IDs instead of Gold's raw numeric item indexes.
- Existing broken v2.5.0 test assignments are migrated to numeric indexes when possible.

- Random World Items: excluded unused Gen 2 `TERU-SAMA` placeholder slots.

## v2.5.0 Randomized TMs Test
- Added RANDOMIZED TMS option (OFF by default).
- TM01-TM50 each teach a randomly selected move for the current playthrough.
- TM moves are selected without replacement, so no two TMs teach the same move.
- HM01-HM07 and all seven HM moves are excluded and remain unchanged.
- TM compatibility follows the original TM slot, so Pokemon compatible with a vanilla TM slot can learn that slot's randomized move.
- A new game clears and regenerates the 50-TM mapping; reloading the same playthrough keeps it stable.

- Randomized TMs Test 2: TM02 (Headbutt) and TM08 (Rock Smash) are protected and excluded from the randomized move pool.
