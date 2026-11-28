-- Comms.lua
-- Reliable transfers over hidden addon whispers. On Forever, addon messages arrive heavily out
-- of order and some get lost (measured with the SyncProbe test addon), so every transfer is
-- numbered, rebuilt by number, checked against a checksum and acknowledged, and the receiver asks
-- again for gaps. Only one transfer per peer is in flight at a time, so documents arrive in the
-- order they were sent.
--
-- Messages (after the prefix):
--   S:tid:sum:data      a whole transfer in one message
--   H:tid:n:sum         header of a transfer in n chunks
--   C:tid:i:n:data      chunk i of n
--   E:tid               end of the chunks; also "how is it going?" when the sender polls
--   A:tid               received intact
--   R:tid:list          send these again: chunk numbers, 0 for the header, * for everything
-- Anything else is a control message for Link (pings, introductions, pairing).

local _, ns = ...
local Util = ns.Util

local Comms = {}
ns.Comms = Comms

local PREFIX = Util.PREFIX
local CHUNK_SIZE = 220 -- data characters per chunk; a message holds at most 255
local RATE, BURST = 2000, 4000 -- bytes per second, and how much may go out at once
local MESSAGE_OVERHEAD = 40 -- rough cost of a message beyond its text, as ChatThrottleLib counts it
local THROTTLE_RETRY = 0.3 -- seconds to wait when the game holds messages back
local LOCKDOWN_RETRY = 5 -- seconds to wait when chat lockdown blocks sending
local ACK_TIMEOUT = 6 -- seconds after the last message left before polling the receiver
local MAX_POLLS = 10 -- unanswered polls before the peer counts as gone
local MAX_RESEND_ROUNDS = 10
local END_GRACE = 1.5 -- receiver: seconds to wait for stragglers after the end marker
local QUIET_TIMEOUT = 10 -- receiver: seconds without news before asking for gaps
local PARTIAL_LIFETIME = 120 -- receiver: seconds before an abandoned transfer is dropped
local DONE_LIFETIME = 600 -- receiver: seconds to remember finished transfers, to answer repeats
local MAX_LIST = 40 -- chunk numbers per resend request

local result = Enum.SendAddonMessageResult or {}
local SUCCESS = result.Success or 0
local THROTTLED = { [result.AddonMessageThrottle or 3] = true, [result.ChannelThrottle or 8] = true }
local LOCKDOWN = result.AddOnMessageLockdown or 11
local OFFLINE = result.TargetOffline or 12

local function RestartTimer(record, seconds, callback)
	if record.timer then
		record.timer:Cancel()
	end
	record.timer = C_Timer.NewTimer(seconds, callback)
end

local function StopTimer(record)
	if record.timer then
		record.timer:Cancel()
		record.timer = nil
	end
end

---------------------------------------------------------------------------------------------
-- Sending: two queues (control first), paced like ChatThrottleLib, retrying when the game
-- holds messages back or chat lockdown blocks them.

local queues = { control = {}, data = {} }
local retryAt = 0
local allowance, allowanceTime = BURST, 0
local recentWhispers = {} -- target -> time of the last whisper, to spot "no player named" errors

local function TrySend(item)
	local ok, code = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, item.channel, item.target)
	if not ok then
		Util.Debug("send error: " .. tostring(code))
		return "error"
	elseif code == nil or code == true or code == SUCCESS then
		return "sent"
	elseif THROTTLED[code] then
		return "throttled"
	elseif code == LOCKDOWN then
		return "lockdown"
	elseif code == OFFLINE then
		return "offline"
	end
	Util.Debug("send refused: " .. tostring(code))
	return "error"
end

local pump = CreateFrame("Frame")
pump:Hide()
pump:SetScript("OnUpdate", function(self)
	local now = GetTime()
	if now < retryAt then
		return
	end
	allowance = math.min(BURST, allowance + (now - allowanceTime) * RATE)
	allowanceTime = now
	while true do
		local queue = queues.control[1] and queues.control or queues.data
		local item = queue[1]
		if not item then
			break
		end
		local size = #item.text + #PREFIX + MESSAGE_OVERHEAD
		if allowance < size then
			return
		end
		local status = TrySend(item)
		if status == "throttled" then
			retryAt = now + THROTTLE_RETRY
			return
		elseif status == "lockdown" then
			retryAt = now + LOCKDOWN_RETRY
			return
		end
		table.remove(queue, 1)
		allowance = allowance - size
		if status == "offline" then
			if item.target then
				ns.Link.OnPeerGone(item.target)
			end
		else
			if item.channel == "WHISPER" then
				recentWhispers[item.target] = now
			end
			if status == "sent" and item.onSent then
				item.onSent()
			end
		end
	end
	self:Hide()
end)

