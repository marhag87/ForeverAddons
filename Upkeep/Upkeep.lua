-- Upkeep: a duration bar for your Paladin seal, a reminder when none of your own
-- blessings is on you, and the blessings you could still cast on your target. The same
-- reminder covers weapon enchants (Shaman imbues, Rogue poisons) and buffs a class keeps
-- on itself, listed per class in WEAPON_ENCHANTS and SELF_BUFFS below, and buffs any
-- class keeps up, such as a gatherer's Find Minerals or Find Herbs, and below the level cap
-- experience food and a sleeping bag. Every reminder is a button that casts what's missing and
-- shows its tooltip, except that one coming up in combat is a plain icon until the fight
-- ends (see "Reminder icons" below). Other addons can add reminders of their own with
-- Upkeep.AddReminder.
--
-- This client restricts addons the way retail does. Established by testing in game:
--   * Enumerating the spellbook and reading the combat log are forbidden outright, and
--     the "blocked" popup that follows cannot be caught with pcall. Asking about one
--     specific spell id (IsSpellKnown, C_Spell.GetSpellName) is fine.
--   * In combat, aura queries return nothing readable at all.
--   * An aura field can hold a value the addon may not touch, and even testing it for
--     nil raises an error, so every field read happens inside a pcall.

local ADDON = ...
local class = select(2, UnitClass("player"))
local isPaladin = class == "PALADIN"

-- Buffs to keep on yourself, per class (the class token from UnitClass), and under ALL
-- for every class. Each entry is one reminder icon and holds a set of spells: any one
-- of them on you satisfies it, for spells that replace each other. Each spell lists all
-- its ranks as spell ids, lowest first, so a position is a rank; a lower rank than you
-- know counts as missing. An entry only reminds you once you know one of its spells.
-- duration, in seconds, times a cast in combat until the buff has been seen on you.
-- early, in seconds, reminds you that long before the buff runs out, so you can refresh it
-- in time; without it the reminder waits until the buff is gone.
local SELF_BUFFS = {
  ALL = {
    -- One tracking at a time, so with both professions either one satisfies it.
    {
      { 2580 },  -- Find Minerals, known once you have trained Mining
      { 2383 },  -- Find Herbs, known once you have trained Herbalism
    },
  },
  SHAMAN = {
    {
      { 324, 325, 905, 945, 8134, 10431, 10432 },  -- Lightning Shield
      { 408510 },  -- Water Shield, which replaces Lightning Shield; one rank
    },
  },
  WARRIOR = {
    {
      { 6673, 5242, 6192, 11549, 11550, 11551, 25289 },  -- Battle Shout
      duration = 120,
    },
  },
}

