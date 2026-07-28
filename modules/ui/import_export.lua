-- -------------------------------------------------------------------------------
-- Angry Era: modules/ui/import_export.lua
--
-- Import/export windows, confirmation dialogs, template management UI.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local AceGUI = app.libs.AceGUI
local json = AngryEra.utils.json
local serialization = AngryEra.utils.serialization
local CompareIndexedEntries = AngryEra.utils.helpers.CompareIndexedEntries

local trackedWindowNames = {
    _encodedExportWindow = "AngryEra_ExportWindow",
    _encodedImportWindow = "AngryEra_ImportWindow",
    _legacyImportWindow = "AngryEra_LegacyImportWindow",
    _generalExportWindow = "AngryEra_GeneralExportWindow",
}

local function RemoveSpecialFrame(name, frame)
    if type(UISpecialFrames) == "table" then
        for index = #UISpecialFrames, 1, -1 do
            if UISpecialFrames[index] == name then
                table.remove(UISpecialFrames, index)
            end
        end
    end
    if frame == nil or rawget(_G, name) == frame then
        rawset(_G, name, nil)
    end
end

local function ReleaseTrackedWindow(owner, field, widget)
    if not widget or widget._angryEraWindowReleased == true then
        return false
    end
    widget._angryEraWindowReleased = true
    if owner[field] == widget then
        owner[field] = nil
    end
    local name = trackedWindowNames[field]
    RemoveSpecialFrame(name, widget.frame)
    AceGUI:Release(widget)
    return true
end

local function CloseTrackedWindow(owner, field)
    return ReleaseTrackedWindow(owner, field, owner[field])
end

local function TrackWindow(owner, field, widget)
    CloseTrackedWindow(owner, field)
    local name = trackedWindowNames[field]
    widget._angryEraWindowReleased = false
    owner[field] = widget
    RemoveSpecialFrame(name)
    rawset(_G, name, widget.frame)
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, name)
    end
    widget:SetCallback("OnClose", function(closed)
        ReleaseTrackedWindow(owner, field, closed)
    end)
end

--- Closes import/export windows and removes their Escape registrations.
function AngryEra:CloseImportExportWindows()
    local closed = false
    for field in pairs(trackedWindowNames) do
        closed = CloseTrackedWindow(self, field) or closed
    end
    return closed
end

-- ── Export / Import (Encoded AA) ────────────────────────────────────────────

--- Builds recursive export payload data for a category.
-- Delegates to serialization module.
function AngryEra:GetCategoryExportData(catId, options)
    return serialization.GetCategoryExportData(self, catId, options)
end

function AngryEra:ShowExportWindow(exportString, pageName)
    local frame = AceGUI:Create("Window")
    frame:SetTitle("Export: " .. pageName)
    frame:SetLayout("Flow")
    frame:SetWidth(520)
    frame:SetHeight(220)
    frame:EnableResize(false)
    TrackWindow(self, "_encodedExportWindow", frame)

    local editBox = AceGUI:Create("MultiLineEditBox")
    editBox:SetLabel(nil)
    editBox:SetFullWidth(true)
    editBox:SetFullHeight(true)
    editBox:DisableButton(true)
    editBox:SetText(exportString)
    frame:AddChild(editBox)

    -- Pre-select all text so user can Ctrl+C immediately
    C_Timer.After(0, function()
        if self._encodedExportWindow == frame and frame._angryEraWindowReleased ~= true and editBox.editBox then
            editBox.editBox:SetFocus()
            editBox.editBox:HighlightText()
        end
    end)
end

--- Parses an encoded `AA:Page` or `AA:Category` payload.
-- Delegates to serialization module.
function AngryEra:ParseImportString(str)
    return serialization.ParseImportString(str)
end

local function ResolveImportOptions(data, options)
    -- A content-only payload cannot be promoted back to a full import. An
    -- absent marker is a legacy complete export.
    return {
        includeVariables = (type(options) ~= "table" or options.includeVariables ~= false)
            and data.VariablesIncluded ~= false,
    }
end

local function VariableImportSummary(self, data, options, existing, category)
    local resolved = ResolveImportOptions(data, options)
    if resolved.includeVariables then
        return "Variables and metadata will be imported."
    end
    local entityName = category and "category" or "page"
    if not existing then
        return "The new " .. entityName .. " will be created without variables or metadata."
    end
    local editable = type(self.CanEditEntityLocally) == "function" and self:CanEditEntityLocally(existing) == true
    if not editable then
        return "The matching "
            .. entityName
            .. " is read-only, so either choice creates a new local "
            .. entityName
            .. " without variables or metadata."
    end
    if category then
        return "Replace keeps this category's variables and metadata, but recreated descendants receive none. "
            .. "Import as New creates the imported hierarchy without them."
    end
    return "Replace keeps this page's variables and metadata. Import as New creates a page without them."