-- transfer tags a message as part of an outgoing transfer, so it can be dropped once that
-- transfer is confirmed.
local function Enqueue(kind, channel, target, text, onSent, transfer)
	table.insert(queues[kind], { channel = channel, target = target, text = text, onSent = onSent, transfer = transfer })
	pump:Show()
end

function Comms.SendControl(channel, target, text)
	Enqueue("control", channel, target, text)
end

function Comms.QueueLength()
	return #queues.control + #queues.data
end

---------------------------------------------------------------------------------------------
-- Outgoing transfers, one in flight per peer.

local outgoing = {} -- normalized name -> { target, pending = { docs }, current = transfer }
local usedIds = {}

local function NewTransferId()
	local id
	repeat
		id = math.random(100000, 999999)
	until not usedIds[id]
	usedIds[id] = true
	return id
end

local StartNext

local function GiveUp(peer)
	Util.Debug("no answer from " .. peer.target .. "; ending the session")
	ns.Link.OnPeerGone(peer.target)
end

-- Asks the receiver how the current transfer is going: the whole message again for a
-- single-message transfer, the end marker otherwise.
local function Poll(peer)
	local transfer = peer.current
	if not transfer then
		return
	end
	transfer.polls = transfer.polls + 1
	if transfer.polls > MAX_POLLS or not ns.Link.IsReachable(peer.target) then
		GiveUp(peer)
		return
	end
	local text = transfer.single and transfer.texts[1] or ("E:" .. transfer.id)
	Enqueue("control", "WHISPER", peer.target, text)
	RestartTimer(transfer, ACK_TIMEOUT, function()
		Poll(peer)
	end)
end

-- Starts the wait for the receiver's answer once a transfer's last message has left. Resent
-- messages can still be queued when the receiver confirms (the originals were only late), so
-- this does nothing for a transfer that's already finished.
local function WaitForAnswer(peer, transfer)
	if peer.current ~= transfer then
		return
	end
	RestartTimer(transfer, ACK_TIMEOUT, function()
		Poll(peer)
	end)
end

local function SendPart(peer, transfer, text, isLast)
	Enqueue("data", "WHISPER", peer.target, text, isLast and function()
		WaitForAnswer(peer, transfer)
	end or nil, transfer)
end

function StartNext(peer)
	if peer.current or not peer.pending[1] then
		return
	end
	local doc = table.remove(peer.pending, 1)
	local id = NewTransferId()
	local sum = Util.Hash(doc.encoded)
	local transfer = { id = id, texts = {}, polls = 0, rounds = 0, onDone = doc.onDone }
	peer.current = transfer

	local single = ("S:%d:%s:%s"):format(id, sum, doc.encoded)
	if #single <= 250 then
		transfer.single = true
		transfer.texts[1] = single
		SendPart(peer, transfer, single, true)
		return
	end

	local count = math.ceil(#doc.encoded / CHUNK_SIZE)
	transfer.count = count
	transfer.texts[0] = ("H:%d:%d:%s"):format(id, count, sum)
	for i = 1, count do
		transfer.texts[i] = ("C:%d:%d:%d:%s"):format(id, i, count,
			doc.encoded:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE))
	end
	for i = 0, count do
		SendPart(peer, transfer, transfer.texts[i])
	end
	SendPart(peer, transfer, "E:" .. id, true)
end

-- Packs a table and sends it to target; onDone runs once the other side has it intact.
function Comms.SendDocument(target, doc, onDone)
	local encoded = Util.Pack(doc)
	if not encoded then
		Util.Debug("couldn't pack a " .. tostring(doc.t))
		return false
	end
	local norm = Util.Norm(target)
	local peer = outgoing[norm]
	if not peer then
		peer = { target = target, pending = {} }
		outgoing[norm] = peer
	end
	table.insert(peer.pending, { encoded = encoded, onDone = onDone })
	StartNext(peer)
	return true
end

local function OnAck(norm, id)
	local peer = outgoing[norm]
	local transfer = peer and peer.current
	if not transfer or transfer.id ~= id then
		return
	end
	StopTimer(transfer)
	peer.current = nil
	-- Resent pieces still waiting to go out aren't needed any more.
	local queue = queues.data
	for i = #queue, 1, -1 do
		if queue[i].transfer == transfer then
			table.remove(queue, i)
		end
	end
	if transfer.onDone then
		transfer.onDone()
	end
	StartNext(peer)