-- Weapon enchants to keep up, per class. Each option is one enchant a weapon can carry.
-- tooltip is how its line starts on the weapon's tooltip; the rank follows as a number
-- or a roman numeral, or not at all for rank 1 ("Rockbiter 2 (56 min)", "Instant
-- Poison II"). You can apply an option if you know one of its spells, or carry one of
-- its items (poisons); either list holds every rank, lowest first, so a position is a
-- rank. Each equipped weapon is checked on its own, so dual wielding gets an icon each.
-- early, in seconds, works as for SELF_BUFFS and covers all of a class's enchants.
local WEAPON_ENCHANTS = {
  SHAMAN = {
    early = 5 * 60,
    { tooltip = "Rockbiter", spells = { 8017, 8018, 8019, 10399, 16314, 16315, 16316 } },
    { tooltip = "Flametongue", spells = { 8024, 8027, 8030, 16339, 16341, 16342 } },
    { tooltip = "Frostbrand", spells = { 8033, 8038, 10456, 16355, 16356 } },
    { tooltip = "Windfury", spells = { 8232, 8235, 10486, 16362 } },
  },
  -- ROGUE = {
  --   { tooltip = "Instant Poison", items = { <item ids, rank I first> } },
  --   { tooltip = "Deadly Poison", items = { ... } },
  -- },
}

-- Nothing is saved between sessions: the defaults are the layout, and the blessing or
-- enchant to suggest is learnt again each session from what is up.
local lastMine   -- key of the last blessing of yours seen on you

local function isSecret(v)
  return issecretvalue and issecretvalue(v) or false
end

local function SpellName(id)
  if id == nil or isSecret(id) then return end
  local ok, n
  if C_Spell and C_Spell.GetSpellName then ok, n = pcall(C_Spell.GetSpellName, id)
  elseif GetSpellInfo then ok, n = pcall(GetSpellInfo, id) end
  if ok and type(n) == "string" and not isSecret(n) then return n end
end

local function SpellTexture(id)
  if id == nil or isSecret(id) then return end
  local ok, t
  if C_Spell and C_Spell.GetSpellTexture then ok, t = pcall(C_Spell.GetSpellTexture, id)
  elseif GetSpellTexture then ok, t = pcall(GetSpellTexture, id) end
  if ok and t ~= nil and not isSecret(t) then return t end
end

-- One aura slot on a unit. Nil when the slot is empty or its name is hidden; any other
-- hidden field comes back as nil on its own.
local function ReadAura(unit, i, filter)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
  local ok, name, dur, exp, src, icon, spellId = pcall(function()
    local a = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
    if not a then return nil end
    return a.name, a.duration, a.expirationTime, a.sourceUnit, a.icon, a.spellId
  end)
  if not ok or name == nil or isSecret(name) or type(name) ~= "string" then return end
  if isSecret(dur) then dur = nil end
  if isSecret(exp) then exp = nil end
  if isSecret(src) then src = nil end
  if isSecret(icon) then icon = nil end
  if isSecret(spellId) then spellId = nil end
  return name, dur, exp, src, icon, spellId
end

-- How many buffs Blizzard's buff frame shows on you, or nil if it cannot tell. Its
-- buttons say that they hold a buff even when what the buff is has been hidden.
local function ShownBuffCount()
  local bf = BuffFrame
  local container = bf and bf.AuraContainer
  if not (container and container.GetChildren) then return end
  local ok, n = pcall(function()
    -- A hidden or collapsed buff frame hides its buttons too, which proves nothing.
    if not bf:IsVisible() then return nil end
    if bf.IsExpanded and not bf:IsExpanded() then return nil end
    local count = 0
    for _, child in ipairs({ container:GetChildren() }) do
      local auraType = child.auraType
      if not isSecret(auraType) and auraType == "Buff" and child:IsShown() then count = count + 1 end
    end
    return count
  end)
  if ok then return n end
end

-- Whether an aura scan that read this many auras can be believed to be complete, so
-- that a buff missing from it is really missing. In combat it never is: the client
-- withholds aura data then, but not always all of it, so a scan that read something
-- can still be missing your blessing. Out of combat on yourself, the buff frame shows
-- whether anything was withheld.
local function AurasTrusted(readable, unit)
  if UnitAffectingCombat("player") or (InCombatLockdown and InCombatLockdown()) then return false end
  if unit ~= "player" then return true end
  local shown = ShownBuffCount()
  return shown == nil or readable >= shown
end

--------------------------------------------------------------------------------
-- Seal bar
--------------------------------------------------------------------------------

local SEAL_PATTERN = "^Seal of"
local FALLBACK_DURATION = 30  -- for timing a seal from your cast when its aura is unreadable

local BAR_GAP = 18           -- between the player frame's health bar and the seal bar
local BAR_FALLBACK_Y = -150  -- the seal bar's height from the screen's centre without one

local bar = CreateFrame("Frame", nil, UIParent)
bar:SetSize(220, 20)
bar:SetPoint("CENTER", 0, BAR_FALLBACK_Y)
bar:Hide()

local barBg = bar:CreateTexture(nil, "BACKGROUND")
barBg:SetAllPoints()
barBg:SetColorTexture(0, 0, 0, 0.6)

local status = CreateFrame("StatusBar", nil, bar)
status:SetPoint("TOPLEFT", 1, -1)
status:SetPoint("BOTTOMRIGHT", -1, 1)
status:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
status:SetStatusBarColor(0.9, 0.75, 0.2)
status:SetMinMaxValues(0, 1)

local sealName = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sealName:SetPoint("LEFT", 4, 0)
local sealTime = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sealTime:SetPoint("RIGHT", -4, 0)

local alarm = status:CreateTexture(nil, "OVERLAY")
alarm:SetAllPoints()
alarm:SetColorTexture(1, 0.15, 0.15, 1)
alarm:SetAlpha(0)

local function PlayerHealthBar()
  local pf = PlayerFrame
  if not pf then return end
  local hb = PlayerFrameHealthBar or pf.healthbar
  if not hb and pf.PlayerFrameContent then
    local main = pf.PlayerFrameContent.PlayerFrameContentMain
    hb = main and main.HealthBarsContainer and main.HealthBarsContainer.HealthBar
  end
  return hb
end

-- As wide as the player frame's health bar, and just above it.
local function PlaceBar()
  bar:ClearAllPoints()
  local hb = PlayerHealthBar()
  local hbWidth = hb and hb:GetWidth()
  if hbWidth and hbWidth > 0 then
    bar:SetWidth(hbWidth * hb:GetEffectiveScale() / bar:GetEffectiveScale())
    bar:SetPoint("BOTTOM", hb, "TOP", 0, BAR_GAP)
  else
    bar:SetPoint("CENTER", 0, BAR_FALLBACK_Y)
  end
end

local sealCast  -- { name, start } from your own cast, for when the aura cannot be read

local function ReadSeal()
  for i = 1, 40 do
    local name, dur, exp = ReadAura("player", i, "HELPFUL|PLAYER")
    if name and name:find(SEAL_PATTERN) and dur and dur > 0 and exp then
      return name, dur, exp
    end
  end
end

local function UpdateSeal()
  if not isPaladin then
    bar:Hide()
    return
  end
  local name, total, exp = ReadSeal()
  local remaining
  if name then
    remaining = exp - GetTime()
    sealCast = { name = name, start = exp - total }  -- keeps the fallback in step
  elseif sealCast then
    name, total = sealCast.name, FALLBACK_DURATION
    remaining = sealCast.start + total - GetTime()
    if remaining <= 0 then sealCast = nil end
  end
  if name and remaining and remaining > 0 then
    alarm:SetAlpha(0)
    status:SetMinMaxValues(0, total)
    status:SetValue(remaining)
    sealName:SetText((name:gsub("^Seal of the ", ""):gsub("^Seal of ", "")))
    sealTime:SetText(string.format("%.1f", remaining))
    bar:Show()
  elseif UnitAffectingCombat("player") then
    -- In combat with no seal up: flash until one is cast or combat ends.
    status:SetMinMaxValues(0, 1)
    status:SetValue(0)
    sealName:SetText("No seal")
    sealTime:SetText("")
    alarm:SetAlpha(0.6 * math.abs(math.sin(GetTime() * math.pi * 1.5)))
    bar:Show()
  else
    alarm:SetAlpha(0)
    bar:Hide()
  end
end

--------------------------------------------------------------------------------
-- Blessings
--
-- Classic rules: one blessing per paladin per target, and a blessing of the same kind
-- from another paladin blocks yours unless you know a higher rank than theirs.
--------------------------------------------------------------------------------

local BLESSING_PATTERN = "^Blessing of"
-- Short-lived utility blessings are not something you keep up.
local UTILITY_BLESSINGS = {
  ["Blessing of Freedom"] = true,
  ["Blessing of Protection"] = true,
  ["Blessing of Sacrifice"] = true,
}

-- Every rank of each kept-up blessing, lowest first, so a position in a list is a rank.
local BLESSING_SPELLS = {
  { 19740, 19834, 19835, 19836, 19837, 19838, 25291 },  -- Might
  { 19742, 19850, 19852, 19853, 19854, 25290 },         -- Wisdom
  { 19977, 19978, 19979 },                              -- Light
  { 1038 },                                             -- Salvation
  { 20217 },                                            -- Kings
  { 20911, 20912, 20913, 20914 },                       -- Sanctuary
}

local RANK_OF = {}  -- spell id -> rank
for _, ids in ipairs(BLESSING_SPELLS) do
  for rank, id in ipairs(ids) do RANK_OF[id] = rank end
end

-- A blessing that is not up has no aura to take an icon from.
local FALLBACK_ICONS = {
  ["blessing of might"] = "Interface/Icons/Spell_Holy_FistOfJustice",
  ["blessing of wisdom"] = "Interface/Icons/Spell_Holy_SealOfWisdom",
  ["blessing of light"] = "Interface/Icons/Spell_Holy_PrayerOfHealing02",
  ["blessing of salvation"] = "Interface/Icons/Spell_Holy_SealOfSalvation",
  ["blessing of kings"] = "Interface/Icons/Spell_Magic_MageArmor",
  ["blessing of sanctuary"] = "Interface/Icons/Spell_Nature_LightningShield",
}

local ICON_SIZE = 24
local ICON_GAP = 2
local CAST_WINDOW = 3  -- seconds within which a new aura on you is taken to be your cast

local known = {}        -- names of the blessings you can cast, sorted
local myRank = {}       -- key -> highest rank you know
local blessingRanks = {} -- key -> the blessing's spell ids by rank, once you know it
local icons = {}        -- key -> texture
local lastKnown = {}    -- key -> last reading on you, or false for "read, and not there"
local lastDur = {}      -- key -> duration last seen on you
local pendingMine = {}  -- key -> GetTime() of your cast at yourself
local mineExp = {}      -- key -> expirationTime of the aura that cast produced
local mineScratch = {}

-- Matched by a normalised name, so a rank suffix cannot make a blessing read as missing.
local function Key(name)
  return (name:lower():gsub("%s*%(.-%)%s*$", ""))
end

local function IsKeptBlessing(name)
  return name:find(BLESSING_PATTERN) ~= nil and not UTILITY_BLESSINGS[name]
end

local function Learn(name)
  for _, n in ipairs(known) do
    if n == name then return end
  end
  known[#known + 1] = name
  table.sort(known)
end

local function IconFor(key)
  return icons[key] or FALLBACK_ICONS[key] or "Interface/Icons/INV_Misc_QuestionMark"
end

-- The spellbook cannot be enumerated here, so ask about every blessing rank by id.
local function SeedKnown()
  if not IsSpellKnown then return end
  for _, ids in ipairs(BLESSING_SPELLS) do
    for rank, id in ipairs(ids) do
      local ok, isKnown = pcall(IsSpellKnown, id)
      local name = ok and isKnown and SpellName(id)
      if name and not UTILITY_BLESSINGS[name] then
        Learn(name)
        local key = Key(name)
        if not myRank[key] or rank > myRank[key] then myRank[key] = rank end
        icons[key] = icons[key] or SpellTexture(id)
        blessingRanks[key] = ids
      end
    end
  end
end

-- The spell id of your best rank of a blessing, nil if not known by id.
local function BlessingSpell(key)
  local ids, rank = blessingRanks[key], myRank[key]
  return ids and rank and ids[rank]
end

-- A blessing reminder: a click casts it on unit.
local function BlessingEntry(id, key, unit)
  local spell = BlessingSpell(key)
  return { id = id, icon = IconFor(key), spell = spell, click = spell and { type = "spell", spell = spell, unit = unit } }
end

-- Did a blessing you just cast land on you? With no friendly target it self-casts.
local function CastAtSelf()
  if not UnitExists("target") then return true end
  local ok, same = pcall(UnitIsUnit, "target", "player")
  if ok and same then return true end
  local okA, assist = pcall(UnitCanAssist, "player", "target")
  return okA and not assist
end

-- key -> { dur, exp, mine, rank } for the kept-up blessings on a unit, plus how many
-- auras were readable at all: none means the client is withholding them.
local function ReadBlessings(unit, out)
  wipe(out)
  wipe(mineScratch)
  -- "HELPFUL|PLAYER" lists only the auras you cast. An empty answer proves nothing
  -- while the client is withholding auras, so it is only trusted when it found some.
  local mineCount = 0
  for i = 1, 40 do
    local name = ReadAura(unit, i, "HELPFUL|PLAYER")
    if name then
      mineCount = mineCount + 1
      mineScratch[Key(name)] = true
      -- One of your blessings being up is proof you can cast it.
      if unit == "player" and IsKeptBlessing(name) then Learn(name) end
    end
  end
  local now, readable = GetTime(), 0
  for i = 1, 40 do
    local name, dur, exp, src, icon, spellId = ReadAura(unit, i, "HELPFUL")
    if name then
      readable = readable + 1
      if IsKeptBlessing(name) then
        local key = Key(name)
        local mine
        if mineCount > 0 then
          mine = mineScratch[key] == true
        elseif src then
          local ok, same = pcall(UnitIsUnit, src, "player")
          if ok and not isSecret(same) then mine = same and true or false end
        end
        if unit == "player" then
          -- An aura that appears just after your own cast is the one you cast.
          local p = pendingMine[key]
          if p and now - p < CAST_WINDOW and exp then
            mineExp[key] = exp
            pendingMine[key] = nil
          end
          if mine == nil and exp and mineExp[key] then mine = (mineExp[key] == exp) end
          if dur and dur > 0 then lastDur[key] = dur end
        end
        if icon then icons[key] = icon end
        out[key] = { dur = dur, exp = exp, mine = mine, rank = spellId and RANK_OF[spellId] }
      end
    end
  end
  return out, readable
end

-- The blessings you could usefully cast on a unit, given what is on it: none at all if
-- one of yours is already there, otherwise each one it lacks or that you outrank.
local function Castable(view, out)
  wipe(out)
  for _, name in ipairs(known) do
    local key = Key(name)
    local a = view[key]
    if a and a.mine then
      wipe(out)
      return out, true
    end
    if not a or (a.rank and myRank[key] and myRank[key] > a.rank) then
      out[#out + 1] = key
    end
  end
  return out, false
end

-- Icons are frames rather than bare textures so Blizzard's spell-alert glow, the game's
-- own "press this now", can be attached to them. dir < 0 packs right to left from the
-- parent's bottom-right corner, dir > 0 left to right from its bottom-left.
local function AddIconArt(t)
  t.icon = t:CreateTexture(nil, "ARTWORK")
  t.icon:SetAllPoints()
  t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)  -- trim the icon border
  -- Used only if this client has no action-button glow to borrow.
  t.glow = t:CreateTexture(nil, "OVERLAY")
  t.glow:SetTexture("Interface/SpellActivationOverlay/IconAlert")
  t.glow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
  t.glow:SetPoint("CENTER")
  t.glow:SetSize(ICON_SIZE * 1.4, ICON_SIZE * 1.4)
  t.glow:SetBlendMode("ADD")
  t.glow:Hide()
  -- How many you carry, for an item that stacks, as on an action button.
  t.count = t:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  t.count:SetDrawLayer("OVERLAY", 7)
  t.count:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -1, 1)
  t.count:SetJustifyH("RIGHT")
end

local function MakeIcon(parent, list, i, dir)
  local t = list[i]
  if t then return t end
  t = CreateFrame("Frame", nil, parent)
  t:SetSize(ICON_SIZE, ICON_SIZE)
  local step = (i - 1) * (ICON_SIZE + ICON_GAP)
  if dir > 0 then
    t:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", step, 0)
  else
    t:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -step, 0)
  end
  AddIconArt(t)
  list[i] = t
  return t
