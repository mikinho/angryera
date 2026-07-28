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
local syncSchema = AngryEra.sync and AngryEra.sync.schema
local editableLimits = syncSchema and syncSchema.LIMITS
    or {
        HierarchyDepth = 32,
        NameBytes = 100,
        ContentsBytes = 20000,
        VarsBytes = 5000,
    }

local EDITABLE_ENTITY_ERRORS = {
    ["invalid-entity"] = "The page or category data is invalid.",
    ["invalid-entity-kind"] = "The page or category type is invalid.",
    ["invalid-name"] = ("Names must be 1-%d bytes, trimmed, and contain no control characters."):format(
        editableLimits.NameBytes
    ),
    ["invalid-contents"] = ("Page contents cannot exceed %d bytes."):format(editableLimits.ContentsBytes),
    ["invalid-vars"] = ("Variables and metadata cannot exceed %d bytes."):format(editableLimits.VarsBytes),
}

local function ContainsControlByte(value)
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 32 or byte == 127 then
            return true
        end
    end
    return false
end

local function FallbackEditableEntityValidation(kind, fields)
    if kind ~= "page" and kind ~= "category" then
        return false, "invalid-entity-kind"
    end
    if type(fields) ~= "table" then
        return false, "invalid-entity"
    end
    local name = fields.Name
    if
        type(name) ~= "string"
        or name == ""
        or #name > editableLimits.NameBytes
        or name ~= name:match("^%s*(.-)%s*$")
        or ContainsControlByte(name)
    then
        return false, "invalid-name"
    end
    if type(fields.Vars) ~= "string" or #fields.Vars > editableLimits.VarsBytes then
        return false, "invalid-vars"
    end
    if kind == "page" and (type(fields.Contents) ~= "string" or #fields.Contents > editableLimits.ContentsBytes) then
        return false, "invalid-contents"
    end
    return true
end

--- Validates local editable fields against the same limits used on the wire.
-- Callers use this before mutating SavedVariables so a page cannot appear to
-- save successfully and then fail only when it is displayed.
-- @tparam string kind `"page"` or `"category"`.
-- @tparam table fields Name, Vars, and optional Contents.
-- @treturn boolean valid
-- @treturn string|nil userError
-- @treturn string|nil errorCode
function AngryEra:ValidateLocalEntityFields(kind, fields)
    local validator = syncSchema and syncSchema.ValidateEditableEntityFields
    local valid, errorCode
    if type(validator) == "function" then
        valid, errorCode = validator(kind, fields)
    else
        valid, errorCode = FallbackEditableEntityValidation(kind, fields)
    end
    if valid then
        return true
    end
    return false, EDITABLE_ENTITY_ERRORS[errorCode] or "The page or category data is invalid.", errorCode
end

local function CategoryDepth(categoryId)
    local depth = 0
    local visited = {}
    while categoryId ~= nil do
        if visited[categoryId] then
            return nil, "category-cycle"
        end
        visited[categoryId] = true
        local category = AngryAssign_Categories[categoryId]
        if type(category) ~= "table" then
            return nil, "missing-category"
        end
        depth = depth + 1
        categoryId = category.CategoryId
    end
    return depth
end

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

local pendingSharedPageDraft

local function SharedPageDraftMatches(draft, page, reference)
    return type(draft) == "table"
        and draft.SyncId == page.SyncId
        and draft.BaseRevision == page.Revision
        and draft.BaseRevisionId == reference.RevisionId
        and draft.BaseContextRevisionId == reference.ContextRevisionId
end

local function DesiredPageState(page)
    return {
        Name = type(page.Name) == "string" and page.Name or "",
        Vars = type(page.Vars) == "string" and page.Vars or "",
        Contents = type(page.Contents) == "string" and page.Contents or "",
    }
end

local function CopyDesiredPageState(desired)
    if
        type(desired) ~= "table"
        or type(desired.Name) ~= "string"
        or type(desired.Vars) ~= "string"
        or type(desired.Contents) ~= "string"
    then
        return nil
    end
    return {
        Name = desired.Name,
        Vars = desired.Vars,
        Contents = desired.Contents,
    }
end

local function RecoverableConflictDesired(self, page)
    local conflict = type(self) == "table" and rawget(self, "syncDraftConflict") or nil
    if type(conflict) ~= "table" or conflict.SyncId ~= page.SyncId then
        return nil
    end
    return CopyDesiredPageState(conflict.Desired)
end

local function PendingDesiredForPage(page)
    if type(pendingSharedPageDraft) ~= "table" or pendingSharedPageDraft.SyncId ~= page.SyncId then
        return nil
    end
    return CopyDesiredPageState(pendingSharedPageDraft.Desired)
end

local function ExactDisplayedPageReference(self, id, page)
    local state = type(AngryAssign_State) == "table" and AngryAssign_State or nil
    if not state or rawget(state, "displayed") ~= id or type(page.SyncId) ~= "string" then
        return nil, "shared-page-not-active"
    end
    if type(self.GetActiveDisplayReference) ~= "function" then
        return nil, "active-display-reference-unavailable"
    end

    local referenceChecked, reference = pcall(self.GetActiveDisplayReference, self)
    if
        not referenceChecked
        or type(reference) ~= "table"
        or reference.SyncId ~= page.SyncId
        or reference.Revision ~= page.Revision
        or reference.RevisionId ~= page.RevisionId
        or type(reference.ContextRevisionId) ~= "string"
    then
        return nil, "shared-page-display-reference-mismatch"
    end
    return reference
end

local function RetainedDesiredForDirectMutation(self, id, page)
    local reference = ExactDisplayedPageReference(self, id, page)
    if reference and SharedPageDraftMatches(pendingSharedPageDraft, page, reference) then
        return CopyDesiredPageState(pendingSharedPageDraft.Desired)
    end
    return RecoverableConflictDesired(self, page) or PendingDesiredForPage(page)
end

local function IsLocallyOwnedPage(self, page)
    if type(self.IsLocallyOwned) ~= "function" then
        return false
    end
    local checked, locallyOwned = pcall(self.IsLocallyOwned, self, page)
    return checked and locallyOwned == true
end

local function IsGrouped()
    local inRaid = type(IsInRaid) == "function" and IsInRaid()
    local inGroup = type(IsInGroup) == "function" and IsInGroup()
    return inRaid == true or inGroup == true
end

local function SubmitSharedPageMutation(self, id, page, changedField, changedValue)
    if type(page.SyncId) ~= "string" then
        return nil, nil, false
    end

    if type(self.CanLocalPlayerPublish) ~= "function" then
        return false, "page-commit-authority-unavailable", true
    end
    local authorityChecked, canCommitPage = pcall(self.CanLocalPlayerPublish, self, "pageUpsert")
    if not authorityChecked then
        return false, "page-commit-authority-check-failed", true
    end
    if canCommitPage == true and IsGrouped() then
        local desired = RetainedDesiredForDirectMutation(self, id, page)
        if desired then
            desired[changedField] = changedValue or ""
        end
        return nil, nil, false, desired
    end

    local reference, routeError = ExactDisplayedPageReference(self, id, page)
    if not reference then
        -- Locally owned background pages remain ordinary local library edits.
        -- Remote cached pages, and any active synchronized page whose exact
        -- tuple is unavailable, must never fall through to in-place mutation.
        if
            IsLocallyOwnedPage(self, page)
            and (type(AngryAssign_State) ~= "table" or rawget(AngryAssign_State, "displayed") ~= id)
        then
            return nil, nil, false
        end
        return false, routeError, true
    end

    if type(self.SubmitSharedPageChangeProposal) ~= "function" then
        return false, "shared-page-change-proposal-unavailable", true
    end

    local desired
    if SharedPageDraftMatches(pendingSharedPageDraft, page, reference) then
        desired = CopyDesiredPageState(pendingSharedPageDraft.Desired)
    end
    -- A rejected or losing proposal remains recoverable after the canonical
    -- tuple advances. Merge the retained editor state onto the new exact base
    -- instead of silently replacing untouched fields with canonical values.
    desired = desired or RecoverableConflictDesired(self, page) or DesiredPageState(page)
    desired[changedField] = changedValue or ""

    local proposal = {
        LocalId = id,
        SyncId = page.SyncId,
        BaseRevision = page.Revision,
        BaseRevisionId = reference.RevisionId,
        BaseContextRevisionId = reference.ContextRevisionId,
        Desired = {
            Name = desired.Name,
            Vars = desired.Vars,
            Contents = desired.Contents,
        },
        ChangedField = changedField,
    }
    local called, submitted, result = pcall(self.SubmitSharedPageChangeProposal, self, proposal)
    if not called then
        return false, "shared-page-change-proposal-error", true
    end
    if submitted ~= true then
        return false, result or "shared-page-change-proposal-failed", true
    end

    pendingSharedPageDraft = {
        SyncId = proposal.SyncId,
        BaseRevision = proposal.BaseRevision,
        BaseRevisionId = proposal.BaseRevisionId,
        BaseContextRevisionId = proposal.BaseContextRevisionId,
        Desired = {
            Name = desired.Name,
            Vars = desired.Vars,
            Contents = desired.Contents,
        },
    }
    return true, result, true
end

local function CanonicalPageMatchesDesired(page, desired)
    local canonical = DesiredPageState(page)
    return canonical.Name == desired.Name and canonical.Vars == desired.Vars and canonical.Contents == desired.Contents
end

local function ClearMatchingRetainedDesired(self, syncId)
    if type(pendingSharedPageDraft) == "table" and pendingSharedPageDraft.SyncId == syncId then
        pendingSharedPageDraft = nil
    end
    local conflict = type(self) == "table" and rawget(self, "syncDraftConflict") or nil
    if type(conflict) ~= "table" or conflict.SyncId ~= syncId then
        return
    end
    if type(self.ClearSyncDraftConflict) == "function" then
        pcall(self.ClearSyncDraftConflict, self, syncId)
    end
    if type(rawget(self, "syncDraftConflict")) == "table" and self.syncDraftConflict.SyncId == syncId then
        self.syncDraftConflict = nil
    end
end

local function PreserveRetainedDesiredAfterDirectMutation(self, id, page, desired)
    desired = CopyDesiredPageState(desired)
    if not desired then
        return false
    end
    if CanonicalPageMatchesDesired(page, desired) then
        ClearMatchingRetainedDesired(self, page.SyncId)
        return false
    end

    local conflict = type(self) == "table" and rawget(self, "syncDraftConflict") or nil
    if type(conflict) == "table" and conflict.SyncId == page.SyncId then
        conflict.Desired = CopyDesiredPageState(desired)
    end

    local reference = ExactDisplayedPageReference(self, id, page)
    if reference then
        pendingSharedPageDraft = {
            SyncId = page.SyncId,
            BaseRevision = page.Revision,
            BaseRevisionId = reference.RevisionId,
            BaseContextRevisionId = reference.ContextRevisionId,
            Desired = CopyDesiredPageState(desired),
        }
    elseif type(pendingSharedPageDraft) == "table" and pendingSharedPageDraft.SyncId == page.SyncId then
        pendingSharedPageDraft.Desired = CopyDesiredPageState(desired)
    end
    return true
end

--- Returns a detached desired-state draft for the exact displayed shared page.
-- Pending drafts are tuple-bound. A same-page conflict may carry the losing
-- desired state across a canonical advance and is rebound to the current exact
-- reference so the editor can recover it without reviving a stale base.
-- @tparam number id Local page id.
-- @treturn table|nil draft
function AngryEra:GetSharedPageChangeDraft(id)
    local page = type(AngryAssign_Pages) == "table" and AngryAssign_Pages[id] or nil
    if type(page) ~= "table" then
        return nil
    end
    -- Draft visibility is not role-bound. Exact pending state survives a
    -- promotion; same-SyncId conflict state survives a canonical tuple advance.
    local reference = ExactDisplayedPageReference(self, id, page)
    if not reference then
        return nil
    end
    local desired
    if SharedPageDraftMatches(pendingSharedPageDraft, page, reference) then
        desired = CopyDesiredPageState(pendingSharedPageDraft.Desired)
    end
    desired = desired or RecoverableConflictDesired(self, page)
    if not desired then
        return nil
    end
    return {
        SyncId = page.SyncId,
        BaseRevision = page.Revision,
        BaseRevisionId = reference.RevisionId,
        BaseContextRevisionId = reference.ContextRevisionId,
        Desired = desired,
    }
end

--- Rebinds a queued desired-state draft after an earlier proposal advances the
-- same canonical page. This keeps later content/name/vars edits merged while
-- the next proposal waits for its debounce.
function AngryEra:RebaseSharedPageChangeDraft(id, reference, desired)
    local page = type(AngryAssign_Pages) == "table" and AngryAssign_Pages[id] or nil
    if
        type(page) ~= "table"
        or type(reference) ~= "table"
        or type(desired) ~= "table"
        or page.SyncId ~= reference.SyncId
        or page.Revision ~= reference.Revision
        or page.RevisionId ~= reference.RevisionId
        or type(reference.ContextRevisionId) ~= "string"
        or type(desired.Name) ~= "string"
        or type(desired.Vars) ~= "string"
        or type(desired.Contents) ~= "string"
    then
        return false, "invalid-shared-page-draft-rebase"
    end
    pendingSharedPageDraft = {
        SyncId = reference.SyncId,
        BaseRevision = reference.Revision,
        BaseRevisionId = reference.RevisionId,
        BaseContextRevisionId = reference.ContextRevisionId,
        Desired = {
            Name = desired.Name,
            Vars = desired.Vars,
            Contents = desired.Contents,
        },
    }
    return true
end

--- Clears the local desired-state editor draft without changing canonical data.
-- User-driven clears also cancel any unsent transport-side debounce.
-- @tparam[opt=false] boolean suppressTransportCancel Internal completion path.
-- @treturn boolean cleared
function AngryEra:ClearSharedPageChangeDraft(suppressTransportCancel)
    local cleared = pendingSharedPageDraft ~= nil
    pendingSharedPageDraft = nil
    if suppressTransportCancel ~= true and type(self.CancelSharedPageChangeProposal) == "function" then
        pcall(self.CancelSharedPageChangeProposal, self, "editor-draft-cleared")
    end
    return cleared
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
    local forcePublication = type(options) == "table" and options.ForcePublication == true

    if not self:CanLocalPlayerPublish("display") then
        return
    end

    local published, displayResult, activatedLocally = self:SendDisplay(id, forcePublication)
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
        AngryEra:ShowDisplay(false)
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

    -- Navigation follows saved manual order; local pin sections affect only the
    -- editor tree and must not change encounter progression.
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

    -- First means the first saved manual page, independent of local pin state.
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
    local tree = type(AngryAssign_State) == "table" and AngryAssign_State.tree or nil
    return selectedLastValue(type(tree) == "table" and tree.selected or nil)
end

function AngryEra:SetSelectedId(selectedId)
    local page = AngryAssign_Pages[selectedId]
    if not self.window or not self.window.tree then
        if type(AngryAssign_State) == "table" then
            if type(AngryAssign_State.tree) ~= "table" then
                AngryAssign_State.tree = {}
            end
            if selectedId == nil then
                AngryAssign_State.tree.selected = nil
            end
        end
        return false
    end
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
-- @tparam[opt=""] string initialVars Initial page variables, applied before the first revision is published.
-- @treturn boolean ok
-- @treturn string|nil err Error message on failure.
-- @treturn number|nil id New page id on success.
function AngryEra:CreatePage(nameOrFrame, content, categoryId, index, suppressDisplayRefresh, initialVars)
    -- Validate and Clean Input
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then
        return false, err
    end

    if content ~= nil and type(content) ~= "string" then
        return false, "Page contents must be text."
    end
    if initialVars ~= nil and type(initialVars) ~= "string" then
        return false, "Variables and metadata must be text."
    end
    content = content or ""
    initialVars = initialVars or ""

    local valid, validationError = self:ValidateLocalEntityFields("page", {
        Name = name,
        Contents = content,
        Vars = initialVars,
    })
    if not valid then
        return false, validationError
    end
    if categoryId ~= nil then
        local parentDepth, parentError = CategoryDepth(categoryId)
        if not parentDepth then
            return false,
                parentError == "category-cycle"
                        and "Cannot create the page because the category hierarchy contains a cycle."
                    or "Cannot create the page because its parent category does not exist."
        end
        if parentDepth + 1 > editableLimits.HierarchyDepth then
            return false,
                ("Cannot create the page: category hierarchy cannot exceed %d levels."):format(
                    editableLimits.HierarchyDepth
                )
        end
    end

    -- Original Business Logic
    local page = self:NewLocalPageRecord({
        Updated = time(),
        UpdateId = self:Hash(name, content, initialVars),
        Name = name,
        Contents = content,
        Vars = initialVars,
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
-- @treturn boolean proposed Whether the desired state was submitted without mutating the canonical page.
function AngryEra:RenamePage(id, nameOrFrame)
    -- Check Existence
    local page = self:Get(id)
    if not page then
        return false, "Page not found.", false
    end

    if not self:CanEditEntityLocally(page) then
        return false, "Permission denied.", false
    end

    -- Validate and Clean Input
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then
        return false, err, false
    end
    local valid, validationError = self:ValidateLocalEntityFields("page", {
        Name = name,
        Contents = type(page.Contents) == "string" and page.Contents or "",
        Vars = type(page.Vars) == "string" and page.Vars or "",
    })
    if not valid then
        return false, validationError, false
    end

    local submitted, submitResult, proposed, retainedDesired = SubmitSharedPageMutation(self, id, page, "Name", name)
    if proposed then
        return submitted, submitResult, true
    end

    -- Optimization: Skip if a directly editable name has not changed.
    if page.Name == name then
        PreserveRetainedDesiredAfterDirectMutation(self, id, page, retainedDesired)
        return true, nil, false
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
            self:ShowDisplay(false)
        end
    end
    ReportFailedDisplayPublish(self, id, published, publishResult, activatedLocally)
    PreserveRetainedDesiredAfterDirectMutation(self, id, page, retainedDesired)

    return true, nil, false
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
    local valid, validationError = self:ValidateLocalEntityFields("category", {
        Name = name,
        Vars = "",
    })
    if not valid then
        return false, validationError
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
    local valid, validationError = self:ValidateLocalEntityFields("category", {
        Name = name,
        Vars = type(cat.Vars) == "string" and cat.Vars or "",
    })
    if not valid then
        return false, validationError
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

local function CategorySubtreeHeight(categoryId, path)
    path = path or {}
    if path[categoryId] then
        return nil, "category-cycle"
    end
    path[categoryId] = true
    local maximumChildHeight = 0
    for id, category in pairs(AngryAssign_Categories) do
        if type(category) == "table" and category.CategoryId == categoryId then
            local childHeight, childError = CategorySubtreeHeight(id, path)
            if not childHeight then
                path[categoryId] = nil
                return nil, childError
            end
            maximumChildHeight = math.max(maximumChildHeight, childHeight)
        end
    end
    path[categoryId] = nil
    return maximumChildHeight + 1
end

local function ValidateCategoryMoveDepth(page, category, parentId)
    local parentDepth, parentError = CategoryDepth(parentId)
    if not parentDepth then
        return false, parentError
    end
    if page then
        return parentDepth + 1 <= editableLimits.HierarchyDepth,
            parentDepth + 1 <= editableLimits.HierarchyDepth and nil or "hierarchy-too-deep"
    end
    local subtreeHeight, subtreeError = CategorySubtreeHeight(category.Id)
    if not subtreeHeight then
        return false, subtreeError
    end
    if parentDepth + subtreeHeight > editableLimits.HierarchyDepth then
        return false, "hierarchy-too-deep"
    end
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
        return false, "missing-category"
    end

    if page then
        if page.CategoryId == parentId then
            page.CategoryId = nil
        else
            local validDepth, depthError = ValidateCategoryMoveDepth(page, nil, parentId)
            if not validDepth then
                self:Print(
                    depthError == "hierarchy-too-deep"
                            and ("Cannot move there: category hierarchy cannot exceed %d levels."):format(
                                editableLimits.HierarchyDepth
                            )
                        or "Cannot move there because the category hierarchy is invalid."
                )
                return false, depthError
            end
            page.CategoryId = parentId
        end
    end

    if cat then
        if cat.CategoryId == parentId then
            cat.CategoryId = nil
        else
            if IsCategoryDescendant(parentId, cat.Id) then
                self:Print("Cannot move into self.")
                return false, "category-cycle"
            end
            local validDepth, depthError = ValidateCategoryMoveDepth(nil, cat, parentId)
            if not validDepth then
                self:Print(
                    depthError == "hierarchy-too-deep"
                            and ("Cannot move there: category hierarchy cannot exceed %d levels."):format(
                                editableLimits.HierarchyDepth
                            )
                        or "Cannot move there because the category hierarchy is invalid."
                )
                return false, depthError
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
    return true
end

--- Updates a page's contents, history, hash, and sync state.
-- @tparam number id Page id.
-- @tparam string value New page content.
-- @treturn boolean ok
-- @treturn string|nil resultOrError
-- @treturn boolean proposed Whether the desired state was submitted without mutating the canonical page.
function AngryEra:UpdateContents(id, value)
    local page = self:Get(id)
    if not page then
        return false, "Page not found.", false
    end
    if not self:CanEditEntityLocally(page) then
        return false, "Permission denied.", false
    end
    if type(value) ~= "string" then
        return false, "Page contents must be text.", false
    end

    local new_content = value:gsub("^%s+", ""):gsub("%s+$", "")
    local valid, validationError = self:ValidateLocalEntityFields("page", {
        Name = type(page.Name) == "string" and page.Name or "",
        Contents = new_content,
        Vars = type(page.Vars) == "string" and page.Vars or "",
    })
    if not valid then
        return false, validationError, false
    end
    local contents_updated = new_content ~= page.Contents

    local submitted, submitResult, proposed, retainedDesired =
        SubmitSharedPageMutation(self, id, page, "Contents", new_content)
    if proposed then
        return submitted, submitResult, true
    end

    if contents_updated then
        self:PushHistory(page, page.Contents, "Local")
    end

    page.Contents = new_content
    page.Backup = new_content
    page.Updated = time()
    page.UpdateId = self:Hash(page.Name, page.Contents, page.Vars)

    local published, publishResult, activatedLocally = PublishPageRevision(self, id)
    ReportFailedDisplayPublish(self, id, published, publishResult, activatedLocally)
    local desiredRemains = PreserveRetainedDesiredAfterDirectMutation(self, id, page, retainedDesired)
    self:UpdateSelected(not desiredRemains)
    if AngryAssign_State.displayed == id then
        self:UpdateDisplayed()
        if activatedLocally == true then
            self:ShowDisplay(false)
            if contents_updated then
                self:DisplayUpdateNotification()
            end
        end
    end
    return true, nil, false
end

--- Updates page variables or submits a desired-state proposal for the exact
-- displayed shared page. Category-variable editing remains local hierarchy
-- behavior and does not use this page-specific path.
-- @tparam number id Page id.
-- @tparam string|nil value New page variable text.
-- @treturn boolean ok
-- @treturn string|nil resultOrError
-- @treturn boolean proposed Whether the desired state was submitted without mutating the canonical page.
function AngryEra:UpdatePageVars(id, value)
    local page = self:Get(id)
    if not page then
        return false, "Page not found.", false
    end
    if not self:CanEditEntityLocally(page) then
        return false, "Permission denied.", false
    end
    if value == nil then
        value = ""
    elseif type(value) ~= "string" then
        return false, "Variables and metadata must be text.", false
    end
    local valid, validationError = self:ValidateLocalEntityFields("page", {
        Name = type(page.Name) == "string" and page.Name or "",
        Contents = type(page.Contents) == "string" and page.Contents or "",
        Vars = value,
    })
    if not valid then
        return false, validationError, false
    end

    local submitted, submitResult, proposed, retainedDesired = SubmitSharedPageMutation(self, id, page, "Vars", value)
    if proposed then
        return submitted, submitResult, true
    end

    page.Vars = value
    self:PageUpdated(id)
    PreserveRetainedDesiredAfterDirectMutation(self, id, page, retainedDesired)
    return true, nil, false
end

function AngryEra:PushHistory(page, content, author)
    if not page or not content or content == "" then
        return
    end
    if type(page.History) ~= "table" then
        page.History = {}
    end

    -- Avoid duplicate consecutive entries
    if #page.History > 0 and type(page.History[1]) == "table" and page.History[1].content == content then
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
