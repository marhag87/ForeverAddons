-- Party Order
-- Puts Blizzard's raid-style party frames (CompactPartyFrame) in an order you choose.
-- Hold Ctrl+Alt and drag a party member onto another one to move it to that spot.
--
-- How it stays clear of taint:
--  * Blizzard's units and sorting are never touched. The existing member frames are only
--    re-anchored (SetPoint), and only out of combat, because they are protected buttons.
--  * Every Blizzard re-layout of the party frame goes through CompactPartyFrame.updateLayoutFunc.
--    It is post-hooked with hooksecurefunc and the saved order is re-applied right after it.
--    If that happens in combat, the re-apply waits for PLAYER_REGEN_ENABLED.
--  * Dragging uses separate, plain overlay frames, so the secure buttons keep their own scripts.

local MAX_MEMBERS = MEMBERS_PER_RAID_GROUP or 5
local PREFIX = "|cff33ff99Party Order|r: "

local partyFrame        -- CompactPartyFrame, once Blizzard has created it
local applyPending = false
local overlays = {}     -- overlays[i] covers CompactPartyFrameMember<i>
local dragSource        -- member frame being dragged, if any
local ghost             -- name label that follows the cursor while dragging
local driver = CreateFrame("Frame")

local function Print(msg)
	print(PREFIX .. msg)
end

local function IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

-- "Name-Realm" for a unit, or nil when it isn't known yet (or is hidden from addons right now).
local function GetUnitKey(unit)
	if not unit or IsSecret(unit) then
		return nil
	end
	local exists = UnitExists(unit)
	if IsSecret(exists) or not exists then
		return nil
	end
	local name, realm = UnitName(unit)
	if IsSecret(name) or IsSecret(realm) or not name or name == "" or name == UNKNOWNOBJECT then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName()
	end
	if not realm or realm == "" then
		return nil
	end
	-- Same form as GetNormalizedRealmName ("Azjol-Nerub" -> "AzjolNerub"), so a key is identical
	-- no matter which of your characters (and realm) you're looking from.
	return name .. "-" .. realm:gsub("[%s%-]", "")
end

local function GetMemberFrame(index)
	return _G["CompactPartyFrameMember" .. index]
end

