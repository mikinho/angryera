local _G = _G

local appName, app = ...;
local L = app.L;

local GetAddOnMetadata = GetAddOnMetadata or C_AddOns.GetAddOnMetadata

local AngryAssign = LibStub("AceAddon-3.0"):NewAddon(appName, "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceTimer-3.0")
local AceGUI = LibStub("AceGUI-3.0")
local libS = LibStub("AceSerializer-3.0")
local libC = LibStub("LibCompress")
local lwin = LibStub("LibWindow-1.1")
local libCE = libC:GetAddonEncodeTable()
local LSM = LibStub("LibSharedMedia-3.0")
local DDM = LibStub("LibDropDownMenu")

local AngryAssign_Title = GetAddOnMetadata(appName, "Title")
local AngryAssign_Version = GetAddOnMetadata(appName, "Version")
local AngryAssign_Timestamp = GetAddOnMetadata(appName, "X-Timestamp")

_G["BINDING_HEADER_" .. appName] = "|cff0070DD" .. AngryAssign_Title

_G["BINDING_NAME_" .. appName .. "_WINDOW"] = "Toggle Window"
_G["BINDING_NAME_" .. appName .. "_LOCK"] = "Toggle Lock"
_G["BINDING_NAME_" .. appName .. "_DISPLAY"] = "Toggle Display"
_G["BINDING_NAME_" .. appName .. "_SHOW_DISPLAY"] = "Show Display"
_G["BINDING_NAME_" .. appName .. "_HIDE_DISPLAY"] = "Hide Display"
_G["BINDING_NAME_" .. appName .. "_OUTPUT"] = "Output Assignment to Chat"
_G["BINDING_NAME_" .. appName .. "_PREV_PAGE"] = "Previous Page"
_G["BINDING_NAME_" .. appName .. "_NEXT_PAGE"] = "Next Page"
_G["BINDING_NAME_" .. appName .. "_OUTPUT"] = "Output Assignment to Chat"

local isClassicVanilla = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
local isClassicTBC = WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
local isClassicWrath = WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC
local isClassic = isClassicVanilla or isClassicTBC or isClassicWrath

local protocolVersion = 1
local comPrefix = appName .. protocolVersion
local updateFrequency = 2
local pageLastUpdate = {}
local pageTimerId = {}
local displayLastUpdate = nil
local displayTimerId = nil
local versionLastUpdate = nil
local versionTimerId = nil

local guildOfficerNames = nil

-- Used for version tracking
local warnedOOD = false
local versionList = {}

local comStarted = false

local warnedPermission = false

local currentGroup = nil

-- Pages Saved Variable Format 
-- 	AngryAssign_Pages = {
-- 		[Id] = { Id = 1231, Updated = time(), UpdateId = self:Hash(name, contents), Name = "Name", Contents = "...", Backup = "...", CategoryId = 123 },
--		...
-- 	}
-- 	AngryAssign_Categories = {
-- 		[Id] = { Id = 1231, Name = "Name", CategoryId = 123 },
--		...
-- 	}
--
-- Format for our addon communication
--
-- { "PAGE", [Id], [Last Update Timestamp], [Name], [Contents], [Last Update Unique Id] }
-- Sent when a page is updated. Id is a random unique value. Unique Id is hash of page contents. Uses RAID.
--
-- { "REQUEST_PAGE", [Id] }
-- Asks to be sent PAGE with given Id. Response is a throttled PAGE. Uses WHISPER to raid leader.
--
-- { "DISPLAY", [Id], [Last Update Timestamp], [Last Update Unique Id] }
-- Raid leader / promoted sends out when new page is to be displayed. Uses RAID.
--
-- { "REQUEST_DISPLAY" }
-- Asks to be sent DISPLAY. Response is a throttled DISPLAY. Uses WHISPER to raid leader.
--
-- { "VER_QUERY" }
-- { "VERSION", [Version], [Project Timestamp], [Valid Raid] }

-- Constants for dealing with our addon communication
local COMMAND = 1

local PAGE_Id = 2
local PAGE_Updated = 3
local PAGE_Name = 4
local PAGE_Contents = 5
local PAGE_UpdateId = 6

local REQUEST_PAGE_Id = 2

local DISPLAY_Id = 2
local DISPLAY_Updated = 3
local DISPLAY_UpdateId = 4

local VERSION_Version = 2
local VERSION_Timestamp = 3
local VERSION_ValidRaid = 4

-----------------------
-- Utility Functions --
-----------------------

