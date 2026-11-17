-- ThreatGap.lua
--
-- Threat on enemy nameplates: a strip along the bottom of the health bar and a number to the
-- left of it. Shows the tank's view while you're tanking and the reverse otherwise.
--
-- Tanking (Defensive Stance, Bear or Dire Bear Form, Righteous Fury; or /threatgap tank):
--   strip   green: you have aggro. Yellow over it: how close the party member nearest to
--           pulling is, as a share of the threat they need (the 110% melee / 130% ranged rule
--           is built in); orange past 90%. Blue: someone else in your group has aggro.
--   number  your threat minus the highest other threat. Green while you have aggro, red not.
--
-- Not tanking (or /threatgap dps):
--   strip   green: you're on the mob's threat list and someone else has aggro. Yellow over
--           it: your own share of the threat you need to pull; orange past 90%. Blue: you
--           have aggro.
--   number  threat you can still add before you pull (-1200 = 1200 to go). Green while
--           someone else has aggro; red, showing your lead, once you have it.
--
-- Forever hides threat from addons (secret values) when a mob is asked about through its
-- nameplate, so the number is only shown for your target, focus and mouseover, where it can
-- be read. The strips work on every mob: a bar can be fed a hidden value without the addon
-- reading it. Aggro comes from the threat status (2 or 3 = tanking) fed to a bar that is
-- empty below 2 and full from 2. The tank strip draws one bar per party member over the
-- others in the same color, so the longest is what you see; those are party-only, not raids.
-- The non-tank strip only uses your own threat and works in raids too.

local ADDON = ...

local REFRESH_INTERVAL = 0.25 -- seconds between refreshes
local AFTER_COMBAT = 5        -- seconds to keep refreshing after you leave combat
local BAR_HEIGHT = 3          -- the strip runs along the bottom inside of the health bar
local NUMBER_GAP = 6          -- space between the number and the left end of the health bar
local DANGER = 90             -- percent where the threat part turns orange
local BAR_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local GOOD_COLOR = { 0.15, 0.75, 0.15 }  -- tank: you have aggro; others: someone else has it
local THREAT_COLOR = { 1, 0.85, 0 }      -- share of the threat needed to pull
local DANGER_COLOR = { 1, 0.45, 0 }      -- ... past DANGER percent
local BAD_COLOR = { 0.2, 0.55, 1 }       -- tank: someone else has aggro; others: you have it
local GOOD_TEXT = { 0.4, 1, 0.4 }
local BAD_TEXT = { 1, 0.4, 0.4 }

-- Threat status 2 or 3 means tanking; a bar with this range is empty below 2 and full from 2.
local TANKING_MIN, TANKING_MAX = 1, 2
-- A bar with range 0 to this is full as soon as there's any threat at all.
local ON_LIST_MAX = 0.001

-- Units whose threat Forever lets addons read, tried for each nameplate in this order.
local STANDINS = { "target", "focus", "mouseover" }

-- What makes the automatic view pick "tank".
local TANK_FORM_IDS = { [5] = "Bear Form", [8] = "Dire Bear Form", [18] = "Defensive Stance" }
local TANK_FORM_SPELLS = { [71] = "Defensive Stance", [5487] = "Bear Form", [9634] = "Dire Bear Form" }
local RIGHTEOUS_FURY = 25780

local UnitDetailedThreatSituation = UnitDetailedThreatSituation
local GetNamePlateForUnit = C_NamePlate.GetNamePlateForUnit
local issecretvalue = issecretvalue or function() return false end
local floor, abs, max = math.floor, math.abs, math.max

local FONT = _G.GameFontHighlightSmallOutline and "GameFontHighlightSmallOutline" or "GameFontHighlightSmall"

local function Print(message)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Threat Gap:|r " .. message)
end

--- value if it's a plain value addons may use, otherwise nil.
local function Plain(value)
  if issecretvalue(value) then return nil end
  return value
end

--------------------------------------------------------------------------------------------
-- Tank or not
--------------------------------------------------------------------------------------------

local role = "auto" -- saved per character: "auto", "tank" or "dps"
local isTank = false
local roleReason    -- why, for /threatgap