-- Returns the member frames in the order they should be on screen:
-- shown frames sorted by the saved order (anyone without a saved spot goes after the others,
-- in Blizzard's order), plus the hidden frames, which go at the end of the chain like Blizzard's.
local function GetOrderedMembers()
	local rank = {}
	for i, key in ipairs(PartyOrderDB.order) do
		rank[key] = i
	end

	local shown, hidden = {}, {}
	local sortRank, blizzardIndex = {}, {}
	for i = 1, MAX_MEMBERS do
		local frame = GetMemberFrame(i)
		if frame then
			blizzardIndex[frame] = i
			if frame:IsShown() then
				local key = GetUnitKey(frame.unit)
				sortRank[frame] = (key and rank[key]) or (1000 + i)
				shown[#shown + 1] = frame
			else
				hidden[#hidden + 1] = frame
			end
		end
	end

	table.sort(shown, function(a, b)
		if sortRank[a] ~= sortRank[b] then
			return sortRank[a] < sortRank[b]
		end
		return blizzardIndex[a] < blizzardIndex[b]
	end)
	return shown, hidden
end

-- Same pet anchoring as CompactPartyFrameMixin:UpdateLayout when the border is hidden,
-- since the pets then hang off a member frame (the first one if horizontal, the last one if vertical).
local function ReanchorPets(horizontal, firstShown, lastShown)
	local anchor = (horizontal and firstShown or lastShown) or partyFrame
	local isFirstShownPet = true
	for _, pet in ipairs(partyFrame.petUnitFrames or {}) do
		pet:ClearAllPoints()
		if horizontal then
			if isFirstShownPet then
				pet:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT")
			else
				pet:SetPoint("LEFT", anchor, "RIGHT")
			end
		else
			pet:SetPoint("TOP", anchor, "BOTTOM")
		end
		if pet:IsShown() then
			anchor = pet
			isFirstShownPet = false
		end
	end
end

local RefreshOverlays -- defined below

-- Re-anchors the member frames in the saved order. Mirrors CompactRaidGroup_UpdateLayout,
-- just walking the frames in our order instead of Member1..Member5.
local function ApplyLayout()
	if not partyFrame then
		return
	end
	if InCombatLockdown() then
		applyPending = true
		return
	end
	applyPending = false

	local shown, hidden = GetOrderedMembers()
	local frames = {}
	for _, frame in ipairs(shown) do
		frames[#frames + 1] = frame
	end
	for _, frame in ipairs(hidden) do
		frames[#frames + 1] = frame
	end
	if #frames == 0 then
		return
	end

	local horizontal = EditModeManagerFrame:ShouldRaidFrameUseHorizontalRaidGroups(partyFrame.groupType)
	local titleHeight = partyFrame.title:GetHeight()

	-- Clear every member first so the new chain can never anchor a frame to one that depends on it.
	for _, frame in ipairs(frames) do
		frame:ClearAllPoints()
	end
	for i, frame in ipairs(frames) do
		if i == 1 then
			if horizontal then
				frame:SetPoint("TOPLEFT", partyFrame, "TOPLEFT", 0, -titleHeight)
			else
				frame:SetPoint("TOP", partyFrame, "TOP", 0, -titleHeight)
			end
		elseif horizontal then
			frame:SetPoint("LEFT", frames[i - 1], "RIGHT", 0, 0)
		else
			frame:SetPoint("TOP", frames[i - 1], "BOTTOM", 0, 0)
		end
	end

	local border = partyFrame.borderFrame
	if border and border:IsShown() then
		-- Pets anchor to the border in this case, so they follow it on their own.
		border:ClearAllPoints()
		border:SetPoint("TOPLEFT", frames[1], "TOPLEFT", -2, 2)
		border:SetPoint("BOTTOMRIGHT", shown[#shown] or frames[1], "BOTTOMRIGHT", 2, -3)
	else
		ReanchorPets(horizontal, shown[1], shown[#shown])
	end

	RefreshOverlays()
end

-- Saves `keys` (the members now in the group, in their new order) into the saved order.
-- They take over the spots they already held in the list, so people who aren't in the group
-- right now keep their place for when they come back.
local function SaveOrder(keys)
	local order = PartyOrderDB.order
	local present, listed = {}, {}
	for _, key in ipairs(keys) do
		present[key] = true
	end
	for _, key in ipairs(order) do
		listed[key] = true
	end
	for _, key in ipairs(keys) do
		if not listed[key] then
			order[#order + 1] = key
		end
	end
	local nextKey = 1
	for i, key in ipairs(order) do
		if present[key] then
			order[i] = keys[nextKey]
			nextKey = nextKey + 1
		end
	end
end

local function MoveMember(source, target)
	local shown = GetOrderedMembers()
	local from, to
	for i, frame in ipairs(shown) do
		if frame == source then
			from = i
		elseif frame == target then
			to = i
		end
	end
	if not from or not to then
		return
	end
	table.remove(shown, from)
	table.insert(shown, to, source)

	local keys, seen = {}, {}
	for _, frame in ipairs(shown) do
		local key = GetUnitKey(frame.unit)
		if not key or seen[key] then
			Print("Couldn't read every party member's name yet, try again in a moment.")
			return
		end
		seen[key] = true
		keys[#keys + 1] = key
	end

	SaveOrder(keys)
	ApplyLayout()
end

---------------------------------------------------------------------------
-- Ctrl+Alt drag overlays
---------------------------------------------------------------------------

local BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8X8",
	edgeFile = "Interface\\Buttons\\WHITE8X8",
	edgeSize = 1,
}

local function ModifiersHeld()
	return IsControlKeyDown() and IsAltKeyDown()
end

local function CanDrag()
	return partyFrame ~= nil
		and partyFrame:IsVisible()
		and not InCombatLockdown()
		and not EditModeManagerFrame:IsEditModeActive()
end

local function GetHoveredOverlay()
	for i = 1, MAX_MEMBERS do
		local overlay = overlays[i]
		if overlay and overlay:IsShown() and overlay:IsMouseOver() then
			return overlay
		end
	end
end

local function StyleOverlays()
	local hovered = GetHoveredOverlay()
	for i = 1, MAX_MEMBERS do
		local overlay = overlays[i]
		if overlay and overlay:IsShown() then
			if overlay.member == dragSource then
				overlay:SetBackdropColor(0, 0, 0, 0.6)
				overlay:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
			elseif overlay == hovered and dragSource then
				overlay:SetBackdropColor(0.2, 1, 0.2, 0.3)
				overlay:SetBackdropBorderColor(0.2, 1, 0.2, 1)
			elseif overlay == hovered then
				overlay:SetBackdropColor(1, 0.82, 0, 0.2)
				overlay:SetBackdropBorderColor(1, 0.82, 0, 1)
			else
				overlay:SetBackdropColor(1, 0.82, 0, 0.06)
				overlay:SetBackdropBorderColor(1, 0.82, 0, 0.8)
			end
		end
	end
end

local function ShowGhost(member)
	if not ghost then
		ghost = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
		ghost:SetFrameStrata("TOOLTIP")
		ghost:SetBackdrop(BACKDROP)
		ghost:SetBackdropColor(0, 0, 0, 0.8)
		ghost:SetBackdropBorderColor(1, 0.82, 0, 1)
		ghost.text = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		ghost.text:SetPoint("CENTER")
	end

	local unit = member.unit
	local name = unit and UnitName(unit)
	if not name or IsSecret(name) then
		name = "?"
	end
	ghost.text:SetText(name)

	local _, class = UnitClass(unit or "")
	local color = class and not IsSecret(class) and RAID_CLASS_COLORS[class]
	if color then
		ghost.text:SetTextColor(color.r, color.g, color.b)
	else
		ghost.text:SetTextColor(1, 1, 1)
	end

	ghost:SetSize(ghost.text:GetStringWidth() + 16, 22)
	ghost:Show()
end

local function MoveGhostToCursor()
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	ghost:ClearAllPoints()
	ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 14, y / scale - 6)
end

local function EndDrag(drop)
	local source = dragSource
	if not source then
		return
	end
	local target = drop and GetHoveredOverlay()
	dragSource = nil
	if ghost then
		ghost:Hide()
	end
	if target and target.member ~= source and CanDrag() then
		MoveMember(source, target.member)
	end
	RefreshOverlays()
end

local function OnDragStart(overlay)
	if not CanDrag() then
		return
	end
	dragSource = overlay.member
	ShowGhost(dragSource)
	MoveGhostToCursor()
	StyleOverlays()
end

local function OnDragStop()
	EndDrag(true)
end

local function GetOverlay(index)
	local overlay = overlays[index]
	if not overlay then
		local member = GetMemberFrame(index)
		if not member then
			return nil
		end
		overlay = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
		overlay:SetFrameStrata("HIGH")
		overlay:SetAllPoints(member)
		overlay:SetBackdrop(BACKDROP)
		overlay:EnableMouse(true)
		overlay:RegisterForDrag("LeftButton")
		overlay:SetScript("OnDragStart", OnDragStart)
		overlay:SetScript("OnDragStop", OnDragStop)
		overlay:Hide()
		overlay.member = member
		overlays[index] = overlay
	end
	return overlay
end

-- Shows an overlay over every visible member while Ctrl+Alt is held (or a drag is going on).
-- The overlays catch the mouse, so clicks don't reach the unit frames while they're up.
function RefreshOverlays()
	if dragSource and not CanDrag() then
		dragSource = nil
		if ghost then
			ghost:Hide()
		end
	end

	local active = dragSource ~= nil or (ModifiersHeld() and CanDrag())
	for i = 1, MAX_MEMBERS do
		local member = GetMemberFrame(i)
		if active and member and member:IsVisible() then
			local overlay = GetOverlay(i)
			if overlay then
				overlay:Show()
			end
		elseif overlays[i] then
			overlays[i]:Hide()
		end
	end

	driver:SetShown(active)
	if active then
		StyleOverlays()
	end
end

-- Runs only while the overlays are up: moves the ghost, and hides everything once
-- Ctrl+Alt is let go (MODIFIER_STATE_CHANGED can be missed, e.g. when alt-tabbing).
driver:Hide()
driver:SetScript("OnUpdate", function()
	if dragSource then
		if not CanDrag() then
			RefreshOverlays()
			return
		end
		if not IsMouseButtonDown("LeftButton") then
			EndDrag(true)
			return
		end
		MoveGhostToCursor()
		StyleOverlays()
	elseif not (ModifiersHeld() and CanDrag()) then
		RefreshOverlays()
	else
		StyleOverlays()
	end
end)

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local function HookPartyFrame()
	if partyFrame or not CompactPartyFrame or type(CompactPartyFrame.updateLayoutFunc) ~= "function" then
		return
	end
	partyFrame = CompactPartyFrame
	hooksecurefunc(partyFrame, "updateLayoutFunc", ApplyLayout)
	ApplyLayout()
end

local function InitDB()
	if type(PartyOrderDB) ~= "table" then
		PartyOrderDB = {}
	end
	local clean, seen = {}, {}
	if type(PartyOrderDB.order) == "table" then
		for _, key in ipairs(PartyOrderDB.order) do
			if type(key) == "string" and not seen[key] then
				seen[key] = true
				clean[#clean + 1] = key
			end
		end
	end
	PartyOrderDB.order = clean
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("MODIFIER_STATE_CHANGED")
events:RegisterEvent("UNIT_NAME_UPDATE")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= "PartyOrder" then
			return
		end
		self:UnregisterEvent("ADDON_LOADED")
		InitDB()
		if type(CompactPartyFrame_Generate) == "function" then
			hooksecurefunc("CompactPartyFrame_Generate", HookPartyFrame)
		end
		HookPartyFrame()
	elseif event == "PLAYER_LOGIN" then
		HookPartyFrame()
	elseif event == "PLAYER_ENTERING_WORLD" then
		ApplyLayout()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if applyPending then
			ApplyLayout()
		end
		RefreshOverlays()
	elseif event == "PLAYER_REGEN_DISABLED" then
		RefreshOverlays()
	elseif event == "MODIFIER_STATE_CHANGED" then
		RefreshOverlays()
	elseif event == "UNIT_NAME_UPDATE" then
		-- A member's name came in after the roster update; now we know where they go.
		if arg1 and not IsSecret(arg1) and (arg1 == "player" or arg1:match("^party%d$")) then
			ApplyLayout()
		end
	end
end)

SLASH_PARTYORDER1 = "/partyorder"
SlashCmdList.PARTYORDER = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "reset" then
		wipe(PartyOrderDB.order)
		ApplyLayout()
		Print("Saved order cleared, back to Blizzard's order.")
	elseif msg == "list" then
		if #PartyOrderDB.order == 0 then
			Print("No saved order yet.")
		else
			Print("Saved order:")
			for i, key in ipairs(PartyOrderDB.order) do
				print(("  %d. %s"):format(i, key))
			end
		end
	else
		Print("Hold Ctrl+Alt and drag a party member onto another one to move it there (out of combat).")
		Print("/partyorder list - show the saved order")
		Print("/partyorder reset - forget the saved order")
	end
end
