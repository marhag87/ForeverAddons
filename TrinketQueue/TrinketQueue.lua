-- TrinketQueue
--
-- Your two trinket slots in a small frame of their own, drawn as the character sheet draws its
-- slots. A click on a slot, or its key binding, uses that trinket. The arrow above a slot opens
-- the character sheet's flyout with the trinkets in your bags; the one you pick goes on as soon
-- as you're out of combat - at once if you are - and waits in the slot's corner till then. A
-- right-click on the slot drops it. Shift-drag moves the frame.
--
-- The art and the flyout's layout are Blizzard's (PaperDollFrame.xml, EquipmentFlyout.lua),
-- copied rather than called, so nothing of the character sheet's is touched.

local SLOTS = { 13, 14 }  -- left, right: the character sheet's upper and lower trinket
local SLOT_NAME = { [13] = "Trinket0Slot", [14] = "Trinket1Slot" }

local SLOT_SIZE = 37
local SLOT_GAP = 6        -- between the slots, as between the character sheet's weapons
local ARROW_W, ARROW_H = 43, 20
local ARROW_GAP = 5       -- between a slot and its arrow
local MARGIN = 6          -- room for the slots' frames inside the movable frame
local TICK = 0.25         -- seconds between looks at a waiting trinket
local RETRY_AFTER = 1.5   -- seconds a swap gets to happen before it's tried again
local MAX_TRIES = 3       -- then the game won't have it (a unique one, a declined bind prompt): dropped

-- A secure button attribute that stops the search for a modified one and does nothing.
local NOOP = ATTRIBUTE_NOOP or ""

-- Key bindings (Bindings.xml): a click on the slot. The button name "Keybind" is one no
-- modifier attribute matches, so a binding with Shift in it still uses the trinket.
_G["BINDING_NAME_CLICK TrinketQueueSlot13:Keybind"] = "Use left trinket"
_G["BINDING_NAME_CLICK TrinketQueueSlot14:Keybind"] = "Use right trinket"

local db
local queue = {}  -- slot -> { id, bag, slot, tries, at }: the trinket waiting to go on

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------

local LOC_PLAYER = ITEM_INVENTORY_LOCATION_PLAYER or 0x00100000
local LOC_BANK = ITEM_INVENTORY_LOCATION_BANK or 0x00200000
local LOC_BAGS = ITEM_INVENTORY_LOCATION_BAGS or 0x00400000
local BAG_SHIFT = ITEM_INVENTORY_BAG_BIT_OFFSET or 8

