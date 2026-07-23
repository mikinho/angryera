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

local function ResolvePageMeta(page)
    local layers = {}
    if page.CategoryId ~= nil and type(AngryAssign_Categories) == "table" then
        local chain = variables.CollectCategoryChain(AngryAssign_Categories, page.CategoryId)
        if chain then
            layers = variables.BuildAncestorVariableLayers(chain) or {}
        end
    end

    local merged = variables.MergeVariableLayers(layers, page.Vars)
    if not merged then
        merged = variables.MergeVariableLayers({}, page.Vars)
    end
    if not merged then
        return {}
    end

    local _, meta = variables.PartitionResolvedVariables(merged)
    return meta or {}
end

local function GetMetaValue(meta, canonicalKey)
    local selectedKey
    for key in pairs(meta) do
        if type(key) == "string" and key:upper() == canonicalKey and (selectedKey == nil or key < selectedKey) then
            selectedKey = key
        end
    end
    if selectedKey == nil then
        return nil
    end
    return meta[selectedKey]
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

local function MatchesEncounterName(meta, page, nameTarget)
    if nameTarget == nil then
        return false
    end
    if NormalizedName(GetMetaValue(meta, "ENCOUNTER")) == nameTarget then
        return true
    end
    return NormalizedName(page.Name) == nameTarget
end

local function FindAnchorPage(encounterId, encounterName, displayedPage, metaByPage)
    local displayedCategoryId = displayedPage and displayedPage.CategoryId or nil
    local nameTarget = NormalizedName(encounterName)

    local idMatch, idMatches, idMatchInDisplayed
    local nameMatch, nameMatches, nameMatchInDisplayed
    for _, page in pairs(AngryAssign_Pages) do
        if type(page) == "table" and page.CategoryId ~= nil then
            local meta = ResolvePageMeta(page)
            metaByPage[page] = meta

            if MatchesEncounterId(meta, encounterId) then
                idMatches = (idMatches or 0) + 1
                idMatch = idMatch or page
                if displayedCategoryId ~= nil and page.CategoryId == displayedCategoryId then
                    idMatchInDisplayed = idMatchInDisplayed or page
                end
            end
            if MatchesEncounterName(meta, page, nameTarget) then
                nameMatches = (nameMatches or 0) + 1
                nameMatch = nameMatch or page
                if displayedCategoryId ~= nil and page.CategoryId == displayedCategoryId then
                    nameMatchInDisplayed = nameMatchInDisplayed or page
                end
            end
        end
    end

    if idMatchInDisplayed then
        return idMatchInDisplayed
    end
    if idMatch and idMatches == 1 then
        return idMatch
    end
    if nameMatchInDisplayed then
        return nameMatchInDisplayed
    end
    if nameMatch and nameMatches == 1 then
        return nameMatch
    end
    if displayedPage and displayedPage.CategoryId ~= nil then
        return displayedPage
    end
    return nil
end

local function FindNextSibling(anchor)
    local siblings = {}
    for _, page in pairs(AngryAssign_Pages) do
        if type(page) == "table" and page.CategoryId == anchor.CategoryId then
            siblings[#siblings + 1] = page
        end
    end
    table.sort(siblings, CompareIndexedEntries)

    for index, page in ipairs(siblings) do
        if page.Id == anchor.Id then
            return siblings[index + 1]
        end
    end
    return nil
end

--- Advances the display to the page after the defeated encounter's page.
-- The anchor resolves `$ENCOUNTERID`, then `$ENCOUNTER`/page-name matches
-- (preferring the displayed page's category), then the displayed page itself.
-- The anchor must opt in through truthy `$AUTOADVANCE` metadata; a page-level
-- `$AUTOADVANCE=false` stops the chain at that boss.
-- @tparam number|nil encounterId Defeated encounter id.
-- @tparam string|nil encounterName Defeated encounter name.
-- @treturn boolean advanced
-- @treturn number|string nextPageIdOrReason
function AngryEra:AdvanceDisplayedPageAfterEncounter(encounterId, encounterName)
    if type(AngryAssign_Pages) ~= "table" or type(AngryAssign_State) ~= "table" then
        return false, "storage-unavailable"
    end

    local displayedPage = AngryAssign_Pages[AngryAssign_State.displayed]
    if displayedPage ~= nil and type(displayedPage) ~= "table" then
        displayedPage = nil
    end

    local metaByPage = {}
    local anchor = FindAnchorPage(encounterId, encounterName, displayedPage, metaByPage)
    if not anchor then
        return false, "no-anchor-page"
    end

    local meta = metaByPage[anchor] or ResolvePageMeta(anchor)
    if not IsTruthyFlag(GetMetaValue(meta, "AUTOADVANCE")) then
        return false, "auto-advance-disabled"
    end

    local nextPage = FindNextSibling(anchor)
    if not nextPage then
        return false, "no-next-page"
    end
    if AngryAssign_State.displayed == nextPage.Id then
        return false, "already-displayed"
    end

    if self:DisplayPage(nextPage.Id) ~= true then
        return false, "display-failed"
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