end

local function NewImportRequest(data, options)
    return {
        Payload = data,
        Options = ResolveImportOptions(data, options),
    }
end

--- Shows import confirmation/overwrite UI for a validated page payload.
-- @tparam table data Page payload.
-- @tparam[opt] table options Import options.
function AngryEra:ConfirmImportPage(data, options)
    local existingId = self:GetEntityByName(data.Name, "Page")
    local existing = existingId and AngryAssign_Pages[existingId] or nil
    local preview = data.Contents:sub(1, 120)
    if #data.Contents > 120 then
        preview = preview .. "…"
    end
    local request = NewImportRequest(data, options)
    local variableSummary = VariableImportSummary(self, data, options, existing, false)

    if existingId then
        StaticPopupDialogs["AngryEra_ImportConflictPage"] = {
            text = string.format(
                "A page named \"%s\" already exists. What would you like to do?\n\n%s\n\n%s",
                data.Name,
                preview,
                variableSummary
            ),
            button1 = "Replace",
            button2 = "Import as New",
            button3 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(popup)
                AngryEra:DoImportPage(popup.data.Payload, nil, existingId, nil, popup.data.Options)
            end,
            OnCancel = function(popup, _, reason)
                if reason == "clicked" then
                    local newData = {
                        Name = popup.data.Payload.Name,
                        Contents = popup.data.Payload.Contents,
                        Vars = popup.data.Payload.Vars,
                        VariablesIncluded = popup.data.Payload.VariablesIncluded,
                        Index = popup.data.Payload.Index,
                    }
                    newData.Name = AngryEra:GetUniqueEntityName(newData.Name, "Page")
                    AngryEra:DoImportPage(newData, nil, nil, nil, popup.data.Options)
                end
            end,
        }
        StaticPopup_Show("AngryEra_ImportConflictPage", nil, nil, request)
    else
        StaticPopupDialogs["AngryEra_ImportConfirmPage"] = {
            text = string.format("Import page \"%s\"?\n\n%s\n\n%s", data.Name, preview, variableSummary),
            button1 = "Import",
            button2 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(popup)
                AngryEra:DoImportPage(popup.data.Payload, nil, nil, nil, popup.data.Options)
            end,
        }
        StaticPopup_Show("AngryEra_ImportConfirmPage", nil, nil, request)
    end
end

local function IsRemoteSynchronizedEntity(self, entity)
    if type(entity) ~= "table" or type(entity.SyncId) ~= "string" then
        return false
    end
    if type(self.IsLocallyOwned) ~= "function" then
        return true
    end
    local checked, locallyOwned = pcall(self.IsLocallyOwned, self, entity)
    return not checked or locallyOwned ~= true
end

local function ApplyImportedPageFields(self, id, data, options)
    local proposed = false
    local saved
    local result
    local fieldProposed

    saved, result, fieldProposed = self:UpdateContents(id, data.Contents or "")
    if saved ~= true then
        return false, result, fieldProposed == true
    end
    proposed = proposed or fieldProposed == true

    if options.includeVariables then
        saved, result, fieldProposed = self:UpdatePageVars(id, data.Vars or "")
        if saved ~= true then
            return false, result, proposed or fieldProposed == true
        end
        proposed = proposed or fieldProposed == true
    end

    saved, result, fieldProposed = self:RenamePage(id, data.Name)
    if saved ~= true then
        return false, result, proposed or fieldProposed == true
    end
    return true, result, proposed or fieldProposed == true
end

--- Applies imported contents and private order without mutating canonical state
-- after UpdateContents routed the edit through CHANGE_PROPOSE.
-- @tparam number id Existing page id.
-- @tparam string contents Imported page contents.
-- @tparam number index Receiver-private sibling order.
-- @treturn boolean updated
-- @treturn string|nil resultOrError
-- @treturn boolean proposed
function AngryEra:ApplyImportedPageUpdate(id, contents, index)
    local updated, result, proposed = self:UpdateContents(id, contents)
    if updated ~= true or proposed == true then
        return updated == true, result, proposed == true
    end

    local page = type(AngryAssign_Pages) == "table" and AngryAssign_Pages[id] or nil
    if type(page) ~= "table" then
        return false, "Page not found.", false
    end
    page.Index = index
    self:PageUpdated(id)
    return true, result, false
