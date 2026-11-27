-- Bobber mock: what the jump key is bound to through casts and catches. One press does one
-- thing: when what the key should do changes while it's held, it does nothing until it's let
-- go, so letting go of the press that reeled in can't cast again. Once it's let go, the next
-- press casts at once (fast looting). Asserts (PASS/FAIL).
local path = ...

local M -- a value that can be called or indexed without end
M = setmetatable({}, { __index = function() return M end, __call = function() return nil end })

local clock = 0
local channel -- the spell being channelled, or nil
local held = false -- the space bar is down
local speed = 0
local frames, bindings = {}, {}

local function NewFrame()
  local f = { scripts = {}, events = {} }
  setmetatable(f, { __index = function(_, method)
    if method == "SetScript" then return function(self, s, fn) self.scripts[s] = fn end end
    if method == "RegisterEvent" then return function(self, e) self.events[e] = true end end
    return function() end
  end })
  frames[#frames + 1] = f
  return f
end

local cvars = { softTargetInteract = "1", SoftTargetInteractArc = "1", SoftTargetInteractRange = "10",
  SoftTargetIconGameObject = "0", autoLootDefault = "0" }

local env = setmetatable({
  CreateFrame = NewFrame,
  RegisterStateDriver = function() end,
  Enum = { ItemClass = { Weapon = 2 }, ItemWeaponSubclass = { Fishingpole = 20 } },
  GetCVar = function(name) return cvars[name] end,
  SetCVar = function(name, value) cvars[name] = value end,
  IsPlayerSpell = function(id) return id == 7620 end,
  C_Spell = { GetSpellName = function(id) return id == 7620 and "Fishing" or nil end },
  C_Item = {
    GetItemInfoInstant = function() return nil, nil, nil, nil, nil, 2, 20 end,
    GetItemCount = function() return 0 end,
  },
  GetInventoryItemID = function(_, slot) return slot == 16 and 6256 or nil end,
  UnitChannelInfo = function()
    if channel then return channel, nil, nil, nil, nil, nil, nil, 7620 end
  end,
  InCombatLockdown = function() return false end,
  GetUnitSpeed = function() return speed end,
  IsFalling = function() return false end,
  IsSwimming = function() return false end,
  IsMounted = function() return false end,
  UnitOnTaxi = function() return false end,
  UnitIsDeadOrGhost = function() return false end,
  GetBindingKey = function(command) if command == "JUMP" then return "SPACE" end end,
  IsKeyDown = function(key) return key == "SPACE" and held end,
  ClearOverrideBindings = function() for k in pairs(bindings) do bindings[k] = nil end end,
  SetOverrideBindingSpell = function(_, _, key, spell) bindings[key] = "spell " .. spell end,
  SetOverrideBinding = function(_, _, key, command) bindings[key] = command end,
  SetOverrideBindingClick = function(_, _, key, button) bindings[key] = "click " .. button end,
  GetTime = function() return clock end,
  issecretvalue = function() return false end,
  tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end,
  wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
  print = function() end,
  SlashCmdList = {},
}, { __index = function(_, k) local v = _G[k]; if v ~= nil then return v end return M end })
env.Upkeep = nil
env.BobberDB = { enabled = true, saved = {}, trace = { "0.000 trace on" } } -- left by the trace build

local chunk = assert(loadfile(path, "t", env))
chunk("Bobber")

local function Fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
-- Time passes in the 0.1 s steps Bobber checks the key at.
local function Wait(seconds)
  for _ = 1, math.floor(seconds * 10 + 0.5) do
    clock = clock + 0.1
    for _, f in ipairs(frames) do
      if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.1) end
    end
  end
end

local CAST, REEL, WAIT = "spell Fishing", "INTERACTTARGET", "click BobberWaitButton"
local failed = false
local function Check(label, want)
  local got = bindings.SPACE
  local cond = got == want
  if not cond then failed = true end
  print((cond and "PASS " or "FAIL ") .. label .. (cond and "" or (": got [" .. tostring(got) .. "], want ["
    .. tostring(want) .. "]")))
end

Fire("PLAYER_LOGIN")
local cleared = env.BobberDB.trace == nil
if not cleared then failed = true end
print((cleared and "PASS " or "FAIL ") .. "the trace build's saved lines are dropped")
Wait(0.1)
Check("pole in hand, standing still: the key casts", CAST)

-- A cast, with the key held down a while.
held = true
channel = "Fishing"
Wait(0.3)
Check("cast, key still down: it does nothing", WAIT)
held = false
Wait(0.1)
Check("let go with the bobber out: the key reels in", REEL)

-- The catch, with the key held down well past the loot. Letting go of this press used to cast.
held = true
channel = nil
Wait(0.2)
Check("reeled in, key still down: no cast", WAIT)
Wait(3)
Check("held for seconds: still no cast", WAIT)
held = false
Wait(0.1)
Check("let go: the key casts", CAST)

-- A quick tap to reel in: the next press casts at once, even before the loot is in.
channel = "Fishing"
Wait(0.5)
Check("bobber out: the key reels in", REEL)
channel = nil
Wait(0.1)
Check("tapped to reel in: the next press casts", CAST)

-- The press that reels in, let go just after the key changed.
channel = "Fishing"
Wait(0.5)
held = true
channel = nil
Wait(0.1)
Check("reeled in, key down at the change: no cast", WAIT)
held = false
Wait(0.1)
Check("let go right after: the key casts", CAST)

-- Moving still jumps, and landing with the key down doesn't cast.
speed = 7
Wait(0.1)
Check("moving: the key jumps", nil)
speed = 0
held = true
Wait(0.1)
Check("stopped with the key down: it does nothing yet", WAIT)
held = false
Wait(0.1)
Check("let go: the key casts", CAST)
print(failed and "FAILED" or "ok")
