-- SyndicatorSync: Syndicator's characters on both of your accounts, through AccountLink.
--
-- AccountLink pairs the accounts and carries the data. This file hands it Syndicator's
-- characters as a dataset and tells Syndicator when a copy from the other account arrives or
-- changes. Copies ("mirrors") live inside this account's Syndicator data, where tooltips, search
-- and the bank view treat them like any other character.

local SYNDICATOR_EVENTS = {
	"BagCacheUpdate", "MailCacheUpdate", "EquippedCacheUpdate", "CurrencyCacheUpdate", "AuctionsCacheUpdate",
	"VoidCacheUpdate",
}
local DATASET = "syndicator"

local db -- SyndicatorSyncDB: { owned, mirrors }, kept by AccountLink
local ready = false

local function Print(text)
	print("|cff33ff99SyndicatorSync:|r " .. text)
end

local function Characters()
	return SYNDICATOR_DATA and SYNDICATOR_DATA.Characters or {}
end

local function LooksLikeCharacter(data)
	return type(data) == "table" and type(data.details) == "table" and type(data.details.character) == "string"
		and type(data.bags) == "table"
end

-- Tells Syndicator a copy changed, so it recounts its tooltip totals and search results for that
-- character. Only MailCacheUpdate: Syndicator treats it as "everything this character holds may
-- have changed", and fires it itself for characters other than the one logged in (mail sent to an
-- alt). The other cache events are only ever fired for the logged-in character, and addons rely
-- on that: Baganator takes BagCacheUpdate as being about your live bags, so one for a synced
-- character swapped its bag window to that character and sorted your real bags by its layout.
local function NotifySyndicator(key)
	Syndicator.CallbackRegistry:TriggerEvent("MailCacheUpdate", key)
end

-- Copies arrive through NotifySyndicator's MailCacheUpdate too; AccountLink ignores changes on
-- characters it holds as copies.
local function OnSyndicatorChange(_, key)
	AccountLink.Changed(DATASET, key)
end

local function OnReady()
	if ready then
		return
	end
	ready = true
	AccountLink.Register(DATASET, {
		state = db,
		title = "Syndicator's bags, bank, mail and gold",
		Store = function()
			return SYNDICATOR_DATA and SYNDICATOR_DATA.Characters
		end,
		CurrentKey = function()
			return Syndicator.API.GetCurrentCharacter()
		end,
		Valid = LooksLikeCharacter,
		OnMirrored = NotifySyndicator,
	})
	for _, event in ipairs(SYNDICATOR_EVENTS) do
		Syndicator.CallbackRegistry:RegisterCallback(event, OnSyndicatorChange, "SyndicatorSync")
	end
end

---------------------------------------------------------------------------------------------
-- Commands. Pairing lives in AccountLink (/alink); these stay for the Syndicator side.

local function Status()
	AccountLink.PrintStatus()
	local copies = {}
	for key, mirror in pairs(db.mirrors) do
		copies[#copies + 1] = key .. (mirror.updated and (" (" .. AccountLink.Age(time() - mirror.updated) .. ")") or "")
	end
	table.sort(copies)
	Print("copies held: " .. (#copies > 0 and table.concat(copies, ", ") or "none"))
end

local function Help()
	Print("/ssync - status")
	Print("/ssync pair <name> - pair with your other account's character (same as /alink pair)")
	Print("/ssync resync - ask the other account to send fresh copies of its characters")
	Print("/ssync unpair - stop sharing with the other account (same as /alink unpair)")
	Print("/ssync forget - remove the other account's characters from Syndicator here")
	Print("/ssync debug - show or hide details of what's sent")
end

SLASH_SYNDICATORSYNC1 = "/ssync"
SlashCmdList.SYNDICATORSYNC = function(message)
	if not ready then
		Print("waiting for Syndicator to finish loading")
		return
	end
	local command, rest = message:match("^%s*(%S*)%s*(.-)%s*$")
	command = command:lower()
	if command == "" or command == "status" then
		Status()
	elseif command == "pair" then
		AccountLink.Pair(rest)
	elseif command == "resync" then
		Print(AccountLink.Resync(DATASET) and "asked for fresh copies" or "not connected to the other account right now")
	elseif command == "unpair" then
		AccountLink.Unpair()
		Print("the other account's characters stay in Syndicator; /ssync forget removes them")
	elseif command == "forget" then
		local count = 0
		for key in pairs(db.mirrors) do
			if Characters()[key] and pcall(Syndicator.API.DeleteCharacter, key) then
				count = count + 1
			end
		end
		wipe(db.mirrors)
		Print(("removed %d characters from Syndicator. While paired they come back at the next sync; /alink unpair stops that")
			:format(count))
	elseif command == "debug" then
		AccountLink.ToggleDebug()
	else
		Help()
	end
end

---------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= "SyndicatorSync" then
			return
		end
		SyndicatorSyncDB = SyndicatorSyncDB or {}
		db = SyndicatorSyncDB
		-- Before 1.1.0 the pairing lived here; AccountLink keeps it now.
		if db.partners or db.accountId then
			AccountLink.Adopt(db.accountId, db.partners)
			db.partners, db.accountId, db.debug = nil, nil, nil
		end
		db.owned = db.owned or {}
		db.mirrors = db.mirrors or {}
	elseif event == "PLAYER_LOGIN" then
		if Syndicator.API.IsReady() then
			OnReady()
		else
			Syndicator.CallbackRegistry:RegisterCallback("Ready", OnReady, "SyndicatorSyncReady")
		end
	end
end)
