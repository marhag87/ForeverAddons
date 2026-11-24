-- TrinketQueue
--
-- Your two trinket slots in a small frame of their own. A click on a slot, or its key binding,
-- uses that trinket. Hovering a slot shows an arrow above it, which opens the character sheet's
-- flyout with the trinkets in your bags; the one you pick goes on as soon as you're out of
-- combat - at once if you are - and waits in the slot's corner till then. A right-click on the
-- slot drops it. Shift-drag moves the frame.
--
-- The arrow and the flyout's layout are Blizzard's (PaperDollFrame.xml, EquipmentFlyout.lua),
-- and the arrow shows on hover as the totem bar's does (MultiCastActionBarFrame.lua). All of it
-- is copied rather than called, so nothing of Blizzard's is touched.

local SLOTS = { 13, 14 }  -- left, right: the character sheet's upper and lower trinket
local SLOT_NAME = { [13] = "Trinket0Slot", [14] = "Trinket1Slot" }

local SLOT_SIZE = 37
local SLOT_GAP = 3        -- between the slots (their arrows are wider, but only one shows at a time)
local ARROW_W, ARROW_H = 43, 20
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
-- Below the action bars' layer, so flyouts from them (such as the totem bar's) open over
-- the slots. Set before the slots are made, so they inherit it.
holder:SetFrameStrata("LOW")
holder:SetSize(SLOT_SIZE * 2 + SLOT_GAP, SLOT_SIZE)  -- the arrows show above it
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

-- The character sheet's arrow (EquipmentFlyoutPopoutButton_RefreshVisualState), pointing up.
local function ArrowLook(arrow)
  arrow:SetNormalAtlas("UI-Character-Info-Button-PullUp", true)
  arrow:SetPushedAtlas("UI-Character-Info-Button-PullUp-Pressed", true)
  arrow:SetHighlightAtlas("UI-Character-Info-Button-PullUp", "ADD")
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

local UpdateSlots, ToggleFlyout, UpdateArrow  -- (below)

local function SlotEnter(self)
  ShowSlotTooltip(self)
  UpdateArrow(self, true)
end

local function SlotLeave(self)
  HideTooltip()
  UpdateArrow(self)
end

local function NewSlot(invSlot, i)
  local level = holder:GetFrameLevel()
  local b = CreateFrame("ItemButton", "TrinketQueueSlot" .. invSlot, holder, "SecureActionButtonTemplate")
  b.invSlot = invSlot
  b:SetSize(SLOT_SIZE, SLOT_SIZE)
  b:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", (i - 1) * (SLOT_SIZE + SLOT_GAP), 0)
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
  b:SetScript("OnEnter", SlotEnter)
  b:SetScript("OnLeave", SlotLeave)
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

  -- The arrow, under the slot and flush with it, so the mouse goes from one to the other
  -- without leaving both. Shown only while hovered, and not while its flyout is open
  -- (UpdateArrow).
  local arrow = CreateFrame("Button", nil, holder)
  arrow:SetFrameLevel(level + 1)
  arrow:SetPoint("BOTTOM", b, "TOP", 0, 0)
  arrow.slotButton = b
  ArrowLook(arrow)
  arrow:Hide()
  arrow:SetScript("OnLeave", function(self) UpdateArrow(self.slotButton) end)
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
-- The flyout: the trinkets in your bags, growing upwards from the slot as the totem bar's does:
-- columns of five, a page of four columns side by side. Laid out as Blizzard's equipment
-- flyout (EquipmentFlyout.lua) but turned upright and without its background. A pick waits for
-- the end of combat.
--------------------------------------------------------------------------------

local PER_COLUMN, COLUMNS = 5, 4
local PER_PAGE = PER_COLUMN * COLUMNS
local ITEM_SIZE = 37
local ITEM_GAP = SLOT_GAP  -- spaced as the slots are
local PAGE_H = 32          -- the page turners' row

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

local itemButtons = {}

-- More than a page: the page turners, on top of the columns (a full page's width).
local nav = CreateFrame("Frame", nil, buttonFrame)
nav:SetSize(COLUMNS * ITEM_SIZE + (COLUMNS - 1) * ITEM_GAP, PAGE_H)
nav:SetPoint("BOTTOMLEFT", buttonFrame, "TOPLEFT", 0, ITEM_GAP)
nav:EnableMouse(true)

local ShowPage  -- (below)

local function PageButton(point, x, delta, art)
  local b = CreateFrame("Button", nil, nav)
  b:SetSize(32, 32)
  b:SetPoint(point, x, 0)
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
nav.prev = PageButton("LEFT", 0, -1, "PrevPage")
nav.next = PageButton("RIGHT", 0, 1, "NextPage")

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
  if (i - 1) % PER_COLUMN == 0 then
    b:SetPoint("BOTTOMLEFT", buttonFrame, "BOTTOMLEFT", (ITEM_SIZE + ITEM_GAP) * math.floor((i - 1) / PER_COLUMN), 0)
  else
    b:SetPoint("BOTTOMLEFT", itemButtons[i - 1], "TOPLEFT", 0, ITEM_GAP)
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
  local up, across = math.min(n, PER_COLUMN), math.ceil(n / PER_COLUMN)
  buttonFrame:SetHeight(up * ITEM_SIZE + (up - 1) * ITEM_GAP)
  buttonFrame:SetWidth(across * ITEM_SIZE + (across - 1) * ITEM_GAP)
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
-- which opens it itself.
local function Inside()
  if buttonFrame:IsMouseOver() or (nav:IsShown() and nav:IsMouseOver()) then return true end
  for _, b in pairs(slotButtons) do
    if b.arrow:IsShown() and b.arrow:IsMouseOver() then return true end
  end
  return false
end

-- A slot's arrow shows while the mouse is on the slot or on the arrow (hovered: it just came
-- onto the slot), but not while the slot's flyout is open, which sits where the arrow was
-- (MultiCastSlotButton_OnEnter and MultiCastFlyoutFrameOpenButton_Hide). Escape or a click
-- elsewhere closes it.
UpdateArrow = function(b, hovered)
  local open = flyout:IsShown() and flyout.slotButton == b
  local over = hovered or b:IsMouseOver() or (b.arrow:IsShown() and b.arrow:IsMouseOver())
  b.arrow:SetShown(over and not open)
end

flyout:SetScript("OnShow", function(self)
  pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN")
end)

flyout:SetScript("OnEvent", function(self, event)
  if event == "GLOBAL_MOUSE_DOWN" and not Inside() then self:Hide() end
end)

flyout:SetScript("OnHide", function(self)
  pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN")
  local b = self.slotButton
  self.slotButton, self.invSlot = nil, nil
  if b then UpdateArrow(b) end  -- back if the mouse is still on the slot
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
  -- Straight above the slot, where the arrow was, the column going on from it.
  buttonFrame:ClearAllPoints()
  buttonFrame:SetPoint("BOTTOMLEFT", b, "TOPLEFT", 0, ITEM_GAP)
  flyout:Show()
  UpdateArrow(b)
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
