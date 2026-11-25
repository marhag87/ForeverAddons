-- ThreatGap mock: a paladin's Righteous Fury picks the tank view, and stays picked through a
-- fight, where buffs can't be read. Asserts (PASS/FAIL).
local path = ...

local M -- a value that can be called or indexed without end
M = setmetatable({}, { __index = function() return M end, __call = function() return nil end })

local clock, combat = 0, false
local furyAura  -- the aura GetPlayerAuraBySpellID gives out of combat, or nil
local frames, printed = {}, {}
local registered, unitRegistered = {}, {}

local function NewFrame()
  local f = { scripts = {} }
  setmetatable(f, { __index = function(_, method)
    if method == "SetScript" then return function(self, s, fn) self.scripts[s] = fn end end
    if method == "RegisterEvent" then return function(_, e) registered[e] = true end end
    if method == "RegisterUnitEvent" then return function(_, e, unit) unitRegistered[e] = unit end end
    return function() end
  end })
  frames[#frames + 1] = f
  return f
end

local env = setmetatable({
  CreateFrame = NewFrame,
  C_NamePlate = { GetNamePlateForUnit = function() return nil end },
  -- Forever hides your buffs in combat.
  C_UnitAuras = { GetPlayerAuraBySpellID = function(id)
      if combat or id ~= 25780 then return nil end
      return furyAura
    end },
  DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) printed[#printed + 1] = msg end },
  UnitAffectingCombat = function() return combat end,
  InCombatLockdown = function() return combat end,
  GetTime = function() return clock end,
  GetShapeshiftFormID = function() return nil end,
  GetNumShapeshiftForms = function() return 0 end,
  UnitClass = function() return "Paladin", "PALADIN" end,
  IsInInstance = function() return false end,
  IsInRaid = function() return false end,
  GetNumSubgroupMembers = function() return 0 end,
  UnitExists = function() return false end,
  issecretvalue = function() return false end,
  wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
  SlashCmdList = {},
}, { __index = function(_, k) local v = _G[k]; if v ~= nil then return v end return M end })

local chunk = assert(loadfile(path, "t", env))
chunk("ThreatGap")

local function Fire(event, ...)
  for _, f in ipairs(frames) do
    if f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end

-- The view /threatgap reports: "tank" or "not tanking", and why.
local function View()
  printed = {}
  env.SlashCmdList.THREATGAP("")
  for _, line in ipairs(printed) do
    local view, why = line:match("View: (.-) %((.*)%)%.")
    if view then return view, why end
  end
end

local failed = false
local function Check(label, want, wantWhy)
  local got, why = View()
  local cond = got == want and (not wantWhy or (why and why:find(wantWhy, 1, true)))
  if not cond then failed = true end
  print((cond and "PASS " or "FAIL ") .. label .. (cond and "" or (": got [" .. tostring(got) .. " / "
    .. tostring(why) .. "], want [" .. want .. "]")))
end

Fire("ADDON_LOADED", "ThreatGap")
furyAura = { expirationTime = clock + 1700 }
Fire("PLAYER_ENTERING_WORLD")
Check("Righteous Fury up, out of combat", "tank", "Righteous Fury")
combat = true
Fire("PLAYER_REGEN_DISABLED")
Check("in combat, where it can't be read", "tank", "carried")
clock = clock + 1800
Fire("PLAYER_TARGET_CHANGED")
Check("run out during the fight", "not tanking")
combat = false
furyAura = nil
Fire("PLAYER_REGEN_ENABLED")
Check("gone after the fight", "not tanking")
combat = true
Fire("PLAYER_REGEN_DISABLED")
Fire("UNIT_SPELLCAST_SENT", "player", "", "guid1", 25780)
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid1", 25780)
Check("cast in combat", "tank", "carried")
combat = false
furyAura = { expirationTime = clock + 1790 }
Fire("PLAYER_REGEN_ENABLED")
Check("after the fight it reads again", "tank", "Righteous Fury")
furyAura = nil
Fire("UNIT_AURA", "player", {})
Check("cancelled out of combat", "not tanking")
combat = true
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid9", 25780)
Check("someone else's cast doesn't count", "not tanking")
combat = false

local unitOnly = unitRegistered.UNIT_SPELLCAST_SUCCEEDED == "player" and unitRegistered.UNIT_AURA == "player"
  and not registered.UNIT_SPELLCAST_SUCCEEDED and not registered.UNIT_AURA
if not unitOnly then failed = true end
print((unitOnly and "PASS " or "FAIL ") .. "casts and auras are registered for you alone")
print(failed and "FAILED" or "ok")
