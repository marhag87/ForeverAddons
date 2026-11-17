-- Sync.lua
-- Pairing, sessions, and keeping Syndicator's characters in step between two accounts.
--
-- Each account sends only its own characters. What it receives it keeps as copies ("mirrors")
-- inside its own Syndicator data, where tooltips and the rest of Syndicator treat them like any
-- other character. A session starts when two paired characters prove the shared pairing secret
-- to each other. They then compare what they hold, send full copies where theirs differ, and
-- after that only small change lists as Syndicator records new loot, mail, gold and so on.
-- Full copies wait while the player is in an instance, where the game only lets about one
-- message a second through.

local _, ns = ...
local Util, Comms = ns.Util, ns.Comms

local Sync = {}
ns.Sync = Sync

local PING_INTERVAL = 60 -- seconds between looking for the other account while not connected
local INTRO_COOLDOWN = 5 -- seconds before answering another ping from the same name
local FLUSH_DELAY = 1.5 -- seconds to collect Syndicator changes before sending them
local PAIR_TIMEOUT = 60 -- seconds a pairing request stays open
local CHECK_INTERVAL = 600 -- seconds between fingerprint checks of the copies we hold
local CHECK_TICK = 30 -- seconds between looking whether a check is due and things are quiet
local QUIET_BEFORE_CHECK = 30 -- seconds without traffic before a check, so copies aren't mid-update
local SYNDICATOR_EVENTS = {
	"BagCacheUpdate", "MailCacheUpdate", "EquippedCacheUpdate", "CurrencyCacheUpdate", "AuctionsCacheUpdate",
	"VoidCacheUpdate",
}

local db -- SyndicatorSyncDB
local ready = false
local peers = {} -- partner account id -> { id, name, norm } of the session's other character
local peerIdByNorm = {} -- normalized name -> partner account id, for active sessions
local lastIntro = {} -- normalized name -> time we last introduced ourselves after a ping
local shadows = {} -- character key -> { partner, rev, data, pending }: what the partner holds of it
local dirty = {} -- character key -> true while it has changes not yet sent
local deferred = {} -- partner id -> { character key -> rev }: full copies waiting for us to leave an instance
local asked = {} -- character key -> true once we've asked for a full copy this session
local recheck = {} -- character key -> fingerprint of the full copy a check made us send
local flushTimer, rosterTimer
local pendingPair -- { norm, nonce, expires } while our pairing request waits for an answer

local function InitDB()
	SyndicatorSyncDB = SyndicatorSyncDB or {}
	db = SyndicatorSyncDB
	db.accountId = db.accountId or Util.RandomString(12)
	db.partners = db.partners or {} -- partner account id -> { secret, characters = { norm -> name }, paired }
	db.mirrors = db.mirrors or {} -- character key -> { partner, rev, updated }: copies we received
	db.owned = db.owned or {} -- character key -> true: characters logged in on this account
end

local function Characters()
	return SYNDICATOR_DATA and SYNDICATOR_DATA.Characters or {}
end

local function CurrentKey()
	return Syndicator.API.GetCurrentCharacter()
end

-- "First Surname" of the logged-in character, the way other clients see it as a sender.
local function MyName()
	local key = CurrentKey()
	if key then
		return (key:gsub("%-[^%-]*$", ""))
	end
	return Util.FullUnitName("player") or UnitName("player")
end

-- Proves knowing the pairing secret without sending it; bound to both names, so it can't be
-- replayed between other characters.
local function Proof(secret, from, to)
	return Util.Hash(secret .. "|" .. Util.Norm(from) .. ">" .. Util.Norm(to) .. "|" .. secret)
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

---------------------------------------------------------------------------------------------
-- Sending our characters: full copies and change lists.

local Flush

local function FlushSoon()
	if not flushTimer then
		flushTimer = C_Timer.NewTimer(FLUSH_DELAY, Flush)
	end
end

