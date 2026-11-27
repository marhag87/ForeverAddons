-- Bobber: fish with the jump key. With a fishing pole in your main hand and standing still,
-- the jump key casts Fishing; while the bobber is out it interacts with the bobber, which
-- reels the catch in. Moving, swimming, falling, mounted, dead or in combat, it jumps as
-- usual.
--
-- One press does one thing: when what the key should do changes while it's held down, it
-- does nothing until it's let go. Otherwise letting go of the press that reeled in would
-- cast again before the catch is looted. A second press casts at once, which still loots.
--
-- A few game settings make this work, so they're switched on while a pole is in your hand
-- and put back when it isn't, and when you log out:
--   * soft targeting for the interact key, from the keyboard, far and wide enough to pick
--     the bobber up;
--   * the interact icon over the object it picks, so your own bobber is marked among
--     everyone else's;
--   * auto loot, so the catch goes straight into your bags.
--
-- The key changes with override bindings, which can't change in combat. A secure state
-- driver clears them the moment combat starts, so the key jumps again; they come back
-- once combat ends.
--
-- With Upkeep loaded, a pole without a lure gets a reminder in Upkeep's row for the best
-- lure in your bags; a click on it puts the lure on. Without Upkeep there is no reminder.

local FISHING_SPELLS = { 18248, 7732, 7731, 7620 } -- Artisan, Expert, Journeyman, Apprentice
local LURES = { -- best first
	6533, -- Aquadynamic Fish Attractor, +100
	6532, 7307, -- Bright Baubles, Flesh Eating Worm, +75
	6530, 6811, -- Nightcrawlers, Aquadynamic Fish Lens, +50
	6529, -- Shiny Bauble, +25
}
local LURE_REMINDER = "Bobber.lure"
local TIME_UNITS = { sec = 1, min = 60, hour = 3600, hr = 3600 }
local ITEM_CLASS_WEAPON = Enum.ItemClass and Enum.ItemClass.Weapon or 2
local FISHING_POLE = Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole or 20
local KEYBOARD_BIT = 2 -- in softTargetInteract: 1 gamepad, 2 keyboard and mouse, 3 both
local WAIT_BUTTON = "BobberWaitButton" -- "wait" binds the key to this button, which does nothing

-- name -> function(current value) returning the value to switch to, or nil if it will do.
local SETTINGS = {
	softTargetInteract = function(value)
		local n = tonumber(value) or 0
		if n % 4 < KEYBOARD_BIT then
			return tostring(n - n % 4 + 3)
		end
	end,
	SoftTargetInteractArc = function(value)
		if (tonumber(value) or 0) < 2 then
			return "2"
		end
	end,
	SoftTargetInteractRange = function(value)
		if (tonumber(value) or 0) < 30 then
			return "30"
		end
	end,
	SoftTargetIconGameObject = function(value)
		if value ~= "1" then
			return "1"
		end
	end,
	autoLootDefault = function(value)
		if value ~= "1" then
			return "1"
		end
	end,
}

local db -- BobberDB: { enabled, saved = { setting name -> value to put back } }
local fishingName -- the Fishing you know, nil if none
local state -- what the key is set up for: "off", "jump", "cast", "reel", "wait" or "combat"
local bestLure -- item id of the best lure in your bags, nil without one
local lureEnds -- GetTime() the pole's lure runs out, false with none on it, nil before a reading
local lureShown -- the lure the reminder was set up with, nil while it isn't up

local function Print(text)
	print("|cff33ff99Bobber:|r " .. text)
end