-- A location from GetInventoryItemsForSlot as bag, slot for an item in your bags; nil for one
-- you wear or one in the bank (EquipmentManager_GetLocationData's arithmetic).
local function BagAndSlot(location)
  if type(location) ~= "number" or location < 0 then return end
  if bit.band(location, LOC_BAGS) == 0 or bit.band(location, LOC_BANK) ~= 0 then return end
  local rest = location
  if bit.band(rest, LOC_PLAYER) ~= 0 then rest = rest - LOC_PLAYER end
  rest = rest - LOC_BAGS
  local bag = bit.rshift(rest, BAG_SHIFT)
  return bag, rest - bit.lshift(bag, BAG_SHIFT)
end

-- The trinkets in your bags that can go in a slot, in bag order, into out.
local found = {}
local function BagTrinkets(invSlot, out)
  wipe(found)
  wipe(out)
  if not (GetInventoryItemsForSlot and pcall(GetInventoryItemsForSlot, invSlot, found)) then return out end
  for location in pairs(found) do
    local bag, slot = BagAndSlot(location)
    -- (the item id read from the bag itself: what Find and the slots compare with)
    local id = bag and C_Container.GetContainerItemID(bag, slot)
    if id then out[#out + 1] = { location = location, bag = bag, slot = slot, id = id } end
  end
  table.sort(out, function(a, b) return a.location < b.location end)
  return out
end

local function ItemIcon(id)
  local f = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return f and f(id)
end

local function EmptySlotTexture(invSlot)
  local f = (C_PaperDollInfo and C_PaperDollInfo.GetInventorySlotInfo) or GetInventorySlotInfo
  if f then
    local ok, _, texture = pcall(f, SLOT_NAME[invSlot])
    if ok and texture then return texture end
  end
  return "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"
end

local function SetCooldown(cooldown, start, duration, enable)
  if not (CooldownFrame_Set and pcall(CooldownFrame_Set, cooldown, start, duration, enable)) then
    cooldown:Clear()
  end
end

local function SetQuality(button, quality, item, isBound)
  if SetItemButtonQuality then
    pcall(SetItemButtonQuality, button, quality, item, false, isBound)
  end
end

--------------------------------------------------------------------------------
-- Swapping: the character sheet's own way, the trinket picked up from its bag and put on the
-- slot (EquipmentManager_EquipContainerItem). Out of combat only, and not while you're dead,
-- casting or holding something on the cursor.
--------------------------------------------------------------------------------

local function Busy()
  if InCombatLockdown() or UnitAffectingCombat("player") then return true end
  if UnitIsDeadOrGhost("player") then return true end
  if GetCursorInfo() then return true end
  if UnitCastingInfo("player") or UnitChannelInfo("player") then return true end
  return false
end

-- Whether a swap for this trinket is under way: tried, and not yet given up on.
local function Swapping(q)
  return q.at ~= nil and GetTime() - q.at < RETRY_AFTER
end

local function Locked(bag, slot)
  local info = C_Container.GetContainerItemInfo(bag, slot)
  return info and info.isLocked
end

-- Where the waiting trinket is now: where it was picked from, or wherever in your bags.
local function Find(q)
  if q.bag and C_Container.GetContainerItemID(q.bag, q.slot) == q.id then return q.bag, q.slot end
  for bag = 0, tonumber(NUM_BAG_SLOTS) or 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      if C_Container.GetContainerItemID(bag, slot) == q.id then return bag, slot end
    end
  end
end

local function Equip(invSlot, bag, slot)
  ClearCursor()
  C_Container.PickupContainerItem(bag, slot)
  if not CursorHasItem() then return end
  if C_PaperDollInfo and C_PaperDollInfo.CursorCanGoInSlot and not C_PaperDollInfo.CursorCanGoInSlot(invSlot) then
    ClearCursor()
    return
  end
  PickupInventoryItem(invSlot)  -- the old trinket goes where the new one was
end

-- Puts on what's waiting, one slot at a time (they share the cursor). Returns true if the
-- queue changed.
local function Process()
  local changed = false
  for _, invSlot in ipairs(SLOTS) do
    local q = queue[invSlot]
    if q and GetInventoryItemID("player", invSlot) == q.id then
      queue[invSlot], changed = nil, true
    end
  end
  if not next(queue) then return changed end
  local ok, busy = pcall(Busy)
  if not ok or busy then return changed end
  for _, invSlot in ipairs(SLOTS) do
    local q = queue[invSlot]
    if q and not Swapping(q) then
      local bag, slot = Find(q)
      if not bag or q.tries >= MAX_TRIES then
        queue[invSlot], changed = nil, true  -- gone from your bags, or the game won't have it
      elseif not (IsInventoryItemLocked(invSlot) or Locked(bag, slot)) then
        q.tries, q.at = q.tries + 1, GetTime()
        Equip(invSlot, bag, slot)
        return changed
      end
    end
  end
  return changed
end

--------------------------------------------------------------------------------
-- The frame: two slots side by side, an arrow above each.
--------------------------------------------------------------------------------

local holder = CreateFrame("Frame", nil, UIParent)
holder:SetSize(SLOT_SIZE * 2 + SLOT_GAP + MARGIN * 2, SLOT_SIZE + ARROW_GAP + ARROW_H + MARGIN * 2)
holder:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
holder:SetMovable(true)
holder:SetClampedToScreen(true)

local slotButtons = {}
local scratch = {}

local function SavePosition()
  db.x, db.y = holder:GetLeft(), holder:GetBottom()
  holder:ClearAllPoints()
  holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", db.x, db.y)
end

local function ApplyPosition()
  if not (db and db.x and db.y) then return end
  holder:ClearAllPoints()
  holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", db.x, db.y)
end

-- Moving: with Shift held, out of combat (the frame holds secure buttons, frozen in combat).
local function StartMove()
  if IsShiftKeyDown() and not InCombatLockdown() then
    holder.moving = true
    holder:StartMoving()
  end
end

local function StopMove()
  if not holder.moving then return end
  holder.moving = false
  holder:StopMovingOrSizing()
  SavePosition()
end

-- The arrow's look, open or not (EquipmentFlyoutPopoutButton_RefreshVisualState, pointing up).
local function ArrowLook(arrow, open)
  local normal = open and "UI-Character-Info-Button-PullUp-Open" or "UI-Character-Info-Button-PullUp"
  arrow:SetNormalAtlas(normal, true)
  arrow:SetPushedAtlas("UI-Character-Info-Button-PullUp-Pressed", true)
  arrow:SetHighlightAtlas(normal, "ADD")
  arrow:SetSize(ARROW_W, ARROW_H)
end

local function ShowSlotTooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if not GameTooltip:SetInventoryItem("player", self.invSlot) then
    GameTooltip:SetText(_G[SLOT_NAME[self.invSlot]:upper()] or "Trinket")
  end
  GameTooltip:Show()
end

local function HideTooltip()
  GameTooltip:Hide()
end

local UpdateSlots, ToggleFlyout  -- (below)

local function NewSlot(invSlot, i)
  local level = holder:GetFrameLevel()
  local b = CreateFrame("ItemButton", "TrinketQueueSlot" .. invSlot, holder, "SecureActionButtonTemplate")
  b.invSlot = invSlot
  b:SetSize(SLOT_SIZE, SLOT_SIZE)
  b:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", MARGIN + (i - 1) * (SLOT_SIZE + SLOT_GAP), MARGIN)
  b:SetFrameLevel(level + 3)
  -- A click uses the trinket. With key-down casting on (ActionButtonUseKeyDown) the template
  -- acts on the press, so both halves of a click have to reach it. Shift is for moving, and a
  -- right-click drops the waiting trinket, so neither uses it.
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type", "macro")
  b:SetAttribute("macrotext", "/use " .. invSlot)
  b:SetAttribute("shift-type1", NOOP)
  b:SetAttribute("*type2", NOOP)
  b:SetScript("PostClick", function(self, button, down)
    if button == "RightButton" and not down and queue[self.invSlot] then
      queue[self.invSlot] = nil
      UpdateSlots()
    end
  end)
  b:SetScript("OnEnter", ShowSlotTooltip)
  b:SetScript("OnLeave", HideTooltip)
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", StartMove)
  b:SetScript("OnDragStop", StopMove)

  b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
  b.cooldown:SetAllPoints()
  b.emptyTexture = EmptySlotTexture(invSlot)

  -- Its key binding in the top right corner, as on an action button (UpdateHotkeys).
  b.binding = "CLICK TrinketQueueSlot" .. invSlot .. ":Keybind"
  b.hotkey = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
  b.hotkey:SetJustifyH("RIGHT")
  b.hotkey:Hide()

  -- The character sheet's frame round the slot, under it.
  local border = CreateFrame("Frame", nil, holder)
  border:SetFrameLevel(level + 2)
  border:SetSize(1, 1)
  border:SetPoint("CENTER", b)
  local art = border:CreateTexture(nil, "BACKGROUND")
  art:SetAtlas("UI-Character-Info-GearSlot", true)
  art:SetPoint("CENTER")

  -- The arrow, under the frame as on the character sheet.
  local arrow = CreateFrame("Button", nil, holder)
  arrow:SetFrameLevel(level + 1)
  arrow:SetPoint("BOTTOM", b, "TOP", 0, ARROW_GAP)
  arrow.slotButton = b
  ArrowLook(arrow, false)
  arrow:SetScript("OnClick", function(self)
    if IsShiftKeyDown() then return end  -- (the end of a move)
    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
    ToggleFlyout(self.slotButton)
  end)
  arrow:RegisterForDrag("LeftButton")
  arrow:SetScript("OnDragStart", StartMove)
  arrow:SetScript("OnDragStop", StopMove)
  b.arrow = arrow

  -- The trinket waiting to go on, in the slot's top left corner (the key binding has the right).
  local waiting = CreateFrame("Frame", nil, b)
  waiting:SetSize(18, 18)
  waiting:SetPoint("TOPLEFT", b, "TOPLEFT", -5, 5)
  waiting:SetFrameLevel(b:GetFrameLevel() + 5)
  local edge = waiting:CreateTexture(nil, "BACKGROUND")
  edge:SetColorTexture(0, 0, 0, 1)
  edge:SetPoint("TOPLEFT", -1, 1)
  edge:SetPoint("BOTTOMRIGHT", 1, -1)
  waiting.icon = waiting:CreateTexture(nil, "ARTWORK")
  waiting.icon:SetAllPoints()
  waiting.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  waiting:Hide()
  b.waiting = waiting

  slotButtons[invSlot] = b
  return b
end

for i, invSlot in ipairs(SLOTS) do NewSlot(invSlot, i) end

local function UpdateSlot(b)
  local invSlot = b.invSlot
  local texture = GetInventoryItemTexture("player", invSlot)
  if texture then
    SetItemButtonTexture(b, texture)
    SetQuality(b, GetInventoryItemQuality("player", invSlot), GetInventoryItemID("player", invSlot), true)
    SetCooldown(b.cooldown, GetInventoryItemCooldown("player", invSlot))
  else
    SetItemButtonTexture(b, b.emptyTexture)
    SetQuality(b, nil)
    b.cooldown:Clear()
  end
  -- (only while it waits: not for the moment a swap takes, as one picked out of combat does)
  local q = queue[invSlot]
  if q and not Swapping(q) then
    b.waiting.icon:SetTexture(ItemIcon(q.id))
    b.waiting:Show()
  else
    b.waiting:Hide()
  end
end

-- Hidden, out of combat, while you have no trinket at all.
local function UpdateShown()
  if InCombatLockdown() then return end
  local any = GetInventoryItemID("player", 13) or GetInventoryItemID("player", 14)
    or #BagTrinkets(13, scratch) > 0
  holder:SetShown(any and true or false)
end

UpdateSlots = function()
  for _, invSlot in ipairs(SLOTS) do UpdateSlot(slotButtons[invSlot]) end
  UpdateShown()
end

-- The keys bound to the slots, shortened as action buttons have them (ActionButton.lua's
-- UpdateHotkeys): tucked inside the border for a keyboard key, the full width for a gamepad's.
local function UpdateHotkeys()
  for _, b in pairs(slotButtons) do
    local key = GetBindingKey(b.binding)
    local text = key and GetBindingText(key, 1) or ""
    local hotkey = b.hotkey
    if text == "" then
      hotkey:Hide()
    else
      local width = b:GetWidth()
      hotkey:ClearAllPoints()
      if IsBindingForGamePad and IsBindingForGamePad(key) then
        hotkey:SetSize(width, 16)
        hotkey:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
      else
        hotkey:SetSize(width - 6, 10)
        hotkey:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -3)
      end
      hotkey:SetText(text)
      hotkey:Show()
    end
  end
end

--------------------------------------------------------------------------------
-- The flyout: Blizzard's (EquipmentFlyout.xml and .lua), pointing up, with only the trinkets
-- in your bags. A pick waits for the end of combat.
--------------------------------------------------------------------------------

local FLYOUT_ART = "Interface\\PaperDollInfoFrame\\UI-GearManager-Flyout"
local PER_ROW, ROWS = 5, 4
local PER_PAGE = PER_ROW * ROWS
local ITEM_SIZE, ITEM_GAP, ROW_STEP, BORDER = 37, 4, 42, 3

-- Blizzard's pieces of the flyout's background: texture coordinates, width, height.
local PIECES = {
  oneSlotLeft = { { 0, 0.09765625, 0.5546875, 0.77734375 }, 25, 54 },
  oneSlotRight = { { 0.41796875, 0.51171875, 0.5546875, 0.77734375 }, 24, 54 },
  rowLeft = { { 0, 0.16796875, 0.5546875, 0.77734375 }, 43, 54 },
  rowCenter = { { 0.16796875, 0.328125, 0.5546875, 0.77734375 }, 41, 54 },
  rowRight = { { 0.328125, 0.51171875, 0.5546875, 0.77734375 }, 47, 54 },
  top = { { 0, 0.8359375, 0, 0.19140625 }, 214, 49 },
  middle = { { 0, 0.8359375, 0.19140625, 0.35546875 }, 214, 42 },
  bottom = { { 0, 0.8359375, 0.35546875, 0.546875 }, 214, 49 },
}

local flyout = CreateFrame("Frame", "TrinketQueueFlyout", UIParent)
flyout:SetFrameStrata("HIGH")
flyout:SetSize(43, 43)
flyout:Hide()
tinsert(UISpecialFrames, "TrinketQueueFlyout")  -- Escape closes it

local highlight = flyout:CreateTexture(nil, "OVERLAY")
highlight:SetTexture("Interface\\PaperDollInfoFrame\\UI-GearManager-ItemButton-Highlight")
highlight:SetTexCoord(0, 0.78125, 0, 0.78125)
highlight:SetSize(50, 50)

local buttonFrame = CreateFrame("Frame", nil, flyout)
buttonFrame:EnableMouse(true)
buttonFrame:SetClampedToScreen(true)

local backgrounds = {}
local itemButtons = {}

local function Piece(i, name, anchor)
  local t = backgrounds[i]
  if not t then
    t = buttonFrame:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(FLYOUT_ART)
    backgrounds[i] = t
  end
  local piece = PIECES[name]
  t:SetTexCoord(unpack(piece[1]))
  t:SetSize(piece[2], piece[3])
  t:ClearAllPoints()
  if anchor then
    -- (a row's next piece to the right of the last, a next row's under it)
    t:SetPoint("TOPLEFT", anchor.frame, anchor.below and "BOTTOMLEFT" or "TOPRIGHT")
  else
    t:SetPoint("TOPLEFT", -5, 4)
  end
  t:Show()
  return t
end

-- The background for n buttons: one slot, one row, or rows (EquipmentFlyout_UpdateItems).
local function LayBackground(n)
  local used = 0
  local function Add(name, after, below)
    used = used + 1
    return Piece(used, name, after and { frame = after, below = below })
  end
  if n == 1 then
    Add("oneSlotRight", Add("oneSlotLeft"))
  elseif n <= PER_ROW then
    local last = Add("rowLeft")
    for _ = 2, n - 1 do last = Add("rowCenter", last) end
    Add("rowRight", last)
  else
    local last = Add("top")
    for _ = 2, math.ceil(n / PER_ROW) - 1 do last = Add("middle", last, true) end
    Add("bottom", last, true)
  end
  for i = used + 1, #backgrounds do backgrounds[i]:Hide() end
end

-- More than a page: the page turners, over the buttons since the flyout opens upwards.
local nav = CreateFrame("Frame", nil, buttonFrame)
nav:SetSize(214, 41)
nav:SetPoint("BOTTOMLEFT", buttonFrame, "TOPLEFT", -5, 4)
nav:EnableMouse(true)
local navArt = nav:CreateTexture(nil, "BACKGROUND")
navArt:SetTexture(FLYOUT_ART)
navArt:SetTexCoord(0, 0.8359375, 0.94921875, 0.7890625)  -- Blizzard's bottom strip, upside down
navArt:SetAllPoints()

local ShowPage  -- (below)

local function PageButton(point, x, delta, art)
  local b = CreateFrame("Button", nil, nav)
  b:SetSize(32, 32)
  b:SetPoint(point, x, -1)
  b:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. art .. "-Up")
  b:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. art .. "-Down")
  b:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. art .. "-Disabled")
  b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  b:SetScript("OnClick", function()
    flyout.page = flyout.page + delta
    ShowPage()
  end)
  return b
