-- -------------------------------------------------------------------------------
-- Angry Era: modules/encounters.lua
--
-- Kill-driven page advancement. After a successful ENCOUNTER_END the raid
-- leader's client advances the display to the next page so the upcoming
-- assignments are visible ahead of the pull. Wipes never advance.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local variables = AngryEra.utils.variables
local helpers = AngryEra.utils.helpers
local CompareIndexedEntries = helpers.CompareIndexedEntries

if not variables or type(variables.PartitionResolvedVariables) ~= "function" then
    error("AngryEra variable helpers must load before encounter handling")
end

local schema = AngryEra.sync and AngryEra.sync.schema
local MAX_SEQUENCE_PAGES = schema and schema.LIMITS and schema.LIMITS.Order or 512
local MAX_BINDING_CANDIDATES = 64
local MAX_SEQUENCE_METADATA_WORK_BYTES = 256 * 1024
local AUTO_ADVANCE_RETRY_DELAY = 2
local AUTO_ADVANCE_MAX_RETRIES = 2

local function IsPlainTable(value)
    return type(value) == "table"
end

local function GetMetaValue(meta, canonicalKey)
    if not IsPlainTable(meta) then
        return nil
    end
    if rawget(meta, canonicalKey) ~= nil then
        return rawget(meta, canonicalKey)
    end
    for key, value in pairs(meta) do
        if type(key) == "string" and key:upper() == canonicalKey then
            return value
        end
    end
    return nil
end

local function IsTruthyFlag(value)
    return value == true or value == 1 or (type(value) == "string" and value:lower() == "true")
end

