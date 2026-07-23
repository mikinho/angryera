-- -------------------------------------------------------------------------------
-- Angry Era: modules/network.lua
--
-- Protocol-v3 active-page publication throttles and group diagnostics.
-- Envelope validation, correlation, and inbound dispatch live in
-- protocol_runtime.lua; canonical page preparation lives in sync/page_runtime.lua.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local helpers = AngryEra.utils.helpers
local EnsureUnitShortName = helpers.EnsureUnitShortName
local PlayerFullName = helpers.PlayerFullName
local IterateGroupMembers = helpers.IterateGroupMembers

local updateFrequency = AngryEra.core.updateFrequency

local pageLastUpdate = {}
local pageTimerId = {}
local displayLastUpdate
local displayTimerId

local function IsGrouped()
    return IsInRaid() or IsInGroup()
end

local function CancelTimer(self, timerId)
    if timerId then
        self:CancelTimer(timerId)
    end
end

local function PreparePage(self, id)
    if type(self.PrepareActivePageUpsert) ~= "function" then
        return nil, "active-page-runtime-unavailable"
    end

    local author = PlayerFullName()
    if type(author) ~= "string" or author == "" then
        return nil, "invalid-local-author"
    end
    return self:PrepareActivePageUpsert(id, {
        UpdatedAt = time(),
        UpdatedBy = author,
    })
end

local function SendPreparedPage(self, id)
    local payload, preparationError = PreparePage(self, id)
    if not payload then
        return false, preparationError
    end

    local sent, result = self:SendProtocolPageUpsert(payload)
    if not sent then
        return false, result
    end
    pageLastUpdate[id] = time()
    return true, payload
end

--- Sends a canonical PAGE_UPSERT with per-page throttling.
-- @tparam number id Local page id.
-- @tparam[opt=false] boolean force Bypass the publication delay.
-- @treturn boolean sentOrScheduled
-- @treturn table|string|nil payloadOrStatus
function AngryEra:SendPage(id, force)
    if not self:CanLocalPlayerPublish("pageUpsert") then
        return false, "unauthorized"
    end

    local now = time()
    local lastUpdate = pageLastUpdate[id]
    if not force and lastUpdate and now - lastUpdate < updateFrequency then
        if not pageTimerId[id] then
            pageTimerId[id] = self:ScheduleTimer("SendPageMessage", updateFrequency - (now - lastUpdate), id)
        end
        return true, "scheduled"
    end

    CancelTimer(self, pageTimerId[id])
    pageTimerId[id] = nil
    return self:SendPageMessage(id)
end

--- Immediately prepares and sends one canonical PAGE_UPSERT.
-- @tparam number id Local page id.
-- @treturn boolean sent
-- @treturn table|string payloadOrError
function AngryEra:SendPageMessage(id)
    pageTimerId[id] = nil
    if not self:CanLocalPlayerPublish("pageUpsert") then
        return false, "unauthorized"
    end
    if not AngryAssign_Pages[id] then
        pageLastUpdate[id] = nil
        return false, "missing-local-page"
    end
    return SendPreparedPage(self, id)
end

--- Publishes an active display selection with throttling.
-- A non-empty selection always sends its exact PAGE_UPSERT first.
-- @tparam[opt] number id Local page id, or nil to clear the shared display.
-- @tparam[opt=false] boolean force Bypass the publication delay.
-- @treturn boolean sentOrScheduled
-- @treturn string|nil messageIdOrStatus
-- @treturn boolean activatedLocally Whether the exact local display state committed.
function AngryEra:SendDisplay(id, force)
    if not self:CanLocalPlayerPublish("display") then
        return false, "unauthorized", false
    end

    local now = time()
    if not force and displayLastUpdate and now - displayLastUpdate < updateFrequency then
        CancelTimer(self, displayTimerId)
        displayTimerId = self:ScheduleTimer("SendDisplayMessage", updateFrequency - (now - displayLastUpdate), id)
        return true, "scheduled", false
    end

    CancelTimer(self, displayTimerId)
    displayTimerId = nil
    return self:SendDisplayMessage(id)
end

