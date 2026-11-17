-- Sets.lua
-- Sets of characters that play together, and which of their members are online.
--
-- A set is a few of your characters, usually on different accounts, with one of them as its
-- main. Each account keeps its own copy of the sets its characters are in, and a revision number
-- lets copies catch up when members meet. Members find each other with whispered addon messages:
-- each says hello to the others when it logs in, an answer proves the other is online, and a
-- quiet check every minute notices one that has gone.
--
-- The messages, all whispered, are kind:body with ':' between fields:
--   H:set:rev:flags      hello; flags hold p (paused), g (in a group), r (please answer)
--   S:set:rev:main:a,b   the set as the sender holds it
--   Q:set                please send me the set
--   U:set                the sender has removed the set, or doesn't know it
--   NQ:set:main:a,b      a new set: please join
--   NA:set, ND:set       joined, declined

local _, ns = ...
local Util = ns.Util

local Sets = {}
ns.Sets = Sets

local KEEPALIVE_TICK = 60 -- seconds between presence checks
local QUIET_ASK = 50 -- ask a member to answer after this long without hearing from them
local QUIET_GONE = 150 -- count a member as gone after this long
local JOIN_TIMEOUT = 60 -- seconds a new set waits for its members to join
local MAX_MEMBERS = 5 -- one party; also keeps every message well inside the size limit

local db, chardb
local online = {} -- norm -> { name, set, paused, grouped, seen } for members we've heard from
local pending -- the set we asked our group to join: { id, main, members, waiting, joined, timer }
local proposed = {} -- set id -> true while we're deciding whether to join it

Sets.online = online

function Sets.Init()
	TandemDB = TandemDB or {}
	db = TandemDB
	db.sets = db.sets or {} -- id -> { main = full name, members = { norm -> full name }, rev }
	db.features = db.features or {}
	for _, feature in ipairs({ "sound", "loot", "invite", "focus" }) do
		if db.features[feature] == nil then
			db.features[feature] = true
		end
	end
	TandemCharDB = TandemCharDB or {}
	chardb = TandemCharDB
	return db, chardb
end

---------------------------------------------------------------------------------------------
-- Looking at sets.

local function MyNorm()
	return Util.Norm(Util.MyName())
end

local function IsMember(set, name)
	return set.members[Util.Norm(name)] ~= nil
end

-- Full names, the main first and the rest in alphabetical order.
local function Names(set)
	local names = {}
	for _, name in pairs(set.members) do
		if Util.Norm(name) ~= Util.Norm(set.main) then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	table.insert(names, 1, set.main)
	return names
end

function Sets.Describe(set)
	local names = Names(set)
	names[1] = names[1] .. " (main)"
	return table.concat(names, ", ")
end

