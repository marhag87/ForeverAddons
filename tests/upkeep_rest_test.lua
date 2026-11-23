restingNow = false
clock = 0
-- Upkeep mock: rested areas hide reminders, except ones added with resting = true.
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
  UnitClass = function() return "Paladin", "PALADIN" end,
  InCombatLockdown = function() return lockdown end,
  UnitAffectingCombat = function() return combat end,
  IsResting = function() return restingNow end,
  GetTime = function() return clock end,
  RegisterStateDriver = function(f, state, cond) f.driver = cond end,
  IsSpellKnown = function(id) return id == 19740 or id == 20217 or id == 6673 end,
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
    out[#out + 1] = ("%d:%s%s"):format(i, b.shown and "shown" or "hidden",
      b.attrs.type and ("(" .. b.attrs.type .. " " .. tostring(b.attrs.spell or b.attrs.item or b.attrs.macrotext) .. ")") or "")
  end
  print(label .. ": " .. (#out > 0 and table.concat(out, " ") or "no buttons"))
end

Fire("PLAYER_LOGIN")
Tick()
Report("after login")

env.Upkeep.AddReminder("Test.a", { icon = 1, click = { type = "spell", spell = 111 }, spell = 111 })
Tick()
Report("added a out of combat")

combat, lockdown = true, true
env.Upkeep.AddReminder("Test.b", { icon = 2, click = { type = "spell", spell = 222 }, spell = 222 })
env.Upkeep.RemoveReminder("Test.a")
for _ = 1, 3 do Tick() end
Report("in combat, b added, a removed")

combat, lockdown = false, false
Fire("PLAYER_REGEN_ENABLED")
Tick()
Report("after combat")

env.Upkeep.AddReminder("Test.b", { icon = 2, click = { type = "spell", spell = 333 }, spell = 333 })
Tick()
Report("b's click changed out of combat")
print("target row driver:", tostring(buttons[1] and buttons[1].parent and buttons[1].parent.driver))
for _, f in ipairs(frames) do
  if f.driver then print("state driver on a frame:", f.driver) end
end
env.Upkeep.AddReminder("Test.c", { icon = 3, click = { type = "spell", spell = 444 }, spell = 444, resting = true })
Tick()
Report("before resting, with c (resting = true)")
restingNow = true
Fire("PLAYER_UPDATE_RESTING")
Report("resting")
restingNow = false
Fire("PLAYER_UPDATE_RESTING")
Report("left the rested area")
combat, lockdown = true, true
restingNow = true
Tick()
Report("in combat, entered a rested area")
combat, lockdown = false, false
Fire("PLAYER_REGEN_ENABLED")
Report("after that combat")
print("ok")