local function SendSnapshot(peer, key, baseRev)
	local data = Characters()[key]
	if not data then
		return
	end
	local shadow = { partner = peer.id, rev = baseRev + 1, data = Util.Copy(data), pending = true, sentAt = GetTime() }
	shadows[key] = shadow
	dirty[key] = nil
	local sent = Comms.SendDocument(peer.name, { t = "snap", key = key, r = shadow.rev, data = data }, function()
		shadow.pending = nil
		if dirty[key] then
			FlushSoon()
		end
	end)
	if not sent then
		shadows[key] = nil
	end
end

local function QueueSnapshot(peer, key, baseRev)
	if IsInInstance() then
		deferred[peer.id] = deferred[peer.id] or {}
		deferred[peer.id][key] = baseRev
		shadows[key] = nil
	else
		SendSnapshot(peer, key, baseRev)
	end
end

local function SendDeferred()
	if IsInInstance() then
		return
	end
	for partnerId, keys in pairs(deferred) do
		local peer = peers[partnerId]
		if peer then
			for key, rev in pairs(keys) do
				SendSnapshot(peer, key, rev)
			end
		end
		deferred[partnerId] = {}
	end
end

-- Sends what changed since the partner's copy, for every character Syndicator reported changes on.
-- One change list per character is in flight at a time; later changes wait and go out together.
function Flush()
	flushTimer = nil
	for key in pairs(dirty) do
		local shadow = shadows[key]
		local peer = shadow and peers[shadow.partner]
		local data = Characters()[key]
		if not data or db.mirrors[key] then
			dirty[key] = nil
		elseif peer and not shadow.pending then
			dirty[key] = nil
			local changes = Util.Diff(shadow.data, data)
			if #changes > 0 then
				local base = shadow.rev
				shadow.rev = base + 1
				Util.Apply(shadow.data, changes)
				shadow.pending = true
				shadow.sentAt = GetTime()
				Comms.SendDocument(peer.name, { t = "delta", key = key, b = base, r = shadow.rev, c = changes }, function()
					shadow.pending = nil
					if dirty[key] then
						FlushSoon()
					end
				end)
			end
		end
	end
end

local function OnSyndicatorChange(_, key)
	if ready and type(key) == "string" and not db.mirrors[key] then
		dirty[key] = true
		FlushSoon()
	end
end

---------------------------------------------------------------------------------------------
-- Sessions.

local function EndSession(partnerId)
	local peer = peers[partnerId]
	if not peer then
		return
	end
	peers[partnerId] = nil
	peerIdByNorm[peer.norm] = nil
	Comms.Forget(peer.name)
	for key, shadow in pairs(shadows) do
		if shadow.partner == partnerId then
			shadows[key] = nil
		end
	end
	deferred[partnerId] = nil
	Util.Debug("session with " .. peer.name .. " ended")
end

-- A fingerprint of each copy we hold of the partner's characters.
local function HeldFingerprints(peer)
	local have = {}
	for key, mirror in pairs(db.mirrors) do
		local data = Characters()[key]
		if mirror.partner == peer.id and data then
			have[key] = { h = Util.ContentHash(data), r = mirror.rev or 0 }
		end
	end
	return have
end