local function EncodeMembers(members)
	local names = {}
	for _, name in pairs(members) do
		names[#names + 1] = name
	end
	table.sort(names)
	return table.concat(names, ",")
end

local function DecodeMembers(list)
	local members, count = {}, 0
	for name in list:gmatch("[^,]+") do
		members[Util.Norm(name)] = name
		count = count + 1
	end
	return members, count
end

local function SameMembers(a, b)
	for norm in pairs(a) do
		if not b[norm] then
			return false
		end
	end
	for norm in pairs(b) do
		if not a[norm] then
			return false
		end
	end
	return true
end

-- The other members' full names.
function Sets.Others(set)
	local me, names = MyNorm(), {}
	for norm, name in pairs(set.members) do
		if norm ~= me then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names
end

-- The sets this character is in, as { id, set }, in a fixed order.
function Sets.Mine()
	local me, list = MyNorm(), {}
	for id, set in pairs(db.sets) do
		if set.members[me] then
			list[#list + 1] = { id = id, set = set }
		end
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

function Sets.IsMain(set)
	return Util.Norm(set.main) == MyNorm()
end

-- The set being played right now: every member online and none paused. With several, the
-- biggest wins.
function Sets.Active()
	if chardb.paused then
		return
	end
	local bestId, best, bestSize
	for _, entry in ipairs(Sets.Mine()) do
		local others = Sets.Others(entry.set)
		local all = true
		for _, name in ipairs(others) do
			local o = online[Util.Norm(name)]
			if not o or o.paused then
				all = false
				break
			end
		end
		if all and (not best or #others > bestSize) then
			bestId, best, bestSize = entry.id, entry.set, #others
		end
	end
	return bestId, best
end

-- True if one set holds this character and every name in norms.
function Sets.AllShareASet(norms)
	for _, entry in ipairs(Sets.Mine()) do
		local all = true
		for _, norm in ipairs(norms) do
			if not entry.set.members[norm] then
				all = false
				break
			end
		end
		if all then
			return true
		end
	end
	return false
end

-- True if this character is the main of a set that holds norm.
function Sets.IsMainWith(norm)
	for _, entry in ipairs(Sets.Mine()) do
		if entry.set.members[norm] and Sets.IsMain(entry.set) then
			return true
		end
	end
	return false
end

-- A set to act on for /tandem main and /tandem unset: the one being played, else the only one.
local function ChooseSet()
	local id, set = Sets.Active()
	if id then
		return id, set
	end
	local mine = Sets.Mine()
	if #mine == 1 then
		return mine[1].id, mine[1].set
	elseif #mine == 0 then
		Util.Print("this character isn't in a set.")
	else
		Util.Print("this character is in several sets. Log in the other members of the one you mean first.")
	end
end

---------------------------------------------------------------------------------------------
-- Talking to members.

local function Hello(id, set, target, wantReply)
	local flags = (chardb.paused and "p" or "") .. (IsInGroup() and "g" or "") .. (wantReply and "r" or "")
	Util.Whisper(target, ("H:%s:%d:%s"):format(id, set.rev, flags))
end

local function SendSet(id, set, target)
	Util.Whisper(target, ("S:%s:%d:%s:%s"):format(id, set.rev, set.main, EncodeMembers(set.members)))
end

-- Says hello to every other member of every set this character is in. Offline ones get a
-- whisper that fails quietly.
function Sets.AnnounceAll()
	for _, entry in ipairs(Sets.Mine()) do
		for _, name in ipairs(Sets.Others(entry.set)) do
			Hello(entry.id, entry.set, name, true)
		end
	end
end

function Sets.OnGone(target)
	local norm = Util.Norm(target)
	if pending and pending.waiting[norm] then
		Sets.CancelCreate(target .. " isn't online")
	end
	if online[norm] then
		online[norm] = nil
		Util.Debug(target .. " has gone")
		ns.Changed()
	end
end

local function Keepalive()
	local now, changed = GetTime(), false
	for norm, entry in pairs(online) do
		local set = db.sets[entry.set]
		if now - entry.seen > QUIET_GONE or not set then
			online[norm] = nil
			changed = true
		elseif now - entry.seen > QUIET_ASK then
			Hello(entry.set, set, entry.name, true)
		end
	end
	if changed then
		ns.Changed()
	end
end

function Sets.Start()
	C_Timer.After(2, Sets.AnnounceAll)
	C_Timer.NewTicker(KEEPALIVE_TICK, Keepalive)
end

---------------------------------------------------------------------------------------------
-- Making, changing and removing sets.

local function FinishCreate()
	local p = pending
	pending = nil
	p.timer:Cancel()
	db.sets[p.id] = { main = p.main, members = p.members, rev = 1 }
	Util.Print("made the set " .. Sets.Describe(db.sets[p.id]) .. ".")
	for _, name in ipairs(Sets.Others(db.sets[p.id])) do
		Hello(p.id, db.sets[p.id], name, true)
	end
	ns.Changed()
end

function Sets.CancelCreate(reason)
	local p = pending
	if not p then
		return
	end
	pending = nil
	p.timer:Cancel()
	for _, name in pairs(p.joined) do
		Util.Whisper(name, "U:" .. p.id)
	end
	Util.Print("no set made: " .. reason .. ".")
end

function Sets.Create()
	if pending then
		Util.Print("still waiting for answers about the last set.")
		return
	end
	if not IsInGroup() then
		Util.Print("group up with the characters you want in the set, then try again.")
		return
	end
	local others, complete = Util.GroupMembers()
	if not complete or #others == 0 then
		Util.Print("couldn't read every name in the group. Try again in a moment.")
		return
	end
	if #others + 1 > MAX_MEMBERS then
		Util.Print(("a set can have at most %d characters."):format(MAX_MEMBERS))
		return
	end
	local me = Util.MyName()
	local members = { [Util.Norm(me)] = me }
	for _, m in ipairs(others) do
		members[m.norm] = m.name
	end
	for _, set in pairs(db.sets) do
		if SameMembers(set.members, members) then
			Util.Print("these characters are already a set: " .. Sets.Describe(set)
				.. ". /tandem main on another of them makes it the main.")
			return
		end
	end
	local id = Util.RandomString(8)
	pending = { id = id, main = me, members = members, waiting = {}, joined = {} }
	local list, names = EncodeMembers(members), {}
	for _, m in ipairs(others) do
		pending.waiting[m.norm] = m.name
		names[#names + 1] = m.name
		Util.Whisper(m.name, ("NQ:%s:%s:%s"):format(id, me, list))
	end
	pending.timer = C_Timer.NewTimer(JOIN_TIMEOUT, function()
		local silent = {}
		for _, name in pairs(pending.waiting) do
			silent[#silent + 1] = name
		end
		Sets.CancelCreate("no answer from " .. table.concat(silent, ", ") .. " (is Tandem installed there?)")
	end)
	Util.Print("asked " .. table.concat(names, ", ") .. " to join a set with you as its main.")
end

function Sets.MakeMain()
	local id, set = ChooseSet()
	if not id then
		return
	end
	if Sets.IsMain(set) then
		Util.Print("this character is already the main of " .. Sets.Describe(set) .. ".")
		return
	end
	set.main = Util.MyName()
	set.rev = set.rev + 1
	-- Members who are offline catch up the next time they say hello.
	for _, name in ipairs(Sets.Others(set)) do
		if online[Util.Norm(name)] then
			SendSet(id, set, name)
		end
	end
	Util.Print("the set is now " .. Sets.Describe(set) .. ".")
	ns.Changed()
end

function Sets.Remove()
	local id, set = ChooseSet()
	if not id then
		return
	end
	db.sets[id] = nil
	-- Members who are offline hear of it the next time they say hello to us.
	for _, name in ipairs(Sets.Others(set)) do
		if online[Util.Norm(name)] then
			Util.Whisper(name, "U:" .. id)
		end
	end
	Util.Print("removed the set " .. Sets.Describe(set) .. ".")
	ns.Changed()
end

function Sets.IsCreating()
	return pending ~= nil
end

---------------------------------------------------------------------------------------------
-- Receiving.

local handlers = {}

function handlers.H(sender, body)
	local id, rev, flags = body:match("^(%w+):(%d+):(%a*)$")
	if not id then
		return
	end
	local set = db.sets[id]
	if not set then
		-- A set we removed, or one still being made: only the first gets an answer.
		if not (pending and pending.id == id) and not proposed[id] then
			Util.Whisper(sender, "U:" .. id)
		end
		return
	end
	if not IsMember(set, sender) then
		return
	end
	local norm = Util.Norm(sender)
	local entry = online[norm]
	local arrived = entry == nil
	entry = entry or {}
	online[norm] = entry
	entry.name, entry.set, entry.seen = sender, id, GetTime()
	entry.paused = flags:find("p", 1, true) ~= nil
	entry.grouped = flags:find("g", 1, true) ~= nil
	rev = tonumber(rev)
	if rev > set.rev then
		Util.Whisper(sender, "Q:" .. id)
	elseif rev < set.rev then
		SendSet(id, set, sender)
	end
	if flags:find("r", 1, true) then
		Hello(id, set, sender, false)
	end
	if arrived then
		Util.Debug(sender .. " is online")
		ns.Arrived(norm)
	end
	ns.Changed()
end

function handlers.S(sender, body)
	local id, rev, main, list = body:match("^(%w+):(%d+):([^:]+):(.+)$")
	local set = id and db.sets[id]
	if not set or not IsMember(set, sender) or tonumber(rev) <= set.rev then
		return
	end
	local members = DecodeMembers(list)
	if not members[Util.Norm(main)] then
		return
	end
	if not members[MyNorm()] then
		db.sets[id] = nil
		Util.Print(sender .. " took this character out of the set " .. Sets.Describe(set) .. ".")
	else
		local newMain = Util.Norm(main) ~= Util.Norm(set.main)
		set.main, set.members, set.rev = main, members, tonumber(rev)
		if newMain then
			Util.Print("the set is now " .. Sets.Describe(set) .. ".")
		end
	end
	ns.Changed()
end

function handlers.Q(sender, body)
	local set = db.sets[body]
	if set and IsMember(set, sender) then
		SendSet(body, set, sender)
	end
end

function handlers.U(sender, body)
	local set = db.sets[body]
	if set and IsMember(set, sender) then
		db.sets[body] = nil
		Util.Print(sender .. " removed the set " .. Sets.Describe(set) .. ".")
		ns.Changed()
	end
end

-- An invitation to a new set. Only from someone in our group, so strangers can't put popups up.
function handlers.NQ(sender, body)
	local id, main, list = body:match("^(%w+):([^:]+):(.+)$")
	if not id or db.sets[id] or proposed[id] or not Util.UnitOf(Util.Norm(sender)) then
		return
	end
	local members, count = DecodeMembers(list)
	if count > MAX_MEMBERS or Util.Norm(main) ~= Util.Norm(sender) or not members[MyNorm()] then
		return
	end
	proposed[id] = true
	local set = { main = main, members = members, rev = 1 }
	local text = ("%s wants to make a Tandem set:\n\n%s\n\nThe main invites the others and keeps its sound. "
		.. "The others turn their sound off while the main is online, accept its invites, and get a "
		.. "reminder to focus it.\n\nJoin this set?"):format(sender, Sets.Describe(set))
	Util.Confirm(text, "Join", JOIN_TIMEOUT - 5, function()
		proposed[id] = nil
		db.sets[id] = set
		Util.Whisper(sender, "NA:" .. id)
		Util.Print("joined the set " .. Sets.Describe(set) .. ".")
	end, function()
		proposed[id] = nil
		Util.Whisper(sender, "ND:" .. id)
	end)
end

function handlers.NA(sender, body)
	local norm = Util.Norm(sender)
	if not (pending and pending.id == body and pending.waiting[norm]) then
		return
	end
	pending.waiting[norm] = nil
	pending.joined[norm] = sender
	if next(pending.waiting) == nil then
		FinishCreate()
	end
end

function handlers.ND(sender, body)
	if pending and pending.id == body and pending.waiting[Util.Norm(sender)] then
		Sets.CancelCreate(sender .. " said no")
	end
end

function Sets.OnMessage(prefix, text, channel, sender)
	if Util.IsHidden(prefix) or Util.IsHidden(text) or Util.IsHidden(channel) or Util.IsHidden(sender) then
		return
	end
	if prefix ~= Util.PREFIX or channel ~= "WHISPER" then
		return
	end
	local kind, body = text:match("^(%u+):(.*)$")
	local handler = kind and handlers[kind]
	if handler then
		Util.Debug("from " .. sender .. ": " .. text)
		handler(sender, body)
	end
end
