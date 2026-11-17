--[[
	GatherReference
	Read-only display of Wowhead gathering node data on the world map and minimap.
	Node data is read from the GatherMate2_Data addon (load on demand), which is loaded
	on every login; nothing is imported into saved variables. Only the per-profession
	toggles are saved.
]]
local addonName, ns = ...

local HBD = LibStub("HereBeDragons-2.0")

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt
local math_sin, math_cos = math.sin, math.cos
local pairs, next, format = pairs, next, string.format

local WORLD_PIN_SIZE = 12
local MINI_PIN_SIZE = 12 * 0.75
local TRACK_CIRCLE_SIZE = 12
local TRACK_DISTANCE = 100    -- yards; closer nodes are drawn as a ring, like GatherMate2
local TRACK_CIRCLE = [[Interface\AddOns\GatherReference\Artwork\track_circle.tga]]
local NODE_RANGE = 2          -- scan radius for minimap pins, in minimap radii
local FULL_SCAN_INTERVAL = 2  -- seconds between full minimap rescans

--[[
	Node types, in button order
]]
local types = {
	{ key = "Herb",     label = "Herbalism", icon = [[Interface\Icons\Trade_Herbalism]], global = "GatherMateData2HerbDB",     color = { 0, 1, 0 } },
	{ key = "Mine",     label = "Mining",    icon = [[Interface\Icons\Trade_Mining]],    global = "GatherMateData2MineDB",     color = { 1, 0, 0 } },
	{ key = "Fish",     label = "Fishing",   icon = [[Interface\Icons\Trade_Fishing]],   global = "GatherMateData2FishDB",     color = { 1, 1, 0 } },
	{ key = "Treasure", label = "Treasure",  icon = [[Interface\Icons\INV_Box_02]],      global = "GatherMateData2TreasureDB", color = { 1, 0, 1 } },
}

local DATA_ADDON = "GatherMate2_Data"

--[[
	Load GatherMate2_Data and keep references to its tables. The globals are left alone so
	GatherMate2 can still import them; its import clears them afterwards, which is why we
	hold our own references. Types without any data are dropped.
]]
local function LoadData()
	local LoadAddOn = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
	local loaded, reason = LoadAddOn(DATA_ADDON)
	if not loaded then
		print(format("|cff33ff99GatherReference|r: could not load %s (%s).", DATA_ADDON, reason and _G["ADDON_" .. reason] or reason or "unknown"))
	end
	for i = #types, 1, -1 do
		local db = _G[types[i].global]
		if type(db) == "table" and next(db) then
			types[i].db = db
		else
			table.remove(types, i)
		end
	end
	if loaded and #types == 0 then
		print(format("|cff33ff99GatherReference|r: %s is loaded but its data was already imported and cleared; /reload to show nodes.", DATA_ADDON))
	end
end

local nodes = ns.nodes
local enabled -- GatherReferenceDB, [typeKey] = bool

local function DecodeLoc(id)
	return floor(id / 1000000) / 10000, floor(id % 1000000 / 100) / 10000
end

local function NodeInfo(typeKey, nodeID)
	local info = nodes[typeKey][nodeID]
	if info then
		return info[1], info[2]
	end
	return "Unknown node " .. nodeID, [[Interface\Icons\INV_Misc_QuestionMark]]
end

