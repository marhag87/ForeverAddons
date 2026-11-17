-- Map.lua
--
-- Draws the world map icons through HereBeDragons-Pins:
--   * one "!" per quest giver position, with a tooltip listing that giver's quests;
--   * one "!" with a small item badge per area where a quest-starting item drops,
--     with a tooltip naming the item, the quest it starts and who drops it.

local ADDON, ns = ...

local Availability, Player, Zones = ns.Availability, ns.Player, ns.Zones

local HBDPins = LibStub("HereBeDragons-Pins-2.0")
local SHOW_PARENT = HBD_PINS_WORLDMAP_SHOW_PARENT or 1
local SHOW_CONTINENT = HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2

local Map = {}
ns.Map = Map

local ICON_TEXTURE = "Interface\\GossipFrame\\AvailableQuestIcon"
local FALLBACK_ITEM_ICON = "Interface\\Icons\\INV_Misc_Note_01"

-- Quest givers: nearby spawns of one giver share an icon.
local GIVER_MAX_POSITIONS = 25
local GIVER_SPACING = 1.5 -- map percent

-- Item drops: all spawns of the droppers are grouped into areas, one icon per area.
local DROPPER_MAX_POSITIONS = 150
local DROPPER_SPACING = 3
local DROP_AREA_RADIUS = 8   -- map percent
local MAX_DROPPERS = 20      -- more than this is a world drop; icons everywhere help nobody
local MAX_NAMES_IN_TOOLTIP = 4

-- Continent maps show every zone's icons at once, so draw them a bit smaller there.
local CONTINENT_SCALE = 0.75

local abs = math.abs
local freeIcons, usedIcons = {}, {}
local placeCache = {} -- "npc123" / "dropnpc123" / ... -> { name, faction, positions } or false
local itemCache = {}  -- itemId -> item info or false

Map.placeCount = 0
Map.questCount = 0

--------------------------------------------------------------------------------------------
-- QuestieDB lookups (cached; spawn data never changes during a session)
--------------------------------------------------------------------------------------------