local function NormalizedName(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value:lower()
end

local function MatchesEncounterId(meta, encounterId)
    if encounterId == nil then
        return false
    end
    local value = GetMetaValue(meta, "ENCOUNTERID")
    if value == nil then
        return false
    end
    return value == encounterId or tonumber(value) == encounterId
end

local function MatchesEncounterName(meta, pageName, nameTarget)
    if nameTarget == nil then
        return false
    end
    if NormalizedName(GetMetaValue(meta, "ENCOUNTER")) == nameTarget then
        return true
    end
    return NormalizedName(pageName) == nameTarget
end

local function PageIsLocallyOwned(page)
    local syncId = rawget(page, "SyncId")
    local ownerId = rawget(page, "OwnerId")
    if syncId == nil and ownerId == nil then
        return true
    end
    if type(syncId) ~= "string" or type(ownerId) ~= "string" then
        return false
    end

    local meta = AngryAssign_Meta
    if not IsPlainTable(meta) or type(meta.InstallationId) ~= "string" then
        return false
    end
    if ownerId == meta.InstallationId then
        return true
    end

    local localState = IsPlainTable(meta.EntityLocal) and rawget(meta.EntityLocal, syncId) or nil
    return IsPlainTable(localState) and localState.OwnedLocally == true
end

local function CompareSequencePages(left, right)
    if CompareIndexedEntries(left, right) then
        return true
    end
    if CompareIndexedEntries(right, left) then
        return false
    end
    return left.Id < right.Id
end

local function ResolveDisplayedSnapshot(self)
    if type(self.GetDisplayedNote) ~= "function" then
        return nil, nil, nil, "display-snapshot-unavailable"
    end

    local snapshotOk, note = pcall(self.GetDisplayedNote, self)
    if not snapshotOk or not IsPlainTable(note) or not IsPlainTable(note.Meta) then
        return nil, nil, nil, "display-snapshot-unavailable"
    end
    if not IsPlainTable(AngryAssign_State) or not IsPlainTable(AngryAssign_Pages) then
        return nil, nil, nil, "storage-unavailable"
    end

    local displayedId = rawget(AngryAssign_State, "displayed")
    local page = type(displayedId) == "number" and rawget(AngryAssign_Pages, displayedId) or nil
    if
        not IsPlainTable(page)
        or note.LocalId ~= displayedId
        or (note.SyncId ~= nil and rawget(page, "SyncId") ~= note.SyncId)
    then
        return nil, nil, nil, "display-snapshot-stale"
    end

    if
        (note.Revision == nil) ~= (note.RevisionId == nil)
        or (note.RevisionId == nil) ~= (note.ContextRevisionId == nil)
    then
        return nil, nil, nil, "display-snapshot-stale"
    end
    if note.RevisionId ~= nil or note.ContextRevisionId ~= nil then
        if type(self.GetActiveDisplayReference) ~= "function" then
            return nil, nil, nil, "display-snapshot-stale"
        end
        local referenceOk, reference = pcall(self.GetActiveDisplayReference, self)
        if
            not referenceOk
            or not IsPlainTable(reference)
            or reference.SyncId ~= note.SyncId
            or reference.Revision ~= note.Revision
            or reference.RevisionId ~= note.RevisionId
            or reference.ContextRevisionId ~= note.ContextRevisionId
        then
            return nil, nil, nil, "display-snapshot-stale"
        end
    end

    local activeContext
    if note.Revision ~= nil and note.RevisionId ~= nil and note.ContextRevisionId ~= nil then
        if type(self.GetActivePageRenderContext) ~= "function" then
            return nil, nil, nil, "display-snapshot-stale"
        end
        local contextOk
        contextOk, activeContext = pcall(
            self.GetActivePageRenderContext,
            self,
            note.SyncId,
            note.Revision,
            note.RevisionId,
            note.ContextRevisionId
        )
        if
            not contextOk
            or not IsPlainTable(activeContext)
            or not IsPlainTable(activeContext.Page)
            or activeContext.Page.SyncId ~= note.SyncId
            or not IsPlainTable(activeContext.AncestorVariableLayers)
        then
            return nil, nil, nil, "display-snapshot-stale"
        end
    end

    return note, page, activeContext
end

local function BuildLocalSequence(displayedPage, displayedNote, activeContext)
    if not PageIsLocallyOwned(displayedPage) then
        return nil, nil, nil, "display-sequence-unavailable"
    end

    local categoryId = rawget(displayedPage, "CategoryId")
    local category = type(categoryId) == "number"
            and IsPlainTable(AngryAssign_Categories)
            and rawget(AngryAssign_Categories, categoryId)
        or nil
    if not IsPlainTable(category) then
        return nil, nil, nil, "display-sequence-unavailable"
    end

    local categorySyncId = rawget(category, "SyncId")
    if
        (displayedNote.CategorySyncId ~= nil and categorySyncId ~= displayedNote.CategorySyncId)
        or (displayedNote.SyncId ~= nil and displayedNote.CategorySyncId ~= categorySyncId)
    then
        return nil, nil, nil, "display-sequence-stale"
    end

    local chain, chainError = variables.CollectCategoryChain(AngryAssign_Categories, categoryId)
    if not chain then
        return nil, nil, nil, chainError or "display-sequence-invalid"
    end
    local layers
    if activeContext ~= nil then
        layers = activeContext.AncestorVariableLayers
        if #layers > #chain then
            return nil, nil, nil, "display-sequence-stale"
        end
        local chainOffset = #chain - #layers
        for index, layer in ipairs(layers) do
            if
                not IsPlainTable(layer)
                or type(layer.SyncId) ~= "string"
                or not IsPlainTable(chain[chainOffset + index])
                or chain[chainOffset + index].SyncId ~= layer.SyncId
            then
                return nil, nil, nil, "display-sequence-stale"
            end
        end
    else
        local layerError
        layers, layerError = variables.BuildAncestorVariableLayers(chain)
        if not layers then
            return nil, nil, nil, layerError or "display-sequence-invalid"
        end
    end

    local ancestorBytes = 0
    for _, layer in ipairs(layers) do
        ancestorBytes = ancestorBytes + #(type(layer.Vars) == "string" and layer.Vars or "")
    end

    local siblings = {}
    for id, page in pairs(AngryAssign_Pages) do
        if IsPlainTable(page) and rawget(page, "CategoryId") == categoryId then
            if type(id) ~= "number" or id < 1 or id % 1 ~= 0 or rawget(page, "Id") ~= id then
                return nil, nil, nil, "display-sequence-invalid"
            end
            if not PageIsLocallyOwned(page) then
                return nil, nil, nil, "display-sequence-unavailable"
            end
            siblings[#siblings + 1] = page
            if #siblings > MAX_SEQUENCE_PAGES then
                return nil, nil, nil, "display-sequence-too-large"
            end
        end
    end
    table.sort(siblings, CompareSequencePages)

    return siblings, layers, ancestorBytes
end

local function ResolveCandidateMeta(layers, page)
    local merged, mergeError = variables.MergeVariableLayers(layers, rawget(page, "Vars"))
    if not merged then
        return nil, mergeError or "candidate-metadata-invalid"
    end
    local _, meta, partitionError = variables.PartitionResolvedVariables(merged)
    if not meta then
        return nil, partitionError or "candidate-metadata-invalid"
    end
    return meta
end

local function FindAnchorPage(encounterId, encounterName, displayedPage, displayedNote, siblings, layers, ancestorBytes)
    local nameTarget = NormalizedName(encounterName)
    if
        MatchesEncounterId(displayedNote.Meta, encounterId)
        or MatchesEncounterName(displayedNote.Meta, displayedNote.Name or displayedPage.Name, nameTarget)
    then
        return displayedPage, displayedNote.Meta
    end
    if #siblings > MAX_BINDING_CANDIDATES then
        return nil, nil, "display-sequence-search-too-large"
    end

    local metadataWorkBytes = 0
    for _, page in ipairs(siblings) do
        if page ~= displayedPage then
            metadataWorkBytes = metadataWorkBytes
                + ancestorBytes
                + #(type(rawget(page, "Vars")) == "string" and rawget(page, "Vars") or "")
            if metadataWorkBytes > MAX_SEQUENCE_METADATA_WORK_BYTES then
                return nil, nil, "display-sequence-metadata-work-exceeded"
            end
        end
    end

    local idMatches = {}
    local nameMatches = {}
    local metaByPage = {}
    for _, page in ipairs(siblings) do
        local meta = displayedNote.Meta
        if page ~= displayedPage then
            local metaError
            meta, metaError = ResolveCandidateMeta(layers, page)
            if not meta then
                return nil, nil, metaError
            end
        end
        metaByPage[page] = meta
        if MatchesEncounterId(meta, encounterId) then
            idMatches[#idMatches + 1] = page
        end
        local pageName = page == displayedPage and displayedNote.Name or page.Name
        if MatchesEncounterName(meta, pageName, nameTarget) then
            nameMatches[#nameMatches + 1] = page
        end
    end

    if #idMatches > 1 then
        return nil, nil, "ambiguous-encounter-id"
    end
    if #idMatches == 1 then
        return idMatches[1], metaByPage[idMatches[1]]
    end
    if #nameMatches > 1 then
        return nil, nil, "ambiguous-encounter-name"
    end
    if #nameMatches == 1 then
        return nameMatches[1], metaByPage[nameMatches[1]]
    end
    return displayedPage, displayedNote.Meta
end

local function FindNextSibling(anchor, siblings)
    for index, page in ipairs(siblings) do
        if page == anchor or (page.Id ~= nil and page.Id == anchor.Id) then
            return siblings[index + 1]
        end
    end
    return nil
end

local function ReportAutoAdvance(self, message)
    if type(self.Print) ~= "function" then
        return
    end
    local red = type(RED_FONT_COLOR_CODE) == "string" and RED_FONT_COLOR_CODE or ""
    local reset = red ~= "" and "|r" or ""
    self:Print(red .. message .. reset)
end

local function ScheduleAutoAdvanceRetry(self, retry)
    if type(self.ScheduleTimer) ~= "function" then
        return false
    end
    local scheduled, timer = pcall(self.ScheduleTimer, self, "RetryAutoAdvanceDisplay", AUTO_ADVANCE_RETRY_DELAY, retry)
    if not scheduled or timer == nil then
        return false
    end
    retry.Timer = timer
    return true
end

--- Cancels a pending auto-advance display-publication retry.
-- @treturn boolean cancelled
function AngryEra:CancelAutoAdvancePublishRetry()
    local retry = self._autoAdvancePublishRetry
    if not IsPlainTable(retry) then
        return false
    end
    self._autoAdvancePublishRetry = nil
    if retry.Timer ~= nil and type(self.CancelTimer) == "function" then
        pcall(self.CancelTimer, self, retry.Timer)
    end
    retry.Timer = nil
    return true
end

local function BeginAutoAdvanceRetry(self, pageId, publicationError)
    self:CancelAutoAdvancePublishRetry()
    local retry = {
        PageId = pageId,
        Attempts = 0,
    }
    self._autoAdvancePublishRetry = retry
    if not ScheduleAutoAdvanceRetry(self, retry) then
        self._autoAdvancePublishRetry = nil
        ReportAutoAdvance(
            self,
            "Auto-advance displayed locally but could not publish it: " .. tostring(publicationError)
        )
        return false
    end
    ReportAutoAdvance(
        self,
        "Auto-advance displayed locally but publication failed; retrying: " .. tostring(publicationError)
    )
    return true
end

--- Retries only the shared publication for an already activated auto-advance.
-- The retry is abandoned when another display replaces the target or the
-- client no longer has leader authority.
-- @tparam table retry Opaque retry state supplied by AceTimer.
function AngryEra:RetryAutoAdvanceDisplay(retry)
    if self._autoAdvancePublishRetry ~= retry or not IsPlainTable(retry) then
        return false, "retry-cancelled"
    end
    retry.Timer = nil
    if
        not IsPlainTable(AngryAssign_State)
        or AngryAssign_State.displayed ~= retry.PageId
        or ((IsInRaid() or IsInGroup()) and not self:IsPlayerRaidLeader())
    then
        self:CancelAutoAdvancePublishRetry()
        return false, "retry-cancelled"
    end

    retry.Attempts = retry.Attempts + 1
    local displayed, displayError, published, publicationResult = self:DisplayPage(retry.PageId, {
        AutoAdvanceRetry = retry,
        ForcePublication = true,
    })
    if displayed ~= true then
        self:CancelAutoAdvancePublishRetry()
        ReportAutoAdvance(self, "Auto-advance publication retry failed: " .. tostring(displayError))
        return false, "display-failed"
    end
    if published == true then
        self._autoAdvancePublishRetry = nil
        return true, retry.PageId
    end
    if retry.Attempts >= AUTO_ADVANCE_MAX_RETRIES or not ScheduleAutoAdvanceRetry(self, retry) then
        self:CancelAutoAdvancePublishRetry()
        ReportAutoAdvance(
            self,
            "Auto-advance remains local after publication retries failed: " .. tostring(publicationResult)
        )
        return false, "display-publish-failed"
    end
    return false, "display-publish-retrying"
end

--- Advances the display to the page after the defeated encounter's page.
-- The exact displayed-note snapshot is authoritative for the displayed page's
-- metadata. Encounter fallback search is restricted to a bounded, locally
-- owned sibling sequence; remote-owned private placement is never inferred.
-- @tparam number|nil encounterId Defeated encounter id.
-- @tparam string|nil encounterName Defeated encounter name.
-- @treturn boolean advanced
-- @treturn number|string nextPageIdOrReason
function AngryEra:AdvanceDisplayedPageAfterEncounter(encounterId, encounterName)
    if type(AngryAssign_Pages) ~= "table" or type(AngryAssign_State) ~= "table" then
        return false, "storage-unavailable"
    end

    local displayedNote, displayedPage, activeContext, snapshotError = ResolveDisplayedSnapshot(self)
    if not displayedNote then
        return false, snapshotError
    end

    local siblings, layers, ancestorBytes, sequenceError =
        BuildLocalSequence(displayedPage, displayedNote, activeContext)
    if not siblings then
        return false, sequenceError
    end

    local anchor, meta, anchorError =
        FindAnchorPage(encounterId, encounterName, displayedPage, displayedNote, siblings, layers, ancestorBytes)
    if not anchor then
        return false, anchorError or "no-anchor-page"
    end
    if not IsTruthyFlag(GetMetaValue(meta, "AUTOADVANCE")) then
        return false, "auto-advance-disabled"
    end

    local nextPage = FindNextSibling(anchor, siblings)
    if not nextPage then
        return false, "no-next-page"
    end
    if AngryAssign_State.displayed == nextPage.Id then
        return false, "already-displayed"
    end

    local displayed, _, published, publicationResult = self:DisplayPage(nextPage.Id, { ForcePublication = true })
    if displayed ~= true then
        return false, "display-failed"
    end
    if published ~= true then
        if not IsInRaid() and not IsInGroup() then
            return true, nextPage.Id
        end
        if BeginAutoAdvanceRetry(self, nextPage.Id, publicationResult) then
            return false, "display-publish-retrying"
        end
        return false, "display-publish-failed"
    end
    return true, nextPage.Id
end

--- ENCOUNTER_END handler: kills advance, wipes never do.
-- Only the raid leader drives shared advancement; solo players may advance
-- their own display while previewing.
function AngryEra:ENCOUNTER_END(_, encounterId, encounterName, _, _, success)
    if success ~= 1 and success ~= true then
        return false, "encounter-not-defeated"
    end
    if (IsInRaid() or IsInGroup()) and not self:IsPlayerRaidLeader() then
        return false, "not-raid-leader"
    end
    return self:AdvanceDisplayedPageAfterEncounter(encounterId, encounterName)
end
