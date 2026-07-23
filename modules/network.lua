-- -------------------------------------------------------------------------------
-- Angry Era: modules/network.lua
--
-- Comm protocol: send/receive/process/throttle for addon communication.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local helpers = AngryEra.utils.helpers
local EnsureUnitFullName = helpers.EnsureUnitFullName
local EnsureUnitShortName = helpers.EnsureUnitShortName
local PlayerFullName = helpers.PlayerFullName
local IterateGroupMembers = helpers.IterateGroupMembers
local ValidateString = helpers.ValidateString

local libS = app.libs.libS
local libC = app.libs.libC
local libCE = app.libs.libCE

local core = AngryEra.core
local comPrefix = core.comPrefix
local updateFrequency = core.updateFrequency
local MAX_COMM_ENCODED_BYTES = core.MAX_COMM_ENCODED_BYTES
local MAX_COMM_DECODED_BYTES = core.MAX_COMM_DECODED_BYTES
local MAX_COMM_SERIALIZED_BYTES = core.MAX_COMM_SERIALIZED_BYTES

local COMMAND = core.COMMAND
local PAGE_Id = core.PAGE_Id
local PAGE_Updated = core.PAGE_Updated
local PAGE_Name = core.PAGE_Name
local PAGE_Contents = core.PAGE_Contents
local PAGE_UpdateId = core.PAGE_UpdateId
local PAGE_Vars = core.PAGE_Vars
local REQUEST_PAGE_Id = core.REQUEST_PAGE_Id
local DISPLAY_Id = core.DISPLAY_Id
local DISPLAY_Updated = core.DISPLAY_Updated
local DISPLAY_UpdateId = core.DISPLAY_UpdateId
local VERSION_Version = core.VERSION_Version
local VERSION_Timestamp = core.VERSION_Timestamp
local VERSION_ValidRaid = core.VERSION_ValidRaid

local AngryEra_Title = AngryEra.Title
local AngryEra_Version = AngryEra.Version
local AngryEra_Timestamp = AngryEra.Timestamp

local pageLastUpdate = {}
local pageTimerId = {}
local displayLastUpdate = nil
local displayTimerId = nil
local versionLastUpdate = nil
local versionTimerId = nil

local warnedOOD = false
local versionList = {}
local legacyPendingDisplaySyncId

local function BuildLegacyPageIdentity(self, sender, remoteId)
    local authority = self:GetRaidLeader() or sender
    return self:BuildLegacyRemoteIdentity(EnsureUnitFullName(authority), "page", remoteId)
end

--- Receives and validates incoming addon communication payloads.
-- Performs decode/decompress/deserialize and dispatches valid messages.
-- @tparam string prefix Message prefix.
-- @tparam string data Encoded wire payload.
-- @tparam string channel Source chat channel.
-- @tparam string sender Sender unit name.
function AngryEra:ReceiveMessage(prefix, data, channel, sender)
    if prefix ~= comPrefix then
        return
    end

    if type(data) ~= "string" or data == "" then
        return
    end
    if #data > MAX_COMM_ENCODED_BYTES then
        return
    end

    local okDecode, one = pcall(libCE.Decode, libCE, data)
    if not okDecode or type(one) ~= "string" then
        return
    end
    if #one > MAX_COMM_DECODED_BYTES then
        return
    end

    local okDecompress, two = pcall(libC.Decompress, libC, one)
    if not okDecompress or not two then
        return
    end
    if #two > MAX_COMM_SERIALIZED_BYTES then
        return
    end

    local okDeserialize, success, final = pcall(libS.Deserialize, libS, two)
    if not okDeserialize or not success or type(final) ~= "table" then
        return
    end

    self:ProcessMessage(sender, final)
end

