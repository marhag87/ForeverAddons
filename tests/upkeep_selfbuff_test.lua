clock = 0
-- Upkeep mock: class self buffs read from auras. Mode "mage": Arcane Intellect and the
-- armors. Mode "paladin": an aura, which never runs out and counts only when it is yours.
-- Asserts (PASS/FAIL).
local path, mode = ...

local M -- a value that can be called or indexed without end
M = setmetatable({}, { __index = function() return M end, __call = function() return nil end })

local combat, lockdown = false, false
local frames, buttons = {}, {}
local auras = {}  -- { name, duration, expirationTime, sourceUnit, spellId } on you

local function NewFrame(kind, name, parent, template)
  local f = { kind = kind, template = template, attrs = {}, scripts = {}, shown = true, parent = parent }
  setmetatable(f, { __index = function(_, method)
    if method == "SetScript" then return function(self, s, fn) self.scripts[s] = fn end end
    if method == "HookScript" then return function() end end
    if method == "GetScript" then return function(self, s) return self.scripts[s] end end
    if method == "SetAttribute" then
      return function(self, k, v)
        if lockdown and self.template == "SecureActionButtonTemplate" then error("SetAttribute in combat") end
        self.attrs[k] = v
      end
    end
    if method == "Show" then
      return function(self)
        if lockdown and self.template == "SecureActionButtonTemplate" then error("Show in combat") end
        self.shown = true
      end
    end
    if method == "Hide" then
      return function(self)
        if lockdown and self.template == "SecureActionButtonTemplate" then error("Hide in combat") end
        self.shown = false
      end
    end
    if method == "IsShown" or method == "IsVisible" then return function(self) return self.shown end end
    if method == "GetWidth" then return function() return 100 end end
    if method == "GetHeight" then return function() return 20 end end
    if method == "GetFrameLevel" then return function() return 1 end end
    if method == "GetEffectiveScale" then return function() return 1 end end
    if method == "CreateTexture" or method == "CreateFontString" then
      return function() return NewFrame("Texture") end
    end
    -- Frame methods are capitalised; any other field a frame doesn't have is nil.
    if method:match("^%u") then return function() end end
    return nil
  end })
  frames[#frames + 1] = f
  if template == "SecureActionButtonTemplate" then buttons[#buttons + 1] = f end
  return f
end

local KNOWN = mode == "paladin"
  and { [10290] = true, [7294] = true }  -- Devotion Aura rank 2, Retribution Aura rank 1
  or { [1459] = true, [1460] = true, [1461] = true, [168] = true, [7300] = true, [7301] = true, [7302] = true }
local NAMES = {
  [10290] = "Devotion Aura", [7294] = "Retribution Aura",
  [1461] = "Arcane Intellect", [7301] = "Frost Armor", [7302] = "Ice Armor",
}

local env = setmetatable({
  CreateFrame = NewFrame,
  UnitClass = function()
    if mode == "paladin" then return "Paladin", "PALADIN" end
    return "Mage", "MAGE"
  end,
  InCombatLockdown = function() return lockdown end,
  UnitAffectingCombat = function() return combat end,
  IsResting = function() return false end,
  IsMounted = function() return false end,
  GetTime = function() return clock end,
  RegisterStateDriver = function(f, state, cond) f.driver = cond end,
  IsSpellKnown = function(id) return KNOWN[id] == true end,
  IsPlayerSpell = function() return false end,
  C_Spell = {
    GetSpellName = function(id) return NAMES[id] end,
    GetSpellTexture = function(id) return id end,
  },
  -- In combat nothing on you is readable.
  C_UnitAuras = { GetAuraDataByIndex = function(unit, i, filter)
      if combat or unit ~= "player" then return nil end
      local list = {}
      for _, a in ipairs(auras) do
        if filter ~= "HELPFUL|PLAYER" or a.sourceUnit == "player" then list[#list + 1] = a end
      end
      return list[i]
    end },
  UnitIsUnit = function(a, b) return a == b end,
  UnitExists = function() return false end,
  issecretvalue = function() return false end,
  wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
  SlashCmdList = {},
  Upkeep = nil,
}, { __index = function(_, k) local v = _G[k]; if v ~= nil then return v end return M end })
env.TargetFrame = NewFrame("Frame", "TargetFrame")
env.UIParent = NewFrame("Frame", "UIParent")
env.PlayerFrame = NewFrame("Frame", "PlayerFrame")
env.GameTooltip = NewFrame("Frame", "GameTooltip")
env.Upkeep = {}

local chunk = assert(loadfile(path, "t", env))
chunk("Upkeep")

local function Fire(event, ...)
  for _, f in ipairs(frames) do
    if f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
local function Tick()
  for _, f in ipairs(frames) do
    if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 1) end
  end
  clock = clock + 1
end
local function Aura(spellId, src, dur)
  return { name = NAMES[spellId] or ("spell " .. spellId), duration = dur or 1800,
    expirationTime = dur == 0 and 0 or clock + (dur or 1800), sourceUnit = src or "player", spellId = spellId }
end

-- The spells the shown reminder buttons cast, sorted, as "spell@unit".
local function Shown()
  local out = {}
  for _, b in ipairs(buttons) do
    if b.shown and b.attrs.spell then out[#out + 1] = b.attrs.spell .. "@" .. tostring(b.attrs.unit) end
  end
  table.sort(out)
  return table.concat(out, " ")
end
-- Plain icons waiting for combat to end.
local function Plain()
  local n = 0
  for _, f in ipairs(frames) do
    if f.entry and f.shown then n = n + 1 end
  end
  return n
end

local failed = false
local function Check(label, got, want)
  local cond = got == want
  if not cond then failed = true end
  print((cond and "PASS " or "FAIL ") .. label .. (cond and "" or (": got [" .. tostring(got) .. "], want [" .. tostring(want) .. "]")))
end

Fire("PLAYER_LOGIN")
Tick()

if mode == "paladin" then
  Check("no aura: Devotion Aura, cast on you", Shown(), "10290@player")
  auras = { Aura(19900, "party1", 0) }  -- another paladin's Fire Resistance Aura
  Tick()
  Check("another paladin's aura doesn't count", Shown(), "10290@player")
  auras = { Aura(7294, "player", 0) }
  Tick()
  Check("your Retribution Aura counts", Shown(), "")
  combat, lockdown = true, true
  clock = clock + 2000
  Tick()
  Check("in combat it doesn't run out", Plain(), 0)
  combat, lockdown = false, false
  auras = {}
  Fire("PLAYER_REGEN_ENABLED")
  Tick()
  Check("gone after combat: the one last up", Shown(), "7294@player")
  auras = { Aura(7294, "player", 0) }
  Tick()
  combat, lockdown = true, true
  Fire("UNIT_SPELLCAST_SENT", "player", "", "guid1", 10290)
  Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid1", 10290)
  clock = clock + 2000
  Tick()
  Check("cast in combat, it doesn't run out", Plain(), 0)
  combat, lockdown = false, false
else
  Check("nothing up: Arcane Intellect and Ice Armor", Shown(), "1461@player 7302@player")
  auras = { Aura(1461, "party1"), Aura(7301) }  -- another mage's Intellect, your Frost Armor
  Tick()
  Check("anyone's Intellect and Frost Armor count", Shown(), "")
  auras = { Aura(23028, "party1"), Aura(7301) }
  Tick()
  Check("Arcane Brilliance counts", Shown(), "")
  auras = { Aura(1460, "party1"), Aura(7301) }
  Tick()
  Check("a lower rank of Intellect counts as missing", Shown(), "1461@player")
  auras = { Aura(1461), Aura(7301, "player", 1800) }
  auras[2].expirationTime = clock + 5
  Tick()
  clock = clock + 10
  combat, lockdown = true, true
  Tick()
  Check("Frost Armor running out in combat: a plain icon", Plain(), 1)
  combat, lockdown = false, false
  auras = { Aura(1461) }
  Fire("PLAYER_REGEN_ENABLED")
  Tick()
  Check("after combat: Frost Armor, the one last up", Shown(), "7301@player")
end
print(failed and "FAILED" or "ok")