end

--- Imports (or overwrites) a single page payload.
-- Remote synchronized pages use the canonical change-proposal model path;
-- their private placement is never overwritten as a side effect.
-- @tparam table data Page payload.
-- @tparam[opt] number parentId Optional parent category id.
-- @tparam[opt] number overwriteId Existing page id to overwrite.
-- @tparam[opt=false] boolean suppressTreeUpdate Skip immediate tree refresh when `true`.
-- @tparam[opt] table options Import options.
-- @treturn number Imported page id.
function AngryEra:DoImportPage(data, parentId, overwriteId, suppressTreeUpdate, options)
    options = ResolveImportOptions(data, options)
    local existing = overwriteId and AngryAssign_Pages[overwriteId]
    local importedName = data.Name
    if existing and not self:CanEditEntityLocally(existing) then
        overwriteId = nil
        existing = nil
        importedName = self:GetUniqueEntityName(importedName, "Page")
    end
    if existing and IsRemoteSynchronizedEntity(self, existing) then
        local applied, applyError, proposed = ApplyImportedPageFields(self, overwriteId, {
            Name = importedName,
            Contents = data.Contents,
            Vars = data.Vars,
        }, options)
        if not applied then
            return nil, applyError, proposed
        end
        return overwriteId, applyError, proposed
    end

    local importedVariables
    if options.includeVariables then
        importedVariables = data.Vars or ""
    elseif existing then
        importedVariables = type(existing.Vars) == "string" and existing.Vars or ""
    else
        importedVariables = ""
    end
    local fields = {
        Updated = time(),
        UpdateId = self:Hash(importedName, data.Contents, importedVariables),
        Name = importedName,
        Contents = data.Contents,
        Vars = importedVariables,
        CategoryId = (existing and existing.CategoryId) or parentId,
        Index = (existing and existing.Index) or data.Index,
    }
    local page
    if overwriteId then
        page = self:ReplacePageRecord(overwriteId, fields)
    else
        page = self:NewLocalPageRecord(fields)
    end
    local id = page.Id
    AngryAssign_Pages[id] = page
    if not suppressTreeUpdate then
        self:UpdateTree(id)
        self:RefreshDisplayedPageAfterHierarchyMutation()
    end
    return id
end

--- Shows import confirmation/overwrite UI for a validated category payload.
-- @tparam table data Category payload.
-- @tparam[opt] table options Import options.
function AngryEra:ConfirmImportCategory(data, options)
    local existingId = self:GetEntityByName(data.Name, "Category")
    local existing = existingId and AngryAssign_Categories[existingId] or nil
    local pageCount = 0
    local catCount = 0
    local function countItems(d)
        for _, child in ipairs(d.Children or {}) do
            if child.Type == "Category" then
                catCount = catCount + 1
                countItems(child)
            else
                pageCount = pageCount + 1
            end
        end
    end
    countItems(data)
    local request = NewImportRequest(data, options)
    local variableSummary = VariableImportSummary(self, data, options, existing, true)

    if existingId then
        StaticPopupDialogs["AngryEra_ImportConflictCat"] = {
            text = string.format(
                "A category named \"%s\" already exists. Replace its contents or import as new?\n\nContains %d pages and %d sub-categories.\n\n%s",
                data.Name,
                pageCount,
                catCount,
                variableSummary
            ),
            button1 = "Replace",
            button2 = "Import as New",
            button3 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(popup)
                AngryEra:DoImportCategory(popup.data.Payload, nil, existingId, nil, popup.data.Options)
            end,
            OnCancel = function(popup, _, reason)
                if reason == "clicked" then
                    local newData = {
                        Name = popup.data.Payload.Name,
                        Vars = popup.data.Payload.Vars,
                        VariablesIncluded = popup.data.Payload.VariablesIncluded,
                        Children = popup.data.Payload.Children,
                        Index = popup.data.Payload.Index,
                    }
                    newData.Name = AngryEra:GetUniqueEntityName(newData.Name, "Category")
                    AngryEra:DoImportCategory(newData, nil, nil, nil, popup.data.Options)
                end
            end,
        }
        StaticPopup_Show("AngryEra_ImportConflictCat", nil, nil, request)
    else
        StaticPopupDialogs["AngryEra_ImportConfirmCat"] = {
            text = string.format(
                "Import category \"%s\" and children?\n\nContains %d pages and %d sub-categories.\n\n%s",
                data.Name,
                pageCount,
                catCount,
                variableSummary
            ),
            button1 = "Import",
            button2 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(popup)
                AngryEra:DoImportCategory(popup.data.Payload, nil, nil, nil, popup.data.Options)
            end,
        }
        StaticPopup_Show("AngryEra_ImportConfirmCat", nil, nil, request)
    end
