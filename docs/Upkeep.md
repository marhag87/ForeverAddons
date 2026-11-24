# Upkeep
Paladin seal duration bar, plus one row of clickable reminders for anything you should keep up (blessings, weapon enchants, class self-buffs, gathering tracking, experience food, sleeping bag). Other addons add their own reminders to the same row. Named SealTimer until 2026-11-17.

## Files
- `Upkeep.lua`: the whole addon. Config tables at the top: `SELF_BUFFS` (per class token, plus `ALL`), `WEAPON_ENCHANTS` (per class, only `SHAMAN` filled in), `BLESSING_SPELLS`, `UTILITY_BLESSINGS`. Sections in order: seal bar (`UpdateSeal`, `PlaceBar`), blessings (`ReadBlessings`, `Castable`), button rows (`NewButtonRow`, `LayoutRow`, `RowAdd`/`RowRemove`, `Sync`, `DrawPlainRow`, `Style`), public API, own reminders (`BlessingReminder`, `WeaponReminders`, `SelfBuffReminders`, `XPReminders`, called from `UpdateSelf`), target row (`UpdateTarget`), driver (`OnCast`, `Every`, `Debug`, event frame).
- Mock tests: `tests/upkeep_*_test.lua` cover rows in and out of combat, food, sleeping bag, Shaman enchant, Redgill, resting and mounted, counts and late-loading food (`nocache`, `nospell` modes, and a no read again at a bag change).

## How it works
- Polling: `Every(0.05, UpdateSeal)`, `Every(0.1, UpdateSelf)`, `Every(0.1, UpdateTarget)`. Each runs on its own OnUpdate frame, so an error in one can't stop the others.
- Events only reseed or re-lay-out: `PLAYER_LOGIN` (places the bar and rows, then `SeedKnown`, `SeedWeaponEnchants`, `SeedSelfBuffs`, `SeedXP`), `SPELLS_CHANGED`, `BAG_UPDATE_DELAYED`, `PLAYER_UPDATE_RESTING`, `PLAYER_REGEN_ENABLED` (lays out rows marked `dirty` and redraws in the same frame, so a plain icon never shows beside its new button).
- Each update builds a list of wanted entries (`{id, icon, click, item|spell|tooltip, glow, desaturate}`) and `Sync`s it into `selfRow` or `targetRow`. `selfOwned`/`targetOwned` record which ids each source added.
- A row holds `SecureActionButtonTemplate` buttons (`RowButton`) for laid-out entries, and a plain-icon row (`selfPlain`, `targetPlain`) for entries waiting for combat to end (`Pending`). The order is first come first placed (`row.order`): buttons first, plain icons after them (`ShiftSelfPlain`).
- `RowAdd` only lays the row out again for a new id, a changed click (`SameClick`) or a change in resting visibility. Icon, tooltip and glow are read live by `Style`. A reminder removed in combat dims (`e.removed`) until combat ends, and adding it again before then brings it back.
- Casts: `UNIT_SPELLCAST_SENT` records the castGUID in `sentCasts`, and only a matching `UNIT_SPELLCAST_SUCCEEDED` calls `OnCast`. That starts timers for seals, self-buffs, enchants and blessings on yourself, for when auras can't be read.
- The last trusted reading is carried forward until it expires: `lastKnown` (blessings), `selfBuffs[i].state`, `weaponState[slot]`. `nil` means never read, and then nothing shows, because absence is unproven.

## Interface
- `/upkeep` previews the seal bar (a fake 30 s seal, `FALLBACK_DURATION`). `/upkeep debug` prints known blessings, auras with their ranks, last readings, weapon tooltips and enchant buttons, self-buffs, the consumables in your bags with their experience verdict, experience buffs, Well-Rested stacks, and every reminder id with its state.
- No SavedVariables, key bindings or addon messages. The blessing and enchant to suggest (`lastMine`, `lastWeaponOption`) are learnt again each session.
- The global `Upkeep.AddReminder(id, info)` takes a string id, and adding the same id again updates it. `Upkeep.RemoveReminder(id)` removes one. `info` fields:
  - `icon`: a texture path or file id.
  - `click`: secure action attributes, copied. Without it, a click does nothing.
  - `item`: shows that item's tooltip, and a count if it stacks.
  - `spell`: shows that spell's tooltip.
  - `tooltip`: plain text, used only when there's no `item` or `spell`.
  - `glow = false`: stays unlit in combat.
  - `desaturate = false`: full colour, unlit.
  - `resting = true`: still shows in rested areas and while mounted.
