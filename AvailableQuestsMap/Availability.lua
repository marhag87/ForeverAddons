-- Availability.lua
--
-- Decides which quests this character can pick up right now, from QuestieDB data only.
--
-- Build() reads every quest once (in the background, see Core.lua) and keeps a compact
-- record for each quest this race/class could ever take from an NPC or object. Compute()
-- then re-checks those records against the character's current state, which is cheap
-- enough to run after every quest log or level change.

local _, ns = ...

local Player = ns.Player

local Availability = {}
ns.Availability = Availability

local records = {}       -- candidate quests, ascending quest ID
local recordById = {}
local exclusiveCache = {} -- exclusiveTo of quests that are not candidates (pre-quest groups)
local built = false

Availability.neededSkills = {}   -- skill IDs some candidate requires
Availability.neededFactions = {} -- faction IDs some candidate requires
Availability.readErrors = 0

local abs = math.abs

-- Holiday and world-event quest categories (QuestieDB sort keys); hidden unless asked for.
local EVENT_SORT_NAMES = {
  "WINTER_VEIL", "HARVEST_FESTIVAL", "CHILDRENS_WEEK", "LOVE_IS_IN_THE_AIR", "PILGRIMS_BOUNTY",
  "NOBLEGARDEN", "BREWFEST", "MIDSUMMER", "LUNAR_FESTIVAL", "DARKMOON_FAIRE", "DAY_OF_THE_DEAD",
  "SEASONAL", "HALLOWS_END", "INVASION", "AHN_QIRAJ_WAR",
}

-- Battleground quests: the Battlegrounds category or a battleground zone (QuestieDB enums).
local PVP_SORT_NAMES = { "BATTLEGROUNDS" }
local PVP_ZONE_NAMES = {
  "ALTERAC_VALLEY", "WARSONG_GULCH", "ARATHI_BASIN",
  "WARSONG_GULCH_WINTER", "WARSONG_GULCH_WINTER_SILVERWING_HOLD", "WARSONG_GULCH_WINTER_WARSONG_LUMBER_MILL",
}

local function LookupSet(enum, names)
  local set = {}
  for _, name in ipairs(names) do
    if enum and enum[name] then set[enum[name]] = true end
  end
  return set
end

local function HasBit(mask, flag)
  -- Arithmetic rather than bit.band: Forever race masks use bits above 32.
  return (mask % (flag * 2)) >= flag
end

local function NonZero(value)
  if type(value) == "number" and value ~= 0 then return value end
  return nil
end

local function NonEmpty(value)
  if type(value) == "table" and next(value) ~= nil then return value end
  return nil
end

local function Pair(value)
  if type(value) == "table" and type(value[1]) == "number" and type(value[2]) == "number" then
    return value
  end
  return nil
end

