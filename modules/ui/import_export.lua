-- -------------------------------------------------------------------------------
-- Angry Era: modules/ui/import_export.lua
--
-- Import/export windows, confirmation dialogs, template management UI.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local AceGUI = app.libs.AceGUI
local libS = app.libs.libS
local libD = app.libs.libD
local json = AngryEra.utils.json
local serialization = AngryEra.utils.serialization
local CompareIndexedEntries = AngryEra.utils.helpers.CompareIndexedEntries

-- ── Export / Import (Encoded AA) ────────────────────────────────────────────

--- Builds recursive export payload data for a category.
-- Delegates to serialization module.
function AngryEra:GetCategoryExportData(catId)
    return serialization.GetCategoryExportData(self, catId)
end

function AngryEra:ShowExportWindow(exportString, pageName)
    local frame = AceGUI:Create("Window")
    frame:SetTitle("Export: " .. pageName)
    frame:SetLayout("Flow")
    frame:SetWidth(520)
    frame:SetHeight(220)
    frame:EnableResize(false)
    _G["AngryEra_ExportWindow"] = frame.frame
    tinsert(UISpecialFrames, "AngryEra_ExportWindow")
    frame:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
    end)

    local editBox = AceGUI:Create("MultiLineEditBox")
    editBox:SetLabel(nil)
    editBox:SetFullWidth(true)
    editBox:SetFullHeight(true)
    editBox:DisableButton(true)
    editBox:SetText(exportString)
    frame:AddChild(editBox)

    -- Pre-select all text so user can Ctrl+C immediately
    C_Timer.After(0, function()
        if editBox.editBox then
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

--- Shows import confirmation/overwrite UI for a validated page payload.
-- @tparam table data Page payload.
function AngryEra:ConfirmImportPage(data)
    local existingId = self:GetEntityByName(data.Name, "Page")
    local preview = data.Contents:sub(1, 120)
    if #data.Contents > 120 then
        preview = preview .. "…"
    end

    if existingId then
        StaticPopupDialogs["AngryEra_ImportConflictPage"] = {
            text = string.format(
                "A page named \"%s\" already exists. What would you like to do?\n\n%s",
                data.Name,
                preview
            ),
            button1 = "Replace",
            button2 = "Import as New",
            button3 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(popup)
                AngryEra:DoImportPage(popup.data, nil, existingId)
            end,
            OnCancel = function(popup, _, reason)
                if reason == "clicked" then
                    local newData = {
                        Name = popup.data.Name,
                        Contents = popup.data.Contents,
                        Vars = popup.data.Vars,
                        Index = popup.data.Index,
                    }
                    newData.Name = AngryEra:GetUniqueEntityName(newData.Name, "Page")
                    AngryEra:DoImportPage(newData)
                end
            end,
        }
        StaticPopup_Show("AngryEra_ImportConflictPage", nil, nil, data)
    else
        StaticPopupDialogs["AngryEra_ImportConfirmPage"] = {
            text = string.format("Import page \"%s\"?\n\n%s", data.Name, preview),
            button1 = "Import",
            button2 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(popup)
                AngryEra:DoImportPage(popup.data)
            end,
        }
        StaticPopup_Show("AngryEra_ImportConfirmPage", nil, nil, data)
    end
end

--- Imports (or overwrites) a single page payload.
-- @tparam table data Page payload.
-- @tparam[opt] number parentId Optional parent category id.
-- @tparam[opt] number overwriteId Existing page id to overwrite.
-- @tparam[opt=false] boolean suppressTreeUpdate Skip immediate tree refresh when `true`.
-- @treturn number Imported page id.
function AngryEra:DoImportPage(data, parentId, overwriteId, suppressTreeUpdate)
    local existing = overwriteId and AngryAssign_Pages[overwriteId]
    local importedName = data.Name
    if existing and not self:CanEditEntityLocally(existing) then
        overwriteId = nil
        existing = nil
        importedName = self:GetUniqueEntityName(importedName, "Page")
    end
    local fields = {
        Updated = time(),
        UpdateId = self:Hash(importedName, data.Contents, data.Vars),
        Name = importedName,
        Contents = data.Contents,
        Vars = data.Vars,
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
    end
    return id
end

--- Shows import confirmation/overwrite UI for a validated category payload.
-- @tparam table data Category payload.
function AngryEra:ConfirmImportCategory(data)
    local existingId = self:GetEntityByName(data.Name, "Category")
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

    if existingId then
        StaticPopupDialogs["AngryEra_ImportConflictCat"] = {
            text = string.format(
                "A category named \"%s\" already exists. Replace its contents or import as new?\n\nContains %d pages and %d sub-categories.",
                data.Name,
                pageCount,
                catCount
            ),
            button1 = "Replace",
            button2 = "Import as New",
            button3 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(popup)
                AngryEra:DoImportCategory(popup.data, nil, existingId)
            end,
            OnCancel = function(popup, _, reason)
                if reason == "clicked" then
                    local newData = { Name = popup.data.Name, Children = popup.data.Children, Index = popup.data.Index }
                    newData.Name = AngryEra:GetUniqueEntityName(newData.Name, "Category")
                    AngryEra:DoImportCategory(newData)
                end
            end,
        }
        StaticPopup_Show("AngryEra_ImportConflictCat", nil, nil, data)
    else
        StaticPopupDialogs["AngryEra_ImportConfirmCat"] = {
            text = string.format(
                "Import category \"%s\" and children?\n\nContains %d pages and %d sub-categories.",
                data.Name,
                pageCount,
                catCount
            ),
            button1 = "Import",
            button2 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(popup)
                AngryEra:DoImportCategory(popup.data)
            end,
        }
        StaticPopup_Show("AngryEra_ImportConfirmCat", nil, nil, data)
    end
end

--- Imports (or overwrites) a category payload and its descendants.
-- @tparam table data Category payload.
-- @tparam[opt] number parentId Optional parent category id.
-- @tparam[opt] number overwriteId Existing category id to overwrite.
-- @tparam[opt=false] boolean suppressTreeUpdate Skip immediate tree refresh when `true`.
-- @treturn number Imported category id.
function AngryEra:DoImportCategory(data, parentId, overwriteId, suppressTreeUpdate)
    local existing = overwriteId and AngryAssign_Categories[overwriteId]
    local importedName = data.Name
    if existing and not self:CanEditEntityLocally(existing) then
        overwriteId = nil
        existing = nil
        importedName = self:GetUniqueEntityName(importedName, "Category")
    end

    if overwriteId then
        self:DeleteCategoryChildren(overwriteId)
    end

    local fields = {
        Name = importedName,
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
            self:DoImportCategory(child, id, nil, true)
        else
            self:DoImportPage(child, id, nil, true)
        end
    end

    if not suppressTreeUpdate then
        self:UpdateTree()
    end
    return id
end

--- Opens the encoded-import window (`AA:Page` / `AA:Category`).
function AngryEra:ShowImportWindow()
    local frame = AceGUI:Create("Window")
    frame:SetTitle("Import")
    frame:SetLayout("Flow")
    frame:SetWidth(520)
    frame:SetHeight(280)
    frame:EnableResize(false)
    _G["AngryEra_ImportWindow"] = frame.frame
    tinsert(UISpecialFrames, "AngryEra_ImportWindow")
    frame:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
    end)

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
        frame:Hide()
        if prefix == "Category" then
            AngryEra:ConfirmImportCategory(result)
        else
            AngryEra:ConfirmImportPage(result)
        end
    end)
    frame:AddChild(editBox)

    C_Timer.After(0, function()
        if editBox.editBox then
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

    frame:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
    end)

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
                            AngryEra:UpdateContents(pageId, pContent)
                            AngryAssign_Pages[pageId].Index = i
                            AngryEra:PageUpdated(pageId)
                        else
                            AngryEra:CreatePage(pName, pContent, catId, i)
                        end
                    end
                    frame:Hide()
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
                    frame:Hide()
                else
                    local success, err = AngryEra:CreatePage(title, pageContent, nil, nil)
                    if not success then
                        print("Error: " .. (err or ""))
                    else
                        frame:Hide()
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
            frame:Hide()
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
                        AngryEra:UpdateContents(pageId, block)
                        AngryAssign_Pages[pageId].Index = i
                        AngryEra:PageUpdated(pageId)
                    else
                        AngryEra:CreatePage(pageTitle, block, catId, i)
                    end
                end
                frame:Hide()
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

local function AngryEra_ShowExportWindow(text, title)
    local frame = AceGUI:Create("Window")
    frame:SetTitle("Export " .. title)
    frame:SetLayout("Flow")
    frame:SetWidth(600)
    frame:SetHeight(500)
    frame:EnableResize(true)

    frame:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
    end)

    local editBox = AceGUI:Create("MultiLineEditBox")
    editBox:SetLabel("Copy the text below (Ctrl+C / Cmd+C)")
    editBox:SetFullWidth(true)
    editBox:SetFullHeight(true)
    editBox:SetText(text)
    editBox:DisableButton(true)
    editBox:SetFocus()
    editBox:HighlightText()
    frame:AddChild(editBox)
end

--- Exports a page or category in one of the supported formats.
-- @tparam number id Entity id.
-- @tparam string type `"page"` or `"category"`.
-- @tparam string format `"Encoded AA"`, `"JSON"`, `"Markdown"`, or `"Output"`.
function AngryEra:Export(id, type, format)
    local exportText = ""
    local title = ""

    if type == "page" then
        local page = AngryAssign_Pages[id]
        if not page then
            return
        end
        title = page.Name

        if format == "Encoded AA" then
            local data = { Name = page.Name, Contents = page.Contents }
            if page.Vars and page.Vars ~= "" and page.Vars ~= "{}" then
                data.Vars = page.Vars
            end
            local serialized = libS:Serialize(data)
            local compressed = libD:CompressDeflate(serialized)
            local encoded = libD:EncodeForPrint(compressed)
            exportText = "AA:Page:1:" .. encoded
        elseif format == "JSON" then
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
    elseif type == "category" then
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

        if format == "Encoded AA" then
            local data = self:GetCategoryExportData(id)
            local serialized = libS:Serialize(data)
            local compressed = libD:CompressDeflate(serialized)
            local encoded = libD:EncodeForPrint(compressed)
            exportText = "AA:Category:1:" .. encoded
        elseif format == "JSON" then
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