local function IsHidden(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

local owner = CreateFrame("Frame", nil, UIParent, "SecureHandlerStateTemplate")
owner:SetAttribute("_onstate-combat", [[
	if newstate == "on" then
		self:ClearBindings()
	end
]])
RegisterStateDriver(owner, "combat", "[combat] on; off")
CreateFrame("Button", WAIT_BUTTON)

---------------------------------------------------------------------------------------------
-- Settings

local function SwitchSettingsOn()
	for name, wanted in pairs(SETTINGS) do
		local current = GetCVar(name)
		local value = current and wanted(current)
		if value then
			if db.saved[name] == nil then
				db.saved[name] = current
			end
			SetCVar(name, value)
		end
	end
end

local function PutSettingsBack()
	for name, value in pairs(db.saved) do
		SetCVar(name, value)
	end
	wipe(db.saved)
end

---------------------------------------------------------------------------------------------
-- What the key should do

local function FindFishing()
	fishingName = nil
	for _, id in ipairs(FISHING_SPELLS) do
		if IsPlayerSpell(id) then
			fishingName = C_Spell.GetSpellName(id)
			return
		end
	end
end

local function HoldingFishingPole()
	local id = GetInventoryItemID("player", 16)
	if IsHidden(id) or not id then
		return false
	end
	local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(id)
	return classID == ITEM_CLASS_WEAPON and subclassID == FISHING_POLE
end

local function BobberOut()
	local name, _, _, _, _, _, _, spellID = UnitChannelInfo("player")
	if IsHidden(name) or not name then
		return false
	end
	if not IsHidden(spellID) and tContains(FISHING_SPELLS, spellID) then
		return true
	end
	return name == fishingName
end

local function JumpKeys()
	local keys = { GetBindingKey("JUMP") }
	if #keys == 0 then
		keys = { "SPACE" }
	end
	return keys
end

-- Whether a jump key is down. A binding such as "SHIFT-SPACE" is down when its last key is.
local function KeyHeld()
	if not IsKeyDown then
		return false
	end
	for _, key in ipairs(JumpKeys()) do
		local down = IsKeyDown(key:match("[^-]+$") or key)
		if not IsHidden(down) and down then
			return true
		end
	end
	return false
end

local function Wanted()
	if InCombatLockdown() then
		return "combat"
	end
	if not (db.enabled and fishingName and HoldingFishingPole()) then
		return "off"
	end
	local speed = GetUnitSpeed("player")
	if IsHidden(speed) or speed > 0 or IsFalling() or IsSwimming() or IsMounted() or UnitOnTaxi("player")
		or UnitIsDeadOrGhost("player") then
		return "jump"
	end
	local wanted = BobberOut() and "reel" or "cast"
	-- Letting go of a key fires what it's bound to then, so the press that reels in would cast
	-- as it's let go, before the catch is looted. Until the key is let go, it does nothing.
	if wanted ~= state and KeyHeld() then
		return "wait"
	end
	return wanted
end

local function Apply(wanted)
	if wanted == state then
		return
	end
	state = wanted
	if wanted == "combat" then
		return -- the state driver has cleared the bindings
	end
	ClearOverrideBindings(owner)
	if wanted == "off" then
		PutSettingsBack()
		return
	end
	SwitchSettingsOn()
	if wanted == "jump" then
		return
	end
	for _, key in ipairs(JumpKeys()) do
		if wanted == "cast" then
			SetOverrideBindingSpell(owner, true, key, fishingName)
		elseif wanted == "reel" then
			SetOverrideBinding(owner, true, key, "INTERACTTARGET")
		else -- "wait"
			SetOverrideBindingClick(owner, true, key, WAIT_BUTTON)
		end
	end
end

---------------------------------------------------------------------------------------------
-- Lures

local function FindBestLure()
	bestLure = nil
	for _, id in ipairs(LURES) do
		if C_Item.GetItemCount(id) > 0 then
			bestLure = id
			return
		end
	end
end

-- A lure shows on the pole's tooltip as a line ending in its time left, "(10 min)". Nothing
-- else on a pole carries one, so the rest of the line's wording doesn't matter. Returns when
-- it runs out, false without one, nil if the tooltip can't be read.
local function ReadLure()
	local ok, result = pcall(function()
		local data = C_TooltipInfo.GetInventoryItem("player", 16)
		if not data or not data.lines then
			return nil
		end
		local readable = false
		for _, line in ipairs(data.lines) do
			local text = line.leftText
			if not IsHidden(text) and type(text) == "string" then
				readable = true
				for amount, unit in text:gmatch("%((%d+) (%a+)%)") do
					if TIME_UNITS[unit] then
						return GetTime() + tonumber(amount) * TIME_UNITS[unit]
					end
				end
			end
		end
		if readable then
			return false
		end
		return nil
	end)
	if ok then
		return result
	end
end

local function UpdateLure()
	if not (Upkeep and Upkeep.AddReminder) then
		return
	end
	local missing = false
	if db.enabled and bestLure and HoldingFishingPole() then
		if not InCombatLockdown() then
			local ends = ReadLure()
			if ends ~= nil then
				lureEnds = ends
			end
		end
		-- Nothing read yet means absence is unproven.
		missing = lureEnds == false or (lureEnds ~= nil and lureEnds <= GetTime())
	else
		lureEnds = nil
	end
	if missing then
		if lureShown ~= bestLure then
			lureShown = bestLure
			Upkeep.AddReminder(LURE_REMINDER, {
				icon = C_Item.GetItemIconByID(bestLure),
				-- The lure, then the pole in slot 16 as what it goes on.
				click = { type = "macro", macrotext = "/use item:" .. bestLure .. "\n/use 16" },
				item = bestLure,
				glow = false,
				resting = true, -- fishing in town wants it too
			})
		end
	elseif lureShown then
		lureShown = nil
		Upkeep.RemoveReminder(LURE_REMINDER)
	end
end

---------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")

local sinceKey, sinceLure = 0, 0
events:SetScript("OnUpdate", function(_, elapsed)
	if not db then
		return
	end
	sinceKey, sinceLure = sinceKey + elapsed, sinceLure + elapsed
	if sinceKey >= 0.1 then
		sinceKey = 0
		Apply(Wanted())
	end
	if sinceLure >= 0.5 then
		sinceLure = 0
		UpdateLure()
	end
end)

events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("BAG_UPDATE_DELAYED") -- lures come and go from your bags
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		BobberDB = BobberDB or {}
		db = BobberDB
		if db.enabled == nil then
			db.enabled = true
		end
		db.saved = db.saved or {}
		db.trace = nil -- left by a trace build used to find the double cast
		PutSettingsBack() -- left over if the game didn't close cleanly last time
		FindFishing()
		FindBestLure()
	elseif event == "SPELLS_CHANGED" then
		FindFishing()
	elseif event == "BAG_UPDATE_DELAYED" then
		FindBestLure()
	elseif event == "PLAYER_LOGOUT" and db then
		-- The settings are saved as the game closes, so they go back now and on again next
		-- time a pole is in hand.
		PutSettingsBack()
	end
end)

SLASH_BOBBER1 = "/bobber"
SlashCmdList.BOBBER = function(msg)
	if msg and msg:lower():match("^%s*debug") then
		local ends = ReadLure()
		Print(("key: %s, fishing spell: %s, best lure in bags: %s, lure on the pole: %s"):format(tostring(state),
			tostring(fishingName), tostring(bestLure and C_Item.GetItemNameByID(bestLure) or bestLure),
			ends == nil and "unreadable" or ends and ("%.0fs left"):format(ends - GetTime()) or "none"))
		local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", 16)
		for i, line in ipairs(ok and data and data.lines or {}) do
			print(("  tooltip %d: %s"):format(i, IsHidden(line.leftText) and "<hidden>" or tostring(line.leftText)))
		end
		return
	end
	db.enabled = not db.enabled
	if db.enabled then
		Print("on. With a fishing pole in hand, the jump key fishes.")
	else
		Print("off. The jump key only jumps.")
	end
end
