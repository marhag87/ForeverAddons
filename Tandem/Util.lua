-- Util.lua
-- Printing, names, group members, sending addon messages, and the confirmation popup.

local _, ns = ...

local Util = {}
ns.Util = Util

Util.PREFIX = "Tandem"

function Util.Print(text)
	print("|cff33ff99Tandem:|r " .. text)
end

function Util.Debug(text)
	if TandemDB and TandemDB.debug then
		Util.Print("|cff999999" .. text .. "|r")
	end
end

-- On Forever, some values are hidden from addons in instances; testing or comparing one is an error.
function Util.IsHidden(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

---------------------------------------------------------------------------------------------
-- Names. Forever names are unique per region and come as "First Surname"; whispers and invites
-- need both parts.

local function SurnameSeparator()
	local consts = Constants and Constants.CharacterNameSeparatorConsts
	local separator = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR
	return type(separator) == "string" and separator ~= "" and separator or " "
end

-- UnitName returns the first name and surname separately.
function Util.FullUnitName(unit)
	local first, surname = UnitName(unit)
	if Util.IsHidden(first) or Util.IsHidden(surname) or not first or first == UNKNOWNOBJECT then
		return nil
	end
	if surname and surname ~= "" then
		return first .. SurnameSeparator() .. surname
	end
	return first
end

-- One spelling per character for comparisons: lower case, without a "-Realm" ending.
function Util.Norm(name)
	return (name:gsub("%-[^%-]*$", "")):lower()
end

function Util.MyName()
	return Util.FullUnitName("player") or UnitName("player")
end

local ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"

function Util.RandomString(length)
	local chars = {}
	for i = 1, length do
		local n = math.random(#ALPHABET)
		chars[i] = ALPHABET:sub(n, n)
	end
	return table.concat(chars)
end

-- Everyone else in the group as { unit, name, norm }, and whether every name could be read.
function Util.GroupMembers()
	local list, complete = {}, true
	local raid = IsInRaid()
	local count = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
	for i = 1, count do
		local unit = (raid and "raid" or "party") .. i
		local isMe = UnitIsUnit(unit, "player")
		if Util.IsHidden(isMe) then
			complete = false
		elseif not isMe then
			local name = Util.FullUnitName(unit)
			if name then
				list[#list + 1] = { unit = unit, name = name, norm = Util.Norm(name) }
			else
				complete = false
			end
		end
	end
	return list, complete
end

function Util.UnitOf(norm)
	for _, member in ipairs(Util.GroupMembers()) do
		if member.norm == norm then
			return member.unit
		end
	end
end

---------------------------------------------------------------------------------------------
-- Sending. Tandem's messages are short single lines. A throttled one is tried again; one to a
-- player who isn't online tells the presence code they've gone.

local results = Enum and Enum.SendAddonMessageResult or {}
local THROTTLED = {
	[results.AddonMessageThrottle or 3] = true,
	[results.ChannelThrottle or 8] = true,
}
local LOCKDOWN = results.AddOnMessageLockdown or 11 -- instances during an encounter
local OFFLINE = results.TargetOffline or 12
local MAX_TRIES = 12

local recentWhispers = {} -- name as whispered -> GetTime()

function Util.Send(text, channel, target, tries)
	tries = tries or 1
	if channel == "WHISPER" then
		recentWhispers[target] = GetTime()
	end
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, Util.PREFIX, text, channel, target)
	if not ok then
		Util.Debug("sending failed: " .. tostring(result))
		return
	end
	if (THROTTLED[result] or result == LOCKDOWN) and tries < MAX_TRIES then
		C_Timer.After(result == LOCKDOWN and 5 or 1, function()
			Util.Send(text, channel, target, tries + 1)
		end)
	elseif result == OFFLINE and target then
		ns.Sets.OnGone(target)
	end
end

function Util.Whisper(target, text)
	Util.Debug("to " .. target .. ": " .. text)
	Util.Send(text, "WHISPER", target)
end

-- Whispering a player who isn't online prints "No player named ... is currently playing." Hide
-- that for names we whispered a moment ago, and take it as them being offline.
local function FilterNotFound(_, _, message)
	if Util.IsHidden(message) or type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then
		return false
	end
	local now = GetTime()
	for target, sent in pairs(recentWhispers) do
		if now - sent > 10 then
			recentWhispers[target] = nil
		elseif message == ERR_CHAT_PLAYER_NOT_FOUND_S:format(target) then
			C_Timer.After(0, function()
				ns.Sets.OnGone(target)
			end)
			return true
		end
	end
	return false
end

local AddFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
if AddFilter then
	AddFilter("CHAT_MSG_SYSTEM", FilterNotFound)
end

---------------------------------------------------------------------------------------------
-- A yes/no popup of Tandem's own; Blizzard's dialog table is better left untouched.

local confirm

function Util.Confirm(text, acceptLabel, timeout, onAccept, onDecline)
	if not confirm then
		confirm = CreateFrame("Frame", "TandemConfirm", UIParent)
		confirm:SetSize(400, 180)
		confirm:SetPoint("TOP", 0, -160)
		confirm:SetFrameStrata("DIALOG")
		confirm:SetToplevel(true)
		confirm:EnableMouse(true)
		confirm:Hide()
		CreateFrame("Frame", nil, confirm, "DialogBorderTemplate")
		confirm.Text = confirm:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		confirm.Text:SetPoint("TOP", 0, -22)
		confirm.Text:SetWidth(350)
		confirm.Accept = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
		confirm.Accept:SetSize(120, 24)
		confirm.Accept:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -6, 18)
		confirm.Accept:SetScript("OnClick", function()
			confirm.answered = true
			confirm:Hide()
			confirm.onAccept()
		end)
		confirm.Decline = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
		confirm.Decline:SetSize(120, 24)
		confirm.Decline:SetPoint("BOTTOMLEFT", confirm, "BOTTOM", 6, 18)
		confirm.Decline:SetText("Not now")
		confirm.Decline:SetScript("OnClick", function()
			confirm:Hide()
		end)
		-- Closing it any other way (Escape, the timeout) counts as declining.
		confirm:SetScript("OnHide", function()
			if confirm.timer then
				confirm.timer:Cancel()
				confirm.timer = nil
			end
			if not confirm.answered then
				confirm.answered = true
				confirm.onDecline()
			end
		end)
		table.insert(UISpecialFrames, confirm:GetName())
	end
	confirm:Hide() -- a new question replaces one still open
	confirm.answered = false
	confirm.onAccept, confirm.onDecline = onAccept, onDecline
	confirm.Accept:SetText(acceptLabel)
	confirm.Text:SetText(text)
	confirm:SetHeight(confirm.Text:GetStringHeight() + 80)
	confirm:Show()
	confirm.timer = C_Timer.NewTimer(timeout, function()
		confirm:Hide()
	end)
end
