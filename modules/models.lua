-- -------------------------------------------------------------------------------
-- Angry Era: modules/models.lua
--
-- Page/category CRUD, history, navigation, display page selection.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local helpers = AngryEra.utils.helpers
local selectedLastValue = helpers.selectedLastValue
local IsCategoryDescendant = helpers.IsCategoryDescendant
local ExtractAndValidateName = helpers.ExtractAndValidateName
local unpackValues = unpack or rawget(table, "unpack")

local libC = app.libs.libC

local function PublishPageRevision(self, id)
    if AngryAssign_State.displayed == id and self:CanLocalPlayerPublish("display") then
        local published, publishResult, activatedLocally = self:SendDisplay(id, true)
        if activatedLocally == true and type(self.CancelAutoAdvancePublishRetry) == "function" then
            self:CancelAutoAdvancePublishRetry()
        end
        return published, publishResult, activatedLocally
    end
    -- A qualified assistant may still publish an edit to the active page, but
    -- only the current group leader may choose or replace the shared display.
    return self:SendPage(id, true)
end

local function ReportFailedDisplayPublish(self, id, published, publishResult, activatedLocally)
    if AngryAssign_State.displayed ~= id or published == true or activatedLocally == true then
        return
    end
    self:Print(RED_FONT_COLOR_CODE .. "Unable to publish the displayed page: " .. tostring(publishResult) .. "|r")
end

--- Republishes the displayed page after a hierarchy mutation may have changed
-- its canonical mixed-sibling order, parent, or inherited variable layers.
-- Private organization changes by unauthorized viewers leave the exact shared
-- display snapshot untouched.
-- @treturn boolean sent
-- @treturn string|nil messageIdOrError
-- @treturn boolean activatedLocally
function AngryEra:RefreshDisplayedPageAfterHierarchyMutation()
    local displayedId = AngryAssign_State.displayed
    if not displayedId or not AngryAssign_Pages[displayedId] then
        return true, "no-displayed-page", false
    end

    local sent, result, activatedLocally = self:SendDisplay(displayedId, true)
    if activatedLocally == true then
        if type(self.CancelAutoAdvancePublishRetry) == "function" then
            self:CancelAutoAdvancePublishRetry()
        end
        self:UpdateDisplayed()
    end
    return sent, result, activatedLocally
end

--- Displays a page by its exact name.
-- @tparam string name Page name.
-- @treturn boolean|nil `true` when displayed, `false` when not found, or `nil` on permission failure.
function AngryEra:DisplayPageByName(name)
    for id, page in pairs(AngryAssign_Pages) do
        if page.Name == name then
            return self:DisplayPage(id)
        end
    end
    return false
end

--- Displays a page locally and publishes its exact v3 page/context snapshot.
-- Existing callers may continue to use the first return value as local display
-- success. The third and fourth returns expose the independent publication
-- result for callers that require shared-display confirmation.
-- @tparam number id Page id.
-- @tparam[opt] table options Internal display options.
-- @treturn boolean|nil `true` on success, or `nil` when permission fails.
-- @treturn string|nil localError
-- @treturn boolean published
-- @treturn string|nil publicationResult
function AngryEra:DisplayPage(id, options)
    local retry = type(options) == "table" and options.AutoAdvanceRetry or nil

    if not self:CanLocalPlayerPublish("display") then
        return
    end

    local published, displayResult, activatedLocally = self:SendDisplay(id, true)
    if activatedLocally ~= true then
        self:Print(RED_FONT_COLOR_CODE .. "Unable to display the page: " .. tostring(displayResult) .. "|r")
        return nil, displayResult, false, displayResult
    end

    if
        type(self.CancelAutoAdvancePublishRetry) == "function"
        and (retry == nil or retry ~= self._autoAdvancePublishRetry)
    then
        self:CancelAutoAdvancePublishRetry()
    end

    local changedPage = AngryAssign_State.displayed ~= id
    if changedPage then
        AngryAssign_State.displayed = id
    end

    -- SendDisplay activates an exact page/context tuple before transport. Even
    -- when the local page id is unchanged (for example, a publication retry),
    -- that tuple can have a new revision and must be rendered into the public
    -- displayed-note snapshot before the next encounter.
    AngryEra:UpdateDisplayed()
    if changedPage then
        AngryEra:ShowDisplay()
        AngryEra:UpdateTree()
        AngryEra:DisplayUpdateNotification()
    end

    return true, nil, published == true, displayResult
