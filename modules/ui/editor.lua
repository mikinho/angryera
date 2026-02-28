-- Angry Era: modules/ui/editor.lua
-- Main editing window, tree, dialogs, bulk management, icon picker, context menus.

local _, app = ...
local AngryAssign = app.AngryAssign

local AceGUI = app.AceGUI
local DDM = app.DDM
local helpers = app.utils.helpers
local colors = app.utils.colors
local EnsureUnitShortName = helpers.EnsureUnitShortName
local IterateGroupMembers = helpers.IterateGroupMembers
local IsCategoryDescendant = helpers.IsCategoryDescendant
local selectedLastValue = helpers.selectedLastValue
local RGBToHex = colors.RGBToHex
local HexToRGB = colors.HexToRGB

local AngryAssign_DropDown

-- -----------------------
-- Guild Colors        --
-- -----------------------

AngryAssign.GuildColors = {}

--- Rebuilds the guild name-to-class-color cache.
-- This cache is later used for display highlighting.
function AngryAssign:UpdateGuildColors()
	if not IsInGuild() then
		return
	end

	local numGuild = GetNumGuildMembers()
	for i = 1, numGuild do
		local name, _, _, _, class, _, _, _, _, _, classFileName = GetGuildRosterInfo(i)
		if name then
			local fileClass = classFileName or class
			if fileClass and RAID_CLASS_COLORS[fileClass] then
				local color = RAID_CLASS_COLORS[fileClass].colorStr
				name = name:match("([^-]+)") -- Strip realm
				AngryAssign.GuildColors[name] = color
			end
		end
	end
end

-- --------------------------
-- Bulk Management      --
-- --------------------------

--- Opens the bulk-management UI for selecting and deleting pages/categories.
function AngryAssign:ShowBulkManagement()
	-- CHANGE: Use "Window" instead of "Frame" for better dialog behavior
	local frame = AceGUI:Create("Window")
	frame:SetTitle("Bulk Manage Pages")
	frame:SetLayout("Flow")
	frame:SetWidth(400)
	frame:SetHeight(500)
	frame:EnableResize(false)

	-- Setup Frame Strata and Global Name for Escape Key
	if frame.frame then
		local f = frame.frame
		if f.SetFrameStrata then
			f:SetFrameStrata("FULLSCREEN_DIALOG")
		end
		if f.SetToplevel then
			f:SetToplevel(true)
		end

		-- Force SOLID Black Background Texture
		local bg = f:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(f)
		bg:SetColorTexture(0, 0, 0, 0.95)

		-- Assign a global name so UISpecialFrames can find it
		local globalName = "AngryAssign_BulkManage"
		_G[globalName] = f

		-- Darker Background
		local backdrop = {
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 }
		}
		if f.SetBackdrop then
			f:SetBackdrop(backdrop)
			f:SetBackdropColor(0, 0, 0, 1)
		end

		-- Register for Escape key closing
		local found = false
		for _, v in ipairs(UISpecialFrames) do
			if v == globalName then
				found = true break
			end
		end
		if not found then
			tinsert(UISpecialFrames, globalName)
		end
	end

	-- Ensure the widget is released (cleaned up) when closed
	frame:SetCallback("OnClose", function(widget)
		AceGUI:Release(widget)
	end)

	-- Fixed height for scroll area
	local scroll = AceGUI:Create("ScrollFrame")
	scroll:SetLayout("List")
	scroll:SetFullWidth(true)
	scroll:SetHeight(420)
	frame:AddChild(scroll)

	local selectedToDelete = { pages = {}, categories = {} }
	local allSelected = false

	-- Helper to build the list
	local function BuildList()
		scroll:ReleaseChildren()

		-- Registry for direct updates
		local pageCheckboxes = {} -- [pageId] = widget

		-- A. Gather Data
		local sortedCats = {}
		for _, cat in pairs(AngryAssign_Categories) do table.insert(sortedCats, cat) end
		table.sort(sortedCats, function(a,b) return a.Name < b.Name end)

		local orphanPages = {}
		for _, page in pairs(AngryAssign_Pages) do
			if not page.CategoryId then
				table.insert(orphanPages, page)
			end
		end
		table.sort(orphanPages, function(a,b) return a.Name < b.Name end)

		-- B. Render Categories
		for _, cat in ipairs(sortedCats) do
			local catPages = {}
			for _, page in pairs(AngryAssign_Pages) do
				if page.CategoryId == cat.Id then
					table.insert(catPages, page)
				end
			end
			table.sort(catPages, function(a,b) return a.Name < b.Name end)

			local catGroup = AceGUI:Create("SimpleGroup")
			catGroup:SetLayout("Flow")
			catGroup:SetFullWidth(true)
			scroll:AddChild(catGroup)

			local catCheck = AceGUI:Create("CheckBox")
			catCheck:SetLabel("|cffffd200["..cat.Name.."]|r")
			catCheck:SetType("checkbox")
			catCheck:SetValue(selectedToDelete.categories[cat.Id])
			catCheck:SetFullWidth(true)

			catCheck:SetCallback("OnValueChanged", function(_, _, val)
				if val then
					-- State 0 -> 1: Just Select Category
					selectedToDelete.categories[cat.Id] = true
				else
					-- Attempting to Uncheck. Check Logic:
					-- Check if ALL children are ALREADY selected?
					local allChildrenSelected = true
					if #catPages == 0 then
						allChildrenSelected = false
					end
					for _, p in ipairs(catPages) do
						 if not selectedToDelete.pages[p.Id] then
							 allChildrenSelected = false break
						 end
					end

					if not allChildrenSelected and #catPages > 0 then
						-- State 1 -> 2: Select All Children
						selectedToDelete.categories[cat.Id] = true
						catCheck:SetValue(true) -- Keep checked
						for _, p in ipairs(catPages) do
							selectedToDelete.pages[p.Id] = true
							if pageCheckboxes[p.Id] then
								pageCheckboxes[p.Id]:SetValue(true)
							end
						end
					else
						-- State 2 -> 0: Deselect All
						selectedToDelete.categories[cat.Id] = nil
						for _, p in ipairs(catPages) do
							selectedToDelete.pages[p.Id] = nil
							 if pageCheckboxes[p.Id] then
								 pageCheckboxes[p.Id]:SetValue(false)
							 end
						end
					end
				end
			end)

			catGroup:AddChild(catCheck)

			-- Render Children
			for _, page in ipairs(catPages) do
				local pageCheck = AceGUI:Create("CheckBox")
				pageCheck:SetLabel("    " .. page.Name)
				pageCheck:SetType("checkbox")
				pageCheck:SetValue(selectedToDelete.pages[page.Id])
				pageCheck:SetCallback("OnValueChanged", function(_, _, val)
					selectedToDelete.pages[page.Id] = val or nil
				end)
				pageCheck:SetFullWidth(true)
				scroll:AddChild(pageCheck)
				pageCheckboxes[page.Id] = pageCheck
			end
		end

		-- C. Render Orphan Pages
		if #orphanPages > 0 then
			local spacer = AceGUI:Create("Label")
			spacer:SetText(" ")
			scroll:AddChild(spacer)

			for _, page in ipairs(orphanPages) do
				local pageCheck = AceGUI:Create("CheckBox")
				pageCheck:SetLabel(page.Name)
				pageCheck:SetValue(selectedToDelete.pages[page.Id])
				pageCheck:SetCallback("OnValueChanged", function(_, _, val)
					selectedToDelete.pages[page.Id] = val or nil
				end)
				pageCheck:SetFullWidth(true)
				scroll:AddChild(pageCheck)
				pageCheckboxes[page.Id] = pageCheck
			end
		end
	end

	BuildList()

	-- 3. Create Button Group at the bottom
	local btnGroup = AceGUI:Create("SimpleGroup")
	btnGroup:SetLayout("Flow")
	btnGroup:SetFullWidth(true)
	frame:AddChild(btnGroup)

	-- SELECT ALL BUTTON (30% Width)
	local selectAllBtn = AceGUI:Create("Button")
	selectAllBtn:SetText("Select All")
	selectAllBtn:SetRelativeWidth(0.30)
	selectAllBtn:SetCallback("OnClick", function()
		allSelected = not allSelected

		local val = allSelected and true or nil
		for _, cat in pairs(AngryAssign_Categories) do
			selectedToDelete.categories[cat.Id] = val
		end
		for _, page in pairs(AngryAssign_Pages) do
			selectedToDelete.pages[page.Id] = val
		end

		if allSelected then
			selectAllBtn:SetText("Unselect All")
		else
			selectAllBtn:SetText("Select All")
		end

		BuildList()
	end)
	btnGroup:AddChild(selectAllBtn)

	-- DELETE BUTTON (40% Width)
	local delBtn = AceGUI:Create("Button")
	delBtn:SetText("Delete Selected")
	delBtn:SetRelativeWidth(0.40)
	delBtn:SetCallback("OnClick", function()
		local pCount, cCount = 0, 0

		for id, _ in pairs(selectedToDelete.pages) do
			if selectedToDelete.pages[id] then
				AngryAssign:DeletePage(id)
				pCount = pCount + 1
			end
		end

		for id, _ in pairs(selectedToDelete.categories) do
			if selectedToDelete.categories[id] then
				AngryAssign:DeleteCategory(id)
				cCount = cCount + 1
			end
		end

		AngryAssign:Print(string.format("Deleted %d pages and %d categories.", pCount, cCount))
		frame:Hide()
		if AngryAssign.window then
			AngryAssign:UpdateTree()
		end
	end)
	btnGroup:AddChild(delBtn)

	-- CLOSE BUTTON (30% Width)
	local closeBtn = AceGUI:Create("Button")
	closeBtn:SetText("Close")
	closeBtn:SetRelativeWidth(0.30)
	closeBtn:SetCallback("OnClick", function() frame:Hide() end)
	btnGroup:AddChild(closeBtn)
