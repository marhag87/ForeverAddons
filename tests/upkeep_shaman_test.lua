minutes = 30
clock = 0
-- Upkeep mock: a shaman's weapon enchant (Rockbiter): early warning, running out, combat.
local path = ...

local M -- a value that can be called or indexed without end
M = setmetatable({}, { __index = function() return M end, __call = function() return nil end })

local combat, lockdown = false, false
local frames, buttons = {}, {}

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

local env = setmetatable({
  CreateFrame = NewFrame,
  UnitClass = function() return "Shaman", "SHAMAN" end,
  Enum = { ItemClass = { Consumable = 0, Weapon = 2 }, ItemWeaponSubclass = { Fishingpole = 20 } },
  GetInventoryItemID = function(unit, slot) return slot == 16 and 1234 or nil end,
  C_Item = { GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, 2, 1 end, GetItemCount = function() return 0 end },
  C_TooltipInfo = { GetInventoryItem = function(unit, slot)
      if minutes == 0 then return { lines = { { leftText = "Stone Axe" } } } end
      return { lines = { { leftText = "Stone Axe" }, { leftText = "Rockbiter 3 (" .. minutes .. " min)" } } }
    end },
  InCombatLockdown = function() return lockdown end,
  UnitAffectingCombat = function() return combat end,
  GetTime = function() return clock end,
  RegisterStateDriver = function(f, state, cond) f.driver = cond end,
  IsSpellKnown = function(id) return id == 8017 or id == 8018 or id == 8019 end,
  IsPlayerSpell = function() return false end,
  C_Spell = {
    GetSpellName = function(id)
      return ({ [19740] = "Blessing of Might", [20217] = "Blessing of Kings", [6673] = "Battle Shout" })[id]
    end,
    GetSpellTexture = function(id) return id end,
  },
  C_UnitAuras = { GetAuraDataByIndex = function() return nil end },
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
local function Report(label)
  local out = {}
  for i, b in ipairs(buttons) do
    out[#out + 1] = ("%d:%s%s"):format(i, b.shown and (b.glowing and "glowing" or "shown") or "hidden",
      b.attrs.type and ("(" .. b.attrs.type .. " " .. tostring(b.attrs.spell or b.attrs.item or b.attrs.macrotext) .. ")") or "")
  end
  print(label .. ": " .. (#out > 0 and table.concat(out, " ") or "no buttons"))
end

Fire("PLAYER_LOGIN")
Tick()
Report("after login")

Report("rockbiter, 30 min left")
minutes = 4
Tick()
Report("rockbiter, 4 min left")
combat = true
Tick()
Report("in combat, 4 min left")
combat = false
minutes = 0
Tick()
Report("run out")
combat = true
Tick()
Report("in combat, run out")
combat = false
print("ok")