end

--- Imports (or overwrites) a category payload and its descendants.
-- @tparam table data Category payload.
-- @tparam[opt] number parentId Optional parent category id.
-- @tparam[opt] number overwriteId Existing category id to overwrite.
-- @tparam[opt=false] boolean suppressTreeUpdate Skip immediate tree refresh when `true`.
-- @tparam[opt] table options Import options.
-- @treturn number Imported category id.
function AngryEra:DoImportCategory(data, parentId, overwriteId, suppressTreeUpdate, options)
    options = ResolveImportOptions(data, options)
    local existing = overwriteId and AngryAssign_Categories[overwriteId]
    local importedName = data.Name
    if existing and not self:CanEditEntityLocally(existing) then
        overwriteId = nil
        existing = nil
        importedName = self:GetUniqueEntityName(importedName, "Category")
    end

    if overwriteId then
        local deleted, deleteError = self:DeleteCategoryChildren(overwriteId, true)
        if not deleted then
            return nil, deleteError
        end
    end

    local importedVariables
    if options.includeVariables then
        importedVariables = data.Vars or ""
    elseif existing then
        importedVariables = type(existing.Vars) == "string" and existing.Vars or ""
    else
        importedVariables = ""
    end
    local fields = {
        Name = importedName,
        Vars = importedVariables,
        CategoryId = (existing and existing.CategoryId) or parentId,
        Index = (existing and existing.Index) or data.Index,
    }
    local category
    if overwriteId then
        category = self:ReplaceCategoryRecord(overwriteId, fields)
    else
        category = self:NewLocalCategoryRecord(fields)
    end
    local id = category.Id
    AngryAssign_Categories[id] = category

    for _, child in ipairs(data.Children or {}) do
        if child.Type == "Category" then
            self:DoImportCategory(child, id, nil, true, options)
        else
            self:DoImportPage(child, id, nil, true, options)
        end
    end

    if not suppressTreeUpdate then
        self:UpdateTree()
        self:RefreshDisplayedPageAfterHierarchyMutation()
    end
    return id
end

--- Opens the encoded-import window (`AA:Page` / `AA:Category`).
function AngryEra:ShowImportWindow()
    local frame = AceGUI:Create("Window")
    frame:SetTitle("Import")
    frame:SetLayout("Flow")
    frame:SetWidth(520)
    frame:SetHeight(340)
    frame:EnableResize(false)
    TrackWindow(self, "_encodedImportWindow", frame)

    local includeVariables = AceGUI:Create("CheckBox")
    includeVariables:SetLabel("Import variables and metadata when included")
    includeVariables:SetValue(true)
    includeVariables:SetFullWidth(true)
    frame:AddChild(includeVariables)

    local variableHelp = AceGUI:Create("Label")
    variableHelp:SetText(
        "Includes variable families, assigned-role snapshots, group layouts, raid markers, encounter settings, and custom $ metadata."
    )
    variableHelp:SetFullWidth(true)
    frame:AddChild(variableHelp)

    local editBox = AceGUI:Create("MultiLineEditBox")
    editBox:SetLabel("Paste export string:")
    editBox:SetFullWidth(true)
    editBox:SetFullHeight(true)
    editBox:DisableButton(true)
    editBox:SetCallback("OnTextChanged", function(widget, event, text)
        local ok, result, prefix = AngryEra:ParseImportString(text)
        if not ok then
            return
        end
        local options = {
            includeVariables = includeVariables:GetValue() == true,
        }
        CloseTrackedWindow(AngryEra, "_encodedImportWindow")
        if prefix == "Category" then
            AngryEra:ConfirmImportCategory(result, options)
        else
            AngryEra:ConfirmImportPage(result, options)
        end
    end)
    frame:AddChild(editBox)

    C_Timer.After(0, function()
        if AngryEra._encodedImportWindow == frame and frame._angryEraWindowReleased ~= true and editBox.editBox then
            editBox.editBox:SetFocus()
        end
    end)
end

-- ── JSON Import Helpers ─────────────────────────────────────────────────────

local function IsJSONNull(value)
    return value == json.JSON_NULL
end

local function IsJSONNilLike(value)
    return value == nil or IsJSONNull(value)
end

local function JSONValueOrNil(value)
    if IsJSONNull(value) then
        return nil
    end
    return value