end

-- --------------------------
-- Editing Pages Window --
-- --------------------------

function AngryAssign_ToggleWindow()
	if not AngryAssign.window then
		AngryAssign:CreateWindow()
	end
	if AngryAssign.window:IsShown() then
		AngryAssign.window:Hide()
	else
		if AngryAssign_State.displayed and AngryAssign_Pages[AngryAssign_State.displayed] then
			AngryAssign:SetSelectedId(AngryAssign_State.displayed)
		end
		AngryAssign.window:Show()
	end
end

function AngryAssign_ToggleLock()
	AngryAssign:ToggleLock()
end

local function AngryAssign_LoadTemplate(template, catIndex)
	if not template then
		return
	end

	-- Find or Create Category
	local catId
	local catName = template.name

	-- Check specific categories
	for id, cat in pairs(AngryAssign_Categories) do
		if cat.Name == catName then
			catId = id
			break
		end
	end

	if not catId then
		local newId = 1
		-- Find new positive ID
		while AngryAssign_Categories[newId] do newId = newId + 1 end

		AngryAssign_Categories[newId] = { Id = newId, Name = catName, CategoryId = nil, Index = catIndex } -- Root category
		catId = newId
		AngryAssign:UpdateTree()
	else
		-- Category exists, update index if none?
		local cat = AngryAssign_Categories[catId]
		if not cat.Index and catIndex then
			 cat.Index = catIndex
			 AngryAssign:CategoryUpdated(catId)
		end
	end

	-- Add Pages
	if template.pages then
		for i, tPage in ipairs(template.pages) do
			-- Check if page exists in category
			local exists = false
			 for _, page in pairs(AngryAssign_Pages) do
				if page.CategoryId == catId and page.Name == tPage.name then
					exists = true
					break
				end
			end

			if not exists then
				AngryAssign:CreatePage(tPage.name, tPage.content, catId, i)
			end
		end
	end

	AngryAssign:UpdateTree()
	AngryAssign:UpdateSelected()
end

function AngryAssign:SaveTemplate(name, catId)
	if not name or name == "" then
		return false, "Invalid name"
	end
	if not catId then
		return false, "Invalid category"
	end

	local pages = {}
	for _, page in pairs(AngryAssign_Pages) do
		if page.CategoryId == catId then
			table.insert(pages, { name = page.Name, content = page.Contents })
		end
	end

	if #pages == 0 then
		return false, "Category is empty"
	end

	table.insert(AngryAssign_Templates, { name = name, pages = pages })
	self:Print("Saved template: " .. name)
	return true
end

function AngryAssign:DeleteTemplate(index)
	if AngryAssign_Templates[index] then
		local name = AngryAssign_Templates[index].name
		table.remove(AngryAssign_Templates, index)
		self:Print("Deleted template: " .. name)
	end
end

local function AngryAssign_SaveTemplatePopup(catId)
	local cat = AngryAssign:GetCat(catId)
	if not cat then
		return
	end

	local popup_name = "AngryAssign_SaveTemplate"
	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			text = "Save Category as Template:",
			button1 = SAVE,
			button2 = CANCEL,
			hasEditBox = true,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
			OnShow = function(self)
				local editBox = self.editBox or self.wideEditBox or self.EditBox
				if editBox then
					editBox:SetText(self.data.defaultName)
					editBox:HighlightText()
				end
			end,
			OnAccept = function(self)
				local editBox = self.editBox or self.wideEditBox or self.EditBox
				if editBox then
					local name = editBox:GetText()
					AngryAssign:SaveTemplate(name, self.data.catId)
				end
			end,
			EditBoxOnEnterPressed = function(self)
				local parent = self:GetParent()
				local editBox = parent.editBox or parent.wideEditBox or parent.EditBox
				if editBox then
					 local name = editBox:GetText()
					 AngryAssign:SaveTemplate(name, parent.data.catId)
					 parent:Hide()
				end
			end,
			EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		}
	end
	StaticPopup_Show(popup_name, nil, nil, { catId = catId, defaultName = cat.Name })
end

