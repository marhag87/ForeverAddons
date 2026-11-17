-- Zones.lua
--
-- QuestieDB stores spawn positions per AreaTable ID (0-100 percent coordinates). The world
-- map works in UiMapIDs, so this file turns QuestieDB's zone support data into that lookup.

local _, ns = ...

local Zones = {}
ns.Zones = Zones

local areaToUiMap = {}
local subZoneToParent = {}
local dungeons = {}
local dungeonAlias = {} -- alternative dungeon AreaID -> dungeon AreaID

-- QuestieDB ships these maps as "return { ... }" source strings; accept plain tables too.
local function Decode(value)
  if type(value) == "table" then return value end
  if type(value) ~= "string" then return nil end
  local chunk = loadstring(value)
  if not chunk then return nil end
  local ok, result = pcall(chunk)
  if ok and type(result) == "table" then return result end
  return nil
end

local function Merge(base, override)
  for k, v in pairs(override or {}) do base[k] = v end
  return base
end

---@return boolean ok
---@return string? problem
function Zones.Initialize()
  local support = LibQuestieDB.Support
  local zoneDB = support and support.Get and support.Get("ZoneDB")
  local data = zoneDB and zoneDB.private
  if type(data) ~= "table" then
    return false, "QuestieDB has no zone data (Support.Get(\"ZoneDB\"))."
  end

  areaToUiMap = Merge(Decode(data.areaIdToUiMapId) or {}, Decode(data.areaIdToUiMapIdOverride))
  subZoneToParent = Merge(Decode(data.subZoneToParentZone) or {}, Decode(data.subZoneToParentZoneOverride))
  dungeons = type(data.dungeons) == "table" and data.dungeons or {}

  for dungeonAreaId, entry in pairs(dungeons) do
    if type(entry) == "table" and type(entry[2]) == "table" then
      for _, alias in ipairs(entry[2]) do dungeonAlias[alias] = dungeonAreaId end
    end
  end

  if not next(areaToUiMap) then
    return false, "QuestieDB's AreaID -> UiMapID table is empty or unreadable."
  end
  return true
end

---@param areaId number
---@return number? uiMapId
function Zones.UiMapFor(areaId)
  local uiMapId = areaToUiMap[areaId]
  if not uiMapId or uiMapId == 0 then
    local parent = subZoneToParent[areaId]
    uiMapId = parent and areaToUiMap[parent]
  end
  if uiMapId and uiMapId ~= 0 then return uiMapId end
  return nil
end

--- Call fn(uiMapId, x, y) for every world-map position of one spawn. Spawns inside an
--- instance are stored as (-1, -1); those are drawn at the dungeon entrance instead.
---@param areaId number
---@param x number
---@param y number
---@param fn fun(uiMapId: number, x: number, y: number)
function Zones.ForEachPosition(areaId, x, y, fn)
  if x == -1 or y == -1 then
    local entry = dungeons[areaId] or dungeons[dungeonAlias[areaId]]
    local entrances = entry and entry[4]
    if type(entrances) ~= "table" then return end
    for _, location in ipairs(entrances) do
      local uiMapId = Zones.UiMapFor(location[1])
      if uiMapId then fn(uiMapId, location[2], location[3]) end
    end
    return
  end

  local uiMapId = Zones.UiMapFor(areaId)
  if uiMapId then fn(uiMapId, x, y) end
end
