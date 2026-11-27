# Bobber
Fish with the jump key. With a fishing pole in the main hand and standing still, the jump key casts Fishing, then reels the bobber in. Moving, swimming or in combat, it jumps. With Upkeep loaded, it also adds a clickable lure reminder.

## Files
- `Bobber.lua`: the whole addon.
  - Tables: `SETTINGS` (CVar name → function returning the value to switch to, or nil if the current one will do), `FISHING_SPELLS` (all ranks), `LURES` (best first).
  - Functions: `Wanted`, `Apply`, `HoldingFishingPole`, `BobberOut`, `JumpKeys` and `KeyHeld` for the key; `SwitchSettingsOn` and `PutSettingsBack` for CVars; `FindBestLure`, `ReadLure` and `UpdateLure` for lures.
- Test: `tests/bobber_test.lua` (asserts) walks the key through a cast held down, a catch held down for seconds, a quick tap to reel in followed at once by a cast, a release just after the key changed, and a landing with the key down.

## How it works
- One OnUpdate on `events` runs `Apply(Wanted())` every 0.1 s and `UpdateLure()` every 0.5 s.
- `Wanted` picks the key's `state`:
  - "combat": in combat lockdown.
  - "off": disabled, no Fishing known, or no pole in slot 16.
  - "jump": moving, falling, swimming, mounted, on a taxi, dead, or speed hidden.
  - "reel": channelling Fishing (`BobberOut`).
  - "cast": otherwise.
  - Then, if "reel" or "cast" differs from the current `state` while a jump key is down (`KeyHeld`, `IsKeyDown` on the binding's last key), it's "wait" until the key is let go. So one press does one thing.
- `Apply` sets override bindings on `owner` for every key bound to `JUMP` (`SPACE` if none, `JumpKeys`). "cast" binds the Fishing spell by name; "reel" binds `INTERACTTARGET`, and soft-target interact picks up the bobber; "wait" binds a click on `BobberWaitButton`, a plain button with no script, so the key does nothing (clearing the binding would make it jump). "jump" clears the bindings but leaves the CVars on; "off" clears them and puts the CVars back.
- `owner` is a `SecureHandlerStateTemplate` frame. Its `[combat] on; off` state driver runs `_onstate-combat`, which calls `ClearBindings()` the moment combat starts. `Apply` binds the key again after combat.
- CVars switched on while a pole is in hand: `softTargetInteract` (keyboard bit), `SoftTargetInteractArc` (at least 2), `SoftTargetInteractRange` (at least 30), `SoftTargetIconGameObject` (marks your own bobber) and `autoLootDefault`. The originals go in `BobberDB.saved` and are put back on "off", on `PLAYER_LOGOUT` (CVars are saved as the game closes) and on `PLAYER_LOGIN` (in case the last session didn't end cleanly).
- Lure: `ReadLure` looks on the pole's tooltip for a line with a time, "(N sec|min|hour|hr)"; nothing else on a pole carries one. It isn't read in combat. `lureEnds == nil` (never read) means no reminder, because absence is unproven.

## Interface
- `/bobber` turns it on or off (`BobberDB.enabled`). `/bobber debug` prints the key state, the Fishing spell, the best lure, the lure's time left and the pole's tooltip lines.
- SavedVariables: `BobberDB = { enabled, saved = { cvar = original value } }`. `PLAYER_LOGIN` drops `BobberDB.trace`, left by the uncommitted trace build that found the double cast.
- Upkeep (`OptionalDeps`): `Upkeep.AddReminder("Bobber.lure", { icon, item = lure, click = macro "/use item:<id>\n/use 16", glow = false, resting = true })`, and `RemoveReminder` once a lure is on. Skipped without `Upkeep.AddReminder`. Upkeep shows the lure's tooltip and count.

## Decisions (keep)
- Written from scratch, because Forever Fishing's code is "All Rights Reserved". Never copy code from it; borrow only the mechanism.
- One press does one thing (1.0.2, confirmed in game 2026-11-27, fast-looting included). Before that, a press that reeled in could cast again as it was let go, and the fish was never looted (reported 2026-11-27): the key was rebound to Fishing 0.1 s after the channel ended while still down, and the release fired the new binding before the loot was taken.
- No wait for the loot: the user fast-loots, since casting again while the loot window is up still gets the catch. A 1.0.2 draft waited for the loot window to close and was rejected for locking that out. Don't add a loot wait back.
- The lure reminder has `resting = true` (fishing in town wants it too) and stays unlit. It offers only the best lure in your bags, in `LURES` order, and is added again when that changes (`lureShown`).

## Gotchas
- Override bindings can't change in combat; only the secure state driver clears them then. A new binding change has to respect that.
- Never rebind a key while it's down to something that acts: it can fire on the same press. Bind "wait" until `KeyHeld` is false.
- Confirmed in game with a trace build (2026-11-27; the trace was removed after): the extra cast comes from the key's release. Space held 3.5 s after a reel with the key rebound to Fishing cast nothing while held, then cast 135 ms after the release. Press-and-hold casting (ActionButtonUseKeyHeldSpell) was 0, ActionButtonUseKeyDown 1. Once a near miss: the release and the rebind fell in the same frame, with the release first.
- The trace suggests the Fishing spell binding fires on the key's release, despite ActionButtonUseKeyDown: in 4 casts, release to cast reply took 117–135 ms and press to reply 186–214 ms, while the reel (interact, on the press) took 111–179 ms from the press.
- Timing on a catch: channel stop and LOOT_READY arrive together, LOOT_OPENED about 0.25 s later, and the fish is taken about 0.35 s after that (autoLootRate 150).
- `SwitchSettingsOn` writes `db.saved[name]` only while it's nil, so Bobber's own value never becomes the "original". A new `SETTINGS` function must return nil when the current value already does.
- `BobberOut` matches the channel by spell id, then by name. `fishingName` comes from `IsPlayerSpell` over `FISHING_SPELLS` and is refreshed on `SPELLS_CHANGED`.
- Upkeep skips its class enchant reminder on a fishing pole, so this is the only weapon reminder there.

## Open
- Not built: icons above the bobber synced between dual-boxed characters. There are no addon messages; each client marks only its own bobber, through `SoftTargetIconGameObject`.