end

function AngryEra:CategoryUpdated(id)
    self:UpdateTree()
    self:RefreshDisplayedPageAfterHierarchyMutation()
end

function AngryEra:PageUpdated(id)
    self:UpdateTree()
    local page = AngryAssign_Pages[id]
    if page then
        page.Updated = time()
        page.UpdateId = self:Hash(page.Name, page.Contents, page.Vars)
        local published, publishResult, activatedLocally = PublishPageRevision(self, id)
        self:UpdateDisplayed()
        ReportFailedDisplayPublish(self, id, published, publishResult, activatedLocally)
        return
    end
    self:UpdateDisplayed()
end

-- ── Import Helper Functions ──────────────────────────────────────────────────

--- Returns the id of a page or category by exact name.
-- @tparam string name Entity name.
-- @tparam string type Either `"Page"` or `"Category"`.
-- @treturn number|nil Matching entity id.
function AngryEra:GetEntityByName(name, type)
    if type == "Page" then
        for id, page in pairs(AngryAssign_Pages) do
            if page.Name == name then
                return id
            end
        end
    elseif type == "Category" then
        for id, cat in pairs(AngryAssign_Categories) do
            if cat.Name == name then
                return id
            end
        end
    end
    return nil
end

--- Produces a unique name by appending ` (n)` suffixes when needed.
-- @tparam string name Base name.
-- @tparam string type Either `"Page"` or `"Category"`.
-- @treturn string Unique name.
function AngryEra:GetUniqueEntityName(name, type)
    local newName = name
    local n = 1
    while self:GetEntityByName(newName, type) do
        newName = string.format("%s (%d)", name, n)
        n = n + 1
    end
    return newName
end