local function AngryAssign_LoadRaidMenu()
	if not AngryAssign_DropDown then
		AngryAssign_DropDown = CreateFrame("Frame", "AngryAssignMenuFrame", UIParent, "UIDropDownMenuTemplate")
	end

	local menu = {
		{ text = "Standard Raids", isTitle = true, notCheckable = true },
	}

	if app.Templates then
		for i, template in ipairs(app.Templates) do
			table.insert(menu, {
				text = template.name,
				func = function() AngryAssign_LoadTemplate(template, i) end,
				notCheckable = true
			})
		end
	end

	if AngryAssign_Templates and #AngryAssign_Templates > 0 then
		table.insert(menu, { text = " ", isTitle = true, notCheckable = true })
		table.insert(menu, { text = "Custom Templates", isTitle = true, notCheckable = true })

		for i, template in ipairs(AngryAssign_Templates) do
			local subMenu = {
				{ text = "Load", func = function() AngryAssign_LoadTemplate(template) end, notCheckable = true },
				{ text = "Delete", func = function() AngryAssign:DeleteTemplate(i) end, notCheckable = true }
			}
			table.insert(menu, {
				text = template.name,
				hasArrow = true,
				menuList = subMenu,
				notCheckable = true
			})
		end
	end

	DDM.EasyMenu(menu, AngryAssign_DropDown, "cursor", 0, 0, "MENU")
end

local function AngryAssign_AddPage(widget, event, value)
	local popup_name = "AngryAssign_AddPage"

	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			text = "New page name:",
			button1 = OKAY,
			button2 = CANCEL,
			hasEditBox = true,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,

			OnAccept = function(self)
				-- Pass 'self' (the popup frame) directly
				local success, err = AngryAssign:CreatePage(self)
				if not success and err then
					print(err)
				end
			end,

			EditBoxOnEnterPressed = function(self)
				local parent = self:GetParent()
				local success, err = AngryAssign:CreatePage(parent)

				if success then
					parent:Hide()
				elseif err then
					print(err)
				end
			end,

			EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		}
	end

	StaticPopup_Show(popup_name)
end

local function AngryAssign_RenamePage(pageId)
	local page = AngryAssign:Get(pageId)
	if not page then
		return
	end

	-- FIX: Use a static name, do not append ID (prevents memory leak)
	local popup_name = "AngryAssign_RenamePage"

	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			-- Use %s to dynamically insert the old name later
			text = "Rename page \"%s\" to:",
			button1 = OKAY,
			button2 = CANCEL,
			hasEditBox = true,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,

			OnShow = function(self)
				-- Retrieve the ID passed via StaticPopup_Show
				local id = self.data
				local p = AngryAssign:Get(id)
				if p then
					local editBox = self.editBox or self.wideEditBox or self.EditBox
					if editBox then
						editBox:SetText(p.Name)
						editBox:HighlightText()
					end
				end
			end,

			OnAccept = function(self)
				local id = self.data
				local success, err = AngryAssign:RenamePage(id, self)
				if not success and err then
					print(err)
				end
			end,

			EditBoxOnEnterPressed = function(self)
				local parent = self:GetParent()
				local id = parent.data
				local success, err = AngryAssign:RenamePage(id, parent)

				if success then
					parent:Hide()
				elseif err then
					print(err)
				end
			end,

			EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		}
	end

	-- Args: Name, TextArg1 (%s), TextArg2, Data (The Page ID)
	StaticPopup_Show(popup_name, page.Name, nil, page.Id)
end

local function AngryAssign_DeletePage(pageId)
	local page = AngryAssign:Get(pageId)
	if not page then
		return
	end

	local popup_name = "AngryAssign_DeletePage"

	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			button1 = OKAY,
			button2 = CANCEL,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,

			OnAccept = function(self)
				-- Get ID from data
				local id = self.data
				AngryAssign:DeletePage(id)
			end,
		}
	end

	-- Pass the dynamic text as arg1, and the ID as data
	StaticPopupDialogs[popup_name].text = "Are you sure you want to delete page \"%s\"?"
	StaticPopup_Show(popup_name, page.Name, nil, page.Id)
end

local function AngryAssign_AddCategory(widget, event, value)
	local popup_name = "AngryAssign_AddCategory"
	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			text = "New category name:",
			button1 = OKAY,
			button2 = CANCEL,
			hasEditBox = true,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,

			OnAccept = function(self)
				local success, err = AngryAssign:CreateCategory(self)
				if not success and err then
					print(err)
				end
			end,

			EditBoxOnEnterPressed = function(self)
				local parent = self:GetParent()
				local success, err = AngryAssign:CreateCategory(parent)
				if success then
					parent:Hide()
				elseif err then
					print(err)
				end
			end,

			EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		}
	end
	StaticPopup_Show(popup_name)
end

local function AngryAssign_RenameCategory(catId)
	local cat = AngryAssign:GetCat(catId)
	if not cat then
		return
	end

	local popup_name = "AngryAssign_RenameCategory"

	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			text = "Rename category \"%s\" to:",
			button1 = OKAY,
			button2 = CANCEL,
			hasEditBox = true,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,

			OnShow = function(self)
				local id = self.data
				local c = AngryAssign:GetCat(id)
				if c then
					local editBox = self.editBox or self.wideEditBox or self.EditBox
					editBox:SetText(c.Name)
					editBox:HighlightText()
				end
			end,

			OnAccept = function(self)
				local id = self.data
				local success, err = AngryAssign:RenameCategory(id, self)
				if not success and err then
					print(err)
				end
			end,

			EditBoxOnEnterPressed = function(self)
				local parent = self:GetParent()
				local id = parent.data
				local success, err = AngryAssign:RenameCategory(id, parent)

				if success then
					parent:Hide()
				elseif err then
					print(err)
				end
			end,

			EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		}
	end

	StaticPopup_Show(popup_name, cat.Name, nil, cat.Id)
end

local function AngryAssign_DeleteCategory(catId)
	local cat = AngryAssign:GetCat(catId)
	if not cat then
		return
	end

	local popup_name = "AngryAssign_DeleteCategory"

	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			button1 = "Delete Category Only",
			button2 = CANCEL,
			button3 = "Delete Category & Pages",
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
			OnAccept = function(self)
				local id = self.data
				AngryAssign:DeleteCategory(id)
			end,
			OnAlt = function(self)
				local id = self.data
				AngryAssign:DeleteCategoryAndChildren(id)
			end,
		}
	end

	StaticPopupDialogs[popup_name].text = "Are you sure you want to delete category \"%s\"?"
	StaticPopup_Show(popup_name, cat.Name, nil, cat.Id)
end

local function AngryAssign_AssignCategory(frame, entryId, catId)
	CloseDropDownMenus()

	AngryAssign:AssignCategory(entryId, catId)
end

local function AngryAssign_DisplayPage(widget, event, value)
	if not AngryAssign:PermissionCheck() then
		return
	end
	local id = AngryAssign:SelectedId()
	AngryAssign:DisplayPage( id )
end

local function AngryAssign_ClearPage(widget, event, value)
	if not AngryAssign:PermissionCheck() then
		return
	end

	AngryAssign:ClearDisplayed()
	AngryAssign:SendDisplay( nil, true )
end
-- Expose for init.lua options table
app._AngryAssign_ClearPage = AngryAssign_ClearPage

local function AngryAssign_TextChanged(widget, event, value)
	AngryAssign.window.button_restore:SetDisabled(false)
	AngryAssign.window.button_display:SetDisabled(true)
	AngryAssign.window.button_output:SetDisabled(true)
