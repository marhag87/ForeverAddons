# CombinedBagOrder
Keeps your last bag sort at the bottom of Blizzard's combined bag so new loot fills in from the top, and adds a bank button that shows any character's saved bank from Syndicator in a copy of the bank window.

## Files
- `CombinedBagOrder.lua`: the bag order. `IsIgnoredBySort`, `IsGamepadUI`, `GetBagSizes`, `MeasureSortedRun`, `ApplyLayout`, the sort-settle logic (`AnyItemLocked`, `SaveSortResult`, `WaitForSortToSettle`), and the event frame.
- `BankView.lua`: the bank copy. Data (`CurrentCharacter`, `GetBankData`, `HasBankData`, `BankCharacters`), labels (`CharacterName`, `RaceIconMarkup`), the grid (`AcquireItemButton`, `SetSlotItem`, `LayoutPage`, `AcquirePageTab`, `UpdatePageTabs`, `UpdateBagButtons`), `ShowOwner`, `ShowPickedCharacter`, `Refresh`, `CreateView`, `ToggleView`, `CreateBagButton`.

## How it works
- A `hooksecurefunc(C_Container, "SortBags")` hook catches every sort (button, bag menu, macros). There is no "sort finished" event, so `WaitForSortToSettle` restarts a timer on each BAG_UPDATE_DELAYED or ITEM_LOCK_CHANGED: 1 s at first, then 0.4 s of quiet. `SaveSortResult` waits until no item is locked.
- `MeasureSortedRun` walks from the last bag down to the backpack, skipping bags with sorting disabled, and counts the unbroken run of filled slots from slot 1. This is the slots the sort filled.
- `ApplyLayout` post-hooks `ContainerFrameCombinedBags:UpdateItemLayout` (set up once Blizzard_UIPanels_Game loads). It builds the reading order (unsorted slots first, then the sorted run reversed) and repositions the buttons with `AnchorUtil.GridLayout`, using the frame's own initial anchor and anchor layout. Only positions change; every button keeps its bag and slot.
- At PLAYER_LOGIN it forces `SetSortBagsRightToLeft(false)` and `SetInsertItemsLeftToRight(false)`, because the layout needs sorting to start in the last bag and loot to go to the backpack first.
- Bank view: the button `CombinedBagOrderBankButton` sits on the combined bag, left of the search box, drawn with the cleanup button's art. It toggles `CombinedBagOrderBankFrame`, which is created on first use. That frame is built from Forever's bank templates (`CamelotBankItemButtonTemplate`, `BankPageTabTemplate`, `BankItemButtonBagTemplate`) and mirrors Camelot/BankFrame.xml.
- The view reads `Syndicator.API.GetByCharacterFullName(key)`: `bankTabs[i].slots` (tab 1 is the bank, 2 and up are bank bags), `containerInfo.characterBank` for the bag items, plus `money` and `details`. Slots are flattened and shown 88 per page in 8 columns.
- The character picker (`BankCharacters`) lists your current character plus every character with bank data that isn't hidden in Syndicator (`details.show.inventory == false`), SyndicatorSync mirrors included. Your own character comes first.

## Interface
- Per-character saved variable `CombinedBagOrderDB = { sortedCount[bag], bagSizes[bag] }`, rewritten whole after each sort.
- Syndicator callbacks: `BagCacheUpdate` and `MailCacheUpdate`, refreshed when the key is the shown character. The view hides on BANKFRAME_OPENED.
- OptionalDeps Syndicator. No slash commands.

## Decisions (keep)
- Keep it client-agnostic: the toc lists 120105 (retail) and 16001, and retail's AddOns folder links here too. The bank view is Forever-only. It is gated on `Syndicator.API`, `CamelotBankPanelItemButtonMixin` and `ContainerFrameCombinedBags`, so on retail only the bag order runs. Guard Forever-only APIs with nil checks, as `IsGamepadUI` does.
- Keep both listeners: SyndicatorSync fires only `MailCacheUpdate` for mirrors, so dropping it stops a synced bank from refreshing.
- The bank view is display-only and never touches the real bank. Shift-click links an item and Ctrl-click previews it. The template scripts are stripped, because they act on the real bank.
- The picker is placed at whole coordinates. The race icon is its own texture plus `OverrideText`, because an inline icon sits off-centre in the button. The pixel fixes are deliberate.

## Gotchas
- `ApplyLayout` falls back to Blizzard's order in these cases: in gamepad UI mode (Forever lays that out differently), when any bag size has changed since the sort (a swapped bag), when a button has an unknown bag ID, or when the button count doesn't match.
- Accounts without an authenticator get extra locked backpack buttons, so slot counts come from the buttons, not from `GetContainerNumSlots`.
- `C_Bank.FetchMaxNumBankTabs` can return 0; the code then falls back to 9 (the bank plus 8 bags).
- Bank tabs without slots mean the bank was never opened with Syndicator on, so the view shows `NO_DATA_TEXT`.
- `ToggleView` does nothing while the real `BankFrame` is shown.

## Open
- No test file. No recorded in-game check of browsing a mirrored character's bank.
