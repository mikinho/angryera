-- Angry Era: modules/ui/editor.lua
-- Main editing window, tree, dialogs, bulk management, icon picker, context menus.

local _, app = ...
local AngryEra = app.AngryEra

local AceGUI = app.libs.AceGUI
local DDM = app.libs.DDM
local helpers = AngryEra.utils.helpers
local colors = AngryEra.utils.colors
local layout = AngryEra.utils.layout
local EnsureUnitShortName = helpers.EnsureUnitShortName
local IterateGroupMembers = helpers.IterateGroupMembers
local IsCategoryDescendant = helpers.IsCategoryDescendant
local selectedLastValue = helpers.selectedLastValue

local AngryEra_DropDown

-- -----------------------
-- Guild Colors        --
-- -----------------------

AngryEra.GuildColors = {}

--- Rebuilds the guild name-to-class-color cache.
-- This cache is later used for display highlighting.
function AngryEra:UpdateGuildColors()
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
                AngryEra.GuildColors[name] = color
            end
        end
    end
end

-- --------------------------
-- Window Chrome        --
-- --------------------------

local WINDOW_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

-- Makes a window read as a panel rather than a pane of glass. The stock
-- backdrop is translucent enough that whatever the window sits over shows
-- through it, so an opaque texture goes underneath and the backdrop is
-- recolored to match instead of tinting the world behind it.
local function DarkenWindow(f)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0, 0, 0, 0.95)

    if not f.SetBackdrop then
        return
    end
    f:SetBackdrop(WINDOW_BACKDROP)
    f:SetBackdropColor(0, 0, 0, 1)
end

-- --------------------------
-- Bulk Management      --
-- --------------------------

--- Opens the bulk-management UI for selecting and deleting pages/categories.
function AngryEra:ShowBulkManagement()
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

        DarkenWindow(f)

        -- Assign a global name so UISpecialFrames can find it
        local globalName = "AngryEra_BulkManage"
        _G[globalName] = f

        -- Register for Escape key closing
        local found = false
        for _, v in ipairs(UISpecialFrames) do
            if v == globalName then
                found = true
                break
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

        -- Registry for direct updates (upvalue shared by RenderCategory and all callbacks)
        local pageCheckboxes = {}

        local RenderCategory
        RenderCategory = function(cat, parentContainer, depth)
            local catPages = {}
            for _, page in pairs(AngryAssign_Pages) do
                if page.CategoryId == cat.Id then
                    table.insert(catPages, page)
                end
            end
            table.sort(catPages, function(a, b)
                return a.Name < b.Name
            end)

            local catGroup = AceGUI:Create("SimpleGroup")
            catGroup:SetLayout("List")
            catGroup:SetFullWidth(true)
            parentContainer:AddChild(catGroup)

            local prefix = string.rep("  ", depth)
            local catCheck = AceGUI:Create("CheckBox")
            catCheck:SetLabel(prefix .. "|cffffd200[" .. cat.Name .. "]|r")
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
                            allChildrenSelected = false
                            break
                        end
                    end

                    if not allChildrenSelected and #catPages > 0 then
                        -- State 1 -> 2: Select All Children
                        selectedToDelete.categories[cat.Id] = true
                        catCheck:SetValue(true)
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

            -- Recurse into subcategories
            local subCats = {}
            for _, sub in pairs(AngryAssign_Categories) do
                if sub.CategoryId == cat.Id then
                    table.insert(subCats, sub)
                end
            end
            table.sort(subCats, function(a, b)
                return a.Name < b.Name
            end)
            for _, sub in ipairs(subCats) do
                RenderCategory(sub, catGroup, depth + 1)
            end

            -- Render page children
            for _, page in ipairs(catPages) do
                local pageCheck = AceGUI:Create("CheckBox")
                pageCheck:SetLabel(prefix .. "    " .. page.Name)
                pageCheck:SetType("checkbox")
                pageCheck:SetValue(selectedToDelete.pages[page.Id])
                pageCheck:SetCallback("OnValueChanged", function(_, _, val)
                    selectedToDelete.pages[page.Id] = val or nil
                end)
                pageCheck:SetFullWidth(true)
                catGroup:AddChild(pageCheck)
                pageCheckboxes[page.Id] = pageCheck
            end
        end

        -- A. Gather orphan pages
        local orphanPages = {}
        for _, page in pairs(AngryAssign_Pages) do
            if not page.CategoryId then
                table.insert(orphanPages, page)
            end
        end
        table.sort(orphanPages, function(a, b)
            return a.Name < b.Name
        end)

        -- B. Render root categories (recursive)
        local rootCats = {}
        for _, cat in pairs(AngryAssign_Categories) do
            if not cat.CategoryId then
                table.insert(rootCats, cat)
            end
        end
        table.sort(rootCats, function(a, b)
            return a.Name < b.Name
        end)
        for _, cat in ipairs(rootCats) do
            RenderCategory(cat, scroll, 0)
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
                AngryEra:DeletePage(id)
                pCount = pCount + 1
            end
        end

        for id, _ in pairs(selectedToDelete.categories) do
            if selectedToDelete.categories[id] then
                AngryEra:DeleteCategory(id)
                cCount = cCount + 1
            end
        end

        AngryEra:Print(string.format("Deleted %d pages and %d categories.", pCount, cCount))
        frame:Hide()
        if AngryEra.window then
            AngryEra:UpdateTree()
        end
    end)
    btnGroup:AddChild(delBtn)

    -- CLOSE BUTTON (30% Width)
    local closeBtn = AceGUI:Create("Button")
    closeBtn:SetText("Close")
    closeBtn:SetRelativeWidth(0.30)
    closeBtn:SetCallback("OnClick", function()
        frame:Hide()
    end)
    btnGroup:AddChild(closeBtn)
end

-- --------------------------
-- Editing Pages Window --
-- --------------------------

function AngryEra_ToggleWindow()
    if not AngryEra.window then
        AngryEra:CreateWindow()
    end
    if AngryEra.window:IsShown() then
        AngryEra.window:Hide()
    else
        if AngryAssign_State.displayed and AngryAssign_Pages[AngryAssign_State.displayed] then
            AngryEra:SetSelectedId(AngryAssign_State.displayed)
        end
        AngryEra.window:Show()
    end
end

function AngryEra_ToggleLock()
    AngryEra:ToggleLock()
end