-- Tells the partner which of its characters we hold (with a fingerprint of each), and which
-- characters are ours. With fresh, claims to hold nothing, so the partner sends full copies of
-- everything.
local function SendManifest(peer, fresh)
	local own = {}
	for key in pairs(db.owned) do
		own[#own + 1] = key
	end
	Comms.SendDocument(peer.name, { t = "manifest", have = fresh and {} or HeldFingerprints(peer), own = own })
end

-- Every so often, while nothing is moving, the fingerprints of our copies go to the partner
-- again; it sends full copies of any that drifted without a change list noticing.
local function CheckPeers()
	local now = GetTime()
	for _, peer in pairs(peers) do
		if now - (peer.lastCheck or peer.started) >= CHECK_INTERVAL and now - (peer.lastDoc or 0) >= QUIET_BEFORE_CHECK
			and not Comms.IsBusy(peer.name) then
			peer.lastCheck = now
			Util.Debug("checking copies with " .. peer.name)
			Comms.SendDocument(peer.name, { t = "check", have = HeldFingerprints(peer) })
		end
	end
end

local function StartSession(partnerId, name)
	local old = peers[partnerId]
	EndSession(partnerId)
	local peer = { id = partnerId, name = name, norm = Util.Norm(name), started = GetTime(), theirs = {} }
	peers[partnerId] = peer
	peerIdByNorm[peer.norm] = partnerId
	deferred[partnerId] = {}
	wipe(asked)
	wipe(recheck)
	db.partners[partnerId].characters[peer.norm] = name
	SendManifest(peer)
	if not old or old.norm ~= peer.norm then
		Util.Print("syncing with " .. name)
	end
end

local function SendIntro(partnerId, target, wantReply)
	local partner = db.partners[partnerId]
	if not partner then
		return
	end
	Comms.SendControl("WHISPER", target, ("I:%s:%s:%d"):format(db.accountId,
		Proof(partner.secret, MyName(), target), wantReply and 1 or 0))
end

local function GroupChannel()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	elseif IsInGroup() then
		return "PARTY"
	end
end

-- Announces this account to the group while some partner isn't connected yet. The ping carries
-- only the account id; the partner answers with a whispered introduction.
local function Ping()
	if not ready then
		return
	end
	local missing = false
	for partnerId in pairs(db.partners) do
		if not peers[partnerId] then
			missing = true
		end
	end
	local channel = GroupChannel()
	if missing and channel then
		Comms.SendControl(channel, nil, "P:" .. db.accountId)
	end
end

function Sync.IsTrusted(sender)
	return peerIdByNorm[Util.Norm(sender)] ~= nil
end

-- False only when the name is in our group and shown as offline.
function Sync.IsReachable(target)
	local norm = Util.Norm(target)
	for i = 1, GetNumSubgroupMembers() do
		local unit = "party" .. i
		local name = Util.FullUnitName(unit)
		if name and Util.Norm(name) == norm then
			local connected = UnitIsConnected(unit)
			return Util.IsHidden(connected) or connected
		end
	end
	return true
end

function Sync.OnPeerGone(target)
	local norm = Util.Norm(target)
	if pendingPair and pendingPair.norm == norm then
		pendingPair = nil
		Util.Print(target .. " isn't online, so the pairing request didn't reach them")
	end
	local partnerId = peerIdByNorm[norm]
	if partnerId then
		EndSession(partnerId)
	end
end

---------------------------------------------------------------------------------------------
-- Receiving the partner's characters.

local function Accepts(peer, key)
	if type(key) ~= "string" then
		return false
	end
	if key == CurrentKey() or db.owned[key] then
		Util.Debug(("ignored %s from %s: it belongs to this account"):format(key, peer.name))
		return false
	end
	return true
end

local documents = {}

-- What the partner holds of our characters decides what we send: a full copy where its copy is
-- missing or differs, nothing where it matches.
function documents.manifest(peer, doc)
	local theirs = {}
	for _, key in ipairs(type(doc.own) == "table" and doc.own or {}) do
		if type(key) == "string" then
			theirs[key] = true
			-- They've logged in on it, so it's theirs, even if we hold a copy we took for ours.
			if not db.owned[key] and not db.mirrors[key] and key ~= CurrentKey() and Characters()[key] then
				db.mirrors[key] = { partner = peer.id, rev = -1 }
			end
		end
	end
	peer.theirs = theirs
	local have = type(doc.have) == "table" and doc.have or {}
	for key, data in pairs(Characters()) do
		if not db.mirrors[key] and not theirs[key] then
			local held = type(have[key]) == "table" and have[key] or nil
			local heldRev = held and tonumber(held.r) or 0
			if held and held.h == Util.ContentHash(data) then
				shadows[key] = { partner = peer.id, rev = heldRev, data = Util.Copy(data) }
				if dirty[key] then
					FlushSoon()
				end
			else
				QueueSnapshot(peer, key, heldRev)
			end
		end
	end
end

-- The partner's periodic fingerprints of its copies of our characters. Characters with changes
-- on the way, or sent recently, are left out: their copies may simply not have caught up yet.
function documents.check(peer, doc)
	local have = type(doc.have) == "table" and doc.have or {}
	local now = GetTime()
	local waiting = deferred[peer.id] or {}
	for key, data in pairs(Characters()) do
		local shadow = shadows[key]
		local busy = dirty[key] or waiting[key] ~= nil
			or (shadow and (shadow.pending or now - (shadow.sentAt or 0) < QUIET_BEFORE_CHECK))
		if not db.mirrors[key] and not peer.theirs[key] and not busy then
			local held = type(have[key]) == "table" and have[key] or nil
			local current = Util.ContentHash(data)
			if held and held.h == current then
				recheck[key] = nil
				if not shadow then
					shadows[key] = { partner = peer.id, rev = tonumber(held.r) or 0, data = Util.Copy(data) }
				end
			elseif recheck[key] == current then
				-- A full copy of exactly this data already went over and still doesn't match:
				-- something in the packing, not drift. Sending it again wouldn't help.
				Util.Debug(("%s still differs on %s's side after a full copy; not sending it again"):format(key, peer.name))
			else
				Util.Debug(("%s differs on %s's side; sending a full copy"):format(key, peer.name))
				recheck[key] = current
				QueueSnapshot(peer, key, held and tonumber(held.r) or (shadow and shadow.rev) or 0)
			end
		end
	end
end

function documents.snap(peer, doc)
	if not Accepts(peer, doc.key) or not LooksLikeCharacter(doc.data) then
		return
	end
	SYNDICATOR_DATA.Characters[doc.key] = doc.data
	db.mirrors[doc.key] = { partner = peer.id, rev = tonumber(doc.r) or 0, updated = time() }
	asked[doc.key] = nil
	NotifySyndicator(doc.key)
end

function documents.delta(peer, doc)
	if not Accepts(peer, doc.key) or type(doc.c) ~= "table" then
		return
	end
	local mirror = db.mirrors[doc.key]
	local data = Characters()[doc.key]
	if not (mirror and data and mirror.partner == peer.id and mirror.rev == doc.b) then
		-- Our copy is out of step (or was deleted): ask once for a full one.
		if not asked[doc.key] then
			asked[doc.key] = true
			Util.Debug(("copy of %s is out of step; asking for a full one"):format(doc.key))
			Comms.SendDocument(peer.name, { t = "need", keys = { doc.key } })
		end
		return
	end
	Util.Apply(data, doc.c)
	mirror.rev = doc.r
	mirror.updated = time()
	NotifySyndicator(doc.key)
end

function documents.need(peer, doc)
	for _, key in ipairs(type(doc.keys) == "table" and doc.keys or {}) do
		if type(key) == "string" and not db.mirrors[key] and Characters()[key] then
			local shadow = shadows[key]
			QueueSnapshot(peer, key, shadow and shadow.rev or 0)
		end
	end
end

function Sync.OnDocument(sender, doc)
	local peer = peers[peerIdByNorm[Util.Norm(sender)] or ""]
	local handler = peer and type(doc.t) == "string" and documents[doc.t]
	if handler then
		peer.lastDoc = GetTime()
		handler(peer, doc)
	end
end

---------------------------------------------------------------------------------------------
-- Pairing.

local confirm

local function ShowPairConfirm(name, onAccept, onDecline)
	if not confirm then
		confirm = CreateFrame("Frame", "SyndicatorSyncPairConfirm", UIParent)
		confirm:SetSize(380, 140)
		confirm:SetPoint("TOP", 0, -160)
		confirm:SetFrameStrata("DIALOG")
		confirm:SetToplevel(true)
		confirm:EnableMouse(true)
		confirm:Hide()
		CreateFrame("Frame", nil, confirm, "DialogBorderTemplate")
		confirm.Text = confirm:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		confirm.Text:SetPoint("TOP", 0, -22)
		confirm.Text:SetWidth(330)
		confirm.Accept = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
		confirm.Accept:SetSize(120, 24)
		confirm.Accept:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -6, 18)
		confirm.Accept:SetText("Pair")
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
	confirm:Hide() -- a new request replaces one still open
	confirm.answered = false
	confirm.onAccept, confirm.onDecline = onAccept, onDecline
	confirm.Text:SetText(("%s wants to pair your accounts, so both share their Syndicator data with each other.\n\nPair with that account?"):format(name))
	confirm:Show()
	confirm.timer = C_Timer.NewTimer(PAIR_TIMEOUT, function()
		confirm:Hide()
	end)