local function LoadPlace(kind, id, maxPositions, spacing)
  local entity = kind == "npc" and LibQuestieDB.Npc or LibQuestieDB.Object
  local spawns = entity.Get(id, "spawns")
  if type(spawns) ~= "table" then return nil end

  local positions = {}
  local function Add(uiMapId, x, y)
    if #positions >= maxPositions then return end
    for i = 1, #positions do
      local p = positions[i]
      if p[1] == uiMapId and abs(p[2] - x) < spacing and abs(p[3] - y) < spacing then return end
    end
    positions[#positions + 1] = { uiMapId, x, y }
  end

  for areaId, list in pairs(spawns) do
    if type(list) == "table" then
      for _, coords in ipairs(list) do
        local x, y = coords[1], coords[2]
        if type(x) == "number" and type(y) == "number" then
          Zones.ForEachPosition(areaId, x, y, Add)
        end
      end
    end
  end
  if not positions[1] then return nil end

  return {
    name = entity.Get(id, "name") or "?",
    faction = kind == "npc" and entity.Get(id, "friendlyToFaction") or nil,
    positions = positions,
  }
end

--- A quest giver or item dropper with its world map positions, or nil if it has none.
---@param kind "npc"|"object"
---@param forDrops boolean? droppers keep more, coarser positions for area grouping
local function GetPlace(kind, id, forDrops)
  local key = (forDrops and "drop" or "") .. kind .. id
  local place = placeCache[key]
  if place == nil then
    local ok, result
    if forDrops then
      ok, result = pcall(LoadPlace, kind, id, DROPPER_MAX_POSITIONS, DROPPER_SPACING)
    else
      ok, result = pcall(LoadPlace, kind, id, GIVER_MAX_POSITIONS, GIVER_SPACING)
    end
    place = ok and result or false
    placeCache[key] = place
  end
  return place or nil
end

local function IsHostile(place)
  local mine = Player.factionLetter
  return mine ~= nil and (place.faction == "A" or place.faction == "H") and place.faction ~= mine
end

local function ItemIcon(itemId)
  local icon
  if C_Item and C_Item.GetItemIconByID then
    icon = C_Item.GetItemIconByID(itemId)
  elseif GetItemIcon then
    icon = GetItemIcon(itemId)
  end
  return icon or FALLBACK_ITEM_ICON
end

local function LoadItem(itemId)
  local Item = LibQuestieDB.Item
  local npcDrops = Item.Get(itemId, "npcDrops") or {}
  local objectDrops = Item.Get(itemId, "objectDrops") or {}
  local vendors = Item.Get(itemId, "vendors") or {}

  local item = {
    id = itemId,
    name = Item.Get(itemId, "name") or ("Item #" .. itemId),
    icon = ItemIcon(itemId),
    sources = {},
  }
  if #npcDrops + #objectDrops > MAX_DROPPERS then
    item.worldDrop = true
    return item
  end

  local function AddSources(ids, kind, how)
    for _, id in ipairs(ids) do
      local place = GetPlace(kind, id, true)
      -- Mobs are hostile by nature; only vendors must be on our side.
      if place and not (how == "vendor" and IsHostile(place)) then
        item.sources[#item.sources + 1] = { place = place, how = how }
      end
    end
  end
  AddSources(npcDrops, "npc", "drop")
  AddSources(objectDrops, "object", "object")
  AddSources(vendors, "npc", "vendor")
  return item
end

local function GetItem(itemId)
  local item = itemCache[itemId]
  if item == nil then
    local ok, result = pcall(LoadItem, itemId)
    item = ok and result or false
    itemCache[itemId] = item
  end
  return item or nil
end

--------------------------------------------------------------------------------------------
-- Tooltips
--------------------------------------------------------------------------------------------

local COLORS = {
  Trivial = { 0.75, 0.75, 0.75 },
  Easy = { 0.25, 0.75, 0.25 },
  Fair = { 1, 1, 0 },
  Difficult = { 1, 0.5, 0.25 },
  Impossible = { 1, 0.1, 0.1 },
}
local colorByDifficulty = {}
if Enum and Enum.RelativeContentDifficulty then
  for name, color in pairs(COLORS) do
    local value = Enum.RelativeContentDifficulty[name]
    if value then colorByDifficulty[value] = color end
  end
end

local function DifficultyColor(questId, level)
  -- Forever knows each quest's difficulty once the quest data is cached.
  if C_PlayerInfo and C_PlayerInfo.GetContentDifficultyQuestForPlayer and HaveQuestData and HaveQuestData(questId) then
    local color = colorByDifficulty[C_PlayerInfo.GetContentDifficultyQuestForPlayer(questId)]
    if color then return color[1], color[2], color[3] end
  end
  local diff = level - Player.level
  local color = (diff >= 5 and COLORS.Impossible) or (diff >= 3 and COLORS.Difficult)
    or (diff >= -2 and COLORS.Fair) or (-diff <= Player.GreenRange() and COLORS.Easy) or COLORS.Trivial
  return color[1], color[2], color[3]
end

local function AddQuestLines(tooltip, quests, indent)
  for _, record in ipairs(quests) do
    local level = record.displayLevel or record.level
    local r, g, b = DifficultyColor(record.id, level)
    local left = ("%s[%d] %s"):format(indent or "", level, Availability.GetName(record))
    local right = record.repeatable and "Repeatable" or ""
    if ns.db.showIds then
      right = (right ~= "" and (right .. "  ") or "") .. "|cff9d9d9d" .. record.id .. "|r"
    end
    tooltip:AddDoubleLine(left, right, r, g, b, 0.4, 0.75, 1)
  end
end
Map.AddQuestLines = AddQuestLines

local SOURCE_LABELS = { drop = "Dropped by", object = "Looted from", vendor = "Sold by" }

local function AddSourceLines(tooltip, sources)
  for _, how in ipairs({ "drop", "object", "vendor" }) do
    local names = sources[how]
    if names and names[1] then
      local text = table.concat(names, ", ", 1, math.min(#names, MAX_NAMES_IN_TOOLTIP))
      if #names > MAX_NAMES_IN_TOOLTIP then
        text = text .. (" and %d more"):format(#names - MAX_NAMES_IN_TOOLTIP)
      end
      tooltip:AddLine("   " .. SOURCE_LABELS[how] .. " " .. text, 0.7, 0.7, 0.7, true)
    end
  end
end

local function Icon_OnEnter(self)
  local data = self.data
  if not data then return end
  local tooltip = GameTooltip
  tooltip:SetOwner(self, "ANCHOR_RIGHT")

  if data.kind == "giver" then
    tooltip:SetText(data.place.name, 1, 1, 1)
    AddQuestLines(tooltip, data.quests)
  else
    for i, entry in ipairs(data.entries) do
      local line = ("|T%s:0|t %s"):format(entry.item.icon, entry.item.name)
      if i == 1 then tooltip:SetText(line, 1, 1, 1) else tooltip:AddLine(line, 1, 1, 1) end
      AddQuestLines(tooltip, entry.quests, "   ")
      AddSourceLines(tooltip, entry.sources)
    end
  end
  tooltip:Show()
end

local function Icon_OnLeave()
  GameTooltip:Hide()
end

local function ShowingContinent()
  local mapId = WorldMapFrame and WorldMapFrame:GetMapID()
  local info = mapId and C_Map.GetMapInfo(mapId)
  return info ~= nil and Enum.UIMapType ~= nil and info.mapType == Enum.UIMapType.Continent
end

-- HereBeDragons hides and re-shows every icon when the map changes, so this runs per map.
local function Icon_OnShow(self)
  self:SetScale(ShowingContinent() and CONTINENT_SCALE or 1)
end

--------------------------------------------------------------------------------------------
-- Icons
--------------------------------------------------------------------------------------------

local function AcquireIcon()
  local icon = table.remove(freeIcons)
  if not icon then
    icon = CreateFrame("Frame", nil, UIParent)
    local texture = icon:CreateTexture(nil, "ARTWORK")
    texture:SetAllPoints()
    texture:SetTexture(ICON_TEXTURE)
    icon.texture = texture

    -- Item-started quests: the item's icon in the lower right corner.
    local badge = icon:CreateTexture(nil, "OVERLAY")
    badge:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 3, -3)
    badge:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon.badge = badge

    icon:EnableMouse(true)
    -- Hover for the tooltip, but let clicks through so the map still zooms/pans.
    if icon.SetMouseClickEnabled then icon:SetMouseClickEnabled(false) end
    icon:SetScript("OnEnter", Icon_OnEnter)
    icon:SetScript("OnLeave", Icon_OnLeave)
    icon:SetScript("OnShow", Icon_OnShow)
    icon:Hide() -- HereBeDragons shows it once its map is displayed
  end
  usedIcons[#usedIcons + 1] = icon
  return icon
end

local function StyleIcon(icon, style, size, badgeTexture)
  icon:SetSize(size, size)
  local texture = icon.texture
  if style == "normal" then
    texture:SetDesaturated(false)
    texture:SetVertexColor(1, 1, 1)
  elseif style == "repeatable" then
    texture:SetDesaturated(true)
    texture:SetVertexColor(0.35, 0.7, 1)
  else -- trivial
    texture:SetDesaturated(true)
    texture:SetVertexColor(0.75, 0.75, 0.75)
  end

  if badgeTexture then
    icon.badge:SetTexture(badgeTexture)
    icon.badge:SetSize(size * 0.6, size * 0.6)
    icon.badge:Show()
  else
    icon.badge:Hide()
  end
end

--- "normal" if any quest is a regular, non-gray one; else "repeatable"; else "trivial".
local function StyleFor(quests, style)
  for _, record in ipairs(quests) do
    if not record.trivial then
      if not record.repeatable then return "normal" end
      style = "repeatable"
    end
  end
  return style or "trivial"
end

function Map.Clear()
  HBDPins:RemoveAllWorldMapIcons(ADDON)
  for i = #usedIcons, 1, -1 do
    local icon = usedIcons[i]
    icon.data = nil
    icon:Hide()
    freeIcons[#freeIcons + 1] = icon
    usedIcons[i] = nil
  end
  Map.placeCount = 0
  Map.questCount = 0
end

--------------------------------------------------------------------------------------------
-- Building what to draw
--------------------------------------------------------------------------------------------

local function SortByLevel(a, b)
  local la, lb = a.displayLevel or a.level, b.displayLevel or b.level
  if la ~= lb then return la < lb end
  return a.id < b.id
end
Map.SortByLevel = SortByLevel

local function AddUnique(list, set, value)
  if not set[value] then
    set[value] = true
    list[#list + 1] = value
  end
end

--- Quest givers: one entry per NPC/object, listing every available quest it gives.
local function CollectGivers(available, drawn)
  local byPlace, givers = {}, {}

  local function Collect(kind, ids, record)
    if not ids then return end
    for i = 1, #ids do
      local key = kind .. ids[i]
      local giver = byPlace[key]
      if giver == nil then
        local place = GetPlace(kind, ids[i])
        giver = (place and not IsHostile(place)) and { kind = "giver", place = place, quests = {} } or false
        byPlace[key] = giver
        if giver then givers[#givers + 1] = giver end
      end
      if giver then
        giver.quests[#giver.quests + 1] = record
        drawn[record] = true
      end
    end
  end

  for _, record in ipairs(available) do
    Collect("npc", record.npcs, record)
    Collect("object", record.objects, record)
  end
  return givers
end

--- Item drops: every spawn of every source of a quest-starting item is grouped into areas
--- (per map), so a mob camp gets one icon however many spawns or mob types it has.
local function CollectDropAreas(available, drawn)
  local areas, areasByMap = {}, {}

  local function AreaAt(uiMapId, x, y)
    local list = areasByMap[uiMapId]
    if not list then
      list = {}
      areasByMap[uiMapId] = list
    end
    for _, area in ipairs(list) do
      if abs(area.seedX - x) < DROP_AREA_RADIUS and abs(area.seedY - y) < DROP_AREA_RADIUS then
        return area
      end
    end
    local area = { kind = "drop", uiMapId = uiMapId, seedX = x, seedY = y, sumX = 0, sumY = 0, count = 0,
      entries = {}, byItem = {} }
    list[#list + 1] = area
    areas[#areas + 1] = area
    return area
  end

  for _, record in ipairs(available) do
    if record.items then
      for _, itemId in ipairs(record.items) do
        local item = GetItem(itemId)
        if item and not item.worldDrop then
          for _, source in ipairs(item.sources) do
            for _, position in ipairs(source.place.positions) do
              local area = AreaAt(position[1], position[2], position[3])
              area.sumX, area.sumY, area.count = area.sumX + position[2], area.sumY + position[3], area.count + 1

              local entry = area.byItem[itemId]
              if not entry then
                entry = { item = item, quests = {}, questSet = {}, sources = {}, sourceSet = {} }
                area.byItem[itemId] = entry
                area.entries[#area.entries + 1] = entry
              end
              AddUnique(entry.quests, entry.questSet, record)
              local names = entry.sources[source.how]
              if not names then
                names = {}
                entry.sources[source.how] = names
              end
              AddUnique(names, entry.sourceSet, source.place.name)
              drawn[record] = true
            end
          end
        end
      end
    end
  end
  return areas
end

---@param available table[] records from Availability.Compute
---@param db table saved settings
function Map.Draw(available, db)
  Map.Clear()
  if not db.enabled then return end

  local showFlag = db.showOnContinent and SHOW_CONTINENT or SHOW_PARENT
  local size = db.iconSize
  local drawn = {}
  local places = 0

  for _, giver in ipairs(CollectGivers(available, drawn)) do
    table.sort(giver.quests, SortByLevel)
    local style = StyleFor(giver.quests)
    for _, position in ipairs(giver.place.positions) do
      local icon = AcquireIcon()
      icon.data = giver
      StyleIcon(icon, style, size)
      HBDPins:AddWorldMapIconMap(ADDON, icon, position[1], position[2] / 100, position[3] / 100, showFlag)
      places = places + 1
    end
  end

  if db.showItemQuests then
    for _, area in ipairs(CollectDropAreas(available, drawn)) do
      local style
      for _, entry in ipairs(area.entries) do
        table.sort(entry.quests, SortByLevel)
        if style ~= "normal" then
          style = StyleFor(entry.quests, style ~= "trivial" and style or nil)
        end
      end
      local icon = AcquireIcon()
      icon.data = area
      StyleIcon(icon, style, size, area.entries[1].item.icon)
      HBDPins:AddWorldMapIconMap(ADDON, icon, area.uiMapId,
        area.sumX / area.count / 100, area.sumY / area.count / 100, showFlag)
      places = places + 1
    end
  end

  local quests = 0
  for _ in pairs(drawn) do quests = quests + 1 end
  Map.placeCount = places
  Map.questCount = quests
end
