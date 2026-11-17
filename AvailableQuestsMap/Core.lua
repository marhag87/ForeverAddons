-- Core.lua
--
-- Settings, events, background loading and the /aqm command.

local ADDON, ns = ...

local Player, Availability, Map, Zones, Tooltip = ns.Player, ns.Availability, ns.Map, ns.Zones, ns.Tooltip

-- QuestieDB's public API contract this addon is written against (LibQuestieDB.RequireContract).
local REQUIRED_CONTRACT = 4

local DEFAULTS = {
  enabled = true,
  showTrivial = false,     -- gray (low level) quests
  showRepeatable = true,
  showEvents = false,      -- holiday / world event quests
  showPvP = true,          -- battleground quests
  showItemQuests = true,   -- quests started by an item, shown where the item drops
  showOnContinent = true,  -- also draw on continent maps, not just zone maps
  showIds = false,         -- quest IDs in tooltips (for /aqm ignore)
  showInTooltip = true,    -- list a quest giver's available quests in their unit tooltip
  iconSize = 16,
}

local function Print(message)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Available Quests Map:|r " .. message)
end

--------------------------------------------------------------------------------------------
-- Updating
--------------------------------------------------------------------------------------------

local lastSignature
local updateQueued, forceQueued = false, false
local availableCount = 0

local function Signature(available)
  local parts = {}
  for i, record in ipairs(available) do
    parts[i] = record.trivial and (record.id .. "t") or record.id
  end
  return table.concat(parts, ",")
end

local function RunUpdate()
  local force = forceQueued
  updateQueued, forceQueued = false, false
  if not Availability.IsBuilt() then return end

  Player.RefreshCompleted()
  Player.RefreshActive()
  local available = Availability.Compute(ns.db)
  availableCount = #available
  Tooltip.SetAvailable(available)

  local signature = Signature(available)
  if force or signature ~= lastSignature then
    lastSignature = signature
    Map.Draw(available, ns.db)
  end
end

--- Recalculate shortly; bursts of events collapse into one update.
---@param delay number? seconds
---@param force boolean? redraw even if the set of quests didn't change
function ns.RequestUpdate(delay, force)
  if force then forceQueued = true end
  if updateQueued then return end
  updateQueued = true
  C_Timer.After(delay or 0.5, RunUpdate)
end

--------------------------------------------------------------------------------------------
-- Background QuestieDB read (spread over frames so login doesn't hitch)
--------------------------------------------------------------------------------------------

local FRAME_BUDGET_MS = 8
local deadline = 0
local buildThread
local runner = CreateFrame("Frame")
runner:Hide()

local function MaybeYield()
  if debugprofilestop() > deadline then coroutine.yield() end
end

local function OnBuilt()
  if Availability.readErrors > 0 then
    Print(("%d quests could not be read from QuestieDB (last error: %s)")
      :format(Availability.readErrors, tostring(Availability.lastError)))
  end
  Player.RefreshSkills(Availability.neededSkills)
  Player.RefreshReputation(Availability.neededFactions)
  ns.RequestUpdate(0, true)
end

runner:SetScript("OnUpdate", function(self)
  deadline = debugprofilestop() + FRAME_BUDGET_MS
  local ok, err = coroutine.resume(buildThread)
  if not ok then
    self:Hide()
    buildThread = nil
    Print("failed to read QuestieDB: " .. tostring(err))
    return
  end
  if coroutine.status(buildThread) == "dead" then
    self:Hide()
    buildThread = nil
    OnBuilt()
  end
end)

local function StartBuild()
  buildThread = coroutine.create(function() Availability.Build(MaybeYield) end)
  runner:Show()
end

--------------------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
  if name ~= ADDON then return end
  AvailableQuestsMapDB = AvailableQuestsMapDB or {}
  local db = AvailableQuestsMapDB
  -- Settings version 2: continent icons became the default; version 1 saved them as off.
  if (db.version or 1) < 2 then db.showOnContinent = nil end
  for key, value in pairs(DEFAULTS) do
    if db[key] == nil then db[key] = value end
  end
  db.ignored = db.ignored or {}
  db.version = 2
  ns.db = db
  ns.AddMapMenuEntries()
end

local GAMEPLAY_EVENTS = {
  "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
  "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED", "UPDATE_FACTION", "LEARNED_SPELL_IN_TAB",
}

function handlers.PLAYER_LOGIN()
  if not (LibQuestieDB and LibQuestieDB.RequireContract) then
    Print("QuestieDB is not loaded. Enable the QuestieDB addon (Questie itself is not needed).")
    return
  end
  local ok, message = LibQuestieDB.RequireContract(REQUIRED_CONTRACT)
  if not ok then
    Print(message)
    return
  end

  ok, message = Zones.Initialize()
  if not ok then
    Print(message)
    return
  end

  ok, message = Player.Initialize()
  if not ok then Print(message) end

  local IsAddOnLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
  if IsAddOnLoaded and IsAddOnLoaded("Questie") then
    Print("Questie is enabled too, so you'll see both sets of icons. You can disable Questie and keep QuestieDB.")
  end

  for _, event in ipairs(GAMEPLAY_EVENTS) do
    -- pcall: registering an event this client doesn't have raises an error.
    pcall(events.RegisterEvent, events, event)
  end
  StartBuild()
end

function handlers.QUEST_LOG_UPDATE()
  if Player.RefreshActive() then ns.RequestUpdate(0.5) end
end

function handlers.QUEST_ACCEPTED()
  ns.RequestUpdate(0.5)
end

function handlers.QUEST_REMOVED()
  ns.RequestUpdate(0.5)
end

function handlers.QUEST_TURNED_IN(questId)
  local record = Availability.GetRecord(questId)
  if not (record and record.repeatable) then Player.MarkTurnedIn(questId) end
  ns.RequestUpdate(0.5)
end

function handlers.PLAYER_LEVEL_UP(level)
  Player.level = level or UnitLevel("player")
  ns.RequestUpdate(0.5)
end

function handlers.SKILL_LINES_CHANGED()
  if Availability.IsBuilt() and Player.RefreshSkills(Availability.neededSkills) then ns.RequestUpdate(1) end
end

function handlers.UPDATE_FACTION()
  if Availability.IsBuilt() and Player.RefreshReputation(Availability.neededFactions) then ns.RequestUpdate(2) end
end

function handlers.LEARNED_SPELL_IN_TAB()
  ns.RequestUpdate(1)
end

events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

--------------------------------------------------------------------------------------------
-- World map "Show:" menu (the filter button at the top of the map)
--------------------------------------------------------------------------------------------

local MAP_MENU_ENTRIES = {
  { "showOnContinent", "Continent Maps" },
  { "showEvents", "Holiday Quests" },
  { "showPvP", "PvP Quests" },
}

local function IsSettingOn(key)
  return ns.db ~= nil and ns.db[key] == true
end

local function ToggleSetting(key)
  ns.db[key] = not ns.db[key]
  ns.RequestUpdate(0, true)
end

function ns.AddMapMenuEntries()
  if not (Menu and Menu.ModifyMenu) then return end
  Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", function(_, rootDescription)
    rootDescription:CreateDivider()
    rootDescription:CreateTitle("Available Quests")
    for _, entry in ipairs(MAP_MENU_ENTRIES) do
      rootDescription:CreateCheckbox(entry[2], IsSettingOn, ToggleSetting, entry[1])
    end
  end)