local function CollectCategoryDescendants(rootId)
    local children = {}
    for id, category in pairs(AngryAssign_Categories) do
        if type(category) ~= "table" or type(id) ~= "number" or id < 1 or id % 1 ~= 0 or category.Id ~= id then
            return nil, "invalid-category-id"
        end
        if category.CategoryId then
            if type(category.CategoryId) ~= "number" or category.CategoryId < 1 or category.CategoryId % 1 ~= 0 then
                return nil, "invalid-category-parent"
            end
            children[category.CategoryId] = children[category.CategoryId] or {}
            children[category.CategoryId][#children[category.CategoryId] + 1] = id
        end
    end
    for _, childIds in pairs(children) do
        table.sort(childIds)
    end

    local visiting = {}
    local visited = {}
    local descendants = {}
    local function Visit(categoryId, depth)
        if visiting[categoryId] then
            return false, "category-cycle"
        end
        if visited[categoryId] then
            return true
        end
        if depth > 32 then
            return false, "category-depth-exceeded"
        end

        visiting[categoryId] = true
        for _, childId in ipairs(children[categoryId] or {}) do
            local ok, traversalError = Visit(childId, depth + 1)
            if not ok then
                return false, traversalError
            end
        end
        visiting[categoryId] = nil
        visited[categoryId] = true
        if categoryId ~= rootId then
            descendants[#descendants + 1] = categoryId
        end
        return true
    end

    local ok, traversalError = Visit(rootId, 1)
    if not ok then
        return nil, traversalError
    end
    return descendants, visited
end

--- Deletes all nested categories and pages under a category id.
-- @tparam number catId Category id to recursively clear.
-- @tparam[opt=false] boolean suppressDisplayRefresh Defer active-page republishing to a larger transaction.
-- @treturn boolean ok
-- @treturn string|nil errorCode
function AngryEra:DeleteCategoryChildren(catId, suppressDisplayRefresh)
    local descendantIds, categorySet = CollectCategoryDescendants(catId)
    if not descendantIds then
        return false, categorySet
    end

    local pageIds = {}
    for id, page in pairs(AngryAssign_Pages) do
        if type(page) == "table" and categorySet[page.CategoryId] then
            if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then
                return false, "invalid-page-id"
            end
            pageIds[#pageIds + 1] = id
        end
    end
    table.sort(pageIds)

    for _, pageId in ipairs(pageIds) do
        self:RemovePageRecord(pageId)
        if AngryAssign_State.displayed == pageId then
            self:ClearDisplayed(true)
        end
    end
    for _, categoryId in ipairs(descendantIds) do
        self:RemoveCategoryRecord(categoryId)
        if AngryAssign_State.tree.groups then
            AngryAssign_State.tree.groups[-categoryId] = nil
        end
    end
    if suppressDisplayRefresh ~= true then
        self:RefreshDisplayedPageAfterHierarchyMutation()
    end
    return true
end

-- ----------------------------------
-- Performing changes functions --
-- ----------------------------------

function AngryEra:PrevPage()
    self:NextPage(true)
end

function AngryEra:NextPage(reverse)
    local page = AngryAssign_Pages[AngryAssign_State.displayed]
    if not page then
        return
    end
    if not page.CategoryId then
        return
    end

    local siblings = {}
    for _, p in pairs(AngryAssign_Pages) do
        if p.CategoryId and p.CategoryId == page.CategoryId then
            table.insert(siblings, p)
        end
    end

    -- Use the same sort order as the Tree
    table.sort(siblings, function(a, b)
        local ia = a.Index
        local ib = b.Index
        if ia and ib then
            if ia == ib then
                return a.Name < b.Name
            end
            return ia < ib
        elseif ia then
            return true
        elseif ib then
            return false
        else
            return a.Name < b.Name
        end
    end)

    for i, p in ipairs(siblings) do
        if p.Id == page.Id then
            local dest = siblings[reverse and (i - 1) or (i + 1)]
            if dest then
                self:DisplayPage(dest.Id)
            else
                self:Print(reverse and "Already at first page." or "Already at last page.")
            end
            return
        end
    end
end

function AngryEra:FirstPage()
    local page = AngryAssign_Pages[AngryAssign_State.displayed]
    if not page or not page.CategoryId then
        return
    end

    local siblings = {}
    for _, p in pairs(AngryAssign_Pages) do
        if p.CategoryId == page.CategoryId then
            table.insert(siblings, p)
        end
    end

    if #siblings == 0 then
        return
    end

    -- Use the same sort order as the Tree
    table.sort(siblings, function(a, b)
        local ia = a.Index
        local ib = b.Index
        if ia and ib then
            if ia == ib then
                return a.Name < b.Name
            end
            return ia < ib
        elseif ia then
            return true
        elseif ib then
            return false
        else
            return a.Name < b.Name
        end
    end)

    local firstSib = siblings[1]

    if page.Id == firstSib.Id then
        -- We are already on the first page. Snap back to the last selected page?
        local lastPage = self.lastNonFirstPageId and AngryAssign_Pages[self.lastNonFirstPageId]
        if lastPage and lastPage.CategoryId == page.CategoryId then
            self:DisplayPage(self.lastNonFirstPageId)
            self.lastNonFirstPageId = nil
        else
            self:Print("Already on the first page.")
        end
    else
        self.lastNonFirstPageId = page.Id
        self:DisplayPage(firstSib.Id)
    end
end

function AngryEra:SelectedId()
    return selectedLastValue(AngryAssign_State.tree.selected)
end

function AngryEra:SetSelectedId(selectedId)
    local page = AngryAssign_Pages[selectedId]
    if page then
        if page.CategoryId then
            local chain = AngryEra.utils.variables.CollectCategoryChain(AngryAssign_Categories, page.CategoryId)
            if not chain then
                self.window.tree:SelectByValue(page.Id)
                return false
            end
            local path = {}
            for _, category in ipairs(chain) do
                path[#path + 1] = -category.Id
            end
            table.insert(path, page.Id)
            self.window.tree:SelectByPath(unpackValues(path))
        else
            self.window.tree:SelectByValue(page.Id)
        end
        return true
    else
        self.window.tree:SetSelected()
    end
    return false
end

--- Returns a page by id or current selection.
-- @tparam[opt] number id Page id, defaults to selected id.
-- @treturn table|nil Page table.
function AngryEra:Get(id)
    if id == nil then
        id = self:SelectedId()
    end
    return AngryAssign_Pages[id]
end

--- Returns a category by id.
-- @tparam number id Category id.
-- @treturn table|nil Category table.
function AngryEra:GetCat(id)
    return AngryAssign_Categories[id]
end

--- Computes a stable FCS32 update hash for page identity/versioning.
-- @tparam string name Page name.
-- @tparam string contents Page contents.
-- @tparam[opt] string vars Page variable string.
-- @treturn string Hash string.
function AngryEra:Hash(name, contents, vars)
    local code = libC:fcs32init()
    code = libC:fcs32update(code, name)
    code = libC:fcs32update(code, "\n")
    code = libC:fcs32update(code, contents)
    if vars then
        code = libC:fcs32update(code, "\n")
        code = libC:fcs32update(code, vars)
    end
    return libC:fcs32final(code)
end

--- Creates a page and syncs it to the group.
-- @tparam string|table nameOrFrame Name text or popup/editbox frame.
-- @tparam[opt=""] string content Initial page content.
-- @tparam[opt] number categoryId Parent category id.
-- @tparam[opt] number index Sort index override.
-- @tparam[opt=false] boolean suppressDisplayRefresh Defer active-page order republishing to a bulk operation.
-- @treturn boolean ok
-- @treturn string|nil err Error message on failure.
-- @treturn number|nil id New page id on success.
function AngryEra:CreatePage(nameOrFrame, content, categoryId, index, suppressDisplayRefresh)
    -- Validate and Clean Input
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then
        return false, err
    end

    if content and type(content) ~= "string" then
        content = ""
    end

    -- Original Business Logic
    local page = self:NewLocalPageRecord({
        Updated = time(),
        UpdateId = self:Hash(name, content or ""),
        Name = name,
        Contents = content or "",
        CategoryId = categoryId,
        Index = index,
    })
    local id = page.Id
    AngryAssign_Pages[id] = page

    if categoryId then
        if AngryAssign_State.tree.groups then
            if AngryAssign_State.tree.groups[categoryId] == nil then
                AngryAssign_State.tree.groups[categoryId] = true
            end
        end
    end

    self:UpdateTree(id)
    PublishPageRevision(self, id)
    if suppressDisplayRefresh ~= true and AngryAssign_State.displayed ~= id then
        self:RefreshDisplayedPageAfterHierarchyMutation()
    end

    return true, nil, id
end

--- Renames a page and broadcasts the update.
-- @tparam number id Page id.
-- @tparam string|table nameOrFrame New name text or popup/editbox frame.
-- @treturn boolean ok
-- @treturn string|nil err Error message when rename fails.
function AngryEra:RenamePage(id, nameOrFrame)
    -- Check Existence
    local page = self:Get(id)
    if not page then
        return false, "Page not found."
    end

    if not self:CanEditEntityLocally(page) then
        return false, "Permission denied."
    end

    -- Validate and Clean Input
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then
        return false, err
    end

    -- Optimization: Skip if name hasn't changed
    if page.Name == name then
        return true
    end

    -- Original Business Logic
    page.Name = name
    page.Updated = time()
    page.UpdateId = self:Hash(page.Name, page.Contents, page.Vars)

    local published, publishResult, activatedLocally = PublishPageRevision(self, id)
    if AngryAssign_State.displayed ~= id then
        self:RefreshDisplayedPageAfterHierarchyMutation()
    end
    self:UpdateTree()

    if AngryAssign_State.displayed == id then
        self:UpdateDisplayed()
        if activatedLocally == true then
            self:ShowDisplay()
        end
    end
    ReportFailedDisplayPublish(self, id, published, publishResult, activatedLocally)

    return true
end

--- Deletes a page from local storage and selection state.
-- @tparam number id Page id.
function AngryEra:DeletePage(id)
    if not AngryAssign_Pages[id] then
        return
    end

    local wasDisplayed = AngryAssign_State.displayed == id
    self:RemovePageRecord(id)
    if self.window and self:SelectedId() == id then
        self:SetSelectedId(nil)
        self:UpdateSelected(true)
    end
    if wasDisplayed then
        self:ClearDisplayed(true)
    else
        self:RefreshDisplayedPageAfterHierarchyMutation()
    end
    self:UpdateTree()
end

--- Creates a category.
-- @tparam string|table nameOrFrame Category name text or popup/editbox frame.
-- @treturn boolean ok
-- @treturn string|nil err Error message on failure.
-- @treturn number|nil id New category id on success.
function AngryEra:CreateCategory(nameOrFrame)
    -- Validate and Clean Input using your new helper
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then
        return false, err
    end

    -- Generate ID and Save
    local category = self:NewLocalCategoryRecord({ Name = name })
    local id = category.Id
    AngryAssign_Categories[id] = category

    if AngryAssign_State.tree.groups then
        AngryAssign_State.tree.groups[-id] = true
    end
    self:UpdateTree()
    self:RefreshDisplayedPageAfterHierarchyMutation()

    return true, nil, id
end

--- Renames a category.
-- @tparam number id Category id.
-- @tparam string|table nameOrFrame New name text or popup/editbox frame.
-- @treturn boolean ok
-- @treturn string|nil err Error message when rename fails.
function AngryEra:RenameCategory(id, nameOrFrame)
    local cat = self:GetCat(id)
    if not cat then
        return false, "Category not found."
    end
    if not self:CanEditEntityLocally(cat) then
        return false, "Permission denied."
    end

    -- Use the helper to validate input (Consistency with CreatePage/RenamePage)
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then
        return false, err
    end

    if cat.Name == name then
        return true
    end

    cat.Name = name
    self:UpdateTree()
    self:RefreshDisplayedPageAfterHierarchyMutation()

    return true
end

--- Deletes a category but keeps its descendants by moving them upward.
-- @tparam number id Category id.
function AngryEra:DeleteCategory(id)
    local cat = self:GetCat(id)
    if not cat then
        return
    end

    local selectedId = self:SelectedId()

    for _, c in pairs(AngryAssign_Categories) do
        if cat.Id == c.CategoryId then
            c.CategoryId = cat.CategoryId
        end
    end

    for _, p in pairs(AngryAssign_Pages) do
        if cat.Id == p.CategoryId then
            p.CategoryId = cat.CategoryId
        end
    end

    -- Remove the expanded/collapsed state for this category
    if AngryAssign_State.tree.groups then
        AngryAssign_State.tree.groups[-id] = nil
    end

    self:RemoveCategoryRecord(id)

    self:UpdateTree()
    self:SetSelectedId(selectedId)
    self:RefreshDisplayedPageAfterHierarchyMutation()
end

--- Deletes a category and all descendants.
-- @tparam number id Category id.
function AngryEra:DeleteCategoryAndChildren(id)
    local cat = self:GetCat(id)
    if not cat then
        return
    end

    local selectedId = self:SelectedId()

    local deleted = self:DeleteCategoryChildren(id, true)
    if not deleted then
        return false
    end

    if AngryAssign_State.tree.groups then
        AngryAssign_State.tree.groups[-id] = nil
    end

    self:RemoveCategoryRecord(id)

    self:UpdateTree()
    self:SetSelectedId(selectedId)
    self:RefreshDisplayedPageAfterHierarchyMutation()
    return true
end

--- Assigns a page/category into a category (or toggles back to root).
-- @tparam number entryId Positive for page id, negative for category id.
-- @tparam number parentId Target category id.
function AngryEra:AssignCategory(entryId, parentId)
    local page, cat
    if entryId > 0 then
        page = self:Get(entryId)
    else
        cat = self:GetCat(-entryId)
    end
    local parent = self:GetCat(parentId)
    if not (page or cat) or not parent then
        return
    end

    if page then
        if page.CategoryId == parentId then
            page.CategoryId = nil
        else
            page.CategoryId = parentId
        end
    end

    if cat then
        if cat.CategoryId == parentId then
            cat.CategoryId = nil
        else
            if IsCategoryDescendant(parentId, cat.Id) then
                self:Print("Cannot move into self.")
                return
            end
            cat.CategoryId = parentId
        end
    end

    local selectedId = self:SelectedId()
    self:UpdateTree()
    if selectedId == entryId then
        self:SetSelectedId(selectedId)
    end
    self:RefreshDisplayedPageAfterHierarchyMutation()
end

--- Updates a page's contents, history, hash, and sync state.
-- @tparam number id Page id.
-- @tparam string value New page content.
function AngryEra:UpdateContents(id, value)
    local page = self:Get(id)
    if not page then
        return
    end
    if not self:CanEditEntityLocally(page) then
        return
    end

    local new_content = value:gsub("^%s+", ""):gsub("%s+$", "")
    local contents_updated = new_content ~= page.Contents

    if contents_updated then
        self:PushHistory(page, page.Contents, "Local")
    end

    page.Contents = new_content
    page.Backup = new_content
    page.Updated = time()
    page.UpdateId = self:Hash(page.Name, page.Contents, page.Vars)

    local published, publishResult, activatedLocally = PublishPageRevision(self, id)
    ReportFailedDisplayPublish(self, id, published, publishResult, activatedLocally)
    self:UpdateSelected(true)
    if AngryAssign_State.displayed == id then
        self:UpdateDisplayed()
        if activatedLocally == true then
            self:ShowDisplay()
            if contents_updated then
                self:DisplayUpdateNotification()
            end
        end
    end
end

function AngryEra:PushHistory(page, content, author)
    if not page or not content or content == "" then
        return
    end
    if not page.History then
        page.History = {}
    end

    -- Avoid duplicate consecutive entries
    if #page.History > 0 and page.History[1].content == content then
        return
    end

    table.insert(page.History, 1, {
        timestamp = time(),
        content = content,
        author = author or "Unknown",
    })

    -- Cap history size (e.g. 10)
    while #page.History > 10 do
        table.remove(page.History)
    end
end

function AngryEra:CreateBackup()
    for _, page in pairs(AngryAssign_Pages) do
        page.Backup = page.Contents
    end
    self:UpdateSelected()
end

--- Clears the current local display and optionally publishes one shared clear.
-- @tparam[opt=false] boolean publish Publish `DISPLAY { Displayed = false }` when authorized.
-- @treturn boolean ok
-- @treturn string|nil errorCode
function AngryEra:ClearDisplayed(publish)
    if type(self.CancelAutoAdvancePublishRetry) == "function" then
        self:CancelAutoAdvancePublishRetry()
    end
    local wasDisplayed = AngryAssign_State.displayed ~= nil
    AngryAssign_State.displayed = nil

    local cleared, clearError
    if type(self.ClearActiveDisplayReference) == "function" then
        cleared, clearError = self:ClearActiveDisplayReference()
    else
        cleared, clearError = false, "active-page-runtime-unavailable"
    end

    local published = true
    local publishError
    if
        publish == true
        and wasDisplayed
        and type(self.CanLocalPlayerPublish) == "function"
        and self:CanLocalPlayerPublish("display")
    then
        published, publishError = self:SendDisplay(nil, true)
    end

    self:UpdateDisplayed()
    self:UpdateTree()
    if cleared ~= true then
        return false, clearError or "active-display-clear-failed"
    end
    if published ~= true then
        return false, publishError
    end
    return true
end
