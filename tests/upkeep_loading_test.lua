clock = 0
-- Food whose use spell hasn't loaded at login: its tooltip has no "Use:" line yet, so
-- Upkeep must look again rather than decide it gives no experience. Modes: "nocache" has no
-- C_Spell.IsSpellDataCached; "nospell" has GetItemSpell name no spell until it has loaded.
local path, mode = ...
local withCacheApi = mode ~= "nocache"
local spellKnownEarly = mode ~= "nospell"

local M
M = setmetatable({}, { __index = function() return M end, __call = function() return nil end })

local frames, buttons = {}, {}
local function NewFrame(kind, name, parent, template)
  local f = { kind = kind, template = template, attrs = {}, scripts = {}, shown = true, parent = parent }
  setmetatable(f, { __index = function(_, method)
    if method == "SetScript" then return function(self, s, fn) self.scripts[s] = fn end end
    if method == "GetScript" then return function(self, s) return self.scripts[s] end end
    if method == "SetAttribute" then return function(self, k, v) self.attrs[k] = v end end
    if method == "Show" then return function(self) self.shown = true end end
    if method == "Hide" then return function(self) self.shown = false end end
    if method == "IsShown" or method == "IsVisible" then return function(self) return self.shown end end
    if method == "GetWidth" then return function() return 100 end end
    if method == "GetHeight" then return function() return 20 end end
    if method == "GetFrameLevel" then return function() return 1 end end
    if method == "GetEffectiveScale" then return function() return 1 end end
    if method == "CreateTexture" or method == "CreateFontString" then
      return function() return NewFrame("Texture") end
    end
    if method:match("^%u") then return function() end end
    return nil
  end })
  frames[#frames + 1] = f
  if template == "SecureActionButtonTemplate" then buttons[#buttons + 1] = f end
  return f
end

local TROUT, REDGILL, BANDAGE, RAPTOR = 8364, 13930, 14529, 990001  -- the raptor's id is made up
local SPELL = { [TROUT] = 18233, [REDGILL] = 18234, [BANDAGE] = 18610, [RAPTOR] = 990002 }
local DESC = {
  [18233] = "Restores 874 health over 27 sec. Must remain seated while eating. If you spend at least 10 sec eating, you will become well fed and gain 5% experience gained from kills.",
  [18234] = "Restores 1,338 health over 30 sec. If you spend at least 10 sec eating, you will become well fed and gain 18 Fishing Skill for 15 min. Additionally, experience gained from kills is increased by 5%.",
  [18610] = "Heals 2000 damage over 8 sec.",
  [990002] = "Restores 874 health over 27 sec. If you spend at least 10 sec eating, you will become well fed and gain 10 Stamina for 15 min. Additionally, experience gained from kills is increased by 5%.",
}
local NAME = { [TROUT] = "Mithril Head Trout", [REDGILL] = "Filet of Redgill", [BANDAGE] = "Runecloth Bandage",
  [RAPTOR] = "Twice-Spiced Raptor Slice" }
local loaded = {}       -- spell id -> true once loaded
local partial = {}      -- spell id -> true while its text reads without the bonus
local function Desc(spell)
  if not loaded[spell] then return "" end
  return partial[spell] and DESC[spell]:match("^[^.]*%.") or DESC[spell]
end
local requested = {}    -- spell ids asked for
local timers = {}

local bagItems = { TROUT, REDGILL, BANDAGE }
local function Tooltip(id)
  local lines = { { leftText = NAME[id] } }
  -- The "Use:" line only once the spell has loaded.
  if loaded[SPELL[id]] then lines[#lines + 1] = { leftText = "Use: " .. Desc(SPELL[id]) .. " (1 Sec Cooldown)" } end
  lines[#lines + 1] = { leftText = "Requires Level 35" }
  lines[#lines + 1] = { leftText = "Sell Price:" }
  return { lines = lines }
end

local C_Spell = {
  GetSpellName = function(id) return ({ [6673] = "Battle Shout" })[id] end,
  GetSpellTexture = function(id) return id end,
  RequestLoadSpellData = function(id) requested[#requested + 1] = id end,
  GetSpellDescription = Desc,
}
if withCacheApi then C_Spell.IsSpellDataCached = function(id) return loaded[id] == true end end

local env = setmetatable({
  CreateFrame = NewFrame,
  UnitClass = function() return "Warrior", "WARRIOR" end,
  UnitLevel = function() return 57 end,
  GetMaxLevelForPlayerExpansion = function() return 60 end,
  NUM_BAG_SLOTS = 0,
  Enum = { ItemClass = { Consumable = 0, Weapon = 2 }, ItemWeaponSubclass = { Fishingpole = 20 } },
  C_Container = { GetContainerNumSlots = function() return #bagItems end,
    GetContainerItemID = function(bag, slot) return bagItems[slot] end,
    GetItemCooldown = function() return 0, 0 end },
  C_TooltipInfo = {
    GetBagItem = function(bag, slot) return Tooltip(bagItems[slot]) end,
    GetUnitAura = function(unit, i)
      if i == 1 then return { lines = { { leftText = "Well-Rested" }, { leftText = "Experience gains increased by 3%." } } } end
      return nil
    end,
    GetInventoryItem = function() return nil end,
  },
  C_Item = {
    GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, 0 end,
    IsItemDataCachedByID = function() return true end,
    GetItemSpell = function(id)
      if spellKnownEarly or loaded[SPELL[id]] then return "Food", SPELL[id] end
    end,
    IsUsableItem = function() return true end, GetItemInfo = function(id) return nil, nil, nil, 35 end,
    GetItemCount = function() return 9 end, GetItemIconByID = function(id) return id end,
    GetItemNameByID = function(id) return NAME[id] end,
    GetItemMaxStackSizeByID = function() return 20 end,
  },
  C_Spell = C_Spell,
  C_Timer = { After = function(t, fn) timers[#timers + 1] = fn end },
  InCombatLockdown = function() return false end,
  UnitAffectingCombat = function() return false end,
  IsResting = function() return false end,
  GetTime = function() return clock end,
  RegisterStateDriver = function(f, state, cond) f.driver = cond end,
  IsSpellKnown = function(id) return id == 6673 end,
  IsPlayerSpell = function() return false end,
  C_UnitAuras = { GetAuraDataByIndex = function() return nil end },
  UnitExists = function() return false end,
  issecretvalue = function() return false end,
  wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
  SlashCmdList = {},
  unpack = table.unpack,
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
  clock = clock + 2
end
local function RunTimers()
  local due = timers
  timers = {}
  for _, fn in ipairs(due) do fn() end
end
local function FoodButton(id)
  for _, b in ipairs(buttons) do
    if b.shown and b.attrs.type == "item" and b.attrs.item == "item:" .. (id or TROUT) then return true end
  end
  return false
end
local function Expect(label, cond)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then failed = true end
end

Fire("PLAYER_LOGIN")
Tick()
Expect("no trout reminder while its spell is loading", not FoodButton())
Expect("asked for the trout's spell (or will look again)", #timers == 1)
if withCacheApi and spellKnownEarly then
  local asked = false
  for _, id in ipairs(requested) do if id == SPELL[TROUT] then asked = true end end
  Expect("requested the trout's spell data", asked)
end
env.SlashCmdList.UPKEEP("debug")

-- The spell data arrives; the retry picks the trout up.
for id in pairs(DESC) do loaded[id] = true end
RunTimers()
Tick()
Expect("trout reminder once its spell has loaded", FoodButton())
Expect("no further retries once everything is read", #timers == 0)
env.SlashCmdList.UPKEEP("debug")

-- A bag update must not undo it, and redgill stays out.
Fire("BAG_UPDATE_DELAYED")
Tick()
Expect("trout reminder still there after a bag update", FoodButton())
for _, b in ipairs(buttons) do
  if b.shown and b.attrs.item == "item:" .. REDGILL then Expect("redgill never offered", false) end
end

-- Food first read without its bonus is read again at the next bag change.
bagItems = { REDGILL, BANDAGE, RAPTOR }
loaded[SPELL[RAPTOR]], partial[SPELL[RAPTOR]] = true, true
Fire("BAG_UPDATE_DELAYED")
Tick()
Expect("no raptor reminder while its text lacks the bonus", not FoodButton(RAPTOR))
partial[SPELL[RAPTOR]] = nil
Fire("BAG_UPDATE_DELAYED")
Tick()
Expect("raptor reminder after the next bag change", FoodButton(RAPTOR))
print(failed and "FAILED" or "ok")
