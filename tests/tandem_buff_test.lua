-- Tandem mock: the set buff. /tandem buff asks Upkeep to keep a buff up while your set is
-- active and you aren't paused, and to stop otherwise. Sets and Util are stubs; only
-- Tandem.lua is loaded. Asserts (PASS/FAIL).
local path = ...

local M -- a value that can be called or indexed without end
M = setmetatable({}, { __index = function() return M end, __call = function() return nil end })

local frames = {}
local function NewFrame()
  local f = { scripts = {} }
  setmetatable(f, { __index = function(_, method)
    if method == "SetScript" then return function(self, s, fn) self.scripts[s] = fn end end
    return function() end
  end })
  frames[#frames + 1] = f
  return f
end

local calls = {}  -- what Upkeep was asked, in order
local printed = {}
local activeSet  -- the set Sets.Active reports, or nil
local db = { features = { sound = false, loot = false, invite = false, focus = false } }
local chardb = {}

local SPELLS = { ["righteous fury"] = { spellID = 25780, name = "Righteous Fury" } }

local env = setmetatable({
  CreateFrame = NewFrame,
  C_ChatInfo = { RegisterAddonMessagePrefix = function() end },
  C_Spell = {
    GetSpellInfo = function(name) return SPELLS[name:lower()] end,
    GetSpellName = function(id) return id == 25780 and "Righteous Fury" or nil end,
    GetSpellTexture = function(id) return id end,
  },
  C_AddOns = { GetAddOnMetadata = function() return "test" end },
  C_Timer = { After = function() end, NewTimer = function() return {} end },
  IsPlayerSpell = function(id) return id == 25780 end,
  GetTime = function() return 0 end,
  GetCVar = function() return "1" end,
  SetCVar = function() end,
  IsInGroup = function() return false end,
  GetNumShapeshiftForms = function() return 0 end,
  print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end,
  SlashCmdList = {},
  Upkeep = {
    AddReminder = function() end,
    RemoveReminder = function() end,
    KeepBuff = function(id, wanted) calls[#calls + 1] = id .. (wanted and " on" or " off") end,
  },
}, { __index = function(_, k) local v = _G[k]; if v ~= nil then return v end return M end })

local ns = {
  Util = {
    PREFIX = "Tandem",
    Print = function(msg) printed[#printed + 1] = msg end,
    Debug = function() end,
    IsHidden = function() return false end,
    UnitOf = function() return nil end,
    Norm = function(name) return name:lower() end,
    GroupMembers = function() return {}, true end,
  },
  Sets = {
    Init = function() return db, chardb end,
    Start = function() end,
    Active = function() if activeSet then return "set1", activeSet end end,
    IsMain = function() return true end,
    AllShareASet = function() return true end,
    Mine = function() return {} end,
    Others = function() return {} end,
    Describe = function() return "" end,
    AnnounceAll = function() end,
    OnMessage = function() end,
    online = {},
  },
}

local chunk = assert(loadfile(path, "t", env))
chunk("Tandem", ns)

local function Fire(event, ...)
  for _, f in ipairs(frames) do
    if f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
local function Slash(msg) env.SlashCmdList.TANDEM(msg) end

local failed = false
local function Check(label, want)
  local got = table.concat(calls, ", ")
  calls = {}
  local cond = got == want
  if not cond then failed = true end
  print((cond and "PASS " or "FAIL ") .. label .. (cond and "" or (": got [" .. got .. "], want [" .. want .. "]")))
end

Fire("PLAYER_LOGIN")
Fire("PLAYER_ENTERING_WORLD", true, false)
Check("no set buff: Upkeep isn't asked", "")
Slash("buff Righteous Fury")
Check("set buff chosen, set not active", "")
activeSet = { main = "Main" }
ns.Changed()
Check("set active: keep it up", "25780 on")
ns.Changed()
Check("asked only once", "")
Slash("pause")
Check("paused: stop", "25780 off")
Slash("resume")
Check("resumed: keep it up", "25780 on")
activeSet = nil
ns.Changed()
Check("set no longer active: stop", "25780 off")
activeSet = { main = "Main" }
ns.Changed()
calls = {}
Slash("buff off")
Check("buff off: stop", "25780 off")
Slash("buff Nonsense")
Check("an unknown spell changes nothing", "")
Slash("buff Righteous Fury")
Check("chosen while the set is active: at once", "25780 on")
printed = {}
Slash("")
local status = table.concat(printed, "\n")
local cond = status:find("set buff: Righteous Fury, kept up now", 1, true) ~= nil
if not cond then failed = true end
print((cond and "PASS " or "FAIL ") .. "status names the set buff")
print(failed and "FAILED" or "ok")
