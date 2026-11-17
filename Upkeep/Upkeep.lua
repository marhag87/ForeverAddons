-- Upkeep: a duration bar for your Paladin seal, a reminder when none of your own
-- blessings is on you, and the blessings you could still cast on your target. The same
-- reminder covers weapon enchants (Shaman imbues, Rogue poisons) and buffs a class keeps
-- on itself, listed per class in WEAPON_ENCHANTS and SELF_BUFFS below, and buffs any
-- class keeps up, such as a gatherer's Find Minerals or Find Herbs.
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
local WEAPON_ENCHANTS = {
  SHAMAN = {
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

local bar = CreateFrame("Frame", nil, UIParent)
bar:SetSize(220, 20)
bar:SetPoint("CENTER", 0, -150)
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
    bar:SetPoint("BOTTOM", hb, "TOP", 0, 18)
  else
    bar:SetPoint("CENTER", 0, -150)
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
      end
    end
  end
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
-- On you: greyed icons beside the seal bar for whatever of yours is missing - a
-- blessing on a Paladin, and any weapon enchant or buff listed for your class. They
-- glow in combat, where the gap costs you something.
--------------------------------------------------------------------------------

local selfPanel = CreateFrame("Frame", nil, UIParent)
selfPanel:SetSize(ICON_SIZE, ICON_SIZE)
selfPanel:SetPoint("BOTTOMRIGHT", bar, "TOPLEFT", -2, 2)
selfPanel:Hide()

local selfIcons = {}
local selfAuras, selfView, selfList = {}, {}, {}

local selfTextures = {}  -- what to show, first one in the seal bar's corner

local function DrawSelf()
  local n = #selfTextures
  local combat = UnitAffectingCombat("player")
  local pulse = 0.4 + 0.6 * math.abs(math.sin(GetTime() * math.pi * 1.5))
  for i, texture in ipairs(selfTextures) do
    local t = MakeIcon(selfPanel, selfIcons, i, -1)
    t.icon:SetTexture(texture)
    t.icon:SetDesaturated(true)
    t.icon:SetAlpha(combat and 1 or 0.65)
    SetGlow(t, combat, pulse)
    t:Show()
  end
  for i = n + 1, #selfIcons do
    SetGlow(selfIcons[i], false)
    selfIcons[i]:Hide()
  end
  if n == 0 then
    selfPanel:Hide()
    return
  end
  selfPanel:SetWidth(n * ICON_SIZE + (n - 1) * ICON_GAP)
  selfPanel:Show()
end

local blessingShown  -- the blessing reminder's last answer, kept when a read fails

-- The icon to show for a missing blessing of yours, or nil.
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
  blessingShown = IconFor(pick)
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

local function ItemCount(id)
  local f = (C_Item and C_Item.GetItemCount) or GetItemCount
  if not f then return 0 end
  local ok, n = pcall(f, id)
  if ok and not isSecret(n) and type(n) == "number" then return n end
  return 0
end

local function ItemIcon(id)
  local f = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  if not f then return end
  local ok, t = pcall(f, id)
  if ok and t ~= nil and not isSecret(t) then return t end
end

-- Which options you can apply, and at what rank: a spell you know, or an item you carry.
local function SeedWeaponEnchants()
  for _, opt in ipairs(weaponOptions) do
    opt.best = nil
    for rank, id in ipairs(opt.spells or {}) do
      local ok, isKnown = pcall(IsSpellKnown, id)
      if ok and isKnown then
        opt.best = rank  -- ranks go up, so the last one found is the highest
        opt.icon = SpellTexture(id) or opt.icon
      end
    end
    for rank, id in ipairs(opt.items or {}) do
      if ItemCount(id) > 0 then
        opt.best = rank
        opt.icon = ItemIcon(id) or opt.icon
      end
    end
  end
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

-- Adds an icon to out for each weapon whose enchant is missing or outranked, main hand
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
    if HasWeapon(slot) then
      ReadWeapon(slot)
      local st = weaponState[slot]
      -- Nothing read yet means absence is unproven.
      if st ~= nil then
        if st and st.exp and st.exp <= now then st = false end
        -- A lower rank than you can apply counts as missing; an unknown rank does not.
        local opt = st and st.option and weaponOptions[st.option]
        local outranked = opt and st.rank and opt.best and opt.best > st.rank
        if not st or outranked then
          -- The outranked option, else the one last on this weapon, else the one last
          -- cast, else the first you can apply.
          local pick = outranked and st.option or nil
          local seen = weaponLast[slot]
          if not pick and seen and weaponOptions[seen].best then pick = seen end
          if not pick and lastWeaponOption and weaponOptions[lastWeaponOption].best then
            pick = lastWeaponOption
          end
          pick = pick or available
          out[#out + 1] = weaponOptions[pick].icon or "Interface/Icons/INV_Misc_QuestionMark"
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

-- Adds the icon of every entry that is missing or outranked to out, in table order.
local function SelfBuffReminders(out)
  ReadSelfBuffs()
  local now = GetTime()
  for _, e in ipairs(selfBuffs) do
    local st = e.state
    -- Nothing known means nothing to cast; nothing read yet means absence is unproven.
    if next(e.known) and st ~= nil then
      if st and st.exp and st.exp > 0 and st.exp <= now then st = false end
      -- A lower rank of the spell that is up than you know counts as missing; a rank
      -- that cannot be read does not, so it never nags without reason.
      local best = st and e.known[st.spell]
      local outranked = st and st.rank and best and best > st.rank
      if not st or outranked then
        -- The outranked spell, else the one from the set you last had up, else the
        -- first one you know.
        local pick = outranked and st.spell or (e.known[e.last] and e.last)
        if not pick then
          for sp = 1, #e.spells do
            if e.known[sp] then
              pick = sp
              break
            end
          end
        end
        out[#out + 1] = e.icons[pick]
      end
    end
  end
end

-- Right to left from the seal bar's corner: blessings, weapon enchants, self buffs.
local function UpdateSelf()
  wipe(selfTextures)
  if isPaladin then
    selfTextures[#selfTextures + 1] = BlessingReminder()
  end
  WeaponReminders(selfTextures)
  SelfBuffReminders(selfTextures)
  DrawSelf()
end

--------------------------------------------------------------------------------
-- On your target: one icon per blessing you could still usefully cast on them.
-- Duration is ignored; the question is only whether a cast of yours would add anything.
--------------------------------------------------------------------------------

local TARGET_X, TARGET_Y = 23, -22  -- from the target frame's top-left corner

local targetPanel = CreateFrame("Frame", nil, UIParent)
targetPanel:SetSize(ICON_SIZE, ICON_SIZE)
targetPanel:Hide()

local targetIcons = {}
local targetAuras, targetList = {}, {}

-- Anchored by its bottom-left corner to the target frame, so the row grows rightwards
-- as icons are added and follows the target frame wherever the client lays it out.
local function PlaceTargetPanel()
  targetPanel:ClearAllPoints()
  if TargetFrame then
    targetPanel:SetPoint("BOTTOMLEFT", TargetFrame, "TOPLEFT", TARGET_X, TARGET_Y)
  else
    targetPanel:SetPoint("CENTER", 0, -120)
  end
end

local function UpdateTarget()
  local shown = 0
  if isPaladin and #known > 0 and UnitExists("target")
    and not UnitIsDead("target") and not UnitIsUnit("target", "player") then
    local okA, assist = pcall(UnitCanAssist, "player", "target")
    if okA and assist then
      -- Nothing is readable in combat, and a target changes too often to carry an old
      -- reading forward, so the row stays empty until combat ends.
      local ok, auras, readable = pcall(ReadBlessings, "target", targetAuras)
      if ok and AurasTrusted(readable, "target") then
        local list = Castable(auras, targetList)
        for i, key in ipairs(list) do
          local t = MakeIcon(targetPanel, targetIcons, i, 1)
          t.icon:SetTexture(IconFor(key))
          t.icon:SetDesaturated(false)  -- casts you could make, not a gap
          t.icon:SetAlpha(0.9)
          t:Show()
          shown = i
        end
      end
    end
  end
  for i = shown + 1, #targetIcons do targetIcons[i]:Hide() end
  if shown == 0 then
    targetPanel:Hide()
    return
  end
  targetPanel:SetWidth(shown * ICON_SIZE + (shown - 1) * ICON_GAP)
  targetPanel:Show()
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
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("BAG_UPDATE_DELAYED")  -- poisons come and go from your bags
events:RegisterEvent("ADDON_ACTION_FORBIDDEN")
events:RegisterEvent("ADDON_ACTION_BLOCKED")
events:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

-- A succeeded "player" cast is not always one you made: in a group other players'
-- seal casts arrive too, and so do triggered spells such as Seal of Command's hit
-- (20424). A cast only counts when you sent it yourself: castGUID -> when it was sent.
local sentCasts = {}

events:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "PLAYER_LOGIN" then
    PlaceBar()
    PlaceTargetPanel()
    SeedKnown()
    SeedWeaponEnchants()
    SeedSelfBuffs()
  elseif event == "BAG_UPDATE_DELAYED" then
    SeedWeaponEnchants()
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
