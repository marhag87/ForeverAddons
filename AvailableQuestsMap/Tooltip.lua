-- Tooltip.lua
--
-- Hovering a quest giver lists the quests you can pick up from them, with level and name,
-- using the same list and filters as the map icons.

local _, ns = ...

local Map = ns.Map

local Tooltip = {}
ns.Tooltip = Tooltip

local LINE_PREFIX = "|TInterface\\GossipFrame\\AvailableQuestIcon:0|t "

local questsByNpc = {} -- npc ID -> available quest records, sorted by level

--- Called after every availability update with the full list of available quests.
---@param available table[]
function Tooltip.SetAvailable(available)
  local index = {}
  for _, record in ipairs(available) do
    if record.npcs then
      for _, npcId in ipairs(record.npcs) do
        local list = index[npcId]
        if not list then
          list = {}
          index[npcId] = list
        end
        list[#list + 1] = record
      end
    end
  end
  for _, list in pairs(index) do
    table.sort(list, Map.SortByLevel)
  end
  questsByNpc = index
end

local function NpcIdFromGuid(guid)
  -- Unit GUIDs are secret in some instances; there's nothing to show there anyway.
  if (issecretvalue and issecretvalue(guid)) or type(guid) ~= "string" then return nil end
  local unitType, _, _, _, _, npcId = strsplit("-", guid)
  if unitType ~= "Creature" and unitType ~= "Vehicle" then return nil end
  return tonumber(npcId)
end

local function AddLines(tooltip, guid)
  if not (ns.db and ns.db.showInTooltip) then return end
  local npcId = NpcIdFromGuid(guid)
  local quests = npcId and questsByNpc[npcId]
  if not quests then return end
  Map.AddQuestLines(tooltip, quests, LINE_PREFIX)
  tooltip:Show() -- resize to fit the new lines
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
    if tooltip ~= GameTooltip then return end
    AddLines(tooltip, data and data.guid)
  end)
else
  GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
    local _, unit = tooltip:GetUnit()
    if unit then AddLines(tooltip, UnitGUID(unit)) end
  end)
end