end

--------------------------------------------------------------------------------------------
-- /aqm
--------------------------------------------------------------------------------------------

local TOGGLES = {
  toggle = { "enabled", "Map icons" },
  trivial = { "showTrivial", "Low-level (gray) quests" },
  repeatable = { "showRepeatable", "Repeatable quests" },
  events = { "showEvents", "Holiday and world event quests" },
  items = { "showItemQuests", "Quests started by items" },
  pvp = { "showPvP", "PvP (battleground) quests" },
  continent = { "showOnContinent", "Icons on continent maps" },
  ids = { "showIds", "Quest IDs in tooltips" },
  tooltip = { "showInTooltip", "Quests in quest giver tooltips" },
}

local function OnOff(value)
  return value and "|cff20ff20on|r" or "|cffff2020off|r"
end

local function QuestLabel(questId)
  local ok, name = pcall(LibQuestieDB.Quest.Get, questId, "name")
  return ("%s (%d)"):format((ok and name) or "?", questId)
end

local function Help()
  local db = ns.db
  Print(("%d quests available, %d of them on the map (%d icons)."):format(
    availableCount, Map.questCount, Map.placeCount))
  Print("/aqm toggle - map icons " .. OnOff(db.enabled))
  Print("/aqm trivial - low-level quests " .. OnOff(db.showTrivial))
  Print("/aqm repeatable - repeatable quests " .. OnOff(db.showRepeatable))
  Print("/aqm events - holiday/event quests " .. OnOff(db.showEvents))
  Print("/aqm items - quests started by items " .. OnOff(db.showItemQuests))
  Print("/aqm pvp - battleground quests " .. OnOff(db.showPvP))
  Print("/aqm continent - icons on continent maps " .. OnOff(db.showOnContinent))
  Print("/aqm ids - quest IDs in tooltips " .. OnOff(db.showIds))
  Print("/aqm tooltip - quests in quest giver tooltips " .. OnOff(db.showInTooltip))
  Print("/aqm size <8-40> - icon size (" .. db.iconSize .. ")")
  Print("/aqm ignore <questID>, /aqm unignore <questID>, /aqm ignored")
end

SLASH_AVAILABLEQUESTSMAP1 = "/aqm"
SlashCmdList.AVAILABLEQUESTSMAP = function(input)
  local db = ns.db
  if not db then return end
  local command, argument = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  command = command:lower()

  local toggle = TOGGLES[command]
  if toggle then
    db[toggle[1]] = not db[toggle[1]]
    Print(toggle[2] .. ": " .. OnOff(db[toggle[1]]))
    ns.RequestUpdate(0, true)
  elseif command == "size" then
    local size = tonumber(argument)
    if size and size >= 8 and size <= 40 then
      db.iconSize = math.floor(size)
      Print("Icon size: " .. db.iconSize)
      ns.RequestUpdate(0, true)
    else
      Print("Usage: /aqm size <8-40>")
    end
  elseif command == "ignore" or command == "unignore" then
    local questId = tonumber(argument)
    if not questId then
      Print("Usage: /aqm " .. command .. " <questID>  (turn on /aqm ids to see IDs in tooltips)")
      return
    end
    db.ignored[questId] = (command == "ignore") or nil
    Print((command == "ignore" and "Ignoring " or "No longer ignoring ") .. QuestLabel(questId))
    ns.RequestUpdate(0, true)
  elseif command == "ignored" then
    local any = false
    for questId in pairs(db.ignored) do
      any = true
      Print("Ignored: " .. QuestLabel(questId))
    end
    if not any then Print("No ignored quests.") end
  elseif command == "refresh" then
    ns.RequestUpdate(0, true)
  else
    Help()
  end
end
