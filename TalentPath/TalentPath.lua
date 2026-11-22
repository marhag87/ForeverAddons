-- TalentPath.lua
-- Follows a Wowhead talent order: paste a talent calculator link for each spec into the box
-- under the talent window, and the window marks the next talents to take, as many as you have
-- points for. It goes by the points
-- you've spent, never by level, so points that come early (legacy points) work too. If your
-- talents stop matching the order, it shows a warning instead and nothing else.
--
-- Forever's talent window is retail's trait system holding the three classic trees, one trait
-- group each. Wowhead counts a tree's talents left to right along each row, rows top to
-- bottom, so the game's talents are put in that order by position.
--
-- With Upkeep loaded, the next talent also shows as a reminder in Upkeep's row while you have
-- points to spend; a click opens the talent window.

local _, ns = ...
local Link = ns.Link

local REMINDER = "TalentPath.next"

-- Extra points to pretend you have, from /talentpath preview, to see the marks without a level.
ns.previewPoints = 0
local playerClass = select(2, UnitClass("player")):lower()

local chardb -- TalentPathCharDB: { links = { [spec group] = link } }

local function Print(text)
	print("|cff33ff99TalentPath:|r " .. text)
end

local function SpecGroup()
	return C_SpecializationInfo.GetActiveSpecGroup() or 1
end

---------------------------------------------------------------------------------------------
-- The game's talents

-- The active spec's talents, Wowhead's way: trees = { { node info, ... } x3 }, plus the points
-- left to spend. Ranks include clicks in the talent window not yet applied.
local function ReadTalents()
	local group = SpecGroup()
	local configID = C_SpecializationInfo.GetCombatConfigIDForSpecGroup(group)
		or (C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID())
	local config = configID and C_Traits.GetConfigInfo(configID)
	local treeID = config and config.treeIDs and config.treeIDs[1]
	if not treeID then
		return
	end
	-- In the order the talent window lays the tree headers out, left to right.
	local groups = C_Traits.GetGroupDisplayInfoByTreeID(treeID)
	if not groups or #groups == 0 then
		return
	end
	local treeOfGroup, trees = {}, {}
	for i, info in ipairs(groups) do
		treeOfGroup[info.groupID] = i
		trees[i] = {}
	end
	for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID)) do
		local node = C_Traits.GetNodeInfo(configID, nodeID)
		if node and node.ID ~= 0 and node.isVisible and node.maxRanks > 0 then
			for _, groupID in ipairs(node.groupIDs or {}) do
				local t = treeOfGroup[groupID]
				if t then
					table.insert(trees[t], node)
					break
				end
			end
		end
	end
	for _, nodes in ipairs(trees) do
		table.sort(nodes, function(a, b)
			if a.posY ~= b.posY then
				return a.posY < b.posY
			end
			return a.posX < b.posX
		end)
	end
	local currency = C_Traits.GetTreeCurrencyInfo(configID, treeID, false)
	local unspent = currency and currency[1] and currency[1].quantity or 0
	return { configID = configID, trees = trees, unspent = unspent }
end

-- spellID, name and icon of a talent.
local function TalentSpell(configID, node)
	local entryID = node.activeEntry and node.activeEntry.entryID or (node.entryIDs and node.entryIDs[1])
	local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
	local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
	if not def then
		return nil, "?", 134400
	end
	local spellID = def.overriddenSpellID or def.spellID
	local name = def.overrideName and def.overrideName ~= "" and def.overrideName
		or spellID and C_Spell.GetSpellName(spellID) or "?"
	local icon = def.overrideIcon and def.overrideIcon ~= 0 and def.overrideIcon
		or spellID and C_Spell.GetSpellTexture(spellID) or 134400
	return spellID, name, icon
end

-- Why a build doesn't fit these talents, or nil if it does.
local function Misfit(build, talents)
	if build.class:gsub("%A", "") ~= playerClass:gsub("%A", "") then
		return "the link is for a " .. build.class .. "."
	end
	for t, ranks in ipairs(build.trees) do
		local nodes = talents.trees[t]
		for index, final in ipairs(ranks) do
			if final > 0 and not (nodes and nodes[index] and final <= nodes[index].maxRanks) then
				return "the link doesn't fit this character's talent trees. Wowhead may be out of date."
			end
		end
	end
