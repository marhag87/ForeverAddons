# AvailableQuestsMap
Puts a "!" on the world map wherever a quest giver (or the drop area of a quest-starting item) has a quest you can pick up now, and lists an NPC giver's quests in its unit tooltip. Data from QuestieDB. User-facing docs (commands, availability rules, known limits): `AvailableQuestsMap/README.md`. Keep it in step with user-visible changes, and don't repeat it here.

## Files
- `Core.lua`: `DEFAULTS`, settings migration, `handlers.*` events, background build (`StartBuild`, coroutine run by the `runner` OnUpdate, `FRAME_BUDGET_MS`), `ns.RequestUpdate`/`RunUpdate`/`Signature`, map menu (`ns.AddMapMenuEntries`), `/aqm` (`TOGGLES`).
- `Availability.lua`: `Build` (one `BuildRecord` per quest), `Compute(db)` (display filters + `Check`), `GetRecord`, `GetName`; `neededSkills`/`neededFactions`.
- `Player.lua`: `Initialize` (level, `raceFlag` from `Enum.raceMaskById`, `classFlag`, `factionLetter`), completed/active quest sets, skills, reputation, `KnowsSpell`, `GreenRange`.
- `Zones.lua`: `Initialize` reads `Support.Get("ZoneDB").private` (AreaID to UiMapID, subzone to parent, dungeons); `UiMapFor`, `ForEachPosition`.
- `Map.lua`: `GetPlace`/`LoadPlace` (spawn positions), `GetItem`/`LoadItem` (drop sources), `CollectGivers`, `CollectDropAreas`, `Draw`, `Clear`, icon pool (`AcquireIcon`, `StyleIcon`, `StyleFor`), `Icon_OnEnter`, `OffMap`. Exports `Map.AddQuestLines` and `Map.SortByLevel` for `Tooltip.lua`.
- `Tooltip.lua`: `SetAvailable` indexes available quests by NPC ID; a `TooltipDataProcessor` Unit post-call (fallback `OnTooltipSetUnit`) adds the lines to `GameTooltip`.
- `Libs/`: LibStub, CallbackHandler, HereBeDragons-2.0 + Pins, copied from GatherMate2.

## How it works
- `ADDON_LOADED`: settings. `PLAYER_LOGIN`: `LibQuestieDB.RequireContract(4)`, `Zones.Initialize`, `Player.Initialize`, register `GAMEPLAY_EVENTS`, `StartBuild`.
- Build: a coroutine reads every quest from `Quest.GetAllIds` once, 8 ms per frame. It keeps a record only for quests this race and class could take from an NPC, object or item. `pcall` per quest; failures are counted in `readErrors` and printed once in `OnBuilt`.
- `RequestUpdate(delay, force)` collapses event bursts into one `C_Timer.After`. `RunUpdate` refreshes completed and active quests, runs `Compute`, `Tooltip.SetAvailable`, then `Map.Draw` only if `Signature` (quest IDs + trivial flag) changed or `force` is set.
- `Draw` clears and redraws all pins: one icon per giver position (at most 25, merged within 1.5 map %), and one per drop area (8 % radius) for item quests. Hostile givers (`friendlyToFaction`) and items with more than 20 droppers are skipped. Styles: normal, repeatable (blue), trivial (gray); 0.75 scale on continent maps.
- `placeCache`, `itemCache` and `exclusiveCache` live for the session, since spawn data doesn't change.
- Completed = `C_QuestLog.GetAllCompletedQuestIDs` + this session's `QUEST_TURNED_IN` (`turnedIn`), because the server's list lags. Active also asks `C_QuestLog.IsOnQuest`, which sees quests under collapsed headers.

## Interface
- `/aqm` toggles, `size`, `ignore`/`unignore`/`ignored` (table in README). Also undocumented `/aqm refresh`: forced redraw.
- SavedVariables (account-wide) `AvailableQuestsMapDB`: `DEFAULTS` keys, `ignored[questID]`, `version` (2: continent icons default on; a version 1 `showOnContinent` is reset).
- World map "Show:" menu: `Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING")` adds checkboxes for Continent Maps, Holiday Quests and PvP Quests.
- Calls (toc `Dependencies: QuestieDB`): `LibQuestieDB.RequireContract`, the `Quest`, `Npc`, `Object` and `Item` entities (`Get`, `GetAllIds`), `Enum` (`sortKeys`, `zoneIDs`, `raceMaskById`), `Support.Get("ZoneDB")`. HereBeDragons-Pins: `AddWorldMapIconMap`, `RemoveAllWorldMapIcons`.

## Decisions (keep)
- Only LibQuestieDB's public API. Never copy from, generate from or depend on files inside the Questie addon: it churns, and the user doesn't want to update this addon for every Questie release. Accept gaps instead: there's no removed-quest blacklist, so `/aqm ignore` covers it.
- With Questie enabled too, only a chat note about double icons. Neither set is suppressed.
- Icons take hover but not clicks (`SetMouseClickEnabled(false)`), so the map still zooms and pans.
- Holiday quests are off by default with no check for running events. Profession-specialization quests are skipped.

## Gotchas
- OpenMap (fixed in 1.0.1): in combat OpenMap moves HereBeDragons icons onto its own layer, and its `GiveBackIcons` re-shows each on its old parent. For idle icons that parent is `UIParent`, which left a "!" mid-screen. `OffMap` (parent is `UIParent`) hides them from both the `OnShow` script and a `hooksecurefunc(icon, "Show")` hook. The hook is needed because `Show` on a frame already shown doesn't fire `OnShow`. Pool icons are created hidden on `UIParent`; keep that. Test: `tests/aqm_offmap_test.lua` (plain and `onshow`).
- A settings change must call `RequestUpdate(0, true)`: `Signature` only tracks the quest set.
- `HasBit` uses arithmetic, not `bit.band`: Forever race masks use bits above 32.
- QuestieDB ships zone tables as `return {...}` strings; `Decode` runs them through `loadstring`. Instance spawns are stored as (-1, -1) and drawn at the dungeon entrances.
- `QUEST_LOG_UPDATE` fires constantly, so it queues an update only when the active set changed. `QUEST_TURNED_IN` doesn't mark repeatables as completed.
- Unmet factions in `STARTS_BELOW_NEUTRAL` count as -36000. The legacy skill API fallback maps enUS names (`SKILL_IDS_BY_NAME`).
- Unit tooltips cover NPC givers only. Object givers and item drops show their quests only in the map icon's tooltip.

## Open
- The OpenMap bug also hits other HereBeDragons users such as Questie. Filing an OpenMap issue was offered to the user but hasn't been done.
