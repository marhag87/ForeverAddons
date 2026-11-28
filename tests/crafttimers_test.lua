-- CraftTimers mock: recipe cooldowns read from an open profession (shared ones as one line,
-- short ones and other people's professions left out), the Salt Shaker and Dedicated Study,
-- the minimap button's flashing and the list. AccountLink is a stub. Asserts (PASS/FAIL).
local path = ...

local M -- a value that can be called or indexed without end
M = setmetatable({}, { __index = function() return M end, __call = function() return nil end })

local clock = 200000 -- GetTime: seconds since the computer started
local SERVER0 = 1800000000
local timers = {}
local function Schedule(seconds, fn, interval)
  local t = { at = clock + seconds, fn = fn, interval = interval }
  function t.Cancel(self) self.cancelled = true end
  timers[#timers + 1] = t
  return t
end
local function RunTimers()
  while true do
    local best, index
    for i, t in ipairs(timers) do
      if not t.cancelled and t.at <= clock and (not best or t.at < best.at) then best, index = t, i end
    end
    if not best then break end
    if best.interval then best.at = best.at + best.interval else table.remove(timers, index) end
    best.fn(best)
  end
end

local frames = {}
local function NewFrame(kind, name)
  local f = { kind = kind, name = name, scripts = {}, events = {}, shown = true, lines = {} }
  setmetatable(f, { __index = function(_, method)
    if method == "SetScript" then return function(self, s, fn) self.scripts[s] = fn end end
    if method == "RegisterEvent" or method == "RegisterUnitEvent" then
      return function(self, e) self.events[e] = true end
    end
    if method == "Show" then return function(self) self.shown = true end end
    if method == "Hide" then return function(self) self.shown = false end end
    if method == "SetShown" then return function(self, v) self.shown = v and true or false end end
    if method == "IsShown" then return function(self) return self.shown end end
    if method == "GetWidth" then return function() return 140 end end
    if method == "GetCenter" then return function() return 500, 500 end end
    if method == "CreateTexture" then return function() return NewFrame("Texture") end end
    if method == "CreateAnimationGroup" then
      return function()
        local g = { playing = false }
        function g.Play(self) self.playing = true end
        function g.Stop(self) self.playing = false end
        function g.IsPlaying(self) return self.playing end
        function g.SetLooping() end
        function g.CreateAnimation() return M end
        return g
      end
    end
    if kind == "GameTooltip" then
      if method == "SetOwner" or method == "ClearLines" then return function(self) self.lines = {} end end
      if method == "AddLine" then return function(self, text) self.lines[#self.lines + 1] = text end end
      if method == "AddDoubleLine" then
        return function(self, l, r) self.lines[#self.lines + 1] = l .. " | " .. r end
      end
    end
    return function() end
  end })
  frames[#frames + 1] = f
  return f
end

-- The game
local known = { [1225469] = true } -- Dedicated Study
local spellCd = { [1225469] = { startTime = clock - 3600, duration = 23 * 3600 } }
local bags = { [15846] = 1 } -- a Salt Shaker
local itemCd = { [15846] = { 0, 0 } }
local profession -- { name, linked, recipes = { [id] = { name, learned, cd, charges, maxCharges } } }

local linkCalls, linkSpec = {}, nil
local env = setmetatable({
  CreateFrame = function(kind, name) local f = NewFrame(kind, name); return f end,
  Minimap = NewFrame("Frame", "Minimap"),
  UIParent = {},
  UISpecialFrames = {},
  GameTooltip = NewFrame("GameTooltip", "GameTooltip"),
  RAID_CLASS_COLORS = { MAGE = { colorStr = "ff3fc7eb" }, WARRIOR = { colorStr = "ffc69b6d" } },
  C_Timer = {
    After = function(s, fn) Schedule(s, fn) end,
    NewTimer = function(s, fn) return Schedule(s, fn) end,
    NewTicker = function(s, fn) return Schedule(s, fn, s) end,
  },
  GetTime = function() return clock end,
  GetServerTime = function() return SERVER0 + math.floor(clock) end,
  UnitName = function(unit) if unit == "player" then return "Tess", "Two" end end,
  UnitClass = function() return "Mage", "MAGE" end,
  InCombatLockdown = function() return false end,
  IsPlayerSpell = function(id) return known[id] == true end,
  C_Spell = {
    GetSpellCooldown = function(id) return spellCd[id] end,
    GetSpellName = function(id) return id == 1225469 and "Dedicated Study" or nil end,
    GetSpellTexture = function() return 136000 end,
    GetSpellInfo = function() return nil end,
  },
  C_Item = {
    GetItemCount = function(id) return bags[id] or 0 end,
    GetItemNameByID = function(id) return id == 15846 and "Salt Shaker" or nil end,
    GetItemIconByID = function() return 135000 end,
  },
  C_Container = { GetItemCooldown = function(id) return itemCd[id][1], itemCd[id][2], 1 end },
  C_TradeSkillUI = {
    IsDataSourceChanging = function() return false end,
    IsTradeSkillLinked = function() return profession and profession.linked or false end,
    IsTradeSkillGuild = function() return false end,
    IsTradeSkillGuildMember = function() return false end,
    IsNPCCrafting = function() return false end,
    GetBaseProfessionInfo = function() return profession and { professionName = profession.name } or {} end,
    GetAllRecipeIDs = function()
      local ids = {}
      for id in pairs(profession and profession.recipes or {}) do ids[#ids + 1] = id end
      table.sort(ids)
      return ids
    end,
    GetRecipeInfo = function(id)
      local r = profession.recipes[id]
      return r and { name = r.name, learned = r.learned, icon = 134000 + id % 1000 }
    end,
    GetRecipeCooldown = function(id)
      local r = profession.recipes[id]
      return r and r.cd, false, r and r.charges, r and r.maxCharges
    end,
  },
  AccountLink = {
    Register = function(name, spec) linkSpec = spec; linkSpec.name = name end,
    Changed = function(name, key) linkCalls[#linkCalls + 1] = name .. ":" .. key end,
  },
  issecretvalue = function() return false end,
  wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
  print = function() end,
  SlashCmdList = {},
  CraftTimersDB = false, -- no saved variables yet
}, { __index = function(_, k) local v = _G[k]; if v ~= nil then return v end return M end })

local chunk = assert(loadfile(path, "t", env))
chunk("CraftTimers")

local function Fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
local function Advance(seconds)
  local stop = clock + seconds
  while clock < stop do
    clock = clock + 0.1
    RunTimers()
  end
end
local function Now() return SERVER0 + math.floor(clock) end

local failed = false
local function Check(label, cond, detail)
  if not cond then failed = true end
  print((cond and "PASS " or "FAIL ") .. label .. (cond and "" or (detail and (": " .. tostring(detail)) or "")))
end

local function Mine() return env.CraftTimersDB.characters["Tess Two"].cds end
local button, list, glow
for i, f in ipairs(frames) do
  if f.kind == "Button" and f.name == "CraftTimersMinimapButton" then button = f end
  if f.kind == "GameTooltip" and f.name == "CraftTimersList" then
    list = f
    -- The glow is the last texture the button made before the list; hidden unless flashing.
    for j = i - 1, 1, -1 do
      if frames[j].kind == "Texture" then glow = frames[j] break end
    end
  end
end
local function IsFlashing() return glow.shown end
local function ListText() return list.shown and table.concat(list.lines, "\n") or "" end
local function Click() button.scripts.OnClick(button) end

Fire("ADDON_LOADED", "CraftTimers")
Fire("PLAYER_LOGIN")
Fire("PLAYER_ENTERING_WORLD", true, false)
Check("registers with AccountLink", linkSpec and linkSpec.name == "crafttimers" and linkSpec.CurrentKey() == "Tess Two")
Advance(6)

-- 1. Dedicated Study cooling down, the Salt Shaker ready.
local study = Mine().s1225469
Check("Dedicated Study recorded with its end", study and math.abs(study.e - (Now() + 22 * 3600 - 6)) <= 2,
  study and (study.e - Now()))
local salt = Mine().i15846
Check("a Salt Shaker in the bags is ready", salt and salt.e == 0 and salt.n == "Salt Shaker")

Advance(1)
Check("the button flashes for the ready Salt Shaker", IsFlashing())
Click()
local text = ListText()
Check("a click shows the list", text:find("Profession cooldowns", 1, true) and text:find("Salt Shaker | Ready", 1, true)
  and text:find("Dedicated Study | 21h", 1, true), text)
Advance(1)
Check("and stops the flashing", not IsFlashing())
Click()
Check("a second click hides the list", ListText() == "")

-- 2. Alchemy: shared transmutes become one line; a 1-hour one and a no-cooldown one don't show.
profession = { name = "Alchemy", recipes = {
  [17187] = { name = "Transmute: Arcanite", learned = true },
  [17563] = { name = "Transmute: Undeath to Water", learned = true },
  [11479] = { name = "Transmute: Iron to Gold", learned = true },
  [11480] = { name = "Transmute: Mithril to Truesilver", learned = false },
  [3170] = { name = "Elixir of Ogre's Strength", learned = true },
} }
Fire("TRADE_SKILL_SHOW")
Advance(1)
Check("nothing cooling down: no recipe lines", Mine().r17187 == nil and Mine().r17563 == nil)
local calls = #linkCalls
profession.recipes[17187].cd = 47 * 3600
profession.recipes[17563].cd = 47 * 3600
profession.recipes[11479].cd = 3600
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 17187)
Fire("TRADE_SKILL_LIST_UPDATE")
Advance(2)
local tm = Mine().r17187
Check("shared transmutes become one line", tm and tm.n == "Transmute" and #tm.m == 2 and Mine().r17563 == nil, tm and tm.n)
Check("the 1-hour transmute isn't tracked", Mine().r11479 == nil)
Check("the other account is told", #linkCalls > calls and linkCalls[#linkCalls] == "crafttimers:Tess Two")
calls = #linkCalls
for _, r in pairs(profession.recipes) do if r.cd then r.cd = r.cd - 5 end end
Fire("TRADE_SKILL_LIST_UPDATE")
Advance(5)
Check("reading the same cooldown again changes nothing", #linkCalls == calls and Mine().r17187.e == tm.e)

-- 3. Someone else's Tailoring (a link) is ignored; your own is read.
profession = { name = "Tailoring", linked = true, recipes = {
  [18560] = { name = "Mooncloth", learned = true, cd = 95 * 3600 },
} }
Fire("TRADE_SKILL_SHOW")
Advance(1)
Check("a linked profession is ignored", Mine().r18560 == nil)
profession.linked = false
Fire("TRADE_SKILL_LIST_UPDATE")
Advance(1)
Check("your own Tailoring: Mooncloth", Mine().r18560 and Mine().r18560.n == "Mooncloth")

-- 4. Charges left and the GetTime wrap.
profession = { name = "Alchemy", recipes = {
  [17187] = { name = "Transmute: Arcanite", learned = true, cd = 40 * 3600 },
  [17563] = { name = "Transmute: Undeath to Water", learned = true, cd = 40 * 3600 },
  [90001] = { name = "Charged Brew", learned = true, cd = 5 * 3600, charges = 1, maxCharges = 2 },
  [90002] = { name = "Wrapped Philter", learned = true, cd = 2 ^ 32 / 1000 + 3 * 3600 },
} }
Fire("TRADE_SKILL_LIST_UPDATE")
Advance(1)
Check("a recipe with a charge left isn't cooling down", Mine().r90001 == nil)
local wrapped = Mine().r90002
Check("a cooldown read 1193 hours too long is corrected", wrapped and math.abs(wrapped.e - (Now() + 3 * 3600)) <= 2,
  wrapped and (wrapped.e - Now()))

-- 5. Time passes: the transmute is ready, the button flashes until clicked.
profession = nil
Advance(41 * 3600)
Check("ready transmute: flashing", IsFlashing())
Click()
Check("the list says so", ListText():find("Transmute | Ready", 1, true), ListText())
Advance(1)
Check("clicked: no flashing", not IsFlashing())
Click()

-- 6. Crafted again: it flashes again once that cooldown ends.
profession = { name = "Alchemy", recipes = {
  [17187] = { name = "Transmute: Arcanite", learned = true, cd = 47 * 3600 },
  [17563] = { name = "Transmute: Undeath to Water", learned = true, cd = 47 * 3600 },
  [90002] = { name = "Wrapped Philter", learned = true },
} }
Fire("TRADE_SKILL_LIST_UPDATE")
Advance(1)
Check("crafted again: cooling down, not flashing", Mine().r17187.e > Now() and not IsFlashing())
profession = nil
Advance(48 * 3600)
Check("ready again: flashing again", IsFlashing())
Click()
Click()

-- 7. The other account's character arrives through AccountLink.
env.CraftTimersDB.characters["Ada One"] = { name = "Ada One", class = "WARRIOR", cds = {
  r1317279 = { n = "Transmute: Legionite", e = Now() - 10, p = "Alchemy", m = { 1317279 } },
} }
linkSpec.OnMirrored("Ada One")
Check("a ready cooldown on the other account flashes", IsFlashing())
Click()
text = ListText()
Check("the list shows both characters, you first", text:find("Tess Two", 1, true)
  and text:find("Ada One", 1, true) and text:find("Tess Two", 1, true) < text:find("Ada One", 1, true)
  and text:find("Transmute: Legionite | Ready", 1, true), text)
Check("AccountLink only takes character records", linkSpec.Valid({ cds = {} }) and not linkSpec.Valid({}))

-- 8. Ended early (a reset): the next reading makes it ready now.
profession = { name = "Alchemy", recipes = {
  [17187] = { name = "Transmute: Arcanite", learned = true, cd = 47 * 3600 },
  [17563] = { name = "Transmute: Undeath to Water", learned = true, cd = 47 * 3600 },
} }
Fire("TRADE_SKILL_LIST_UPDATE")
Advance(1)
profession.recipes[17187].cd = nil
profession.recipes[17563].cd = nil
Fire("TRADE_SKILL_LIST_UPDATE")
Advance(1)
Check("a cooldown that ended early is ready", Mine().r17187.e <= Now())

-- 9. Unlearned: its line goes. Reset clears the character.
profession.recipes[17187].learned = false
profession.recipes[17563].learned = false
Fire("TRADE_SKILL_LIST_UPDATE")
Advance(1)
Check("unlearned recipes' line goes", Mine().r17187 == nil)
env.SlashCmdList.CRAFTTIMERS("reset")
Check("/ct reset clears this character", next(Mine()) == nil)
env.SlashCmdList.CRAFTTIMERS("debug")
print(failed and "FAILED" or "ok")