--- Sends a serialized addon message to raid/party/instance chat.
-- If `channel` is omitted, the function auto-selects the best current group channel.
-- @tparam table data Message table to serialize.
-- @tparam[opt] string channel Channel override such as `"RAID"` or `"WHISPER"`.
-- @tparam[opt] string target Whisper target when `channel` is `"WHISPER"`.
-- @treturn boolean|nil Returns `true` when sent, or `nil` when no channel is available.
function AngryEra:SendOutMessage(data, channel, target)
    local one = libS:Serialize(data)
    local two = libC:CompressHuffman(one)
    local final = libCE:Encode(two)
    if not channel then
        if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) or IsInRaid(LE_PARTY_CATEGORY_INSTANCE) then
            channel = "INSTANCE_CHAT"
        elseif IsInRaid(LE_PARTY_CATEGORY_HOME) then
            channel = "RAID"
        elseif IsInGroup(LE_PARTY_CATEGORY_HOME) then
            channel = "PARTY"
        end
    end

    if not channel then
        return
    end

    -- self:Print("Sending "..data[COMMAND].." over "..channel.." to "..tostring(target))
    self:SendCommMessage(comPrefix, final, channel, target, "NORMAL")
    return true
end

--- Processes a decoded message command from another client.
-- Applies permission checks, updates local state, and triggers UI sync.
-- @tparam string sender Sender player name.
-- @tparam table data Decoded command payload.
function AngryEra:ProcessMessage(sender, data)
    local cmd = data[COMMAND]
    sender = EnsureUnitFullName(sender)

    -- self:Print("Received "..data[COMMAND].." from "..sender)
    if cmd == "PAGE" then
        if sender == PlayerFullName() then
            return
        end
        if not self:CanReceiveFrom(sender, "pageUpsert") then
            self:PermissionCheckFailError(sender)
            return
        end

        -- SECURITY FIX: Validate Inputs immediately
        -- Limit Name to 100 chars, Contents to 20,000 chars (generous but safe)
        local safeName = ValidateString(data[PAGE_Name], 100, "Name")
        local safeContents = ValidateString(data[PAGE_Contents], 20000, "Contents")

        local contents_updated = true
        local remoteId = data[PAGE_Id]
        local wireIdentity = BuildLegacyPageIdentity(self, sender, remoteId)
        if not wireIdentity then
            return
        end

        local page = self:GetPageBySyncId(wireIdentity.SyncId)
        local id = page and page.Id
        if page then
            self:SetLegacyRemoteId(page, remoteId)
            if data[PAGE_UpdateId] and page.UpdateId == data[PAGE_UpdateId] then
                local newCatVars = ValidateString(data[8], 5000, "CatVars")
                if page.CatVars ~= newCatVars then
                    page.CatVars = newCatVars
                    if AngryAssign_State.displayed == id then
                        self:UpdateDisplayed()
                    end
                end
                return
            end

            contents_updated = page.Contents ~= safeContents
            if contents_updated then
                self:PushHistory(page, page.Contents, sender)
            end
            page.Name = safeName
            page.Contents = safeContents
            page.Vars = ValidateString(data[PAGE_Vars], 5000, "Vars")
            page.CatVars = ValidateString(data[8], 5000, "CatVars")
            page.Updated = data[PAGE_Updated]
            page.UpdateId = data[PAGE_UpdateId] or self:Hash(page.Name, page.Contents, page.Vars)

            if self:SelectedId() == id then
                self:SelectedUpdated(sender)
                self:UpdateSelected()
            end
        else
            id = remoteId
            if AngryAssign_Pages[id] then
                id = self:AllocateLocalEntityId("page")
            end
            local pageRecord = {
                Id = id,
                Updated = data[PAGE_Updated],
                UpdateId = data[PAGE_UpdateId],
                Name = safeName,
                Contents = safeContents,
                Vars = ValidateString(data[PAGE_Vars], 5000, "Vars"),
                CatVars = ValidateString(data[8], 5000, "CatVars"),
            }
            local registered = self:RegisterRemoteEntityIdentity(pageRecord, "page", wireIdentity)
            if not registered then
                return
            end
            self:SetLegacyRemoteId(pageRecord, remoteId)
            AngryAssign_Pages[id] = pageRecord
        end
        if legacyPendingDisplaySyncId == wireIdentity.SyncId then
            legacyPendingDisplaySyncId = nil
            AngryAssign_State.displayed = id
        end
        if AngryAssign_State.displayed == id then
            self:UpdateDisplayed()
            self:ShowDisplay()
            if contents_updated then
                self:DisplayUpdateNotification()
            end
        end
        self:UpdateTree()
    elseif cmd == "DISPLAY" then
        if sender == PlayerFullName() then
            return
        end
        if not self:CanReceiveFrom(sender, "display") then
            if data[DISPLAY_Id] then
                self:PermissionCheckFailError(sender)
            end
            return
        end

        local remoteId = data[DISPLAY_Id]
        local updated = data[DISPLAY_Updated]
        local updateId = data[DISPLAY_UpdateId]
        local wireIdentity
        local page
        local id
        if remoteId ~= nil then
            wireIdentity = BuildLegacyPageIdentity(self, sender, remoteId)
            if not wireIdentity then
                return
            end
            page = self:GetPageBySyncId(wireIdentity.SyncId)
            id = page and page.Id
        end
        local sameVersion = (updateId and page and updateId == page.UpdateId)
            or (not updateId and page and updated == page.Updated)
        if remoteId and not sameVersion then
            self:SendRequestPage(remoteId, sender)
        end

        legacyPendingDisplaySyncId = remoteId and not page and wireIdentity.SyncId or nil
        if AngryAssign_State.displayed ~= id then
            AngryAssign_State.displayed = id
            self:UpdateTree()
            self:UpdateDisplayed()
            self:ShowDisplay()
            if id then
                self:DisplayUpdateNotification()
            end
        end
    elseif cmd == "REQUEST_DISPLAY" then
        if sender == PlayerFullName() then
            return
        end
        if not self:CanReceiveFrom(sender, "request") or not self:IsPlayerRaidLeader() then
            return
        end

        self:SendDisplay(AngryAssign_State.displayed)
    elseif cmd == "REQUEST_PAGE" then
        if sender == PlayerFullName() then
            return
        end
        if not self:CanReceiveFrom(sender, "request") then
            return
        end

        local requestedId = data[REQUEST_PAGE_Id]
        local wireIdentity = BuildLegacyPageIdentity(self, sender, requestedId)
        if wireIdentity then
            local page = self:GetPageBySyncId(wireIdentity.SyncId) or AngryAssign_Pages[requestedId]
            if page then
                self:SendPage(page.Id)
            end
        end
    elseif cmd == "VER_QUERY" then
        if self:CanReceiveFrom(sender, "version") then
            self:SendVersion()
        end
    elseif cmd == "VERSION" then
        if not self:CanReceiveFrom(sender, "version") then
            return
        end
        -- Existing version logic is mostly safe as it casts tostring/tonumber
        -- but let's wrap the assignments just to be sure
        local ver = tostring(data[VERSION_Version] or "")
        local timestamp = tonumber(data[VERSION_Timestamp]) or 0

        local localTimestamp = "dev"
        local localIsClassic = 0
        if AngryEra_Timestamp:sub(1, 1) ~= "@" then
            localTimestamp = tonumber(AngryEra_Timestamp) or 0
            if AngryEra_Version:sub(-3) == "tbc" then
                localIsClassic = 2
            elseif AngryEra_Version:sub(-1) == "c" then
                localIsClassic = 1
            end
        end

        local remoteIsClassic = 0
        if ver:sub(-3) == "tbc" then
            remoteIsClassic = 2
        elseif ver:sub(-1) == "c" then
            remoteIsClassic = 1
        end

        local localStr = tostring(localTimestamp)
        local remoteStr = tostring(timestamp)

        if (localStr ~= "dev" and localStr:len() ~= 14) or (remoteStr ~= "dev" and remoteStr:len() ~= 14) then
            if localStr ~= "dev" then
                localTimestamp = tonumber(localStr:sub(1, 8))
            end
            if remoteStr ~= "dev" then
                timestamp = tonumber(remoteStr:sub(1, 8))
            end
        end

        if
            localTimestamp ~= "dev"
            and timestamp ~= "dev"
            and timestamp > localTimestamp
            and localIsClassic == remoteIsClassic
            and not warnedOOD
        then
            self:Print(
                "Your version of "
                    .. AngryEra_Title
                    .. " is out of date! Download the latest version from curseforge.com."
            )
            warnedOOD = true
        end

        versionList[sender] = { valid = data[VERSION_ValidRaid], version = ver }
    end