end

local function ValidateJSONImportData(data)
    if type(data) ~= "table" then
        return false, "Invalid JSON import: root value must be an object."
    end

    if not IsJSONNilLike(data.pages) then
        if type(data.pages) ~= "table" then
            return false, "Invalid JSON import: \"pages\" must be an array."
        end
        for key in pairs(data.pages) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                return false, "Invalid JSON import: \"pages\" must be an array."
            end
        end
        if not IsJSONNilLike(data.name) and type(data.name) ~= "string" then
            return false, "Invalid JSON import: \"name\" must be a string when provided."
        end
        for index, page in ipairs(data.pages) do
            if type(page) ~= "table" then
                return false, string.format("Invalid JSON import: pages[%d] must be an object.", index)
            end
            local pageName = JSONValueOrNil(page.name)
            if type(pageName) ~= "string" or pageName:match("^%s*$") then
                return false, string.format("Invalid JSON import: pages[%d].name must be a non-empty string.", index)
            end
            local pageContent = JSONValueOrNil(page.content)
            if pageContent ~= nil and type(pageContent) ~= "string" then
                return false,
                    string.format("Invalid JSON import: pages[%d].content must be a string when provided.", index)
            end
        end
        return true
    end

    local rootName = JSONValueOrNil(data.name)
    local rootContent = JSONValueOrNil(data.content)

    if rootName ~= nil and type(rootName) ~= "string" then
        return false, "Invalid JSON import: \"name\" must be a string when provided."
    end
    if rootContent ~= nil and type(rootContent) ~= "string" then
        return false, "Invalid JSON import: \"content\" must be a string when provided."
    end
    if rootName == nil and rootContent == nil then
        return false, "Invalid JSON import: expected \"pages\" for categories or \"name\"/\"content\" for pages."
    end

    return true
end

-- ── Legacy JSON/Markdown Import Window ──────────────────────────────────────