end

local control = {}

-- A ping: some partner account is looking for us.
function control.P(sender, _, body)
	local partnerId = body:match("^(%w+)$")
	if not partnerId or partnerId == db.accountId or not db.partners[partnerId] then
		return
	end
	local norm = Util.Norm(sender)
	local peer = peers[partnerId]
	if peer and peer.norm == norm then
		EndSession(partnerId) -- our peer lost its session (a reload, say): start over
	end
	if lastIntro[norm] and GetTime() - lastIntro[norm] < INTRO_COOLDOWN then
		return
	end
	lastIntro[norm] = GetTime()
	SendIntro(partnerId, sender, true)
end

-- An introduction: the sender proves it's on a paired account, and may ask us to do the same.
function control.I(sender, channel, body)
	if channel ~= "WHISPER" then
		return
	end
	local partnerId, proof, wantReply = body:match("^(%w+):([%d%.]+):(%d)$")
	local partner = partnerId and db.partners[partnerId]
	if not partner then
		return
	end
	if proof ~= Proof(partner.secret, sender, MyName()) then
		Util.Debug("ignored an introduction from " .. sender .. " with the wrong proof")
		return
	end
	local peer = peers[partnerId]
	if wantReply == "1" or not (peer and peer.norm == Util.Norm(sender)) then
		StartSession(partnerId, sender)
	end
	if wantReply == "1" then
		SendIntro(partnerId, sender, false)
	end
