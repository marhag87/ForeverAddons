-- CraftTimers: profession cooldowns for every character, on both of your accounts.
--
-- Recipe cooldowns can only be read while one of your own professions is open, so they're
-- read when it opens and after each craft. Every learned recipe on a cooldown of two hours or
-- more is recorded with the server time it ends. Recipes that end at the same moment share a
-- cooldown (transmutes, say) and become one line. A few cooldowns that aren't recipes are read
-- whenever the character has them: the Salt Shaker in your bags, and the Dedicated Study
-- talent. A line stays after its cooldown ends and shows "Ready".
--
-- Records live in account-wide saved variables, so every character on the account shows. With
-- AccountLink they're also shared with your other account while you're grouped.
--
-- A minimap button flashes while something is ready that you haven't looked at yet. A click
-- shows the list and counts everything ready as seen.

local MIN_COOLDOWN = 2 * 3600 -- shorter ones (Iron to Gold, 1 hour) would flash all day
local GETTIME_WRAP = 2 ^ 32 / 1000 -- see Unwrap
local SHARED_WINDOW = 5 -- seconds: recipes ending this close together share one cooldown
local SAME_END = 60 -- seconds: a reading this close to the recorded end is the same cooldown
local SCAN_DELAY = 0.5
local DATASET = "crafttimers"
local ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local ITEMS = { [15846] = "Leatherworking" } -- Salt Shaker
local SPELLS = { { id = 1225469, name = "Dedicated Study", profession = "Professions" } }

local db -- CraftTimersDB
local meKey -- this character's key, "First Surname"
local Refresh -- the minimap button and list, below