end

local function AngryAssign_TextEntered(widget, event, value)
	AngryAssign:UpdateContents(AngryAssign:SelectedId(), value)
end

local function AngryAssign_RestorePage(widget, event, value)
	local pageId = AngryAssign:SelectedId()
	if not pageId then
		return
	end
	local page = AngryAssign_Pages[pageId]
	if not page then
		return
	end

	if not AngryAssign_DropDown then
		AngryAssign_DropDown = CreateFrame("Frame", "AngryAssignMenuFrame", UIParent, "UIDropDownMenuTemplate")
	end

	local menu = {
		{ text = "Restore Version", isTitle = true, notCheckable = true },
	}

	if page.History then
		for i, entry in ipairs(page.History) do
			local dateStr = date("%m/%d %H:%M", entry.timestamp)
			local author = entry.author or "?"
			local contentPreview = entry.content:gsub("\n", " "):sub(1, 20)

			table.insert(menu, {
				text = string.format("|cff999999%s|r |cffffd100%s|r: %s...", dateStr, author, contentPreview),
				func = function()
					AngryAssign:UpdateContents(pageId, entry.content)
					AngryAssign.window.text:SetText(entry.content)
					AngryAssign.window.text.button:Enable()
					AngryAssign_TextChanged(widget, event, value)
				end,
				notCheckable = true
			})
		end
	end

	if #menu == 1 then
		table.insert(menu, { text = "No history available", disabled = true, notCheckable = true })
	end

	DDM.EasyMenu(menu, AngryAssign_DropDown, "cursor", 0, 0, "MENU")
end

local function AngryAssign_HighlightNames()
	if not AngryAssign.window or not AngryAssign.window.text then
		return
	end

	local text = AngryAssign.window.text:GetText()
	if not text or text == "" then
		return
	end

	-- Strip existing color codes to fix broken tags or refresh highlights
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")

	local roster = {}
	if not (IsInRaid() or IsInGroup()) then
		local name = UnitName("player")
		local _, class = UnitClass("player")
		if name and class and app.ColorTable["|c"..class:lower()] then
			roster[name] = app.ColorTable["|c"..class:lower()]
		end
	else
		IterateGroupMembers(function(rawName, fullName, _, _, class)
			if class and app.ColorTable["|c"..class:lower()] then
				local shortName = (rawName or EnsureUnitShortName(fullName)):match("([^-]+)")
				if shortName then
					roster[shortName] = app.ColorTable["|c"..class:lower()]
				end
			end
			return false
		end)
	end

	-- Include Guild Roster
	if IsInGuild() then
		local numGuild = GetNumGuildMembers()
		for i = 1, numGuild do
			local name, _, _, _, class, _, _, _, _, _, classFileName = GetGuildRosterInfo(i)
			-- Use classFileName (English) if available, otherwise fallback to class (Localized)
			local fileClass = classFileName or class

			if name and fileClass and app.ColorTable["|c"..fileClass:lower()] then
				name = name:match("([^-]+)") -- Strip realm
				roster[name] = app.ColorTable["|c"..fileClass:lower()]
			end
		end
	end

	local Mask = {}
	-- Mask tags like {mark} so we don't colorize the text inside them
	text = text:gsub("(%b{})", function(s)
		table.insert(Mask, s)
		return "\001" .. #Mask .. "\002"
	end)

	local count = 0
	for name, color in pairs(roster) do
		-- Escape magic chars and wrap in capture group
		local escapedName = name:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
		local pattern = "%f[%a](" .. escapedName .. ")%f[%A]"
		local newText, n = text:gsub(pattern, color .. "%1|r")
		if n > 0 then
			text = newText
			count = count + n
		end
	end

	-- Unmask
	text = text:gsub("\001(%d+)\002", function(id)
		return Mask[tonumber(id)]
	end)

	if count > 0 then
		AngryAssign.window.text:SetText(text)
		AngryAssign.window.text:SetFocus()

		-- Save the highlighted text immediately
		local selectedId = AngryAssign:SelectedId()
		if selectedId and selectedId > 0 then
			AngryAssign:UpdateContents(selectedId, text)
		end

		-- Re-enable the Send button since we just saved
		if AngryAssign.window.button_display then
			AngryAssign.window.button_display:SetDisabled(false)
		end
	end
end

local function AngryAssign_CategoryMenuList(entryId, parentId)
	local categories = {}

	local checkedId
	if entryId > 0 then
		local page = AngryAssign_Pages[entryId]
		checkedId = page.CategoryId
	else
		local cat = AngryAssign_Categories[-entryId]
		checkedId = cat.CategoryId
	end

	for _, cat in pairs(AngryAssign_Categories) do
		if cat.Id ~= -entryId and (parentId or not cat.CategoryId) and (not parentId or cat.CategoryId == parentId) then
			local subMenu = AngryAssign_CategoryMenuList(entryId, cat.Id)
			table.insert(categories, { text = cat.Name, value = cat.Id, menuList = subMenu, hasArrow = (subMenu ~= nil), checked = (checkedId == cat.Id), func = AngryAssign_AssignCategory, arg1 = entryId, arg2 = cat.Id })
		end
	end

	table.sort(categories, function(a,b) return a.text < b.text end)

	if #categories > 0 then
		return categories
	end
end

local function AngryAssign_EditVariables(id, type)
	if not AngryAssign:PermissionCheck() then
		return
	end

	local vars = nil
	if type == "category" then
		local cat = AngryAssign_Categories[id]
		if cat then
			vars = cat.Vars
		end
	else
		local page = AngryAssign_Pages[id]
		if page then
			vars = page.Vars
		end
	end

	local DEFAULT_VARS_TEMPLATE = "MT=\nOT1=\nOT2=\nOT3=\nOT4=\nOT5=\nMARK="
	if not vars or vars == "" or vars == "{}" then
		vars = DEFAULT_VARS_TEMPLATE
	end

	local frame = AceGUI:Create("Window")
	frame:SetTitle("Edit Template Variables")
	frame:SetLayout("Flow")
	frame:SetWidth(400)
	frame:SetHeight(300)
	frame:EnableResize(true)
	_G["AngryAssign_EditVars_Window"] = frame.frame
	table.insert(UISpecialFrames, "AngryAssign_EditVars_Window")

	local editBox = AceGUI:Create("MultiLineEditBox")
	editBox:SetLabel("Variables (JSON or Key=Value pairs)")
	editBox:SetNumLines(15)
	editBox:SetText(vars)
	editBox:SetFullWidth(true)
	editBox:SetFullHeight(true)
	editBox:DisableButton(false)
	editBox:SetCallback("OnEnterPressed", function(widget, event, text)
		-- Normalize Line Endings
		local normalized = text:gsub("\r\n", "\n")

		-- Don't save if unmodified default template
		if normalized == "MT=\nOT1=\nOT2=\nOT3=\nOT4=\nOT5=\nMARK=" then
			text = nil
		elseif text == "" then
			text = nil
		end

		if type == "category" then
			local cat = AngryAssign_Categories[id]
			if cat then
				cat.Vars = text
				AngryAssign:CategoryUpdated(id)
			end
		else
			local page = AngryAssign_Pages[id]
			if page then
				page.Vars = text
				AngryAssign:PageUpdated(id)
			end
		end
		frame:Hide()
		AngryAssign:UpdateDisplayed()
	end)
	frame:AddChild(editBox)
	frame:SetCallback("OnClose", function(widget) AceGUI:Release(widget) end)
