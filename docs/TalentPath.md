# TalentPath
Marks your next talent pick in the talent window from a Wowhead talent-calculator link (one link per spec group, pasted in a box under the window), and warns when your talents leave that order.

## Files
- `Link.lua`: `ns.Link.Parse(text)` -> `{ class, trees = { ranks per talent } x3, steps = { { tree, index, rank } } }` or `nil, reason`. Pure Lua; `tests/link_test.lua` checks it against real mage and paladin links.
- `TalentPath.lua`: `ReadTalents` (game tree in Wowhead's order), `TalentSpell`, `Misfit`, `Evaluate`, `Mark`/`ShowInTalentWindow` (glows), `ShowReminder` (Upkeep), `Refresh` + `driver`, `HookTalentWindow`, `CreateLinkBox`/`UpdateLinkBox`, `PrintOrder`, slash handler, `events` frame.

## How it works
- Link: `talent-calc/<class>/<build>/<order>`. Build = leading letters, then one digit per talent (final rank), trees split by `-`, trailing zeros dropped, rest (`_t0`) ignored. Talents numbered row by row, left to right. Order: a digit switches tree (0-based); a lowercase letter adds one point; an uppercase letter fills the talent to its final rank in the link (not its max). Letter = talent index in `abcdefghjkmnpqrstvwxyz` (no i, l, o, u). `Parse` rejects an order that doesn't add up exactly to the build.
- `ReadTalents`: config from `C_SpecializationInfo.GetCombatConfigIDForSpecGroup(GetActiveSpecGroup())` (fallback `C_ClassTalents.GetActiveConfigID`), `config.treeIDs[1]` (one tree, three trait groups). Group order from `C_Traits.GetGroupDisplayInfoByTreeID` = Wowhead's tree order; nodes per group sorted by `posY` then `posX` = Wowhead's numbering (confirmed in game). Skips nodes with ID 0, not `isVisible`, or `maxRanks` 0.
- `Evaluate`: spent = sum of `ranksPurchased` (includes staged, unapplied clicks). Every node must equal its rank after `spent` steps of the order, else "off". Points left = `C_Traits.GetTreeCurrencyInfo(configID, treeID, false)[1].quantity` + `ns.previewPoints`. Statuses: none, wait, bad, off, done, on (`picks` = next steps, `later` = every node the rest of the build still touches).
- Goes by points spent, never by level, so early (legacy) points work. `PLAYER_LEVEL_UP` is just a refresh trigger.
- `driver` OnUpdate: refresh every 0.25 s while the talents tab is visible, 0.3 s after any event (`soon = true`), else every 5 s. Events only set `soon`. `Refresh` runs `Evaluate` in `pcall`; "wait" leaves the display as it was.
- The window is `PlayerSpellsFrame.TalentsFrame` from load-on-demand `Blizzard_PlayerSpells`; `HookTalentWindow` runs on `PLAYER_LOGIN` and on that addon's `ADDON_LOADED`.

## Interface
- `/talentpath`: help. `/talentpath order`: prints the active spec's build step by step with this character's talent names, to compare with Wowhead's list. `/talentpath preview <n>`: pretend n more points (0-51, not saved; `preview 0` or a reload ends it).
- SavedVariablesPerCharacter `TalentPathCharDB.links[specGroup]` = link text as pasted.
- Upkeep (OptionalDeps): `Upkeep.AddReminder("TalentPath.next", { icon, spell, click = { type = "click", clickbutton = TalentMicroButton }, glow = false, resting = true })` / `Upkeep.RemoveReminder`; re-sent only when `nodeID:rank` changes (`reminderKey`).
- Talent frame methods used: `GetTalentButtonByNodeID`, `IsInspecting`, `IsActiveTabSelected` (last two guarded).

## Decisions (keep)
- Off-order talents or an unfit link: only the red strip under the box, "Your talents don't follow this build." or "This link doesn't fit this character." No chat output, no label on the box. The detailed `state.message` strings are built but deliberately not shown.
- Marks: yellow `IconAlert` glow on the next pick (`picks[1]`), light-blue (`LATER_COLOR`) `UI-ActionButton-Border` on every other talent the build still takes; both only while a point is available. Numbered marks were tried and rejected (they overlapped and were hard to read over the glow): don't bring numbers back.
- Marks are frames of our own laid over Blizzard's buttons. Never modify, hook or reparent the talent buttons: the talent window is easily upset by addons.
- Marks only on your own active spec: hidden while inspecting or on a non-active tab.
- Link box: Enter or focus loss saves, Escape undoes, empty removes the build. The text is kept as pasted even when it doesn't parse; the strip says so.
- Upkeep reminder has `resting = true`: spending points in town is fine.

## Gotchas
- A Lua error inside `Evaluate` becomes status "bad", so it shows as "This link doesn't fit this character." Rule out a code error before blaming the link.
- "off" compares step by step, so the right talents taken in a different sequence still count as off. That's by design.
- `picks` has one entry per available point, but only `picks[1]` is drawn and sent to Upkeep. The file header and the `.toc` Notes still say "talents", plural, from the numbered-marks version.
- `Misfit` also fails when a link rank exceeds a node's `maxRanks` or names a missing talent ("Wowhead may be out of date").
- `UpdateLinkBox` skips while the box has focus, so the 0.25 s refresh doesn't overwrite typing.
- The box is parented to `talentsFrame` (so it hides with the tab) but anchored under `PlayerSpellsFrame`, at 70% of its width, reapplied in `OnShow`.

## Open
- Dual spec and respecs are untested (links keyed by `GetActiveSpecGroup`). The user will test on a max-level character.