local function AngryEra_LoadTemplate(template, catIndex)
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
        local category = AngryEra:NewLocalCategoryRecord({
            Name = catName,
            CategoryId = nil,
            Index = catIndex,
        })
        catId = category.Id
        AngryAssign_Categories[catId] = category
        AngryEra:UpdateTree()
    else
        -- Category exists, update index if none?
        local cat = AngryAssign_Categories[catId]
        if not cat.Index and catIndex then
            cat.Index = catIndex
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
                AngryEra:CreatePage(tPage.name, tPage.content, catId, i, true)
            end
        end
    end

    AngryEra:UpdateTree()
    AngryEra:UpdateSelected()
    AngryEra:RefreshDisplayedPageAfterHierarchyMutation()
end

function AngryEra:SaveTemplate(name, catId)
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

function AngryEra:DeleteTemplate(index)
    if AngryAssign_Templates[index] then
        local name = AngryAssign_Templates[index].name
        table.remove(AngryAssign_Templates, index)
        self:Print("Deleted template: " .. name)
    end
end

local function AngryEra_SaveTemplatePopup(catId)
    local cat = AngryEra:GetCat(catId)
    if not cat then
        return
    end

    local popup_name = "AngryEra_SaveTemplate"
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
                    AngryEra:SaveTemplate(name, self.data.catId)
                end
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local editBox = parent.editBox or parent.wideEditBox or parent.EditBox
                if editBox then
                    local name = editBox:GetText()
                    AngryEra:SaveTemplate(name, parent.data.catId)
                    parent:Hide()
                end
            end,
            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
        }
    end
    StaticPopup_Show(popup_name, nil, nil, { catId = catId, defaultName = cat.Name })
end

local function AngryEra_LoadRaidMenu()
    if not AngryEra_DropDown then
        AngryEra_DropDown = CreateFrame("Frame", "AngryEraMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end

    local menu = {
        { text = "Standard Raids", isTitle = true, notCheckable = true },
    }

    if AngryEra.Templates then
        for i, template in ipairs(AngryEra.Templates) do
            table.insert(menu, {
                text = template.name,
                func = function()
                    AngryEra_LoadTemplate(template, i)
                end,
                notCheckable = true,
            })
        end
    end

    if AngryAssign_Templates and #AngryAssign_Templates > 0 then
        table.insert(menu, { text = " ", isTitle = true, notCheckable = true })
        table.insert(menu, { text = "Custom Templates", isTitle = true, notCheckable = true })

        for i, template in ipairs(AngryAssign_Templates) do
            local subMenu = {
                {
                    text = "Load",
                    func = function()
                        AngryEra_LoadTemplate(template)
                    end,
                    notCheckable = true,
                },
                {
                    text = "Delete",
                    func = function()
                        AngryEra:DeleteTemplate(i)
                    end,
                    notCheckable = true,
                },
            }
            table.insert(menu, {
                text = template.name,
                hasArrow = true,
                menuList = subMenu,
                notCheckable = true,
            })
        end
    end

    DDM.EasyMenu(menu, AngryEra_DropDown, "cursor", 0, 0, "MENU")
end

local function AngryEra_AddPage(widget, event, value)
    local popup_name = "AngryEra_AddPage"

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
                local success, err = AngryEra:CreatePage(self)
                if not success and err then
                    print(err)
                end
            end,

            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local success, err = AngryEra:CreatePage(parent)

                if success then
                    parent:Hide()
                elseif err then
                    print(err)
                end
            end,

            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
        }
    end

    StaticPopup_Show(popup_name)
end

local function AngryEra_RenamePage(pageId)
    local page = AngryEra:Get(pageId)
    if not page then
        return
    end

    -- FIX: Use a static name, do not append ID (prevents memory leak)
    local popup_name = "AngryEra_RenamePage"

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
                local p = AngryEra:Get(id)
                if p then
                    local editBox = self.editBox or self.wideEditBox or self.EditBox
                    if editBox then
                        local draft = type(AngryEra.GetSharedPageChangeDraft) == "function"
                                and AngryEra:GetSharedPageChangeDraft(id)
                            or nil
                        editBox:SetText(draft and draft.Desired.Name or p.Name)
                        editBox:HighlightText()
                    end
                end
            end,

            OnAccept = function(self)
                local id = self.data
                local success, err = AngryEra:RenamePage(id, self)
                if not success and err then
                    print(err)
                end
            end,

            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local id = parent.data
                local success, err = AngryEra:RenamePage(id, parent)

                if success then
                    parent:Hide()
                elseif err then
                    print(err)
                end
            end,

            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
        }
    end

    -- Args: Name, TextArg1 (%s), TextArg2, Data (The Page ID)
    StaticPopup_Show(popup_name, page.Name, nil, page.Id)
end

local function AngryEra_DeletePage(pageId)
    local page = AngryEra:Get(pageId)
    if not page then
        return
    end

    local popup_name = "AngryEra_DeletePage"

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
                AngryEra:DeletePage(id)
            end,
        }
    end

    -- Pass the dynamic text as arg1, and the ID as data
    StaticPopupDialogs[popup_name].text = "Are you sure you want to delete page \"%s\"?"
    StaticPopup_Show(popup_name, page.Name, nil, page.Id)
end

local function AngryEra_AddCategory(widget, event, value)
    local popup_name = "AngryEra_AddCategory"
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
                local success, err = AngryEra:CreateCategory(self)
                if not success and err then
                    print(err)
                end
            end,

            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local success, err = AngryEra:CreateCategory(parent)
                if success then
                    parent:Hide()
                elseif err then
                    print(err)
                end
            end,

            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
        }
    end
    StaticPopup_Show(popup_name)
end

local function AngryEra_RenameCategory(catId)
    local cat = AngryEra:GetCat(catId)
    if not cat then
        return
    end

    local popup_name = "AngryEra_RenameCategory"

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
                local c = AngryEra:GetCat(id)
                if c then
                    local editBox = self.editBox or self.wideEditBox or self.EditBox
                    editBox:SetText(c.Name)
                    editBox:HighlightText()
                end
            end,

            OnAccept = function(self)
                local id = self.data
                local success, err = AngryEra:RenameCategory(id, self)
                if not success and err then
                    print(err)
                end
            end,

            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local id = parent.data
                local success, err = AngryEra:RenameCategory(id, parent)

                if success then
                    parent:Hide()
                elseif err then
                    print(err)
                end
            end,

            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
        }
    end

    StaticPopup_Show(popup_name, cat.Name, nil, cat.Id)
end

local function AngryEra_DeleteCategory(catId)
    local cat = AngryEra:GetCat(catId)
    if not cat then
        return
    end

    local popup_name = "AngryEra_DeleteCategory"

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
                AngryEra:DeleteCategory(id)
            end,
            OnAlt = function(self)
                local id = self.data
                AngryEra:DeleteCategoryAndChildren(id)
            end,
        }
    end

    StaticPopupDialogs[popup_name].text = "Are you sure you want to delete category \"%s\"?"
    StaticPopup_Show(popup_name, cat.Name, nil, cat.Id)