end

--- Sends a page update with throttling.
-- @tparam number id Page id.
-- @tparam[opt=false] boolean force When `true`, bypasses throttle delay.
function AngryEra:SendPage(id, force)
    if not self:CanLocalPlayerPublish("pageUpsert") then
        return false
    end
    local lastUpdate = pageLastUpdate[id]
    local timerId = pageTimerId[id]
    local curTime = time()

    if lastUpdate and (curTime - lastUpdate <= updateFrequency) then
        if not timerId then
            if force then
                self:SendPageMessage(id)
            else
                pageTimerId[id] = self:ScheduleTimer("SendPageMessage", updateFrequency - (curTime - lastUpdate), id)
            end
        elseif force then
            self:CancelTimer(timerId)
            self:SendPageMessage(id)
        end
    else
        self:SendPageMessage(id)
    end
end

--- Sends one PAGE payload for the supplied page id.
-- @tparam number id Page id.
function AngryEra:SendPageMessage(id)
    pageTimerId[id] = nil
    if not self:CanLocalPlayerPublish("pageUpsert") then
        return false
    end

    local page = AngryAssign_Pages[id]
    if not page then
        pageLastUpdate[id] = nil
        return
    end

    pageLastUpdate[id] = time()
    if not page.UpdateId then
        page.UpdateId = self:Hash(page.Name, page.Contents, page.Vars)
    end

    local catVars = nil
    if page.CategoryId then
        local cat = AngryAssign_Categories[page.CategoryId]
        if cat and cat.Vars then
            catVars = cat.Vars
        end
    end

    local wireId = self:GetLegacyRemoteId(page) or page.Id
    self:SendOutMessage({
        "PAGE",
        [PAGE_Id] = wireId,
        [PAGE_Updated] = page.Updated,
        [PAGE_Name] = page.Name,
        [PAGE_Contents] = page.Contents,
        [PAGE_UpdateId] = page.UpdateId,
        [PAGE_Vars] = page.Vars,
        [8] = catVars,
    })
