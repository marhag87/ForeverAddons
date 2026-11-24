-- Runs TrinketQueue.lua against a mock of the game: bags, two trinket slots, the cursor.
local path = ...
local function band(a, b)
  local r, bitv = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then r = r + bitv end
    a, b, bitv = a // 2, b // 2, bitv * 2
  end
  return r
end
local bitlib = { band = band,
  rshift = function(a, n) return math.floor(a / 2 ^ n) end,
  lshift = function(a, n) return math.floor(a * 2 ^ n) end }

local clock, combat, casting, shift = 0, false, false, false
local equipped = { [13] = 1001, [14] = 1002 }
local bags = { [0] = { [1] = 3001, [3] = 2001 }, [1] = { [5] = 2002 } }
local TRINKETS = { [1001] = true, [1002] = true, [2001] = true, [2002] = true }
local cursor
local bindings = {}
local pendingSwap
local frames = {}
local env

local Frame = {}
local function NewFrame(kind, name, parent, template)
  local f = setmetatable({ kind = kind, name = name, parent = parent, template = template, attrs = {}, scripts = {},
    shown = kind ~= "Cooldown", events = {} }, Frame)
  if kind == "ItemButton" then
    f.icon = NewFrame("Texture"); f.IconBorder = NewFrame("Texture"); f.Count = NewFrame("Texture")
  end
  frames[#frames + 1] = f
  if name and env then env[name] = f end
  return f
end
Frame.__index = function(_, k)
  local m = rawget(Frame, k)
  if m then return m end
  if type(k) == "string" and k:match("^%u") then return function() end end
end
function Frame:SetAttribute(k, v) if combat then error("SetAttribute in combat") end self.attrs[k] = v end
function Frame:GetAttribute(k) return self.attrs[k] end
function Frame:SetScript(s, fn) self.scripts[s] = fn end
function Frame:GetScript(s) return self.scripts[s] end
function Frame:Show() local was = self.shown self.shown = true if not was and self.scripts.OnShow then self.scripts.OnShow(self) end end
function Frame:Hide() local was = self.shown self.shown = false if was and self.scripts.OnHide then self.scripts.OnHide(self) end end
function Frame:SetShown(v) if v then self:Show() else self:Hide() end end
function Frame:IsShown() return self.shown end
function Frame:IsMouseOver() return self.mouseOver == true end
function Frame:GetParent() return self.parent end
function Frame:GetFrameLevel() return self.level or 1 end
function Frame:SetFrameLevel(l) self.level = l end
function Frame:RegisterEvent(e) self.events[e] = true end
function Frame:UnregisterEvent(e) self.events[e] = nil end
function Frame:RegisterForClicks(...) self.clicks = { ... } end
function Frame:CreateTexture() return NewFrame("Texture") end
function Frame:CreateFontString() return NewFrame("FontString") end
function Frame:SetTexture(t) self.texture = t end
function Frame:GetWidth() return 37 end
function Frame:SetText(t) self.text = t end
function Frame:SetEnabled(v) self.enabled = v end
function Frame:GetLeft() return 300 end
function Frame:GetBottom() return 200 end
function Frame:GetRight() return 400 end
function Frame:StartMoving() self.isMoving = true end
function Frame:StopMovingOrSizing() self.isMoving = false end
function Frame:Clear() self.cd = nil end

local function Fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
local function Tick(n)
  for _ = 1, n or 1 do
    clock = clock + 0.3
    if pendingSwap then local f = pendingSwap pendingSwap = nil f() end
    for _, f in ipairs(frames) do if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.3) end end
  end
end

