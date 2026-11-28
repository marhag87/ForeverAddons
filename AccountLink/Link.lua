-- Link.lua
-- Pairing, sessions, and keeping other addons' data about your characters in step between two
-- accounts.
--
-- Two accounts pair once: a popup on the other client confirms, and both keep a shared secret.
-- While a character from each is in the same group, they prove the secret to each other and hold
-- a session.
--
-- Addons register datasets: tables keyed by character. This account's characters are its own;
-- the partner's arrive as copies ("mirrors"). Each account sends only its own characters. At the
-- start of a session each side tells the other, per dataset, which of its characters it holds,
-- with a fingerprint of each. The owner sends full copies where those differ, and after that only
-- small change lists as the addon reports changes. Full copies wait while the sender is in an
-- instance, where the game only lets about one message a second through.
--
-- API (global AccountLink):
--   AccountLink.Register(name, spec) once the addon's data is ready. spec:
--     state       a table in the addon's saved variables; AccountLink keeps state.owned
--                 (characters logged in on this account) and state.mirrors (copies received,
--                 key -> { partner, rev, updated }) in it.
--     Store()     returns the table of character key -> data, own characters and copies alike.
--                 Copies are written into it.
--     CurrentKey() returns the logged-in character's key.
--     Valid(data) optional: false drops a received copy.
--     OnMirrored(key) optional: called after a copy arrived or changed (state.mirrors is set).
--     title       optional: what the data is, for the pairing popup and /alink.
--   AccountLink.Changed(name, key)  one of this account's characters changed.
--   AccountLink.Resync(name)        asks the partner for fresh full copies; nil name: every dataset.
--   AccountLink.Pair(name), AccountLink.Unpair(), AccountLink.PrintStatus(), AccountLink.ToggleDebug().

local _, ns = ...
local Util, Comms = ns.Util, ns.Comms

local Link = {}
ns.Link = Link

AccountLink = {}

local PING_INTERVAL = 60 -- seconds between looking for the other account while not connected
local INTRO_COOLDOWN = 5 -- seconds before answering another ping from the same name
local FLUSH_DELAY = 1.5 -- seconds to collect changes before sending them
local PAIR_TIMEOUT = 60 -- seconds a pairing request stays open
local CHECK_INTERVAL = 600 -- seconds between fingerprint checks of the copies we hold
local CHECK_TICK = 30 -- seconds between looking whether a check is due and things are quiet
local QUIET_BEFORE_CHECK = 30 -- seconds without traffic before a check, so copies aren't mid-update

local db -- AccountLinkDB
local ready = false
-- name -> { name, spec, shadows, dirty, asked, recheck }, where per character key:
--   shadows: { partner, rev, data, pending, sentAt }, what the partner holds of it
--   dirty: true while it has changes not yet sent
--   asked: true once we've asked for a full copy this session
--   recheck: fingerprint of the full copy a check made us send
local datasets = {}
local order = {} -- dataset names in the order they registered
-- partner account id -> { id, name, norm, started, boot, lastDoc, lastCheck, theirs, manifests }
-- for the session's other character. theirs[dataset] = set of its own keys; manifests[dataset]
-- = its latest manifest, kept for datasets that register here later.
local peers = {}
local peerIdByNorm = {} -- normalized name -> partner account id, for active sessions
local lastIntro = {} -- normalized name -> time we last introduced ourselves after a ping
local deferred = {} -- partner id -> { dataset -> { key -> rev } }: full copies waiting for us to leave an instance
local flushTimer, rosterTimer
local pendingPair -- { norm, nonce, expires } while our pairing request waits for an answer
-- Names this load of the UI in pings and introductions, so a ping that was sent before the
-- partner heard from us can be told apart from one sent after the partner reloaded.
local bootId = Util.RandomString(6)

local function InitDB()
	AccountLinkDB = AccountLinkDB or {}
	db = AccountLinkDB
	db.accountId = db.accountId or Util.RandomString(12)
	db.partners = db.partners or {} -- partner account id -> { secret, characters = { norm -> name }, paired }
end