end

-- ── Context Menus and Tree ──────────────────────────────────────────────────

local PagesDropDownList
function AngryAssign_PageMenu(pageId)
	local page = AngryAssign_Pages[pageId]
	if not page then
		return
	end

	if not PagesDropDownList then
		PagesDropDownList = {
			{ notCheckable = true, isTitle = true },
			{ text = "Rename", notCheckable = true, func = function(_, clickedPageId) AngryAssign_RenamePage(clickedPageId) end },
			{ text = "Delete", notCheckable = true, func = function(_, clickedPageId) AngryAssign_DeletePage(clickedPageId) end },
			{ text = "Edit Variables", notCheckable = true, func = function(_, clickedPageId) AngryAssign_EditVariables(clickedPageId, "page") end },
			{ text = "Export", notCheckable = true, hasArrow = true, menuList = {
				{ text = "Encoded AA", notCheckable = true, func = function(frame, id) AngryAssign:Export(id, "page", "Encoded AA") end },
				{ text = "JSON", notCheckable = true, func = function(frame, id) AngryAssign:Export(id, "page", "JSON") end },
				{ text = "Markdown", notCheckable = true, func = function(frame, id) AngryAssign:Export(id, "page", "Markdown") end },
				{ text = "Output", notCheckable = true, func = function(frame, id) AngryAssign:Export(id, "page", "Output") end },
			} },
			{ text = "Category", notCheckable = true, hasArrow = true },
		}
	end

	local permission = AngryAssign:PermissionCheck()

	PagesDropDownList[1].text = page.Name
	PagesDropDownList[2].arg1 = pageId
	PagesDropDownList[2].disabled = not permission
	PagesDropDownList[3].arg1 = pageId
	PagesDropDownList[4].arg1 = pageId
	for _, item in ipairs(PagesDropDownList[5].menuList) do item.arg1 = pageId end

	local categories = AngryAssign_CategoryMenuList(pageId)
	if categories ~= nil then
		PagesDropDownList[6].menuList = categories
		PagesDropDownList[6].disabled = false
		PagesDropDownList[6].arg1 = pageId
	else
		PagesDropDownList[6].menuList = {}
		PagesDropDownList[6].disabled = true
	end

	return PagesDropDownList
end

local CategoriesDropDownList
local function AngryAssign_CategoryMenu(catId)
	local cat = AngryAssign_Categories[catId]
	if not cat then
		return
	end

	if not CategoriesDropDownList then
		CategoriesDropDownList = {
			{ notCheckable = true, isTitle = true },
			{ text = "Rename", notCheckable = true, func = function(_, clickedCategoryId) AngryAssign_RenameCategory(clickedCategoryId) end },
			{ text = "Save as Template", notCheckable = true, func = function(_, clickedCategoryId) AngryAssign_SaveTemplatePopup(clickedCategoryId) end },
			{ text = "Delete", notCheckable = true, func = function(_, clickedCategoryId) AngryAssign_DeleteCategory(clickedCategoryId) end },
			{ text = "Edit Variables", notCheckable = true, func = function(_, clickedCategoryId) AngryAssign_EditVariables(clickedCategoryId, "category") end },
			{ text = "Export", notCheckable = true, hasArrow = true, menuList = {
				{ text = "Encoded AA", notCheckable = true, func = function(frame, id) AngryAssign:Export(id, "category", "Encoded AA") end },
				{ text = "JSON", notCheckable = true, func = function(frame, id) AngryAssign:Export(id, "category", "JSON") end },
				{ text = "Markdown", notCheckable = true, func = function(frame, id) AngryAssign:Export(id, "category", "Markdown") end },
				{ text = "Output", notCheckable = true, func = function(frame, id) AngryAssign:Export(id, "category", "Output") end },
			} },
			{ text = "Category", notCheckable = true, hasArrow = true },
		}
	end
	CategoriesDropDownList[1].text = cat.Name
	CategoriesDropDownList[2].arg1 = catId
	CategoriesDropDownList[3].arg1 = catId
	CategoriesDropDownList[4].arg1 = catId
	CategoriesDropDownList[5].arg1 = catId
	CategoriesDropDownList[6].arg1 = catId
	for _, item in ipairs(CategoriesDropDownList[6].menuList) do item.arg1 = catId end
	CategoriesDropDownList[7].arg1 = catId

	local categories = AngryAssign_CategoryMenuList(-catId)
	if categories ~= nil then
		CategoriesDropDownList[7].menuList = categories
		CategoriesDropDownList[7].disabled = false
	else
		CategoriesDropDownList[7].menuList = {}
		CategoriesDropDownList[7].disabled = true
	end

	return CategoriesDropDownList
end

local clickTime = 0
local clickValue = nil
local function AngryAssign_TreeClick(widget, event, value, selected, button)
	HideDropDownMenu(1)
	local selectedId = selectedLastValue(value)

	if button == "LeftButton" and selectedId > 0 then
		if clickValue == value and (GetTime() - clickTime) < 0.3 then
			 AngryAssign_DisplayPage()
			 clickValue = nil
			 return false
		end
		clickTime = GetTime()
		clickValue = value
	end
	if selectedId < 0 then
		if button == "RightButton" then
			if not AngryAssign_DropDown then
				AngryAssign_DropDown = CreateFrame("Frame", "AngryAssignMenuFrame", UIParent, "UIDropDownMenuTemplate")
			end
			DDM.EasyMenu(AngryAssign_CategoryMenu(-selectedId), AngryAssign_DropDown, "cursor", 0 , 0, "MENU")

		else
			local status = (widget.status or widget.localstatus).groups
			status[value] = not status[value]
			widget:RefreshTree()
		end
		return false
	else
		if button == "RightButton" then
			if not AngryAssign_DropDown then
				AngryAssign_DropDown = CreateFrame("Frame", "AngryAssignMenuFrame", UIParent, "UIDropDownMenuTemplate")
			end
			DDM.EasyMenu(AngryAssign_PageMenu(selectedId), AngryAssign_DropDown, "cursor", 0 , 0, "MENU")

			return false
		end
	end
end

local function AngryAssign_TreeMenuClick(widget, event, uniquevalue)
	-- uniquevalue might be concatenated string "parent\001child".
	-- But AngryTreeGroup fires button.uniquevalue.
	-- Wait, selectedLastValue(value) parses it.
	local selectedId = selectedLastValue(uniquevalue)

	if not AngryAssign_DropDown then
		AngryAssign_DropDown = CreateFrame("Frame", "AngryAssignMenuFrame", UIParent, "UIDropDownMenuTemplate")
	end

	if selectedId < 0 then
		-- Category
		DDM.EasyMenu(AngryAssign_CategoryMenu(-selectedId), AngryAssign_DropDown, "cursor", 0 , 0, "MENU")
	else
		-- Page
		DDM.EasyMenu(AngryAssign_PageMenu(selectedId), AngryAssign_DropDown, "cursor", 0 , 0, "MENU")
	end