end
nav.prev = PageButton("LEFT", 6, -1, "PrevPage")
nav.next = PageButton("RIGHT", -3, 1, "NextPage")

local function ItemTooltip(self)
  local item = self.item
  if not item then return end
  local x = self:GetRight() or 0
  GameTooltip:SetOwner(self, x < GetScreenWidth() / 2 and "ANCHOR_RIGHT" or "ANCHOR_LEFT")
  GameTooltip:SetBagItem(item.bag, item.slot)
  if GameTooltip_ShowCompareItem then pcall(GameTooltip_ShowCompareItem, GameTooltip) end
  GameTooltip:Show()
end

local function Pick(invSlot, item)
  -- (the same one waiting for the other slot comes here instead)
  for _, other in ipairs(SLOTS) do
    local q = queue[other]
    if q and q.bag == item.bag and q.slot == item.slot then queue[other] = nil end
  end
  queue[invSlot] = { id = item.id, bag = item.bag, slot = item.slot, tries = 0 }
  flyout:Hide()
  Process()
  UpdateSlots()
end

local function NewItemButton(i)
  local b = CreateFrame("ItemButton", nil, buttonFrame)
  b:SetSize(ITEM_SIZE, ITEM_SIZE)
  if (i - 1) % PER_ROW == 0 then
    b:SetPoint("TOPLEFT", buttonFrame, "TOPLEFT", BORDER, -BORDER - ROW_STEP * math.floor((i - 1) / PER_ROW))
  else
    b:SetPoint("TOPLEFT", itemButtons[i - 1], "TOPRIGHT", ITEM_GAP, 0)
  end
  b:RegisterForClicks("LeftButtonUp")
  b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
  b.cooldown:SetAllPoints()
  b:SetScript("OnClick", function(self)
    if self.item then Pick(flyout.invSlot, self.item) end
  end)
  b:SetScript("OnEnter", ItemTooltip)
  b:SetScript("OnLeave", HideTooltip)
  itemButtons[i] = b
  return b