end

-- A pairing request; only a click on the popup answers it.
function control.PQ(sender, channel, body)
	if channel ~= "WHISPER" then
		return
	end
	local partnerId, nonce = body:match("^(%w+):(%w+)$")
	if not partnerId or partnerId == db.accountId then
		return
	end
	ShowPairConfirm(sender, function()
		local secret = Util.RandomString(24)
		db.partners[partnerId] = { secret = secret, characters = { [Util.Norm(sender)] = sender }, paired = time() }
		Comms.SendControl("WHISPER", sender, ("PA:%s:%s:%s"):format(db.accountId, nonce, secret))
		Util.Print("paired with " .. sender .. "'s account")
	end, function()
		Comms.SendControl("WHISPER", sender, "PD:" .. nonce)
	end)
end

-- Our pairing request was accepted: keep the secret and introduce ourselves.
function control.PA(sender, channel, body)
	if channel ~= "WHISPER" or not pendingPair then
		return
	end
	local partnerId, nonce, secret = body:match("^(%w+):(%w+):(%w+)$")
	if not partnerId or nonce ~= pendingPair.nonce or Util.Norm(sender) ~= pendingPair.norm
		or GetTime() > pendingPair.expires then
		return
	end
	pendingPair = nil
	db.partners[partnerId] = { secret = secret, characters = { [Util.Norm(sender)] = sender }, paired = time() }
	Util.Print("paired with " .. sender .. "'s account")
	SendIntro(partnerId, sender, true)
end

function control.PD(sender, _, body)
	if pendingPair and body == pendingPair.nonce then
		pendingPair = nil
		Util.Print(sender .. " declined pairing")
	end
end

function Sync.OnControl(kind, body, sender, channel)
	local handler = ready and control[kind]
	if handler then
		handler(sender, channel, body)
	end
end

---------------------------------------------------------------------------------------------
-- Commands.

local function Age(seconds)
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. " min ago"
	elseif seconds < 86400 then
		return math.floor(seconds / 3600) .. " h ago"
	end
	return math.floor(seconds / 86400) .. " days ago"
end

