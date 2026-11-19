-- Tandem.lua
-- What Tandem does once it knows who is online: turns the follower's sound off, invites and
-- accepts, sets free-for-all loot, reminds the follower to focus the main, and reminds any
-- character of a spell to cast after logging in. Also the events and the slash commands.
--
-- The reminders are buttons in Upkeep's reminder row, so they need Upkeep; without it Tandem
-- does everything else and skips them.

local ADDON, ns = ...
local Util, Sets = ns.Util, ns.Sets

local REMINDER_FOCUS = "Tandem.focus"
local REMINDER_LOGIN = "Tandem.login"
local INVITE_DELAY = 1.5 -- seconds after a member turns up before inviting them
local RELOAD_HOLD = 20 -- seconds a muted follower stays muted after a reload while members find each other again
local LOGIN_SETTLE = 10 -- seconds after logging in before the stance or form shown can be trusted
local SOUND_CVAR = "Sound_EnableAllSound"

local db, chardb
local loaded = false
local holdUntil -- GetTime() until which a reload keeps the sound off
local settleUntil -- GetTime() until which the stance shown may still be the one you logged out in
local sentCasts = {} -- castGUID -> GetTime() for casts you sent yourself
local lootDoneFor -- the group, as sorted names, we last set free-for-all for
local lootWaiting = false -- free-for-all is waiting for combat to end
local acceptedInvite = false -- we accepted an invite and the popup still needs closing
local rosterTimer

local function Paused()
	return chardb.paused
end

---------------------------------------------------------------------------------------------
-- Reminders, through Upkeep. Each is sent only when it changes.

local sentReminders = {} -- id -> key of what Upkeep was last given

local function HasUpkeep()
	return Upkeep ~= nil and Upkeep.AddReminder ~= nil and Upkeep.RemoveReminder ~= nil
end

local function ShowReminder(id, info, key)
	if not HasUpkeep() or sentReminders[id] == key then
		return
	end
	sentReminders[id] = key
	Upkeep.AddReminder(id, info)
end

local function HideReminder(id)
	if not sentReminders[id] then
		return
	end
	sentReminders[id] = nil
	if HasUpkeep() then
		Upkeep.RemoveReminder(id)
	end
end

---------------------------------------------------------------------------------------------
-- Sound. The setting is shared by every client run from the same folder and saved when one
-- exits, so the follower turns it back on as it logs out.

local function Mute(main)
	if db.muted then
		return
	end
	local current = GetCVar(SOUND_CVAR)
	db.muted = { restore = current }
	if current ~= "0" then
		SetCVar(SOUND_CVAR, "0")
		Util.Print("sound off while you play with " .. main .. ".")
	end
end

local function Unmute(quiet)
	local muted = db.muted
	if not muted then
		return
	end
	db.muted = nil
	-- Leave it alone if you've turned the sound back on yourself.
	if GetCVar(SOUND_CVAR) == "0" and muted.restore and muted.restore ~= "0" then
		SetCVar(SOUND_CVAR, muted.restore)
		if not quiet then
			Util.Print("sound back on.")
		end
	end
end

local function UpdateSound(set, isMain)
	if set and not isMain and db.features.sound then
		Mute(set.main)
	elseif not (holdUntil and GetTime() < holdUntil) then
		Unmute()
	end
end

---------------------------------------------------------------------------------------------
-- Focus: a follower gets a button that focuses the main while the main is in the group and
-- isn't the focus.

local function UpdateFocus(set, isMain)
	local unit = set and not isMain and db.features.focus and Util.UnitOf(Util.Norm(set.main))
	if unit then
		local isFocus = UnitIsUnit("focus", unit)
		if Util.IsHidden(isFocus) then
			return -- unreadable for now; keep whatever is showing
		end
		if not isFocus then
			local _, class = UnitClass(unit)
			local icon = (not Util.IsHidden(class) and class) and ("Interface/Icons/ClassIcon_" .. class)
				or "Interface/Icons/Ability_Hunter_SniperShot"
			ShowReminder(REMINDER_FOCUS, {
				icon = icon,
				click = { type = "focus", unit = unit },
				tooltip = "Focus " .. set.main,
			}, unit .. icon)
			return
		end
	end
	HideReminder(REMINDER_FOCUS)
end

---------------------------------------------------------------------------------------------
-- Login spell: a spell to cast once after each login, like a warrior's stance, which the game
-- resets on relogging. A reload keeps the reminder if it was still waiting; casting the spell,
-- or already being in that stance or form, clears it for the rest of the session.

local function SpellMatches(spellID, spell)
	if Util.IsHidden(spellID) or not spellID then
		return false
	end
	return spellID == spell.id or C_Spell.GetSpellName(spellID) == spell.name
