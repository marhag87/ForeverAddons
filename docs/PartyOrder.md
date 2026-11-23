# PartyOrder
Reorders Blizzard's raid-style party frames (`CompactPartyFrame`) when you hold Ctrl+Alt and drag one party member onto another.

## Status
- Shelved: the user called it a dud on 2026-11-17. The code stays here but isn't linked into the game, and there is no junction in `_forever_\Interface\AddOns`. Don't relink or extend it unless the user asks. Why it was a dud isn't recorded, so ask before reviving it.

## Files
- `PartyOrder.lua`: everything. It holds the order (`GetUnitKey`, `GetOrderedMembers`, `SaveOrder`, `MoveMember`), the layout (`ApplyLayout`, `ReanchorPets`) and the drag overlays (`GetOverlay`, `RefreshOverlays`, `StyleOverlays`, `ShowGhost`, `OnDragStart`/`EndDrag`, the `driver` OnUpdate). Then come `HookPartyFrame`, `InitDB`, the events and the slash command.

## How it works
- `HookPartyFrame` post-hooks `CompactPartyFrame.updateLayoutFunc`, and `CompactPartyFrame_Generate` too if Blizzard creates the frame later. After every Blizzard re-layout, `ApplyLayout` re-anchors `CompactPartyFrameMember1..5` in the saved order. It mirrors `CompactRaidGroup_UpdateLayout`, plus the border and pet anchoring from `CompactPartyFrameMixin:UpdateLayout`. Horizontal or vertical comes from `EditModeManagerFrame:ShouldRaidFrameUseHorizontalRaidGroups`.
- In combat it sets `applyPending` and re-applies at PLAYER_REGEN_ENABLED. It also re-applies on PLAYER_ENTERING_WORLD and on UNIT_NAME_UPDATE for player and partyN, because names can arrive after the roster.
- Drag: plain `Button` overlays on UIParent (HIGH strata) cover each visible member while Ctrl+Alt is held. They aren't shown in combat or in Edit Mode. A ghost name label follows the cursor, and a drop calls `MoveMember`, then `SaveOrder`, then `ApplyLayout`.
- Members with no saved spot go after the others, in Blizzard's order. Hidden frames go at the end of the chain.

## Interface
- `/partyorder list`, `/partyorder reset`; anything else prints help.
- Saved variable `PartyOrderDB.order`: a list of "Name-Realm" keys, with spaces and hyphens stripped from the realm as `GetNormalizedRealmName` does. Members who aren't in the group keep their place in the list.

## Decisions (keep)
- To stay clear of taint, it never touches Blizzard's units or sorting. It only calls SetPoint on the existing frames. Dragging goes through separate overlays, so the secure buttons keep their own scripts.

## Gotchas
- MODIFIER_STATE_CHANGED can be missed, for example when alt-tabbing. The `driver` OnUpdate therefore polls the modifier keys and the mouse button while the overlays are up.
- The overlays swallow clicks meant for the unit frames while Ctrl+Alt is held.
- `MoveMember` gives up, with a chat message, if any member's name is unknown or secret.

## Open
- Only Interface 16001. Its toc has no icon or category, unlike the other addons.
