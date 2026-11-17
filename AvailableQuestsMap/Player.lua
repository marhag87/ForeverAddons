-- Player.lua
--
-- What the character is right now: level, race/class bits, quest log, completed quests,
-- professions and reputation. Everything here comes from the game client.

local _, ns = ...

local Player = {}
ns.Player = Player

Player.level = 1
Player.raceFlag = nil    -- QuestieDB's requiredRaces bit for this race
Player.classFlag = nil   -- requiredClasses bit for this class
Player.factionLetter = nil -- "A" / "H", matched against NPC friendlyToFaction

local completed = {}
local turnedIn = {} -- this session; the server's completed list can lag behind QUEST_TURNED_IN
local active = {}
local skills = {}
local reputation = {}

local IsOnQuest = C_QuestLog and C_QuestLog.IsOnQuest

function Player.Initialize()
  Player.level = UnitLevel("player") or 1

  local raceId = select(3, UnitRace("player"))
  local masks = LibQuestieDB.Enum and LibQuestieDB.Enum.raceMaskById
  Player.raceFlag = masks and masks[raceId] or nil

  local classId = select(3, UnitClass("player"))
  Player.classFlag = classId and 2 ^ (classId - 1) or nil

  local faction = UnitFactionGroup("player")
  Player.factionLetter = (faction == "Alliance" and "A") or (faction == "Horde" and "H") or nil

  if not Player.raceFlag then
    return false, "QuestieDB has no race mask for race ID " .. tostring(raceId) ..
      "; race-restricted quests will be hidden."
  end
  return true
end

--------------------------------------------------------------------------------------------
-- Quests
--------------------------------------------------------------------------------------------

function Player.RefreshCompleted()
  wipe(completed)
  if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
    local ids = C_QuestLog.GetAllCompletedQuestIDs()
    if ids then
      for i = 1, #ids do completed[ids[i]] = true end
    end
  elseif GetQuestsCompleted then
    local done = GetQuestsCompleted()
    if done then
      for id in pairs(done) do completed[id] = true end
    end
  end
  for id in pairs(turnedIn) do completed[id] = true end
end

function Player.MarkTurnedIn(questId)
  if questId then
    turnedIn[questId] = true
    completed[questId] = true
  end
end

function Player.IsCompleted(questId)
  return completed[questId] == true
end

--- Rebuild the set of quests in the log.
---@return boolean changed
function Player.RefreshActive()
  local seen = {}
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
    for i = 1, (C_QuestLog.GetNumQuestLogEntries()) do
      local info = C_QuestLog.GetInfo(i)
      if info and not info.isHeader and info.questID and info.questID > 0 then
        seen[info.questID] = true
      end
    end
  elseif GetNumQuestLogEntries and GetQuestLogTitle then
    for i = 1, (GetNumQuestLogEntries()) do
      local _, _, _, isHeader, _, _, _, questId = GetQuestLogTitle(i)
      if not isHeader and questId and questId > 0 then seen[questId] = true end
    end
  end

  local changed = false
  for id in pairs(seen) do
    if not active[id] then changed = true; active[id] = true end
  end
  for id in pairs(active) do
    if not seen[id] then changed = true; active[id] = nil end
  end
  return changed
end

function Player.IsActive(questId)
  if active[questId] then return true end
  -- Also catches quests hidden under a collapsed quest-log header.
  return IsOnQuest ~= nil and IsOnQuest(questId) == true
end

--------------------------------------------------------------------------------------------
-- Professions, reputation, spells
--------------------------------------------------------------------------------------------

-- The legacy skill API reports only localized names (this client runs enUS).
local SKILL_IDS_BY_NAME = {
  ["Alchemy"] = 171, ["Blacksmithing"] = 164, ["Cooking"] = 185, ["Enchanting"] = 333,
  ["Engineering"] = 202, ["First Aid"] = 129, ["Fishing"] = 356, ["Herbalism"] = 182,
  ["Leatherworking"] = 165, ["Mining"] = 186, ["Skinning"] = 393, ["Tailoring"] = 197,
  ["Lockpicking"] = 633, ["Poisons"] = 40,
}

--- Re-read the skills some quest requires.
---@param needed table<number, boolean> skill IDs to track
---@return boolean changed
function Player.RefreshSkills(needed)
  local seen = {}
  if C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
    for i = 1, (C_SkillInfo.GetNumSkillLines()) do
      local line = C_SkillInfo.GetSkillLineInfo(i)
      if line and not line.isHeader and line.skillID and needed[line.skillID] then
        seen[line.skillID] = line.rank or 0
      end
    end
  elseif GetNumSkillLines and GetSkillLineInfo then
    for i = 1, (GetNumSkillLines()) do
      local name, isHeader, _, rank = GetSkillLineInfo(i)
      local id = name and not isHeader and SKILL_IDS_BY_NAME[name]
      if id and needed[id] then seen[id] = rank or 0 end
    end
  end

  local changed = false
  for id, rank in pairs(seen) do
    if skills[id] ~= rank then changed = true; skills[id] = rank end
  end
  for id in pairs(skills) do
    if not seen[id] then changed = true; skills[id] = nil end
  end
  return changed
end

---@return number? rank nil when the character doesn't have the skill
function Player.GetSkill(skillId)
  return skills[skillId]
end

-- Factions that start below neutral before the character has met them.
local STARTS_BELOW_NEUTRAL = { [87] = true, [576] = true, [910] = true }

local function ReadReputation(factionId)
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local data = C_Reputation.GetFactionDataByID(factionId)
    if data and data.name and data.currentStanding then return data.currentStanding end
  elseif GetFactionInfoByID then
    local name, _, _, _, _, barValue = GetFactionInfoByID(factionId)
    if name and barValue then return barValue end
  end
  return STARTS_BELOW_NEUTRAL[factionId] and -36000 or 0
end

---@param needed table<number, boolean> faction IDs to track
---@return boolean changed
function Player.RefreshReputation(needed)
  local changed = false
  for id in pairs(needed) do
    local value = ReadReputation(id)
    if reputation[id] ~= value then changed = true; reputation[id] = value end
  end
  return changed
end

---@return number value absolute reputation (e.g. 3000 = start of Friendly)
function Player.GetReputation(factionId)
  local value = reputation[factionId]
  if value == nil then
    value = ReadReputation(factionId)
    reputation[factionId] = value
  end
  return value
end

function Player.KnowsSpell(spellId)
  if C_SpellBook and C_SpellBook.IsSpellKnown then return C_SpellBook.IsSpellKnown(spellId) == true end
  if IsPlayerSpell then return IsPlayerSpell(spellId) == true end
  return IsSpellKnown ~= nil and IsSpellKnown(spellId) == true
end

--- Quests at or above (level - range) are not trivial (not gray).
function Player.GreenRange()
  if C_QuestLog and C_QuestLog.GetTrivialRange then return C_QuestLog.GetTrivialRange() or 8 end
  if GetQuestGreenRange then return GetQuestGreenRange() or 8 end
  return 8
end
