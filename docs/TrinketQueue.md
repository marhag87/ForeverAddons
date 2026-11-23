# TrinketQueue
Your two trinket slots in a frame of their own, drawn like the character sheet's. A click or a key binding uses a trinket; the arrow above a slot lists the trinkets in your bags, and the one picked is equipped as soon as you're out of combat.

## Files
- `TrinketQueue.lua`: everything. Sections: items (`BagAndSlot`, `BagTrinkets`), swapping (`Busy`, `Swapping`, `Find`, `Equip`, `Process`), the movable holder (`SavePosition`/`ApplyPosition`, `StartMove`/`StopMove`), slots (`NewSlot`, `UpdateSlot`, `UpdateShown`, `UpdateHotkeys`), the flyout (`PIECES`/`LayBackground`, `Fill`, `ShowPage`, `Pick`, `Inside`), then events.
- `Bindings.xml`: two CLICK bindings, `TrinketQueueSlot13:Keybind` and `TrinketQueueSlot14:Keybind`.

## How it works
- The slots are `ItemButton` + `SecureActionButtonTemplate` frames named `TrinketQueueSlot13`/`14`, with `type=macro`, `macrotext=/use 13` (or 14). Left is slot 13, right is 14.
- `queue[invSlot] = { id, bag, slot, tries, at }`. `Pick` queues a bag trinket (taking the same bag slot out of the other slot's queue), then calls `Process` at once.
- `Process` runs from events and from an OnUpdate ticker (every `TICK`, only while the queue isn't empty). It drops entries that are satisfied, does nothing while `Busy` (combat, dead, cursor holding something, casting), and makes one `Equip` attempt per call. After `MAX_TRIES` attempts, `RETRY_AFTER` seconds apart, or once the item is gone from the bags, it drops the entry silently.
- `Equip`: `ClearCursor`, `C_Container.PickupContainerItem`, `C_PaperDollInfo.CursorCanGoInSlot`, `PickupInventoryItem`. This works deferred at PLAYER_REGEN_ENABLED, with no hardware event.
- The flyout copies Blizzard's EquipmentFlyout art and layout (`UI-GearManager-Flyout` pieces) rather than calling Blizzard's code: 5 per row, 20 per page, with prev/next above. It closes on Escape (`UISpecialFrames`) and on a click outside it (`GLOBAL_MOUSE_DOWN` while shown).
- Out of combat the frame hides when you have no trinkets at all.

## Interface
- Saved variable `TrinketQueueDB`: `x`, `y` (the holder's BOTTOMLEFT on UIParent).
- Key bindings show in the Key Bindings menu under TrinketQueue as "Use left trinket" and "Use right trinket" (`BINDING_NAME_*` set in the Lua). The key text sits top right on the slot, styled like an action button's.
- No slash command and no chat output (user's choice).

## Decisions (keep)
- Shift-drag moves the frame; a plain drag does nothing. Shift-clicks on the slots and arrows are ignored (the `shift-type1` NOOP attribute), so a move never fires a trinket.
- A right-click on a slot cancels its queued swap (`*type2` NOOP plus PostClick).
- The waiting icon in a slot's top-left corner shows only while the swap waits on combat, not during an out-of-combat swap (`Swapping`), which made it flicker.
- Binding names carry no "TrinketQueue:" prefix.

## Gotchas
- `GetInventoryItemsForSlot` returns item links on Forever, so `BagTrinkets` reads each ID from the bag slot. Before that fix, flyout picks silently did nothing.
- Bank locations are skipped; only bags count.
- A CLICK binding with the custom button name "Keybind" gets suffix `-Keybind`, so modifier keys in the binding aren't caught by the `shift-type1` NOOP.
- The holder can't move in combat (it holds secure children): `StopMove` also runs on PLAYER_REGEN_DISABLED.

## Open
- Covered by `tests/tq_test.lua`; everything above was confirmed in game.
