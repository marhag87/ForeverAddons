-- Combined Bag Order
-- Redraws Blizzard's combined bag so the slots filled by the last sort sit at the bottom,
-- first sorted item in the bottom-right corner, and every other slot fills from the top.
-- Only button positions change: every button keeps its real bag and slot.

local NUM_BAGS = Constants.InventoryConstants.NumBagSlots
local FIRST_UPDATE_DELAY = 1 -- seconds to wait for a sort to start moving items
local QUIET_DELAY = 0.4 -- seconds without bag changes before a sort counts as finished

local function IsIgnoredBySort(bag)
	if bag == Enum.BagIndex.Backpack then
		return C_Container.GetBackpackAutosortDisabled()
	end
	return C_Container.GetBagSlotFlag(bag, Enum.BagSlotFlags.DisableAutoSort)
end

-- Forever lays out the combined bag differently in gamepad mode; retail has no such mode.
local function IsGamepadUI()
	return InputUtil.IsGamepadUIEnabled ~= nil and InputUtil.IsGamepadUIEnabled()
end

local function GetBagSizes()
	local sizes = {}
	for bag = 0, NUM_BAGS do
		sizes[bag] = C_Container.GetContainerNumSlots(bag)
	end
	return sizes
end

-- With sorting set to start in the last bag, the sort fills each non-ignored bag from slot 1
-- upward, last bag first. What it placed is the unbroken run of items from that start.
local function MeasureSortedRun(sizes)
	local sortedCount = {}
	for bag = 0, NUM_BAGS do
		sortedCount[bag] = 0
	end
	for bag = NUM_BAGS, 0, -1 do
		if not IsIgnoredBySort(bag) then
			for slot = 1, sizes[bag] do
				if not C_Container.GetContainerItemID(bag, slot) then
					return sortedCount
				end
				sortedCount[bag] = slot
			end
		end
	end
	return sortedCount
end

local function ApplyLayout(frame)
	local db = CombinedBagOrderDB
	if not db or IsGamepadUI() then
		return
	end

	-- A swapped bag makes the saved run meaningless; keep Blizzard's order until the next sort.
	local sizes = GetBagSizes()
	for bag = 0, NUM_BAGS do
		if sizes[bag] ~= db.bagSizes[bag] then
			return
		end
	end

	-- Index the buttons by bag and slot. Accounts without an authenticator get extra locked
	-- backpack buttons, so slot counts come from the buttons rather than the bag sizes.
	local buttons, lastSlot, total = {}, {}, 0
	for bag = 0, NUM_BAGS do
		buttons[bag], lastSlot[bag] = {}, 0
	end
	for _, button in frame:EnumerateValidItems() do
		local bag, slot = button:GetBagID(), button:GetID()
		if not buttons[bag] then
			return
		end
		buttons[bag][slot] = button
		lastSlot[bag] = math.max(lastSlot[bag], slot)
		total = total + 1
	end

	-- Reading order, top-left first: unsorted slots in normal order, then the sorted run
	-- reversed so the first sorted item ends up in the bottom-right corner.
	local ordered = {}
	for bag = 0, NUM_BAGS do
		for slot = db.sortedCount[bag] + 1, lastSlot[bag] do
			table.insert(ordered, buttons[bag][slot])
		end
	end
	for bag = 0, NUM_BAGS do
		for slot = db.sortedCount[bag], 1, -1 do
			table.insert(ordered, buttons[bag][slot])
		end
	end
	if #ordered ~= total then
		return
	end

	-- Blizzard's grid puts its first frame in the bottom-right corner and fills leftward, then up.
	local placement = {}
	for i = #ordered, 1, -1 do
		table.insert(placement, ordered[i])
	end
	AnchorUtil.GridLayout(placement, frame:GetInitialItemAnchor(), frame:GetAnchorLayout())
end

local settleTimer
local WaitForSortToSettle

local function AnyItemLocked()
	for bag = 0, NUM_BAGS do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.isLocked then
				return true
			end
		end
	end
	return false
end

local function SaveSortResult()
	if AnyItemLocked() then
		WaitForSortToSettle(QUIET_DELAY)
		return
	end
	settleTimer = nil

	local sizes = GetBagSizes()
	CombinedBagOrderDB = { sortedCount = MeasureSortedRun(sizes), bagSizes = sizes }
	if ContainerFrameCombinedBags:IsShown() then
		ApplyLayout(ContainerFrameCombinedBags)
	end
end

-- There is no "sort finished" event, so wait until the bags stop changing.
function WaitForSortToSettle(delay)
	if settleTimer then
		settleTimer:Cancel()
	end
	settleTimer = C_Timer.NewTimer(delay, SaveSortResult)
end

-- The sort button, the bag menu and macros all go through this function.
hooksecurefunc(C_Container, "SortBags", function()
	WaitForSortToSettle(FIRST_UPDATE_DELAY)
end)

EventUtil.ContinueOnAddOnLoaded("Blizzard_UIPanels_Game", function()
	hooksecurefunc(ContainerFrameCombinedBags, "UpdateItemLayout", ApplyLayout)
end)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("ITEM_LOCK_CHANGED")
eventFrame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		-- The layout relies on sorting starting in the last bag and loot going to the backpack first.
		C_Container.SetSortBagsRightToLeft(false)
		C_Container.SetInsertItemsLeftToRight(false)
	elseif settleTimer then
		WaitForSortToSettle(QUIET_DELAY)
	end
end)