-- "First Surname" of the logged-in character, the way other clients see it as a sender.
local function MyName()
	return Util.FullUnitName("player") or UnitName("player")
end

-- Proves knowing the pairing secret without sending it; bound to both names, so it can't be
-- replayed between other characters.
local function Proof(secret, from, to)
	return Util.Hash(secret .. "|" .. Util.Norm(from) .. ">" .. Util.Norm(to) .. "|" .. secret)
end

local function Store(set)
	return set.spec.Store() or {}
end

local function Mirrored(set, key)
	if set.spec.OnMirrored then
		local ok, err = pcall(set.spec.OnMirrored, key)
		if not ok then
			Util.Debug(("%s: OnMirrored failed: %s"):format(set.name, tostring(err)))
		end
	end
end

local function DeferredFor(partnerId, set)
	deferred[partnerId] = deferred[partnerId] or {}
	deferred[partnerId][set.name] = deferred[partnerId][set.name] or {}
	return deferred[partnerId][set.name]
end

---------------------------------------------------------------------------------------------
-- Sending our characters: full copies and change lists.

local Flush

local function FlushSoon()
	if not flushTimer then
		flushTimer = C_Timer.NewTimer(FLUSH_DELAY, Flush)
	end
end

local function SendSnapshot(peer, set, key, baseRev)
	local data = Store(set)[key]
	if not data then
		return
	end
	local shadow = { partner = peer.id, rev = baseRev + 1, data = Util.Copy(data), pending = true, sentAt = GetTime() }
	set.shadows[key] = shadow
	set.dirty[key] = nil
	local sent = Comms.SendDocument(peer.name, { t = "snap", ds = set.name, key = key, r = shadow.rev, data = data },
		function()
			shadow.pending = nil
			if set.dirty[key] then
				FlushSoon()
			end
		end)
	if not sent then
		set.shadows[key] = nil
	end
end

local function QueueSnapshot(peer, set, key, baseRev)
	if IsInInstance() then
		DeferredFor(peer.id, set)[key] = baseRev
		set.shadows[key] = nil
	else
		SendSnapshot(peer, set, key, baseRev)
	end
end

local function SendDeferred()
	if IsInInstance() then
		return
	end
	for partnerId, byDataset in pairs(deferred) do
		local peer = peers[partnerId]
		if peer then
			for name, keys in pairs(byDataset) do
				local set = datasets[name]
				if set then
					for key, rev in pairs(keys) do
						SendSnapshot(peer, set, key, rev)
					end
				end
			end
		end
		deferred[partnerId] = {}
	end
end

-- Sends what changed since the partner's copy, for every character an addon reported changes
-- on. One change list per character is in flight at a time; later changes wait and go out
-- together.
function Flush()
	flushTimer = nil
	for _, name in ipairs(order) do
		local set = datasets[name]
		local store, mirrors = Store(set), set.spec.state.mirrors
		for key in pairs(set.dirty) do
			local shadow = set.shadows[key]
			local peer = shadow and peers[shadow.partner]
			local data = store[key]
			if not data or mirrors[key] then
				set.dirty[key] = nil
			elseif peer and not shadow.pending then
				set.dirty[key] = nil
				local changes = Util.Diff(shadow.data, data)
				if #changes > 0 then
					local base = shadow.rev
					shadow.rev = base + 1
					Util.Apply(shadow.data, changes)
					shadow.pending = true
					shadow.sentAt = GetTime()
					Comms.SendDocument(peer.name, { t = "delta", ds = name, key = key, b = base, r = shadow.rev, c = changes },
						function()
							shadow.pending = nil
							if set.dirty[key] then
								FlushSoon()
							end
						end)
				end
			end
		end
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
	for _, set in pairs(datasets) do
		for key, shadow in pairs(set.shadows) do
			if shadow.partner == partnerId then
				set.shadows[key] = nil
			end
		end
	end
	deferred[partnerId] = nil
	Util.Debug("session with " .. peer.name .. " ended")
end