local function DetectTank()
  local formId = Plain(GetShapeshiftFormID and GetShapeshiftFormID())
  if formId and TANK_FORM_IDS[formId] then return true, TANK_FORM_IDS[formId] end
  for i = 1, (Plain(GetNumShapeshiftForms()) or 0) do
    local _, active, _, spellId = GetShapeshiftFormInfo(i)
    spellId = Plain(spellId)
    if Plain(active) and spellId and TANK_FORM_SPELLS[spellId] then
      return true, TANK_FORM_SPELLS[spellId]
    end
  end
  if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    -- pcall: auras can be hidden from addons, and reading them may raise an error.
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, RIGHTEOUS_FURY)
    if ok and not issecretvalue(aura) and aura then return true, "Righteous Fury" end
  end
  return false, "no tanking stance, form or Righteous Fury"
end

local function RefreshRole()
  if role == "tank" or role == "dps" then
    isTank, roleReason = (role == "tank"), "set with /threatgap " .. role
    return
  end
  local ok, tank, reason = pcall(DetectTank)
  if ok then
    isTank, roleReason = tank, reason
  else
    isTank, roleReason = false, "couldn't check stance or form: " .. tostring(tank)
  end
end

--------------------------------------------------------------------------------------------
-- Group
--------------------------------------------------------------------------------------------

local others = {} -- units compared against you: group members and pets