local function Status()
	if not next(db.partners) then
		Util.Print("not paired. Group with your other account's character and type /ssync pair <its name>")
	end
	for partnerId, partner in pairs(db.partners) do
		local names = {}
		for _, name in pairs(partner.characters) do
			names[#names + 1] = name
		end
		table.sort(names)
		local peer = peers[partnerId]
		Util.Print(("paired with %s; %s"):format(table.concat(names, ", "),
			peer and ("syncing with " .. peer.name) or "not connected (it connects while you're grouped)"))
	end
	local copies = {}
	for key, mirror in pairs(db.mirrors) do
		copies[#copies + 1] = key .. (mirror.updated and (" (" .. Age(time() - mirror.updated) .. ")") or "")
	end
	table.sort(copies)
	Util.Print("copies held: " .. (#copies > 0 and table.concat(copies, ", ") or "none"))
	local waiting = Comms.QueueLength()
	if waiting > 0 then
		Util.Print(waiting .. " messages waiting to be sent")
	end
end

local function Help()
	Util.Print("/ssync - status")
	Util.Print("/ssync pair <name> - pair with your other account's character (both online)")
	Util.Print("/ssync resync - ask the other account to send fresh copies of its characters")
	Util.Print("/ssync unpair - stop syncing with the other account")
	Util.Print("/ssync forget - remove the other account's characters from Syndicator here")
	Util.Print("/ssync debug - show or hide details of what's sent")
end

SLASH_SYNDICATORSYNC1 = "/ssync"
SlashCmdList.SYNDICATORSYNC = function(message)
	if not ready then
		Util.Print("waiting for Syndicator to finish loading")
		return
	end
	local command, rest = message:match("^%s*(%S*)%s*(.-)%s*$")
	command = command:lower()
	if command == "" or command == "status" then
		Status()
	elseif command == "pair" then
		if rest == "" then
			Util.Print("usage: /ssync pair <name of your other account's character>")
			return
		end
		local target = Util.CompleteName(rest)
		pendingPair = { norm = Util.Norm(target), nonce = Util.RandomString(8), expires = GetTime() + PAIR_TIMEOUT }
		Comms.SendControl("WHISPER", target, ("PQ:%s:%s"):format(db.accountId, pendingPair.nonce))
		Util.Print(("asked %s to pair; accept the popup on that client"):format(target))
	elseif command == "resync" then
		local any = false
		for _, peer in pairs(peers) do
			SendManifest(peer, true)
			any = true
		end
		Util.Print(any and "asked for fresh copies" or "not connected to the other account right now")
	elseif command == "unpair" then
		for partnerId in pairs(db.partners) do
			EndSession(partnerId)
		end
		wipe(db.partners)
		Util.Print("unpaired. The other account's characters stay in Syndicator; /ssync forget removes them")
	elseif command == "forget" then
		local count = 0
		for key in pairs(db.mirrors) do
			if Characters()[key] and pcall(Syndicator.API.DeleteCharacter, key) then
				count = count + 1
			end
		end
		wipe(db.mirrors)
		Util.Print(("removed %d characters from Syndicator.%s"):format(count,
			next(db.partners) and " While paired they come back at the next sync; /ssync unpair stops that" or ""))
	elseif command == "debug" then
		db.debug = not db.debug
		Util.Print("details " .. (db.debug and "shown" or "hidden"))
	else
		Help()
	end
end

---------------------------------------------------------------------------------------------

local function OnReady()
	if ready then
		return
	end
	ready = true
	local current = CurrentKey()
	if current then
		db.owned[current] = true
		db.mirrors[current] = nil
	end
	for _, event in ipairs(SYNDICATOR_EVENTS) do
		Syndicator.CallbackRegistry:RegisterCallback(event, OnSyndicatorChange, Sync)
	end
	C_Timer.After(3, Ping)
	C_Timer.NewTicker(PING_INTERVAL, Ping)
	C_Timer.NewTicker(CHECK_TICK, CheckPeers)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, ...)
	if event == "CHAT_MSG_ADDON" then
		if ready then
			Comms.OnMessage(...)
		end
	elseif event == "PLAYER_LOGIN" then
		InitDB()
		C_ChatInfo.RegisterAddonMessagePrefix(Util.PREFIX)
		if Syndicator.API.IsReady() then
			OnReady()
		else
			Syndicator.CallbackRegistry:RegisterCallback("Ready", OnReady, "SyndicatorSyncReady")
		end
	elseif event == "GROUP_ROSTER_UPDATE" then
		if ready and not rosterTimer then
			rosterTimer = C_Timer.NewTimer(3, function()
				rosterTimer = nil
				Ping()
			end)
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if ready then
			SendDeferred()
		end
	end
end)