local function IsHidden(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

local function Print(text)
	print("|cff33ff99CraftTimers:|r " .. text)
end

local function Now()
	return GetServerTime and GetServerTime() or time()
end

local function Try(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, a, b, c, d = pcall(fn, ...)
	if ok then
		return a, b, c, d
	end
end

local function Equal(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not Equal(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- UnitName gives first name and surname separately; whispers and keys use both.
local function FullName()
	local first, surname = UnitName("player")
	if IsHidden(first) or IsHidden(surname) or not first then
		return nil
	end
	if surname and surname ~= "" then
		local consts = Constants and Constants.CharacterNameSeparatorConsts
		local separator = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR
		return first .. (type(separator) == "string" and separator ~= "" and separator or " ") .. surname
	end
	return first
end

-- GetTime counts from when the computer started, in 32-bit milliseconds. A cooldown that started
-- before a restart comes back with its start 2^32 ms (about 1193 hours) late, so seconds left
-- read that much too high. Seen by Crafter's Journal on Forever ("ready in 1195 h" for 59 min).
local function Unwrap(seconds)
	if seconds > GETTIME_WRAP / 2 then
		seconds = seconds - GETTIME_WRAP
	end
	return math.max(0, seconds)
end

-- Seconds left on a GetTime-based cooldown: 0 when there's none, nil when it can't be read.
local function Remaining(start, duration)
	if type(start) ~= "number" or type(duration) ~= "number" or IsHidden(start) or IsHidden(duration) then
		return nil
	end
	if start <= 0 or duration <= 2 then -- the global cooldown isn't one
		return 0
	end
	return Unwrap(start + duration - GetTime())
end

---------------------------------------------------------------------------------------------
-- This character's records: cds[id] = { n = name, i = icon, e = server time it's ready, p =
-- profession, m = recipe ids (recipe lines only) }. e is 0 for a line never seen cooling down.

local function Mine()
	local char = db.characters[meKey]
	if not char then
		char = { name = meKey, cds = {} }
		db.characters[meKey] = char
	end
	local _, class = UnitClass("player")
	char.class = class
	return char.cds
end

local function Changed()
	if AccountLink and AccountLink.Changed then
		AccountLink.Changed(DATASET, meKey)
	end
	Refresh()
end

-- The end time to record for a cooldown now this many seconds from its end: the recorded one
-- if it's the same cooldown, so repeated readings don't change anything.
local function EndsIn(old, left, now)
	local ends = now + math.floor(left + 0.5)
	if old and old.e > now and math.abs(old.e - ends) <= SAME_END then
		return old.e
	end
	return ends
end

-- The end time for a line that's ready: unchanged once it's in the past, now if it ended
-- early, 0 for one never seen cooling down.
local function ReadyEnds(old, now)
	if not old then
		return 0
	end
	return old.e <= now and old.e or now
end

local function Put(cds, id, entry)
	if Equal(cds[id], entry) then
		return false
	end
	cds[id] = entry
	return true
end

---------------------------------------------------------------------------------------------
-- Recipes, while your own profession is open

-- The open profession's name, or nil when none is open or it's someone else's (a link, a
-- guild member's, an NPC's).
local function OwnProfession()
	local T = C_TradeSkillUI
	if not T or Try(T.IsDataSourceChanging) then
		return nil
	end
	for _, check in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting" }) do
		local other = Try(T[check])
		if other and not IsHidden(other) then
			return nil
		end
	end
	local info = Try(T.GetBaseProfessionInfo)
	local name = type(info) == "table" and info.professionName
	if type(name) == "string" and name ~= "" and not IsHidden(name) then
		return name
	end
end

-- Every recipe of the open profession. complete is false for the filtered list (the search box
-- narrows it), which can't tell an unlearned recipe from a hidden one.
local function RecipeIDs()
	local T = C_TradeSkillUI
	local ids = Try(T.GetAllRecipeIDs)
	if type(ids) == "table" then
		return ids, true
	end
	ids = Try(T.GetFilteredRecipeIDs)
	return type(ids) == "table" and ids or {}, false
end

-- "Transmute" for transmutes sharing a cooldown, else the first name and how many more.
local function Label(names)
	if #names == 1 then
		return names[1]
	end
	local prefix = names[1]:match("^([^:]+):")
	for _, name in ipairs(names) do
		if not prefix or name:match("^([^:]+):") ~= prefix then
			prefix = nil
			break
		end
	end
	return prefix or (names[1] .. " +" .. (#names - 1))
end

local function Overlaps(a, b)
	for _, x in ipairs(a) do
		for _, y in ipairs(b) do
			if x == y then
				return true
			end
		end
	end
	return false
end

local function ScanRecipes()
	local profession = OwnProfession()
	if not profession or not meKey then
		return
	end
	local T = C_TradeSkillUI
	local now = Now()
	local ids, complete = RecipeIDs()
	local groups, learned, cooling = {}, {}, {}
	for _, recipeID in ipairs(ids) do
		local info = Try(T.GetRecipeInfo, recipeID)
		if type(info) == "table" and info.learned and not IsHidden(info.learned) then
			learned[recipeID] = true
			local cd, _, charges, maxCharges = Try(T.GetRecipeCooldown, recipeID)
			local hasCharge = (tonumber(maxCharges) or 0) > 0 and (tonumber(charges) or 0) > 0
			if type(cd) == "number" and not IsHidden(cd) and not hasCharge then
				cd = Unwrap(cd)
				if cd >= MIN_COOLDOWN then
					cooling[recipeID] = true
					local ends = now + math.floor(cd + 0.5)
					local group
					for _, g in ipairs(groups) do
						if math.abs(g.ends - ends) <= SHARED_WINDOW then
							group = g
							break
						end
					end
					if not group then
						group = { ends = ends, ids = {}, names = {}, icon = info.icon }
						groups[#groups + 1] = group
					end
					table.insert(group.ids, recipeID)
					table.insert(group.names, info.name or ("Recipe " .. recipeID))
				end
			end
		end
	end

	local cds = Mine()
	local changed = false
	for _, g in ipairs(groups) do
		table.sort(g.ids)
		table.sort(g.names)
		-- The line that already holds any of these recipes keeps its id; others merge into it.
		local id
		for entryId, entry in pairs(cds) do
			if entry.p == profession and entry.m and Overlaps(entry.m, g.ids) then
				if id then
					cds[entryId] = nil
					changed = true
				else
					id = entryId
				end
			end
		end
		id = id or ("r" .. g.ids[1])
		local old = cds[id]
		changed = Put(cds, id, { n = Label(g.names), i = g.icon, e = EndsIn(old, g.ends - now, now), p = profession,
			m = g.ids }) or changed
	end
	for entryId, entry in pairs(cds) do
		if entry.p == profession and entry.m then
			local known, still = false, false
			for _, recipeID in ipairs(entry.m) do
				known = known or learned[recipeID] == true
				still = still or cooling[recipeID] == true
			end
			if complete and not known then
				cds[entryId] = nil -- none of its recipes is known any more
				changed = true
			elseif entry.e > now and not still then
				entry.e = now -- ended early
				changed = true
			end
		end
	end
	if changed then
		Changed()
	end
end

---------------------------------------------------------------------------------------------
-- Items in your bags and spells, whenever the character has them

local function ScanItems()
	if not meKey then
		return
	end
	local now = Now()
	local cds = Mine()
	local changed = false
	for itemID, profession in pairs(ITEMS) do
		local count = Try(C_Item.GetItemCount, itemID)
		if type(count) == "number" and count > 0 then
			local id = "i" .. itemID
			local old = cds[id]
			local start, duration = Try(C_Container and C_Container.GetItemCooldown, itemID)
			local left = Remaining(start, duration)
			if left then
				local ends = left >= MIN_COOLDOWN and EndsIn(old, left, now) or ReadyEnds(old, now)
				local name = Try(C_Item.GetItemNameByID, itemID) or (old and old.n) or ("Item " .. itemID)
				changed = Put(cds, id, { n = name, i = Try(C_Item.GetItemIconByID, itemID), e = ends, p = profession })
					or changed
			end
		end
	end
	if changed then
		Changed()
	end
end

local function KnownSpell(spell)
	if IsPlayerSpell(spell.id) then
		return spell.id
	end
	-- In case Forever's id differs from the one found online: the name, for a known spell.
	local info = Try(C_Spell.GetSpellInfo, spell.name)
	local id = type(info) == "table" and info.spellID
	if type(id) == "number" and not IsHidden(id) and IsPlayerSpell(id) then
		return id
	end
end

local function ScanSpells()
	if not meKey or InCombatLockdown() then
		return
	end
	local now = Now()
	local cds = Mine()
	local changed = false
	for _, spell in ipairs(SPELLS) do
		local spellID = KnownSpell(spell)
		if spellID then
			local id = "s" .. spell.id
			local old = cds[id]
			local info = Try(C_Spell.GetSpellCooldown, spellID)
			local left = type(info) == "table" and Remaining(info.startTime, info.duration)
			if left then
				local ends = left >= MIN_COOLDOWN and EndsIn(old, left, now) or ReadyEnds(old, now)
				changed = Put(cds, id, { n = Try(C_Spell.GetSpellName, spellID) or spell.name,
					i = Try(C_Spell.GetSpellTexture, spellID), e = ends, p = spell.profession }) or changed
			end
		end
	end
	if changed then
		Changed()
	end
end

local timers = {}
local function Soon(fn, delay)
	if timers[fn] then
		return
	end
	timers[fn] = true
	C_Timer.After(delay or SCAN_DELAY, function()
		timers[fn] = nil
		if db then
			fn()
		end
	end)
end

---------------------------------------------------------------------------------------------
-- Seen: a line counts as seen once its ready state has been on the list after a click.
-- db.acks[key][id] = the end time that was seen ready.

local function ReadyUnseen()
	local now = Now()
	for key, char in pairs(db.characters) do
		local acks = db.acks[key]
		for id, entry in pairs(type(char.cds) == "table" and char.cds or {}) do
			if type(entry.e) == "number" and entry.e <= now and not (acks and acks[id] == entry.e) then
				return true
			end
		end
	end
	return false
end

local function SeeAll()
	local now = Now()
	wipe(db.acks)
	for key, char in pairs(db.characters) do
		for id, entry in pairs(type(char.cds) == "table" and char.cds or {}) do
			if type(entry.e) == "number" and entry.e <= now then
				db.acks[key] = db.acks[key] or {}
				db.acks[key][id] = entry.e
			end
		end
	end
end

---------------------------------------------------------------------------------------------
-- Minimap button and list

local function Left(seconds)
	local floor = math.floor
	if seconds >= 86400 then
		return ("%dd %dh"):format(floor(seconds / 86400), floor(seconds % 86400 / 3600))
	elseif seconds >= 3600 then
		return ("%dh %dm"):format(floor(seconds / 3600), floor(seconds % 3600 / 60))
	elseif seconds >= 60 then
		return ("%dm"):format(floor(seconds / 60))
	end
	return "<1m"
end

local function Colored(char)
	local color = RAID_CLASS_COLORS and char.class and RAID_CLASS_COLORS[char.class]
	if color and color.colorStr then
		return "|c" .. color.colorStr .. (char.name or "?") .. "|r"
	end
	return char.name or "?"
end

local button = CreateFrame("Button", "CraftTimersMinimapButton", Minimap)
button:SetSize(31, 31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("AnyUp")
button:RegisterForDrag("LeftButton")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
local background = button:CreateTexture(nil, "BACKGROUND")
background:SetSize(20, 20)
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
background:SetPoint("TOPLEFT", 7, -5)
local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetSize(17, 17)
icon:SetTexture(ICON)
icon:SetPoint("TOPLEFT", 7, -6)
local border = button:CreateTexture(nil, "OVERLAY")
border:SetSize(53, 53)
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetPoint("TOPLEFT")
local glow = button:CreateTexture(nil, "OVERLAY", nil, 7)
glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
glow:SetBlendMode("ADD")
glow:SetAllPoints()
glow:Hide()
local pulse = glow:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(0.1)
fade:SetToAlpha(1)
fade:SetDuration(0.7)
button:Hide()

local list = CreateFrame("GameTooltip", "CraftTimersList", UIParent, "GameTooltipTemplate")
list:Hide()
table.insert(UISpecialFrames, "CraftTimersList") -- Escape closes it

local atan2 = math.atan2 or math.atan

local function Place()
	local angle = math.rad(db.minimap.angle or 200)
	local radius = Minimap:GetWidth() / 2 + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function FillList()
	list:SetOwner(button, "ANCHOR_NONE")
	list:ClearAllPoints()
	list:SetPoint("TOPRIGHT", button, "BOTTOMLEFT", 0, 0)
	list:AddLine("Profession cooldowns")
	local now = Now()
	local keys = {}
	for key, char in pairs(db.characters) do
		if type(char.cds) == "table" and next(char.cds) then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys, function(a, b)
		if (a == meKey) ~= (b == meKey) then
			return a == meKey -- the character you're on first
		end
		return a < b
	end)
	for _, key in ipairs(keys) do
		local char = db.characters[key]
		list:AddLine(" ")
		list:AddLine(Colored(char))
		local ids = {}
		for id in pairs(char.cds) do
			ids[#ids + 1] = id
		end
		table.sort(ids, function(a, b)
			local ea, eb = char.cds[a].e or 0, char.cds[b].e or 0
			if ea ~= eb then
				return ea < eb
			end
			return a < b
		end)
		for _, id in ipairs(ids) do
			local entry = char.cds[id]
			local text = (entry.i and ("|T%s:14:14:0:0|t "):format(entry.i) or "") .. (entry.n or id)
			if (entry.e or 0) <= now then
				list:AddDoubleLine(text, "Ready", 1, 1, 1, 0.1, 1, 0.1)
			else
				list:AddDoubleLine(text, Left(entry.e - now), 1, 1, 1, 1, 1, 1)
			end
		end
	end
	if #keys == 0 then
		list:AddLine("Nothing yet. Open a profession that has a cooldown recipe, or craft one.", 0.7, 0.7, 0.7, true)
	end
	list:Show()
end

function Refresh()
	if not db then
		return
	end
	local flash = ReadyUnseen()
	if flash and not pulse:IsPlaying() then
		glow:Show()
		pulse:Play()
	elseif not flash and pulse:IsPlaying() then
		pulse:Stop()
		glow:Hide()
	end
	if list:IsShown() then
		FillList()
	end
end

local function Toggle()
	SeeAll()
	if list:IsShown() then
		list:Hide()
	else
		GameTooltip:Hide()
		FillList()
	end
	Refresh()
end

button:SetScript("OnClick", Toggle)
button:SetScript("OnEnter", function(self)
	if list:IsShown() then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("CraftTimers")
	GameTooltip:AddLine("Click: profession cooldowns", 1, 1, 1)
	GameTooltip:AddLine("Drag: move around the minimap", 1, 1, 1)
	GameTooltip:Show()
end)
button:SetScript("OnLeave", function()
	GameTooltip:Hide()
end)
button:SetScript("OnDragStart", function(self)
	GameTooltip:Hide()
	self:SetScript("OnUpdate", function()
		local mx, my = Minimap:GetCenter()
		local px, py = GetCursorPosition()
		local scale = Minimap:GetEffectiveScale()
		db.minimap.angle = math.deg(atan2(py / scale - my, px / scale - mx))
		Place()
	end)
end)
button:SetScript("OnDragStop", function(self)
	self:SetScript("OnUpdate", nil)
end)

---------------------------------------------------------------------------------------------
-- Debug: what the game gives, to check the readings in game.

local function Debug()
	local T = C_TradeSkillUI or {}
	local has = {}
	for _, name in ipairs({ "GetRecipeCooldown", "GetAllRecipeIDs", "GetFilteredRecipeIDs", "GetRecipeInfo",
		"GetBaseProfessionInfo", "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
		has[#has + 1] = name .. (T[name] and "" or " MISSING")
	end
	Print("API: " .. table.concat(has, ", "))
	Print(("character %s, AccountLink %s"):format(tostring(meKey), AccountLink and AccountLink.Register and "loaded" or "not loaded"))
	local profession = OwnProfession()
	if profession then
		local ids, complete = RecipeIDs()
		local learned, found = 0, {}
		for _, recipeID in ipairs(ids) do
			local info = Try(T.GetRecipeInfo, recipeID)
			if type(info) == "table" and info.learned then
				learned = learned + 1
				local cd, isDay, charges, maxCharges = Try(T.GetRecipeCooldown, recipeID)
				if cd or (tonumber(maxCharges) or 0) > 0 then
					found[#found + 1] = ("%s %s: %s s%s, charges %s/%s"):format(tostring(recipeID), tostring(info.name),
						tostring(cd), isDay and " (day)" or "", tostring(charges), tostring(maxCharges))
				end
			end
		end
		Print(("open: %s, %d recipes (%s), %d learned, %d with a cooldown:"):format(profession, #ids,
			complete and "all" or "filtered", learned, #found))
		for _, line in ipairs(found) do
			print("  " .. line)
		end
	else
		Print("no profession of yours is open")
	end
	for _, spell in ipairs(SPELLS) do
		local spellID = KnownSpell(spell)
		local info = spellID and Try(C_Spell.GetSpellCooldown, spellID)
		Print(("%s: %s, cooldown start %s duration %s"):format(spell.name, spellID and ("known as " .. spellID) or "not known",
			tostring(type(info) == "table" and info.startTime), tostring(type(info) == "table" and info.duration)))
	end
	for itemID in pairs(ITEMS) do
		local start, duration = Try(C_Container and C_Container.GetItemCooldown, itemID)
		Print(("item %d: %s in bags, cooldown start %s duration %s"):format(itemID, tostring(Try(C_Item.GetItemCount, itemID)),
			tostring(start), tostring(duration)))
	end
	local now = Now()
	for id, entry in pairs(db.characters[meKey] and db.characters[meKey].cds or {}) do
		print(("  %s %s (%s): %s"):format(id, tostring(entry.n), tostring(entry.p),
			entry.e <= now and "ready" or Left(entry.e - now)))
	end
end

SLASH_CRAFTTIMERS1 = "/crafttimers"
SLASH_CRAFTTIMERS2 = "/ct"
SlashCmdList.CRAFTTIMERS = function(message)
	if not db or not meKey then
		return
	end
	local command = (message or ""):match("^%s*(%S*)"):lower()
	if command == "" then
		Toggle()
	elseif command == "minimap" then
		db.minimap.hide = not db.minimap.hide
		button:SetShown(not db.minimap.hide)
		Print(db.minimap.hide and "minimap button hidden; /ct shows the list" or "minimap button shown")
	elseif command == "reset" then
		wipe(Mine())
		Changed()
		Print("this character's cooldowns cleared; they come back as you open its professions")
	elseif command == "debug" then
		Debug()
	else
		Print("/ct - the list, /ct minimap - hide or show the button, /ct reset - clear this character's cooldowns, /ct debug")
	end
end

---------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("TRADE_SKILL_SHOW")
events:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
events:RegisterEvent("BAG_UPDATE_COOLDOWN")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("SPELL_UPDATE_COOLDOWN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
events:SetScript("OnEvent", function(_, event, arg)
	if event == "ADDON_LOADED" then
		if arg ~= "CraftTimers" then
			return
		end
		CraftTimersDB = CraftTimersDB or {}
		db = CraftTimersDB
		db.characters = db.characters or {} -- key -> { name, class, cds }
		db.acks = db.acks or {}
		db.minimap = db.minimap or { angle = 200 }
		db.link = db.link or {} -- AccountLink's owned/mirrors
		return
	end
	if not db then
		return
	end
	if event == "PLAYER_LOGIN" then
		meKey = FullName()
		if not meKey then
			return
		end
		Mine()
		if AccountLink and AccountLink.Register then
			AccountLink.Register(DATASET, {
				state = db.link,
				title = "CraftTimers' profession cooldowns",
				Store = function()
					return db.characters
				end,
				CurrentKey = function()
					return meKey
				end,
				Valid = function(data)
					return type(data) == "table" and type(data.cds) == "table"
				end,
				OnMirrored = function()
					Refresh()
				end,
			})
		end
		Place()
		button:SetShown(not db.minimap.hide)
		C_Timer.NewTicker(1, Refresh)
	elseif event == "PLAYER_ENTERING_WORLD" then
		Soon(ScanItems, 5)
		Soon(ScanSpells, 5)
	elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
		Soon(ScanRecipes)
	elseif event == "BAG_UPDATE_COOLDOWN" or event == "BAG_UPDATE_DELAYED" then
		Soon(ScanItems, 1)
	elseif event == "SPELL_UPDATE_COOLDOWN" or event == "PLAYER_REGEN_ENABLED" then
		Soon(ScanSpells, 1)
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- A craft: its cooldown shows a moment later, and the list update may come first.
		Soon(ScanRecipes, 1.5)
		Soon(ScanSpells, 1.5)
	end
end)