local function RebuildGroup()
  wipe(others)
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local unit = "raid" .. i
      local isPlayer = UnitIsUnit(unit, "player")
      if issecretvalue(isPlayer) or not isPlayer then others[#others + 1] = unit end
      others[#others + 1] = "raidpet" .. i
    end
  else
    others[1] = "pet"
    for i = 1, GetNumSubgroupMembers() do
      others[#others + 1] = "party" .. i
      others[#others + 1] = "partypet" .. i
    end
  end
end

--------------------------------------------------------------------------------------------
-- The number (target, focus, mouseover)
--------------------------------------------------------------------------------------------

--- unit's threat on mob: nil when not on its threat list, false when the client hides it.
local function Threat(unit, mob)
  local _, _, _, _, value = UnitDetailedThreatSituation(unit, mob)
  if issecretvalue(value) then return false end
  return value
end

--- Your threat minus the highest other threat on mob. nil when nobody in your group has
--- threat on it; false when the client hides threat for this unit.
local function Gap(mob)
  local mine = Threat("player", mob)
  if mine == false then return false end
  local top
  for i = 1, #others do
    local value = Threat(others[i], mob)
    if value == false then return false end
    if value and (not top or value > top) then top = value end
  end
  if (mine or 0) == 0 and (top or 0) == 0 then return nil end -- nobody has threat on it
  return (mine or 0) - (top or 0)
end

local function IsSame(a, b)
  return Plain(UnitIsUnit(a, b)) == true
end

--- A unit for this nameplate's mob whose threat can be read: the nameplate itself if the
--- client allows it, otherwise your target, focus or mouseover if one of them is this mob.
local function ReadableUnit(plateUnit)
  if Threat("player", plateUnit) ~= false then return plateUnit end
  for i = 1, #STANDINS do
    local standin = STANDINS[i]
    if IsSame(plateUnit, standin) and Threat("player", standin) ~= false then return standin end
  end
  return nil
end

--- The number for a nameplate, and whether it's good news for you (green) or not (red).
---@return number|nil value
---@return boolean good
---@return string|nil source the unit the threat was read through
local function PlateNumber(plateUnit)
  local source = ReadableUnit(plateUnit)
  if not source then return nil, false end
  local gap = Gap(source)
  if not gap then return nil, false end
  local isTanking, _, scaled, _, mine = UnitDetailedThreatSituation("player", source)
  isTanking = Plain(isTanking) == true
  if isTank or isTanking then
    -- Tanks always see their lead; a non-tank who has aggro sees it too, in red.
    return gap, isTank == isTanking, source
  end
  scaled, mine = Plain(scaled), Plain(mine)
  if mine and scaled and scaled > 0 then
    -- scaled is your share of the threat you'd need to pull, so the threshold is
    -- mine * 100 / scaled; show how much is left before you reach it.
    return -max(mine * 100 / scaled - mine, 0), true, source
  end
  return gap, true, source
end

local function FormatNumber(value)
  local rounded = floor(abs(value) + 0.5)
  if rounded == 0 then return "0" end
  return (value < 0 and "-" or "+") .. rounded
end

--------------------------------------------------------------------------------------------
-- Nameplate widgets: the strip inside the health bar and the number to its left
--------------------------------------------------------------------------------------------

local widgets = {} -- nameplate unit -> widget frame
local pool = {}
local barStats = { hidden = 0, plain = 0, errors = 0 }

local function HealthBar(plate)
  local unitFrame = plate.UnitFrame
  if not unitFrame then return plate end
  return unitFrame.healthBar or unitFrame.HealthBarsContainer or unitFrame
end

--- Bars are stacked by layer: higher layers draw over lower ones.
local function AddBar(widget, bar, layer)
  bar.layer = layer
  bar:SetFrameLevel(widget:GetFrameLevel() + layer)
  widget.allBars[#widget.allBars + 1] = bar
  return bar
end

local function LevelBars(widget)
  local level = widget:GetFrameLevel()
  for i = 1, #widget.allBars do
    widget.allBars[i]:SetFrameLevel(level + widget.allBars[i].layer)
  end
end

local function CreateBar(widget, color, minValue, maxValue)
  local bar = CreateFrame("StatusBar", nil, widget)
  bar:SetStatusBarTexture(BAR_TEXTURE)
  bar:SetStatusBarColor(color[1], color[2], color[3])
  bar:SetMinMaxValues(minValue, maxValue)
  return bar
end

--- A bar across the whole strip.
local function NewBar(widget, color, minValue, maxValue, layer)
  local bar = CreateBar(widget, color, minValue, maxValue)
  bar:SetAllPoints(widget)
  return AddBar(widget, bar, layer)
end

--- The orange part: covers the last (100 - DANGER) percent of the width and fills from
--- DANGER to 100, so it lines up with the yellow bar under it.
local function SizeDangerBars(widget, width)
  width = Plain(width)
  if not width then return end
  for i = 1, #widget.dangers do
    widget.dangers[i]:SetWidth(width * (100 - DANGER) / 100)
  end
end

local function NewDangerBar(widget, layer)
  local bar = CreateBar(widget, DANGER_COLOR, DANGER, 100)
  bar:SetPoint("TOPRIGHT")
  bar:SetPoint("BOTTOMRIGHT")
  widget.dangers[#widget.dangers + 1] = bar
  SizeDangerBars(widget, widget:GetWidth())
  return AddBar(widget, bar, layer)
end

local function SetBarsShown(bars, shown)
  for _, bar in pairs(bars) do bar:SetShown(shown) end
end

--- Tank strip: your aggro (green), then per party member their share of the pull threshold
--- (yellow, orange) and their aggro (blue).
local function TankParts(widget)
  if not widget.tank then
    widget.tank = { aggro = NewBar(widget, GOOD_COLOR, TANKING_MIN, TANKING_MAX, 1), sets = {} }
  end
  return widget.tank
end

local function TankSet(widget, i)
  local sets = TankParts(widget).sets
  if not sets[i] then
    sets[i] = {
      main = NewBar(widget, THREAT_COLOR, 0, 100, 2),
      danger = NewDangerBar(widget, 3),
      lost = NewBar(widget, BAD_COLOR, TANKING_MIN, TANKING_MAX, 4),
    }
  end
  return sets[i]
end

--- Non-tank strip, all from your own threat: on the list (green), your share of the pull
--- threshold (yellow, orange) and your aggro (blue).
local function DpsParts(widget)
  if not widget.dps then
    widget.dps = {
      onList = NewBar(widget, GOOD_COLOR, 0, ON_LIST_MAX, 1),
      main = NewBar(widget, THREAT_COLOR, 0, 100, 2),
      danger = NewDangerBar(widget, 3),
      aggro = NewBar(widget, BAD_COLOR, TANKING_MIN, TANKING_MAX, 4),
    }
  end
  return widget.dps
end

local function HideTankParts(widget)
  local parts = widget.tank
  if not parts then return end
  parts.aggro:Hide()
  for i = 1, #parts.sets do SetBarsShown(parts.sets[i], false) end
end

local function HideDpsParts(widget)
  if widget.dps then SetBarsShown(widget.dps, false) end
end

--- Show a value on a bar. Hidden (secret) values go straight to the bar.
local function FeedBar(bar, value)
  if issecretvalue(value) then
    barStats.hidden = barStats.hidden + 1
    local ok, err = pcall(bar.SetValue, bar, value)
    if not ok then
      barStats.errors = barStats.errors + 1
      barStats.lastError = err
      bar:SetValue(0)
    end
  else
    barStats.plain = barStats.plain + 1
    bar:SetValue(value or 0)
  end
end

local function UpdateTankStrip(widget, unit)
  HideDpsParts(widget)
  local parts = TankParts(widget)
  local _, myStatus = UnitDetailedThreatSituation("player", unit)
  FeedBar(parts.aggro, myStatus)
  parts.aggro:Show()

  local count = IsInRaid() and 0 or #others
  for i = 1, count do
    local _, status, scaled = UnitDetailedThreatSituation(others[i], unit)
    local set = TankSet(widget, i)
    FeedBar(set.main, scaled)
    FeedBar(set.danger, scaled)
    FeedBar(set.lost, status)
    SetBarsShown(set, true)
  end
  for i = count + 1, #parts.sets do SetBarsShown(parts.sets[i], false) end
end

local function UpdateDpsStrip(widget, unit)
  HideTankParts(widget)
  local parts = DpsParts(widget)
  local _, status, scaled = UnitDetailedThreatSituation("player", unit)
  FeedBar(parts.onList, scaled)
  FeedBar(parts.main, scaled)
  FeedBar(parts.danger, scaled)
  FeedBar(parts.aggro, status)
  SetBarsShown(parts, true)
end

local function AcquireWidget(unit)
  local plate = GetNamePlateForUnit(unit)
  if not plate then return nil end -- gone, or a plate addons may not touch
  local widget = tremove(pool)
  if not widget then
    widget = CreateFrame("Frame")
    widget.allBars = {}
    widget.dangers = {}
    widget.text = widget:CreateFontString(nil, "OVERLAY", FONT)
    widget:SetScript("OnSizeChanged", SizeDangerBars)
  end
  widget:SetParent(plate)
  widget:SetFrameLevel(plate:GetFrameLevel() + 20)
  LevelBars(widget)
  -- Inside the health bar and to its left, clear of the cast bar that appears below it.
  local healthBar = HealthBar(plate)
  widget:ClearAllPoints()
  widget:SetPoint("BOTTOMLEFT", healthBar, "BOTTOMLEFT")
  widget:SetPoint("BOTTOMRIGHT", healthBar, "BOTTOMRIGHT")
  widget:SetHeight(BAR_HEIGHT)
  widget.text:ClearAllPoints()
  widget.text:SetPoint("RIGHT", healthBar, "LEFT", -NUMBER_GAP, 0)
  widget:Show()
  return widget
end

local function ReleaseWidget(unit)
  local widget = widgets[unit]
  if not widget then return end
  widgets[unit] = nil
  widget:Hide()
  widget.text:SetText("")
  widget:ClearAllPoints()
  widget:SetParent(nil)
  pool[#pool + 1] = widget
end

--- Redraw one nameplate; returns whether it shows a number.
local function Update(unit)
  local widget = widgets[unit]
  if not widget then return false end

  local number, good = PlateNumber(unit)
  if number then
    local color = good and GOOD_TEXT or BAD_TEXT
    widget.text:SetTextColor(color[1], color[2], color[3])
    widget.text:SetText(FormatNumber(number))
  else
    widget.text:SetText("")
  end

  if isTank then
    UpdateTankStrip(widget, unit)
  else
    UpdateDpsStrip(widget, unit)
  end
  return number ~= nil
end

-- Errors are caught so one bad nameplate can't stop the rest; the first is printed, the
-- latest is kept for /threatgap.
local lastError

local function SafeUpdate(unit)
  local ok, result = pcall(Update, unit)
  if ok then return result end
  if not lastError then Print("error updating a nameplate: " .. tostring(result)) end
  lastError = result
  return false
end

local anyShown = false -- any nameplate showing a number

local function UpdateAll()
  RefreshRole()
  anyShown = false
  for unit in pairs(widgets) do
    if SafeUpdate(unit) then anyShown = true end
  end
end

-- Threat changes don't always come with an event, so refresh on a timer while fighting.
local sinceRefresh, lastCombat = 0, -math.huge
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, elapsed)
  sinceRefresh = sinceRefresh + elapsed
  if sinceRefresh < REFRESH_INTERVAL then return end
  sinceRefresh = 0
  local now = GetTime()
  if InCombatLockdown() then lastCombat = now end
  if anyShown or now - lastCombat <= AFTER_COMBAT then UpdateAll() end
end)

--------------------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------------------

local handlers = {}

function handlers.ADDON_LOADED(name)
  if name ~= ADDON then return end
  ThreatGapCharDB = ThreatGapCharDB or {}
  role = ThreatGapCharDB.role or "auto"
  RefreshRole()
end

function handlers.NAME_PLATE_UNIT_ADDED(unit)
  local attackable = UnitCanAttack("player", unit)
  if not issecretvalue(attackable) and not attackable then return end
  ReleaseWidget(unit)
  local widget = AcquireWidget(unit)
  if not widget then return end
  widgets[unit] = widget
  if SafeUpdate(unit) then anyShown = true end
end

function handlers.NAME_PLATE_UNIT_REMOVED(unit)
  ReleaseWidget(unit)
end

function handlers.UNIT_THREAT_LIST_UPDATE(unit)
  if unit and widgets[unit] and SafeUpdate(unit) then anyShown = true end
end

function handlers.GROUP_ROSTER_UPDATE()
  RebuildGroup()
  UpdateAll()
end

handlers.PLAYER_ENTERING_WORLD = handlers.GROUP_ROSTER_UPDATE
handlers.UNIT_PET = UpdateAll
handlers.UPDATE_SHAPESHIFT_FORM = UpdateAll
handlers.PLAYER_TARGET_CHANGED = UpdateAll
handlers.PLAYER_FOCUS_CHANGED = UpdateAll
handlers.UPDATE_MOUSEOVER_UNIT = UpdateAll
handlers.PLAYER_REGEN_DISABLED = UpdateAll
handlers.PLAYER_REGEN_ENABLED = UpdateAll

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
  if issecretvalue((...)) then return end
  handlers[event](...)
end)
for event in pairs(handlers) do
  -- pcall: registering an event this client doesn't have raises an error.
  pcall(events.RegisterEvent, events, event)
end

--------------------------------------------------------------------------------------------
-- /threatgap [tank | dps | auto]
--------------------------------------------------------------------------------------------

local function Describe(value)
  if issecretvalue(value) then return "hidden" end
  return tostring(value)
end

local function YesNo(value)
  return value and "yes" or "no"
end

local function Diagnose()
  local count, shown = 0, 0
  for _, widget in pairs(widgets) do
    count = count + 1
    if widget.text:GetText() ~= "" then shown = shown + 1 end
  end
  local inInstance, instanceType = IsInInstance()
  Print(("View: %s (%s). Change with /threatgap tank, dps or auto.")
    :format(isTank and "tank" or "not tanking", tostring(roleReason)))
  Print(("In combat: %s. In instance: %s. Enemy nameplates: %d, with a number: %d.")
    :format(YesNo(InCombatLockdown()), inInstance and tostring(instanceType) or "no", count, shown))
  Print(("Strips: fed %d hidden and %d plain values, %d failed%s.")
    :format(barStats.hidden, barStats.plain, barStats.errors,
      barStats.lastError and (" (last: " .. tostring(barStats.lastError) .. ")") or ""))
  if lastError then Print("last error: " .. tostring(lastError)) end

  for unit in pairs(widgets) do
    local ok, number, good, source = pcall(PlateNumber, unit)
    local result
    if not ok then
      result = "error " .. tostring(number)
    elseif number then
      result = ("%s, %s (read through %s)"):format(FormatNumber(number), good and "green" or "red", source)
    else
      result = "no number"
    end
    Print(("%s (%s): %s"):format(unit, Describe(UnitName(unit)), result))
  end

  if not UnitExists("target") then
    Print("Target an enemy you're fighting and run /threatgap again to see its threat table.")
    return
  end
  for i = 0, #others do
    local unit = (i == 0) and "player" or others[i]
    if UnitExists(unit) then
      local isTanking, status, scaled, _, value = UnitDetailedThreatSituation(unit, "target")
      Print(("target, %s (%s): threat %s, %s%% of pull, status %s, tanking %s"):format(
        unit, Describe(UnitName(unit)), Describe(value), Describe(scaled), Describe(status),
        Describe(isTanking)))
    end
  end
end

local ROLE_MESSAGES = {
  tank = "Always showing the tank view.",
  dps = "Always showing the non-tank view.",
  auto = "Picking the view from your stance, form or Righteous Fury.",
}

SLASH_THREATGAP1 = "/threatgap"
SlashCmdList.THREATGAP = function(input)
  local command = ((input or ""):match("^%s*(%S*)") or ""):lower()
  if ROLE_MESSAGES[command] then
    role = command
    ThreatGapCharDB = ThreatGapCharDB or {}
    ThreatGapCharDB.role = command
    UpdateAll()
    Print(ROLE_MESSAGES[command] .. " Now: " .. (isTank and "tank" or "not tanking") .. ".")
    return
  end
  Diagnose()
end