end

-- ── Main Menu and Window ────────────────────────────────────────────────────

local function AngryAssign_MainMenu(frame)
	if not AngryAssign_DropDown then
		AngryAssign_DropDown = CreateFrame("Frame", "AngryAssignMenuFrame", UIParent, "UIDropDownMenuTemplate")
	end

	local menu = {
		{ text = "Add Page", func = AngryAssign_AddPage, notCheckable = true },
		{ text = "Add Category", func = AngryAssign_AddCategory, notCheckable = true },
		{ text = "Load Raid Template", func = AngryAssign_LoadRaidMenu, notCheckable = true },
		{ text = " ", isTitle = true, notCheckable = true },
		{ text = "Import", hasArrow = true, notCheckable = true, menuList = {
			{ text = "Encoded AA", func = function() AngryAssign:ShowImportWindow() end, notCheckable = true },
			{ text = "JSON", func = function() app._AngryAssign_ImportPage() end, notCheckable = true },
			{ text = "Markdown", func = function() app._AngryAssign_ImportPage() end, notCheckable = true },
		} },
		{ text = " ", isTitle = true, notCheckable = true },
		{ text = "Manage Pages", func = function() AngryAssign:ShowBulkManagement() end, notCheckable = true },
		{ text = "Clear Page", func = AngryAssign_ClearPage, notCheckable = true },
	}
	DDM.EasyMenu(menu, AngryAssign_DropDown, "cursor", 0, 0, "MENU")
end

local AngryAssign_Title = app.Title

function AngryAssign:CreateWindow()
	local window = AceGUI:Create("Frame")
	window:SetTitle(AngryAssign_Title)
	window:SetStatusText("")
	window:SetLayout("Flow")
	if AngryAssign:GetConfig("scale") then
		window.frame:SetScale( AngryAssign:GetConfig("scale") )
	end
	window:SetStatusTable(AngryAssign_State.window)
	window:Hide()
	AngryAssign.window = window

	-- Move content area up 20px relative to the title bar
	window.content:ClearAllPoints()
	window.content:SetPoint("TOPLEFT", window.frame, "TOPLEFT", 17, -7)
	window.content:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -17, 40)
	window.OnHeightSet = function(frameWidget, height)
		local content = frameWidget.content
		local contentheight = height - 37
		if contentheight < 0 then
			contentheight = 0
		end
		content:SetHeight(contentheight)
		content.height = contentheight
	end
	window:OnHeightSet(window.frame:GetHeight())

	AngryAssign_Window = window.frame
	if window.frame.SetResizeBounds then -- WoW 10.0
		window.frame:SetResizeBounds(600, 300)
	else
		window.frame:SetMinResize(600, 300)
	end
	window.frame:SetFrameStrata("HIGH")
	window.frame:SetFrameLevel(1)
	window.frame:SetClampedToScreen(true)
	tinsert(UISpecialFrames, "AngryAssign_Window")

	local header = AceGUI:Create("SimpleGroup")
	header:SetLayout("Flow")
	header:SetFullWidth(true)
	window:AddChild(header)

	local searchBox = AceGUI:Create("EditBox")
	searchBox:DisableButton(true)
	searchBox:SetWidth(175)
	searchBox:SetCallback("OnTextChanged", function(_, _, v)
		if AngryAssign.window.tree then
			AngryAssign.window.tree:SetSearchKeyword(v)
		end
	end)
	header:AddChild(searchBox)
	window.searchBox = searchBox

	local searchIcon = searchBox.editbox:CreateTexture(nil, "OVERLAY")
	searchIcon:SetTexture("Interface\\Common\\UI-SearchBox-Icon")
	searchIcon:SetSize(14, 14)
	searchIcon:SetPoint("RIGHT", searchBox.editbox, "RIGHT", -4, 0)
	searchIcon:SetAlpha(0.5)
	searchBox.editbox:SetTextInsets(4, 20, 0, 0)

	local tree = AceGUI:Create("AngryTreeGroup")
	tree:SetTree( self:GetTree() )
	tree:SelectByValue(1)
	tree:SetStatusTable(AngryAssign_State.tree)
	tree:SetFullWidth(true)
	tree:SetFullHeight(true)
	tree:SetLayout("Flow")
	tree:SetCallback("OnGroupSelected", function(widget, event, value) AngryAssign:UpdateSelected(true) end)
	tree:SetCallback("OnTreeDragDrop", function(widget, event, source, target, position) AngryAssign:MoveItem(source, target, position) end)
	tree:SetCallback("OnClick", AngryAssign_TreeClick)
	tree:SetCallback("OnButtonMenu", AngryAssign_TreeMenuClick)
	window:AddChild(tree)
	window.tree = tree

	tree.treeframe:HookScript("OnSizeChanged", function(frame, width)
		if AngryAssign.window and AngryAssign.window.searchBox then
			AngryAssign.window.searchBox:SetWidth(width)
		end
	end)

	-- Enable delete key for tree
	tree.treeframe:EnableKeyboard(true)
	tree.treeframe:SetPropagateKeyboardInput(true)
	tree.treeframe:SetScript("OnKeyDown", function(treeFrame, key)
		if key == "DELETE" then
			local selectedId = AngryAssign:SelectedId()
			if selectedId and selectedId > 0 then
				AngryAssign_DeletePage(selectedId)
				treeFrame:SetPropagateKeyboardInput(false)
			end
		end
	end)

	local text = AceGUI:Create("MultiLineEditBox")
	text:SetLabel(nil)
	text:SetFullWidth(true)
	text:SetFullHeight(true)
	text:SetCallback("OnTextChanged", AngryAssign_TextChanged)
	text:SetCallback("OnEnterPressed", AngryAssign_TextEntered)
	tree:AddChild(text)
	window.text = text
	text.button:SetWidth(75)
	local buttontext = text.button:GetFontString()
	buttontext:ClearAllPoints()
	buttontext:SetPoint("TOPLEFT", text.button, "TOPLEFT", 15, -1)
	buttontext:SetPoint("BOTTOMRIGHT", text.button, "BOTTOMRIGHT", -15, 1)

	tree:PauseLayout()
	local button_display = AceGUI:Create("Button")
	button_display:SetText("Send")
	button_display:SetWidth(90)
	button_display:SetHeight(22)
	button_display:ClearAllPoints()
	button_display:SetPoint("BOTTOMRIGHT", text.frame, "BOTTOMRIGHT", 0, 4)
	button_display:SetCallback("OnClick", AngryAssign_DisplayPage)
	tree:AddChild(button_display)
	window.button_display = button_display

	window.button_display = button_display

	local button_restore = AceGUI:Create("Button")
	button_restore:SetText("Restore")
	button_restore:SetWidth(80)
	button_restore:SetHeight(22)
	button_restore:ClearAllPoints()
	-- Anchor directly to text frame (replace Revert button position)
	button_restore:SetPoint("BOTTOMLEFT", text.frame, "BOTTOMLEFT", 100, 4)
	button_restore:SetCallback("OnClick", AngryAssign_RestorePage)
	tree:AddChild(button_restore)
	window.button_restore = button_restore

	-- Right-aligned group (Output <- Highlight <- Send)

	local button_high = AceGUI:Create("Button")
	button_high:SetText("Highlight")
	button_high:SetWidth(90)
	button_high:SetHeight(22)
	button_high:ClearAllPoints()
	button_high:SetPoint("RIGHT", button_display.frame, "LEFT", -6, 0)
	button_high:SetCallback("OnClick", AngryAssign_HighlightNames)
	tree:AddChild(button_high)
	window.button_high = button_high

	local button_output = AceGUI:Create("Button")
	button_output:SetText("Output")
	button_output:SetWidth(80)
	button_output:SetHeight(22)
	button_output:ClearAllPoints()
	button_output:SetPoint("RIGHT", button_high.frame, "LEFT", -6, 0)
	button_output:SetCallback("OnClick", AngryAssign_OutputDisplayed)
	tree:AddChild(button_output)
	window.button_output = button_output

	window:PauseLayout()

	-- Bottom Left "Menu" Button
	local button_menu = AceGUI:Create("Button")
	button_menu:SetText("Menu")
	button_menu:SetWidth(80)
	button_menu:SetHeight(19)
	button_menu:ClearAllPoints()
	button_menu:SetPoint("BOTTOMLEFT", window.frame, "BOTTOMLEFT", 17, 18)
	button_menu:SetCallback("OnClick", AngryAssign_MainMenu)
	window:AddChild(button_menu)
	window.button_menu = button_menu

	self:UpdateSelected(true)
	self:UpdateMedia()

	--self:CreateIconPicker()