local function BuildRecord(Quest, id, eventSorts, pvpSorts)
  local races = Quest.Get(id, "requiredRaces")
  if races and races ~= 0 and not (Player.raceFlag and HasBit(races, Player.raceFlag)) then return nil end

  local classes = Quest.Get(id, "requiredClasses")
  if classes and classes ~= 0 and not (Player.classFlag and HasBit(classes, Player.classFlag)) then return nil end

  -- Quests start from an NPC, an object, or an item (placed where the item drops).
  local startedBy = Quest.Get(id, "startedBy")
  local npcs = startedBy and NonEmpty(startedBy[1])
  local objects = startedBy and NonEmpty(startedBy[2])
  local items = startedBy and NonEmpty(startedBy[3])
  if not npcs and not objects and not items then return nil end

  -- Profession specializations (e.g. Goblin/Gnomish Engineering) aren't modelled; skip them.
  if NonZero(Quest.Get(id, "requiredSpecialization")) then return nil end

  local specialFlags = Quest.Get(id, "specialFlags") or 0
  local zoneOrSort = Quest.Get(id, "zoneOrSort") or 0
  local preSingle = NonEmpty(Quest.Get(id, "preQuestSingle"))

  local record = {
    id = id,
    npcs = npcs,
    objects = objects,
    items = items,
    level = Quest.Get(id, "questLevel") or 0,
    requiredLevel = Quest.Get(id, "requiredLevel") or 0,
    maxLevel = NonZero(Quest.Get(id, "requiredMaxLevel")),
    repeatable = specialFlags % 2 == 1,
    event = eventSorts[zoneOrSort] == true,
    pvp = pvpSorts[zoneOrSort] == true,
    preSingle = preSingle,
    -- preQuestSingle and preQuestGroup are mutually exclusive; single wins.
    preGroup = (not preSingle) and NonEmpty(Quest.Get(id, "preQuestGroup")) or nil,
    exclusiveTo = NonEmpty(Quest.Get(id, "exclusiveTo")),
    nextInChain = NonZero(Quest.Get(id, "nextQuestInChain")),
    parent = NonZero(Quest.Get(id, "parentQuest")),
    breadcrumbFor = NonZero(Quest.Get(id, "breadcrumbForQuestId")),
    breadcrumbs = NonEmpty(Quest.Get(id, "breadcrumbs")),
    disabledBy = NonZero(Quest.Get(id, "disabledByQuest")),
    availableUntil = NonZero(Quest.Get(id, "availableUntilCompleted")),
    availableStarting = NonZero(Quest.Get(id, "availableStartingWith")),
    skill = Pair(Quest.Get(id, "requiredSkill")),
    minRep = Pair(Quest.Get(id, "requiredMinRep")),
    maxRep = Pair(Quest.Get(id, "requiredMaxRep")),
    spell = NonZero(Quest.Get(id, "requiredSpell")),
  }

  if record.skill then Availability.neededSkills[record.skill[1]] = true end
  if record.minRep then Availability.neededFactions[record.minRep[1]] = true end
  if record.maxRep then Availability.neededFactions[record.maxRep[1]] = true end
  return record
end

