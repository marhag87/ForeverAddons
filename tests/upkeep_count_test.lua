counts = { [8364] = 7, [211527] = 1, [6532] = 4, [6533] = 2 }
STACKS = { [8364] = 20, [211527] = 1, [6532] = 20, [6533] = 20 }
if select(2, ...) == "info" then STACKS = nil end
INFO_STACKS = { [8364] = 20, [211527] = 1, [6532] = 20, [6533] = 20 }
clock = 0
buffed = false
rested = false
stacks, expires = 3, 3600
-- Upkeep mock: item reminders show how many you carry; arg info = no GetItemMaxStackSizeByID.
local path, mode = ...

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
    if method == "SetText" then return function(self, s) self.text = s end end
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
  UnitClass = function() return "Warrior", "WARRIOR" end,
  UnitLevel = function() return 30 end,
  GetMaxLevelForPlayerExpansion = function() return 60 end,
  NUM_BAG_SLOTS = 0,
  Enum = { ItemClass = { Consumable = 0, Weapon = 2 }, ItemWeaponSubclass = { Fishingpole = 20 } },
  C_Container = { GetContainerNumSlots = function() return 2 end,
    GetContainerItemID = function(bag, slot) return slot == 1 and 8364 or 211527 end,
    GetItemCooldown = function() return 0, 0, 1 end },
  C_TooltipInfo = {
    GetBagItem = function(bag, slot)
      if slot == 1 then return { lines = { { leftText = "Mithril Head Trout" },
        { leftText = "Use: Restores 841 health. Additionally, experience gained from kills is increased by 5%." } } } end
      return { lines = { { leftText = "Linen Cloth" }, { leftText = "Trade Goods" } } }
    end,
    GetUnitAura = function(unit, i)
      if i == 1 and rested then return { lines = { { leftText = "Well-Rested" }, { leftText = "Experience gained from kills increased by 10%." } } } end
      if buffed and i == (rested and 2 or 1) then return { lines = { { leftText = "Well Fed" }, { leftText = "Attack Power increased by 20. Experience gained from kills increased by 5%." } } } end
      return nil
    end,
    GetInventoryItem = function() return nil end,
  },
  C_Item = { GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, id == 8364 and 0 or 7 end,
    IsUsableItem = function() return true end, GetItemInfo = function(id) return "x", nil, nil, 35, nil, nil, nil, INFO_STACKS[id] end,
    GetItemCount = function(id) return counts[id] or 0 end, GetItemMaxStackSizeByID = STACKS and function(id) return STACKS[id] end or nil, GetItemIconByID = function(id) return id end,
    GetItemNameByID = function(id) return id == 211527 and "Cozy Sleeping Bag" or "Mithril Head Trout" end },
  C_Timer = { After = function() end },
  InCombatLockdown = function() return lockdown end,
  UnitAffectingCombat = function() return combat end,
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
  C_UnitAuras = { GetAuraDataByIndex = function() return nil end,
    GetAuraDataBySpellName = function(unit, name) if rested and name == "Well-Rested" then return { applications = stacks, expirationTime = clock + expires } end end },
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

local function Counts(label)
  local out = {}
  for i, b in ipairs(buttons) do
    if b.shown and b.attrs.type then
      out[#out + 1] = ("%d:%s=[%s]"):format(i, tostring(b.attrs.item or b.attrs.macrotext):gsub("\n", " "), tostring(b.count and b.count.text))
    end
  end
  local plain = {}
  for _, f in ipairs(frames) do
    if f.kind == "Frame" and f.count and f.shown and not f.template and f.parent and f.parent.shown then
      plain[#plain + 1] = "[" .. tostring(f.count.text) .. "]"
    end
  end
  print(label .. ": " .. table.concat(out, " ") .. (#plain > 0 and ("  plain " .. table.concat(plain, " ")) or ""))
end

Fire("PLAYER_LOGIN")
Tick()
Counts("food 7, bag in bags")
env.Upkeep.AddReminder("Bobber.lure", { icon = 3, item = 6532, click = { type = "macro", macrotext = "/use item:6532\n/use 16" }, glow = false, resting = true })
Tick()
Counts("lure added, 4 lures")
counts[6532] = 3
counts[8364] = 6
Tick()
Counts("used a lure and a fish")
combat, lockdown = true, true
env.Upkeep.AddReminder("Test.lure2", { icon = 4, item = 6533, click = { type = "item", item = "item:6533" } })
Tick()
Counts("in combat, another lure as a plain icon")
counts[6533] = 12345
Tick()
Counts("in combat, lots of them")
print("ok")