end

local function AngryEra_AssignCategory(frame, entryId, catId)
    CloseDropDownMenus()

    AngryEra:AssignCategory(entryId, catId)
end

local function AngryEra_DisplayPage(widget, event, value)
    local id = AngryEra:SelectedId()
    AngryEra:DisplayPage(id)
end

local function AngryEra_ClearPage(widget, event, value)
    AngryEra:ClearDisplayed(true)
end
-- Expose for init.lua options table
AngryEra._AngryEra_ClearPage = AngryEra_ClearPage

local function AngryEra_TextChanged(widget, event, value)
    AngryEra.window.button_revert:SetDisabled(false)
    AngryEra.window.button_restore:SetDisabled(false)
    AngryEra.window.button_display:SetDisabled(true)
    AngryEra.window.button_output:SetDisabled(true)
end

local function AngryEra_TextEntered(widget, event, value)
    local saved, saveError = AngryEra:UpdateContents(AngryEra:SelectedId(), value)
    if not saved and saveError then
        print(saveError)
    end
end

local function AngryEra_RevertPage()
    if not AngryEra.window then
        return
    end
    AngryEra:UpdateSelected(true)
end

local function AngryEra_OutputSelectedPage()
    return AngryEra:OutputDisplayed(AngryEra:SelectedId())
end

local function AngryEra_RestorePage(widget, event, value)
    local pageId = AngryEra:SelectedId()
    if not pageId then
        return
    end
    local page = AngryAssign_Pages[pageId]
    if not page then
        return
    end

    if not AngryEra_DropDown then
        AngryEra_DropDown = CreateFrame("Frame", "AngryEraMenuFrame", UIParent, "UIDropDownMenuTemplate")
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
                    AngryEra.window.text:SetText(entry.content)
                    AngryEra.window.text.button:Enable()
                    AngryEra_TextChanged()
                end,
                notCheckable = true,
            })
        end
    end

    if #menu == 1 then
        table.insert(menu, { text = "No history available", disabled = true, notCheckable = true })
    end

    DDM.EasyMenu(menu, AngryEra_DropDown, "cursor", 0, 0, "MENU")
end

local function AngryEra_HighlightNames()
    if not AngryEra.window or not AngryEra.window.text then
        return
    end

    local text = AngryEra.window.text:GetText()
    if not text or text == "" then
        return
    end

    -- Strip existing color codes to fix broken tags or refresh highlights
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")

    local roster = {}
    if not (IsInRaid() or IsInGroup()) then
        local name = UnitName("player")
        local _, class = UnitClass("player")
        if name and class and colors.ColorTable["|c" .. class:lower()] then
            roster[name] = colors.ColorTable["|c" .. class:lower()]
        end
    else
        IterateGroupMembers(function(rawName, fullName, _, _, class)
            if class and colors.ColorTable["|c" .. class:lower()] then
                local shortName = (rawName or EnsureUnitShortName(fullName)):match("([^-]+)")
                if shortName then
                    roster[shortName] = colors.ColorTable["|c" .. class:lower()]
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

            if name and fileClass and colors.ColorTable["|c" .. fileClass:lower()] then
                name = name:match("([^-]+)") -- Strip realm
                roster[name] = colors.ColorTable["|c" .. fileClass:lower()]
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
        AngryEra.window.text:SetText(text)
        AngryEra.window.text:SetFocus()

        -- Save the highlighted text immediately
        local selectedId = AngryEra:SelectedId()
        if selectedId and selectedId > 0 then
            AngryEra:UpdateContents(selectedId, text)
        end
    end
end

local function AngryEra_CategoryMenuList(entryId, parentId)
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
            local subMenu = AngryEra_CategoryMenuList(entryId, cat.Id)
            table.insert(categories, {
                text = cat.Name,
                value = cat.Id,
                menuList = subMenu,
                hasArrow = (subMenu ~= nil),
                checked = (checkedId == cat.Id),
                func = AngryEra_AssignCategory,
                arg1 = entryId,
                arg2 = cat.Id,
            })
        end
    end

    table.sort(categories, function(a, b)
        return a.text < b.text
    end)

    if #categories > 0 then
        return categories
    end
end

local function AngryEra_EditVariables(id, type)
    local entity
    if type == "category" then
        entity = AngryAssign_Categories[id]
    else
        entity = AngryAssign_Pages[id]
    end
    if not AngryEra:CanEditEntityLocally(entity) then
        return
    end
    local vars = entity.Vars
    if type ~= "category" and AngryEra.GetSharedPageChangeDraft then
        local draft = AngryEra:GetSharedPageChangeDraft(id)
        if draft then
            vars = draft.Desired.Vars
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
    _G["AngryEra_EditVars_Window"] = frame.frame
    table.insert(UISpecialFrames, "AngryEra_EditVars_Window")

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

        local saved = true
        local saveError
        local proposed = false
        if type == "category" then
            local cat = AngryAssign_Categories[id]
            if cat and AngryEra:CanEditEntityLocally(cat) then
                cat.Vars = text
                AngryEra:CategoryUpdated(id)
            end
        else
            local page = AngryAssign_Pages[id]
            if page and AngryEra:CanEditEntityLocally(page) then
                saved, saveError, proposed = AngryEra:UpdatePageVars(id, text)
            end
        end
        if not saved then
            if saveError then
                print(saveError)
            end
            return
        end
        -- A shared-page proposal intentionally leaves the canonical page and
        -- editor draft unchanged until the leader commits a new revision.
        if proposed then
            return
        end
        frame:Hide()
        AngryEra:UpdateDisplayed()
    end)
    frame:AddChild(editBox)
    frame:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
    end)
end