end

--- Sends display selection updates with throttling.
-- @tparam[opt] number id Page id to display, or `nil` to clear.
-- @tparam[opt=false] boolean force When `true`, bypasses throttle delay.
function AngryEra:SendDisplay(id, force)
    if not self:CanLocalPlayerPublish("display") then
        return false
    end
    local curTime = time()

    if displayLastUpdate and (curTime - displayLastUpdate <= updateFrequency) then
        if not displayTimerId then
            if force then
                self:SendDisplayMessage(id)
            else
                displayTimerId =
                    self:ScheduleTimer("SendDisplayMessage", updateFrequency - (curTime - displayLastUpdate), id)
            end
        elseif force then
            self:CancelTimer(displayTimerId)
            self:SendDisplayMessage(id)
        end
    else
        self:SendDisplayMessage(id)
    end
end

--- Sends one DISPLAY payload.
-- @tparam[opt] number id Page id to display, or `nil` to clear.
function AngryEra:SendDisplayMessage(id)
    displayTimerId = nil
    if not self:CanLocalPlayerPublish("display") then
        return false
    end
    displayLastUpdate = time()

    local page = AngryAssign_Pages[id]
    if not page then
        self:SendOutMessage({ "DISPLAY", [DISPLAY_Id] = nil, [DISPLAY_Updated] = nil, [DISPLAY_UpdateId] = nil })
    else
        if not page.UpdateId then
            page.UpdateId = self:Hash(page.Name, page.Contents, page.Vars)
        end
        local wireId = self:GetLegacyRemoteId(page) or page.Id
        self:SendOutMessage({
            "DISPLAY",
            [DISPLAY_Id] = wireId,
            [DISPLAY_Updated] = page.Updated,
            [DISPLAY_UpdateId] = page.UpdateId,
        })
    end
end

--- Requests current displayed page from the active raid leader.
function AngryEra:SendRequestDisplay()
    if IsInRaid() or IsInGroup() then
        local to = self:GetRaidLeader(true)
        if to then
            self:SendOutMessage({ "REQUEST_DISPLAY" }, "WHISPER", to)
        end
    end
end

--- Sends addon version information with throttling.
-- @tparam[opt=false] boolean force When `true`, bypasses throttle delay.
function AngryEra:SendVersion(force)
    local curTime = time()

    if versionLastUpdate and (curTime - versionLastUpdate <= updateFrequency) then
        if not versionTimerId then
            if force then
                self:SendVersionMessage()
            else
                versionTimerId =
                    self:ScheduleTimer("SendVersionMessage", updateFrequency - (curTime - versionLastUpdate))
            end
        elseif force then
            self:CancelTimer(versionTimerId)
            self:SendVersionMessage()
        end
    else
        self:SendVersionMessage()
    end