local LOC_PLAYER, LOC_BAGS = 0x00100000, 0x00400000
env = setmetatable({
  CreateFrame = NewFrame, GameTooltip = NewFrame("Frame"),
  UISpecialFrames = {}, tinsert = table.insert, wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
  bit = bitlib, unpack = table.unpack, NUM_BAG_SLOTS = 4, ATTRIBUTE_NOOP = "",
  GetTime = function() return clock end,
  InCombatLockdown = function() return combat end, UnitAffectingCombat = function() return combat end,
  UnitIsDeadOrGhost = function() return false end,
  UnitCastingInfo = function() return casting and "Frostbolt" or nil end, UnitChannelInfo = function() return nil end,
  GetCursorInfo = function() return cursor and "item" or nil end, CursorHasItem = function() return cursor ~= nil end,
  ClearCursor = function() cursor = nil end,
  IsShiftKeyDown = function() return shift end,
  IsInventoryItemLocked = function() return false end,
  GetInventoryItemID = function(_, s) return equipped[s] end,
  GetInventoryItemTexture = function(_, s) return equipped[s] and ("icon" .. equipped[s]) end,
  GetInventoryItemQuality = function() return 3 end,
  GetInventoryItemCooldown = function() return 0, 0, 1 end,
  GetInventoryItemsForSlot = function(_, t)
    for s, id in pairs(equipped) do t[LOC_PLAYER + s] = id end
    for bag, slots in pairs(bags) do
      for s, id in pairs(slots) do
        if TRINKETS[id] then t[LOC_PLAYER + LOC_BAGS + bag * 256 + s] = id end
      end
    end
  end,
  C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and 30 or 0 end,
    GetContainerItemID = function(bag, s) return bags[bag] and bags[bag][s] end,
    GetContainerItemInfo = function(bag, s)
      local id = bags[bag] and bags[bag][s]
      return id and { iconFileID = "icon" .. id, stackCount = 1, quality = 3, hyperlink = "item:" .. id }
    end,
    GetContainerItemCooldown = function() return 0, 0, 1 end,
    PickupContainerItem = function(bag, s)
      local id = bags[bag] and bags[bag][s]
      if id then cursor = { bag = bag, slot = s, id = id } end
    end,
  },
  PickupInventoryItem = function(s)
    if not cursor then return end
    if combat then error("equip in combat") end
    local c = cursor
    cursor = nil
    pendingSwap = function()
      local old = equipped[s]
      equipped[s] = c.id
      bags[c.bag][c.slot] = old
      Fire("PLAYER_EQUIPMENT_CHANGED", s)
    end
  end,
  C_Item = { GetItemIconByID = function(id) return "icon" .. id end },
  C_PaperDollInfo = { CursorCanGoInSlot = function() return true end, GetInventorySlotInfo = function() return 13, "emptyslot" end },
  SetItemButtonTexture = function(b, t) b.icon.texture = t end,
  SetItemButtonCount = function() end, SetItemButtonQuality = function() end,
  CooldownFrame_Set = function(cd, _, dur) cd.cd = dur end,
  GetScreenWidth = function() return 1920 end, SlashCmdList = {},
  GetBindingKey = function(b) return bindings[b] end,
  GetBindingText = function(k, abbrev) return abbrev and (k:gsub("SHIFT%-", "s-")) or k end,
}, { __index = _G })
env._G = env
env.UIParent = NewFrame("Frame", "UIParent")

local chunk = assert(loadfile(path, "t", env))
chunk("TrinketQueue")
Fire("ADDON_LOADED", "TrinketQueue")
Fire("PLAYER_LOGIN")