- Callers: Bobber (`Bobber.lure`), Tandem and TalentPath, all with `resting = true`. They declare `OptionalDeps: Upkeep` and check `Upkeep and Upkeep.AddReminder` first. Upkeep's own ids start with `Upkeep.`.

## Decisions (keep)
- Reminders grow rightwards from the seal bar's top-left corner (this was flipped from leftwards on 2026-11-22). `selfRow` is anchored to the player health bar, never to `bar`, so the seal bar can still show and hide in combat. `PlaceSelfRow` repeats `PlaceBar`'s arithmetic, so change both together. Only the plain-icon row is anchored to `bar`.
- Target row: a child of `TargetFrame`, starting at its top-left (`TARGET_X`, `TARGET_Y`), hidden in combat by the state driver `[combat] hide; show`. It shows one button per blessing a cast of yours would add, and none if one of yours is already there. Duration is ignored; icons are full colour and unlit. Freedom, Protection and Sacrifice never count.
- In rested areas (`IsResting`) and while mounted (`IsMounted`, a secret value counts as not mounted), reminders on both rows hide but are kept: `Resting()`, polled by `UpdateResting` each refresh. `resting = true` opts a reminder out. The seal bar is unaffected.
- No class enchant reminder for a fishing pole in the main hand: the pole wants a lure, which is Bobber's reminder.
- Experience food: you only count as fed with a "Well Fed" buff whose tooltip says "xperience". Well-Rested and Camp Benefits mention experience too, and counting them was a bug. Food that mentions "Fishing Skill" (Filet of Redgill) is kept for fishing; the user chose this. The pick is the highest item level, then the biggest stack.
- Sleeping bag: offered when it's off cooldown and Well-Rested is missing, under `BAG_STACKS` (3) or under `BAG_EARLY` (10 min) left.
- Glow is only for real gaps. Early warnings (`early`; Shaman imbues warn 5 min ahead), experience food, the sleeping bag and target blessings stay unlit. The experience reminders don't come or go during combat.
- A lower rank than you know counts as missing; a rank that can't be read doesn't, so it never nags without reason.

## Gotchas
- The spellbook can't be enumerated. Every rank is listed by spell id (lowest first, so a position is a rank) and checked with `IsSpellKnown`, falling back to `IsPlayerSpell` for rune spells such as Water Shield 408510. A new spell needs its ids added to the tables.
- `AurasTrusted`: in combat, no scan is believed. Out of combat, a scan of your own buffs is believed only if it read as many as `BuffFrame` shows (`ShownBuffCount`).
- `GetWeaponEnchantInfo` reports no enchant on this client. Enchants come from lines on the weapon's tooltip (`TooltipEnchant`; `RankAfterName` reads "2", "II" or nothing). In combat they come from `BuffFrame`'s TempEnchant buttons (`EnchantButton`), which can't tell your enchant from a whetstone. `OnCast` assumes an enchant lands on the main hand.
- `UNIT_SPELLCAST_SUCCEEDED` for "player" also brings other players' seal casts and procs such as Seal of Command's hit (20424). Keep the `sentCasts` filter.
- English text is matched in several places: "Seal of", "Blessing of", enchant prefixes, "xperience", "Use:", "Fishing Skill", "Well Fed", "Well-Rested", "Cozy Sleeping Bag", and times such as "(N min)".
- Food text loads in the background. `UseText` asks for the item and spell data and returns false until it's there. `GetItemSpell` can also return nothing for a cached item whose spell hasn't loaded, so `XPVerdict` doesn't judge food that has neither a description nor a "Use:" line. `SeedXP` looks again every 3 s, up to `XP_RETRIES` (5) times. `xpFoodOf` keeps a yes for the session; a no is read again at every look (each bag change). Before 2.19, a too-early read marked food as giving no experience for the session (seen on a Shaman at 59).
- Counts show only for items that stack (`Stacks`, which is nil until the item loads), and as "*" above 9999.

## Open
- Untested in game: sleeping-bag stacks and early warning, rested-area and mounted hiding, target-frame blessing buttons on a Paladin.
- `WEAPON_ENCHANTS.ROGUE` (poisons) is a commented-out stub with no item ids, though the file's header mentions Rogue poisons.
- `/upkeep`'s preview shows nothing on a non-Paladin, because `UpdateSeal` hides the bar.
