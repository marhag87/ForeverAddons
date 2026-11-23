-- Replays OpenMap's combat view against AvailableQuestsMap's Map.lua: an icon given back to
-- UIParent must stay hidden, one given back to a map pin must show.
local path, reparentFiresOnShow = ...
reparentFiresOnShow = reparentFiresOnShow == "onshow"

local Frame = {}
Frame.__index = Frame
local function Visible(f)
  if not f then return true end
  return f.shown and Visible(f.parent)
end
local function Fire(f, wasVisible)
  if not wasVisible and Visible(f) and f.scripts.OnShow then f.scripts.OnShow(f) end
end
function Frame:Show() local was = Visible(self) self.shown = true Fire(self, was) end
function Frame:Hide() self.shown = false end
function Frame:IsShown() return self.shown end
function Frame:GetParent() return self.parent end
function Frame:SetParent(p)
  local was = Visible(self)
  self.parent = p
  if reparentFiresOnShow then Fire(self, was) end
end
function Frame:SetScript(s, fn) self.scripts[s] = fn end
function Frame:CreateTexture() return setmetatable({}, { __index = function() return function() end end }) end
setmetatable(Frame, { __index = function() return function() end end })
local function NewFrame(_, _, parent)
  return setmetatable({ shown = true, parent = parent, scripts = {} }, Frame)
end

local UIParent = NewFrame("Frame")
UIParent.parent = false
local icons = {}
local env = setmetatable({
  CreateFrame = NewFrame,
  UIParent = UIParent,
  hooksecurefunc = function(t, key, fn)
    local orig = t[key]
    rawset(t, key, function(...) local r = orig(...) fn(...) return r end)
  end,
  LibStub = function() return {
    AddWorldMapIconMap = function(_, _, icon) icons[#icons + 1] = icon end,
    RemoveAllWorldMapIcons = function() end,
  } end,
  LibQuestieDB = { Npc = { Get = function(id, field)
    if field == "spawns" then return { [1] = { { 50, 50 } } } end
    if field == "name" then return "Giver " .. id end
  end } },
  WorldMapFrame = { GetMapID = function() return 1429 end },
  C_Map = { GetMapInfo = function() return { mapType = 3 } end },
  Enum = { UIMapType = { Continent = 2 } },
}, { __index = _G })

local ns = {
  Availability = { GetName = function(r) return "Quest " .. r.id end },
  Player = { factionLetter = "A", level = 10, GreenRange = function() return 5 end },
  Zones = { ForEachPosition = function(_, x, y, add) add(1429, x, y) end },
}
assert(loadfile(path, "t", env))("AvailableQuestsMap", ns)
ns.Map.Draw({ { id = 1, level = 5, npcs = { 101 } }, { id = 2, level = 6, npcs = { 202 } } },
  { enabled = true, iconSize = 16 })
local here, there = icons[1], icons[2]
local function State(label)
  print(("%-44s here %s on %s   there %s on %s"):format(label,
    tostring(here:IsShown()), here.parent == UIParent and "UIParent" or here.parent.name,
    tostring(there:IsShown()), there.parent == UIParent and "UIParent" or there.parent.name))
end
State("drawn")

-- HereBeDragons puts the icon of this zone on a pin of the open map.
local map = NewFrame("Frame", nil, UIParent) map.name = "map"
local pin = NewFrame("Frame", nil, map) pin.name = "pin"
here:SetParent(pin) here:ClearAllPoints() here:SetPoint("CENTER", pin) here:Show()
State("map open")

-- A fight: OpenMap's own view takes both, the other zone's from UIParent.
local layer = NewFrame("Frame", nil, map) layer.name = "layer"
local moved = {}
for _, icon in ipairs({ here, there }) do
  moved[icon] = icon:GetParent()
  icon:SetParent(layer) icon:ClearAllPoints() icon:SetPoint("CENTER", layer) icon:Show()
end
State("in combat, on OpenMap's view")

-- The map closes in combat: OpenMap gives them back, shown if the parent is.
map:Hide()
for icon, parent in pairs(moved) do
  icon:ClearAllPoints()
  icon:SetParent(parent)
  icon:SetPoint("CENTER", parent, "CENTER")
  if parent:IsShown() then icon:Show() else icon:Hide() end
end
State("map closed, icons given back")
print(Visible(there) and "LEFTOVER on screen" or "no leftover")
-- And the next time the map opens, the pinned one still shows.
map:Show()
print("map reopened, pinned icon visible:", tostring(Visible(here)))
print((not Visible(there) and Visible(here)) and "ok" or "FAILED")