local s13, s14 = env.TrinketQueueSlot13, env.TrinketQueueSlot14
local flyout = env.TrinketQueueFlyout
local function ids(list)
  local out = {}
  for _, it in ipairs(list or {}) do out[#out + 1] = it.id end
  return table.concat(out, ",")
end
local function State(label)
  print(("%-40s 13=%s 14=%s  waiting13=%s waiting14=%s  flyout=%s"):format(label, tostring(equipped[13]), tostring(equipped[14]),
    s13.waiting.shown and s13.waiting.icon.texture or "-", s14.waiting.shown and s14.waiting.icon.texture or "-",
    flyout.shown and ("[" .. ids(flyout.items) .. "]") or "closed"))
end
print("attrs 13:", s13.attrs.type, s13.attrs.macrotext, "shift-type1=[" .. tostring(s13.attrs["shift-type1"]) .. "]",
  "*type2=[" .. tostring(s13.attrs["*type2"]) .. "]", table.concat(s13.clicks, "+"))
print("binding names:", env["BINDING_NAME_CLICK TrinketQueueSlot13:Keybind"], "/", env["BINDING_NAME_CLICK TrinketQueueSlot14:Keybind"])
State("logged in")
local function Keys(label) print(("%-40s left=[%s]%s right=[%s]%s"):format(label, tostring(s13.hotkey.text), s13.hotkey.shown and "" or "(hidden)",
  tostring(s14.hotkey.text), s14.hotkey.shown and "" or "(hidden)")) end
Keys("no keys bound")
bindings["CLICK TrinketQueueSlot13:Keybind"] = "SHIFT-1"
bindings["CLICK TrinketQueueSlot14:Keybind"] = "F"
Fire("UPDATE_BINDINGS")
Keys("Shift-1 and F bound")
bindings["CLICK TrinketQueueSlot14:Keybind"] = nil
Fire("UPDATE_BINDINGS")
Keys("F unbound")

local function PickItem(id)
  for _, f in ipairs(frames) do
    if f.kind == "ItemButton" and f.shown and f.item and f.item.id == id and f.parent and f.parent.parent == flyout then
      f.scripts.OnClick(f)
      return true
    end
  end
  print("  (no button for " .. id .. ")")
end

s13.arrow.scripts.OnClick(s13.arrow)
State("arrow 13 opened")
local shows = 0
local realShow = s13.waiting.Show
s13.waiting.Show = function(self) shows = shows + 1 return realShow(self) end
PickItem(2001)
Tick(3)
State("picked 2001 out of combat")
print("corner icon shown during that swap:", shows, "times")
s13.waiting.Show = nil

combat = true
Fire("PLAYER_REGEN_DISABLED")
s14.arrow.scripts.OnClick(s14.arrow)
State("in combat, arrow 14 opened")
PickItem(2002)
Tick(5)
State("in combat, picked 2002")
combat, casting = false, true
Fire("PLAYER_REGEN_ENABLED")
Tick(2)
State("combat over but casting")
casting = false
Tick(2)
State("cast done")

combat = true
s13.arrow.scripts.OnClick(s13.arrow)
PickItem(1001)
State("in combat, 1001 queued for 13")
s13.scripts.PostClick(s13, "RightButton", true)
s13.scripts.PostClick(s13, "RightButton", false)
State("right-clicked slot 13")
s14.arrow.scripts.OnClick(s14.arrow)
PickItem(1001)
s13.arrow.scripts.OnClick(s13.arrow)
PickItem(1001)
State("1001 queued for 14, then for 13")
combat = false
Fire("PLAYER_REGEN_ENABLED")
Tick(2)
State("after combat")

-- Paging: 23 more trinkets in the bags.
bags[2] = {}
for i = 1, 23 do bags[2][i] = 5000 + i TRINKETS[5000 + i] = true end
s13.arrow.scripts.OnClick(s13.arrow)
local shownButtons = 0
for _, f in ipairs(frames) do
  if f.kind == "ItemButton" and f.shown and f.item and f.parent and f.parent.parent == flyout then shownButtons = shownButtons + 1 end
end
print("25 in bags: items", #flyout.items, "buttons on page", shownButtons, "page", flyout.page)
s13.arrow.scripts.OnClick(s13.arrow)
print("arrow clicked again, flyout", flyout.shown and "open" or "closed")

-- A click outside closes the flyout; one on it or on an arrow doesn't.
s13.arrow.scripts.OnClick(s13.arrow)
local buttonFrame
for _, f in ipairs(frames) do if f.kind == "ItemButton" and f.parent and f.parent.parent == flyout then buttonFrame = f.parent break end end
buttonFrame.mouseOver = true
Fire("GLOBAL_MOUSE_DOWN", "LeftButton")
print("click on the flyout, flyout", flyout.shown and "open" or "closed")
buttonFrame.mouseOver = false
Fire("GLOBAL_MOUSE_DOWN", "LeftButton")
print("click elsewhere, flyout", flyout.shown and "open" or "closed", "listening", tostring(flyout.events.GLOBAL_MOUSE_DOWN))
s13.arrow.scripts.OnClick(s13.arrow)
print("arrow again, flyout", flyout.shown and "open" or "closed")
s13.arrow.scripts.OnClick(s13.arrow)

-- The arrow shows on hover only, as the totem bar's (asserted).
local function Expect(label, cond)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then failed = true end
end
Expect("arrows hidden at rest", not s13.arrow.shown and not s14.arrow.shown)
s13.mouseOver = true
s13.scripts.OnEnter(s13)
Expect("hovering slot 13 shows its arrow only", s13.arrow.shown and not s14.arrow.shown)
s13.mouseOver, s13.arrow.mouseOver = false, true
s13.scripts.OnLeave(s13)
Expect("moving onto the arrow keeps it", s13.arrow.shown)
s13.arrow.mouseOver = false
s13.arrow.scripts.OnLeave(s13.arrow)
Expect("leaving both hides it", not s13.arrow.shown)
s13.mouseOver = true
s13.scripts.OnEnter(s13)
s13.arrow.scripts.OnClick(s13.arrow)
Expect("opening the flyout hides the slot's arrow", flyout.shown and not s13.arrow.shown)
s13.scripts.OnEnter(s13)
Expect("hovering the open slot doesn't bring its arrow back", not s13.arrow.shown)
s13.mouseOver = false
s13.scripts.OnLeave(s13)
s14.mouseOver = true
s14.scripts.OnEnter(s14)
Expect("another slot's arrow still shows", s14.arrow.shown)
s14.arrow.scripts.OnClick(s14.arrow)
Expect("opening 14's flyout: neither slot arrow shows", flyout.shown and not s13.arrow.shown and not s14.arrow.shown)
flyout:Hide()
Expect("closed with the mouse on slot 14: its arrow is back", s14.arrow.shown)
s14.mouseOver = false
s14.scripts.OnLeave(s14)
Expect("then leaving hides it", not s14.arrow.shown)

-- Moving: only with Shift.
s13.scripts.OnDragStart(s13)
print("drag without shift moves:", tostring(s13:GetParent().isMoving))
shift = true
s13.scripts.OnDragStart(s13)
s13.scripts.OnDragStop(s13)
print("shift-drag saved:", env.TrinketQueueDB.x, env.TrinketQueueDB.y)

-- No trinkets at all: hidden.
equipped[13], equipped[14], bags = nil, nil, { [0] = {} }
Fire("BAG_UPDATE_DELAYED")
print("no trinkets, frame shown:", tostring(s13:GetParent():IsShown()))
print(failed and "FAILED" or "ok")
