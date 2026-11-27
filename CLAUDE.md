# ForeverAddons

Small one-off WoW addons, mostly for WoW: Forever. One folder per addon; README.md has a one-line summary of each.

## Layout
- Addon folders are what gets installed: `<WoW>\_forever_\Interface\AddOns\<Addon>` is a directory junction into this repo (CombinedBagOrder also into `_retail_`), so edits are live after a `/reload`. Keep docs, tests and notes out of addon folders.
- `docs/<Addon>.md`: agent notes per addon (files, flow, decisions to keep, open items). Read only the one for the addon at hand.
- `tests/`: mock tests, `sh tests/run.sh` (see Testing).
- PartyOrder stays in the repo but isn't linked into the game (the user called it a dud).

## Workflow
- Commit and push (main → origin) only when the user says so. Messages: `<Addon>: <what changed>`, then a short body.
- Every user-visible change bumps `## Version` in the addon's .toc. Update the addon's README row and `docs/<Addon>.md` when behaviour or structure changes.
- The user tests in game and reports back; say plainly what hasn't been tested in game.
- New addon: folder with a .toc (`## Interface: 16001`), README row, `docs/<Addon>.md`, then a junction (`cmd /c mklink /J <AddOns>\<Addon> <repo>\<Addon>`). Remove a junction with `cmd /c rmdir`, never a recursive delete.
- User preferences: no chat output except an explicit debug command; settings by slash command; reuse Blizzard's own art, atlases and templates so it looks standard; small addons that do one thing.
- Never copy code from addons whose license forbids it (Forever Fishing is All Rights Reserved): learn the mechanism, write it fresh. Quest data: only LibQuestieDB's public API, never files inside Questie (it churns).

## The Forever client
- Interface 16001, enUS: Classic rules on a retail (Midnight-era) client. Retail APIs (C_Container, C_TooltipInfo, C_Traits, ItemButton, atlases) with Classic content. `/reload` picks up new addons and .toc edits.
- Blizzard's UI source: GitHub Gethe/wow-ui-source, branch `forever`; Forever's own files sit in `Camelot` folders, API docs in `Blizzard_APIDocumentationGenerated`. Fetch: `gh api "repos/Gethe/wow-ui-source/contents/Interface/AddOns/<path>?ref=forever" -H "Accept: application/vnd.github.raw"`; list every file: `gh api "repos/Gethe/wow-ui-source/git/trees/forever?recursive=1"`.
- Secret values: in instances, and for nameplate units even outside, unit and combat values can be secret, and comparing or doing math on one errors. Check `issecretvalue(x)` first and quietly skip.
- No combat log for addons: registering COMBAT_LOG_EVENT_UNFILTERED triggers a blocked-action popup; UNIT_COMBAT amounts are secret. Item chance-on-hit procs do fire UNIT_SPELLCAST_SUCCEEDED, but Windfury procs leave no trace, so proc alerts were scrapped.
- `/run` code carries strong taint: something blocked from `/run` may still work from an addon.
- Casting a spell on a bag item: `/run C_Container.UseContainerItem(...)` after `/cast` is blocked ("ForceTaint_Strong"), and secure overlay buttons over Blizzard's bag slots got no clicks in game (Comprehend, scrapped 2026-11-25, cause not found). What's left: `/cast X` then `/use <bag> <slot>` in a macro, or a secure button's `target-bag`/`target-slot` fired by a key binding.
- Never write into Blizzard tables or frames that handle secret values: the taint breaks them until /reload.
- Secure buttons: no attribute changes, Show/Hide or moves in combat (nor of the frames they're anchored to): queue for PLAYER_REGEN_ENABLED. ActionButtonUseKeyDown is on, so `RegisterForClicks("AnyUp", "AnyDown")`.
- Addon messages: party and whisper work (even though `C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()` says true) but arrive heavily out of order, and some are lost or 8 s+ late; in dungeons they're throttled to about 1/s after a burst of 10. AceComm is unsafe: number chunks, reassemble by number, resend gaps (SyndicatorSync's Comms.lua does this). `string.format("%d")` errors above 2^31.
- Character names are "First Surname" (regionally unique); whispers and invites need the full name, and `UnitName` returns the two parts separately.
- `GetInventoryItemsForSlot` fills `t[location]` with item links, not IDs: read the ID from the bag slot. Decode locations with the client's `ITEM_INVENTORY_LOCATION_*` globals, not hardcoded flags.
- Item and spell text loads in the background: a tooltip read too early lacks its "Use:" line. Check `C_Item.IsItemDataCachedByID` / `C_Spell.IsSpellDataCached` and look again later.
- Tooltip and buff matching is English text, which is fine on this enUS client.
- Equipping from addon code (container pickup, then `PickupInventoryItem`) works out of combat without a hardware event.

## Testing
- Lua 5.4 comes from the lua-language-server VS Code extension: `~/.vscode/extensions/sumneko.lua-*/server/bin/lua-language-server.exe <test.lua> <addon file> [arg]`. `sh tests/run.sh` runs every test.
- Each test loads one addon file into a mock game (frames, C_ APIs, events, combat lockdown) and drives events. "ok" from most of them only means no Lua error and no secure frame touched in combat; the printed report shows behaviour. `upkeep_loading_test`, `upkeep_selfbuff_test`, `tandem_buff_test`, `threatgap_fury_test`, `bobber_test`, `link_test`, `aqm_offmap_test` and the mounted part of `upkeep_rest_test` assert (PASS/FAIL). For a new test, copy the nearest one.
- Lint: `lua-language-server.exe --check=<addon dir> --checklevel=Warning --check_out_path=<out>.json`. Undefined WoW globals are expected; compare against a lint of the last commit to spot new findings.
- The real test is in game. When something doesn't show, ask for the addon's debug command output (e.g. `/upkeep debug`) or a screenshot. Syndicator's saved variables (`WTF/Account/*/SavedVariables/Syndicator.lua`) show what every character carries.