end

local function OnResend(norm, id, list)
	local peer = outgoing[norm]
	local transfer = peer and peer.current
	if not transfer or transfer.id ~= id then
		return
	end
	transfer.rounds = transfer.rounds + 1
	if transfer.rounds > MAX_RESEND_ROUNDS then
		GiveUp(peer)
		return
	end
	transfer.polls = 0
	StopTimer(transfer)
	if transfer.single then
		SendPart(peer, transfer, transfer.texts[1], true)
		return
	end
	if list == "*" then
		for i = 0, transfer.count do
			SendPart(peer, transfer, transfer.texts[i])
		end
	else
		for index in list:gmatch("%d+") do
			local text = transfer.texts[tonumber(index)]
			if text then
				SendPart(peer, transfer, text)
			end
		end
	end
	SendPart(peer, transfer, "E:" .. id, true)
end

---------------------------------------------------------------------------------------------
-- Incoming transfers, rebuilt by number whatever order the pieces arrive in.

local incoming = {} -- norm .. ":" .. id -> transfer being rebuilt
local done = {} -- norm .. ":" .. id -> time it finished, to answer repeats

local function Forget(key)
	local transfer = incoming[key]
	if transfer then
		StopTimer(transfer)
		incoming[key] = nil
	end
end

local function Deliver(transfer, encoded)
	local key = transfer.key
	Forget(key)
	local now = GetTime()
	done[key] = now
	for oldKey, time in pairs(done) do
		if now - time > DONE_LIFETIME then
			done[oldKey] = nil
		end
	end
	Comms.SendControl("WHISPER", transfer.sender, "A:" .. transfer.id)
	local doc = Util.Unpack(encoded)
	if doc then
		ns.Link.OnDocument(transfer.sender, doc)
	else
		Util.Debug("couldn't unpack a transfer from " .. transfer.sender)
	end
end