-- A fingerprint of each copy we hold of the partner's characters.
local function HeldFingerprints(peer, set)
	local have = {}
	local store = Store(set)
	for key, mirror in pairs(set.spec.state.mirrors) do
		local data = store[key]
		if mirror.partner == peer.id and data then
			have[key] = { h = Util.ContentHash(data), r = mirror.rev or 0 }
		end
	end
	return have
end

-- Tells the partner which of its characters we hold (with a fingerprint of each), and which
-- characters are ours. With fresh, claims to hold nothing, so the partner sends full copies of
-- everything.
local function SendManifest(peer, set, fresh)
	local own = {}
	for key in pairs(set.spec.state.owned) do
		own[#own + 1] = key
	end
	Comms.SendDocument(peer.name, { t = "manifest", ds = set.name, have = fresh and {} or HeldFingerprints(peer, set),
		own = own })
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
			for _, name in ipairs(order) do
				Comms.SendDocument(peer.name, { t = "check", ds = name, have = HeldFingerprints(peer, datasets[name]) })
			end
		end
	end
end

local function StartSession(partnerId, name)
	local old = peers[partnerId]
	EndSession(partnerId)
	local peer = { id = partnerId, name = name, norm = Util.Norm(name), started = GetTime(), theirs = {}, manifests = {} }
	peers[partnerId] = peer
	peerIdByNorm[peer.norm] = partnerId
	deferred[partnerId] = {}
	for _, set in pairs(datasets) do
		wipe(set.asked)
		wipe(set.recheck)
	end
	db.partners[partnerId].characters[peer.norm] = name
	for _, setName in ipairs(order) do
		SendManifest(peer, datasets[setName])
	end
	if not old or old.norm ~= peer.norm then
		Util.Print("linked with " .. name)
	end
end

local function SendIntro(partnerId, target, wantReply)
	local partner = db.partners[partnerId]
	if not partner then
		return
	end
	Comms.SendControl("WHISPER", target, ("I:%s:%s:%d:%s"):format(db.accountId,
		Proof(partner.secret, MyName(), target), wantReply and 1 or 0, bootId))
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
		Comms.SendControl(channel, nil, "P:" .. db.accountId .. ":" .. bootId)
	end
end

function Link.IsTrusted(sender)
	return peerIdByNorm[Util.Norm(sender)] ~= nil
end

-- False only when the name is in our group and shown as offline.
function Link.IsReachable(target)
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

function Link.OnPeerGone(target)
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

local function Accepts(peer, set, key)
	if type(key) ~= "string" then
		return false
	end
	if key == set.spec.CurrentKey() or set.spec.state.owned[key] then
		Util.Debug(("ignored %s %s from %s: it belongs to this account"):format(set.name, key, peer.name))
		return false
	end
	return true
end

local documents = {}

-- What the partner holds of our characters decides what we send: a full copy where its copy is
-- missing or differs, nothing where it matches.
function documents.manifest(peer, set, doc)
	local state, store = set.spec.state, Store(set)
	local theirs = {}
	for _, key in ipairs(type(doc.own) == "table" and doc.own or {}) do
		if type(key) == "string" then
			theirs[key] = true
			-- They've logged in on it, so it's theirs, even if we hold a copy we took for ours.
			if not state.owned[key] and not state.mirrors[key] and key ~= set.spec.CurrentKey() and store[key] then
				state.mirrors[key] = { partner = peer.id, rev = -1 }
			end
		end
	end
	peer.theirs[set.name] = theirs
	local have = type(doc.have) == "table" and doc.have or {}
	for key, data in pairs(store) do
		if not state.mirrors[key] and not theirs[key] then
			local held = type(have[key]) == "table" and have[key] or nil
			local heldRev = held and tonumber(held.r) or 0
			if held and held.h == Util.ContentHash(data) then
				set.shadows[key] = { partner = peer.id, rev = heldRev, data = Util.Copy(data) }
				if set.dirty[key] then
					FlushSoon()
				end
			else
				QueueSnapshot(peer, set, key, heldRev)
			end
		end
	end
end

-- The partner's periodic fingerprints of its copies of our characters. Characters with changes
-- on the way, or sent recently, are left out: their copies may simply not have caught up yet.
function documents.check(peer, set, doc)
	local state = set.spec.state
	local have = type(doc.have) == "table" and doc.have or {}
	local now = GetTime()
	local waiting = deferred[peer.id] and deferred[peer.id][set.name] or {}
	local theirs = peer.theirs[set.name] or {}
	for key, data in pairs(Store(set)) do
		local shadow = set.shadows[key]
		local busy = set.dirty[key] or waiting[key] ~= nil
			or (shadow and (shadow.pending or now - (shadow.sentAt or 0) < QUIET_BEFORE_CHECK))
		if not state.mirrors[key] and not theirs[key] and not busy then
			local held = type(have[key]) == "table" and have[key] or nil
			local current = Util.ContentHash(data)
			if held and held.h == current then
				set.recheck[key] = nil
				if not shadow then
					set.shadows[key] = { partner = peer.id, rev = tonumber(held.r) or 0, data = Util.Copy(data) }
				end
			elseif set.recheck[key] == current then
				-- A full copy of exactly this data already went over and still doesn't match:
				-- something in the packing, not drift. Sending it again wouldn't help.
				Util.Debug(("%s %s still differs on %s's side after a full copy; not sending it again"):format(set.name,
					key, peer.name))
			else
				Util.Debug(("%s %s differs on %s's side; sending a full copy"):format(set.name, key, peer.name))
				set.recheck[key] = current
				QueueSnapshot(peer, set, key, held and tonumber(held.r) or (shadow and shadow.rev) or 0)
			end
		end
	end
end

function documents.snap(peer, set, doc)
	if not Accepts(peer, set, doc.key) or (set.spec.Valid and not set.spec.Valid(doc.data)) then
		return
	end
	Store(set)[doc.key] = doc.data
	set.spec.state.mirrors[doc.key] = { partner = peer.id, rev = tonumber(doc.r) or 0, updated = time() }
	set.asked[doc.key] = nil
	Mirrored(set, doc.key)
end

function documents.delta(peer, set, doc)
	if not Accepts(peer, set, doc.key) or type(doc.c) ~= "table" then
		return
	end
	local mirror = set.spec.state.mirrors[doc.key]
	local data = Store(set)[doc.key]
	if not (mirror and data and mirror.partner == peer.id and mirror.rev == doc.b) then
		-- Our copy is out of step (or was deleted): ask once for a full one.
		if not set.asked[doc.key] then
			set.asked[doc.key] = true
			Util.Debug(("copy of %s %s is out of step; asking for a full one"):format(set.name, doc.key))
			Comms.SendDocument(peer.name, { t = "need", ds = set.name, keys = { doc.key } })
		end
		return
	end
	Util.Apply(data, doc.c)
	mirror.rev = doc.r
	mirror.updated = time()
	Mirrored(set, doc.key)
end

function documents.need(peer, set, doc)
	local store, mirrors = Store(set), set.spec.state.mirrors
	for _, key in ipairs(type(doc.keys) == "table" and doc.keys or {}) do
		if type(key) == "string" and not mirrors[key] and store[key] then
			local shadow = set.shadows[key]
			QueueSnapshot(peer, set, key, shadow and shadow.rev or 0)
		end
	end
end

-- Documents for a dataset that isn't registered here are dropped, except the manifest: it's
-- kept, so the dataset can answer it if its addon registers later in the session.
function Link.OnDocument(sender, doc)
	local peer = peers[peerIdByNorm[Util.Norm(sender)] or ""]
	local handler = peer and type(doc.t) == "string" and documents[doc.t]
	if not handler or type(doc.ds) ~= "string" then
		return
	end
	peer.lastDoc = GetTime()
	if doc.t == "manifest" then
		peer.manifests[doc.ds] = doc
	end
	local set = datasets[doc.ds]
	if set then
		handler(peer, set, doc)
	end
end

---------------------------------------------------------------------------------------------
-- Pairing.

local confirm

local function Titles()
	local titles = {}
	for _, name in ipairs(order) do
		titles[#titles + 1] = datasets[name].spec.title or name
	end
	return titles
end

local function ShowPairConfirm(name, onAccept, onDecline)
	if not confirm then
		confirm = CreateFrame("Frame", "AccountLinkPairConfirm", UIParent)
		confirm:SetSize(380, 150)
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
	local titles = Titles()
	confirm.Text:SetText(("%s wants to pair your accounts, so both share data about your characters with each other%s.\n\nPair with that account?")
		:format(name, #titles > 0 and (" (" .. table.concat(titles, ", ") .. ")") or ""))
	confirm:Show()
	confirm.timer = C_Timer.NewTimer(PAIR_TIMEOUT, function()
		confirm:Hide()
	end)
end

local control = {}

-- A ping: some partner account is looking for us.
function control.P(sender, _, body)
	local partnerId, boot = body:match("^(%w+):?(%w*)$")
	if not partnerId or partnerId == db.accountId or not db.partners[partnerId] then
		return
	end
	local norm = Util.Norm(sender)
	local peer = peers[partnerId]
	local samePeer = peer and peer.norm == norm
	-- Both sides ping at login, and messages arrive out of order, so a ping can come from the
	-- very load we already have a session with, sent before it heard from us. The session
	-- stands; an introduction without a reply wanted lets their side start it too, in case
	-- ours went missing.
	local crossed = samePeer and boot ~= "" and boot == peer.boot
	if samePeer and not crossed then
		EndSession(partnerId) -- a new load of their UI (a reload, say): start over
	end
	if lastIntro[norm] and GetTime() - lastIntro[norm] < INTRO_COOLDOWN then
		return
	end
	lastIntro[norm] = GetTime()
	SendIntro(partnerId, sender, not crossed)
end

-- An introduction: the sender proves it's on a paired account, and may ask us to do the same.
function control.I(sender, channel, body)
	if channel ~= "WHISPER" then
		return
	end
	local partnerId, proof, wantReply, boot = body:match("^(%w+):([%d%.]+):(%d):?(%w*)$")
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
	peers[partnerId].boot = boot -- which load of their UI this session is with
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

function Link.OnControl(kind, body, sender, channel)
	local handler = ready and control[kind]
	if handler then
		handler(sender, channel, body)
	end
end

---------------------------------------------------------------------------------------------
-- API for other addons

function AccountLink.Register(name, spec)
	if type(name) ~= "string" or type(spec) ~= "table" or type(spec.state) ~= "table" or type(spec.Store) ~= "function"
		or type(spec.CurrentKey) ~= "function" then
		error("Usage: AccountLink.Register(name, { state = table, Store = function, CurrentKey = function, ... })", 2)
	end
	if datasets[name] then
		error("AccountLink: dataset " .. name .. " is already registered", 2)
	end
	local state = spec.state
	state.owned = state.owned or {}
	state.mirrors = state.mirrors or {}
	local current = spec.CurrentKey()
	if current then
		state.owned[current] = true
		state.mirrors[current] = nil
	end
	local set = { name = name, spec = spec, shadows = {}, dirty = {}, asked = {}, recheck = {} }
	datasets[name] = set
	order[#order + 1] = name
	-- Sessions already running learn about it now.
	for _, peer in pairs(peers) do
		SendManifest(peer, set)
		if peer.manifests[name] then
			documents.manifest(peer, set, peer.manifests[name])
		end
	end
end

function AccountLink.Changed(name, key)
	local set = datasets[name]
	if set and type(key) == "string" and not set.spec.state.mirrors[key] then
		set.dirty[key] = true
		FlushSoon()
	end
end

-- Returns true if a partner was connected to ask.
function AccountLink.Resync(name)
	local any = false
	for _, peer in pairs(peers) do
		for _, setName in ipairs(order) do
			if not name or name == setName then
				SendManifest(peer, datasets[setName], true)
			end
		end
		any = true
	end
	return any
end

-- Takes over a pairing made by an older version of an addon (SyndicatorSync before AccountLink),
-- so the accounts don't have to pair again. Only while AccountLink has no pairing of its own.
function AccountLink.Adopt(accountId, partners)
	if not db or next(db.partners) or type(accountId) ~= "string" or type(partners) ~= "table" or not next(partners) then
		return false
	end
	db.accountId = accountId
	db.partners = partners
	return true
end

function AccountLink.Pair(name)
	if not ready then
		Util.Print("still loading; try again in a moment")
		return
	end
	if not name or name == "" then
		Util.Print("usage: /alink pair <name of your other account's character>")
		return
	end
	local target = Util.CompleteName(name)
	pendingPair = { norm = Util.Norm(target), nonce = Util.RandomString(8), expires = GetTime() + PAIR_TIMEOUT }
	Comms.SendControl("WHISPER", target, ("PQ:%s:%s"):format(db.accountId, pendingPair.nonce))
	Util.Print(("asked %s to pair; accept the popup on that client"):format(target))
end

function AccountLink.Unpair()
	for partnerId in pairs(db.partners) do
		EndSession(partnerId)
	end
	wipe(db.partners)
	Util.Print("unpaired")
end

function AccountLink.ToggleDebug()
	db.debug = not db.debug
	Util.Print("details " .. (db.debug and "shown" or "hidden"))
	return db.debug
end

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
AccountLink.Age = Age

function AccountLink.PrintStatus()
	if not next(db.partners) then
		Util.Print("not paired. Group with your other account's character and type /alink pair <its name>")
	end
	for partnerId, partner in pairs(db.partners) do
		local names = {}
		for _, name in pairs(partner.characters) do
			names[#names + 1] = name
		end
		table.sort(names)
		local peer = peers[partnerId]
		Util.Print(("paired with %s; %s"):format(table.concat(names, ", "),
			peer and ("linked with " .. peer.name) or "not connected (it connects while you're grouped)"))
	end
	local lines = {}
	for _, name in ipairs(order) do
		local count = 0
		for _ in pairs(datasets[name].spec.state.mirrors) do
			count = count + 1
		end
		lines[#lines + 1] = ("%s (%d %s held)"):format(datasets[name].spec.title or name, count,
			count == 1 and "copy" or "copies")
	end
	Util.Print("shared: " .. (#lines > 0 and table.concat(lines, ", ") or "nothing yet; no addon has registered"))
	local waiting = Comms.QueueLength()
	if waiting > 0 then
		Util.Print(waiting .. " messages waiting to be sent")
	end
end

---------------------------------------------------------------------------------------------
-- Commands.

local function Help()
	Util.Print("/alink - status")
	Util.Print("/alink pair <name> - pair with your other account's character (both online, grouped)")
	Util.Print("/alink resync - ask the other account to send fresh copies of everything")
	Util.Print("/alink unpair - stop sharing with the other account")
	Util.Print("/alink debug - show or hide details of what's sent")
end

SLASH_ACCOUNTLINK1 = "/alink"
SlashCmdList.ACCOUNTLINK = function(message)
	if not ready then
		Util.Print("still loading; try again in a moment")
		return
	end
	local command, rest = message:match("^%s*(%S*)%s*(.-)%s*$")
	command = command:lower()
	if command == "" or command == "status" then
		AccountLink.PrintStatus()
	elseif command == "pair" then
		AccountLink.Pair(rest)
	elseif command == "resync" then
		Util.Print(AccountLink.Resync() and "asked for fresh copies" or "not connected to the other account right now")
	elseif command == "unpair" then
		AccountLink.Unpair()
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
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, ...)
	if event == "CHAT_MSG_ADDON" then
		if ready then
			Comms.OnMessage(...)
		end
	elseif event == "ADDON_LOADED" then
		if ... == "AccountLink" then
			InitDB() -- before the addons that depend on it load, so they can adopt an old pairing
		end
	elseif event == "PLAYER_LOGIN" then
		C_ChatInfo.RegisterAddonMessagePrefix(Util.PREFIX)
		ready = true
		C_Timer.After(3, Ping)
		C_Timer.NewTicker(PING_INTERVAL, Ping)
		C_Timer.NewTicker(CHECK_TICK, CheckPeers)
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