local IconTable = {
    -- Raid Targets (Mapped directly to textures now)
    ["{star}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t",
    ["{rt1}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t",

    ["{circle}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:0|t",
    ["{rt2}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:0|t",

    ["{diamond}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:0|t",
    ["{rt3}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:0|t",

    ["{triangle}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:0|t",
    ["{rt4}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:0|t",

    ["{moon}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:0|t",
    ["{rt5}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:0|t",

    ["{square}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:0|t",
    ["{rt6}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:0|t",

    ["{cross}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:0|t",
    ["{x}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:0|t",
    ["{rt7}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:0|t",

    ["{skull}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:0|t",
    ["{rt8}"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:0|t",

    -- Other Icons
    ["{healthstone}"] = "|TInterface\\Icons\\INV_Stone_04:0|t",
    ["{hs}"] = "|TInterface\\Icons\\INV_Stone_04:0|t",
    ["{damage}"] = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:22:41|t",
    ["{dps}"] = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:22:41|t",
    ["{tank}"] = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:0:19:22:41|t",
    ["{healer}"] = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:0:0:0:0:64:64:20:39:1:20|t",
    ["{hero}"] = "|TInterface\\Icons\\ABILITY_Shaman_Heroism:0|t",
    ["{heroism}"] = "|TInterface\\Icons\\ABILITY_Shaman_Heroism:0|t",
    ["{bl}"] = "|TInterface\\Icons\\SPELL_Nature_Bloodlust:0|t",
    ["{bloodlust}"] = "|TInterface\\Icons\\SPELL_Nature_Bloodlust:0|t",
    
    -- Class Icons
    ["{hunter}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:16:32|t",
    ["{warrior}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:0:16|t",
    ["{rogue}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:0:16|t",
    ["{mage}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:0:16|t",
    ["{priest}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:16:32|t",
    ["{warlock}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:48:64:16:32|t",
    ["{paladin}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:32:48|t",
    ["{druid}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:48:64:0:16|t",
    ["{shaman}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:16:32|t",
    ["{dk}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:32:48|t",
    ["{deathknight}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:16:32:32:48|t",
    ["{monk}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:32:48:32:48|t",
    ["{dh}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:64:48:32:48|t",
    ["{demonhunter}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:64:48:32:48|t",
    ["{evoker}"] = "|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:0:0:0:0:64:64:0:16:48:64|t"
}

-- Ensure ProcessTag uses this table correctly
local function ProcessTag(tag)
    local lowerTag = tag:lower()
    
    -- Check static table first (This now returns the texture directly)
    if IconTable[lowerTag] then return IconTable[lowerTag] end

    -- Check dynamic patterns
    local type, id = lowerTag:match("{(%a+)%s+(%d+)}")
    if type then
        if type == "spell" then
            return GetSpellLink(tonumber(id)) or tag
        elseif type == "icon" then
            return format("|T%s:0|t", select(3, GetSpellInfo(tonumber(id))) or "")
        elseif type == "boss" then
            return select(5, EJ_GetEncounterInfo(tonumber(id))) or tag
        elseif type == "journal" then
            return (C_EncounterJournal.GetSectionInfo(tonumber(id)) and C_EncounterJournal.GetSectionInfo(tonumber(id)).link) or tag
        end
    end

    -- Check named icon {icon name}
    local iconName = lowerTag:match("{icon%s+([%w_]+)}")
    if iconName then
        return "|TInterface\\Icons\\"..iconName..":0|t"
    end

    return tag
end

local function selectedLastValue(input)
	local a = select(-1, strsplit("", input or ""))
	return tonumber(a)
end

local function tReverse(tbl)
	for i=1, math.floor(#tbl / 2) do
		tbl[i], tbl[#tbl - i + 1] = tbl[#tbl - i + 1], tbl[i]
	end
end

local _player_realm = nil
local function EnsureUnitFullName(unit)
	if not _player_realm then _player_realm = select(2, UnitFullName('player')) end
	if unit and not unit:find('-') then
		unit = unit..'-'.._player_realm
	end
	return unit
end

local function EnsureUnitShortName(unit)
	if not _player_realm then _player_realm = select(2, UnitFullName('player')) end
	local name, realm = strsplit("-", unit, 2)
	if not realm or realm == _player_realm then
		return name
	else
		return unit
	end
end

local function PlayerFullName()
	if not _player_realm then _player_realm = select(2, UnitFullName('player')) end
	return UnitName('player')..'-'.._player_realm
end

local function RGBToHex(r, g, b, a)
	r = math.ceil(255 * r)
	g = math.ceil(255 * g)
	b = math.ceil(255 * b)
	if a == nil then
		return string.format("%02x%02x%02x", r, g, b)
	else
		a = math.ceil(255 * a)
		return string.format("%02x%02x%02x%02x", r, g, b, a)
	end
end

local function HexToRGB(hex)
	if string.len(hex) == 8 then
		return tonumber("0x"..hex:sub(1,2)) / 255, tonumber("0x"..hex:sub(3,4)) / 255, tonumber("0x"..hex:sub(5,6)) / 255, tonumber("0x"..hex:sub(7,8)) / 255
	else
		return tonumber("0x"..hex:sub(1,2)) / 255, tonumber("0x"..hex:sub(3,4)) / 255, tonumber("0x"..hex:sub(5,6)) / 255
	end
end

-------------------------
-- Addon Communication --
-------------------------

function AngryAssign:ReceiveMessage(prefix, data, channel, sender)
	if prefix ~= comPrefix then return end
	
	local one = libCE:Decode(data) -- Decode the compressed data
	
	local two, message = libC:Decompress(one) -- Decompress the decoded data
	
	if not two then error("Error decompressing: " .. message); return end
	
	local success, final = libS:Deserialize(two) -- Deserialize the decompressed data
	if not success then error("Error deserializing " .. final); return end

	self:ProcessMessage( sender, final )
end

function AngryAssign:SendOutMessage(data, channel, target)
	local one = libS:Serialize( data )
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

	if not channel then return end

	-- self:Print("Sending "..data[COMMAND].." over "..channel.." to "..tostring(target))
	self:SendCommMessage(comPrefix, final, channel, target, "NORMAL")
	return true
end

local function ValidateString(str, maxLength, fieldName)
    -- Type Safety: Ensure it is actually a string
    if type(str) ~= "string" then 
        return "" -- Fail safe to empty string
    end

    -- Length Limit: Truncate if too long to prevent memory bloat
    if #str > maxLength then
        str = string.sub(str, 1, maxLength)
    end

    -- Texture Safety: Neutralize direct texture tags (|T...|t)
    -- We replace the pipe '|' with a lookalike or simple replacement to break the tag
    -- This prevents the "Mega-Texture" client crash exploit.
    -- We explicitly look for the texture pattern to avoid breaking color codes |c
    str = string.gsub(str, "|[Tt]", "!") 

    return str
end

function AngryAssign:ProcessMessage(sender, data)
	local cmd = data[COMMAND]
	sender = EnsureUnitFullName(sender)
	
	-- self:Print("Received "..data[COMMAND].." from "..sender)
	if cmd == "PAGE" then
		if sender == PlayerFullName() then return end
		if not self:PermissionCheck(sender) then
			self:PermissionCheckFailError(sender)
			return
		end

        -- SECURITY FIX: Validate Inputs immediately
        -- Limit Name to 100 chars, Contents to 20,000 chars (generous but safe)
        local safeName = ValidateString(data[PAGE_Name], 100, "Name")
        local safeContents = ValidateString(data[PAGE_Contents], 20000, "Contents")

		local contents_updated = true
		local id = data[PAGE_Id]
        
        -- Type check ID to prevent table index errors
        if type(id) ~= "number" then return end

		local page = AngryAssign_Pages[id]
		if page then
			if data[PAGE_UpdateId] and page.UpdateId == data[PAGE_UpdateId] then return end 

			contents_updated = page.Contents ~= safeContents
			page.Name = safeName
			page.Contents = safeContents
			page.Updated = data[PAGE_Updated]
			page.UpdateId = data[PAGE_UpdateId] or self:Hash(page.Name, page.Contents)

			if self:SelectedId() == id then
				self:SelectedUpdated(sender)
				self:UpdateSelected()
			end
		else
			AngryAssign_Pages[id] = { 
                Id = id, 
                Updated = data[PAGE_Updated], 
                UpdateId = data[PAGE_UpdateId], 
                Name = safeName, 
                Contents = safeContents 
            }
		end
		if AngryAssign_State.displayed == id then
			self:UpdateDisplayed()
			self:ShowDisplay()
			if contents_updated then self:DisplayUpdateNotification() end
		end
		self:UpdateTree()

	elseif cmd == "DISPLAY" then
		if sender == PlayerFullName() then return end
		if not self:PermissionCheck(sender) then
			if data[DISPLAY_Id] then self:PermissionCheckFailError(sender) end
			return
		end

		local id = data[DISPLAY_Id]
        -- Safety check on ID
        if id and type(id) ~= "number" then return end

		local updated = data[DISPLAY_Updated]
		local updateId = data[DISPLAY_UpdateId]
		local page = AngryAssign_Pages[id]
		local sameVersion = (updateId and page and updateId == page.UpdateId) or (not updateId and page and updated == page.Updated)
		if id and not sameVersion then
			self:SendRequestPage(id, sender)
		end
		
		if AngryAssign_State.displayed ~= id then
			AngryAssign_State.displayed = id
			self:UpdateTree()
			self:UpdateDisplayed()
			self:ShowDisplay()
			if id then self:DisplayUpdateNotification() end
		end

	elseif cmd == "REQUEST_DISPLAY" then
		if sender == PlayerFullName() then return end
		if not self:IsPlayerRaidLeader() then return end

		self:SendDisplay( AngryAssign_State.displayed )

	elseif cmd == "REQUEST_PAGE" then
		if sender == PlayerFullName() then return end
		
        -- Safety check on requested ID
        if type(data[REQUEST_PAGE_Id]) == "number" then
		    self:SendPage( data[REQUEST_PAGE_Id] )
        end

	elseif cmd == "VER_QUERY" then
		self:SendVersion()
		
	elseif cmd == "VERSION" then
		-- Existing version logic is mostly safe as it casts tostring/tonumber
        -- but let's wrap the assignments just to be sure
		local ver = tostring(data[VERSION_Version] or "")
		local timestamp = tonumber(data[VERSION_Timestamp]) or 0

		local localTimestamp = "dev"
		local localIsClassic = 0
		if AngryAssign_Timestamp:sub(1,1) ~= "@" then
			localTimestamp = tonumber(AngryAssign_Timestamp) or 0
			if AngryAssign_Version:sub(-3) == "tbc" then
				localIsClassic = 2
			elseif AngryAssign_Version:sub(-1) == "c" then
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
			if localStr ~= "dev" then localTimestamp = tonumber(localStr:sub(1,8)) end
			if remoteStr ~= "dev" then timestamp = tonumber(remoteStr:sub(1,8)) end
		end

		if localTimestamp ~= "dev" and timestamp ~= "dev" and timestamp > localTimestamp and localIsClassic == remoteIsClassic and not warnedOOD then
			self:Print("Your version of " .. AngryAssign_Title .. " is out of date! Download the latest version from curseforge.com.")
			warnedOOD = true
		end

		versionList[ sender ] = { valid = data[VERSION_ValidRaid], version = ver }
	end
end

function AngryAssign:PermissionCheckFailError(sender)
	if not warnedPermission then
		self:Print( RED_FONT_COLOR_CODE .. "You have received a page update from "..Ambiguate(sender, "none").." that was rejected due to insufficient permissions. If you wish to see this page, please adjust your permission settings.|r" )
		warnedPermission = true
	end
end

function AngryAssign:SendPage(id, force)
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
			self:CancelTimer( timerId )
			self:SendPageMessage(id)
		end
	else
		self:SendPageMessage(id)
	end
end

function AngryAssign:SendPageMessage(id)
	pageLastUpdate[id] = time()
	pageTimerId[id] = nil
	
	local page = AngryAssign_Pages[ id ]
	if not page then error("Can't send page, does not exist"); return end
	if not page.UpdateId then page.UpdateId = self:Hash(page.Name, page.Contents) end
	self:SendOutMessage({ "PAGE", [PAGE_Id] = page.Id, [PAGE_Updated] = page.Updated, [PAGE_Name] = page.Name, [PAGE_Contents] = page.Contents, [PAGE_UpdateId] = page.UpdateId })
end

function AngryAssign:SendDisplay(id, force)
	local curTime = time()

	if displayLastUpdate and (curTime - displayLastUpdate <= updateFrequency) then
		if not displayTimerId then
			if force then
				self:SendDisplayMessage(id)
			else
				displayTimerId = self:ScheduleTimer("SendDisplayMessage", updateFrequency - (curTime - displayLastUpdate), id)
			end
		elseif force then
			self:CancelTimer( displayTimerId )
			self:SendDisplayMessage(id)
		end
	else
		self:SendDisplayMessage(id)
	end
end

function AngryAssign:SendDisplayMessage(id)
	displayLastUpdate = time()
	displayTimerId = nil
	
	local page = AngryAssign_Pages[ id ]
	if not page then
		self:SendOutMessage({ "DISPLAY", [DISPLAY_Id] = nil, [DISPLAY_Updated] = nil, [DISPLAY_UpdateId] = nil }) 
	else
		if not page.UpdateId then page.UpdateId = self:Hash(page.Name, page.Contents) end
		self:SendOutMessage({ "DISPLAY", [DISPLAY_Id] = page.Id, [DISPLAY_Updated] = page.Updated, [DISPLAY_UpdateId] = page.UpdateId }) 
	end
end

function AngryAssign:SendRequestDisplay()
	if (IsInRaid() or IsInGroup()) then
		local to = self:GetRaidLeader(true)
		if to then self:SendOutMessage({ "REQUEST_DISPLAY" }, "WHISPER", to) end
	end
end

function AngryAssign:SendVersion(force)
	local curTime = time()

	if versionLastUpdate and (curTime - versionLastUpdate <= updateFrequency) then
		if not versionTimerId then
			if force then
				self:SendVersionMessage(id)
			else
				versionTimerId = self:ScheduleTimer("SendVersionMessage", updateFrequency - (curTime - versionLastUpdate), id)
			end
		elseif force then
			self:CancelTimer( versionTimerId )
			self:SendVersionMessage()
		end
	else
		self:SendVersionMessage()
	end
end

function AngryAssign:SendVersionMessage()
	versionLastUpdate = time()
	versionTimerId = nil

	local revToSend
	local timestampToSend
	local verToSend
	if AngryAssign_Version:sub(1,1) == "@" then verToSend = "dev" else verToSend = AngryAssign_Version end
	if AngryAssign_Timestamp:sub(1,1) == "@" then timestampToSend = "dev" else timestampToSend = tonumber(AngryAssign_Timestamp) end
	self:SendOutMessage({ "VERSION", [VERSION_Version] = verToSend, [VERSION_Timestamp] = timestampToSend, [VERSION_ValidRaid] = self:IsValidRaid() })
end


function AngryAssign:SendVerQuery()
	self:SendOutMessage({ "VER_QUERY" })
end

function AngryAssign:SendRequestPage(id, to)
	if (IsInRaid() or IsInGroup()) or to then
		if not to then to = self:GetRaidLeader(true) end
		if to then self:SendOutMessage({ "REQUEST_PAGE", [REQUEST_PAGE_Id] = id }, "WHISPER", to) end
	end
end

function AngryAssign:GetRaidLeader(online_only)
	if (IsInRaid() or IsInGroup()) then
		for i = 1, GetNumGroupMembers() do
			local name, rank, subgroup, level, class, fileName, zone, online, isDead, role, isML = GetRaidRosterInfo(i)
			if rank == 2 then
				if (not online_only) or online then
					return EnsureUnitFullName(name)
				else
					return nil
				end
			end
		end
	end
	return nil
end

function AngryAssign:GetCurrentGroup()
	local player = PlayerFullName()
	if (IsInRaid() or IsInGroup()) then
		for i = 1, GetNumGroupMembers() do
			local name, _, subgroup = GetRaidRosterInfo(i)
			if EnsureUnitFullName(name) == player then
				return subgroup
			end
		end
	end
	return nil
end

function AngryAssign:VersionCheckOutput()
	local missing_addon = {}
	local invalid_raid = {}
	local different_version = {}
	local up_to_date = {}
	
	local ver = AngryAssign_Version
	if ver:sub(1,1) == "@" then ver = "dev" end
	
	if (IsInRaid() or IsInGroup()) then
		for i = 1, GetNumGroupMembers() do
			local name, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
			local fullname = EnsureUnitFullName(name)
			if online then
				if not versionList[ fullname ] then
					tinsert(missing_addon, name)
				elseif versionList[ fullname ].valid == false or versionList[ fullname ].valid == nil then
					tinsert(invalid_raid, name)
				elseif ver ~= versionList[ fullname ].version then
					tinsert(different_version, string.format("%s - %s", name, versionList[ fullname ].version)  )
				else
					tinsert(up_to_date, name)
				end
			end
		end
	end
	
	self:Print("Version check results:")
	if #up_to_date > 0 then
		print(LIGHTYELLOW_FONT_COLOR_CODE.."Same version:|r "..table.concat(up_to_date, ", "))
	end
	
	if #different_version > 0 then
		print(LIGHTYELLOW_FONT_COLOR_CODE.."Different version:|r "..table.concat(different_version, ", "))
	end
	
	if #invalid_raid > 0 then
		print(LIGHTYELLOW_FONT_COLOR_CODE.."Not allowing changes:|r "..table.concat(invalid_raid, ", "))
	end
	
	if #missing_addon > 0 then
		print(LIGHTYELLOW_FONT_COLOR_CODE.."Missing addon:|r "..table.concat(missing_addon, ", "))
	end
end

--------------------------
-- Editing Pages Window --
--------------------------

function AngryAssign_ToggleWindow()
	if not AngryAssign.window then AngryAssign:CreateWindow() end
	if AngryAssign.window:IsShown() then 
		AngryAssign.window:Hide() 
	else
		AngryAssign.window:Show() 
	end
end

function AngryAssign_ToggleLock()
	AngryAssign:ToggleLock()
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
                if not success and err then print(err) end
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
    if not page then return end

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
                if not success and err then print(err) end
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
    if not page then return end

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
    StaticPopupDialogs[popup_name].text = 'Are you sure you want to delete page "%s"?'
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
                if not success and err then print(err) end
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
    if not cat then return end

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
                if not success and err then print(err) end
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
    if not cat then return end

    local popup_name = "AngryAssign_DeleteCategory"
    
    if StaticPopupDialogs[popup_name] == nil then
        StaticPopupDialogs[popup_name] = {
            button1 = OKAY,
            button2 = CANCEL,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(self)
                local id = self.data
                AngryAssign:DeleteCategory(id)
            end,
        }
    end
    
    StaticPopupDialogs[popup_name].text = 'Are you sure you want to delete category "%s"?'
    StaticPopup_Show(popup_name, cat.Name, nil, cat.Id)
end

local function AngryAssign_AssignCategory(frame, entryId, catId)
	HideDropDownMenu(1)

	AngryAssign:AssignCategory(entryId, catId)
end

local function AngryAssign_RevertPage(widget, event, value)
	if not AngryAssign.window then return end
	AngryAssign:UpdateSelected(true)
end

function AngryAssign:DisplayPageByName( name )
	for id, page in pairs(AngryAssign_Pages) do
		if page.Name == name then
			return self:DisplayPage( id )
		end
	end
	return false
end

function AngryAssign:DisplayPage( id )
	if not self:PermissionCheck() then return end

	self:TouchPage( id )
	self:SendPage( id, true )
	self:SendDisplay( id, true )
	
	if AngryAssign_State.displayed ~= id then
		AngryAssign_State.displayed = id
		AngryAssign:UpdateDisplayed()
		AngryAssign:ShowDisplay()
		AngryAssign:UpdateTree()
		AngryAssign:DisplayUpdateNotification()
	end
	
	return true
end

local function AngryAssign_DisplayPage(widget, event, value)
	if not AngryAssign:PermissionCheck() then return end
	local id = AngryAssign:SelectedId()
	AngryAssign:DisplayPage( id )
end

local function AngryAssign_ClearPage(widget, event, value)
	if not AngryAssign:PermissionCheck() then return end

	AngryAssign:ClearDisplayed()
	AngryAssign:SendDisplay( nil, true )
end

local function AngryAssign_TextChanged(widget, event, value)
	AngryAssign.window.button_revert:SetDisabled(false)
	AngryAssign.window.button_restore:SetDisabled(false)
	AngryAssign.window.button_display:SetDisabled(true)
	AngryAssign.window.button_output:SetDisabled(true)
end

local function AngryAssign_TextEntered(widget, event, value)
	AngryAssign:UpdateContents(AngryAssign:SelectedId(), value)
end

local function AngryAssign_RestorePage(widget, event, value)
	if not AngryAssign.window then return end
	local page = AngryAssign_Pages[AngryAssign:SelectedId()]
	if not page or not page.Backup then return end
	
	AngryAssign.window.text:SetText( page.Backup )
	AngryAssign.window.text.button:Enable()
	AngryAssign_TextChanged(widget, event, value)
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

local PagesDropDownList
function AngryAssign_PageMenu(pageId)
	local page = AngryAssign_Pages[pageId]
	if not page then return end

	if not PagesDropDownList then
		PagesDropDownList = {
			{ notCheckable = true, isTitle = true },
			{ text = "Rename", notCheckable = true, func = function(frame, pageId) AngryAssign_RenamePage(pageId) end },
			{ text = "Delete", notCheckable = true, func = function(frame, pageId) AngryAssign_DeletePage(pageId) end },
			{ text = "Category", notCheckable = true, hasArrow = true },
		}
	end

	local permission = AngryAssign:PermissionCheck()

	PagesDropDownList[1].text = page.Name
	PagesDropDownList[2].arg1 = pageId
	PagesDropDownList[2].disabled = not permission
	PagesDropDownList[3].arg1 = pageId

	local categories = AngryAssign_CategoryMenuList(pageId)
	if categories ~= nil then
		PagesDropDownList[4].menuList = categories
		PagesDropDownList[4].disabled = false
	else
		PagesDropDownList[4].menuList = {}
		PagesDropDownList[4].disabled = true
	end

	return PagesDropDownList
end

local CategoriesDropDownList
local function AngryAssign_CategoryMenu(catId)
	local cat = AngryAssign_Categories[catId]
	if not cat then return end

	if not CategoriesDropDownList then
		CategoriesDropDownList = {
			{ notCheckable = true, isTitle = true },
			{ text = "Rename", notCheckable = true, func = function(frame, pageId) AngryAssign_RenameCategory(pageId) end },
			{ text = "Delete", notCheckable = true, func = function(frame, pageId) AngryAssign_DeleteCategory(pageId) end },
			{ text = "Category", notCheckable = true, hasArrow = true },
		}
	end
	CategoriesDropDownList[1].text = cat.Name
	CategoriesDropDownList[2].arg1 = catId
	CategoriesDropDownList[3].arg1 = catId


	local categories = AngryAssign_CategoryMenuList(-catId)
	if categories ~= nil then
		CategoriesDropDownList[4].menuList = categories
		CategoriesDropDownList[4].disabled = false
	else
		CategoriesDropDownList[4].menuList = {}
		CategoriesDropDownList[4].disabled = true
	end

	return CategoriesDropDownList
end

local AngryAssign_DropDown
local function AngryAssign_TreeClick(widget, event, value, selected, button)
	HideDropDownMenu(1)
	local selectedId = selectedLastValue(value)
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

function AngryAssign:CreateWindow()
	local window = AceGUI:Create("Frame")
	window:SetTitle(AngryAssign_Title)
	window:SetStatusText("")
	window:SetLayout("Flow")
	if AngryAssign:GetConfig('scale') then window.frame:SetScale( AngryAssign:GetConfig('scale') ) end
	window:SetStatusTable(AngryAssign_State.window)
	window:Hide()
	AngryAssign.window = window

	AngryAssign_Window = window.frame
	if window.frame.SetResizeBounds then -- WoW 10.0
		window.frame:SetResizeBounds(700, 400)
	else
		window.frame:SetMinResize(700, 400)
	end
	window.frame:SetFrameStrata("HIGH")
	window.frame:SetFrameLevel(1)
	window.frame:SetClampedToScreen(true)
	tinsert(UISpecialFrames, "AngryAssign_Window")

	local header = AceGUI:Create("SimpleGroup")
	header:SetLayout("Flow")
	header:SetFullWidth(true)
	window:AddChild(header)

	local searchLabel = AceGUI:Create("Label")
	searchLabel:SetText("Search:")
	searchLabel:SetWidth(40)
	header:AddChild(searchLabel)

	local searchBox = AceGUI:Create("EditBox")
	searchBox:DisableButton(true)
	searchBox:SetCallback("OnTextChanged", function(_, _, v) AngryAssign.window.tree:SetSearchKeyword(v) end)
	header:AddChild(searchBox)

	local tree = AceGUI:Create("AngryTreeGroup")
	tree:SetTree( self:GetTree() )
	tree:SelectByValue(1)
	tree:SetStatusTable(AngryAssign_State.tree)
	tree:SetFullWidth(true)
	tree:SetFullHeight(true)
	tree:SetLayout("Flow")
	tree:SetCallback("OnGroupSelected", function(widget, event, value) AngryAssign:UpdateSelected(true) end)
	tree:SetCallback("OnClick", AngryAssign_TreeClick)
	window:AddChild(tree)
	window.tree = tree
	
	-- Enable delete key for tree
	tree.treeframe:EnableKeyboard(true)
	tree.treeframe:SetPropagateKeyboardInput(true)
	tree.treeframe:SetScript("OnKeyDown", function(self, key)
		if key == "DELETE" then
			local selectedId = AngryAssign:SelectedId()
			if selectedId and selectedId > 0 then
				AngryAssign_DeletePage(selectedId)
				self:SetPropagateKeyboardInput(false)
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
	button_display:SetText("Send and Display")
	button_display:SetWidth(140)
	button_display:SetHeight(22)
	button_display:ClearAllPoints()
	button_display:SetPoint("BOTTOMRIGHT", text.frame, "BOTTOMRIGHT", 0, 4)
	button_display:SetCallback("OnClick", AngryAssign_DisplayPage)
	tree:AddChild(button_display)
	window.button_display = button_display

	local button_revert = AceGUI:Create("Button")
	button_revert:SetText("Revert")
	button_revert:SetWidth(80)
	button_revert:SetHeight(22)
	button_revert:ClearAllPoints()
	button_revert:SetDisabled(true)
	button_revert:SetPoint("BOTTOMLEFT", text.button, "BOTTOMRIGHT", 6, 0)
	button_revert:SetCallback("OnClick", AngryAssign_RevertPage)
	tree:AddChild(button_revert)
	window.button_revert = button_revert
	
	local button_restore = AceGUI:Create("Button")
	button_restore:SetText("Restore")
	button_restore:SetWidth(80)
	button_restore:SetHeight(22)
	button_restore:ClearAllPoints()
	button_restore:SetPoint("LEFT", button_revert.frame, "RIGHT", 6, 0)
	button_restore:SetCallback("OnClick", AngryAssign_RestorePage)
	tree:AddChild(button_restore)
	window.button_restore = button_restore
	
	local button_output = AceGUI:Create("Button")
	button_output:SetText("Output")
	button_output:SetWidth(80)
	button_output:SetHeight(22)
	button_output:ClearAllPoints()
	button_output:SetPoint("BOTTOMLEFT", button_restore.frame, "BOTTOMRIGHT", 6, 0)
	button_output:SetCallback("OnClick", AngryAssign_OutputDisplayed)
	tree:AddChild(button_output)
	window.button_output = button_output

	window:PauseLayout()
	local button_add = AceGUI:Create("Button")
	button_add:SetText("Add")
	button_add:SetWidth(80)
	button_add:SetHeight(19)
	button_add:ClearAllPoints()
	button_add:SetPoint("BOTTOMLEFT", window.frame, "BOTTOMLEFT", 17, 18)
	button_add:SetCallback("OnClick", AngryAssign_AddPage)
	window:AddChild(button_add)
	window.button_add = button_add

	local button_rename = AceGUI:Create("Button")
	button_rename:SetText("Rename")
	button_rename:SetWidth(80)
	button_rename:SetHeight(19)
	button_rename:ClearAllPoints()
	button_rename:SetPoint("BOTTOMLEFT", button_add.frame, "BOTTOMRIGHT", 5, 0)
	button_rename:SetCallback("OnClick", function() AngryAssign_RenamePage(AngryAssign:SelectedId()) end)
	window:AddChild(button_rename)
	window.button_rename = button_rename

	local button_delete = AceGUI:Create("Button")
	button_delete:SetText("Delete")
	button_delete:SetWidth(80)
	button_delete:SetHeight(19)
	button_delete:ClearAllPoints()
	button_delete:SetPoint("BOTTOMLEFT", button_rename.frame, "BOTTOMRIGHT", 5, 0)
	button_delete:SetCallback("OnClick", function() AngryAssign_DeletePage(AngryAssign:SelectedId()) end)
	window:AddChild(button_delete)
	window.button_delete = button_delete

	local button_add_cat = AceGUI:Create("Button")
	button_add_cat:SetText("Add Category")
	button_add_cat:SetWidth(120)
	button_add_cat:SetHeight(19)
	button_add_cat:ClearAllPoints()
	button_add_cat:SetPoint("BOTTOMLEFT", button_delete.frame, "BOTTOMRIGHT", 5, 0)
	button_add_cat:SetCallback("OnClick", function() AngryAssign_AddCategory() end)
	window:AddChild(button_add_cat)
	window.button_add_cat = button_add_cat

	local button_clear = AceGUI:Create("Button")
	button_clear:SetText("Clear")
	button_clear:SetWidth(80)
	button_clear:SetHeight(19)
	button_clear:ClearAllPoints()
	button_clear:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -135, 18)
	button_clear:SetCallback("OnClick", AngryAssign_ClearPage)
	window:AddChild(button_clear)
	window.button_clear = button_clear

	self:UpdateSelected(true)
	self:UpdateMedia()
	
	--self:CreateIconPicker()
end

local function AngryAssign_IconPicker_Clicked(widget, event)
	local texture
	if widget:GetUserData('name') then
		icon = widget:GetUserData('name')
	else
		icon = '{icon '..strmatch(widget.image:GetTexture():lower(), "^interface\\icons\\([-_%w]+)$")..'}'
	end

	local position = AngryAssign.window.text.editBox:GetCursorPosition()
	if position > 0 then
		local text = AngryAssign.window.text:GetText()
		AngryAssign.window.text:SetText( strsub(text, 1, position)..icon..strsub(text, position+1, AngryAssign.window.text.editBox:GetNumLetters()) )
		AngryAssign.window.text.editBox:SetCursorPosition( position, string.len(text) )
	else
		AngryAssign.window.text:SetText( AngryAssign.window.text:GetText()..icon)
	end

	AngryAssign.window.text.button:Enable()
	AngryAssign_TextChanged()
end

local iconCache = nil
local function AngryAssign_IconPicker_TextChanged(widget, event, value)
	AngryAssign.iconpicker_scroll:ReleaseChildren()

	local names = {}

	local spellID = strmatch(value, '|Hspell:(%d+)|')
	local itemID = strmatch(value, '|Hitem:(%d+):')

	if spellID then
		local path = select(3, GetSpellInfo(tonumber(spellID)))
		tinsert(names, path)
	elseif itemID then
		local path = select(10, GetItemInfo(tonumber(itemID)))
		tinsert(names, path)
	elseif value ~= "" then
		if not iconCache then iconCache = GetMacroIcons() end
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
			icon:SetCallback('OnClick', AngryAssign_IconPicker_Clicked)
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
	icon:SetUserData('name', name)
	icon:SetCallback('OnClick', AngryAssign_IconPicker_Clicked)
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

local function GetTree_InsertPage(tree, page)
	if page.Id == AngryAssign_State.displayed then
		table.insert(tree, { value = page.Id, text = page.Name, icon = "Interface\\BUTTONS\\UI-GuildButton-MOTD-Up" })
	else
		table.insert(tree, { value = page.Id, text = page.Name })
	end
end

local function GetTree_InsertChildren(categoryId, displayedPages)
	local tree = {}
	for _, cat in pairs(AngryAssign_Categories) do
		if cat.CategoryId == categoryId then
			table.insert(tree, { value = -cat.Id, text = cat.Name, children = GetTree_InsertChildren(cat.Id, displayedPages) })
		end
	end

	for _, page in pairs(AngryAssign_Pages) do
		if page.CategoryId == categoryId then
			displayedPages[page.Id] = true
			GetTree_InsertPage(tree, page)
		end
	end

	table.sort(tree, function(a,b) return a.text < b.text end)
	return tree
end

function AngryAssign:GetTree()
	local tree = {}
	local displayedPages = {}

	for _, cat in pairs(AngryAssign_Categories) do
		if not cat.CategoryId then
			table.insert(tree, { value = -cat.Id, text = cat.Name, children = GetTree_InsertChildren(cat.Id, displayedPages) })
		end
	end

	for _, page in pairs(AngryAssign_Pages) do
		if not page.CategoryId or not displayedPages[page.Id] then
			GetTree_InsertPage(tree, page)
		end
	end

	table.sort(tree, function(a,b) return a.text < b.text end)

	return tree
end

function AngryAssign:UpdateTree(id)
	if not self.window then return end
	self.window.tree:SetTree( self:GetTree() )
	if id then
		self:SetSelectedId( id )
	end
end

function AngryAssign:UpdateSelected(destructive)
	if not self.window then return end
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
		self.window.button_rename:SetDisabled(false)
		self.window.button_revert:SetDisabled(not self.window.text.button:IsEnabled())
		self.window.button_display:SetDisabled(self.window.text.button:IsEnabled())
		self.window.button_output:SetDisabled(self.window.text.button:IsEnabled())
		self.window.button_restore:SetDisabled(not self.window.text.button:IsEnabled() and page.Backup == page.Contents)
		self.window.text:SetDisabled(false)
	else
		self.window.button_rename:SetDisabled(true)
		self.window.button_revert:SetDisabled(true)
		self.window.button_display:SetDisabled(true)
		self.window.button_output:SetDisabled(true)
		self.window.button_restore:SetDisabled(true)
		self.window.text:SetDisabled(true)
	end
	if page then
		self.window.button_delete:SetDisabled(false)
	else
		self.window.button_delete:SetDisabled(true)
	end
	if permission then
		self.window.button_add:SetDisabled(false)
		self.window.button_clear:SetDisabled(false)
	else
		self.window.button_add:SetDisabled(true)
		self.window.button_clear:SetDisabled(true)
	end
end

----------------------------------
-- Performing changes functions --
----------------------------------

function AngryAssign:PrevPage()
	self:NextPage(true);
end

function AngryAssign:NextPage(reverse)
	local page = AngryAssign_Pages[ AngryAssign_State.displayed ]
	if not page then return end
	if not page.CategoryId then return end

	local tree = { }

	for _, p in pairs(AngryAssign_Pages) do
		if p.CategoryId and page.CategoryId == p.CategoryId then
			table.insert(tree, p)
		end
	end

	table.sort(tree, function(a, b) return a.Name < b.Name end)

	for i = 1, #tree, 1 do
		local p = tree[i]
		if p.Id == page.Id then
			local inc = 1
			if reverse then inc = -1 end
			local next = tree[i + inc]
			if next then
				return self:DisplayPage(next .Id)
			end
		end
	end
end

function AngryAssign:SelectedId()
	return selectedLastValue( AngryAssign_State.tree.selected )
end

function AngryAssign:SetSelectedId(selectedId)
	local page = AngryAssign_Pages[selectedId]
	if page then
		if page.CategoryId then
			local cat = AngryAssign_Categories[page.CategoryId]
			local path = { }
			while cat do
				table.insert(path, -cat.Id)
				if cat.CategoryId then
					cat = AngryAssign_Categories[cat.CategoryId]
				else 
					cat = nil
				end
			end
			tReverse(path)
			table.insert(path, page.Id)
			self.window.tree:SelectByPath(unpack(path))
		else
			self.window.tree:SelectByValue(page.Id)
		end
	else
		self.window.tree:SetSelected()
	end
end

function AngryAssign:Get(id)
	if id == nil then id = self:SelectedId() end
	return AngryAssign_Pages[id]
end

function AngryAssign:GetCat(id)
	return AngryAssign_Categories[id]
end

function AngryAssign:Hash(name, contents)
	local code = libC:fcs32init()
	code = libC:fcs32update(code, name)
	code = libC:fcs32update(code, "\n")
	code = libC:fcs32update(code, contents)
	return libC:fcs32final(code)
end

-- Helper function to handle the "Duck Typing" of the input
-- Places this at the top of your file or above the methods
local function ExtractAndValidateName(nameOrFrame)
    local text

    -- Extract text if input is a UI Frame
    if type(nameOrFrame) == "table" then
        local editBox = nameOrFrame.editBox or nameOrFrame.wideEditBox or nameOrFrame.EditBox
        -- Fallback: If passed the EditBox directly
        if not editBox and nameOrFrame.GetText then editBox = nameOrFrame end
        
        if not editBox then return nil, "Could not find input box." end
        text = editBox:GetText()
    else
        -- Input is already a string
        text = nameOrFrame
    end

    -- Validate type
    if type(text) ~= "string" then return nil, "Invalid name format." end

    -- Trim whitespace
    local cleanName = text:match("^%s*(.-)%s*$")

    -- Check empty
    if cleanName == "" then return nil, "Name cannot be empty." end

    return cleanName
end

function AngryAssign:CreatePage(nameOrFrame)
    -- Check Permissions first
    if not self:PermissionCheck() then return false, "Permission denied." end

    -- Validate and Clean Input
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then return false, err end

    -- Original Business Logic
    local id = self:Hash("page", math.random(2000000000))

    AngryAssign_Pages[id] = { 
        Id = id, 
        Updated = time(), 
        UpdateId = self:Hash(name, ""), 
        Name = name, 
        Contents = "" 
    }
    
    self:UpdateTree(id)
    self:SendPage(id, true)
    
    return true
end

function AngryAssign:RenamePage(id, nameOrFrame)
    -- Check Existence
    local page = self:Get(id)
    if not page then return false, "Page not found." end

    -- Check Permissions
    if not self:PermissionCheck() then return false, "Permission denied." end

    -- Validate and Clean Input
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then return false, err end

    -- Optimization: Skip if name hasn't changed
    if page.Name == name then return true end

    -- Original Business Logic
    page.Name = name
    page.Updated = time()
    page.UpdateId = self:Hash(page.Name, page.Contents)

    self:SendPage(id, true)
    self:UpdateTree()
    
    if AngryAssign_State.displayed == id then
        self:UpdateDisplayed()
        self:ShowDisplay()
    end

    return true
end

function AngryAssign:DeletePage(id)
	AngryAssign_Pages[id] = nil
	if self.window and self:SelectedId() == id then
		self:SetSelectedId(nil)
		self:UpdateSelected(true)
	end
	if AngryAssign_State.displayed == id then
		self:ClearDisplayed()
	end
	self:UpdateTree()
end

function AngryAssign:TouchPage(id)
	if not self:PermissionCheck() then return end
	local page = self:Get(id)
	if not page then return end

	page.Updated = time()
end

function AngryAssign:CreateCategory(nameOrFrame)
    -- Validate and Clean Input using your new helper
    local name, err = ExtractAndValidateName(nameOrFrame)
    if not name then return false, err end

    -- Generate ID and Save
    local id = self:Hash("cat", math.random(2000000000))

    AngryAssign_Categories[id] = { Id = id, Name = name }

    if AngryAssign_State.tree.groups then
        AngryAssign_State.tree.groups[ -id ] = true
    end
    self:UpdateTree()
    
    return true
end

function AngryAssign:RenameCategory(id, nameOrFrame)
    local cat = self:GetCat(id)
    if not cat then return false, "Category not found." end

    local nameToProcess

    -- Input Handling: Is it a UI Frame or a String?
    if type(nameOrFrame) == "table" then
        -- It is a frame, let's find the edit box inside it
        -- We support passing the Popup frame directly
        local editBox = nameOrFrame.editBox or nameOrFrame.wideEditBox or nameOrFrame.EditBox
        
        -- If we were passed the EditBox itself, use it, otherwise check for sub-keys
        if not editBox and nameOrFrame.GetText then 
             editBox = nameOrFrame 
        end

        if not editBox then return false, "Could not find input box." end
        nameToProcess = editBox:GetText()
    else
        -- It is a raw string (e.g. from a slash command)
        nameToProcess = nameOrFrame
    end

    -- 2. Validation (Standard checks)
    if type(nameToProcess) ~= "string" then return false, "Invalid name format." end
    local cleanName = nameToProcess:match("^%s*(.-)%s*$")

    if cleanName == "" then 
        return false, "Category name cannot be empty." 
    end

    if cat.Name == cleanName then return true end

    -- 3. Execution
    cat.Name = cleanName
    self:UpdateTree()
    
    return true
end

function AngryAssign:DeleteCategory(id)
	local cat = self:GetCat(id)
	if not cat then return end

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

	AngryAssign_Categories[id] = nil

	self:UpdateTree()
	self:SetSelectedId(selectedId)
end

function AngryAssign:AssignCategory(entryId, parentId)
	local page, cat
	if entryId > 0 then
		page = self:Get(entryId)
	else
		cat = self:GetCat(-entryId)
	end
	local parent = self:GetCat(parentId)
	if not (page or cat) or not parent then return end

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
			cat.CategoryId = parentId
		end
	end

	local selectedId = self:SelectedId()
	self:UpdateTree()
	if selectedId == entryId then
		self:SetSelectedId( selectedId )
	end
end

function AngryAssign:UpdateContents(id, value)
	if not self:PermissionCheck() then return end
	local page = self:Get(id)
	if not page then return end

	local new_content = value:gsub('^%s+', ''):gsub('%s+$', '')
	local contents_updated = new_content ~= page.Contents
	page.Contents = new_content
	page.Backup = new_content
	page.Updated = time()
	page.UpdateId = self:Hash(page.Name, page.Contents)

	self:SendPage(id, true)
	self:UpdateSelected(true)
	if AngryAssign_State.displayed == id then
		self:UpdateDisplayed()
		self:ShowDisplay()
		if contents_updated then self:DisplayUpdateNotification() end
	end
end

function AngryAssign:CreateBackup()
	for _, page in pairs(AngryAssign_Pages) do
		page.Backup = page.Contents
	end
	self:UpdateSelected()
end
function AngryAssign:ClearDisplayed()
	AngryAssign_State.displayed = nil
	self:UpdateDisplayed()
	self:UpdateTree()
end

function AngryAssign:IsGuildOfficer(player)
	if not player then return false end
	local fullplayer = EnsureUnitFullName(player)

	if guildOfficerNames == nil then
		self:UpdateOfficerRank()
	end

	return guildOfficerNames[fullplayer]
end

function AngryAssign:ResetOfficerRank()
	guildOfficerNames = nil
end

function AngryAssign:UpdateOfficerRank()
	guildOfficerNames = {}

	if C_Club and C_Club.GetGuildClubId then
		local clubId, streamId = C_Club.GetGuildClubId(), nil
		local memberIds = CommunitiesUtil.GetMemberIdsSortedByName(clubId, streamId)
		local allMemberList = CommunitiesUtil.GetMemberInfo(clubId, memberIds)

		for _, memberInfo in ipairs(allMemberList) do
			if memberInfo.name and (memberInfo.role == Enum.ClubRoleIdentifier.Owner or memberInfo.role == Enum.ClubRoleIdentifier.Leader or memberInfo.role == Enum.ClubRoleIdentifier.Moderator) then
				guildOfficerNames[EnsureUnitFullName(memberInfo.name)] = true
			end
		end
	end

	return guildOfficerNames
end

function AngryAssign:IsPlayerRaidLeader()
	local leader = self:GetRaidLeader()
	return leader and PlayerFullName() == EnsureUnitFullName(leader)
end

function AngryAssign:IsGuildRaid()
	local leader = self:GetRaidLeader()
	
	if self:IsGuildOfficer(leader) then
		return true
	end
	
	return false
end
	
	
function AngryAssign:IsValidRaid()
	if self:GetConfig('allowall') then
		return true
	end
	
	local leader = self:GetRaidLeader()
	
	if self:IsGuildOfficer(leader) then
		return true
	end
	
	for token in string.gmatch( AngryAssign:GetConfig('allowplayers') , "[^%s!#$%%&()*+,./:;<=>?@\\^_{|}~%[%]]+") do
		if leader and EnsureUnitFullName(token):lower() == EnsureUnitFullName(leader):lower() then
			return true
		end
	end

	if self:IsPlayerRaidLeader() then
		return true
	end
	
	return false
end

function AngryAssign:PermissionCheck(sender)
	if not sender then sender = PlayerFullName() end

	if (IsInRaid() or IsInGroup()) then
		return (UnitIsGroupLeader(EnsureUnitShortName(sender)) == true or UnitIsGroupAssistant(EnsureUnitShortName(sender)) == true) and self:IsValidRaid()
	else
		return sender == PlayerFullName()
	end
end


function AngryAssign:PermissionsUpdated()
	self:UpdateSelected()
	if comStarted then
		self:SendRequestDisplay()
	end
	if (IsInRaid() or IsInGroup()) and not self:IsValidRaid() then
		self:ClearDisplayed()
	end
end

---------------------
-- Displaying Page --
---------------------

local function DragHandle_MouseDown(frame) frame:GetParent():GetParent():StartSizing("RIGHT") end
local function DragHandle_MouseUp(frame)
	local display = frame:GetParent():GetParent()
	display:StopMovingOrSizing()
	AngryAssign_State.display.width = display:GetWidth()
	lwin.SavePosition(display)
	AngryAssign:UpdateBackdrop()
end
local function Mover_MouseDown(frame) frame:GetParent():StartMoving() end
local function Mover_MouseUp(frame)
	local display = frame:GetParent()
	display:StopMovingOrSizing()
	lwin.SavePosition(display)
end

function AngryAssign:ResetPosition()
	AngryAssign_State.display = {}
	AngryAssign_State.directionUp = false
	AngryAssign_State.locked = false
	
	self.display_text:Show()
	self.mover:Show()
	self.frame:SetWidth(300)
	
	lwin.RegisterConfig(self.frame, AngryAssign_State.display)
	lwin.RestorePosition(self.frame)
	
	self:UpdateDirection()
end

function AngryAssign_ToggleDisplay()
	AngryAssign:ToggleDisplay()
end

function AngryAssign_ShowDisplay()
	AngryAssign:ShowDisplay()
end

function AngryAssign_HideDisplay()
	AngryAssign:HideDisplay()
end

function AngryAssign_PrevPage()
	AngryAssign:PrevPage()
end

function AngryAssign_NextPage()
	AngryAssign:NextPage()
end

function AngryAssign:ShowDisplay()
	self.display_text:Show()
	self:UpdateBackdrop()
	AngryAssign_State.display.hidden = false
end

function AngryAssign:HideDisplay()
	self.display_text:Hide()
	AngryAssign_State.display.hidden = true
end

function AngryAssign:ToggleDisplay()
	if self.display_text:IsShown() then
		self:HideDisplay()
	else
		self:ShowDisplay()
	end
end


function AngryAssign:CreateDisplay()
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetPoint("CENTER",0,0)
	frame:SetWidth(AngryAssign_State.display.width or 300)
	frame:SetHeight(1)
	frame:SetMovable(true)
	frame:SetResizable(true)
	frame:SetClampedToScreen(true)
	if frame.SetResizeBounds then -- WoW 10.0
		frame:SetResizeBounds(180, 1, 830, 1)
	else
		frame:SetMinResize(180,1)
		frame:SetMaxResize(830,1)
	end
	frame:SetFrameStrata("MEDIUM")	
	self.frame = frame

	lwin.RegisterConfig(frame, AngryAssign_State.display)
	lwin.RestorePosition(frame)

	local text = CreateFrame("ScrollingMessageFrame", nil, frame)
	text:SetIndentedWordWrap(true)
	text:SetJustifyH("LEFT")
	text:SetFading(false)
	text:SetMaxLines(70)
	text:SetHeight(700)
	text:SetHyperlinksEnabled(false)
	self.display_text = text

	local backdrop = text:CreateTexture()
	backdrop:SetDrawLayer("BACKGROUND")
	self.backdrop = backdrop

	local mover = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
	mover:SetPoint("LEFT",0,0)
	mover:SetPoint("RIGHT",0,0)
	mover:SetHeight(16)
	mover:EnableMouse(true)
	mover:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
	mover:SetBackdropColor( 0.616, 0.149, 0.114, 0.9)
	mover:SetScript("OnMouseDown", Mover_MouseDown)
	mover:SetScript("OnMouseUp", Mover_MouseUp)
	self.mover = mover
	if AngryAssign_State.locked then mover:Hide() end

	local label = mover:CreateFontString()
	label:SetFontObject("GameFontNormal")
	label:SetJustifyH("CENTER")
	label:SetPoint("LEFT", 38, 0)
	label:SetPoint("RIGHT", -38, 0)
	label:SetText(AngryAssign_Title)

	local direction = CreateFrame("Button", nil, mover)
	direction:SetPoint("LEFT", 2, 0)
	direction:SetWidth(16)
	direction:SetHeight(16)
	direction:SetNormalTexture("Interface\\Buttons\\UI-Panel-QuestHideButton")
	direction:SetPushedTexture("Interface\\Buttons\\UI-Panel-QuestHideButton")
	direction:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
	direction:SetScript("OnClick", function() AngryAssign:ToggleDirection() end)
	self.direction_button = direction

	local lock = CreateFrame("Button", nil, mover)
	lock:SetNormalTexture("Interface\\LFGFRAME\\UI-LFG-ICON-LOCK")
	lock:GetNormalTexture():SetTexCoord(0, 0.71875, 0, 0.875)
	lock:SetPoint("LEFT", direction, "RIGHT", 4, 0)
	lock:SetWidth(12)
	lock:SetHeight(14)
	lock:SetScript("OnClick", function() AngryAssign:ToggleLock() end)

	local drag = CreateFrame("Frame", nil, mover)
	drag:SetFrameLevel(mover:GetFrameLevel() + 10)
	drag:SetWidth(16)
	drag:SetHeight(16)
	drag:SetPoint("BOTTOMRIGHT", 0, 0)
	drag:EnableMouse(true)
	drag:SetScript("OnMouseDown", DragHandle_MouseDown)
	drag:SetScript("OnMouseUp", DragHandle_MouseUp)
	drag:SetAlpha(0.5)

	local dragtex = drag:CreateTexture(nil, "OVERLAY")
	dragtex:SetTexture("Interface\\AddOns\\" .. appName .. "\\Textures\\draghandle")
	dragtex:SetWidth(16)
	dragtex:SetHeight(16)
	dragtex:SetBlendMode("ADD")
	dragtex:SetPoint("CENTER", drag)

	local glow = text:CreateTexture()
	glow:SetDrawLayer("BORDER")
	glow:SetTexture("Interface\\AddOns\\" .. appName .. "\\Textures\\LevelUpTex")
	glow:SetSize(223, 115)
	glow:SetTexCoord(0.56054688, 0.99609375, 0.24218750, 0.46679688)
	glow:SetVertexColor( HexToRGB(self:GetConfig('glowColor')) )
	glow:SetAlpha(0)
	self.display_glow = glow

	local glow2 = text:CreateTexture()
	glow2:SetDrawLayer("BORDER")
	glow2:SetTexture("Interface\\AddOns\\" .. appName .. "\\Textures\\LevelUpTex")
	glow2:SetSize(418, 7)
	glow2:SetTexCoord(0.00195313, 0.81835938, 0.01953125, 0.03320313)
	glow2:SetVertexColor( HexToRGB(self:GetConfig('glowColor')) )
	glow2:SetAlpha(0)
	self.display_glow2 = glow2

	if AngryAssign_State.display.hidden then text:Hide() end
	self:UpdateMedia()
	self:UpdateDirection()
end

function AngryAssign:ToggleLock()
	AngryAssign_State.locked = not AngryAssign_State.locked
	if AngryAssign_State.locked then
		self.mover:Hide()
	else
		self.mover:Show()
	end
end

function AngryAssign:ToggleDirection()
	AngryAssign_State.directionUp = not AngryAssign_State.directionUp
	self:UpdateDirection()
end

function AngryAssign:UpdateDirection()
	if AngryAssign_State.directionUp then
		self.display_text:ClearAllPoints()
		self.display_text:SetPoint("BOTTOMLEFT", 0, 8)
		self.display_text:SetPoint("RIGHT", 0, 0)
		self.display_text:SetInsertMode(SCROLLING_MESSAGE_FRAME_INSERT_MODE_BOTTOM)
		self.direction_button:GetNormalTexture():SetTexCoord(0, 0.5, 0.5, 1)
		self.direction_button:GetPushedTexture():SetTexCoord(0.5, 1, 0.5, 1)

		self.display_glow:ClearAllPoints()
		self.display_glow:SetPoint("BOTTOM", 0, -4)
		self.display_glow:SetTexCoord(0.56054688, 0.99609375, 0.24218750, 0.46679688)
		self.display_glow2:ClearAllPoints()
		self.display_glow2:SetPoint("TOP", self.display_glow, "BOTTOM", 0, 6)
	else
		self.display_text:ClearAllPoints()
		self.display_text:SetPoint("TOPLEFT", 0, -8)
		self.display_text:SetPoint("RIGHT", 0, 0)
		self.display_text:SetInsertMode(SCROLLING_MESSAGE_FRAME_INSERT_MODE_TOP)
		self.direction_button:GetNormalTexture():SetTexCoord(0, 0.5, 0, 0.5)
		self.direction_button:GetPushedTexture():SetTexCoord(0.5, 1, 0, 0.5)

		self.display_glow:ClearAllPoints()
		self.display_glow:SetPoint("TOP", 0, 4)
		self.display_glow:SetTexCoord(0.56054688, 0.99609375, 0.46679688, 0.24218750)
		self.display_glow2:ClearAllPoints()
		self.display_glow2:SetPoint("BOTTOM", self.display_glow, "TOP", 0, 0)
	end
	if self.display_text:IsShown() then
		self.display_text:Hide()
		self.display_text:Show()
	end
	self:UpdateDisplayed()
end

function AngryAssign:UpdateBackdrop()
	local first, last
	for lineIndex, visibleLine in ipairs(self.display_text.visibleLines) do
		local messageInfo = self.display_text.historyBuffer:GetEntryAtIndex(lineIndex)
		if messageInfo then
			if not first then first = visibleLine end
			last = visibleLine
		end
	end

	if first and last and self:GetConfig('backdropShow') then
		self.backdrop:ClearAllPoints()
		if AngryAssign_State.directionUp then
			self.backdrop:SetPoint("TOPLEFT", last, "TOPLEFT", -4, 4)
			self.backdrop:SetPoint("BOTTOMRIGHT", first, "BOTTOMRIGHT", 4, -4)
		else
			self.backdrop:SetPoint("TOPLEFT", first, "TOPLEFT", -4, 4)
			self.backdrop:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", 4, -4)
		end
		self.backdrop:SetColorTexture( HexToRGB(self:GetConfig('backdropColor')) )
		self.backdrop:Show()
	else
		self.backdrop:Hide()
	end
end

local editFontName, editFontHeight, editFontFlags
function AngryAssign:UpdateMedia()
	local fontName = LSM:Fetch("font", AngryAssign:GetConfig('fontName'))
	local fontHeight = AngryAssign:GetConfig('fontHeight')
	local fontFlags = AngryAssign:GetConfig('fontFlags')

	if fontFlags == "NONE" then
		fontFlags = ""
	end

	self.display_text:SetTextColor( HexToRGB(self:GetConfig('color')) )
	self.display_text:SetFont(fontName, fontHeight, fontFlags)
	self.display_text:SetSpacing( AngryAssign:GetConfig('lineSpacing') )

	if self.window then
		if self:GetConfig('editBoxFont') then
			if not editFontName then
				editFontName, editFontHeight, editFontFlags = self.window.text.editBox:GetFont()
			end
			self.window.text.editBox:SetFont(fontName, fontHeight, fontFlags)
		elseif editFontName then
			self.window.text.editBox:SetFont(editFontName, editFontHeight, editFontFlags)
		end
	end

	self:UpdateBackdrop()
end

local updateFlasher, updateFlasher2 = nil, nil
function AngryAssign:DisplayUpdateNotification()
	if updateFlasher == nil then
		updateFlasher = self.display_glow:CreateAnimationGroup() 

		-- Flashing in
		local fade1 = updateFlasher:CreateAnimation("Alpha")
		fade1:SetDuration(0.5)
		fade1:SetFromAlpha(0)
		fade1:SetToAlpha(1)
		fade1:SetOrder(1)

		-- Holding it visible for 1 second
		fade1:SetEndDelay(5)

		-- Flashing out
		local fade2 = updateFlasher:CreateAnimation("Alpha")
		fade2:SetDuration(0.5)
		fade2:SetFromAlpha(1)
		fade2:SetToAlpha(0)
		fade2:SetOrder(3)
	end
	if updateFlasher2 == nil then
		updateFlasher2 = self.display_glow2:CreateAnimationGroup() 

		-- Flashing in
		local fade1 = updateFlasher2:CreateAnimation("Alpha")
		fade1:SetDuration(0.5)
		fade1:SetFromAlpha(0)
		fade1:SetToAlpha(1)
		fade1:SetOrder(1)

		-- Holding it visible for 1 second
		fade1:SetEndDelay(5)

		-- Flashing out
		local fade2 = updateFlasher2:CreateAnimation("Alpha")
		fade2:SetDuration(0.5)
		fade2:SetFromAlpha(1)
		fade2:SetToAlpha(0)
		fade2:SetOrder(3)
	end

	updateFlasher:Play()
	updateFlasher2:Play()
end

local function ci_pattern(pattern)
	local p = pattern:gsub("(%%?)(.)", function(percent, letter)
		if percent ~= "" or not letter:match("%a") then
			return percent .. letter
		else
			return string.format("[%s%s]", letter:lower(), letter:upper())
		end
	end)
	return p
end

function AngryAssign:UpdateDisplayedIfNewGroup()
	local newGroup = self:GetCurrentGroup()
	if newGroup ~= currentGroup then
		currentGroup = newGroup
		self:UpdateDisplayed()
	end
end

function AngryAssign:UpdateDisplayed()
    local page = AngryAssign_Pages[ AngryAssign_State.displayed ]
    if not page then 
        self.display_text:Clear()
        self:UpdateBackdrop()
        return 
    end

    local text = page.Contents
    
    -- 1. Prepare Highlight Map (Optimization: O(1) lookup)
    local highlightSet = {}
    local currentGroupStr = 'g' .. (self:GetCurrentGroup() or 0)
    
    for token in string.gmatch( AngryAssign:GetConfig('highlight') , "[^%s%p]+") do
        token = token:lower()
        if token == 'group' then
            highlightSet[currentGroupStr] = true
        else
            highlightSet[token] = true
        end
    end
    local highlightHex = self:GetConfig('highlightColor')

    -- 2. Normalize Pipes
    text = text:gsub("||", "|")

    -- 3. Process Colors (Single Pass)
    text = text:gsub("(|c%w+)", function(c)
        return ColorTable[c:lower()] or c
    end)

    -- 4. Process Tags (Single Pass)
    -- (%b{}) captures anything balanced between { and }
    text = text:gsub("(%b{})", ProcessTag)

    -- 5. Process Highlights (Word Scan)
    -- We only replace if the word exists in our highlightSet
    text = text:gsub("([^%s%p]+)", function(word)
        if highlightSet[word:lower()] then
            return string.format("|cff%s%s|r", highlightHex, word)
        end
        return word -- Return original if no match
    end)

    -- 6. Render
    self.display_text:Clear()
    local lines = { strsplit("\n", text) }
    local lines_count = #lines
    
    for i = 1, lines_count do
        local line
        if AngryAssign_State.directionUp then
            line = lines[i]
        else 
            line = lines[lines_count - i + 1]
        end
        if line == "" then line = " " end
        self.display_text:AddMessage(line)
    end

    self:UpdateBackdrop()
end

function AngryAssign_OutputDisplayed()
	return AngryAssign:OutputDisplayed( AngryAssign:SelectedId() )
end

function AngryAssign:OutputDisplayed(id)
	if not self:PermissionCheck() then
		self:Print( RED_FONT_COLOR_CODE .. "You don't have permission to output a page.|r" )
	end
	if not id then id = AngryAssign_State.displayed end
	local page = AngryAssign_Pages[ id ]
	local channel
	if not isClassic and (IsInGroup(LE_PARTY_CATEGORY_INSTANCE) or IsInRaid(LE_PARTY_CATEGORY_INSTANCE)) then
		channel = "INSTANCE_CHAT"
	elseif IsInRaid() then
		channel = "RAID"
	elseif IsInGroup() then
		channel = "PARTY"
	end
	if channel and page then
		local output = page.Contents

		output = output:gsub("||", "|")
			:gsub(ci_pattern('|r'), "")
			:gsub(ci_pattern('|cblue'), "")
			:gsub(ci_pattern('|cgreen'), "")
			:gsub(ci_pattern('|cred'), "")
			:gsub(ci_pattern('|cyellow'), "")
			:gsub(ci_pattern('|corange'), "")
			:gsub(ci_pattern('|cpink'), "")
			:gsub(ci_pattern('|cpurple'), "")
			:gsub(ci_pattern('|cdruid'), "")
			:gsub(ci_pattern('|chunter'), "")
			:gsub(ci_pattern('|cmage'), "")
			:gsub(ci_pattern('|cpaladin'), "")
			:gsub(ci_pattern('|cpriest'), "")
			:gsub(ci_pattern('|crogue'), "")
			:gsub(ci_pattern('|cshaman'), "")
			:gsub(ci_pattern('|cwarlock'), "")
			:gsub(ci_pattern('|cwarrior'), "")
			:gsub(ci_pattern('{spell%s+(%d+)}'), function(id)
				return GetSpellLink(id)
			end)
			:gsub(ci_pattern('{star}'), "{rt1}")
			:gsub(ci_pattern('{circle}'), "{rt2}")
			:gsub(ci_pattern('{diamond}'), "{rt3}")
			:gsub(ci_pattern('{triangle}'), "{rt4}")
			:gsub(ci_pattern('{moon}'), "{rt5}")
			:gsub(ci_pattern('{square}'), "{rt6}")
			:gsub(ci_pattern('{cross}'), "{rt7}")
			:gsub(ci_pattern('{x}'), "{rt7}")
			:gsub(ci_pattern('{skull}'), "{rt8}")
			:gsub(ci_pattern('{healthstone}'), "{hs}")
			:gsub(ci_pattern('{hs}'), 'Healthstone')
			:gsub(ci_pattern('{icon%s+([%w_]+)}'), '')
			:gsub(ci_pattern('{damage}'), 'Damage')
			:gsub(ci_pattern('{tank}'), 'Tanks')
			:gsub(ci_pattern('{healer}'), 'Healers')
			:gsub(ci_pattern('{dps}'), 'Damage')
			:gsub(ci_pattern('{hunter}'), LOCALIZED_CLASS_NAMES_MALE["HUNTER"])
			:gsub(ci_pattern('{warrior}'), LOCALIZED_CLASS_NAMES_MALE["WARRIOR"])
			:gsub(ci_pattern('{rogue}'), LOCALIZED_CLASS_NAMES_MALE["ROGUE"])
			:gsub(ci_pattern('{mage}'), LOCALIZED_CLASS_NAMES_MALE["MAGE"])
			:gsub(ci_pattern('{priest}'), LOCALIZED_CLASS_NAMES_MALE["PRIEST"])
			:gsub(ci_pattern('{warlock}'), LOCALIZED_CLASS_NAMES_MALE["WARLOCK"])
			:gsub(ci_pattern('{paladin}'), LOCALIZED_CLASS_NAMES_MALE["PALADIN"])
			:gsub(ci_pattern('{druid}'), LOCALIZED_CLASS_NAMES_MALE["DRUID"])
			:gsub(ci_pattern('{shaman}'), LOCALIZED_CLASS_NAMES_MALE["SHAMAN"])

		if not isClassicVanilla then
			output = output:gsub(ci_pattern('{bloodlust}'), "{bl}")
				:gsub(ci_pattern('{bl}'), 'Bloodlust')
				:gsub(ci_pattern('{hero}'), "{heroism}")
				:gsub(ci_pattern('{heroism}'), 'Heroism')

			if not isClassicTBC then
				output = output:gsub(ci_pattern('|cdk'), "|cdeathknight")
					:gsub(ci_pattern('|cdeathknight'), "")
					:gsub(ci_pattern('{dk}'), "{deathknight}")
					:gsub(ci_pattern('{deathknight}'), LOCALIZED_CLASS_NAMES_MALE["DEATHKNIGHT"])
						
				if not isClassicWrath then
					output = output:gsub(ci_pattern('|cmonk'), "")
						:gsub(ci_pattern('|cdh'), "|cdemonhunter")
						:gsub(ci_pattern('|cdemonhunter'), "")
						:gsub(ci_pattern('|cevoker'), "")
						:gsub(ci_pattern('{boss%s+(%d+)}'), function(id)
							return select(5, EJ_GetEncounterInfo(id))
						end)
						:gsub(ci_pattern('{journal%s+(%d+)}'), function(id)
							return C_EncounterJournal.GetSectionInfo(id) and C_EncounterJournal.GetSectionInfo(id).link
						end)
                        :gsub(ci_pattern('{monk}'), LOCALIZED_CLASS_NAMES_MALE["MONK"])
						:gsub(ci_pattern('{dh}'), "{demonhunter}")						
                        :gsub(ci_pattern('{demonhunter}'), LOCALIZED_CLASS_NAMES_MALE["DEMONHUNTER"])
						:gsub(ci_pattern('{evoker}'), LOCALIZED_CLASS_NAMES_MALE["EVOKER"])
				end
			end
        end

        output = output:gsub(ci_pattern('|c%w?%w?%w?%w?%w?%w?%w?%w?'), "")
		
		local lines = { strsplit("\n", output) }
		for _, line in ipairs(lines) do
			if line ~= "" then
				SendChatMessage(line, channel)
			end
		end
	end
end

-----------------
-- Addon Setup --
-----------------

local configDefaults = {
	scale = 1,
	hideoncombat = false,
	fontName = "Friz Quadrata TT",
	fontHeight = 12,
	fontFlags = "NONE",
	highlight = "",
	highlightColor = "ffd200",
	color = "ffffff",
	allowall = false,
	lineSpacing = 0,
	allowplayers = "",
	backdropShow = false,
	backdropColor = "00000080",
	glowColor = "FF0000",
	editBoxFont = false,
}

function AngryAssign:GetConfig(key)
	if AngryAssign_Config[key] == nil then
		return configDefaults[key]
	else
		return AngryAssign_Config[key]
	end
end

function AngryAssign:SetConfig(key, value)
	if configDefaults[key] == value then
		AngryAssign_Config[key] = nil
	else
		AngryAssign_Config[key] = value
	end
end

function AngryAssign:RestoreDefaults()
	AngryAssign_Config = {}
	self:UpdateMedia()
	self:UpdateDisplayed()
	LibStub("AceConfigRegistry-3.0"):NotifyChange("AngryAssign")
end

function AngryAssign:CleanupOrphanedStates()
    if not AngryAssign_State or not AngryAssign_State.tree or not AngryAssign_State.tree.groups then return end

    local count = 0
    -- Iterate over the saved "expanded/collapsed" state of the tree
    for id, _ in pairs(AngryAssign_State.tree.groups) do
        -- Category IDs are stored as negative numbers in the tree group state
        if id < 0 then
            -- Check if the category actually exists (flip ID back to positive)
            if not AngryAssign_Categories[-id] then
                AngryAssign_State.tree.groups[id] = nil
                count = count + 1
            end
        end
    end
end

local blizOptionsPanel
function AngryAssign:OnInitialize()
	if AngryAssign_State == nil then
		AngryAssign_State = { tree = {}, window = {}, display = {}, displayed = nil, locked = false, directionUp = false }
	end
	if AngryAssign_Pages == nil then AngryAssign_Pages = { } end
	if AngryAssign_Config == nil then AngryAssign_Config = { } end
	if AngryAssign_Categories == nil then
		AngryAssign_Categories = { }
	else
		for _, cat in pairs(AngryAssign_Categories) do
			if cat.Children then
				for _, pageId in ipairs(cat.Children) do
					local page = AngryAssign_Pages[pageId]
					if page then
						page.CategoryId = cat.Id
					end
				end
				cat.Children = nil
			end
		end
	end

	-- Run cleanup once on load
    self:CleanupOrphanedStates()

	local ver = AngryAssign_Version
	if ver:sub(1,1) == "@" then ver = "dev" end
	
	local options = {
		name = appName .. " " .. ver,
		handler = AngryAssign,
		type = "group",
		args = {
			window = {
				type = "execute",
				order = 3,
				name = "Toggle Window",
				desc = "Shows/hides the edit window (also available in game keybindings)",
				func = function() AngryAssign_ToggleWindow() end
			},
			help = {
				type = "execute",
				order = 99,
				name = "Help",
				hidden = true,
				func = function()
					LibStub("AceConfigCmd-3.0").HandleCommand(self, "aa", "AngryAssign", "")
				end
			},
			toggle = {
				type = "execute",
				order = 1,
				name = "Toggle Display",
				desc = "Shows/hides the display frame (also available in game keybindings)",
				func = function() AngryAssign_ToggleDisplay() end
			},
			deleteall = {
				type = "execute",
				name = "Delete All Pages",
				desc = "Deletes all pages",
				order = 4,
				hidden = true,
				cmdHidden = false,
				confirm = true,
				func = function()
					AngryAssign_State.displayed = nil
					AngryAssign_Pages = {}
					AngryAssign_Categories = {}
					self:UpdateTree()
					self:UpdateSelected()
					self:UpdateDisplayed()
					if self.window then self.window.tree:SetSelected(nil) end
					self:Print("All pages have been deleted.")
				end
			},
			defaults = {
				type = "execute",
				name = "Restore Defaults",
				desc = "Restore configuration values to their default settings",
				order = 10,
				hidden = true,
				cmdHidden = false,
				confirm = true,
				func = function()
					self:RestoreDefaults()
				end
			},
			output = {
				type = "execute",
				name = "Output",
				desc = "Outputs currently displayed assignents to chat",
				order = 11,
				hidden = true,
				cmdHidden = false,
				confirm = true,
				func = function()
					self:OutputDisplayed()
				end
			},
			send = {
				type = "input",
				name = "Send and Display",
				desc = "Sends page with specified name",
				order = 12,
				hidden = true,
				cmdHidden = false,
				confirm = true,
				get = function(info) return "" end,
				set = function(info, val)
					local result = self:DisplayPageByName( val:trim() )
					if result == false then
						self:Print( RED_FONT_COLOR_CODE .. "A page with the name \""..val:trim().."\" could not be found.|r" )
					elseif not result then 
						self:Print( RED_FONT_COLOR_CODE .. "You don't have permission to send a page.|r" )
					end
				end
			},
			clear = {
				type = "execute",
				name = "Clear",
				desc = "Clears currently displayed page",
				order = 13,
				hidden = true,
				cmdHidden = false,
				confirm = true,
				func = function()
					AngryAssign_ClearPage()
				end
			},
			backup = {
				type = "execute",
				order = 20,
				name = "Backup Pages",
				desc = "Creates a backup of all pages with their current contents",
				func = function() 
					self:CreateBackup()
					self:Print("Created a backup of all pages.")
				end
			},
			resetposition = {
				type = "execute",
				order = 22,
				name = "Reset Position",
				desc = "Resets position for the assignment display",
				func = function()
					self:ResetPosition()
				end
			},
			version = {
				type = "execute",
				order = 21,
				name = "Version Check",
				desc = "Displays a list of all users (in the raid) running the addon and the version they're running",
				func = function()
					if (IsInRaid() or IsInGroup()) then
						versionList = {} -- start with a fresh version list, when displaying it
						self:SendOutMessage({ "VER_QUERY" }) 
						self:ScheduleTimer("VersionCheckOutput", 3)
						self:Print("Version check running...")
					else
						self:Print("You must be in a raid group to run the version check.")
					end
				end
			},
			lock = {
				type = "execute",
				order = 2,
				name = "Toggle Lock",
				desc = "Shows/hides the display mover (also available in game keybindings)",
				func = function() self:ToggleLock() end
			},
			config = { 
				type = "group",
				order = 5,
				name = "General",
				inline = true,
				args = {
					highlight = {
						type = "input",
						order = 1,
						name = "Highlight",
						desc = "A list of words to highlight on displayed pages (separated by spaces or punctuation)\n\nUse 'Group' to highlight the current group you are in, ex. G2",
						get = function(info) return self:GetConfig('highlight') end,
						set = function(info, val)
							self:SetConfig('highlight', val)
							self:UpdateDisplayed()
						end
					},
					hideoncombat = {
						type = "toggle",
						order = 3,
						name = "Hide on Combat",
						desc = "Enable to hide display frame upon entering combat",
						get = function(info) return self:GetConfig('hideoncombat') end,
						set = function(info, val)
							self:SetConfig('hideoncombat', val)
						end
					},
					scale = {
						type = "range",
						order = 4,
						name = "Scale",
						desc = "Sets the scale of the edit window",
						min = 0.3,
						max = 3,
						get = function(info) return self:GetConfig('scale') end,
						set = function(info, val)
							self:SetConfig('scale', val)
							if AngryAssign.window then AngryAssign.window.frame:SetScale(val) end
						end
					},
					backdrop = {
						type = "toggle",
						order = 5,
						name = "Display Backdrop",
						desc = "Enable to display a backdrop behind the assignment display",
						get = function(info) return self:GetConfig('backdropShow') end,
						set = function(info, val)
							self:SetConfig('backdropShow', val)
							self:UpdateBackdrop()
						end
					},
					backdropcolor = {
						type = "color",
						order = 6,
						name = "Backdrop Color",
						desc = "The color used by the backdrop",
						hasAlpha = true,
						get = function(info)
							local hex = self:GetConfig('backdropColor')
							return HexToRGB(hex)
						end,
						set = function(info, r, g, b, a)
							self:SetConfig('backdropColor', RGBToHex(r, g, b, a))
							self:UpdateMedia()
							self:UpdateDisplayed()
						end
					},
					updatecolor = {
						type = "color",
						order = 7,
						name = "Update Notification Color",
						desc = "The color used by the update notification glow",
						get = function(info)
							local hex = self:GetConfig('glowColor')
							return HexToRGB(hex)
						end,
						set = function(info, r, g, b)
							self:SetConfig('glowColor', RGBToHex(r, g, b))
							self.display_glow:SetVertexColor(r, g, b)
							self.display_glow2:SetVertexColor(r, g, b)
						end
					}
				}
			},
			font = { 
				type = "group",
				order = 6,
				name = "Font",
				inline = true,
				args = {
					fontname = {
						type = 'select',
						order = 1,
						dialogControl = 'LSM30_Font',
						name = 'Face',
						desc = 'Sets the font face used to display a page',
						values = LSM:HashTable("font"),
						get = function(info) return self:GetConfig('fontName') end,
						set = function(info, val)
							self:SetConfig('fontName', val)
							self:UpdateMedia()
						end
					},
					fontheight = {
						type = "range",
						order = 2,
						name = "Size",
						desc = function() 
							return "Sets the font height used to display a page"
						end,
						min = 6,
						max = 24,
						step = 1,
						get = function(info) return self:GetConfig('fontHeight') end,
						set = function(info, val)
							self:SetConfig('fontHeight', val)
							self:UpdateMedia()
						end
					},
					fontflags = {
						type = "select",
						order = 3,
						name = "Outline",
						desc = "Sets the font outline used to display a page",
						values = { ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline", ["MONOCHROMEOUTLINE"] = "Monochrome" },
						get = function(info) return self:GetConfig('fontFlags') end,
						set = function(info, val)
							self:SetConfig('fontFlags', val)
							self:UpdateMedia()
						end
					},
					color = {
						type = "color",
						order = 4,
						name = "Normal Color",
						desc = "The normal color used to display assignments",
						get = function(info)
							local hex = self:GetConfig('color')
							return HexToRGB(hex)
						end,
						set = function(info, r, g, b)
							self:SetConfig('color', RGBToHex(r, g, b))
							self:UpdateMedia()
							self:UpdateDisplayed()
						end
					},
					highlightcolor = {
						type = "color",
						order = 5,
						name = "Highlight Color",
						desc = "The color used to emphasize highlighted words",
						get = function(info)
							local hex = self:GetConfig('highlightColor')
							return HexToRGB(hex)
						end,
						set = function(info, r, g, b)
							self:SetConfig('highlightColor', RGBToHex(r, g, b))
							self:UpdateDisplayed()
						end
					},
					linespacing = {
						type = "range",
						order = 6,
						name = "Line Spacing",
						desc = function()
							return "Sets the line spacing used to display a page"
						end,
						min = 0,
						max = 10,
						step = 1,
						get = function(info) return self:GetConfig('lineSpacing') end,
						set = function(info, val)
							self:SetConfig('lineSpacing', val)
							self:UpdateMedia()
							self:UpdateDisplayed()
						end
					},
					editBoxFont =  {
						type = "toggle",
						order = 7,
						name = "Change Edit Box Font",
						desc = "Enable to set edit box font to display font",
						get = function(info) return self:GetConfig('editBoxFont') end,
						set = function(info, val)
							self:SetConfig('editBoxFont', val)
							self:UpdateMedia()
						end
					},
				}
			},
			permissions = { 
				type = "group",
				order = 7,
				name = "Permissions",
				inline = true,
				args = {
					allowall = {
						type = "toggle",
						order = 1,
						name = "Allow All",
						desc = "Enable to allow changes from any raid assistant, even if you aren't in a guild raid",
						get = function(info) return self:GetConfig('allowall') end,
						set = function(info, val)
							self:SetConfig('allowall', val)
							self:PermissionsUpdated()
						end
					},
					allowplayers = {
						type = "input",
						order = 2,
						name = "Allow Players",
						desc = "A list of players that when they are the raid leader to allow changes from all raid assistants",
						get = function(info) return self:GetConfig('allowplayers') end,
						set = function(info, val)
							self:SetConfig('allowplayers', val)
							self:PermissionsUpdated()
						end
					},
				}
			}
		}
	}

	self:RegisterChatCommand("aa", "ChatCommand")
	LibStub("AceConfig-3.0"):RegisterOptionsTable("AngryAssign", options)

	blizOptionsPanel = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("AngryAssign", AngryAssign_Title)
	blizOptionsPanel.default = function() self:RestoreDefaults() end
end

function AngryAssign:ChatCommand(input)
  if not input or input:trim() == "" then
	Settings.OpenToCategory(AngryAssign_Title)
  else
    LibStub("AceConfigCmd-3.0").HandleCommand(self, "aa", "AngryAssign", input)
  end
end

function AngryAssign:OnEnable()
	self:ResetOfficerRank()
	self:CreateDisplay()
	
	self:ScheduleTimer("AfterEnable", 4)

	self:RegisterEvent("PLAYER_REGEN_DISABLED")
	self:RegisterEvent("PLAYER_GUILD_UPDATE")
	self:RegisterEvent("GUILD_ROSTER_UPDATE")

	if isClassic then
		GuildRoster()
	end

	LSM.RegisterCallback(self, "LibSharedMedia_Registered", "UpdateMedia")
	LSM.RegisterCallback(self, "LibSharedMedia_SetGlobal", "UpdateMedia")
end


function AngryAssign:PARTY_LEADER_CHANGED()
	self:PermissionsUpdated()
	if AngryAssign_State.displayed and not (self:IsGuildRaid() or self:IsValidRaid()) then self:ClearDisplayed() end
end

function AngryAssign:PARTY_CONVERTED_TO_RAID()
	self:SendRequestDisplay()
	self:SendVerQuery()
	self:UpdateDisplayedIfNewGroup()
end

function AngryAssign:GROUP_JOINED()
	versionList = {} -- Reset version tracking when joining a new group
	self:SendVerQuery()
	self:UpdateDisplayedIfNewGroup()
	self:ScheduleTimer("SendRequestDisplay", 0.5)
end

function AngryAssign:PLAYER_REGEN_DISABLED()
	if AngryAssign:GetConfig('hideoncombat') then
		self:HideDisplay()
	end
end

function AngryAssign:GROUP_ROSTER_UPDATE()
	self:UpdateSelected()
	if not (IsInRaid() or IsInGroup()) then
		if AngryAssign_State.displayed then self:ClearDisplayed() end
		currentGroup = nil
		warnedPermission = false
	else
		self:UpdateDisplayedIfNewGroup()
	end
end

function AngryAssign:PLAYER_GUILD_UPDATE()
	self:ResetOfficerRank()
	self:PermissionsUpdated()
end

function AngryAssign:GUILD_ROSTER_UPDATE(...)
	local canRequestRosterUpdate = ...
	self:ResetOfficerRank()
	if canRequestRosterUpdate and isClassic then
		GuildRoster()
	end
end

function AngryAssign:AfterEnable()
	self:RegisterComm(comPrefix, "ReceiveMessage")
	comStarted = true

	if not (IsInRaid() or IsInGroup()) then
		self:ClearDisplayed()
	end

	--self:RegisterEvent("PARTY_CONVERTED_TO_RAID")
	self:RegisterEvent("PARTY_LEADER_CHANGED")
	self:RegisterEvent("GROUP_JOINED")
	self:RegisterEvent("GROUP_ROSTER_UPDATE")

	self:SendRequestDisplay()
	self:UpdateDisplayedIfNewGroup()
	self:SendVerQuery()
end