end

local function AngryAssign_IconPicker_Clicked(widget, event)
	local icon

	if widget:GetUserData("name") then
		icon = widget:GetUserData("name")
	else
		icon = "{icon "..strmatch(widget.image:GetTexture():lower(), "^interface\\icons\\([-_%w]+)$").."}"
	end

	local position = AngryAssign.window.text.editBox:GetCursorPosition()
	if position > 0 then
		local text = AngryAssign.window.text:GetText()
		AngryAssign.window.text:SetText(strsub(text, 1, position)..icon..strsub(text, position+1, AngryAssign.window.text.editBox:GetNumLetters()))
		AngryAssign.window.text.editBox:SetCursorPosition(position, string.len(text))
	else
		AngryAssign.window.text:SetText(AngryAssign.window.text:GetText()..icon)
	end

	AngryAssign.window.text.button:Enable()
	AngryAssign_TextChanged()
end

local iconCache = nil
local function AngryAssign_IconPicker_TextChanged(widget, event, value)
	AngryAssign.iconpicker_scroll:ReleaseChildren()

	local names = {}

	local spellID = strmatch(value, "|Hspell:(%d+)|")
	local itemID = strmatch(value, "|Hitem:(%d+):")

	if spellID then
		local path = select(3, GetSpellInfo(tonumber(spellID)))
		tinsert(names, path)
	elseif itemID then
		local path = select(10, GetItemInfo(tonumber(itemID)))
		tinsert(names, path)
	elseif value ~= "" then
		if not iconCache then
			iconCache = GetMacroIcons()
		end
		local iconsFound = 0
		local subname = value:lower()
		for _, path in ipairs(iconCache) do
			if path:lower():find(subname) then
				tinsert(names, "Interface\\Icons\\"..path)
				iconsFound = iconsFound + 1
			end

			if iconsFound >= 60 then
				break
			end
		end
	end

	for _, path in ipairs(names) do
		if path then
			local icon = AceGUI:Create("Icon")
			icon:SetImage(path)
			icon:SetImageSize(32, 32)
			icon:SetWidth(36)
			icon:SetHeight(36)
			icon:SetCallback("OnClick", AngryAssign_IconPicker_Clicked)
			AngryAssign.iconpicker_scroll:AddChild(icon)
		end
	end
end

function AngryAssign:CreateIconButton(name, texture)
	local icon = AceGUI:Create("Icon")
	icon:SetImage(texture)
	icon:SetImageSize(20, 20)
	icon:SetWidth(21)
	icon:SetHeight(24)
	icon:SetUserData("name", name)
	icon:SetCallback("OnClick", AngryAssign_IconPicker_Clicked)
	return icon
end

function AngryAssign:CreateIconPicker()
	local window = AceGUI:Create("Window")
	window:SetTitle("Insert an Icon")
	window:SetLayout("List")
	window:SetWidth(240)
	window:SetHeight(320)
	window.frame:SetParent(self.window.frame)
	window.frame:ClearAllPoints()
	window.frame:SetPoint("TOPLEFT", self.window.frame, "TOPRIGHT", 4, -4)
	window.frame:SetMovable(false)
	window.title:SetScript("OnMouseDown", nil)
	window.title:SetScript("OnMouseUp", nil)
	window:EnableResize(false)
	self.iconpicker = window

	local group = AceGUI:Create("SimpleGroup")
	group:SetLayout("Flow")
	group:SetFullWidth(true)
	for i = 8, 1, -1 do
		group:AddChild( self:CreateIconButton("{rt"..i.."}", "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"..i) )
	end
	group:AddChild( self:CreateIconButton("{bl}", "Interface\\Icons\\SPELL_Nature_Bloodlust") )
	group:AddChild( self:CreateIconButton("{hs}", "Interface\\Icons\\INV_Stone_04") )
	window:AddChild(group)

	local heading = AceGUI:Create("Heading")
	heading:SetFullWidth(true)
	window:AddChild(heading)

	local text = AceGUI:Create("EditBox")
	text:SetFullWidth(true)
	text:DisableButton(true)
	text:SetCallback("OnTextChanged", AngryAssign_IconPicker_TextChanged)
	window:AddChild(text)

	local scroll = AceGUI:Create("ScrollFrame")
	scroll:SetLayout("Flow")
	scroll:SetFullWidth(true)
	scroll:SetFullHeight(true)
	window:AddChild(scroll)
	self.iconpicker_scroll = scroll
end

function AngryAssign:SelectedUpdated(sender)
	if self.window and self.window.text.button:IsEnabled() then
		local popup_name = "AngryAssign_PageUpdated"
		if StaticPopupDialogs[popup_name] == nil then
			StaticPopupDialogs[popup_name] = {
				button1 = OKAY,
				whileDead = true,
				text = "",
				hideOnEscape = true,
				preferredIndex = 3
			}
		end
		StaticPopupDialogs[popup_name].text = "The page you are editing has been updated by "..sender..".\n\nYou can view this update by reverting your changes."
		StaticPopup_Show(popup_name)
		return true
	else
		return false
	end
end

-- ── Tree building ───────────────────────────────────────────────────────────

local function GetTree_Sort(a, b)
	if a.index and b.index then
		if a.index == b.index then
			return a.text < b.text
		else
			return a.index < b.index
		end
	elseif a.index then
		return true
	elseif b.index then
		return false
	else
		return a.text < b.text
	end
end

