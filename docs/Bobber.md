# Bobber
Fish with the jump key. With a fishing pole in the main hand and standing still, the jump key casts Fishing, then reels the bobber in. Moving, swimming or in combat, it jumps. With Upkeep loaded, it also adds a clickable lure reminder.

## Files
- `Bobber.lua`: the whole addon.
  - Tables: `SETTINGS` (CVar name → function returning the value to switch to, or nil if the current one will do), `FISHING_SPELLS` (all ranks), `LURES` (best first).
  - Functions: `Wanted`, `Apply`, `HoldingFishingPole` and `BobberOut` for the key; `SwitchSettingsOn` and `PutSettingsBack` for CVars; `FindBestLure`, `ReadLure` and `UpdateLure` for lures.

## How it works
- One OnUpdate on `events` runs `Apply(Wanted())` every 0.1 s and `UpdateLure()` every 0.5 s.
- `Wanted` picks the key's `state`:
  - "combat": in combat lockdown.
  - "off": disabled, no Fishing known, or no pole in slot 16.
  - "jump": moving, falling, swimming, mounted, on a taxi, dead, or speed hidden.
  - "reel": channelling Fishing (`BobberOut`).
  - "cast": otherwise.
- `Apply` sets override bindings on `owner` for every key bound to `JUMP` (`SPACE` if none). "cast" binds the Fishing spell by name; "reel" binds `INTERACTTARGET`, and soft-target interact picks up the bobber. "jump" clears the bindings but leaves the CVars on; "off" clears them and puts the CVars back.
- `owner` is a `SecureHandlerStateTemplate` frame. Its `[combat] on; off` state driver runs `_onstate-combat`, which calls `ClearBindings()` the moment combat starts. `Apply` binds the key again after combat.
- CVars switched on while a pole is in hand: `softTargetInteract` (keyboard bit), `SoftTargetInteractArc` (at least 2), `SoftTargetInteractRange` (at least 30), `SoftTargetIconGameObject` (marks your own bobber) and `autoLootDefault`. The originals go in `BobberDB.saved` and are put back on "off", on `PLAYER_LOGOUT` (CVars are saved as the game closes) and on `PLAYER_LOGIN` (in case the last session didn't end cleanly).
- Lure: `ReadLure` looks on the pole's tooltip for a line with a time, "(N sec|min|hour|hr)"; nothing else on a pole carries one. It isn't read in combat. `lureEnds == nil` (never read) means no reminder, because absence is unproven.

## Interface
- `/bobber` turns it on or off (`BobberDB.enabled`). `/bobber debug` prints the key state, the Fishing spell, the best lure, the lure's time left and the pole's tooltip lines.
- SavedVariables: `BobberDB = { enabled, saved = { cvar = original value } }`.
- Upkeep (`OptionalDeps`): `Upkeep.AddReminder("Bobber.lure", { icon, item = lure, click = macro "/use item:<id>\n/use 16", glow = false, resting = true })`, and `RemoveReminder` once a lure is on. Skipped without `Upkeep.AddReminder`. Upkeep shows the lure's tooltip and count.

## Decisions (keep)
- Written from scratch, because Forever Fishing's code is "All Rights Reserved". Never copy code from it; borrow only the mechanism.
- The lure reminder has `resting = true` (fishing in town wants it too) and stays unlit. It offers only the best lure in your bags, in `LURES` order, and is added again when that changes (`lureShown`).

## Gotchas
- Override bindings can't change in combat; only the secure state driver clears them then. A new binding change has to respect that.
- `SwitchSettingsOn` writes `db.saved[name]` only while it's nil, so Bobber's own value never becomes the "original". A new `SETTINGS` function must return nil when the current value already does.
- `BobberOut` matches the channel by spell id, then by name. `fishingName` comes from `IsPlayerSpell` over `FISHING_SPELLS` and is refreshed on `SPELLS_CHANGED`.
- Upkeep skips its class enchant reminder on a fishing pole, so this is the only weapon reminder there.

## Open
- Not built: icons above the bobber synced between dual-boxed characters. There are no addon messages; each client marks only its own bobber, through `SoftTargetIconGameObject`.