--- Immediately sends DISPLAY and, for a selected page, its exact PAGE_UPSERT.
-- @tparam[opt] number id Local page id, or nil to clear the shared display.
-- @treturn boolean sent
-- @treturn string|nil messageIdOrError
-- @treturn boolean activatedLocally Whether the exact local display state committed.
function AngryEra:SendDisplayMessage(id)
    displayTimerId = nil
    if not self:CanLocalPlayerPublish("display") then
        return false, "unauthorized", false
    end

    if
        type(self.BuildActiveDisplayPayload) ~= "function"
        or type(self.ActivatePreparedActiveDisplay) ~= "function"
        or type(self.ClearActiveDisplayReference) ~= "function"
    then
        return false, "active-page-runtime-unavailable", false
    end
    if id ~= nil and not self:CanLocalPlayerPublish("pageUpsert") then
        return false, "unauthorized", false
    end

    local author = PlayerFullName()
    if type(author) ~= "string" or author == "" then
        return false, "invalid-local-author", false
    end
    local displayPayload, pagePayloadOrError = self:BuildActiveDisplayPayload(id, {
        UpdatedAt = time(),
        UpdatedBy = author,
    })
    if not displayPayload then
        return false, pagePayloadOrError, false
    end

    local pagePayload = pagePayloadOrError
    local activated, activationError
    if id == nil then
        activated, activationError = self:ClearActiveDisplayReference()
    else
        activated, activationError = self:ActivatePreparedActiveDisplay(displayPayload, pagePayload)
    end
    if activated ~= true then
        return false, activationError or "active-display-activation-failed", false
    end

    if pagePayload then
        CancelTimer(self, pageTimerId[id])
        pageTimerId[id] = nil
        local pageSent, pageResult = self:SendProtocolPageUpsert(pagePayload)
        if not pageSent then
            return false, pageResult, true
        end
        pageLastUpdate[id] = time()
    end

    local sent, result = self:SendProtocolDisplay(displayPayload)
    if sent then
        displayLastUpdate = time()
    end
    return sent, result, true
end

--- Requests the current display from the online raid/party leader.
-- @treturn boolean sent
-- @treturn string|nil messageIdOrError
function AngryEra:SendRequestDisplay()
    if not IsGrouped() then
        return false, "not-grouped"
    end

    local target = self:GetRaidLeader(true)
    if not target then
        return false, "leader-unavailable"
    end
    if target == PlayerFullName() then
        return false, "local-player-is-leader"
    end
    return self:SendProtocolDisplayRequest(target)
end

--- Returns the current raid or party leader full name.
-- @tparam[opt=false] boolean onlineOnly Require the leader to be online.
-- @treturn string|nil leaderName
function AngryEra:GetRaidLeader(onlineOnly)
    local leaderName
    IterateGroupMembers(function(_, fullName, rank, _, _, online)
        if rank == 2 and (not onlineOnly or online) then
            leaderName = fullName
            return true
        end
        return false
    end)
    return leaderName
end

--- Finds the local player's current raid subgroup.
-- @treturn number|nil subgroup
function AngryEra:GetCurrentGroup()
    local player = PlayerFullName()
    local subgroup
    IterateGroupMembers(function(_, fullName, _, memberSubgroup)
        if fullName == player then
            subgroup = memberSubgroup
            return true
        end
        return false
    end)
    return subgroup
end

--- Prints responses correlated to one protocol-v3 version query.
-- @tparam string queryId VERSION_QUERY message id.
function AngryEra:VersionCheckOutput(queryId)
    if type(queryId) ~= "string" or queryId == "" then
        self:Print("Unable to display version check results: missing query identifier.")
        return false
    end

    local missingAddon = {}
    local invalidRaid = {}
    local differentVersion = {}
    local upToDate = {}
    local localVersion = AngryEra.Version
    if localVersion:sub(1, 1) == "@" then
        localVersion = "dev"
    end
    local localPlayer = PlayerFullName()

    IterateGroupMembers(function(rawName, fullName, _, _, _, online)
        if not online then
            return false
        end

        local displayName = rawName or EnsureUnitShortName(fullName)
        local peer = fullName ~= localPlayer and self:GetProtocolPeer(fullName, queryId)
            or {
                AddonVersion = localVersion,
                AcceptsCurrentGroup = self:IsValidRaid(),
            }
        if not peer then
            table.insert(missingAddon, displayName)
        elseif peer.AcceptsCurrentGroup ~= true then
            table.insert(invalidRaid, displayName)
        elseif peer.AddonVersion ~= localVersion then
            table.insert(differentVersion, string.format("%s - %s", displayName, peer.AddonVersion))
        else
            table.insert(upToDate, displayName)
        end
        return false
    end)

    self:Print("Version check results:")
    if #upToDate > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Same version:|r " .. table.concat(upToDate, ", "))
    end
    if #differentVersion > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Different version:|r " .. table.concat(differentVersion, ", "))
    end
    if #invalidRaid > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Not allowing changes:|r " .. table.concat(invalidRaid, ", "))
    end
    if #missingAddon > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Missing addon:|r " .. table.concat(missingAddon, ", "))
    end
    return true
end

--- Cancels pending publication for a page being removed.
-- @tparam number id Local page id.
function AngryEra:CancelPageTimer(id)
    CancelTimer(self, pageTimerId[id])
    pageTimerId[id] = nil
    pageLastUpdate[id] = nil
end