--- Read QuestieDB once. Runs inside a coroutine; maybeYield() hands the frame back.
---@param maybeYield fun()
function Availability.Build(maybeYield)
  local Quest = LibQuestieDB.Quest
  local enum = LibQuestieDB.Enum or {}
  local eventSorts = LookupSet(enum.sortKeys, EVENT_SORT_NAMES)
  local pvpSorts = LookupSet(enum.sortKeys, PVP_SORT_NAMES)
  for zoneId in pairs(LookupSet(enum.zoneIDs, PVP_ZONE_NAMES)) do pvpSorts[zoneId] = true end

  local ids = Quest.GetAllIds()
  for i = 1, #ids do
    local id = ids[i]
    -- pcall per quest: one malformed row shouldn't hide every other quest.
    local ok, record = pcall(BuildRecord, Quest, id, eventSorts, pvpSorts)
    if not ok then
      Availability.readErrors = Availability.readErrors + 1
      Availability.lastError = record
    elseif record then
      records[#records + 1] = record
      recordById[id] = record
    end
    maybeYield()
  end
  built = true
end

function Availability.IsBuilt()
  return built
end

function Availability.CandidateCount()
  return #records
end

function Availability.GetRecord(questId)
  return recordById[questId]
end

--- Localized quest name, read lazily for tooltips.
function Availability.GetName(record)
  if not record.name then
    local ok, name = pcall(LibQuestieDB.Quest.Get, record.id, "name")
    record.name = (ok and type(name) == "string" and name ~= "") and name or ("Quest #" .. record.id)
  end
  return record.name
end

--------------------------------------------------------------------------------------------
-- Checks (mirrors the rules Questie uses for "available" quests)
--------------------------------------------------------------------------------------------

local IsCompleted, IsActive = Player.IsCompleted, Player.IsActive

local function DoneOrActive(questId)
  return IsCompleted(questId) or IsActive(questId)
end

local function ExclusiveOf(questId)
  local record = recordById[questId]
  if record then return record.exclusiveTo end
  local cached = exclusiveCache[questId]
  if cached == nil then
    local ok, value = pcall(LibQuestieDB.Quest.Get, questId, "exclusiveTo")
    cached = ok and NonEmpty(value) or false
    exclusiveCache[questId] = cached
  end
  return cached or nil
end

local function AnyCompleted(list)
  for i = 1, #list do
    if IsCompleted(list[i]) then return true end
  end
  return false
end

local function PreQuestGroupDone(list)
  for i = 1, #list do
    local pre = list[i]
    if pre < 0 then
      -- Negative entries must be completed themselves; their exclusive quests don't count.
      if not IsCompleted(-pre) then return false end
    elseif not IsCompleted(pre) then
      local exclusive = ExclusiveOf(pre)
      if not (exclusive and AnyCompleted(exclusive)) then return false end
    end
  end
  return true
end

--- nil when the quest can't be picked up; otherwise whether it's trivial (gray).
local function Check(r, playerLevel, minGreenLevel)
  local id = r.id
  if IsCompleted(id) or IsActive(id) then return nil end

  local level, required = r.level, r.requiredLevel
  if level == -1 then -- scales with the player
    if required > playerLevel then
      level = required
    else
      level, required = playerLevel, playerLevel
    end
  end
  r.displayLevel = level

  local trivial = false
  if r.parent then
    -- Child quests appear while their parent is in the log, whatever the level.
    if not IsActive(r.parent) then return nil end
  else
    if required > playerLevel then return nil end
    if r.maxLevel and playerLevel > r.maxLevel then return nil end
    trivial = level < minGreenLevel
  end

  if r.preSingle then
    if not AnyCompleted(r.preSingle) then return nil end
  elseif r.preGroup and not PreQuestGroupDone(r.preGroup) then
    return nil
  end

  if r.nextInChain and DoneOrActive(r.nextInChain) then return nil end
  if r.exclusiveTo then
    for i = 1, #r.exclusiveTo do
      if DoneOrActive(r.exclusiveTo[i]) then return nil end
    end
  end
  if r.breadcrumbFor and DoneOrActive(r.breadcrumbFor) then return nil end
  if r.breadcrumbs then
    for i = 1, #r.breadcrumbs do
      if IsActive(r.breadcrumbs[i]) then return nil end
    end
  end
  if r.disabledBy and IsActive(r.disabledBy) then return nil end
  if r.availableUntil and IsCompleted(r.availableUntil) then return nil end
  if r.availableStarting and not DoneOrActive(r.availableStarting) then return nil end

  if r.skill then
    local rank = Player.GetSkill(r.skill[1])
    if not rank or rank < r.skill[2] then return nil end
  end
  if r.minRep and Player.GetReputation(r.minRep[1]) < r.minRep[2] then return nil end
  if r.maxRep and Player.GetReputation(r.maxRep[1]) >= r.maxRep[2] then return nil end
  if r.spell then
    local known = Player.KnowsSpell(abs(r.spell))
    if (r.spell > 0) ~= known then return nil end
  end

  return trivial
end

--- Quests the character can pick up now, after the user's display filters.
---@param db table saved settings
---@return table[] records (each with .trivial and .displayLevel set)
function Availability.Compute(db)
  local result = {}
  local playerLevel = Player.level
  local minGreenLevel = playerLevel - Player.GreenRange()
  local ignored = db.ignored

  for i = 1, #records do
    local r = records[i]
    if not ignored[r.id] and (db.showEvents or not r.event) and (db.showRepeatable or not r.repeatable)
        and (db.showPvP or not r.pvp) and (db.showItemQuests or r.npcs or r.objects) then
      local trivial = Check(r, playerLevel, minGreenLevel)
      if trivial ~= nil and (db.showTrivial or not trivial) then
        r.trivial = trivial
        result[#result + 1] = r
      end
    end
  end
  return result
end