end

local function SetGlow(t, on, alpha)
  if on then
    if not t.glowing then
      t.glowing = true
      local shown = false
      if ActionButton_ShowOverlayGlow then shown = pcall(ActionButton_ShowOverlayGlow, t) end
      t.usingFallback = not shown
      if t.usingFallback then t.glow:Show() end
    end
    if t.usingFallback then t.glow:SetAlpha(alpha) end
  elseif t.glowing then
    t.glowing = false
    if ActionButton_HideOverlayGlow then pcall(ActionButton_HideOverlayGlow, t) end
    t.glow:Hide()
  end
end

--------------------------------------------------------------------------------
-- Reminder icons. Each reminder is an entry: { id, icon, click, item or spell or tooltip,
-- glow, desaturate }. Wherever it can be, it is a secure action button, so a click casts
-- the spell or uses the item, and mouseover shows its tooltip.
--
-- The game freezes such buttons in combat: they cannot appear, disappear, move or change
-- what they do. So a reminder that comes up in combat shows at once as a plain icon, with
-- its tooltip but no click, and becomes a button when combat ends; one that goes in combat
-- dims at once and leaves when combat ends. The combat glow works throughout.
--
-- A frame holding such buttons cannot move in combat either, and neither can a frame it is
-- anchored to, so the button rows are anchored where they belong, not to the seal bar,
-- which stays free to show and hide.
--------------------------------------------------------------------------------

local function ShowEntryTooltip(owner, e)
  if not (e and (e.item or e.spell or e.tooltip)) then return end
  GameTooltip:SetOwner(owner, "ANCHOR_TOP")
  if e.item then
    GameTooltip:SetItemByID(e.item)
  elseif e.spell then
    GameTooltip:SetSpellByID(e.spell)
  else
    GameTooltip:SetText(e.tooltip, 1, 1, 1, 1, true)
  end
  GameTooltip:Show()
end

local function HideTooltip()
  GameTooltip:Hide()
end

local function ItemCount(id)
  local f = (C_Item and C_Item.GetItemCount) or GetItemCount
  if not f then return 0 end
  local ok, n = pcall(f, id)
  if ok and not isSecret(n) and type(n) == "number" then return n end
  return 0
end

-- Whether an item stacks, so its count is worth showing: food, lures and poisons do, a
-- sleeping bag does not. Nil until the game has loaded the item.
local stacksOf = {}

local function Stacks(id)
  if stacksOf[id] == nil then
    local size
    local f = C_Item and C_Item.GetItemMaxStackSizeByID
    if f then
      local ok, n = pcall(f, id)
      if ok and not isSecret(n) and type(n) == "number" then size = n end
    end
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not size and info then
      local ok, _, _, _, _, _, _, _, n = pcall(info, id)
      if ok and not isSecret(n) and type(n) == "number" then size = n end
    end
    if size then stacksOf[id] = size > 1 end
  end
  return stacksOf[id]
end

local function CountText(e)
  if not (e.item and Stacks(e.item)) then return "" end
  local n = ItemCount(e.item)
  return n > 9999 and "*" or tostring(n)
end

-- Greyed, and glowing in combat, for something missing; in full colour and unlit for
-- something you could do (desaturate = false). Dimmed while it waits to go.
local function Style(t, e, combat, pulse, dimmed)
  t.icon:SetTexture(e.icon)
  local count = CountText(e)
  if t.countText ~= count then
    t.countText = count
    t.count:SetText(count)
  end
  t.count:SetAlpha(dimmed and 0.25 or 1)
  if not e.desaturate then
    t.icon:SetDesaturated(false)
    t.icon:SetAlpha(dimmed and 0.25 or 0.9)
    SetGlow(t, false)
  else
    t.icon:SetDesaturated(true)
    t.icon:SetAlpha(dimmed and 0.25 or (combat and 1 or 0.65))
    SetGlow(t, not dimmed and combat and e.glow, pulse)
  end
end

-- Plain icons, for reminders that can't be buttons until combat ends.
local function NewPlainRow(dir)
  local row = { panel = CreateFrame("Frame", nil, UIParent), icons = {}, dir = dir }
  row.panel:SetSize(ICON_SIZE, ICON_SIZE)
  row.panel:Hide()
  return row
end

local function DrawPlainRow(row, entries, combat, pulse)
  local n = #entries
  for i, e in ipairs(entries) do
    local t = row.icons[i]
    if not t then
      t = MakeIcon(row.panel, row.icons, i, row.dir)
      t:EnableMouse(true)
      t:SetScript("OnEnter", function(self) ShowEntryTooltip(self, self.entry) end)
      t:SetScript("OnLeave", HideTooltip)
    end
    t.entry = e
    Style(t, e, combat, pulse)
    t:Show()
  end
  for i = n + 1, #row.icons do
    SetGlow(row.icons[i], false)
    row.icons[i].entry = nil
    row.icons[i]:Hide()
  end
  if n == 0 then
    row.panel:Hide()
    return
  end
  row.panel:SetWidth(n * ICON_SIZE + (n - 1) * ICON_GAP)
  row.panel:Show()
end

-- In a rested area - an inn or a city - reminders stay out of the way, except those added
-- with resting = true (such as a lure reminder, for fishing in town). They are kept, not
-- removed, and come back as you leave.
local resting = false

local function Shown(e)
  return e.resting or not resting
end

-- Buttons. dir < 0 packs right to left from the panel's bottom-right corner, dir > 0 left
-- to right from its bottom-left. place puts the panel where it belongs (out of combat);
-- onLayout runs after every layout.
local buttonRows = {}