end

--- Sends one VERSION payload with current addon metadata.
function AngryEra:SendVersionMessage()
    versionLastUpdate = time()
    versionTimerId = nil

    local timestampToSend
    local verToSend
    if AngryEra_Version:sub(1, 1) == "@" then
        verToSend = "dev"
    else
        verToSend = AngryEra_Version
    end
    if AngryEra_Timestamp:sub(1, 1) == "@" then
        timestampToSend = "dev"
    else
        timestampToSend = tonumber(AngryEra_Timestamp)
    end
    self:SendOutMessage({
        "VERSION",
        [VERSION_Version] = verToSend,
        [VERSION_Timestamp] = timestampToSend,
        [VERSION_ValidRaid] = self:IsValidRaid(),
    })
end

--- Broadcasts a version query to nearby addon users.
function AngryEra:SendVerQuery()
    self:SendOutMessage({ "VER_QUERY" })
end

--- Requests a specific page from leader (or explicit target).
-- @tparam number id Requested page id.
-- @tparam[opt] string to Explicit whisper target.
function AngryEra:SendRequestPage(id, to)
    if (IsInRaid() or IsInGroup()) or to then
        if not to then
            to = self:GetRaidLeader(true)
        end
        if to then
            self:SendOutMessage({ "REQUEST_PAGE", [REQUEST_PAGE_Id] = id }, "WHISPER", to)
        end
    end
end

--- Returns the current raid leader full name.
-- @tparam[opt=false] boolean online_only Require leader to be online.
-- @treturn string|nil Leader name in `Name-Realm` format when available.
function AngryEra:GetRaidLeader(online_only)
    local leaderName
    IterateGroupMembers(function(_, fullName, rank, _, _, online)
        if rank == 2 and ((not online_only) or online) then
            leaderName = fullName
            return true
        end
        return false
    end)
    return leaderName
end

--- Finds the player's current raid subgroup.
-- @treturn number|nil Raid subgroup index (1..8) when grouped.
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

--- Prints categorized addon version-check results for current group members.
function AngryEra:VersionCheckOutput()
    local missing_addon = {}
    local invalid_raid = {}
    local different_version = {}
    local up_to_date = {}

    local ver = AngryEra_Version
    if ver:sub(1, 1) == "@" then
        ver = "dev"
    end

    IterateGroupMembers(function(rawName, fullName, _, _, _, online)
        if not online then
            return false
        end

        local displayName = rawName or EnsureUnitShortName(fullName)
        if not versionList[fullName] then
            tinsert(missing_addon, displayName)
        elseif versionList[fullName].valid == false or versionList[fullName].valid == nil then
            tinsert(invalid_raid, displayName)
        elseif ver ~= versionList[fullName].version then
            tinsert(different_version, string.format("%s - %s", displayName, versionList[fullName].version))
        else
            tinsert(up_to_date, displayName)
        end
        return false
    end)

    self:Print("Version check results:")
    if #up_to_date > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Same version:|r " .. table.concat(up_to_date, ", "))
    end

    if #different_version > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Different version:|r " .. table.concat(different_version, ", "))
    end

    if #invalid_raid > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Not allowing changes:|r " .. table.concat(invalid_raid, ", "))
    end

    if #missing_addon > 0 then
        print(LIGHTYELLOW_FONT_COLOR_CODE .. "Missing addon:|r " .. table.concat(missing_addon, ", "))
    end
end

--- Resets the version list used by version check output.
-- Called by settings (version check command) and init (group join).
function AngryEra:ResetVersionList()
    versionList = {}
end

--- Cancels any pending send timer for a page and clears its update tracking.
-- Called by models.lua when deleting a page.
-- @tparam number id Page id.
function AngryEra:CancelPageTimer(id)
    local timerId = pageTimerId[id]
    if timerId then
        self:CancelTimer(timerId)
        pageTimerId[id] = nil
    end
    pageLastUpdate[id] = nil
end