local function GetTree_InsertPage(tree, page)
	local name = page.Name
	if page.Vars and page.Vars ~= "{}" and page.Vars ~= "" then
		name = name .. " |cffaaaaaa‡|r"
	end
	-- Use page.Index
	local item = { value = page.Id, text = name, index = page.Index }
	if page.Id == AngryAssign_State.displayed then
		item.icon = "Interface\\BUTTONS\\UI-GuildButton-MOTD-Up"
	end
	table.insert(tree, item)
end

local function GetTree_InsertChildren(categoryId, displayedPages)
	local tree = {}
	for _, cat in pairs(AngryAssign_Categories) do
		if cat.CategoryId == categoryId then
			local name = cat.Name
			if cat.Vars and cat.Vars ~= "{}" and cat.Vars ~= "" then
				name = name .. " |cffaaaaaa‡|r"
			end
			table.insert(tree, { value = -cat.Id, text = name, index = cat.Index, children = GetTree_InsertChildren(cat.Id, displayedPages) })
		end
	end

	for _, page in pairs(AngryAssign_Pages) do
		if page.CategoryId == categoryId then
			displayedPages[page.Id] = true
			GetTree_InsertPage(tree, page)
		end
	end

	table.sort(tree, GetTree_Sort)
	return tree
end

function AngryAssign:GetTree()
	local tree = {}
	local displayedPages = {}

	for _, cat in pairs(AngryAssign_Categories) do
		if not cat.CategoryId then
			local name = cat.Name
			if cat.Vars and cat.Vars ~= "{}" and cat.Vars ~= "" then
				name = name .. " |cffaaaaaa‡|r"
			end
			table.insert(tree, { value = -cat.Id, text = name, index = cat.Index, children = GetTree_InsertChildren(cat.Id, displayedPages) })
		end
	end

	for _, page in pairs(AngryAssign_Pages) do
		if not page.CategoryId or not displayedPages[page.Id] then
			GetTree_InsertPage(tree, page)
		end
	end

	table.sort(tree, GetTree_Sort)

	return tree
end

function AngryAssign:MoveItem(sourceValue, targetValue, position)
	if not sourceValue or not targetValue then
		return
	end
	if sourceValue == targetValue then
		return
	end

	local sourceId = selectedLastValue(sourceValue)
	local targetId = selectedLastValue(targetValue)
	if sourceId == targetId then
		return
	end

	local sourceObj, sourceType
	if sourceId > 0 then
		sourceObj = AngryAssign_Pages[sourceId]
		sourceType = "page"
	else
		sourceObj = AngryAssign_Categories[-sourceId]
		sourceType = "category"
	end
	if not sourceObj then
		return
	end

	local targetObj, targetType
	if targetId > 0 then
		targetObj = AngryAssign_Pages[targetId]
		targetType = "page"
	else
		targetObj = AngryAssign_Categories[-targetId]
		targetType = "category"
	end
	if not targetObj then
		return
	end

	local newParentId, newIndex
	position = position or "after"

	if position == "into" and targetType == "category" then
		newParentId = targetObj.Id
		local maxIdx = 0
		for _, p in pairs(AngryAssign_Pages) do
			if p.CategoryId == newParentId and (p.Index or 0) > maxIdx then
				maxIdx = p.Index or 0
			end
		end
		for _, c in pairs(AngryAssign_Categories) do
			if c.CategoryId == newParentId and (c.Index or 0) > maxIdx then
				maxIdx = c.Index or 0
			end
		end
		newIndex = maxIdx + 1
	elseif position == "into_start" and targetType == "category" then
		newParentId = targetObj.Id
		-- Or 0.5.
		newIndex = 0
	elseif position == "before" then
		newParentId = targetObj.CategoryId
		newIndex = (targetObj.Index or 0) - 0.5
	else -- "after"
		newParentId = targetObj.CategoryId
		newIndex = (targetObj.Index or 0) + 0.5
	end

	if sourceType == "category" and newParentId and IsCategoryDescendant(newParentId, sourceObj.Id) then
		self:Print("Cannot move into self.")
		return
	end

	-- Save old parent ID for cleanup
	local oldCategoryId = sourceObj.CategoryId

	-- Apply Change
	sourceObj.CategoryId = newParentId
	sourceObj.Index = newIndex

	-- Normalize Indices
	local siblings = {}
	for _, p in pairs(AngryAssign_Pages) do
		if p.CategoryId == newParentId then
			table.insert(siblings, p)
		end
	end
	for _, c in pairs(AngryAssign_Categories) do
		if c.CategoryId == newParentId then
			table.insert(siblings, c)
		end
	end

	table.sort(siblings, function(a, b)
		local ia = a.Index or 0
		local ib = b.Index or 0
		if ia == ib then
			return a.Name < b.Name
		end
		return ia < ib
	end)

	-- Check if old parent is empty and collapse it
	if oldCategoryId then
		local hasChildren = false
		for _, p in pairs(AngryAssign_Pages) do
			if p.CategoryId == oldCategoryId then
				hasChildren = true break
			end
		end
		if not hasChildren then
			for _, c in pairs(AngryAssign_Categories) do
				if c.CategoryId == oldCategoryId then
					hasChildren = true break
				end
			end
		end

		if not hasChildren then
			 local groups = AngryAssign_State.tree.groups
			 if groups then
				 local targetSuffix = "\001-"..oldCategoryId
				 local targetRoot = -oldCategoryId
				 for k, v in pairs(groups) do
					 if k == targetRoot then
						 groups[k] = nil
					 elseif type(k) == "string" and string.sub(k, -string.len(targetSuffix)) == targetSuffix then
						 groups[k] = nil
					 end
				 end
			 end
		end
	end

	self:UpdateTree()
end

function AngryAssign:UpdateTree(id)
	if not self.window then
		return
	end
	self.window.tree:SetTree( self:GetTree() )
	if id then
		self:SetSelectedId( id )
	end
end

function AngryAssign:UpdateSelected(destructive)
	if not self.window then
		return
	end
	local page = AngryAssign_Pages[ self:SelectedId() ]
	local permission = self:PermissionCheck()
	if destructive or not self.window.text.button:IsEnabled() then
		if page then
			self.window.text:SetText( page.Contents )
		else
			self.window.text:SetText("")
		end
		self.window.text.button:Disable()
	end
	if page and permission then
		-- self.window.button_revert:SetDisabled(not self.window.text.button:IsEnabled()) -- Removed Revert
		self.window.button_display:SetDisabled(self.window.text.button:IsEnabled())
		self.window.button_output:SetDisabled(self.window.text.button:IsEnabled())
		-- Always enable Restore button so users can see the menu (even if empty)
		self.window.button_restore:SetDisabled(false)
		self.window.text:SetDisabled(false)
	else
		-- self.window.button_revert:SetDisabled(true) -- Removed Revert
		self.window.button_display:SetDisabled(true)
		self.window.button_output:SetDisabled(true)
		self.window.button_restore:SetDisabled(true)
		self.window.text:SetDisabled(true)
	end
	if permission then
		self.window.button_menu:SetDisabled(false)
	else
		self.window.button_menu:SetDisabled(true)
	end
end