local function NewButtonRow(parent, dir)
  local row = {
    panel = CreateFrame("Frame", nil, parent), dir = dir,
    entries = {},  -- id -> entry, plus click, removed, laidOut, hasButton
    order = {},    -- ids, oldest first; the oldest sits nearest the anchor
    buttons = {},  -- by position
    shown = 0,     -- buttons laid out
    dirty = false, -- a change is waiting for combat to end
  }
  row.panel:SetSize(1, ICON_SIZE)
  buttonRows[#buttonRows + 1] = row
  return row
end

local function RowButton(row, i)
  local b = row.buttons[i]
  if b then return b end
  b = CreateFrame("Button", nil, row.panel, "SecureActionButtonTemplate")
  b:SetSize(ICON_SIZE, ICON_SIZE)
  local step = (i - 1) * (ICON_SIZE + ICON_GAP)
  if row.dir > 0 then
    b:SetPoint("BOTTOMLEFT", row.panel, "BOTTOMLEFT", step, 0)
  else
    b:SetPoint("BOTTOMRIGHT", row.panel, "BOTTOMRIGHT", -step, 0)
  end
  -- With key-down casting on (ActionButtonUseKeyDown) the template acts on the press,
  -- so both halves of a click have to reach it.
  b:RegisterForClicks("AnyUp", "AnyDown")
  AddIconArt(b)
  b:SetHighlightTexture("Interface/Buttons/ButtonHilight-Square", "ADD")
  b:SetScript("OnEnter", function(self) ShowEntryTooltip(self, self.id and row.entries[self.id]) end)
  b:SetScript("OnLeave", HideTooltip)
  row.buttons[i] = b
  return b
end

-- Out of combat only: makes the buttons match the entries.
local function LayoutRow(row)
  if InCombatLockdown() then
    row.dirty = true
    return
  end
  row.dirty = false
  if row.place and not row.placed then
    row.place()
    row.placed = true
  end
  for i = #row.order, 1, -1 do
    local id = row.order[i]
    if row.entries[id].removed then
      row.entries[id] = nil
      table.remove(row.order, i)
    end
  end
  local n = 0
  for _, id in ipairs(row.order) do
    local e = row.entries[id]
    -- Up to date either way: a button if it's shown, none while resting hides it.
    e.laidOut, e.hasButton = true, Shown(e)
    if e.hasButton then
      n = n + 1
      local b = RowButton(row, n)
      for k in pairs(b.attributes or {}) do
        b:SetAttribute(k, nil)
      end
      b.attributes = e.click
      for k, v in pairs(e.click or {}) do
        b:SetAttribute(k, v)
      end
      b.id = id
      b:Show()
    end
  end
  for i = n + 1, #row.buttons do
    local b = row.buttons[i]
    SetGlow(b, false)
    b.id = nil
    b:Hide()
  end
  row.shown = n
  if row.onLayout then row.onLayout() end
end

local function SameClick(a, b)
  if a == b then return true end
  if not (a and b) then return false end
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- Adds or updates a reminder. Only a new one, or a new click, needs a new layout; the
-- look and tooltip are read live.
local function RowAdd(row, id, info)
  local click
  if type(info.click) == "table" then
    click = {}
    for k, v in pairs(info.click) do click[k] = v end
  end
  local e = row.entries[id]
  if not e then
    e = {}
    row.entries[id] = e
    row.order[#row.order + 1] = id
  end
  e.icon = info.icon or "Interface/Icons/INV_Misc_QuestionMark"
  e.tooltip, e.glow, e.desaturate = info.tooltip, info.glow ~= false, info.desaturate ~= false
  e.item, e.spell = tonumber(info.item), tonumber(info.spell)
  local wasShown = Shown(e)
  e.resting = info.resting == true
  if not e.laidOut or not SameClick(e.click, click) or Shown(e) ~= wasShown then
    e.click, e.removed, e.laidOut = click, nil, false
    LayoutRow(row)
  elseif e.removed then
    e.removed = nil  -- wanted again before it went; its button still does the right thing
  end
end

local function RowRemove(row, id)
  local e = row.entries[id]
  if not e or e.removed then return end
  e.removed = true
  LayoutRow(row)
end

-- The entries to show that have no up-to-date button yet, into out.
local function Pending(row, out)
  wipe(out)
  for _, id in ipairs(row.order) do
    local e = row.entries[id]
    if Shown(e) and not e.removed and not (e.laidOut and e.hasButton) then out[#out + 1] = e end
  end
  return out
end

local function DrawRow(row, combat, pulse)
  for i = 1, row.shown do
    local b = row.buttons[i]
    local e = b.id and row.entries[b.id]
    if e then Style(b, e, combat, pulse, e.removed or not e.laidOut or not Shown(e)) end
  end
end

-- Notices entering or leaving a rested area and lays the rows out again (after combat, if
-- in it). Returns nothing; called every refresh and on PLAYER_UPDATE_RESTING.
local function UpdateResting()
  local now = IsResting() == true
  if now == resting then return end
  resting = now
  for _, row in ipairs(buttonRows) do
    LayoutRow(row)
  end
end

-- Brings one source's reminders up to date: adds every entry in wanted and removes the
-- rest of the ones it added before (owned: id -> true).
local function Sync(row, owned, wanted)
  local keep = {}
  for _, e in ipairs(wanted) do
    keep[e.id] = true
    owned[e.id] = true
    RowAdd(row, e.id, e)
  end
  for id in pairs(owned) do
    if not keep[id] then
      owned[id] = nil
      RowRemove(row, id)
    end
  end
end

--------------------------------------------------------------------------------
-- On you: reminders beside the seal bar for whatever of yours is missing - a blessing
-- on a Paladin, and any weapon enchant or buff listed for your class - plus reminders
-- other addons add through Upkeep.AddReminder. They run rightwards along the top of the
-- seal bar from its top-left corner: buttons first, plain icons after them.
--------------------------------------------------------------------------------

local selfRow = NewButtonRow(UIParent, 1)
local selfPlain = NewPlainRow(1)

-- Plain icons start after the buttons.
local function ShiftSelfPlain()
  local shift = selfRow.shown * (ICON_SIZE + ICON_GAP)
  selfPlain.panel:ClearAllPoints()
  selfPlain.panel:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", shift, 2)
end
selfRow.onLayout = ShiftSelfPlain
ShiftSelfPlain()

-- Out of combat only. Puts the button row where the seal bar's top-left corner is,
-- matching PlaceBar's arithmetic.
local function PlaceSelfRow()
  local panel = selfRow.panel
  panel:ClearAllPoints()
  local hb = PlayerHealthBar()
  local hbWidth = hb and hb:GetWidth()
  local w, h = bar:GetWidth(), bar:GetHeight()
  if hbWidth and hbWidth > 0 then
    panel:SetPoint("BOTTOMLEFT", hb, "TOP", -w / 2, BAR_GAP + h + 2)
  else
    panel:SetPoint("BOTTOMLEFT", UIParent, "CENTER", -w / 2, BAR_FALLBACK_Y + h / 2 + 2)
  end
end
selfRow.place = PlaceSelfRow

-- The public API. id names the reminder; adding an id again updates it.
-- info.icon:       texture path or file id.
-- info.click:      secure action attributes for a click, e.g. { type = "spell", spell = 71 }
--                  or { type = "focus", unit = "party1" }. Without it a click does nothing.
-- info.item:       an item id; mouseover shows that item's own tooltip, and if it stacks
--                  the icon shows how many you carry.
-- info.spell:      a spell id; mouseover shows that spell's own tooltip.
-- info.tooltip:    text shown on mouseover, when neither item nor spell is given.
-- info.glow:       false to stay unlit in combat.
-- info.desaturate: false to show the icon in full colour, unlit.
-- info.resting:    true to show it in rested areas too, where reminders are hidden.
Upkeep = Upkeep or {}

function Upkeep.AddReminder(id, info)
  if type(id) ~= "string" or type(info) ~= "table" then
    error("Usage: Upkeep.AddReminder(id, info) with a string id and an info table", 2)
  end
  RowAdd(selfRow, id, info)
end

function Upkeep.RemoveReminder(id)
  RowRemove(selfRow, id)
end

local selfAuras, selfView, selfList = {}, {}, {}
local blessingShown  -- the blessing reminder's last answer, kept when a read fails

-- The reminder for a missing blessing of yours, or nil. A click casts it on you.
local function BlessingReminder()
  if #known == 0 then
    blessingShown = nil
    return
  end
  local ok, auras, readable = pcall(ReadBlessings, "player", selfAuras)
  if not ok then return blessingShown end  -- keep showing what we had rather than blank out
  local live = AurasTrusted(readable, "player")
  local haveData = live
  local now = GetTime()
  wipe(selfView)
  for _, name in ipairs(known) do
    local key = Key(name)
    local a
    if live then
      a = auras[key]
      lastKnown[key] = a or false
      if not a then mineExp[key] = nil end
    else
      -- Nothing is readable in combat: carry the last reading forward until it expires.
      -- With nothing ever read, absence is unproven, so the icon stays hidden.
      if lastKnown[key] ~= nil then haveData = true end
      a = lastKnown[key] or nil
      if a and a.exp and a.exp <= now then a = nil end
    end
    selfView[key] = a
    if a and a.mine then lastMine = key end  -- the one to suggest next time
  end
  local list, anyMine = Castable(selfView, selfList)
  if not haveData or anyMine or #list == 0 then
    blessingShown = nil
    return
  end
  local pick = list[1]
  for _, key in ipairs(list) do
    if key == lastMine then pick = key end
  end
  blessingShown = BlessingEntry("Upkeep.blessing", pick, "player")
  return blessingShown
end

-- Weapon enchants from WEAPON_ENCHANTS, for this class.
local WEAPON_SLOTS = { 16, 17 }  -- main hand, then off hand when it holds a weapon
local ITEM_CLASS_WEAPON = Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2
local TIME_UNITS = { sec = 1, min = 60, hour = 3600, hr = 3600 }

-- The options, each given best: the highest rank you can apply now, nil if none; and
-- icon to match.
local weaponOptions = WEAPON_ENCHANTS[class] or {}
local WEAPON_SPELL_OF = {}  -- spell id -> { option, rank }
for i, opt in ipairs(weaponOptions) do
  for rank, id in ipairs(opt.spells or {}) do WEAPON_SPELL_OF[id] = { option = i, rank = rank } end
end

local weaponState = {}  -- slot -> { option, rank, exp } if enchanted, false if not, nil before a reading
local weaponLast = {}   -- slot -> the option last seen on that weapon
local lastWeaponOption  -- the option last cast, for a weapon that has shown none yet

local function ItemIcon(id)
  local f = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  if not f then return end
  local ok, t = pcall(f, id)
  if ok and t ~= nil and not isSecret(t) then return t end
end

-- Which options you can apply, and at what rank: a spell you know, or an item you carry.
-- bestSpell or bestItem is what a click on the reminder uses.
local function SeedWeaponEnchants()
  for _, opt in ipairs(weaponOptions) do
    opt.best, opt.bestSpell, opt.bestItem = nil, nil, nil
    for rank, id in ipairs(opt.spells or {}) do
      local ok, isKnown = pcall(IsSpellKnown, id)
      if ok and isKnown then
        opt.best, opt.bestSpell = rank, id  -- ranks go up, so the last one found is the highest
        opt.icon = SpellTexture(id) or opt.icon
      end
    end
    for rank, id in ipairs(opt.items or {}) do
      if ItemCount(id) > 0 then
        opt.best, opt.bestSpell, opt.bestItem = rank, nil, id
        opt.icon = ItemIcon(id) or opt.icon
      end
    end
  end
end

-- A weapon enchant reminder: a click casts the enchant, or uses the item on that weapon.
local function WeaponEntry(slot, opt)
  local e = { id = "Upkeep.weapon" .. slot, icon = opt.icon or "Interface/Icons/INV_Misc_QuestionMark" }
  if opt.bestSpell then
    e.spell = opt.bestSpell
    e.click = { type = "spell", spell = opt.bestSpell }
  elseif opt.bestItem then
    e.item = opt.bestItem
    e.click = { type = "macro", macrotext = "/use item:" .. opt.bestItem .. "\n/use " .. slot }
  end
  return e
end

-- Whether a slot holds something that can be enchanted: the main hand always, the off
-- hand only when it is a weapon rather than a shield or an off-hand item.
local function HasWeapon(slot)
  local ok, isWeapon = pcall(function()
    local id = GetInventoryItemID("player", slot)
    if isSecret(id) or id == nil then return false end
    if slot == 16 then return true end
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    return select(6, getInfo(id)) == ITEM_CLASS_WEAPON
  end)
  return ok and isWeapon
end

local FISHING_POLE = Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole or 20

local function HoldingFishingPole()
  local ok, isPole = pcall(function()
    local id = GetInventoryItemID("player", 16)
    if isSecret(id) or id == nil then return false end
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local _, _, _, _, _, classID, subclassID = getInfo(id)
    return classID == ITEM_CLASS_WEAPON and subclassID == FISHING_POLE
  end)
  return ok and isPole
end

local function Roman(numeral)
  local values = { I = 1, V = 5, X = 10 }
  local total, highest = 0, 0
  for i = #numeral, 1, -1 do
    local v = values[numeral:sub(i, i)]
    if v < highest then
      total = total - v
    else
      total = total + v
      highest = v
    end
  end
  return total
end

-- The rank in what follows an enchant's name on the tooltip: " 2", " II", or nothing
-- for rank 1. nil when something else follows, such as "Windfury Totem 1".
local function RankAfterName(rest)
  local n = rest:match("^ (%d+)")
  if n then return tonumber(n) end
  local numeral = rest:match("^ ([IVX]+)%f[%A]")
  if numeral then return Roman(numeral) end
  if rest == "" or rest:find("^ %(") then return 1 end
end

-- Reads a weapon's tooltip. Returns the option, its rank, its expiry (when the line
-- gives a time) and the line; false if the tooltip is readable but names none of your
-- options; nil if nothing on it is readable. The tooltip names the enchant, so a
-- whetstone or a totem's weapon buff does not count. (GetWeaponEnchantInfo is no use
-- here: this client answers it with "no enchant" even when there is one.)
local function TooltipEnchant(slot)
  if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then return end
  local ok, option, rank, exp, line = pcall(function()
    local data = C_TooltipInfo.GetInventoryItem("player", slot)
    if not data or not data.lines then return nil end
    local readable = 0
    for _, l in ipairs(data.lines) do
      local text = l.leftText
      if not isSecret(text) and type(text) == "string" then
        readable = readable + 1
        for i, opt in ipairs(weaponOptions) do
          local r = text:sub(1, #opt.tooltip) == opt.tooltip and RankAfterName(text:sub(#opt.tooltip + 1))
          if r then
            local secs
            for amount, unit in text:gmatch("%((%d+) (%a+)%)") do
              if TIME_UNITS[unit] then
                secs = tonumber(amount) * TIME_UNITS[unit]
                break
              end
            end
            return i, r, secs and (GetTime() + secs) or nil, text
          end
        end
      end
    end
    if readable > 0 then return false end
    return nil
  end)
  if ok then return option, rank, exp, line end
end

-- The buff frame's enchant button for a weapon: true and its expiry if shown, false if
-- not, nil if the buff frame cannot be read. Unlike your other buffs it stays readable
-- in combat, and it belongs to one weapon slot, so it can be trusted there.
local function EnchantButton(slot)
  local bf = BuffFrame
  local container = bf and bf.AuraContainer
  if not (container and container.GetChildren) then return end
  local ok, shown, exp = pcall(function()
    -- A hidden or collapsed buff frame hides its buttons too, which proves nothing.
    if not bf:IsVisible() then return nil end
    if bf.IsExpanded and not bf:IsExpanded() then return nil end
    for _, child in ipairs({ container:GetChildren() }) do
      local auraType, info = child.auraType, child.buttonInfo
      if not isSecret(auraType) and auraType == "TempEnchant" and child:IsShown()
        and type(info) == "table" and not isSecret(info.ID) and info.ID == slot then
        local e = info.expirationTime
        return true, not isSecret(e) and type(e) == "number" and e > 0 and e or nil
      end
    end
    return false
  end)
  if ok then return shown, exp end
end

local function ReadWeapon(slot)
  if not UnitAffectingCombat("player") then
    local option, rank, exp = TooltipEnchant(slot)
    if option then
      weaponLast[slot] = option
      local _, buttonExp = EnchantButton(slot)
      weaponState[slot] = { option = option, rank = rank, exp = exp or buttonExp }
      return
    elseif option == false then
      weaponState[slot] = false
      return
    end
  end
  -- In combat, or with the tooltip unreadable: the enchant button. It cannot tell your
  -- enchant from a whetstone, but it does show one ending - poison charges running out
  -- mid-fight - and one being applied.
  local shown, exp = EnchantButton(slot)
  if shown == nil then return end
  local st = weaponState[slot]
  if not shown then
    weaponState[slot] = false
  elseif st then
    st.exp = exp or st.exp
  else
    weaponState[slot] = { exp = exp }
  end
end

-- Adds a reminder to out for each weapon whose enchant is missing or outranked, main hand
-- first.
local function WeaponReminders(out)
  local available
  for i, opt in ipairs(weaponOptions) do
    if opt.best then
      available = i
      break
    end
  end
  if not available then return end
  local now = GetTime()
  for _, slot in ipairs(WEAPON_SLOTS) do
    -- A fishing pole wants a lure, not your class's enchant.
    if HasWeapon(slot) and not (slot == 16 and HoldingFishingPole()) then
      ReadWeapon(slot)
      local st = weaponState[slot]
      -- Nothing read yet means absence is unproven.
      if st ~= nil then
        if st and st.exp and st.exp <= now then st = false end
        -- A lower rank than you can apply counts as missing; an unknown rank does not.
        local opt = st and st.option and weaponOptions[st.option]
        local outranked = opt and st.rank and opt.best and opt.best > st.rank
        -- So does one running out within the class's early warning.
        local early = weaponOptions.early
        local endingSoon = st and st.exp and early and st.exp - now <= early
        if not st or outranked or endingSoon then
          -- The outranked or ending option when you can apply it, else the one last on
          -- this weapon, else the one last cast, else the first you can apply.
          local pick = (outranked or (endingSoon and opt and opt.best)) and st.option or nil
          local seen = weaponLast[slot]
          if not pick and seen and weaponOptions[seen].best then pick = seen end
          if not pick and lastWeaponOption and weaponOptions[lastWeaponOption].best then
            pick = lastWeaponOption
          end
          pick = pick or available
          local entry = WeaponEntry(slot, weaponOptions[pick])
          -- An early warning for one still up doesn't glow; only a gap does.
          entry.glow = not st or outranked or false
          out[#out + 1] = entry
        end
      end
    end
  end
end

-- Self buffs from SELF_BUFFS, for this class.
local SELF_BUFF_DURATION = 600  -- for an entry that gives none

-- One entry per reminder icon. Per spell in its set (by position): known = highest rank
-- you know, icons, names, dur = duration last seen on you. state is the last reading:
-- { exp, spell, rank } if one of the set is up, false if none is, nil before any.
-- last is the spell from the set you last had up or cast, the one to suggest.
local selfBuffs = {}
local SELF_BUFF_OF = {}  -- spell id -> { entry, spell, rank }
-- Your class's entries first, so they sit nearer the seal bar's corner.
for _, list in ipairs({ SELF_BUFFS[class] or {}, SELF_BUFFS.ALL }) do
  for _, spells in ipairs(list) do
    local e = { spells = spells, known = {}, icons = {}, names = {}, dur = {} }
    selfBuffs[#selfBuffs + 1] = e
    for sp, ranks in ipairs(spells) do
      for rank, id in ipairs(ranks) do SELF_BUFF_OF[id] = { entry = e, spell = sp, rank = rank } end
    end
  end
end

local function SeedSelfBuffs()
  if not IsSpellKnown then return end
  for _, e in ipairs(selfBuffs) do
    wipe(e.known)
    for sp, ranks in ipairs(e.spells) do
      for rank, id in ipairs(ranks) do
        local ok, isKnown = pcall(IsSpellKnown, id)
        -- A spell from a rune can be missing from IsSpellKnown but still be yours.
        if not (ok and isKnown) and IsPlayerSpell then ok, isKnown = pcall(IsPlayerSpell, id) end
        if ok and isKnown then
          e.known[sp] = rank  -- ranks go up, so the last one known is the highest
          e.icons[sp] = SpellTexture(id) or e.icons[sp] or "Interface/Icons/INV_Misc_QuestionMark"
          e.names[sp] = e.names[sp] or SpellName(id)
        end
      end
    end
  end
end

-- The entry and spell an aura belongs to: by spell id, or by name when the id is hidden.
local function SelfBuffOf(name, spellId)
  local b = spellId and SELF_BUFF_OF[spellId]
  if b then return b.entry, b.spell, b.rank end
  for _, e in ipairs(selfBuffs) do
    for sp in ipairs(e.spells) do
      if e.names[sp] == name then return e, sp end
    end
  end
end

-- One scan of your auras updates every entry. In combat nothing is readable, so each
-- keeps its last reading, carried forward until it would run out: a buff that ends
-- early mid-fight (Lightning Shield running out of charges) shows once combat ends.
local selfBuffScratch = {}
local function ReadSelfBuffs()
  if #selfBuffs == 0 then return end
  wipe(selfBuffScratch)
  local readable = 0
  for i = 1, 40 do
    local name, dur, exp, _, _, spellId = ReadAura("player", i, "HELPFUL")
    if name then
      readable = readable + 1
      local e, sp, rank = SelfBuffOf(name, spellId)
      if e then
        if dur and dur > 0 then e.dur[sp] = dur end
        selfBuffScratch[e] = { exp = exp, spell = sp, rank = rank }
      end
    end
  end
  if not AurasTrusted(readable, "player") then return end
  for _, e in ipairs(selfBuffs) do
    e.state = selfBuffScratch[e] or false
    if e.state then e.last = e.state.spell end
  end
end

-- Adds a reminder to out for every entry that is missing or outranked, in table order. A
-- click casts your best rank of the spell it suggests.
local function SelfBuffReminders(out)
  ReadSelfBuffs()
  local now = GetTime()
  for i, e in ipairs(selfBuffs) do
    local st = e.state
    local pick  -- the spell to remind you of, by position in the set; nil if nothing is missing
    local gap = false  -- missing or outranked, rather than just ending soon
    -- Nothing known means nothing to cast; nothing read yet means absence is unproven.
    if next(e.known) and st ~= nil then
      if st and st.exp and st.exp > 0 and st.exp <= now then st = false end
      -- A lower rank of the spell that is up than you know counts as missing; a rank
      -- that cannot be read does not, so it never nags without reason.
      local best = st and e.known[st.spell]
      local outranked = st and st.rank and best and best > st.rank
      -- So does one running out within the entry's early warning.
      local early = e.spells.early
      local endingSoon = st and st.exp and st.exp > 0 and early and st.exp - now <= early
      if not st or outranked or endingSoon then
        gap = not st or outranked or false
        -- The outranked or ending spell when you know it, else the one from the set you
        -- last had up, else the first one you know.
        pick = (outranked or (endingSoon and best)) and st.spell or (e.known[e.last] and e.last)
        if not pick then
          for sp = 1, #e.spells do
            if e.known[sp] then
              pick = sp
              break
            end
          end
        end
      end
    end
    if pick then
      local spell = e.spells[pick][e.known[pick]]
      out[#out + 1] = {
        id = "Upkeep.selfbuff" .. i, icon = e.icons[pick], spell = spell,
        click = { type = "spell", spell = spell },
        glow = gap,  -- an early warning for one still up doesn't glow; only a gap does
      }
    end
  end
end

--------------------------------------------------------------------------------
-- Experience bonuses, below the level cap:
--   * Food that adds experience: with some in your bags and not Well Fed with an
--     experience bonus, a reminder offers the best of it; a click starts eating. Food
--     that raises Fishing skill is left for fishing.
--   * A Cozy Sleeping Bag: with one in your bags and off cooldown, a reminder offers it
--     while you're not fully Well-Rested - under three stacks, each a minute's rest - or
--     have less than ten minutes of it left, when a minute's rest tops it up instead of
--     three building it again; a click unfurls it.
-- Neither comes up in combat, where you can't use them, and neither glows. They are
-- recognised by English text: "experience" on the food's and the buffs' tooltips, and the
-- sleeping bag and buff names.
--------------------------------------------------------------------------------

local XP_TEXT = "xperience"  -- "Experience ..." or "... experience gained from kills ..."
local FISHING_FOOD_TEXT = "Fishing Skill"  -- food such as Filet of Redgill, kept for fishing
local USE_TEXT = "Use:"       -- starts the tooltip line with the use spell's description
local FOOD_BUFF = "Well Fed"
local SLEEPING_BAG = "Cozy Sleeping Bag"
local BAG_BUFF = "Well-Rested"
local BAG_STACKS = 3          -- Well-Rested's full strength
local BAG_EARLY = 10 * 60     -- seconds left at which to top it up
local XP_CHECK = 1           -- seconds between looks at your buffs
local XP_RETRIES = 5         -- times to look again for items still loading
local ITEM_CLASS_CONSUMABLE = Enum and Enum.ItemClass and Enum.ItemClass.Consumable or 0

local xpFoodOf = {}     -- item id -> true if its text promises experience, false if not (yet)
local xpFoods = {}      -- item ids of such food in your bags
local consumables = {}  -- item ids of every consumable in your bags, for /upkeep debug
local sleepingBag       -- item id of a sleeping bag in your bags
local xpCheckAt = 0
local foodEntry, bagEntry  -- the reminders while they're wanted
local xpRetries, xpRetryPending = 0, false

local function TooltipSays(data, text)
  for _, line in ipairs(data.lines) do
    local t = line.leftText
    if not isSecret(t) and type(t) == "string" and t:find(text, 1, true) then return true end
  end
  return false
end

-- Whether a consumable's text has loaded, and its use spell's description. Item and
-- spell data load in the background, and until they have, the tooltip has no "Use:"
-- line: it would look like food without an experience bonus. Asks for whatever is
-- missing; false means look again later.
local function UseText(id)
  if C_Item.IsItemDataCachedByID and not C_Item.IsItemDataCachedByID(id) then
    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    return false
  end
  local getSpell = C_Item.GetItemSpell or GetItemSpell
  local spell = getSpell and select(2, getSpell(id))
  if type(spell) ~= "number" or isSecret(spell) or not C_Spell then return true end
  local cached = C_Spell.IsSpellDataCached
  if cached and not cached(spell) then
    if C_Spell.RequestLoadSpellData then C_Spell.RequestLoadSpellData(spell) end
    return false
  end
  local desc = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spell)
  if isSecret(desc) or type(desc) ~= "string" then return true end
  -- Without a way to ask, an empty description is taken to be still loading.
  if desc == "" and not cached then return false end
  return true, desc
end

-- Whether a consumable's text promises experience: true or false, or nil while its text
-- is still loading. Food whose use spell hasn't loaded has no "Use:" line yet, and
-- GetItemSpell may not name that spell yet either, so food without one isn't judged.
-- Fishing food is kept for fishing, whatever else it gives.
local function XPVerdict(id, bag, slot)
  local ready, desc = UseText(id)
  if not ready then return nil end
  local ok, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
  if not (ok and data and data.lines) then return nil end
  if desc == "" then desc = nil end
  if desc == nil and not TooltipSays(data, USE_TEXT) then return nil end
  local function Says(text)
    return TooltipSays(data, text) or (desc ~= nil and desc:find(text, 1, true) ~= nil)
  end
  return Says(XP_TEXT) and not Says(FISHING_FOOD_TEXT)
end

local function MaxLevel()
  local ok, cap = pcall(GetMaxLevelForPlayerExpansion)
  if ok and type(cap) == "number" and cap > 0 then return cap end
  return MAX_PLAYER_LEVEL
end

-- Looks through your bags for experience food and a sleeping bag. Each kind of consumable
-- is asked about once its text has loaded; anything still loading is asked again a
-- little later. retry is true for those later looks.
local function SeedXP(retry)
  wipe(xpFoods)
  wipe(consumables)
  sleepingBag = nil
  if not (C_Container and C_TooltipInfo and C_TooltipInfo.GetBagItem) then return end
  if not retry then xpRetries = 0 end
  local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  local seen, loading = {}, false
  for bag = 0, tonumber(NUM_BAG_SLOTS) or 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local id = C_Container.GetContainerItemID(bag, slot)
      if id and not isSecret(id) and not seen[id] then
        seen[id] = true
        local name = C_Item.GetItemNameByID(id)
        if name == SLEEPING_BAG then
          sleepingBag = id
        elseif name == nil then
          loading = true
        end
        if select(6, getInfo(id)) == ITEM_CLASS_CONSUMABLE then
          consumables[#consumables + 1] = id
          -- A yes holds for the session. A no is read again at each look, in case it
          -- was read before all of the text had loaded.
          if not xpFoodOf[id] then
            local verdict = XPVerdict(id, bag, slot)
            if verdict == nil then loading = true else xpFoodOf[id] = verdict end
          end
          if xpFoodOf[id] then xpFoods[#xpFoods + 1] = id end
        end
      end
    end
  end
  if loading and xpRetries < XP_RETRIES and not xpRetryPending then
    xpRetries = xpRetries + 1
    xpRetryPending = true
    C_Timer.After(3, function()
      xpRetryPending = false
      SeedXP(true)
    end)
  end
end

-- The names of the buffs on you that mention experience, as a set, and whether the scan
-- can be trusted to have seen every buff. into, if given, collects the names in order.
local function XPBuffs(into)
  local names, readable = {}, 0
  if not (C_TooltipInfo and C_TooltipInfo.GetUnitAura) then return names, false end
  for i = 1, 40 do
    local ok, data = pcall(C_TooltipInfo.GetUnitAura, "player", i, "HELPFUL")
    if not ok or not data or not data.lines then break end
    readable = readable + 1
    if TooltipSays(data, XP_TEXT) then
      local name = data.lines[1] and data.lines[1].leftText
      if not isSecret(name) and type(name) == "string" then
        names[name] = true
        if into then into[#into + 1] = name end
      end
    end
  end
  return names, AurasTrusted(readable, "player")
end

-- true if the buff is on you, false if it's surely not, nil if that can't be told.
local function BuffState(names, trusted, buff)
  if names[buff] then return true end
  if trusted then return false end
end

-- Well-Rested's stacks and seconds left, or nil if it isn't on you or can't be read.
local function WellRested()
  local find = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
  if not find then return end
  local ok, aura = pcall(find, "player", BAG_BUFF, "HELPFUL")
  if not ok or not aura then return end
  local stacks, exp = aura.applications, aura.expirationTime
  if isSecret(stacks) or isSecret(exp) or type(exp) ~= "number" then return end
  local left = exp > 0 and exp - GetTime() or math.huge
  return math.max(tonumber(stacks) or 0, 1), left
end

local function OnCooldown(id)
  local ok, start, duration = pcall(C_Container.GetItemCooldown, id)
  -- The global cooldown alone doesn't count.
  return ok and type(duration) == "number" and duration > 1.5 and start + duration > GetTime()
end

-- The best food you can eat, as a reminder: the highest item level, then the biggest stack.
-- The one already shown is kept while it's still the pick.
local function BestFood()
  local best, bestLevel, bestCount
  for _, id in ipairs(xpFoods) do
    if C_Item.IsUsableItem(id) then
      local itemLevel = select(4, C_Item.GetItemInfo(id)) or 0
      local count = ItemCount(id)
      if not best or itemLevel > bestLevel or (itemLevel == bestLevel and count > bestCount) then
        best, bestLevel, bestCount = id, itemLevel, count
      end
    end
  end
  if not best then return nil end
  if foodEntry and foodEntry.item == best then return foodEntry end
  return {
    id = "Upkeep.xpfood", icon = ItemIcon(best), item = best,
    click = { type = "item", item = "item:" .. best }, glow = false,
  }
end

local function XPReminders(out)
  local level, cap = UnitLevel("player"), MaxLevel()
  if (#xpFoods == 0 and not sleepingBag) or type(level) ~= "number" or type(cap) ~= "number" or level >= cap then
    foodEntry, bagEntry = nil, nil
    return
  end
  -- In combat they stay as they were: they don't come up, and one already there waits.
  local now = GetTime()
  if not UnitAffectingCombat("player") and now >= xpCheckAt then
    xpCheckAt = now + XP_CHECK
    local names, trusted = XPBuffs()
    local fed = BuffState(names, trusted, FOOD_BUFF)
    if fed then
      foodEntry = nil
    elseif fed == false then
      foodEntry = BestFood()
    end
    -- wanted stays nil when that can't be told, and the reminder stays as it was.
    local rested, wanted = BuffState(names, trusted, BAG_BUFF), nil
    if rested == false then
      wanted = true
    elseif rested then
      local stacks, left = WellRested()
      wanted = stacks ~= nil and (stacks < BAG_STACKS or left < BAG_EARLY)
    end
    if not sleepingBag or wanted == false or OnCooldown(sleepingBag) then
      bagEntry = nil
    elseif wanted and not (bagEntry and bagEntry.item == sleepingBag) then
      bagEntry = {
        id = "Upkeep.sleepingbag", icon = ItemIcon(sleepingBag), item = sleepingBag,
        click = { type = "item", item = "item:" .. sleepingBag }, glow = false,
      }
    end
  end
  if foodEntry then out[#out + 1] = foodEntry end
  if bagEntry then out[#out + 1] = bagEntry end
end

local selfOwned, selfWanted, selfPending = {}, {}, {}

local function Pulse()
  return 0.4 + 0.6 * math.abs(math.sin(GetTime() * math.pi * 1.5))
end

-- Blessing, weapon enchants, self buffs, food and sleeping bag, in the order they first came up.
local function UpdateSelf()
  UpdateResting()
  wipe(selfWanted)
  if isPaladin then
    selfWanted[#selfWanted + 1] = BlessingReminder()
  end
  WeaponReminders(selfWanted)
  SelfBuffReminders(selfWanted)
  XPReminders(selfWanted)
  Sync(selfRow, selfOwned, selfWanted)
  local combat, pulse = UnitAffectingCombat("player"), Pulse()
  DrawPlainRow(selfPlain, Pending(selfRow, selfPending), combat, pulse)
  DrawRow(selfRow, combat, pulse)
end

--------------------------------------------------------------------------------
-- On your target: one icon per blessing you could still usefully cast on them.
-- Duration is ignored; the question is only whether a cast of yours would add anything.
--------------------------------------------------------------------------------

local TARGET_X, TARGET_Y = 23, -22  -- from the target frame's top-left corner

-- The buttons are children of the target frame, so they go when it does, even in combat.
-- Nothing on a target is readable in combat, and targets change too often to carry an old
-- reading forward, so a secure state driver hides the row in combat.
local targetRow = NewButtonRow(TargetFrame or UIParent, 1)
local targetPlain = NewPlainRow(1)

-- Anchored by the bottom-left corner to the target frame, so the row grows rightwards and
-- follows the target frame wherever the client lays it out. Out of combat only.
local function TargetAnchor(frame, shift)
  frame:ClearAllPoints()
  if TargetFrame then
    frame:SetPoint("BOTTOMLEFT", TargetFrame, "TOPLEFT", TARGET_X + shift, TARGET_Y)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", shift, -120)
  end
end

-- Plain icons start after the buttons.
local function ShiftTargetPlain()
  TargetAnchor(targetPlain.panel, targetRow.shown * (ICON_SIZE + ICON_GAP))
end
targetRow.onLayout = ShiftTargetPlain

local function PlaceTargetRow()
  TargetAnchor(targetRow.panel, 0)
  if TargetFrame then
    targetRow.panel:SetFrameLevel(TargetFrame:GetFrameLevel() + 20)
  end
  if not targetRow.driven then
    targetRow.driven = true
    RegisterStateDriver(targetRow.panel, "visibility", "[combat] hide; show")
  end
  ShiftTargetPlain()
end
targetRow.place = PlaceTargetRow

local targetOwned, targetWanted, targetPending = {}, {}, {}
local targetAuras, targetList = {}, {}

-- One reminder per blessing you could still usefully cast on your target, in full colour;
-- a click casts it on them. Duration is ignored; the question is only whether a cast of
-- yours would add anything.
local function UpdateTarget()
  wipe(targetWanted)
  if isPaladin and #known > 0 and UnitExists("target")
    and not UnitIsDead("target") and not UnitIsUnit("target", "player") then
    local okA, assist = pcall(UnitCanAssist, "player", "target")
    if okA and assist then
      local ok, auras, readable = pcall(ReadBlessings, "target", targetAuras)
      if ok and AurasTrusted(readable, "target") then
        for _, key in ipairs(Castable(auras, targetList)) do
          local e = BlessingEntry("Upkeep.target." .. key, key, "target")
          e.desaturate, e.glow = false, false  -- casts you could make, not a gap
          targetWanted[#targetWanted + 1] = e
        end
      end
    end
  end
  Sync(targetRow, targetOwned, targetWanted)
  local combat, pulse = UnitAffectingCombat("player"), Pulse()
  DrawPlainRow(targetPlain, Pending(targetRow, targetPending), combat, pulse)
  DrawRow(targetRow, combat, pulse)
end

--------------------------------------------------------------------------------
-- Driving it
--------------------------------------------------------------------------------

local function OnCast(spellID)
  local name = SpellName(spellID)
  if not name then return end
  local w = WEAPON_SPELL_OF[spellID]
  if w then
    lastWeaponOption = w.option
    -- Where the enchant lands is not reported, so take the main hand, where a Shaman's
    -- imbue goes. The enchant button then supplies its expiry, even in combat.
    weaponState[16] = { option = w.option, rank = w.rank }
    return
  end
  local b = SELF_BUFF_OF[spellID]
  if b then
    local e = b.entry
    e.last = b.spell
    local d = e.dur[b.spell] or e.spells.duration or SELF_BUFF_DURATION
    e.state = { exp = GetTime() + d, spell = b.spell, rank = b.rank }
    return
  end
  if name:find(SEAL_PATTERN) then
    sealCast = { name = name, start = GetTime() }
    return
  end
  if not IsKeptBlessing(name) then return end
  Learn(name)
  local key = Key(name)
  icons[key] = icons[key] or SpellTexture(spellID)
  if CastAtSelf() then
    local now = GetTime()
    pendingMine[key] = now
    -- Nothing will be readable if this was in combat, so start the estimate now.
    local d = lastDur[key]
    lastKnown[key] = { dur = d, exp = d and (now + d) or nil, mine = true, rank = RANK_OF[spellID] }
  end
end

-- Each part has its own OnUpdate frame, so an error in one cannot stop the others.
local function Every(interval, fn)
  local since = 0
  local driver = CreateFrame("Frame")
  driver:SetScript("OnUpdate", function(_, elapsed)
    since = since + elapsed
    if since < interval then return end
    since = 0
    fn()
  end)
end
Every(0.05, UpdateSeal)
Every(0.1, UpdateSelf)
Every(0.1, UpdateTarget)

local function Debug()
  print("Upkeep: known = " .. (#known > 0 and table.concat(known, ", ") or "none"))
  wipe(mineScratch)
  local mine = 0
  for i = 1, 40 do
    local name = ReadAura("player", i, "HELPFUL|PLAYER")
    if name then
      mine = mine + 1
      mineScratch[Key(name)] = true
    end
  end
  print(string.format("Upkeep: %d readable aura(s) of yours on you", mine))
  local readable = 0
  for i = 1, 40 do
    if ReadAura("player", i, "HELPFUL") then readable = readable + 1 end
  end
  print(string.format("Upkeep: buffs readable=%d  shown by buff frame=%s  trusted=%s", readable,
    tostring(ShownBuffCount()), tostring(AurasTrusted(readable, "player"))))
  for i = 1, 40 do
    local name, dur, _, _, _, spellId = ReadAura("player", i, "HELPFUL")
    if name then
      local key = Key(name)
      print(string.format("  [%d] %s  id=%s dur=%s mine=%s rank=%s yours=%s", i, name, tostring(spellId),
        tostring(dur), tostring(mineScratch[key] == true), tostring(spellId and RANK_OF[spellId]),
        tostring(myRank[key])))
    end
  end
  -- What the reminder goes on in combat: the last reading of each, carried forward.
  for _, name in ipairs(known) do
    local a = lastKnown[Key(name)]
    print(string.format("  last read: %s  %s", name, a == nil and "never read" or not a and "not on you"
      or string.format("on you, mine=%s left=%s", tostring(a.mine),
        a.exp and string.format("%.0fs", a.exp - GetTime()) or "?")))
  end
  if #weaponOptions > 0 then
    local names = {}
    for _, opt in ipairs(weaponOptions) do
      if opt.best then names[#names + 1] = opt.tooltip .. " r" .. opt.best end
    end
    print("Upkeep: weapon enchants available = " .. (#names > 0 and table.concat(names, ", ") or "none"))
    for _, slot in ipairs(WEAPON_SLOTS) do
      local option, rank, exp, line = TooltipEnchant(slot)
      local shown = EnchantButton(slot)
      local st = weaponState[slot]
      print(string.format("Upkeep: slot %d weapon=%s tooltip=%s rank=%s left=%s (%s) button=%s state=%s",
        slot, tostring(HasWeapon(slot)),
        tostring(option and weaponOptions[option].tooltip or option), tostring(rank),
        exp and string.format("%.0fs", exp - GetTime()) or "nil", tostring(line), tostring(shown),
        st == nil and "not read yet" or (st and tostring(st.option and weaponOptions[st.option].tooltip or "enchanted") or "none")))
      -- The full tooltip, to check how an enchant's line reads on this client.
      if HasWeapon(slot) then
        local ok, data = pcall(C_TooltipInfo and C_TooltipInfo.GetInventoryItem, "player", slot)
        if ok and data and data.lines then
          for i, l in ipairs(data.lines) do
            local text = l.leftText
            print(string.format("  tooltip %d: %s", i, isSecret(text) and "<secret>" or tostring(text)))
          end
        end
      end
    end
  end
  ReadSelfBuffs()
  for i, e in ipairs(selfBuffs) do
    local knownNames = {}
    for sp in ipairs(e.spells) do
      if e.known[sp] then knownNames[#knownNames + 1] = tostring(e.names[sp]) .. " r" .. e.known[sp] end
    end
    local st = e.state
    print(string.format("Upkeep: self buff %d known=%s  up=%s rank=%s left=%s", i,
      #knownNames > 0 and table.concat(knownNames, ", ") or "none",
      st == nil and "not read yet" or (st and tostring(e.names[st.spell]) or "none"),
      tostring(st and st.rank),
      st and st.exp and string.format("%.0fs", st.exp - GetTime()) or "nil"))
  end
  local foods, read = {}, {}
  for _, id in ipairs(xpFoods) do
    foods[#foods + 1] = (C_Item.GetItemNameByID(id) or id) .. (C_Item.IsUsableItem(id) and "" or " (not usable)")
  end
  for _, id in ipairs(consumables) do
    local verdict = xpFoodOf[id]
    read[#read + 1] = string.format("%s %s", C_Item.GetItemNameByID(id) or id,
      verdict == nil and "(not read yet)" or verdict and "(experience)" or "(no)")
  end
  print("Upkeep: consumables in your bags: " .. (#read > 0 and table.concat(read, ", ") or "none"))
  local xpBuffs = {}
  local names, trusted = XPBuffs(xpBuffs)
  print(string.format("Upkeep: level %s of %s, experience food: %s, sleeping bag: %s, buffs mentioning "
    .. "experience: %s, well fed: %s, well rested: %s", tostring(UnitLevel("player")), tostring(MaxLevel()),
    #foods > 0 and table.concat(foods, ", ") or "none",
    sleepingBag and (OnCooldown(sleepingBag) and "on cooldown" or "ready") or "none",
    #xpBuffs > 0 and table.concat(xpBuffs, ", ") or "none",
    tostring(BuffState(names, trusted, FOOD_BUFF)), tostring(BuffState(names, trusted, BAG_BUFF))))
  local stacks, left = WellRested()
  if stacks then
    print(string.format("Upkeep: Well-Rested %d of %d stacks, %.0f min left", stacks, BAG_STACKS, left / 60))
  end
  for _, row in ipairs(buttonRows) do
    for _, id in ipairs(row.order) do
      local e = row.entries[id]
      print(string.format("Upkeep: reminder %s%s%s%s", id, e.click and ", clickable" or "",
        e.laidOut and "" or ", a button after combat", e.removed and ", going when combat ends" or ""))
    end
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("BAG_UPDATE_DELAYED")  -- poisons, food and sleeping bags come and go
events:RegisterEvent("ADDON_ACTION_FORBIDDEN")
events:RegisterEvent("ADDON_ACTION_BLOCKED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")  -- reminder changes held back by combat
events:RegisterEvent("PLAYER_UPDATE_RESTING")  -- entering or leaving a rested area
events:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

-- A succeeded "player" cast is not always one you made: in a group other players'
-- seal casts arrive too, and so do triggered spells such as Seal of Command's hit
-- (20424). A cast only counts when you sent it yourself: castGUID -> when it was sent.
local sentCasts = {}

events:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "PLAYER_LOGIN" then
    PlaceBar()
    resting = IsResting() == true
    -- Place the button rows now the bar has its size (held back if in combat).
    for _, row in ipairs(buttonRows) do
      row.placed = false
      LayoutRow(row)
    end
    SeedKnown()
    SeedWeaponEnchants()
    SeedSelfBuffs()
    SeedXP()
  elseif event == "PLAYER_REGEN_ENABLED" then
    for _, row in ipairs(buttonRows) do
      if row.dirty then LayoutRow(row) end
    end
    -- Redraw in the same frame, so a plain icon hides as its button takes its place
    -- rather than showing beside it until the next refresh.
    UpdateSelf()
    UpdateTarget()
  elseif event == "PLAYER_UPDATE_RESTING" then
    UpdateResting()
    UpdateSelf()
    UpdateTarget()
  elseif event == "BAG_UPDATE_DELAYED" then
    SeedWeaponEnchants()
    SeedXP()
  elseif event == "SPELLS_CHANGED" then
    SeedKnown()
    SeedWeaponEnchants()
    SeedSelfBuffs()
  elseif event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
    -- Name the call, so a new restriction is obvious instead of an anonymous popup.
    if a1 == ADDON then
      print("Upkeep: blocked calling " .. tostring(a2) .. " (" .. event .. ") - please report this.")
    end
  elseif event == "UNIT_SPELLCAST_SENT" then
    -- unit, target, castGUID, spellID. Casts that never land leave an entry behind.
    if isSecret(a3) or not a3 then return end
    local now = GetTime()
    for guid, t in pairs(sentCasts) do
      if now - t > 30 then sentCasts[guid] = nil end
    end
    sentCasts[a3] = now
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    -- unit, castGUID, spellID
    if isSecret(a2) or isSecret(a3) then return end
    if not (a2 and sentCasts[a2]) then return end
    sentCasts[a2] = nil
    OnCast(a3)
  end
end)

SLASH_UPKEEP1 = "/upkeep"
SlashCmdList.UPKEEP = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "debug" then
    Debug()
  else
    print("Upkeep: /upkeep debug shows what it reads. Previewing the seal bar.")
    if not bar:IsShown() then sealCast = { name = "Seal (preview)", start = GetTime() } end
  end
end
