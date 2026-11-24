# TrinketQueue
Your two trinket slots in a frame of their own. A click or a key binding uses a trinket; hovering a slot shows an arrow above it that lists the trinkets in your bags, and the one picked is equipped as soon as you're out of combat.

## Files
- `TrinketQueue.lua`: everything. Sections: items (`BagAndSlot`, `BagTrinkets`), swapping (`Busy`, `Swapping`, `Find`, `Equip`, `Process`), the movable holder (`SavePosition`/`ApplyPosition`, `StartMove`/`StopMove`), slots (`NewSlot`, `SlotEnter`/`SlotLeave`, `UpdateSlot`, `UpdateShown`, `UpdateHotkeys`), the flyout (`Fill`, `ShowPage`, `Pick`, `Inside`, `UpdateArrow`), then events.
- `Bindings.xml`: two CLICK bindings, `TrinketQueueSlot13:Keybind` and `TrinketQueueSlot14:Keybind`.

## How it works
- The slots are `ItemButton` + `SecureActionButtonTemplate` frames named `TrinketQueueSlot13`/`14`, with `type=macro`, `macrotext=/use 13` (or 14). Left is slot 13, right is 14. The holder is exactly the two slots; no frame art round them.
- Arrows copy the totem bar (`MultiCastSlotButton_OnEnter`, `MultiCastFlyoutFrameOpenButton_Show`/`_Hide`): hidden at rest, shown on entering the slot, kept by `UpdateArrow` while the mouse is on the slot or arrow, and hidden while that slot's flyout is open. Flush against the slot so the mouse never crosses a gap. They're plain Buttons, so showing them in combat is fine.
- An open flyout sits straight above its slot, where the arrow was. Unlike the totem bar it has no close arrow on top (tried, and the user found it fine without); Escape or a click elsewhere closes it.
- `queue[invSlot] = { id, bag, slot, tries, at }`. `Pick` queues a bag trinket (taking the same bag slot out of the other slot's queue), then calls `Process` at once.
- `Process` runs from events and from an OnUpdate ticker (every `TICK`, only while the queue isn't empty). It drops entries that are satisfied, does nothing while `Busy` (combat, dead, cursor holding something, casting), and makes one `Equip` attempt per call. After `MAX_TRIES` attempts, `RETRY_AFTER` seconds apart, or once the item is gone from the bags, it drops the entry silently.
- `Equip`: `ClearCursor`, `C_Container.PickupContainerItem`, `C_PaperDollInfo.CursorCanGoInSlot`, `PickupInventoryItem`. This works deferred at PLAYER_REGEN_ENABLED, with no hardware event.
- The flyout has no background (the user removed Blizzard's EquipmentFlyout art): bare item buttons in columns of 5 growing up from the slot, spaced like the slots (`ITEM_GAP = SLOT_GAP`), 4 columns (20) per page side by side, prev/next on top. Only the slot highlight (`UI-GearManager-ItemButton-Highlight`) is Blizzard's art.
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
- The holder (slots and arrows) is in the LOW strata, under the action bars' MEDIUM, so the totem bar's flyout opens over the slots (1.1). The trinket list (`TrinketQueueFlyout`) stays HIGH.

## Gotchas
- `GetInventoryItemsForSlot` returns item links on Forever, so `BagTrinkets` reads each ID from the bag slot. Before that fix, flyout picks silently did nothing.
- Bank locations are skipped; only bags count.
- A CLICK binding with the custom button name "Keybind" gets suffix `-Keybind`, so modifier keys in the binding aren't caught by the `shift-type1` NOOP.
- The holder can't move in combat (it holds secure children): `StopMove` also runs on PLAYER_REGEN_DISABLED.

## Open
- Covered by `tests/tq_test.lua`; everything above was confirmed in game.
