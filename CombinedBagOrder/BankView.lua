-- Bank View
-- Puts a bank button on the combined bag. Clicking it opens a copy of the bank window
-- filled with what Syndicator saved at the last bank visit, so the bank can be checked from
-- anywhere. The copy is built from the bank window's own templates and art and laid out the
-- same way. The real bank window is never touched, so this can't break it. A picker next to the
-- search box switches to any other character Syndicator knows a bank for, including ones synced
-- from another account.
-- Forever only (retail's bank has no such templates), and only when Syndicator is enabled.

local SLOTS_PER_PAGE = 88 -- Forever's bank page size
local NUM_COLUMNS = 8
local SLOT_SIZE = 37
local SLOT_GAP_X, SLOT_GAP_Y = 13, 10
local FIRST_SLOT_X, FIRST_SLOT_Y = 47, -63
local FRAME_WIDTH = 480
local BASE_HEIGHT, BASE_ROWS, ROW_HEIGHT = 460, 6, 47 -- the bank grows by a row height past six rows
local FALLBACK_MAX_TABS = 9 -- the bank itself plus eight bank bag slots
local BANK_ICON = "Interface/ICONS/INV_SideTab_Bank_c60" -- the bank's first page tab icon

local NO_DATA_TEXT = "Syndicator hasn't saved this character's bank yet.\nOpen the bank at a banker once and it will."
local BUTTON_TOOLTIP = "Shows what Syndicator saved at your last bank visit."

local view -- the bank copy, created on first use
local bagButton -- the button on the combined bag

local function CurrentCharacter()
	return Syndicator.API.GetCurrentCharacter() or (UnitName("player") .. "-" .. GetNormalizedRealmName())
end

-- Each Syndicator bank tab holds every slot, with an empty table for an empty slot.
-- Tab 1 is the bank itself; tabs 2 and up are the bank bags.
local function GetBankData(character)
	if not character or not character.bankTabs then
		return nil
	end
	local bagItems = character.containerInfo and character.containerInfo.characterBank or {}
	return character.bankTabs, bagItems
end

local function HasBankData(character)
	for _, tab in ipairs(character.bankTabs or {}) do
		if type(tab.slots) == "table" and #tab.slots > 0 then
			return true
		end
	end
	return false
end

-- Characters with a saved bank, plus the one you're on: yours first, then by name. Characters
-- hidden in Syndicator's options are left out.
local function BankCharacters()
	local current = CurrentCharacter()
	local list = {}
	for _, key in ipairs(Syndicator.API.GetAllCharacters()) do
		local character = Syndicator.API.GetByCharacterFullName(key)
		local show = character and character.details and character.details.show
		local hidden = show and show.inventory == false
		if key == current or (character and not hidden and HasBankData(character)) then
			table.insert(list, key)
		end
	end
	table.sort(list, function(a, b)
		if (a == current) ~= (b == current) then
			return a == current
		end
		return a < b
	end)
	return list
end

local function CharacterDetails(key)
	local character = Syndicator.API.GetByCharacterFullName(key)
	return character and character.details or {}
end

-- Class-coloured name, the way Syndicator's tooltips show characters.
local function CharacterName(key)
	local details = CharacterDetails(key)
	local name = details.character or key:gsub("%-[^%-]*$", "")
	local color = details.className and C_ClassColor and C_ClassColor.GetClassColor(details.className)
	return color and color:WrapTextInColorCode(name) or name
end

-- Syndicator's race icon, as inline markup ("|A:atlas:13:13|a").
local function RaceIconMarkup(key)
	local details = CharacterDetails(key)
	if details.race and details.sex and Syndicator.Utilities and Syndicator.Utilities.GetCharacterIcon then
		local ok, icon = pcall(Syndicator.Utilities.GetCharacterIcon, details.race, details.sex)
		if ok and type(icon) == "string" then
			return icon
		end
	end
end

-- A menu line: race icon and name.
local function CharacterLabel(key)
	local icon = RaceIconMarkup(key)
	return icon and (icon .. " " .. CharacterName(key)) or CharacterName(key)
end

local function HighlightItemsInTab(tabIndex, show)
	for _, button in ipairs(view.itemButtons) do
		if button:IsShown() and button.tabIndex == tabIndex then
			button.BagIndicator:SetShown(show)
		end
	end
end

local function ApplySearch()
	local text = view.SearchBox:GetText():lower()
	for _, button in ipairs(view.itemButtons) do
		if button:IsShown() then
			button:SetMatchesSearch(text == "" or not button.itemLink or button.searchName:find(text, 1, true) ~= nil)
		end
	end
end

local function ShowItemTooltip(button)
	if button.itemLink then
		GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(button.itemLink)
		GameTooltip:Show()
	end
end

-- Shift-click links the item and ctrl-click previews it; nothing can be moved or used.
local function OnItemClick(button)
	if button.itemLink and IsModifiedClick() then
		HandleModifiedItemClick(button.itemLink)
	end
end

local function AcquireItemButton(index)
	local button = view.itemButtons[index]
	if not button then
		button = CreateFrame("ItemButton", nil, view, "CamelotBankItemButtonTemplate")
		-- Replace the template's bank actions with display-only ones.
		button:SetScript("OnEnter", ShowItemTooltip)
		button:SetScript("OnLeave", GameTooltip_Hide)
		button:SetScript("OnClick", OnItemClick)
		button:SetScript("OnDragStart", nil)
		button:SetScript("OnReceiveDrag", nil)
		button:SetBankType(Enum.BankType.Character)
		button:UpdateVisualsForBankType()
		view.itemButtons[index] = button
	end
	return button
end

local function SetSlotItem(button, item)
	local hasItem = item.itemID ~= nil
	local link = hasItem and item.itemLink or nil
	button.itemLink = link
	button.searchName = link and (link:match("%[(.-)%]") or ""):lower() or ""
	button.icon:SetTexture(hasItem and item.iconTexture or nil)
	button.icon:SetShown(hasItem)
	SetItemButtonCount(button, hasItem and item.itemCount or 0)
	SetItemButtonQuality(button, hasItem and item.quality or nil, link, false, hasItem and item.isBound)
	button.IconQuestTexture:Hide()
	button.BagIndicator:Hide()
	-- The bank gives filled slots a different frame than empty ones.
	button:GetNormalTexture():SetAtlas(hasItem and "bank-frame-bag-slotframe" or "bank-frame-item-slotframe",
		TextureKitConstants.IgnoreAtlasSize)
end

local UpdatePageTabs

local function LayoutPage()
	local first = (view.page - 1) * SLOTS_PER_PAGE
	local count = math.max(0, math.min(SLOTS_PER_PAGE, #view.slots - first))
	for i = 1, count do
		local slot = view.slots[first + i]
		local button = AcquireItemButton(i)
		local row, column = math.floor((i - 1) / NUM_COLUMNS), (i - 1) % NUM_COLUMNS
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", FIRST_SLOT_X + column * (SLOT_SIZE + SLOT_GAP_X),
			FIRST_SLOT_Y - row * (SLOT_SIZE + SLOT_GAP_Y))
		button.tabIndex = slot.tabIndex
		SetSlotItem(button, slot.item)
		button:Show()
	end
	for i = count + 1, #view.itemButtons do
		view.itemButtons[i]:Hide()
	end

	local rows = math.ceil(count / NUM_COLUMNS)
	view:SetHeight(BASE_HEIGHT + math.max(0, rows - BASE_ROWS) * ROW_HEIGHT)
	ApplySearch()
end

local function AcquirePageTab(index)
	local tab = view.pageTabs[index]
	if not tab then
		tab = CreateFrame("Frame", nil, view, "BankPageTabTemplate")
		-- The template's own handler would page the real bank.
		tab:SetCustomOnMouseUpHandler(function(self, mouseButton, upInside)
			if mouseButton == "LeftButton" and upInside and self.pageNumber ~= view.page then
				view.page = self.pageNumber
				LayoutPage()
				UpdatePageTabs()
			end
		end)
		if index == 1 then
			tab:SetPoint("TOPLEFT", view, "TOPRIGHT", 0, -60)
		else
			tab:SetPoint("TOPLEFT", view.pageTabs[index - 1], "BOTTOMLEFT", 0, -2)
		end
		view.pageTabs[index] = tab
	end
	return tab
end

function UpdatePageTabs()
	local numPages = math.max(1, math.ceil(#view.slots / SLOTS_PER_PAGE))
	for page = 1, numPages do
		local tab = AcquirePageTab(page)
		tab:SetPageInfo(Enum.BankType.Character, page, view.page)
		tab:Show()
	end
	for page = numPages + 1, #view.pageTabs do
		view.pageTabs[page]:Hide()
	end
end

local function UpdateBagButtons(tabs, bagItems)
	for index, button in ipairs(view.bagButtons) do
		local tabIndex = index + 1
		local bought = tabs ~= nil and tabs[tabIndex] ~= nil
		local bag = bought and bagItems[tabIndex] or nil
		button.tabIndex = tabIndex
		button.itemLink = bag and bag.itemLink or nil
		button.tooltipText = bought and BANK_BAG or BANK_BAG_PURCHASE
		button.DisabledOverlay:SetShown(not bought)
		SetItemButtonTexture(button, bag and bag.iconTexture or nil)
		button:SetShown(tabs ~= nil)
	end
end

-- Your own portrait and gold for your character; another character gets its class icon and its
-- saved gold.
local function ShowOwner(key, character)
	if key == CurrentCharacter() then
		view:SetPortraitTexCoord(0, 1, 0, 1)
		view:SetPortraitToUnit("player")
		MoneyFrame_SetType(view.Money, "PLAYER")
		MoneyFrame_UpdateMoney(view.Money)
		return
	end
	local class = character and character.details and character.details.className
	if type(class) == "string" and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class:upper()] then
		view:SetPortraitToClassIcon(class)
	else
		view:SetPortraitTexCoord(0, 1, 0, 1)
		view:SetPortraitToAsset(BANK_ICON)
	end
	MoneyFrame_SetType(view.Money, "STATIC")
	MoneyFrame_Update(view.Money, character and tonumber(character.money) or 0)
end

-- The picker's button shows the race icon as its own texture: the button's text line is only 10
-- tall, so an inline icon sits off-centre in it. OverrideText also stops the dropdown from
-- copying the menu line, inline icon and all, into the button.
local PICKER_ICON_SIZE = 14

local function ShowPickedCharacter(key)
	local picker = view.CharacterPicker
	local atlas = (RaceIconMarkup(key) or ""):match("^|A:([^:|]+)")
	local textLeft = 8
	if atlas then
		view.CharacterIcon:SetAtlas(atlas)
		view.CharacterIcon:Show()
		textLeft = 8 + PICKER_ICON_SIZE + 4
	else
		view.CharacterIcon:Hide()
	end
	picker.Text:ClearAllPoints()
	picker.Text:SetPoint("TOPLEFT", textLeft, -8)
	picker.Text:SetPoint("TOPRIGHT", picker.Arrow, "LEFT")
	picker:OverrideText(CharacterName(key))
end

local function Refresh()
	local character = Syndicator.API.GetByCharacterFullName(view.characterKey)
	local tabs, bagItems = GetBankData(character)
	local slots = {}
	for tabIndex, tab in ipairs(tabs or {}) do
		for _, item in ipairs(tab.slots or {}) do
			table.insert(slots, { item = item, tabIndex = tabIndex })
		end
	end
	if #slots == 0 then
		tabs = nil -- tabs without slots means the bank was never opened with Syndicator on
	end

	view.slots = slots
	view.page = math.min(view.page, math.max(1, math.ceil(#slots / SLOTS_PER_PAGE)))
	ShowOwner(view.characterKey, character)
	ShowPickedCharacter(view.characterKey)
	view.NoData:SetShown(tabs == nil)
	view.BagText:SetShown(tabs ~= nil)
	LayoutPage()
	UpdatePageTabs()
	UpdateBagButtons(tabs, bagItems)
end

local function BagButton_OnEnter(button)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	if button.itemLink then
		GameTooltip:SetHyperlink(button.itemLink)
	else
		GameTooltip:SetText(button.tooltipText)
	end
	GameTooltip:Show()
	HighlightItemsInTab(button.tabIndex, true)
end

local function BagButton_OnLeave(button)
	GameTooltip:Hide()
	HighlightItemsInTab(button.tabIndex, false)
end

-- Same pieces and positions as Forever's BankFrame (Camelot/BankFrame.xml) and the BankPanel
-- it holds (Mainline/BankFrameTemplates.xml), minus everything that needs a banker.
local function CreateView()
	view = CreateFrame("Frame", "CombinedBagOrderBankFrame", UIParent, "PortraitFrameTemplate")
	view:Hide()
	view:SetToplevel(true)
	view:EnableMouse(true)
	view:SetSize(FRAME_WIDTH, BASE_HEIGHT)
	view:SetPoint("TOPLEFT", 16, -116)
	view:SetTitle(BANK)
	view.onCloseCallback = function()
		view:Hide()
		return false -- not a UI panel, so skip HideUIPanel
	end
	table.insert(UISpecialFrames, view:GetName()) -- Escape closes it

	view.page = 1
	view.slots = {}
	view.itemButtons = {}
	view.pageTabs = {}
	view.bagButtons = {}

	local background = view:CreateTexture(nil, "BACKGROUND")
	background:SetAtlas("bank-frame-background")
	background:SetHorizTile(true)
	background:SetVertTile(true)
	background:SetPoint("TOPLEFT", 0, -20)
	background:SetPoint("BOTTOMRIGHT", 0, 30)

	local inset = CreateFrame("Frame", nil, view)
	if inset.SetUsingParentLevel then
		inset:SetUsingParentLevel(true)
	end
	inset:SetPoint("TOPLEFT", 0, -20)
	inset:SetPoint("BOTTOMRIGHT", 0, 30)
	NineSliceUtil.ApplyLayoutByName(inset, "InsetFrameTemplate")

	local shadows = CreateFrame("Frame", nil, view, "BankPanelEdgeShadowTemplate")
	shadows:ClearAllPoints()
	shadows:SetPoint("TOPLEFT")
	shadows:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT")

	local divider = view:CreateTexture(nil, "ARTWORK")
	divider:SetAtlas("bank-divider", true)
	divider:SetScale(0.48)
	divider:SetPoint("BOTTOM", 0, 220)

	view.BagText = view:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	view.BagText:SetSize(120, 40)
	view.BagText:SetJustifyH("RIGHT")
	view.BagText:SetJustifyV("MIDDLE")
	view.BagText:SetPoint("BOTTOMLEFT", 15, 67)
	view.BagText:SetText(BAGSLOTTEXT_COLON or "Bag Slots:")

	view.NoData = view:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	view.NoData:SetPoint("CENTER", 0, 20)
	view.NoData:SetText(NO_DATA_TEXT)

	view.SearchBox = CreateFrame("EditBox", nil, view, "SearchBoxTemplate")
	view.SearchBox:SetSize(110, 20)
	view.SearchBox:SetPoint("TOPRIGHT", -56, -33)
	view.SearchBox:SetAutoFocus(false)
	view.SearchBox:HookScript("OnTextChanged", ApplySearch)

	-- Whose bank to show, in the space between the portrait and the search box.
	-- Only the width changes: the template's art is drawn for its own height. Placed at whole
	-- coordinates, like Edit Mode's layout dropdown: centring its 25 height on the 20-high search
	-- box would put it half a pixel off, and the arrow then snaps apart from its frame. This ends
	-- 14 left of the search box, level with it to half a pixel.
	view.CharacterPicker = CreateFrame("DropdownButton", nil, view, "WowStyle1DropdownTemplate")
	view.CharacterPicker:SetWidth(180)
	view.CharacterPicker:SetPoint("TOPLEFT", 120, -31)
	view.CharacterIcon = view.CharacterPicker:CreateTexture(nil, "OVERLAY")
	view.CharacterIcon:SetSize(PICKER_ICON_SIZE, PICKER_ICON_SIZE)
	view.CharacterIcon:SetPoint("LEFT", 8, -1) -- level with the text, which sits a pixel below centre
	view.CharacterPicker:SetupMenu(function(_, rootDescription)
		for _, key in ipairs(BankCharacters()) do
			rootDescription:CreateRadio(CharacterLabel(key), function()
				return view.characterKey == key
			end, function()
				view.characterKey = key
				view.page = 1
				Refresh()
			end)
		end
	end)

	local moneyBorder = CreateFrame("Frame", nil, view, "ThinGoldEdgeTemplate")
	moneyBorder:SetSize(178, 19)
	moneyBorder:SetPoint("BOTTOMRIGHT", -5, 6)
	view.Money = CreateFrame("Frame", nil, moneyBorder, "SmallMoneyFrameTemplate")
	view.Money:SetPoint("RIGHT", moneyBorder, "RIGHT")

	-- One button per bank bag slot. Made here while the frame is hidden, and stripped of the
	-- template's scripts before they can run, since those act on the real bank.
	local maxTabs = C_Bank.FetchMaxNumBankTabs(Enum.BankType.Character) or 0
	if maxTabs < 1 then
		maxTabs = FALLBACK_MAX_TABS
	end
	for index = 1, maxTabs - 1 do
		local button = CreateFrame("ItemButton", nil, view, "BankItemButtonBagTemplate")
		for _, script in ipairs({ "OnShow", "OnHide", "OnEvent", "OnDragStart", "OnReceiveDrag" }) do
			button:SetScript(script, nil)
		end
		button:SetScript("OnEnter", BagButton_OnEnter)
		button:SetScript("OnLeave", BagButton_OnLeave)
		button:SetScript("OnClick", OnItemClick)
		if index == 1 then
			button:SetPoint("LEFT", view, "BOTTOMLEFT", 200, 115)
		else
			button:SetPoint("TOPLEFT", view.bagButtons[index - 1], "TOPLEFT", 50, 0)
		end
		view.bagButtons[index] = button
	end

	-- Opens on your own bank; the bag button stays lit while the bank copy is open.
	view:SetScript("OnShow", function()
		view.characterKey = CurrentCharacter()
		view.page = 1
		Refresh()
		bagButton:LockHighlight()
	end)

	-- Picks up changes while open, such as a synced character's bank arriving or updating.
	Syndicator.CallbackRegistry:RegisterCallback("BagCacheUpdate", function(_, key)
		if view:IsShown() and key == view.characterKey then
			Refresh()
		end
	end, view)
	view:SetScript("OnHide", function()
		bagButton:UnlockHighlight()
	end)

	-- The real bank takes over at a banker.
	view:RegisterEvent("BANKFRAME_OPENED")
	view:SetScript("OnEvent", function()
		view:Hide()
	end)
end

local function ToggleView()
	if BankFrame and BankFrame:IsShown() then
		return -- at a banker the real bank is already open
	end
	if not view then
		CreateView()
	end
	view:SetShown(not view:IsShown())
end

-- Built like the bag's cleanup button (BagItemAutoSortButton: same size, art and highlight),
-- in the gap left of the search box. The cleanup art is its frame and broom in one picture,
-- drawn about 21x20 inside the 28x26 button, so the bank icon is laid over the broom and the
-- frame shows around it.
local function CreateBagButton()
	local bags = ContainerFrameCombinedBags
	bagButton = CreateFrame("Button", "CombinedBagOrderBankButton", bags)
	bagButton:SetSize(28, 26)
	-- Same height as the cleanup button (TOPRIGHT -9, -34) and the same gap to the search box.
	bagButton:SetPoint("TOPLEFT", bags, "TOPLEFT", 27, -34)
	bagButton:SetFrameLevel(bags:GetFrameLevel() + 5) -- above the portrait's edge
	bagButton:SetNormalAtlas("bags-button-autosort-up")
	bagButton:SetPushedAtlas("bags-button-autosort-down")
	bagButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	local highlight = bagButton:GetHighlightTexture()
	highlight:ClearAllPoints()
	highlight:SetSize(24, 23)
	highlight:SetPoint("CENTER")

	local icon = bagButton:CreateTexture(nil, "OVERLAY")
	icon:SetTexture(BANK_ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the icon's own edge
	icon:SetSize(15, 14) -- just inside the frame drawn by the cleanup art
	icon:SetPoint("CENTER")
	bagButton.Icon = icon

	-- Nudge the icon while pressed, as the pressed cleanup art does.
	bagButton:SetScript("OnMouseDown", function()
		icon:SetPoint("CENTER", 1, -1)
	end)
	bagButton:SetScript("OnMouseUp", function()
		icon:SetPoint("CENTER")
	end)
	bagButton:SetScript("OnClick", ToggleView)
	bagButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self)
		GameTooltip_SetTitle(GameTooltip, BANK, HIGHLIGHT_FONT_COLOR)
		GameTooltip_AddNormalLine(GameTooltip, BUTTON_TOOLTIP)
		GameTooltip:Show()
	end)
	bagButton:SetScript("OnLeave", GameTooltip_Hide)
end

EventUtil.ContinueOnAddOnLoaded("Blizzard_UIPanels_Game", function()
	if not (Syndicator and Syndicator.API and CamelotBankPanelItemButtonMixin and ContainerFrameCombinedBags) then
		return
	end
	CreateBagButton()
end)