end

local function DrawItem(b)
  local item = b.item
  local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
  SetItemButtonTexture(b, info and info.iconFileID or ItemIcon(item.id))
  SetItemButtonCount(b, info and info.stackCount)
  SetQuality(b, info and info.quality, info and info.hyperlink or item.id, info and info.isBound)
  SetCooldown(b.cooldown, C_Container.GetContainerItemCooldown(item.bag, item.slot))
end

ShowPage = function()
  local items = flyout.items
  local total = #items
  local pages = math.max(1, math.ceil(total / PER_PAGE))
  flyout.page = math.min(math.max(flyout.page or 1, 1), pages)
  local offset = (flyout.page - 1) * PER_PAGE
  local onPage = math.min(PER_PAGE, total - offset)
  for i = 1, math.max(onPage, #itemButtons) do
    local b = itemButtons[i]
    if i <= onPage then
      b = b or NewItemButton(i)
      b.item = items[offset + i]
      DrawItem(b)
      b:Show()
      if b:IsMouseOver() then ItemTooltip(b) end
    elseif b then
      b.item = nil
      b:Hide()
    end
  end
  -- (past one page, every page is a full one, so the flyout keeps its size)
  local n = pages > 1 and PER_PAGE or onPage
  local across = math.min(n, PER_ROW)
  buttonFrame:SetWidth(across * ITEM_SIZE + (across - 1) * ITEM_GAP + BORDER)
  buttonFrame:SetHeight(43 + math.floor((n - 1) / PER_ROW) * ROW_STEP)
  LayBackground(n)
  nav:SetShown(pages > 1)
  nav.prev:SetEnabled(flyout.page > 1)
  nav.next:SetEnabled(flyout.page < pages)
end

-- Reads the bags again; false if there's nothing to show.
local function Fill()
  flyout.items = BagTrinkets(flyout.invSlot, flyout.items or {})
  if #flyout.items == 0 then return false end
  ShowPage()
  return true
end

-- A click anywhere else closes it: on the world, a frame, the slots. Not one on an arrow,
-- which opens or closes it itself.
local function Inside()
  if buttonFrame:IsMouseOver() or (nav:IsShown() and nav:IsMouseOver()) then return true end
  for _, b in pairs(slotButtons) do
    if b.arrow:IsMouseOver() then return true end
  end
  return false
end

flyout:SetScript("OnShow", function(self)
  pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN")
end)

flyout:SetScript("OnEvent", function(self, event)
  if event == "GLOBAL_MOUSE_DOWN" and not Inside() then self:Hide() end
end)

flyout:SetScript("OnHide", function(self)
  pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN")
  if self.slotButton then ArrowLook(self.slotButton.arrow, false) end
  self.slotButton, self.invSlot = nil, nil
end)

ToggleFlyout = function(b)
  if flyout:IsShown() and flyout.slotButton == b then
    flyout:Hide()
    return
  end
  flyout:Hide()
  flyout.slotButton, flyout.invSlot, flyout.page = b, b.invSlot, 1
  if not Fill() then
    flyout.slotButton, flyout.invSlot = nil, nil
    return
  end
  flyout:ClearAllPoints()
  flyout:SetPoint("CENTER", b)
  highlight:ClearAllPoints()
  highlight:SetPoint("CENTER", b)
  buttonFrame:ClearAllPoints()
  buttonFrame:SetPoint("BOTTOMLEFT", b.arrow, "TOPLEFT", 0, 0)
  ArrowLook(b.arrow, true)
  flyout:Show()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("BAG_UPDATE_COOLDOWN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("UPDATE_BINDINGS")
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "UPDATE_BINDINGS" or event == "PLAYER_LOGIN" then
    UpdateHotkeys()
    if event == "UPDATE_BINDINGS" then return end
  end
  if event == "ADDON_LOADED" then
    if arg1 == "TrinketQueue" then
      TrinketQueueDB = TrinketQueueDB or {}
      db = TrinketQueueDB
      ApplyPosition()
    end
    return
  end
  if event == "PLAYER_REGEN_DISABLED" then
    StopMove()
    return
  end
  Process()
  UpdateSlots()
  if flyout:IsShown() and (event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED") then
    if not Fill() then flyout:Hide() end
  end
end)

-- While a trinket waits: a look now and then, for the end of a cast or a cursor let go, and
-- the slots drawn again (a swap that didn't happen shows its trinket waiting again).
local since = 0
events:SetScript("OnUpdate", function(_, elapsed)
  since = since + elapsed
  if since < TICK then return end
  since = 0
  if next(queue) then
    Process()
    UpdateSlots()
  end
end)