local function AngryEra_ImportPage()
    local frame = AceGUI:Create("Window")
    frame:SetTitle("Import Category or Page")
    frame:SetLayout("Flow")
    frame:SetWidth(500)
    frame:SetHeight(400)
    frame:EnableResize(true)
    TrackWindow(AngryEra, "_legacyImportWindow", frame)

    local nameBox = AceGUI:Create("EditBox")
    nameBox:SetLabel("Name")
    nameBox:SetFullWidth(true)
    nameBox:SetFocus()
    frame:AddChild(nameBox)

    local contentBox = AceGUI:Create("MultiLineEditBox")
    contentBox:SetLabel("Content")
    contentBox:SetFullWidth(true)
    contentBox:SetNumLines(15)
    frame:AddChild(contentBox)

    local importBtn = AceGUI:Create("Button")
    importBtn:SetText("Import")
    importBtn:SetFullWidth(true)

    local function DoImport(nameStr, s, jsonData)
        if jsonData then
            if not nameStr or type(nameStr) ~= "string" or nameStr:match("^%s*$") then
                nameStr = JSONValueOrNil(jsonData.name)
            end
            if type(nameStr) ~= "string" or nameStr:match("^%s*$") then
                nameStr = "Imported"
            end

            local jsonPages = JSONValueOrNil(jsonData.pages)
            if jsonPages then
                -- Category Import
                local title = nameStr
                local catId
                for _, cat in pairs(AngryAssign_Categories) do
                    if cat.Name == title then
                        catId = cat.Id
                        break
                    end
                end
                if catId and not AngryEra:CanEditEntityLocally(AngryAssign_Categories[catId]) then
                    title = AngryEra:GetUniqueEntityName(title, "Category")
                    catId = nil
                end

                if not catId then
                    local success, err, newId = AngryEra:CreateCategory(title)
                    if success then
                        catId = newId
                    else
                        print("Error creating category: " .. (err or ""))
                        return
                    end
                end

                if catId then
                    for i, pData in ipairs(jsonPages) do
                        local pName = JSONValueOrNil(pData.name)
                        local pContent = JSONValueOrNil(pData.content) or ""

                        local pageId
                        for _, p in pairs(AngryAssign_Pages) do
                            if p.CategoryId == catId and p.Name == pName then
                                pageId = p.Id
                                break
                            end
                        end
                        if pageId and not AngryEra:CanEditEntityLocally(AngryAssign_Pages[pageId]) then
                            pName = AngryEra:GetUniqueEntityName(pName, "Page")
                            pageId = nil
                        end

                        if pageId then
                            local updated, updateError = AngryEra:ApplyImportedPageUpdate(pageId, pContent, i)
                            if not updated and updateError then
                                print(updateError)
                            end
                        else
                            AngryEra:CreatePage(pName, pContent, catId, i)
                        end
                    end
                    CloseTrackedWindow(AngryEra, "_legacyImportWindow")
                end
            else
                -- Single Page Import
                local title = nameStr
                local pageContent = JSONValueOrNil(jsonData.content) or ""
                local existingId
                for _, page in pairs(AngryAssign_Pages) do
                    if page.Name == title and not page.CategoryId then
                        existingId = page.Id
                        break
                    end
                end
                if existingId and not AngryEra:CanEditEntityLocally(AngryAssign_Pages[existingId]) then
                    title = AngryEra:GetUniqueEntityName(title, "Page")
                    existingId = nil
                end

                if existingId then
                    AngryEra:UpdateContents(existingId, pageContent)
                    AngryEra:RenamePage(existingId, title)
                    CloseTrackedWindow(AngryEra, "_legacyImportWindow")
                else
                    local success, err = AngryEra:CreatePage(title, pageContent, nil, nil)
                    if not success then
                        print("Error: " .. (err or ""))
                    else
                        CloseTrackedWindow(AngryEra, "_legacyImportWindow")
                    end
                end
            end
            AngryEra:UpdateTree()
            return
        end

        local searchStr = "\n" .. s
        local headers = {}
        for startPos, title in searchStr:gmatch("()\n# ([^\n]+)") do
            if #headers > 0 then
                headers[#headers].contentEnd = startPos - 1
            end
            table.insert(headers, {
                title = title:match("^%s*(.-)%s*$"),
                headerStart = startPos + 1,
            })
        end
        if #headers > 0 then
            headers[#headers].contentEnd = #searchStr
        end

        if #headers == 0 then
            -- Single Page
            local existingId
            for _, page in pairs(AngryAssign_Pages) do
                if page.Name == nameStr and not page.CategoryId then
                    existingId = page.Id
                    break
                end
            end
            if existingId and not AngryEra:CanEditEntityLocally(AngryAssign_Pages[existingId]) then
                nameStr = AngryEra:GetUniqueEntityName(nameStr, "Page")
                existingId = nil
            end

            if existingId then
                AngryEra:UpdateContents(existingId, s)
                AngryEra:RenamePage(existingId, nameStr)
            else
                local success, err = AngryEra:CreatePage(nameStr, s, nil, nil)
                if not success then
                    print("Error: " .. (err or ""))
                end
            end
            CloseTrackedWindow(AngryEra, "_legacyImportWindow")
        else
            -- Category
            local catId
            for _, cat in pairs(AngryAssign_Categories) do
                if cat.Name == nameStr then
                    catId = cat.Id
                    break
                end
            end
            if catId and not AngryEra:CanEditEntityLocally(AngryAssign_Categories[catId]) then
                nameStr = AngryEra:GetUniqueEntityName(nameStr, "Category")
                catId = nil
            end

            if not catId then
                local success, err, newId = AngryEra:CreateCategory(nameStr)
                if success then
                    catId = newId
                else
                    print("Error creating category: " .. (err or ""))
                    return
                end
            end

            if catId then
                for i, h in ipairs(headers) do
                    local block = searchStr:sub(h.headerStart, h.contentEnd)
                    local pageId
                    for _, p in pairs(AngryAssign_Pages) do
                        if p.CategoryId == catId and p.Name == h.title then
                            pageId = p.Id
                            break
                        end
                    end
                    local pageTitle = h.title
                    if pageId and not AngryEra:CanEditEntityLocally(AngryAssign_Pages[pageId]) then
                        pageTitle = AngryEra:GetUniqueEntityName(pageTitle, "Page")
                        pageId = nil
                    end

                    if pageId then
                        local updated, updateError = AngryEra:ApplyImportedPageUpdate(pageId, block, i)
                        if not updated and updateError then
                            print(updateError)
                        end
                    else
                        AngryEra:CreatePage(pageTitle, block, catId, i)
                    end
                end
                CloseTrackedWindow(AngryEra, "_legacyImportWindow")
            end
        end
        AngryEra:UpdateTree()
    end

    importBtn:SetCallback("OnClick", function()
        local nameStr = nameBox:GetText()
        local s = contentBox:GetText()
        if not s then
            s = ""
        end

        local jsonData
        local looksLikeJSON = s:match("^%s*[{[]") ~= nil
        if looksLikeJSON then
            local decoded = json.JSON_TryDecode(s)
            if decoded == nil then
                print("Invalid JSON. Check syntax and try again.")
                return
            end
            local valid, validationError = ValidateJSONImportData(decoded)
            if not valid then
                print(validationError)
                return
            end
            jsonData = decoded
        end

        if jsonData then
            if not nameStr or nameStr == "" then
                nameStr = JSONValueOrNil(jsonData.name)
            end
        end

        if type(nameStr) ~= "string" then
            nameStr = nil
        end

        if (not nameStr or nameStr:match("^%s*$")) and not jsonData then
            print("Please enter a name.")
            return
        end
        if not nameStr or nameStr:match("^%s*$") then
            nameStr = "Imported"
        end

        local exists = false
        if jsonData then
            local jsonPages = JSONValueOrNil(jsonData.pages)
            if jsonPages then
                for _, cat in pairs(AngryAssign_Categories) do
                    if cat.Name == nameStr then
                        exists = true
                        break
                    end
                end
            else
                for _, page in pairs(AngryAssign_Pages) do
                    if page.Name == nameStr and not page.CategoryId then
                        exists = true
                        break
                    end
                end
            end
        else
            local hasHeaders = s:match("\n# ") or s:match("^# ")
            if hasHeaders then
                for _, cat in pairs(AngryAssign_Categories) do
                    if cat.Name == nameStr then
                        exists = true
                        break
                    end
                end
            else
                for _, page in pairs(AngryAssign_Pages) do
                    if page.Name == nameStr and not page.CategoryId then
                        exists = true
                        break
                    end
                end
            end
        end

        if exists then
            local popup_name = "AngryEra_ImportOverwrite"
            StaticPopupDialogs[popup_name] = {
                text = "A %s named \"%s\" already exists.\nOverwrite?",
                button1 = YES,
                button2 = NO,
                whileDead = true,
                hideOnEscape = true,
                timeout = 0,
                OnAccept = function()
                    DoImport(nameStr, s, jsonData)
                end,
            }
            local typeStr = "page"
            if jsonData and JSONValueOrNil(jsonData.pages) then
                typeStr = "category"
            elseif not jsonData and (s:match("\n# ") or s:match("^# ")) then
                typeStr = "category"
            end

            StaticPopup_Show(popup_name, typeStr, nameStr)
        else
            DoImport(nameStr, s, jsonData)
        end
    end)
    frame:AddChild(importBtn)
end

-- Expose for editor.lua main menu
AngryEra._AngryEra_ImportPage = AngryEra_ImportPage

-- ── Export Logic ────────────────────────────────────────────────────────────

local function SerializeJSON(val)
    return json.JSON_Encode(val)
end

local function HighlightExportText(editBox, frame)
    C_Timer.After(0, function()
        if AngryEra._generalExportWindow == frame and frame._angryEraWindowReleased ~= true and editBox.editBox then
            editBox:SetFocus()
            editBox:HighlightText()
        end
    end)
end

local function AngryEra_ShowExportWindow(text, title, encodedOptions)
    local frame = AceGUI:Create("Window")
    frame:SetTitle("Export " .. title)
    frame:SetLayout("Flow")
    frame:SetWidth(600)
    frame:SetHeight(encodedOptions and 570 or 500)
    frame:EnableResize(true)
    TrackWindow(AngryEra, "_generalExportWindow", frame)

    local editBox
    if encodedOptions then
        local includeVariables = AceGUI:Create("CheckBox")
        includeVariables:SetLabel("Include variables and metadata")
        includeVariables:SetValue(encodedOptions.includeVariables)
        includeVariables:SetFullWidth(true)
        frame:AddChild(includeVariables)

        local variableHelp = AceGUI:Create("Label")
        variableHelp:SetText(encodedOptions.description)
        variableHelp:SetFullWidth(true)
        frame:AddChild(variableHelp)

        local revertingValue = false
        includeVariables:SetCallback("OnValueChanged", function(widget, _, value)
            if revertingValue then
                return
            end
            local updatedText, exportError = encodedOptions.build(value == true)
            if not updatedText then
                AngryEra:Print("Unable to update export: " .. tostring(exportError or "invalid hierarchy"))
                revertingValue = true
                widget:SetValue(value ~= true)
                revertingValue = false
                return
            end
            editBox:SetText(updatedText)
            HighlightExportText(editBox, frame)
        end)
    end

    editBox = AceGUI:Create("MultiLineEditBox")
    editBox:SetLabel("Copy the text below (Ctrl+C / Cmd+C)")
    editBox:SetFullWidth(true)
    editBox:SetFullHeight(true)
    editBox:SetText(text)
    editBox:DisableButton(true)
    frame:AddChild(editBox)
    HighlightExportText(editBox, frame)
end

local function BuildEncodedExport(self, id, entityType, includeVariables)
    local options = {
        includeVariables = includeVariables,
    }
    if entityType == "page" then
        local page = AngryAssign_Pages[id]
        if not page then
            return nil, "page-not-found"
        end
        local data, exportError = serialization.GetPageExportData(page, options)
        if not data then
            return nil, exportError or "invalid-page"
        end
        return serialization.EncodeExportString(data, "Page"), page.Name
    end
    if entityType == "category" then
        local cat = AngryAssign_Categories[id]
        if not cat then
            return nil, "category-not-found"
        end
        local data, exportError = self:GetCategoryExportData(id, options)
        if not data then
            return nil, exportError or "invalid-hierarchy"
        end
        return serialization.EncodeExportString(data, "Category"), cat.Name
    end
    return nil, "invalid-entity-type"
end

--- Exports a page or category in one of the supported formats.
-- @tparam number id Entity id.
-- @tparam string entityType `"page"` or `"category"`.
-- @tparam string format `"Encoded AA"`, `"JSON"`, `"Markdown"`, or `"Output"`.
-- @tparam[opt] table options Export options.
function AngryEra:Export(id, entityType, format, options)
    local exportText = ""
    local title = ""

    if format == "Encoded AA" then
        local includeVariables = type(options) ~= "table" or options.includeVariables ~= false
        exportText, title = BuildEncodedExport(self, id, entityType, includeVariables)
        if not exportText and includeVariables then
            local variableError = title
            exportText, title = BuildEncodedExport(self, id, entityType, false)
            if exportText then
                includeVariables = false
                self:Print(
                    "Variables and metadata could not be included ("
                        .. tostring(variableError)
                        .. "). Opened a content-only export instead."
                )
            end
        end
        if not exportText then
            self:Print("Unable to export " .. tostring(entityType) .. ": " .. tostring(title or "not found"))
            return
        end
        local description
        if entityType == "category" then
            description =
                "Includes variable families, role snapshots, layouts, markers, and automation metadata recursively. Values inherited from above this category are not copied."
        else
            description =
                "Includes variable families, role snapshots, layouts, markers, and automation metadata declared directly on this page. Inherited category values are not copied."
        end
        AngryEra_ShowExportWindow(exportText, title .. " (" .. format .. ")", {
            includeVariables = includeVariables,
            description = description,
            build = function(selected)
                local rebuilt, rebuiltTitleOrError = BuildEncodedExport(self, id, entityType, selected)
                return rebuilt, rebuilt and nil or rebuiltTitleOrError
            end,
        })
        return
    end

    if entityType == "page" then
        local page = AngryAssign_Pages[id]
        if not page then
            return
        end
        title = page.Name

        if format == "JSON" then
            local data = { name = page.Name, content = page.Contents }
            exportText = SerializeJSON(data)
        elseif format == "Markdown" then
            local content = page.Contents
            if not content:match("^# ") then
                content = "# " .. page.Name .. "\n\n" .. content
            end
            exportText = content
        elseif format == "Output" then
            exportText = self:ProcessPageForOutput(page)
        end
    elseif entityType == "category" then
        local cat = AngryAssign_Categories[id]
        if not cat then
            return
        end
        title = cat.Name

        -- Gather Pages in Order
        local pages = {}
        for _, p in pairs(AngryAssign_Pages) do
            if p.CategoryId == id then
                table.insert(pages, p)
            end
        end
        table.sort(pages, CompareIndexedEntries)

        if format == "JSON" then
            local data = { name = cat.Name, pages = {} }
            for _, p in ipairs(pages) do
                table.insert(data.pages, { name = p.Name, content = p.Contents })
            end
            exportText = SerializeJSON(data)
        elseif format == "Markdown" then
            local chunks = {}
            for _, p in ipairs(pages) do
                local content = p.Contents
                if not content:match("^# ") then
                    content = "# " .. p.Name .. "\n\n" .. content
                end
                table.insert(chunks, content)
            end
            exportText = table.concat(chunks, "\n\n")
        elseif format == "Output" then
            local chunks = {}
            for _, p in ipairs(pages) do
                local processed = self:ProcessPageForOutput(p)
                table.insert(chunks, processed)
            end
            exportText = table.concat(chunks, "\n\n")
        end
    end

    AngryEra_ShowExportWindow(exportText, title .. " (" .. format .. ")")
end