--- Collects the short names of the current group, in roster order.
-- @treturn table Array of short names.
local function CollectRosterNames()
    local names = {}
    IterateGroupMembers(function(rawName, fullName)
        local shortName = (rawName or EnsureUnitShortName(fullName) or ""):match("([^-]+)")
        if shortName and shortName ~= "" then
            names[#names + 1] = shortName
        end
        return false
    end)
    return names
end

--- Prompts for one line of layout text and hands the answer back.
-- @tparam table data Prompt, optional seed Text, and an OnAccept(text) callback.
local function AngryEra_LayoutTextPopup(data)
    local popup_name = "AngryEra_LayoutText"
    if StaticPopupDialogs[popup_name] == nil then
        StaticPopupDialogs[popup_name] = {
            text = "",
            button1 = OKAY,
            button2 = CANCEL,
            hasEditBox = true,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnShow = function(self)
                local editBox = self.editBox or self.wideEditBox or self.EditBox
                if editBox then
                    editBox:SetText(self.data.Text or "")
                    editBox:HighlightText()
                end
            end,
            OnAccept = function(self)
                local editBox = self.editBox or self.wideEditBox or self.EditBox
                if editBox then
                    self.data.OnAccept(editBox:GetText())
                end
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local editBox = parent.editBox or parent.wideEditBox or parent.EditBox
                if editBox then
                    parent.data.OnAccept(editBox:GetText())
                    parent:Hide()
                end
            end,
            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
        }
    end
    StaticPopupDialogs[popup_name].text = data.Prompt
    StaticPopup_Show(popup_name, nil, nil, data)
end

--- Confirms a layout edit that throws work away before running it.
-- @tparam table data Prompt and an OnAccept() callback.
local function AngryEra_LayoutConfirmPopup(data)
    local popup_name = "AngryEra_LayoutConfirm"
    if StaticPopupDialogs[popup_name] == nil then
        StaticPopupDialogs[popup_name] = {
            text = "",
            button1 = YES,
            button2 = NO,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(self)
                self.data.OnAccept()
            end,
        }
    end
    StaticPopupDialogs[popup_name].text = data.Prompt
    StaticPopup_Show(popup_name, nil, nil, data)
end

--- Opens a dedicated editor for a page's `$LAYOUT` group layout.
-- The visual view drags members between raid subgroup boxes, free-form group
-- boxes, and the roster palette; the text view edits the same layout one group
-- per line. Save writes the layout, and Apply rearranges the actual raid.
-- @tparam number id Page id.
function AngryEra:ShowGroupLayoutEditor(id)
    local page = AngryAssign_Pages[id]
    if not page or not self:CanEditEntityLocally(page) then
        return
    end

    local roster = CollectRosterNames()
    local model = layout.Parse(layout.ExtractSource(page.Vars) or "")
    local textMode = false
    local editBox, grid, closed

    local frame = AceGUI:Create("Window")
    frame:SetTitle("Group Layout")
    frame:SetLayout("Flow")
    frame:SetWidth(470)
    frame:SetHeight(500)
    frame:EnableResize(true)
    DarkenWindow(frame.frame)
    _G["AngryEra_LayoutEditor_Window"] = frame.frame
    table.insert(UISpecialFrames, "AngryEra_LayoutEditor_Window")
    -- The palette mirrors the live raid, so someone joining or leaving while the
    -- editor sits open has to reach it. The window listens for itself because
    -- the addon's own roster handler is already bound to another method, and an
    -- AceEvent registration is per-object.
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("GROUP_ROSTER_UPDATE")
    watcher:SetScript("OnEvent", function()
        roster = CollectRosterNames()
        -- The text view's roster buttons are only a typing shortcut, and
        -- rebuilding them would throw away whatever is half-typed above them.
        if closed or not grid then
            return
        end
        grid:SetRoster(roster)
    end)

    -- A prompt outlives the window it was opened from, so closing the editor
    -- marks the views dead rather than letting a late answer touch a widget
    -- AceGUI has already recycled.
    frame:SetCallback("OnClose", function(widget)
        closed = true
        watcher:UnregisterAllEvents()
        watcher:SetScript("OnEvent", nil)
        AceGUI:Release(widget)
    end)

    -- Whichever view is showing owns the layout; the other is rebuilt from it
    -- on every switch so the two never drift apart.
    local function CurrentSource()
        if not textMode then
            return layout.Serialize(model)
        end
        local text = editBox and editBox:GetText() or ""
        return (text:gsub("[\r\n]+", ";"):gsub("%s*;%s*", ";"):gsub("^;+", ""):gsub(";+$", ""))
    end

    -- A group nobody filled is kept while editing so its box stays draggable,
    -- but dropped on save rather than persisted as an empty line.
    local function SaveLayout()
        local source = layout.Serialize(layout.Compact(layout.Parse(CurrentSource())))
        local newVars = layout.UpsertSource(page.Vars, source)
        local saved, saveError = self:UpdatePageVars(id, newVars)
        if not saved and saveError then
            print(saveError)
            return false
        end
        self:UpdateDisplayed()
        return true
    end

    local body = AceGUI:Create("ScrollFrame")
    body:SetLayout("Flow")
    body:SetFullWidth(true)
    body:SetHeight(360)

    local function BuildTextView()
        editBox = AceGUI:Create("MultiLineEditBox")
        editBox:SetLabel("Groups, one per line:  Label/N: name, A > B, *MAGE x2, group:2")
        editBox:SetNumLines(10)
        editBox:SetText((layout.Serialize(model):gsub("%s*;%s*", "\n")))
        editBox:SetFullWidth(true)
        editBox:DisableButton(false)
        editBox:SetCallback("OnEnterPressed", function()
            SaveLayout()
        end)
        body:AddChild(editBox)

        local heading = AceGUI:Create("Heading")
        heading:SetText("Roster (click to insert)")
        heading:SetFullWidth(true)
        body:AddChild(heading)

        local palette = AceGUI:Create("SimpleGroup")
        palette:SetLayout("Flow")
        palette:SetFullWidth(true)
        body:AddChild(palette)

        for _, shortName in ipairs(roster) do
            local button = AceGUI:Create("Button")
            button:SetText(shortName)
            button:SetWidth(96)
            button:SetCallback("OnClick", function()
                local inner = editBox.editBox
                local position = inner and inner:GetCursorPosition() or 0
                local text = editBox:GetText() or ""
                if position and position > 0 then
                    editBox:SetText(text:sub(1, position) .. shortName .. text:sub(position + 1))
                    inner:SetCursorPosition(position + #shortName)
                    return
                end
                editBox:SetText(text .. shortName)
            end)
            palette:AddChild(button)
        end

        if #roster == 0 then
            local hint = AceGUI:Create("Label")
            hint:SetText("Join a group to insert roster names here.")
            hint:SetFullWidth(true)
            palette:AddChild(hint)
        end
    end

    local function BuildVisualView()
        grid = AceGUI:Create("AngryLayoutGrid")
        grid:SetFullWidth(true)
        grid:SetLayoutEngine(layout)
        grid:SetRoster(roster)
        -- Every visual edit runs the same pure mutator the drag path uses and
        -- redraws from the model it returns, so typed and dragged edits cannot
        -- drift apart. An edit confirmed after the grid was rebuilt belongs to
        -- a layout that no longer exists, so it is dropped.
        local widget = grid
        local function Commit(applied, updated)
            if not applied or closed or grid ~= widget then
                return
            end
            model = updated
            widget:SetLayoutModel(model)
        end

        -- A prompt does not block the grid, so an index taken when it opened can
        -- point at something else by the time it is answered. Each one re-reads
        -- what it named and gives up if that moved.
        local function StillHolds(group, slot, expression)
            local current = model.groups[group]
            if not current then
                return false
            end
            if slot then
                return current.slots[slot] == expression
            end
            return current.name == expression
        end

        grid:SetCallback("OnLayoutDrop", function(_, drag, drop)
            Commit(layout.ApplyDrop(model, drag, drop))
        end)

        grid:SetCallback("OnSlotClick", function(_, group, slot, button)
            local target = model.groups[group]
            if not target then
                return
            end
            if button == "RightButton" then
                Commit(layout.ApplyDrop(model, { kind = "slot", group = group, slot = slot }, { kind = "remove" }))
                return
            end
            local expression = target.slots[slot]
            AngryEra_LayoutTextPopup({
                Prompt = "Slot in " .. target.name .. ":",
                Text = expression,
                OnAccept = function(text)
                    if not StillHolds(group, slot, expression) then
                        return
                    end
                    Commit(layout.SetSlot(model, group, slot, text))
                end,
            })
        end)

        -- An unused row types into its box, which is the only way to fill a
        -- layout while solo since the palette needs a live roster.
        grid:SetCallback("OnEmptyClick", function(_, group, subgroup, button)
            if button ~= "LeftButton" then
                return
            end
            local drop = group and { kind = "group", group = group } or { kind = "subgroup", subgroup = subgroup }
            AngryEra_LayoutTextPopup({
                Prompt = "Add a slot:",
                OnAccept = function(text)
                    Commit(layout.ApplyDrop(model, { kind = "text", text = text }, drop))
                end,
            })
        end)

        grid:SetCallback("OnGroupClick", function(_, group, subgroup, button)
            local existing = group and model.groups[group]
            local label = existing and existing.name
            if button == "RightButton" then
                if not existing then
                    return
                end
                AngryEra_LayoutConfirmPopup({
                    Prompt = ("Remove the group %s?"):format(label),
                    OnAccept = function()
                        if not StillHolds(group, nil, label) then
                            return
                        end
                        Commit(layout.RemoveGroup(model, group))
                    end,
                })
                return
            end
            AngryEra_LayoutTextPopup({
                Prompt = "Group name:",
                Text = label,
                OnAccept = function(text)
                    if not existing then
                        Commit(layout.AddGroup(model, text, subgroup))
                        return
                    end
                    if not StillHolds(group, nil, label) then
                        return
                    end
                    Commit(layout.SetGroupName(model, group, text))
                end,
            })
        end)

        body:AddChild(grid)
        grid:SetLayoutModel(model)
    end

    local function BuildBody()
        body:ReleaseChildren()
        editBox, grid = nil, nil
        if textMode then
            BuildTextView()
            return
        end
        BuildVisualView()
    end

    local toggle = AceGUI:Create("CheckBox")
    toggle:SetLabel("Edit as text")
    toggle:SetValue(false)
    toggle:SetWidth(140)
    toggle:SetCallback("OnValueChanged", function(_, _, value)
        model = layout.Parse(CurrentSource())
        textMode = value and true or false
        BuildBody()
    end)
    frame:AddChild(toggle)

    -- Reads the view back first so a group added from the text view lands after
    -- whatever is already typed there rather than replacing it.
    local newGroup = AceGUI:Create("Button")
    newGroup:SetText("New Group")
    newGroup:SetWidth(120)
    newGroup:SetCallback("OnClick", function()
        AngryEra_LayoutTextPopup({
            Prompt = "Group name:",
            OnAccept = function(text)
                if closed then
                    return
                end
                model = layout.Parse(CurrentSource())
                local added, updated = layout.AddGroup(model, text)
                if not added then
                    return
                end
                model = updated
                BuildBody()
            end,
        })
    end)
    frame:AddChild(newGroup)

    frame:AddChild(body)
    BuildBody()

    local saveButton = AceGUI:Create("Button")
    saveButton:SetText("Save")
    saveButton:SetWidth(120)
    saveButton:SetCallback("OnClick", function()
        SaveLayout()
    end)
    frame:AddChild(saveButton)

    local applyButton = AceGUI:Create("Button")
    applyButton:SetText("Apply to Raid")
    applyButton:SetWidth(150)
    applyButton:SetCallback("OnClick", function()
        if not SaveLayout() then
            return
        end
        local applied, result = self:ApplyGroupLayoutToRaid()
        if applied then
            self:Print(("Rearranged the raid to the layout (%d move%s)."):format(result, result == 1 and "" or "s"))
        else
            self:Print("Could not apply the layout: " .. tostring(result))
        end
    end)
    frame:AddChild(applyButton)
end

-- ── Context Menus and Tree ──────────────────────────────────────────────────

local PagesDropDownList

-- Entries are addressed by label rather than position so adding one to the menu
-- above cannot silently renumber the wiring below it. Index 1 holds the page
-- name and is skipped, since a page could be named after an entry.
local function PageMenuEntry(text)
    for index = 2, #PagesDropDownList do
        local item = PagesDropDownList[index]
        if item.text == text then
            return item
        end
    end
end

function AngryEra_PageMenu(pageId)
    local page = AngryAssign_Pages[pageId]
    if not page then
        return
    end

    if not PagesDropDownList then
        PagesDropDownList = {
            { notCheckable = true, isTitle = true },
            {
                text = "Rename",
                notCheckable = true,
                func = function(_, clickedPageId)
                    AngryEra_RenamePage(clickedPageId)
                end,
            },
            {
                text = "Delete",
                notCheckable = true,
                func = function(_, clickedPageId)
                    AngryEra_DeletePage(clickedPageId)
                end,
            },
            {
                text = "Edit Variables",
                notCheckable = true,
                func = function(_, clickedPageId)
                    AngryEra_EditVariables(clickedPageId, "page")
                end,
            },
            {
                text = "Edit Group Layout",
                notCheckable = true,
                func = function(_, clickedPageId)
                    AngryEra:ShowGroupLayoutEditor(clickedPageId)
                end,
            },
            {
                text = "Export",
                notCheckable = true,
                hasArrow = true,
                menuList = {
                    {
                        text = "Encoded AA",
                        notCheckable = true,
                        func = function(frame, id)
                            AngryEra:Export(id, "page", "Encoded AA")
                        end,
                    },
                    {
                        text = "JSON",
                        notCheckable = true,
                        func = function(frame, id)
                            AngryEra:Export(id, "page", "JSON")
                        end,
                    },
                    {
                        text = "Markdown",
                        notCheckable = true,
                        func = function(frame, id)
                            AngryEra:Export(id, "page", "Markdown")
                        end,
                    },
                    {
                        text = "Output",
                        notCheckable = true,
                        func = function(frame, id)
                            AngryEra:Export(id, "page", "Output")
                        end,
                    },
                },
            },
            { text = "Category", notCheckable = true, hasArrow = true },
        }
    end

    local permission = AngryEra:CanEditEntityLocally(page)

    PagesDropDownList[1].text = page.Name
    for index = 2, #PagesDropDownList do
        PagesDropDownList[index].arg1 = pageId
    end

    PageMenuEntry("Rename").disabled = not permission
    PageMenuEntry("Edit Variables").disabled = not permission
    PageMenuEntry("Edit Group Layout").disabled = not permission

    for _, item in ipairs(PageMenuEntry("Export").menuList) do
        item.arg1 = pageId
    end

    local categories = AngryEra_CategoryMenuList(pageId)
    local category = PageMenuEntry("Category")
    category.menuList = categories or {}
    category.disabled = categories == nil

    return PagesDropDownList
end

local CategoriesDropDownList
local function AngryEra_CategoryMenu(catId)
    local cat = AngryAssign_Categories[catId]
    if not cat then
        return
    end

    if not CategoriesDropDownList then
        CategoriesDropDownList = {
            { notCheckable = true, isTitle = true },
            {
                text = "Rename",
                notCheckable = true,
                func = function(_, clickedCategoryId)
                    AngryEra_RenameCategory(clickedCategoryId)
                end,
            },
            {
                text = "Save as Template",
                notCheckable = true,
                func = function(_, clickedCategoryId)
                    AngryEra_SaveTemplatePopup(clickedCategoryId)
                end,
            },
            {
                text = "Delete",
                notCheckable = true,
                func = function(_, clickedCategoryId)
                    AngryEra_DeleteCategory(clickedCategoryId)
                end,
            },
            {
                text = "Edit Variables",
                notCheckable = true,
                func = function(_, clickedCategoryId)
                    AngryEra_EditVariables(clickedCategoryId, "category")
                end,
            },
            {
                text = "Export",
                notCheckable = true,
                hasArrow = true,
                menuList = {
                    {
                        text = "Encoded AA",
                        notCheckable = true,
                        func = function(frame, id)
                            AngryEra:Export(id, "category", "Encoded AA")
                        end,
                    },
                    {
                        text = "JSON",
                        notCheckable = true,
                        func = function(frame, id)
                            AngryEra:Export(id, "category", "JSON")
                        end,
                    },
                    {
                        text = "Markdown",
                        notCheckable = true,
                        func = function(frame, id)
                            AngryEra:Export(id, "category", "Markdown")
                        end,
                    },
                    {
                        text = "Output",
                        notCheckable = true,
                        func = function(frame, id)
                            AngryEra:Export(id, "category", "Output")
                        end,
                    },
                },
            },
            { text = "Category", notCheckable = true, hasArrow = true },
        }
    end
    CategoriesDropDownList[1].text = cat.Name
    CategoriesDropDownList[2].arg1 = catId
    CategoriesDropDownList[2].disabled = not AngryEra:CanEditEntityLocally(cat)
    CategoriesDropDownList[3].arg1 = catId
    CategoriesDropDownList[4].arg1 = catId
    CategoriesDropDownList[5].arg1 = catId
    CategoriesDropDownList[5].disabled = not AngryEra:CanEditEntityLocally(cat)
    CategoriesDropDownList[6].arg1 = catId
    for _, item in ipairs(CategoriesDropDownList[6].menuList) do
        item.arg1 = catId
    end
    CategoriesDropDownList[7].arg1 = catId

    local categories = AngryEra_CategoryMenuList(-catId)
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
local function AngryEra_TreeClick(widget, event, value, selected, button)
    HideDropDownMenu(1)
    local selectedId = selectedLastValue(value)

    if button == "LeftButton" and selectedId > 0 then
        if clickValue == value and (GetTime() - clickTime) < 0.3 then
            AngryEra_DisplayPage()
            clickValue = nil
            return false
        end
        clickTime = GetTime()
        clickValue = value
    end
    if selectedId < 0 then
        if button == "RightButton" then
            if not AngryEra_DropDown then
                AngryEra_DropDown = CreateFrame("Frame", "AngryEraMenuFrame", UIParent, "UIDropDownMenuTemplate")
            end
            DDM.EasyMenu(AngryEra_CategoryMenu(-selectedId), AngryEra_DropDown, "cursor", 0, 0, "MENU")
        else
            local status = (widget.status or widget.localstatus).groups
            status[value] = not status[value]
            widget:RefreshTree()
        end
        return false
    else
        if button == "RightButton" then
            if not AngryEra_DropDown then
                AngryEra_DropDown = CreateFrame("Frame", "AngryEraMenuFrame", UIParent, "UIDropDownMenuTemplate")
            end
            DDM.EasyMenu(AngryEra_PageMenu(selectedId), AngryEra_DropDown, "cursor", 0, 0, "MENU")

            return false
        end
    end
end

local function AngryEra_TreeMenuClick(widget, event, uniquevalue)
    -- uniquevalue might be concatenated string "parent\001child".
    -- But AngryTreeGroup fires button.uniquevalue.
    -- Wait, selectedLastValue(value) parses it.
    local selectedId = selectedLastValue(uniquevalue)

    if not AngryEra_DropDown then
        AngryEra_DropDown = CreateFrame("Frame", "AngryEraMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end

    if selectedId < 0 then
        -- Category
        DDM.EasyMenu(AngryEra_CategoryMenu(-selectedId), AngryEra_DropDown, "cursor", 0, 0, "MENU")
    else
        -- Page
        DDM.EasyMenu(AngryEra_PageMenu(selectedId), AngryEra_DropDown, "cursor", 0, 0, "MENU")
    end
end

-- ── Main Menu and Window ────────────────────────────────────────────────────

local function AngryEra_MainMenu(frame)
    if not AngryEra_DropDown then
        AngryEra_DropDown = CreateFrame("Frame", "AngryEraMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end

    local menu = {
        { text = "Add Page", func = AngryEra_AddPage, notCheckable = true },
        { text = "Add Category", func = AngryEra_AddCategory, notCheckable = true },
        { text = "Load Raid Template", func = AngryEra_LoadRaidMenu, notCheckable = true },
        { text = " ", isTitle = true, notCheckable = true },
        {
            text = "Import",
            hasArrow = true,
            notCheckable = true,
            menuList = {
                {
                    text = "Encoded AA",
                    func = function()
                        AngryEra:ShowImportWindow()
                    end,
                    notCheckable = true,
                },
                {
                    text = "JSON",
                    func = function()
                        AngryEra._AngryEra_ImportPage()
                    end,
                    notCheckable = true,
                },
                {
                    text = "Markdown",
                    func = function()
                        AngryEra._AngryEra_ImportPage()
                    end,
                    notCheckable = true,
                },
            },
        },
        { text = " ", isTitle = true, notCheckable = true },
        {
            text = "Manage Pages",
            func = function()
                AngryEra:ShowBulkManagement()
            end,
            notCheckable = true,
        },
        { text = "Clear Page", func = AngryEra_ClearPage, notCheckable = true },
    }
    DDM.EasyMenu(menu, AngryEra_DropDown, "cursor", 0, 0, "MENU")
end

local AngryEra_Title = AngryEra.Title

function AngryEra:CreateWindow()
    local window = AceGUI:Create("Frame")
    window:SetTitle(AngryEra_Title)
    window:SetStatusText("")
    window:SetLayout("Flow")
    if AngryEra:GetConfig("scale") then
        window.frame:SetScale(AngryEra:GetConfig("scale"))
    end
    window:SetStatusTable(AngryAssign_State.window)
    if window.frame:GetWidth() < 780 then
        window:SetWidth(780)
    end
    window:Hide()
    AngryEra.window = window

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

    AngryEra_Window = window.frame
    if window.frame.SetResizeBounds then -- WoW 10.0
        window.frame:SetResizeBounds(780, 300)
    else
        window.frame:SetMinResize(780, 300)
    end
    window.frame:SetFrameStrata("HIGH")
    window.frame:SetFrameLevel(1)
    window.frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "AngryEra_Window")

    local header = AceGUI:Create("SimpleGroup")
    header:SetLayout("Flow")
    header:SetFullWidth(true)
    window:AddChild(header)

    local searchBox = AceGUI:Create("EditBox")
    searchBox:DisableButton(true)
    searchBox:SetWidth(175)
    searchBox:SetCallback("OnTextChanged", function(_, _, v)
        if AngryEra.window.tree then
            AngryEra.window.tree:SetSearchKeyword(v)
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
    tree:SetTree(self:GetTree())
    tree:SelectByValue(1)
    tree:SetStatusTable(AngryAssign_State.tree)
    tree:SetFullWidth(true)
    tree:SetFullHeight(true)
    tree:SetLayout("Flow")
    tree:SetCallback("OnGroupSelected", function(widget, event, value)
        AngryEra:UpdateSelected(true)
    end)
    tree:SetCallback("OnTreeDragDrop", function(widget, event, source, target, position)
        AngryEra:MoveItem(source, target, position)
    end)
    tree:SetCallback("OnClick", AngryEra_TreeClick)
    tree:SetCallback("OnButtonMenu", AngryEra_TreeMenuClick)
    window:AddChild(tree)
    window.tree = tree

    tree.treeframe:HookScript("OnSizeChanged", function(frame, width)
        if AngryEra.window and AngryEra.window.searchBox then
            AngryEra.window.searchBox:SetWidth(width)
        end
    end)

    -- Enable delete key for tree
    tree.treeframe:EnableKeyboard(true)
    tree.treeframe:SetPropagateKeyboardInput(true)
    tree.treeframe:SetScript("OnKeyDown", function(treeFrame, key)
        if key == "DELETE" then
            local selectedId = AngryEra:SelectedId()
            if selectedId and selectedId > 0 then
                AngryEra_DeletePage(selectedId)
                treeFrame:SetPropagateKeyboardInput(false)
            end
        end
    end)

    local text = AceGUI:Create("MultiLineEditBox")
    text:SetLabel(nil)
    text:SetFullWidth(true)
    text:SetFullHeight(true)
    text:SetCallback("OnTextChanged", AngryEra_TextChanged)
    text:SetCallback("OnEnterPressed", AngryEra_TextEntered)
    tree:AddChild(text)
    window.text = text
    text.button:SetText("Save")
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
    button_display:SetCallback("OnClick", AngryEra_DisplayPage)
    tree:AddChild(button_display)
    window.button_display = button_display

    window.button_display = button_display

    local button_revert = AceGUI:Create("Button")
    button_revert:SetText("Revert")
    button_revert:SetWidth(70)
    button_revert:SetHeight(22)
    button_revert:ClearAllPoints()
    button_revert:SetPoint("BOTTOMLEFT", text.frame, "BOTTOMLEFT", 100, 4)
    button_revert:SetCallback("OnClick", AngryEra_RevertPage)
    tree:AddChild(button_revert)
    window.button_revert = button_revert

    local button_restore = AceGUI:Create("Button")
    button_restore:SetText("Restore")
    button_restore:SetWidth(80)
    button_restore:SetHeight(22)
    button_restore:ClearAllPoints()
    button_restore:SetPoint("LEFT", button_revert.frame, "RIGHT", 6, 0)
    button_restore:SetCallback("OnClick", AngryEra_RestorePage)
    tree:AddChild(button_restore)
    window.button_restore = button_restore

    -- Right-aligned group (Output <- Highlight <- Send)

    local button_high = AceGUI:Create("Button")
    button_high:SetText("Highlight")
    button_high:SetWidth(90)
    button_high:SetHeight(22)
    button_high:ClearAllPoints()
    button_high:SetPoint("RIGHT", button_display.frame, "LEFT", -6, 0)
    button_high:SetCallback("OnClick", AngryEra_HighlightNames)
    tree:AddChild(button_high)
    window.button_high = button_high

    local button_output = AceGUI:Create("Button")
    button_output:SetText("Output")
    button_output:SetWidth(80)
    button_output:SetHeight(22)
    button_output:ClearAllPoints()
    button_output:SetPoint("RIGHT", button_high.frame, "LEFT", -6, 0)
    button_output:SetCallback("OnClick", AngryEra_OutputSelectedPage)
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
    button_menu:SetCallback("OnClick", AngryEra_MainMenu)
    window:AddChild(button_menu)
    window.button_menu = button_menu

    self:UpdateSelected(true)
    self:UpdateMedia()

    --self:CreateIconPicker()
end

local function AngryEra_IconPicker_Clicked(widget, event)
    local icon

    if widget:GetUserData("name") then
        icon = widget:GetUserData("name")
    else
        icon = "{icon " .. strmatch(widget.image:GetTexture():lower(), "^interface\\icons\\([-_%w]+)$") .. "}"
    end

    local position = AngryEra.window.text.editBox:GetCursorPosition()
    if position > 0 then
        local text = AngryEra.window.text:GetText()
        AngryEra.window.text:SetText(
            strsub(text, 1, position)
                .. icon
                .. strsub(text, position + 1, AngryEra.window.text.editBox:GetNumLetters())
        )
        AngryEra.window.text.editBox:SetCursorPosition(position, string.len(text))
    else
        AngryEra.window.text:SetText(AngryEra.window.text:GetText() .. icon)
    end

    AngryEra.window.text.button:Enable()
    AngryEra_TextChanged()
end

local iconCache = nil
local function AngryEra_IconPicker_TextChanged(widget, event, value)
    AngryEra.iconpicker_scroll:ReleaseChildren()

    local names = {}

    local spellID = strmatch(value, "|Hspell:(%d+)|")
    local itemID = strmatch(value, "|Hitem:(%d+):")

    if spellID then
        local path = helpers.GetSpellTexture(tonumber(spellID))
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
                tinsert(names, "Interface\\Icons\\" .. path)
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
            icon:SetCallback("OnClick", AngryEra_IconPicker_Clicked)
            AngryEra.iconpicker_scroll:AddChild(icon)
        end
    end
end

function AngryEra:CreateIconButton(name, texture)
    local icon = AceGUI:Create("Icon")
    icon:SetImage(texture)
    icon:SetImageSize(20, 20)
    icon:SetWidth(21)
    icon:SetHeight(24)
    icon:SetUserData("name", name)
    icon:SetCallback("OnClick", AngryEra_IconPicker_Clicked)
    return icon
end

function AngryEra:CreateIconPicker()
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
        group:AddChild(
            self:CreateIconButton("{rt" .. i .. "}", "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. i)
        )
    end
    group:AddChild(self:CreateIconButton("{bl}", "Interface\\Icons\\SPELL_Nature_Bloodlust"))
    group:AddChild(self:CreateIconButton("{hs}", "Interface\\Icons\\INV_Stone_04"))
    window:AddChild(group)

    local heading = AceGUI:Create("Heading")
    heading:SetFullWidth(true)
    window:AddChild(heading)

    local text = AceGUI:Create("EditBox")
    text:SetFullWidth(true)
    text:DisableButton(true)
    text:SetCallback("OnTextChanged", AngryEra_IconPicker_TextChanged)
    window:AddChild(text)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("Flow")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    window:AddChild(scroll)
    self.iconpicker_scroll = scroll
end

function AngryEra:SelectedUpdated(sender)
    if self.window and self.window.text.button:IsEnabled() then
        local popup_name = "AngryEra_PageUpdated"
        if StaticPopupDialogs[popup_name] == nil then
            StaticPopupDialogs[popup_name] = {
                button1 = OKAY,
                whileDead = true,
                text = "",
                hideOnEscape = true,
                preferredIndex = 3,
            }
        end
        StaticPopupDialogs[popup_name].text = "The page you are editing has been updated by "
            .. sender
            .. ".\n\nYou can view this update by reverting your changes."
        StaticPopup_Show(popup_name)
        return true
    else
        return false
    end
end

-- ── Tree building ───────────────────────────────────────────────────────────

local GetTree_Sort = helpers.CompareIndexedEntries

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
            table.insert(tree, {
                value = -cat.Id,
                text = name,
                index = cat.Index,
                children = GetTree_InsertChildren(cat.Id, displayedPages),
            })
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

function AngryEra:GetTree()
    local tree = {}
    local displayedPages = {}

    for _, cat in pairs(AngryAssign_Categories) do
        if not cat.CategoryId then
            local name = cat.Name
            if cat.Vars and cat.Vars ~= "{}" and cat.Vars ~= "" then
                name = name .. " |cffaaaaaa‡|r"
            end
            table.insert(tree, {
                value = -cat.Id,
                text = name,
                index = cat.Index,
                children = GetTree_InsertChildren(cat.Id, displayedPages),
            })
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

function AngryEra:MoveItem(sourceValue, targetValue, position)
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
                hasChildren = true
                break
            end
        end
        if not hasChildren then
            for _, c in pairs(AngryAssign_Categories) do
                if c.CategoryId == oldCategoryId then
                    hasChildren = true
                    break
                end
            end
        end

        if not hasChildren then
            local groups = AngryAssign_State.tree.groups
            if groups then
                local targetSuffix = "\001-" .. oldCategoryId
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
    self:RefreshDisplayedPageAfterHierarchyMutation()
end

function AngryEra:UpdateTree(id)
    if not self.window then
        return
    end
    self.window.tree:SetTree(self:GetTree())
    if id then
        self:SetSelectedId(id)
    end
end

function AngryEra:UpdateSelected(destructive)
    if destructive then
        self:ClearSyncDraftConflict()
        if type(self.ClearSharedPageChangeDraft) == "function" then
            self:ClearSharedPageChangeDraft()
        end
    end
    if not self.window then
        return
    end
    local page = AngryAssign_Pages[self:SelectedId()]
    local sharedDraft = page
            and type(self.GetSharedPageChangeDraft) == "function"
            and self:GetSharedPageChangeDraft(page.Id)
        or nil
    local canEdit = self:CanEditEntityLocally(page)
    local canDisplay = self:CanLocalPlayerPublish("display")
    local canOutput = self:CanLocalPlayerOutput()
    if destructive or not self.window.text.button:IsEnabled() then
        if page then
            self.window.text:SetText(sharedDraft and sharedDraft.Desired.Contents or page.Contents)
        else
            self.window.text:SetText("")
        end
        self.window.text.button:Disable()
    end
    if page and canEdit then
        self.window.button_revert:SetDisabled(not self.window.text.button:IsEnabled())
        self.window.button_display:SetDisabled(self.window.text.button:IsEnabled() or not canDisplay)
        self.window.button_output:SetDisabled(self.window.text.button:IsEnabled() or not canOutput)
        -- Always enable Restore button so users can see the menu (even if empty)
        self.window.button_restore:SetDisabled(false)
        self.window.text:SetDisabled(false)
    else
        self.window.button_revert:SetDisabled(true)
        self.window.button_display:SetDisabled(true)
        self.window.button_output:SetDisabled(true)
        self.window.button_restore:SetDisabled(true)
        self.window.text:SetDisabled(true)
    end
    self.window.button_menu:SetDisabled(false)
end