end

---------------------------------------------------------------------------------------------
-- Where you are in the build

-- { status, message, picks, talents }. status: "none" (no link for this spec), "wait" (talents
-- not readable yet), "bad" (link unusable), "off" (talents don't follow the order), "done", or
-- "on" with picks = the next talents to take, one per point you have.
local function Evaluate()
	local link = chardb.links[SpecGroup()]
	if not link then
		return { status = "none" }
	end
	local build, err = Link.Parse(link)
	if not build then
		return { status = "bad", message = err .. "." }
	end
	local talents = ReadTalents()
	if not talents then
		return { status = "wait" }
	end
	local misfit = Misfit(build, talents)
	if misfit then
		return { status = "bad", message = misfit }
	end

	local spent = 0
	for _, nodes in ipairs(talents.trees) do
		for _, node in ipairs(nodes) do
			spent = spent + node.ranksPurchased
		end
	end
	if spent > #build.steps then
		return { status = "off", message = "you've spent more points than the build has.", talents = talents }
	end
	-- Each talent's rank after that many points of the order.
	local expected = {}
	for s = 1, spent do
		local step = build.steps[s]
		expected[talents.trees[step.tree][step.index]] = step.rank
	end
	for _, nodes in ipairs(talents.trees) do
		for _, node in ipairs(nodes) do
			local want = expected[node] or 0
			if node.ranksPurchased ~= want then
				local _, name = TalentSpell(talents.configID, node)
				return {
					status = "off",
					talents = talents,
					message = ("%s has %d of %d, but at this point the build has %d."):format(name,
						node.ranksPurchased, node.maxRanks, want),
				}
			end
		end
	end
	if spent == #build.steps then
		return { status = "done", talents = talents }
	end

	local picks = {}
	for s = spent + 1, math.min(spent + talents.unspent + ns.previewPoints, #build.steps) do
		local step = build.steps[s]
		local node = talents.trees[step.tree][step.index]
		local spellID, name, icon = TalentSpell(talents.configID, node)
		picks[#picks + 1] = { node = node, rank = step.rank, spellID = spellID, name = name, icon = icon }
	end
	-- Every talent the rest of the build still puts points in.
	local later, seen = {}, {}
	for s = spent + 1, #build.steps do
		local step = build.steps[s]
		local node = talents.trees[step.tree][step.index]
		if not seen[node] then
			seen[node] = true
			later[#later + 1] = node
		end
	end
	return { status = "on", picks = picks, later = later, talents = talents }
end

---------------------------------------------------------------------------------------------
-- In the talent window: a yellow glow on the talent your next point goes in, a blue one on
-- every other talent the build still takes, or a warning. These are frames of our own laid over
-- Blizzard's; its buttons are never touched, since the talent window is easily upset by addons.

local LATER_COLOR = { 0.3, 0.7, 1 }

local talentsFrame
local marks = {}
local warning

local function Mark(i)
	local mark = marks[i]
	if mark then
		return mark
	end
	mark = CreateFrame("Frame", nil, talentsFrame)
	mark.next = mark:CreateTexture(nil, "OVERLAY")
	mark.next:SetTexture("Interface/SpellActivationOverlay/IconAlert")
	mark.next:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
	mark.next:SetBlendMode("ADD")
	mark.next:SetAllPoints()
	-- A white border glow, tinted.
	mark.later = mark:CreateTexture(nil, "OVERLAY")
	mark.later:SetTexture("Interface/Buttons/UI-ActionButton-Border")
	mark.later:SetBlendMode("ADD")
	mark.later:SetVertexColor(LATER_COLOR[1], LATER_COLOR[2], LATER_COLOR[3])
	mark.later:SetPoint("CENTER")
	marks[i] = mark
	return mark
end

local function ShowInTalentWindow(state)
	if not talentsFrame then
		return
	end
	for _, mark in ipairs(marks) do
		mark:Hide()
	end
	if warning then
		warning:Hide()
	end
	if not talentsFrame:IsVisible() then
		return
	end
	-- Only on your own active spec's talents.
	if talentsFrame.IsInspecting and talentsFrame:IsInspecting() then
		return
	end
	if talentsFrame.IsActiveTabSelected and not talentsFrame:IsActiveTabSelected() then
		return
	end
	if state.status == "off" or state.status == "bad" then
		if warning then
			warning.text:SetText(state.status == "off" and "Your talents don't follow this build."
				or "This link doesn't fit this character.")
			warning:Show()
		end
		return
	end
	if state.status ~= "on" then
		return
	end
	-- Only while you have a point to spend.
	local nextNode = state.picks[1] and state.picks[1].node
	if not nextNode then
		return
	end
	for i, node in ipairs(state.later) do
		local button = talentsFrame:GetTalentButtonByNodeID(node.ID)
		if button and button:IsShown() then
			local mark = Mark(i)
			local width = button:GetWidth()
			mark:SetSize(width * 1.5, width * 1.5)
			mark:ClearAllPoints()
			mark:SetPoint("CENTER", button, "CENTER")
			mark:SetFrameLevel(button:GetFrameLevel() + 10)
			local isNext = node.ID == nextNode.ID
			mark.next:SetShown(isNext)
			mark.later:SetShown(not isNext)
			mark.later:SetSize(width * 1.8, width * 1.8)
			mark:Show()
		end
	end
end

---------------------------------------------------------------------------------------------
-- Outside it: the next talent in Upkeep's row while you have points to spend.

local reminderKey

local function ShowReminder(state)
	if not (Upkeep and Upkeep.AddReminder) then
		return
	end
	local pick = state.status == "on" and state.picks[1]
	local key = pick and (pick.node.ID .. ":" .. pick.rank)
	if key == reminderKey then
		return
	end
	reminderKey = key
	if pick then
		Upkeep.AddReminder(REMINDER, {
			icon = pick.icon,
			spell = pick.spellID,
			click = TalentMicroButton and { type = "click", clickbutton = TalentMicroButton } or nil,
			glow = false,
		})
	else
		Upkeep.RemoveReminder(REMINDER)
	end
end

---------------------------------------------------------------------------------------------

local CreateLinkBox, UpdateLinkBox -- the link box under the talent window, further down

local function Refresh()
	local ok, state = pcall(Evaluate)
	if not ok then
		state = { status = "bad", message = "couldn't read your talents (" .. tostring(state) .. ")." }
	end
	if state.status == "wait" then
		return
	end
	ShowInTalentWindow(state)
	ShowReminder(state)
	UpdateLinkBox()
end

-- Every so often, faster while the talent window is open so the marks follow your clicks, and
-- soon after anything talent-related happens.
local driver = CreateFrame("Frame")
local since, soon = 0, true
driver:SetScript("OnUpdate", function(_, elapsed)
	if not chardb then
		return
	end
	since = since + elapsed
	local open = talentsFrame and talentsFrame:IsVisible()
	if since >= (open and 0.25 or soon and 0.3 or 5) then
		since, soon = 0, false
		Refresh()
	end
end)

local function HookTalentWindow()
	if talentsFrame or not (PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame) then
		return
	end
	talentsFrame = PlayerSpellsFrame.TalentsFrame
	talentsFrame:HookScript("OnShow", function()
		soon = true
	end)
	CreateLinkBox()
end

---------------------------------------------------------------------------------------------
-- The link box under the talent window, and commands

-- Kept as pasted, even when it doesn't fit: the warning under the box says so.
local function Save(text)
	text = strtrim(text)
	chardb.links[SpecGroup()] = text ~= "" and text or nil
	soon = true
end

-- Always there with the talent window, holding the active spec's link to copy or replace, with
-- a warning under it when needed. Enter or clicking away saves an edit; Escape undoes it; an
-- empty box removes the build.
local box

function UpdateLinkBox()
	if not box or box.edit:HasFocus() then
		return
	end
	local link = chardb.links[SpecGroup()] or ""
	if box.edit:GetText() ~= link then
		box.edit:SetText(link)
		box.edit:SetCursorPosition(0)
	end
end

function CreateLinkBox()
	box = CreateFrame("Frame", nil, talentsFrame, "TooltipBackdropTemplate")
	box:SetHeight(36)
	box:SetPoint("TOP", PlayerSpellsFrame, "BOTTOM", 0, -2)
	box.edit = CreateFrame("EditBox", nil, box, "InputBoxTemplate")
	box.edit:SetHeight(20)
	box.edit:SetPoint("LEFT", 18, 0)
	box.edit:SetPoint("RIGHT", -14, 0)
	box.edit:SetAutoFocus(false)
	box.edit:SetMaxLetters(0)
	box.edit:SetScript("OnEnterPressed", function(edit)
		edit:ClearFocus() -- saves, as below
	end)
	box.edit:SetScript("OnEscapePressed", function(edit)
		edit.undo = true
		edit:ClearFocus()
	end)
	box.edit:SetScript("OnEditFocusLost", function(edit)
		local undo = edit.undo
		edit.undo = nil
		local saved = chardb.links[SpecGroup()] or ""
		if not undo and strtrim(edit:GetText()) ~= saved then
			Save(edit:GetText())
		end
		edit:SetText(chardb.links[SpecGroup()] or "")
		edit:SetCursorPosition(0)
	end)
	box:SetScript("OnShow", function()
		box:SetWidth(PlayerSpellsFrame:GetWidth() * 0.7)
		UpdateLinkBox()
	end)
	box:SetWidth(PlayerSpellsFrame:GetWidth() * 0.7)
	UpdateLinkBox()

	warning = CreateFrame("Frame", nil, talentsFrame, "TooltipBackdropTemplate")
	warning:SetHeight(30)
	warning:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -2)
	warning:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -2)
	warning.text = warning:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	warning.text:SetPoint("CENTER")
	warning.text:SetTextColor(1, 0.3, 0.3)
	warning:Hide()
end

-- The build's order with this character's talent names, to check it against Wowhead's list.
local function PrintOrder()
	local link = chardb.links[SpecGroup()]
	local build = link and Link.Parse(link)
	local talents = ReadTalents()
	if not (build and talents) then
		Print("no build for this spec, or the talents can't be read yet.")
		return
	end
	local misfit = Misfit(build, talents)
	if misfit then
		Print(misfit)
		return
	end
	for s, step in ipairs(build.steps) do
		local _, name = TalentSpell(talents.configID, talents.trees[step.tree][step.index])
		print(("  %d. %s, rank %d"):format(s, name, step.rank))
	end
end

SLASH_TALENTPATH1 = "/talentpath"
SlashCmdList.TALENTPATH = function(msg)
	local command, arg = strtrim(msg or ""):lower():match("^(%S*)%s*(.-)$")
	if command == "order" then
		PrintOrder()
	elseif command == "preview" then
		-- Not saved: a reload ends it.
		ns.previewPoints = math.max(0, math.min(tonumber(arg) or 0, 51))
		soon = true
		if ns.previewPoints > 0 then
			Print(("showing the next talents as if you had %d more point%s. /talentpath preview 0 stops it.")
				:format(ns.previewPoints, ns.previewPoints == 1 and "" or "s"))
		else
			Print("preview off.")
		end
	else
		Print("paste a Wowhead talent link in the box under the talent window. /talentpath order lists the "
			.. "build; /talentpath preview <points> shows the marks as if you had that many more points.")
	end
end

---------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
for _, event in ipairs({
	"PLAYER_LEVEL_UP", "TRAIT_CONFIG_UPDATED", "TRAIT_NODE_CHANGED", "TRAIT_TREE_CURRENCY_INFO_UPDATED",
	"ACTIVE_PLAYER_SPECIALIZATION_CHANGED", "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_TALENT_UPDATE",
}) do
	pcall(events.RegisterEvent, events, event) -- some may not exist on this client
end
events:SetScript("OnEvent", function(_, event, addon)
	if event == "PLAYER_LOGIN" then
		TalentPathCharDB = TalentPathCharDB or {}
		chardb = TalentPathCharDB
		chardb.links = chardb.links or {}
		HookTalentWindow()
	elseif event == "ADDON_LOADED" then
		if addon == "Blizzard_PlayerSpells" then
			HookTalentWindow()
		end
	end
	soon = true
end)