--[[
	Shared tooltip: lists every pin of the same set under the cursor
]]
local function ShowTooltip(owner, pins)
	local x = owner:GetCenter()
	local parentX = UIParent:GetCenter()
	GameTooltip:SetOwner(owner, (x and x > parentX) and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	local seen = {}
	local text
	for _, pin in ipairs(pins) do
		if pin.title and pin:IsShown() and pin:IsMouseOver() and not seen[pin.title] then
			seen[pin.title] = true
			text = text and (text .. "\n" .. pin.title) or pin.title
		end
	end
	GameTooltip:SetText(text or owner.title or "")
	GameTooltip:Show()
end

---------------------------------------------------------
-- World map

local WorldMapDataProvider = CreateFromMixins(MapCanvasDataProviderMixin)

function WorldMapDataProvider:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate("GatherReferenceWorldMapPinTemplate")
end

function WorldMapDataProvider:RefreshAllData(fromOnShow)
	self:RemoveAllData()

	local map = self:GetMap()
	local uiMapID = map:GetMapID()
	if not uiMapID then return end

	for _, t in ipairs(types) do
		local zoneData = enabled[t.key] and t.db[uiMapID]
		if zoneData then
			for coord, nodeID in pairs(zoneData) do
				map:AcquirePin("GatherReferenceWorldMapPinTemplate", coord, nodeID, t.key)
			end
		end
	end
end

GatherReferenceWorldMapPinMixin = CreateFromMixins(MapCanvasPinMixin)

function GatherReferenceWorldMapPinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
	self:SetScalingLimits(1, 1.0, 1.2)
	self:SetSize(WORLD_PIN_SIZE, WORLD_PIN_SIZE)
	-- hover for tooltips, but let clicks fall through to the map
	if self.SetMouseClickEnabled then
		self:SetMouseClickEnabled(false)
		self:SetMouseMotionEnabled(true)
	end
end

function GatherReferenceWorldMapPinMixin:OnAcquired(coord, nodeID, typeKey)
	self:SetPosition(DecodeLoc(coord))
	local title, texture = NodeInfo(typeKey, nodeID)
	self.title = title
	self.texture:SetTexture(texture)
end

function GatherReferenceWorldMapPinMixin:OnMouseEnter()
	local pins = {}
	for pin in WorldMapFrame:EnumeratePinsByTemplate("GatherReferenceWorldMapPinTemplate") do
		pins[#pins + 1] = pin
	end
	ShowTooltip(self, pins)
end

function GatherReferenceWorldMapPinMixin:OnMouseLeave()
	GameTooltip:Hide()
end

-- avoid tainting the map in combat (same workaround as GatherMate2)
GatherReferenceWorldMapPinMixin.SetPassThroughButtons = function() end

---------------------------------------------------------
-- Minimap

local Minimap = Minimap
local minimapPins = {}   -- [key] = pin
local pinPool = {}
local pinCount = 0
local zone
local rotateMinimap = C_CVar.GetCVar("rotateMinimap") == "1"
local lastX, lastY, lastFacing, lastZoom
local mapRadius, minimapWidth, minimapHeight, minimapShape
local sin, cos
local forceUpdate = true

local minimapShapes = {
	-- { upper-left, lower-left, upper-right, lower-right }
	["SQUARE"]                = { false, false, false, false },
	["CORNER-TOPLEFT"]        = { true,  false, false, false },
	["CORNER-TOPRIGHT"]       = { false, false, true,  false },
	["CORNER-BOTTOMLEFT"]     = { false, true,  false, false },
	["CORNER-BOTTOMRIGHT"]    = { false, false, false, true },
	["SIDE-LEFT"]             = { true,  true,  false, false },
	["SIDE-RIGHT"]            = { false, false, true,  true },
	["SIDE-TOP"]              = { true,  false, true,  false },
	["SIDE-BOTTOM"]           = { false, true,  false, true },
	["TRICORNER-TOPLEFT"]     = { true,  true,  true,  false },
	["TRICORNER-TOPRIGHT"]    = { true,  false, true,  true },
	["TRICORNER-BOTTOMLEFT"]  = { true,  true,  false, true },
	["TRICORNER-BOTTOMRIGHT"] = { false, true,  true,  true },
}

local function MiniPinOnEnter(self)
	local pins = {}
	for _, pin in pairs(minimapPins) do
		pins[#pins + 1] = pin
	end
	ShowTooltip(self, pins)
end

local function MiniPinOnLeave()
	GameTooltip:Hide()
end

local function AcquireMiniPin()
	local pin = next(pinPool)
	if pin then
		pinPool[pin] = nil
		return pin
	end
	pinCount = pinCount + 1
	pin = CreateFrame("Frame", "GatherReferenceMiniPin" .. pinCount, Minimap)
	pin:SetSize(MINI_PIN_SIZE, MINI_PIN_SIZE)
	pin:EnableMouse(true)
	if pin.SetMouseClickEnabled then
		pin:SetMouseClickEnabled(false)
	end
	local texture = pin:CreateTexture(nil, "OVERLAY")
	texture:SetAllPoints(pin)
	texture:SetTexelSnappingBias(0)
	texture:SetSnapToPixelGrid(false)
	pin.texture = texture
	pin:SetScript("OnEnter", MiniPinOnEnter)
	pin:SetScript("OnLeave", MiniPinOnLeave)
	pin:Hide()
	return pin
end

local function ReleaseMiniPin(key)
	local pin = minimapPins[key]
	pin:Hide()
	pin.title = nil
	pin.isCircle = nil
	minimapPins[key] = nil
	pinPool[pin] = true
end

local function ClearMiniPins()
	for key in pairs(minimapPins) do
		ReleaseMiniPin(key)
	end
end

-- size multiplier compensating for the minimap's own scale
local miniPinScale = 1

-- Switch a pin between its node icon and the coloured tracking ring
local function SetMiniPinCircle(pin, circle)
	pin.isCircle = circle
	local texture = pin.texture
	texture:ClearAllPoints()
	if circle then
		local size = TRACK_CIRCLE_SIZE * miniPinScale
		pin:SetSize(size, size)
		texture:SetTexture(TRACK_CIRCLE)
		texture:SetVertexColor(pin.color[1], pin.color[2], pin.color[3], 1)
		texture:SetPoint("TOPLEFT", -1, 1)
		texture:SetPoint("BOTTOMRIGHT", -1, 1)
	else
		local size = MINI_PIN_SIZE * miniPinScale
		pin:SetSize(size, size)
		texture:SetTexture(pin.texturePath)
		texture:SetVertexColor(1, 1, 1, 1)
		texture:SetAllPoints(pin)
	end
end

local function PlaceMiniPin(pin)
	local xDist, yDist = lastX - pin.wx, lastY - pin.wy

	local circle = xDist * xDist + yDist * yDist <= TRACK_DISTANCE * TRACK_DISTANCE
	if circle ~= pin.isCircle then
		SetMiniPinCircle(pin, circle)
	end

	-- rotating minimap: transpose coordinates for the circular movement
	if rotateMinimap then
		local dx, dy = xDist, yDist
		xDist = dx * cos - dy * sin
		yDist = dx * sin + dy * cos
	end

	local diffX = xDist / mapRadius
	local diffY = yDist / mapRadius

	local isRound = true
	if minimapShape and not (xDist == 0 or yDist == 0) then
		isRound = (xDist < 0) and 1 or 3
		if yDist < 0 then
			isRound = minimapShape[isRound]
		else
			isRound = minimapShape[isRound + 1]
		end
	end

	local dist
	if isRound then
		dist = (diffX * diffX + diffY * diffY) / 0.81
	else
		dist = max(diffX * diffX, diffY * diffY) / 0.81
	end

	-- outside the map: slide along the border and fade out
	local alpha = 1
	if dist > 1 then
		dist = sqrt(dist)
		diffX = diffX / dist
		diffY = diffY / dist
		alpha = max(2 - dist, 0)
	end

	if alpha > 0 then
		pin:ClearAllPoints()
		pin:SetPoint("CENTER", Minimap, "CENTER", diffX * minimapWidth, -diffY * minimapHeight)
		pin:SetAlpha(min(alpha, 1))
		pin:Show()
	else
		pin:Hide()
	end
end

local function GetFacing()
	if rotateMinimap then
		return GetPlayerFacing()
	end
	return lastFacing
end

-- Rescan nearby nodes and (re)create pins
local function UpdateMiniMap()
	forceUpdate = false
	if not zone or not Minimap:IsVisible() then
		ClearMiniPins()
		return
	end

	local x, y, instance = HBD:GetPlayerWorldPosition()
	local facing = GetFacing()
	if not x or (rotateMinimap and not facing) then
		ClearMiniPins()
		return
	end

	local px, py = HBD:GetZoneCoordinatesFromWorldInstance(x, y, instance, zone)
	local zoneW, zoneH = HBD:GetZoneSize(zone)
	if not px or not zoneW or zoneW == 0 then
		ClearMiniPins()
		return
	end

	minimapShape = GetMinimapShape and minimapShapes[GetMinimapShape() or "ROUND"]
	minimapWidth = Minimap:GetWidth() / 2
	minimapHeight = Minimap:GetHeight() / 2
	mapRadius = C_Minimap.GetViewRadius()
	lastZoom = Minimap:GetZoom()
	lastX, lastY, lastFacing = x, y, facing
	if rotateMinimap then
		sin, cos = math_sin(facing), math_cos(facing)
	end

	local newScale = UIParent:GetEffectiveScale() / Minimap:GetEffectiveScale()
	local rescale = newScale ~= miniPinScale
	miniPinScale = newScale
	local strata, level = Minimap:GetFrameStrata(), Minimap:GetFrameLevel() + 5
	local radiusSq = (mapRadius * NODE_RANGE) ^ 2

	local keep = {}
	for i, t in ipairs(types) do
		local zoneData = enabled[t.key] and t.db[zone]
		if zoneData then
			for coord, nodeID in pairs(zoneData) do
				local nx, ny = DecodeLoc(coord)
				local dx, dy = (nx - px) * zoneW, (ny - py) * zoneH
				if dx * dx + dy * dy <= radiusSq then
					local key = i * 1e14 + coord
					keep[key] = true
					local pin = minimapPins[key]
					if not pin then
						pin = AcquireMiniPin()
						pin.title, pin.texturePath = NodeInfo(t.key, nodeID)
						pin.color = t.color
						pin.wx, pin.wy = HBD:GetWorldCoordinatesFromZone(nx, ny, zone)
						minimapPins[key] = pin
					end
					pin:SetParent(Minimap)
					pin:SetFrameStrata(strata)
					pin:SetFrameLevel(level)
					if rescale then
						pin.isCircle = nil -- reapply size
					end
					if pin.wx then
						PlaceMiniPin(pin)
					else
						pin:Hide()
					end
				end
			end
		end
	end

	for key in pairs(minimapPins) do
		if not keep[key] then
			ReleaseMiniPin(key)
		end
	end
end

-- Cheap per-frame update: only move existing pins
local function UpdateIconPositions()
	if not zone or not Minimap:IsVisible() then return end
	if Minimap:GetZoom() ~= lastZoom then
		return UpdateMiniMap()
	end
	if not next(minimapPins) then return end

	local x, y = HBD:GetPlayerWorldPosition()
	local facing = GetFacing()
	if not x or (rotateMinimap and not facing) then
		return UpdateMiniMap()
	end

	if x ~= lastX or y ~= lastY or facing ~= lastFacing then
		mapRadius = C_Minimap.GetViewRadius()
		lastX, lastY, lastFacing = x, y, facing
		if rotateMinimap then
			sin, cos = math_sin(facing), math_cos(facing)
		end
		for _, pin in pairs(minimapPins) do
			if pin.wx then
				PlaceMiniPin(pin)
			end
		end
	end
end

---------------------------------------------------------
-- Toggles in the world map's "Map Filter" dropdown

local function RefreshAll()
	WorldMapDataProvider:RefreshAllData()
	UpdateMiniMap()
end

local function IsTypeEnabled(t)
	return enabled[t.key]
end

local function ToggleType(t)
	enabled[t.key] = not enabled[t.key]
	RefreshAll()
end

local function AddFilterMenuEntries()
	Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", function(owner, rootDescription, contextData)
		rootDescription:CreateDivider()
		rootDescription:CreateTitle("Gathering Nodes")
		for _, t in ipairs(types) do
			rootDescription:CreateCheckbox(format("|T%s:16:16:0:0:64:64:5:59:5:59|t %s", t.icon, t.label), IsTypeEnabled, ToggleType, t)
		end
	end)
end

---------------------------------------------------------
-- Startup

local function PlayerZoneChanged()
	local newZone = HBD:GetPlayerZone()
	if newZone ~= zone then
		zone = newZone
		ClearMiniPins()
		forceUpdate = true
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 ~= addonName then return end
		self:UnregisterEvent("ADDON_LOADED")

		LoadData()

		GatherReferenceDB = GatherReferenceDB or {}
		enabled = GatherReferenceDB
		for _, t in ipairs(types) do
			if enabled[t.key] == nil then
				enabled[t.key] = true
			end
		end

		WorldMapFrame:AddDataProvider(WorldMapDataProvider)
		AddFilterMenuEntries()

		HBD.RegisterCallback(ns, "PlayerZoneChanged", PlayerZoneChanged)
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("MINIMAP_UPDATE_ZOOM")
		self:RegisterEvent("CVAR_UPDATE")

		local elapsedTotal = 0
		self:SetScript("OnUpdate", function(_, elapsed)
			elapsedTotal = elapsedTotal + elapsed
			if forceUpdate or elapsedTotal > FULL_SCAN_INTERVAL then
				elapsedTotal = 0
				UpdateMiniMap()
			else
				UpdateIconPositions()
			end
		end)
	elseif event == "PLAYER_ENTERING_WORLD" then
		rotateMinimap = C_CVar.GetCVar("rotateMinimap") == "1"
		PlayerZoneChanged()
		forceUpdate = true
	elseif event == "MINIMAP_UPDATE_ZOOM" then
		forceUpdate = true
	elseif event == "CVAR_UPDATE" then
		if arg1 == "rotateMinimap" then
			rotateMinimap = arg2 == "1"
		end
		forceUpdate = true
	end
end)