local function RequestMissing(key)
	local transfer = incoming[key]
	if not transfer then
		return
	end
	if GetTime() - transfer.started > PARTIAL_LIFETIME then
		Forget(key)
		return
	end
	local missing = {}
	if not transfer.count then
		missing[1] = "*"
	else
		if not transfer.sum then
			missing[1] = 0
		end
		for i = 1, transfer.count do
			if not transfer.chunks[i] and #missing < MAX_LIST then
				missing[#missing + 1] = i
			end
		end
	end
	Comms.SendControl("WHISPER", transfer.sender, ("R:%d:%s"):format(transfer.id, table.concat(missing, ",")))
	RestartTimer(transfer, QUIET_TIMEOUT, function()
		RequestMissing(key)
	end)
end

local function CheckComplete(transfer)
	if not (transfer.sum and transfer.count and transfer.got == transfer.count) then
		return false
	end
	local encoded = table.concat(transfer.chunks, "", 1, transfer.count)
	if Util.Hash(encoded) ~= transfer.sum then
		-- Arrived changed somehow: start this transfer over.
		Util.Debug("checksum mismatch from " .. transfer.sender .. "; asking for it again")
		transfer.chunks, transfer.got, transfer.count, transfer.sum = {}, 0, nil, nil
		RequestMissing(transfer.key)
		return true
	end
	Deliver(transfer, encoded)
	return true
end

local function GetIncoming(sender, norm, id)
	local key = norm .. ":" .. id
	if done[key] then
		return nil, key
	end
	local transfer = incoming[key]
	if not transfer then
		transfer = { key = key, id = id, sender = sender, chunks = {}, got = 0, started = GetTime() }
		incoming[key] = transfer
	end
	transfer.sender = sender
	return transfer, key
end

local function WaitForMore(transfer, seconds)
	RestartTimer(transfer, seconds, function()
		RequestMissing(transfer.key)
	end)
end

local handlers = {}

function handlers.S(sender, norm, body)
	local id, sum, data = body:match("^(%d+):([%d%.]+):(.+)$")
	id = tonumber(id)
	if not id then
		return
	end
	local transfer, key = GetIncoming(sender, norm, id)
	if not transfer then
		Comms.SendControl("WHISPER", sender, "A:" .. id) -- a repeat: the acknowledgement got lost
		return
	end
	if Util.Hash(data) == sum then
		Deliver(transfer, data)
	else
		Forget(key) -- the sender polls with the whole message again
	end
end

function handlers.H(sender, norm, body)
	local id, count, sum = body:match("^(%d+):(%d+):([%d%.]+)$")
	id = tonumber(id)
	local transfer = id and GetIncoming(sender, norm, id)
	if not transfer then
		return
	end
	transfer.count, transfer.sum = tonumber(count), sum
	if not CheckComplete(transfer) then
		WaitForMore(transfer, transfer.ended and END_GRACE or QUIET_TIMEOUT)
	end
end

function handlers.C(sender, norm, body)
	local id, index, count, data = body:match("^(%d+):(%d+):(%d+):(.+)$")
	id, index, count = tonumber(id), tonumber(index), tonumber(count)
	local transfer = id and GetIncoming(sender, norm, id)
	if not transfer or index < 1 or index > count then
		return
	end
	transfer.count = transfer.count or count
	if not transfer.chunks[index] then
		transfer.chunks[index] = data
		transfer.got = transfer.got + 1
	end
	if not CheckComplete(transfer) then
		WaitForMore(transfer, transfer.ended and END_GRACE or QUIET_TIMEOUT)
	end
end

function handlers.E(sender, norm, body)
	local id = tonumber(body)
	if not id then
		return
	end
	local key = norm .. ":" .. id
	if done[key] then
		Comms.SendControl("WHISPER", sender, "A:" .. id)
		return
	end
	local transfer = incoming[key]
	if not transfer then
		Comms.SendControl("WHISPER", sender, ("R:%d:*"):format(id)) -- nothing of it arrived
		return
	end
	-- Gaps at the end marker are often just messages still on the way.
	transfer.ended = true
	WaitForMore(transfer, END_GRACE)
end

function handlers.A(_, norm, body)
	local id = tonumber(body)
	if id then
		OnAck(norm, id)
	end
end

function handlers.R(_, norm, body)
	local id, list = body:match("^(%d+):([%d,%*]+)$")
	if id then
		OnResend(norm, tonumber(id), list)
	end
end

---------------------------------------------------------------------------------------------

-- Drops everything queued for or arriving from a peer, when its session ends or restarts.
function Comms.Forget(target)
	local norm = Util.Norm(target)
	for _, queue in pairs(queues) do
		for i = #queue, 1, -1 do
			if queue[i].target and Util.Norm(queue[i].target) == norm then
				table.remove(queue, i)
			end
		end
	end
	local peer = outgoing[norm]
	if peer then
		if peer.current then
			StopTimer(peer.current)
		end
		outgoing[norm] = nil
	end
	for key, transfer in pairs(incoming) do
		if Util.Norm(transfer.sender) == norm then
			Forget(key)
		end
	end
end

-- True while anything is queued for, in flight to, or arriving from a peer.
function Comms.IsBusy(target)
	local norm = Util.Norm(target)
	for _, queue in pairs(queues) do
		for _, item in ipairs(queue) do
			if item.target and Util.Norm(item.target) == norm then
				return true
			end
		end
	end
	local peer = outgoing[norm]
	if peer and (peer.current or peer.pending[1]) then
		return true
	end
	for _, transfer in pairs(incoming) do
		if Util.Norm(transfer.sender) == norm then
			return true
		end
	end
	return false
end

function Comms.OnMessage(prefix, text, channel, sender)
	if Util.IsHidden(prefix) or Util.IsHidden(text) or Util.IsHidden(channel) or Util.IsHidden(sender) then
		return
	end
	if prefix ~= PREFIX then
		return
	end
	local kind, body = text:match("^(%u+):(.*)$")
	if not kind then
		return
	end
	local handler = handlers[kind]
	if handler then
		-- Transfers only count from the peer of an active session.
		if channel == "WHISPER" and ns.Link.IsTrusted(sender) then
			handler(sender, Util.Norm(sender), body)
		end
	else
		ns.Link.OnControl(kind, body, sender, channel)
	end
end

-- Whispering a player who just logged out prints "No player named ... is currently playing."
-- Hide that for names we whispered a moment ago, and take it as the peer having left.
local function FilterNotFound(_, _, message)
	if Util.IsHidden(message) or type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then
		return false
	end
	local now = GetTime()
	for target, time in pairs(recentWhispers) do
		if now - time < 10 and message == ERR_CHAT_PLAYER_NOT_FOUND_S:format(target) then
			C_Timer.After(0, function()
				ns.Link.OnPeerGone(target)
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
