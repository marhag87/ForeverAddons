-- Two-client mock for SyndicatorSync (and AccountLink once SyndicatorSync depends on it): each
-- client loads the addons from their .toc files into its own environment, and a simulated
-- network carries addon messages between them with latency, reordering and, in one part, loss.
-- Checks pairing, the first full copies, change lists, a reload, instance deferral and pairing
-- from scratch. Asserts (PASS/FAIL).
--
-- Run: lua-language-server.exe link_sync_test.lua ../SyndicatorSync
local addonDir = ...
local ROOT = addonDir:match("^(.*)[/\\][^/\\]+$") or "."

math.randomseed(7)

---------------------------------------------------------------------------------------------
-- Clock, timers and the network

local clock = 0
local timers = {}

local function Schedule(seconds, fn, interval)
  local t = { at = clock + seconds, fn = fn, interval = interval }
  function t.Cancel(self) self.cancelled = true end
  timers[#timers + 1] = t
  return t
end

local function RunTimers()
  while true do
    local best, bestIndex
    for i, t in ipairs(timers) do
      if not t.cancelled and t.at <= clock and (not best or t.at < best.at) then
        best, bestIndex = t, i
      end
    end
    if not best then
      break
    end
    if best.interval then
      best.at = best.at + best.interval
    else
      table.remove(timers, bestIndex)
    end
    best.fn(best)
  end
  for i = #timers, 1, -1 do
    if timers[i].cancelled then table.remove(timers, i) end
  end
end

local C_Timer = {
  After = function(seconds, fn) Schedule(seconds, fn) end,
  NewTimer = function(seconds, fn) return Schedule(seconds, fn) end,
  NewTicker = function(seconds, fn) return Schedule(seconds, fn, seconds) end,
}

local net = { drop = 0, minLatency = 0.05, maxLatency = 0.4, sent = 0, dropped = 0 }
local inflight = {}
local clients = {} -- name -> client
local group = {} -- list of client names in the one group

---------------------------------------------------------------------------------------------
-- The game's encoding tools, as plain Lua literals

local function Serialize(v)
  local tv = type(v)
  if tv == "table" then
    local parts = {}
    for k, x in pairs(v) do
      local key
      if type(k) == "string" then key = ("[%q]"):format(k)
      elseif math.type(k) == "integer" then key = "[" .. k .. "]"
      elseif type(k) == "number" then key = ("[%.17g]"):format(k)
      elseif type(k) == "boolean" then key = "[" .. tostring(k) .. "]"
      else error("can't serialize key " .. tostring(k)) end
      parts[#parts + 1] = key .. "=" .. Serialize(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif tv == "string" then
    return ("%q"):format(v)
  elseif tv == "number" then
    return math.type(v) == "integer" and tostring(v) or ("%.17g"):format(v)
  elseif tv == "boolean" then
    return tostring(v)
  end
  error("can't serialize " .. tv)
end

local C_EncodingUtil = {
  SerializeCBOR = Serialize,
  DeserializeCBOR = function(s) return assert(load("return " .. s, "=cbor", "t", {}))() end,
  CompressString = function(s) return s end,
  DecompressString = function(s) return s end,
  EncodeBase64 = function(s) return s end,
  DecodeBase64 = function(s) return s end,
}

---------------------------------------------------------------------------------------------
-- Helpers

local function Copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = Copy(x) end
  return c
end

local function Equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not Equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function ReadToc(name)
  local f = io.open(ROOT .. "/" .. name .. "/" .. name .. ".toc", "r")
  if not f then return nil end
  local toc = { name = name, files = {}, deps = {}, saved = {} }
  for raw in f:lines() do
    local line = raw:gsub("\r$", "")
    local deps = line:match("^##%s*Dependencies:%s*(.+)$")
    local saved = line:match("^##%s*SavedVariables:%s*(.+)$")
    if deps then
      for dep in deps:gmatch("[^,%s]+") do toc.deps[#toc.deps + 1] = dep end
    elseif saved then
      for var in saved:gmatch("[^,%s]+") do toc.saved[#toc.saved + 1] = var end
    elseif line ~= "" and not line:match("^#") then
      toc.files[#toc.files + 1] = (line:gsub("\\", "/"))
    end
  end
  f:close()
  return toc
end

-- The addons to load, dependencies first. Dependencies outside the repo (Syndicator) are mocked.
local ADDONS = {}
do
  local seen = {}
  local function Add(name)
    if seen[name] then return end
    seen[name] = true
    local toc = ReadToc(name)
    if not toc then return end
    for _, dep in ipairs(toc.deps) do Add(dep) end
    ADDONS[#ADDONS + 1] = toc
  end
  Add(addonDir:match("([^/\\]+)$"))
end
local HAS_LINK = false
for _, toc in ipairs(ADDONS) do
  if toc.name == "AccountLink" then HAS_LINK = true end
end

local function Character(first, surname, seed)
  local bags = {}
  for bag = 0, 4 do
    local slots = {}
    for slot = 1, 16 do
      local id = 2000 + seed * 100 + bag * 16 + slot
      slots[slot] = { itemID = id, itemCount = (slot % 5) + 1, quality = slot % 4,
        itemLink = ("|cff1eff00|Hitem:%d::::::::60:::::|h[Item %d]|h|r"):format(id, id) }
    end
    bags[bag + 1] = slots
  end
  return { details = { character = first .. " " .. surname, realm = "Camelot", class = seed }, bags = bags,
    bank = { { { itemID = 1, itemCount = 1 } } }, money = 1000 * seed }
end

---------------------------------------------------------------------------------------------
-- A client: one game with the addons loaded

local Client = {}
Client.__index = Client

local function NewFrame(client, name)
  local f = { scripts = {}, events = {}, shown = true, name = name }
  setmetatable(f, { __index = function(_, method)
    if method == "SetScript" then return function(self, s, fn) self.scripts[s] = fn end end
    if method == "GetScript" then return function(self, s) return self.scripts[s] end end
    if method == "RegisterEvent" then return function(self, e) self.events[e] = true end end
    if method == "UnregisterEvent" then return function(self, e) self.events[e] = nil end end
    if method == "Show" then return function(self) self.shown = true end end
    if method == "Hide" then
      return function(self)
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
      end
    end
    if method == "IsShown" then return function(self) return self.shown end end
    if method == "GetName" then return function(self) return self.name end end
    if method == "CreateFontString" or method == "CreateTexture" then
      return function() return NewFrame(client) end
    end
    return function() end
  end })
  client.frames[#client.frames + 1] = f
  if name then client.env[name] = f end
  return f
end

function Client:Fire(event, ...)
  for _, f in ipairs(self.frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end

function Client:Others()
  local others = {}
  local inGroup = false
  for _, name in ipairs(group) do if name == self.name then inGroup = true end end
  if not inGroup then return others end
  for _, name in ipairs(group) do
    if name ~= self.name then others[#others + 1] = clients[name] end
  end
  return others
end

function Client:Data()
  return self.env.SYNDICATOR_DATA.Characters
end

function Client:Own()
  return self:Data()[self.key]
end

function Client:Trigger(event, key)
  self.env.Syndicator.CallbackRegistry:TriggerEvent(event, key)
end

function Client:Slash(command, text)
  self.env.SlashCmdList[command](text)
end

local function Norm(name)
  return (name:gsub("%-[^%-]*$", "")):lower()
end

function Client:Load()
  local client = self
  self.frames = {}
  self.log = {}
  self.triggered = {}
  local first, surname = self.name:match("^(%S+) (%S+)$")
  local env
  env = setmetatable({
    Enum = {},
    C_Timer = C_Timer,
    C_EncodingUtil = C_EncodingUtil,
    C_ChatInfo = {
      RegisterAddonMessagePrefix = function() return true end,
      SendAddonMessage = function(prefix, text, channel, target)
        assert(#text <= 255, "addon message over 255 characters: " .. #text)
        local to = {}
        if channel == "WHISPER" then
          local other = clients[target] or nil
          for _, c in pairs(clients) do
            if Norm(c.name) == Norm(target) then other = c end
          end
          if other and other.online then to[1] = other end
        elseif channel == "PARTY" then
          to = client:Others()
        end
        for _, other in ipairs(to) do
          net.sent = net.sent + 1
          if math.random() < net.drop then
            net.dropped = net.dropped + 1
          else
            inflight[#inflight + 1] = { at = clock + net.minLatency + math.random() * (net.maxLatency - net.minLatency),
              to = other.name, prefix = prefix, text = text, channel = channel, sender = client.name }
          end
        end
        return 0
      end,
    },
    CreateFrame = function(_, name) return NewFrame(client, name) end,
    UIParent = {},
    UISpecialFrames = {},
    ChatFrame_AddMessageEventFilter = function() end,
    GetTime = function() return clock end,
    time = function() return 1800000000 + math.floor(clock) end,
    IsInGroup = function(category)
      if category == 2 then return false end
      return #client:Others() > 0
    end,
    LE_PARTY_CATEGORY_INSTANCE = 2,
    IsInInstance = function() return client.inInstance end,
    GetNumSubgroupMembers = function() return #client:Others() end,
    UnitName = function(unit)
      if unit == "player" then return first, surname end
      local i = tonumber(unit:match("^party(%d)$") or "")
      local other = i and client:Others()[i]
      if other then return other.name:match("^(%S+) (%S+)$") end
    end,
    UnitIsConnected = function(unit)
      local i = tonumber(unit:match("^party(%d)$") or "")
      local other = i and client:Others()[i]
      return other and other.online or false
    end,
    issecretvalue = function() return false end,
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
    unpack = table.unpack,
    print = function(...) client.log[#client.log + 1] = table.concat({ ... }, " ") end,
    SlashCmdList = {},
    SYNDICATOR_DATA = self.saved.SYNDICATOR_DATA,
  }, { __index = _G })
  self.env = env
  local callbacks = {}
  env.Syndicator = {
    API = {
      IsReady = function() return true end,
      GetCurrentCharacter = function() return client.key end,
      DeleteCharacter = function(key) env.SYNDICATOR_DATA.Characters[key] = nil end,
    },
    CallbackRegistry = {
      RegisterCallback = function(_, event, fn, owner)
        callbacks[event] = callbacks[event] or {}
        table.insert(callbacks[event], { fn = fn, owner = owner })
      end,
      TriggerEvent = function(_, event, ...)
        client.triggered[#client.triggered + 1] = { event = event, key = (...) }
        for _, cb in ipairs(callbacks[event] or {}) do cb.fn(cb.owner, ...) end
      end,
    },
  }
  self.online = true
  for _, toc in ipairs(ADDONS) do
    local ns = {}
    for _, file in ipairs(toc.files) do
      local chunk = assert(loadfile(ROOT .. "/" .. toc.name .. "/" .. file, "t", env))
      chunk(toc.name, ns)
    end
    for _, var in ipairs(toc.saved) do
      env[var] = self.saved[var]
    end
    self:Fire("ADDON_LOADED", toc.name)
  end
  self:Fire("PLAYER_LOGIN")
  self:Fire("PLAYER_ENTERING_WORLD", true, false)
end

function Client:Save()
  for _, toc in ipairs(ADDONS) do
    for _, var in ipairs(toc.saved) do
      self.saved[var] = self.env[var]
    end
  end
  self.saved.SYNDICATOR_DATA = self.env.SYNDICATOR_DATA
end

function Client:Reload()
  self:Fire("PLAYER_LOGOUT")
  self:Save()
  self:Load()
end

local function NewClient(name, seed, syncDB)
  local first, surname = name:match("^(%S+) (%S+)$")
  local client = setmetatable({ name = name, key = name .. "-Camelot", inInstance = false }, Client)
  client.saved = {
    SyndicatorSyncDB = syncDB,
    SYNDICATOR_DATA = { Characters = { [client.key] = Character(first, surname, seed) } },
  }
  clients[name] = client
  return client
end

local function Advance(seconds)
  local stop = clock + seconds
  while clock < stop do
    clock = clock + 0.05
    RunTimers()
    table.sort(inflight, function(a, b) return a.at < b.at end)
    while inflight[1] and inflight[1].at <= clock do
      local m = table.remove(inflight, 1)
      local to = clients[m.to]
      if to and to.online then
        to:Fire("CHAT_MSG_ADDON", m.prefix, m.text, m.channel, m.sender)
      end
    end
    for _, client in pairs(clients) do
      if client.online then
        for _, f in ipairs(client.frames) do
          if f.shown and f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.05) end
        end
      end
    end
  end
end

local function Group(...)
  group = { ... }
  for _, name in ipairs(group) do clients[name]:Fire("GROUP_ROSTER_UPDATE") end
end

local failed = false
local function Check(label, cond, detail)
  if not cond then failed = true end
  print((cond and "PASS " or "FAIL ") .. label .. (cond and "" or (detail and (": " .. detail) or "")))
end

local function Mirror(client, key)
  local db = client.env.SyndicatorSyncDB
  return db and db.mirrors and db.mirrors[key]
end

local function OnlyMailEvents(client, key)
  for _, t in ipairs(client.triggered) do
    if t.key == key and t.event ~= "MailCacheUpdate" then return false, t.event end
  end
  return true
end

---------------------------------------------------------------------------------------------
-- 1. Two paired accounts log in grouped (Tandem groups them at once, so pings cross).

local A = NewClient("Alpha One", 1, {
  accountId = "acctA", partners = { acctB = { secret = "s3cr3tkey", characters = { ["beta two"] = "Beta Two" }, paired = 1 } },
  mirrors = {}, owned = {},
})
local B = NewClient("Beta Two", 2, {
  accountId = "acctB", partners = { acctA = { secret = "s3cr3tkey", characters = { ["alpha one"] = "Alpha One" }, paired = 1 } },
  mirrors = {}, owned = {},
})
group = { A.name, B.name }
A:Load()
B:Load()
local expectA, expectB = Copy(A:Own()), Copy(B:Own())
Advance(30)
Check("B holds A's character", Equal(B:Data()[A.key], expectA))
Check("A holds B's character", Equal(A:Data()[B.key], expectB))
Check("B records it as a copy from A's account", Mirror(B, A.key) and Mirror(B, A.key).partner == "acctA")
Check("A records it as a copy from B's account", Mirror(A, B.key) and Mirror(A, B.key).partner == "acctB")
Check("each account's own character is untouched", Equal(A:Own(), expectA) and Equal(B:Own(), expectB))
if HAS_LINK then
  local link = A.env.AccountLinkDB
  Check("pairing moved to AccountLink", link and link.accountId == "acctA" and link.partners.acctB
    and link.partners.acctB.secret == "s3cr3tkey")
  Check("and out of SyndicatorSync's saved data", A.env.SyndicatorSyncDB.partners == nil
    and A.env.SyndicatorSyncDB.accountId == nil)
end

-- 2. A loots an item: a change list, not a full copy.
local revBefore = Mirror(B, A.key) and Mirror(B, A.key).rev
A:Own().bags[1][3] = { itemID = 12345, itemCount = 7, quality = 3, itemLink = "|cff0070dd|Hitem:12345|h[Loot]|h|r" }
A:Own().money = A:Own().money + 55
A:Trigger("BagCacheUpdate", A.key)
expectA = Copy(A:Own())
Advance(10)
Check("B's copy shows A's loot", Equal(B:Data()[A.key], expectA))
Check("it came as one change list (rev +1)", Mirror(B, A.key) and Mirror(B, A.key).rev == revBefore + 1,
  tostring(revBefore) .. " -> " .. tostring(Mirror(B, A.key) and Mirror(B, A.key).rev))
local ok, bad = OnlyMailEvents(B, A.key)
Check("Syndicator hears only MailCacheUpdate for a copy", ok, bad)

-- 3. A big change on a lossy, shuffled network.
net.drop = 0.15
for bag = 1, 5 do
  for slot = 1, 16 do
    B:Own().bags[bag][slot].itemCount = B:Own().bags[bag][slot].itemCount + 10
  end
end
B:Trigger("BagCacheUpdate", B.key)
expectB = Copy(B:Own())
Advance(180)
net.drop = 0
Check("A's copy catches up through lost messages", Equal(A:Data()[B.key], expectB),
  ("%d of %d messages dropped"):format(net.dropped, net.sent))

-- 4. B reloads after a change it made while the session was down.
B:Fire("PLAYER_LOGOUT")
B.online = false
B:Own().money = 999999
expectB = Copy(B:Own())
B:Save()
Advance(5)
B:Load()
Advance(30)
Check("after B's reload, A's copy has the change", Equal(A:Data()[B.key], expectB))
A:Own().money = 4242
A:Trigger("CurrencyCacheUpdate", A.key)
expectA = Copy(A:Own())
Advance(10)
Check("and the new session carries changes", Equal(B:Data()[A.key], expectA))

-- 5. Full copies wait while the sender is in an instance.
B.inInstance = true
local revHeld = Mirror(A, B.key).rev
A:Slash("SYNDICATORSYNC", "resync")
Advance(20)
Check("in an instance, B holds back its full copy", Mirror(A, B.key).rev == revHeld)
B.inInstance = false
B:Fire("PLAYER_ENTERING_WORLD", false, false)
Advance(20)
Check("outside, it sends it", Mirror(A, B.key).rev ~= revHeld and Equal(A:Data()[B.key], expectB))

-- 6. Each account sends only its own characters.
Check("A's own character never came back from B", Equal(A:Own(), expectA))
Check("B's own character never came back from A", Equal(B:Own(), expectB))

-- 7. AccountLink only: more datasets beside Syndicator's.
if HAS_LINK then
  local function Toy(client, name, value)
    client[name] = { store = { [client.key] = { v = value } }, state = {} }
    local toy = client[name]
    return { state = toy.state, title = name, Store = function() return toy.store end,
      CurrentKey = function() return client.key end, OnMirrored = function(key) toy.mirrored = key end }
  end
  A.env.AccountLink.Register("toy", Toy(A, "toy", 1))
  Advance(5)
  B.env.AccountLink.Register("toy", Toy(B, "toy", 2))
  Advance(20)
  Check("a dataset registered later on one side syncs both ways", Equal(B.toy.store[A.key], { v = 1 })
    and Equal(A.toy.store[B.key], { v = 2 }))
  A.toy.store[A.key].v = 3
  A.env.AccountLink.Changed("toy", A.key)
  Advance(10)
  Check("its changes go as change lists", Equal(B.toy.store[A.key], { v = 3 }) and B.toy.state.mirrors[A.key].rev == 2)
  Check("and copies reach its OnMirrored", B.toy.mirrored == A.key)
  A.env.AccountLink.Register("solo", Toy(A, "solo", 9))
  A:Own().money = A:Own().money + 1
  A:Trigger("BagCacheUpdate", A.key)
  expectA = Copy(A:Own())
  Advance(20)
  Check("a dataset the other side lacks breaks nothing", B.solo == nil and Equal(B:Data()[A.key], expectA))
  A:Slash("ACCOUNTLINK", "")
  A:Slash("SYNDICATORSYNC", "")
  local log = table.concat(A.log, "\n")
  Check("/alink and /ssync report the link and the copies", log:find("linked with Beta Two", 1, true)
    and log:find("Beta Two-Camelot", 1, true) and log:find("toy (1 copy held)", 1, true), log)
end

-- 8. Pairing from scratch, from the slash command and the popup.
local C = NewClient("Gamma Three", 3, nil)
local D = NewClient("Delta Four", 4, nil)
group = { C.name, D.name }
C:Load()
D:Load()
Advance(5)
C:Slash("SYNDICATORSYNC", "pair Delta Four")
Advance(2)
local popup = D.env.AccountLinkPairConfirm or D.env.SyndicatorSyncPairConfirm
Check("D gets the pairing popup", popup and popup.shown)
if popup then popup.Accept.scripts.OnClick() end
Advance(30)
Check("D holds C's character after pairing", Equal(D:Data()[C.key], C:Own()))
Check("C holds D's character after pairing", Equal(C:Data()[D.key], D:Own()))

print(("network: %d messages, %d dropped"):format(net.sent, net.dropped))
print(failed and "FAILED" or "ok")