end

local function InLoginForm(spell)
	for i = 1, GetNumShapeshiftForms() do
		local _, active, _, spellID = GetShapeshiftFormInfo(i)
		if not Util.IsHidden(active) and active and SpellMatches(spellID, spell) then
			return true
		end
	end
	return false
end

local function UpdateLoginSpell()
	local spell = chardb.loginSpell
	-- Right after logging in, the game can show the stance you logged out in for a moment
	-- before it puts you in Battle Stance, so that isn't trusted yet.
	local settled = not (settleUntil and GetTime() < settleUntil)
	if spell and chardb.loginPending and settled and InLoginForm(spell) then
		chardb.loginPending = false
		Util.Debug("login spell done: already in " .. spell.name)
	end
	if spell and chardb.loginPending and not Paused() then
		ShowReminder(REMINDER_LOGIN, {
			icon = C_Spell.GetSpellTexture(spell.id) or "Interface/Icons/INV_Misc_QuestionMark",
			click = { type = "spell", spell = spell.id },
			spell = spell.id, -- mouseover shows the spell's own tooltip
		}, tostring(spell.id))
	else
		HideReminder(REMINDER_LOGIN)
	end
end

---------------------------------------------------------------------------------------------
-- Loot: the leader of a group made only of set members switches it to free-for-all, once per
-- group, so a change you make by hand afterwards stays.

local function UpdateLoot()
	if not IsInGroup() then
		lootDoneFor = nil
		return
	end
	if Paused() or not db.features.loot then
		return
	end
	local leader = UnitIsGroupLeader("player")
	if Util.IsHidden(leader) or not leader then
		return
	end
	local members, complete = Util.GroupMembers()
	if not complete or #members == 0 then
		return
	end
	local norms = {}
	for i, m in ipairs(members) do
		norms[i] = m.norm
	end
	if not Sets.AllShareASet(norms) then
		return
	end
	table.sort(norms)
	local key = table.concat(norms, ",")
	if key == lootDoneFor then
		return
	end
	if InCombatLockdown() then
		lootWaiting = true
		return
	end
	lootDoneFor = key
	if C_PartyInfo.GetLootMethod() ~= Enum.LootMethod.Freeforall then
		local ok, err = pcall(C_PartyInfo.SetLootMethod, Enum.LootMethod.Freeforall)
		if not ok then
			Util.Debug("couldn't set the loot method: " .. tostring(err))
		end
	end
end

---------------------------------------------------------------------------------------------
-- Invites. The main invites a member when they turn up, unless that would pull them, or the
-- main, into a group with other players. Members accept invites from anyone they share a set
-- with.

local function CanInvite()
	if not IsInGroup() then
		return true
	end
	local leader = UnitIsGroupLeader("player")
	if Util.IsHidden(leader) then
		return false
	end
	if leader then
		return true
	end
	local assistant = IsInRaid() and UnitIsGroupAssistant("player")
	return not Util.IsHidden(assistant) and assistant == true
end

-- manual: from /tandem invite, which also invites a member who says they're in a group, and
-- doesn't mind who else is in ours.
local function TryInvite(norm, manual)
	local entry = Sets.online[norm]
	if not entry or entry.paused or Util.UnitOf(norm) or not Sets.IsMainWith(norm) then
		return false
	end
	if not manual then
		if entry.grouped then
			return false
		end
		local norms = { norm }
		for _, m in ipairs(Util.GroupMembers()) do
			norms[#norms + 1] = m.norm
		end
		if not Sets.AllShareASet(norms) then
			return false
		end
	end
	if not CanInvite() then
		return false
	end
	local ok, err = pcall(C_PartyInfo.InviteUnit, entry.name)
	if not ok then
		Util.Debug("couldn't invite " .. entry.name .. ": " .. tostring(err))
	end
	return ok
end

function ns.Arrived(norm)
	if Paused() or not db.features.invite then
		return
	end
	C_Timer.After(INVITE_DELAY, function()
		if not Paused() and db.features.invite then
			TryInvite(norm, false)
		end
	end)
end

local function InviteNow(manual)
	local any = false
	for norm in pairs(Sets.online) do
		if TryInvite(norm, manual) then
			any = true
		end
	end
	return any
end

local function OnInvite(name)
	if Util.IsHidden(name) or not name or Paused() or not db.features.invite then
		return
	end
	if not Sets.AllShareASet({ Util.Norm(name) }) then
		return
	end
	local ok = pcall(AcceptGroup)
	acceptedInvite = ok
end

-- Accepting leaves Blizzard's invite popup up; close it once we're in the group.
local function CloseInvitePopup()
	if not (acceptedInvite and IsInGroup()) then
		return
	end
	acceptedInvite = false
	if StaticPopup_Hide then
		StaticPopup_Hide("PARTY_INVITE")
	end
	if LFGInvitePopup and LFGInvitePopup:IsShown() and StaticPopupSpecial_Hide then
		StaticPopupSpecial_Hide(LFGInvitePopup)
	end
end

---------------------------------------------------------------------------------------------
-- Everything is worked out again from scratch whenever something changes.

function ns.Changed()
	if not loaded then
		return
	end
	local _, set = Sets.Active()
	local isMain = set and Sets.IsMain(set)
	UpdateSound(set, isMain)
	UpdateFocus(set, isMain)
	UpdateLoginSpell()
	UpdateLoot()
end

---------------------------------------------------------------------------------------------
-- Slash commands.

local function OnOff(value)
	return value and "on" or "off"
end

local function Status()
	local version = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON, "Version") or ""
	Util.Print(("version %s, %s."):format(version, Paused() and "|cffff8040paused|r (/tandem resume)" or "running"))
	local activeId = Sets.Active()
	local mine = Sets.Mine()
	if #mine == 0 then
		Util.Print("this character isn't in a set. Group up with your other characters and type /tandem set.")
	end
	for _, entry in ipairs(mine) do
		local state
		if entry.id == activeId then
			state = Sets.IsMain(entry.set) and "playing now, this character is the main"
				or "playing now, this character follows"
		else
			local missing = {}
			for _, name in ipairs(Sets.Others(entry.set)) do
				local o = Sets.online[Util.Norm(name)]
				missing[#missing + 1] = name .. (not o and " (offline)" or o.paused and " (paused)" or "")
			end
			state = "waiting for " .. table.concat(missing, ", ")
		end
		Util.Print("set: " .. Sets.Describe(entry.set) .. " - " .. state .. ".")
	end
	local f = db.features
	Util.Print(("sound %s, loot %s, invites %s, focus %s."):format(OnOff(f.sound), OnOff(f.loot),
		OnOff(f.invite), OnOff(f.focus)))
	local spell = chardb.loginSpell
	Util.Print("login spell: " .. (spell and (spell.name .. (chardb.loginPending and ", waiting to be cast"
		or ", cast this session")) or "none") .. ".")
	if not HasUpkeep() then
		Util.Print("Upkeep isn't loaded, so there are no reminders.")
	end
end

local function Help()
	Util.Print("commands:")
	print("  /tandem - what Tandem knows and is doing")
	print("  /tandem set - make your group a set, with this character as its main")
	print("  /tandem main - make this character the main of its set")
	print("  /tandem unset - remove this character's set")
	print("  /tandem invite - invite your set now; /tandem invite on|off for automatic invites")
	print("  /tandem sound on|off, /tandem loot on|off, /tandem focus on|off")
	print("  /tandem login <spell> - a reminder to cast it after each login; /tandem login off")
	print("  /tandem pause, /tandem resume - stop everything, and start again")
end

local function SetLoginSpell(name)
	if name:lower() == "off" then
		chardb.loginSpell, chardb.loginPending = nil, nil
		Util.Print("no login spell.")
		ns.Changed()
		return
	end
	local info = C_Spell.GetSpellInfo(name)
	local known = info and IsPlayerSpell(info.spellID)
	if not known then
		Util.Print("this character doesn't know a spell called \"" .. name .. "\".")
		return
	end
	chardb.loginSpell = { id = info.spellID, name = info.name }
	chardb.loginPending = true
	Util.Print("after each login you'll get a reminder to cast " .. info.name .. ".")
	if not HasUpkeep() then
		Util.Print("the reminder needs Upkeep, which isn't loaded.")
	end
	ns.Changed()
end

local FEATURES = { sound = "sound", loot = "loot", invite = "invite", invites = "invite", focus = "focus" }

SLASH_TANDEM1 = "/tandem"
SlashCmdList.TANDEM = function(msg)
	if not loaded then
		return
	end
	local command, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	command = command:lower()
	local feature = FEATURES[command]
	if command == "" or command == "status" then
		Status()
	elseif command == "set" then
		Sets.Create()
	elseif command == "main" then
		Sets.MakeMain()
	elseif command == "unset" then
		Sets.Remove()
	elseif command == "login" then
		if rest == "" then
			Util.Print("/tandem login <spell name>, or /tandem login off")
		else
			SetLoginSpell(rest)
		end
	elseif command == "pause" then
		chardb.paused = true
		Util.Print("paused until you type /tandem resume, even after logging out.")
		Sets.AnnounceAll()
		ns.Changed()
	elseif command == "resume" then
		chardb.paused = false
		lootDoneFor = nil
		Util.Print("running again.")
		Sets.AnnounceAll()
		ns.Changed()
		C_Timer.After(INVITE_DELAY, function()
			InviteNow(false)
		end)
	elseif feature and (rest == "on" or rest == "off") then
		db.features[feature] = rest == "on"
		if feature == "loot" then
			lootDoneFor = nil
		end
		Util.Print(feature .. " " .. rest .. ".")
		ns.Changed()
	elseif feature == "invite" and rest == "" then
		if not InviteNow(true) then
			Util.Print("nobody to invite: no member of a set you're the main of is online and out of your group.")
		end
	elseif command == "debug" then
		db.debug = not db.debug
		Util.Print("debug messages " .. OnOff(db.debug) .. ".")
	else
		Help()
	end
end

---------------------------------------------------------------------------------------------
-- Events.

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PARTY_LEADER_CHANGED")
events:RegisterEvent("PARTY_INVITE_REQUEST")
events:RegisterEvent("UNIT_CONNECTION")
events:RegisterEvent("PLAYER_FOCUS_CHANGED")
events:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

local function OnFirstWorld(isInitialLogin, isReloadingUi)
	-- A follower muted before a reload stays muted while its members find each other again.
	if isReloadingUi and db.heldMute then
		db.muted = { restore = db.heldMute }
		SetCVar(SOUND_CVAR, "0")
		holdUntil = GetTime() + RELOAD_HOLD
		C_Timer.After(RELOAD_HOLD + 0.5, ns.Changed)
	end
	db.heldMute = nil
	if isInitialLogin then
		chardb.loginPending = chardb.loginSpell ~= nil
		settleUntil = GetTime() + LOGIN_SETTLE
		C_Timer.After(LOGIN_SETTLE + 0.5, ns.Changed)
	end
	loaded = true
	Sets.Start()
	ns.Changed()
end

events:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_LOGIN" then
		db, chardb = Sets.Init()
		C_ChatInfo.RegisterAddonMessagePrefix(Util.PREFIX)
	elseif event == "PLAYER_ENTERING_WORLD" then
		if not loaded then
			OnFirstWorld(...)
		end
	elseif not loaded then
		return
	elseif event == "CHAT_MSG_ADDON" then
		Sets.OnMessage(...)
	elseif event == "GROUP_ROSTER_UPDATE" or event == "PARTY_LEADER_CHANGED" then
		CloseInvitePopup()
		-- Names can take a moment to arrive after the roster changes.
		if not rosterTimer then
			rosterTimer = C_Timer.NewTimer(1, function()
				rosterTimer = nil
				ns.Changed()
			end)
		end
	elseif event == "PARTY_INVITE_REQUEST" then
		OnInvite((...))
	elseif event == "UNIT_CONNECTION" then
		local unit, isConnected = ...
		if not Util.IsHidden(unit) and not Util.IsHidden(isConnected) and isConnected == false then
			local name = Util.FullUnitName(unit)
			if name then
				Sets.OnGone(name)
			end
		end
	elseif event == "UNIT_SPELLCAST_SENT" then
		-- unit, target, castGUID, spellID. Casts that never land leave an entry behind.
		local _, _, castGUID = ...
		if Util.IsHidden(castGUID) or not castGUID then
			return
		end
		local now = GetTime()
		for guid, sent in pairs(sentCasts) do
			if now - sent > 30 then
				sentCasts[guid] = nil
			end
		end
		sentCasts[castGUID] = now
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- unit, castGUID, spellID. Only a cast you sent counts, not one the game makes for you,
		-- such as putting you back in a stance as you log in.
		local _, castGUID, spellID = ...
		if Util.IsHidden(castGUID) or not (castGUID and sentCasts[castGUID]) then
			return
		end
		sentCasts[castGUID] = nil
		local spell = chardb.loginSpell
		if spell and chardb.loginPending and SpellMatches(spellID, spell) then
			chardb.loginPending = false
			Util.Debug("login spell done: you cast " .. spell.name)
			ns.Changed()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if lootWaiting then
			lootWaiting = false
			ns.Changed()
		end
	elseif event == "PLAYER_LOGOUT" then
		local muted = db.muted
		if muted then
			local stillOff = GetCVar(SOUND_CVAR) == "0"
			Unmute(true)
			-- Kept for a reload, where the next load picks it up; a real logout clears it then.
			db.heldMute = stillOff and muted.restore or nil
		end
	else -- PLAYER_FOCUS_CHANGED, UPDATE_SHAPESHIFT_FORM
		ns.Changed()
	end
end)
