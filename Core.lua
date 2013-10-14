local AngryAssign = LibStub("AceAddon-3.0"):NewAddon("AngryAssignments", "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceTimer-3.0")
local AceGUI = LibStub("AceGUI-3.0")
local libS = LibStub("AceSerializer-3.0")
local libC = LibStub("LibCompress")
local lwin = LibStub("LibWindow-1.1")
local libCE = libC:GetAddonEncodeTable()
local LSM = LibStub("LibSharedMedia-3.0")

BINDING_HEADER_AngryAssign = "Angry Assignments"
BINDING_NAME_AngryAssign_WINDOW = "Toggle Window"
BINDING_NAME_AngryAssign_LOCK = "Toggle Lock"
BINDING_NAME_AngryAssign_DISPLAY = "Toggle Display"

local AngryAssign_Version = '@project-version@'
local AngryAssign_Timestamp = '@project-date-integer@'

local default_channel = "GUILD"
local protocolVersion = 1
local comPrefix = "AnAss"..protocolVersion
local updateFrequency = 2
local pageLastUpdate = {}
local pageTimerId = {}
local displayLastUpdate = nil
local displayTimerId = nil

local officerGuildRank = 2 -- The lowest officer guild rank

-- Used for version tracking
local warnedOOD = false
local versionList = {}

-- Pages Saved Variable Format 
-- 	AngryAssign_Pages = {
-- 		[Id] = { Id = "1231", Updated = time(), Name = "Name", Contents = "..." },
--		...
-- 	}
--
-- Format for our addon communication
--
-- { "PAGE", [Id], [Last Update Timestamp], [Name], [Contents] }
-- Sent when a page is updated. Id is a random unique value. Checks that sender is Officer or Promoted. Uses GUILD.
--
-- { "REQUEST_PAGE", [Id] }
-- Asks to be sent PAGE with given Id. Response is a throttled PAGE. Uses WHISPER to raid leader.
--
-- { "DISPLAY", [Id], [Last Update Timestamp] }
-- Raid leader / promoted sends out when new page is to be displayed. Checks that sender is Officer or Promoted. Uses RAID.
--
-- { "REQUEST_DISPLAY" }
-- Asks to be sent DISPLAY. Response is a throttled DISPLAY. Uses WHISPER to raid leader.
--
-- { "VER_QUERY" }
-- { "VERSION", [Version], [Project Timestamp] }

-- Constants for dealing with our addon communication
local COMMAND = 1

local PAGE_Id = 2
local PAGE_Updated = 3
local PAGE_Name = 4
local PAGE_Contents = 5

local REQUEST_PAGE_Id = 2

local DISPLAY_Id = 2
local DISPLAY_Updated = 3

local VERSION_Version = 2
local VERSION_Timestamp = 3

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

function AngryAssign:SendMessage(data, channel, target)
	local one = libS:Serialize( data )
	local two = libC:CompressHuffman(one)
	local final = libCE:Encode(two)
	local destChannel = channel or default_channel

	if destChannel ~= "RAID" or IsInRaid(LE_PARTY_CATEGORY_HOME) then
		-- self:Print("Sending "..data[COMMAND].." over "..destChannel.." to "..tostring(target))
		self:SendCommMessage(comPrefix, final, destChannel, target, "NORMAL")
	end
end

function AngryAssign:ProcessMessage(sender, data)
	local cmd = data[COMMAND]
	-- self:Print("Received "..data[COMMAND].." from "..sender)
	if cmd == "PAGE" then
		if not self:PermissionCheck(sender) or sender == UnitName('player') then return end

		local id = data[PAGE_Id]
		local page = AngryAssign_Pages[id]
		if page then
			if page.Updated >= data[PAGE_Updated] then return end -- The version sent it not newer then the one we already have

			page.Updated = data[PAGE_Updated]
			page.Name = data[PAGE_Name]
			page.Contents = data[PAGE_Contents]

			if self:SelectedId() == id then
				self:SelectedUpdated(sender)
				self:UpdateSelected()
			end
		else
			AngryAssign_Pages[id] = { Id = id, Updated = data[PAGE_Updated], Name = data[PAGE_Name], Contents = data[PAGE_Contents] }
		end
		if AngryAssign_State.displayed == id then
			self:UpdateDisplayed()
			self:ShowDisplay()
			self:DisplayUpdateNotification()
		end
		self:UpdateTree()


	elseif cmd == "DISPLAY" then
		if not self:PermissionCheck(sender) then return end

		local id = data[DISPLAY_Id]
		local updated = data[DISPLAY_Updated]
		local page = AngryAssign_Pages[id]
		if id and (not page or updated > page.Updated) then
			self:SendRequestPage(id, sender)
		end
		
		if AngryAssign_State.displayed ~= id then
			AngryAssign_State.displayed = id
			self:UpdateTree()
			self:UpdateDisplayed()
			self:ShowDisplay()
			self:DisplayUpdateNotification()
		end

	elseif cmd == "REQUEST_DISPLAY" then

		self:SendDisplay( AngryAssign_State.displayed )

	elseif cmd == "REQUEST_PAGE" then
		
		self:SendPage( data[REQUEST_PAGE_Id] )

	elseif cmd == "VER_QUERY" then
		local revToSend
		local timestampToSend
		if AngryAssign_Version:sub(1,1) == "@" then verToSend = "dev" else verToSend = AngryAssign_Version end
		if AngryAssign_Timestamp:sub(1,1) == "@" then timestampToSend = "dev" else timestampToSend = tonumber(AngryAssign_Timestamp) end
		self:SendMessage({ "VERSION", [VERSION_Version] = verToSend, [VERSION_Timestamp] = timestampToSend })


	elseif cmd == "VERSION" then
		local localTimestamp, ver, timestamp
		
		if AngryAssign_Timestamp:sub(1,1) == "@" then localTimestamp = nil else localTimestamp = tonumber(AngryAssign_Timestamp) end
		ver = data[VERSION_Version]
		timestamp = data[VERSION_Timestamp]
			
		if localTimestamp ~= nil and timestamp ~= "dev" and timestamp > localTimestamp and not warnedOOD then 
			self:Print("Your version of Angry Assignments is out of date! Download the latest version from www.wowace.com.")
			warnedOOD = true
		end

		local found = false
		for i,v in pairs(versionList) do
			if (v["name"] == sender) then
				v["version"] = ver
				found = true
			end
		end
		if not found then tinsert(versionList, {name = sender, version = ver}) end

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
	self:SendMessage({ "PAGE", [PAGE_Id] = page.Id, [PAGE_Updated] = page.Updated, [PAGE_Name] = page.Name, [PAGE_Contents] = page.Contents })
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
		self:SendMessage({ "DISPLAY", [DISPLAY_Id] = nil, [DISPLAY_Updated] = nil }, "RAID") 
	else
		self:SendMessage({ "DISPLAY", [DISPLAY_Id] = page.Id, [DISPLAY_Updated] = page.Updated }, "RAID") 
	end
end

function AngryAssign:SendRequestDisplay()
	if IsInRaid(LE_PARTY_CATEGORY_HOME) then
		local to = self:GetRaidLeader()
		if to then self:SendMessage({ "REQUEST_DISPLAY" }, "WHISPER", to) end
	end
end

function AngryAssign:SendRequestPage(id, to)
	if IsInRaid(LE_PARTY_CATEGORY_HOME) or to then
		if not to then to = self:GetRaidLeader() end
		if to then self:SendMessage({ "REQUEST_PAGE", [REQUEST_PAGE_Id] = id }, "WHISPER", to) end
	end
end

function AngryAssign:GetRaidLeader()
	if IsInRaid(LE_PARTY_CATEGORY_HOME) then
		for i = 1, GetNumGroupMembers() do
			local name, rank = GetRaidRosterInfo(i)
			if rank == 2 then
				return name
			end
		end
	end
	return nil
end

function AngryAssign:VersionCheckOutput()
	local versionliststr = ""
	for i,v in pairs(versionList) do
		versionliststr = versionliststr..v["name"].."-|cFFFF0000"..v["version"].."|r "
	end
	self:Print(versionliststr)
	versionliststr = ""
	if IsInRaid(LE_PARTY_CATEGORY_HOME) then
		for i = 1, GetNumGroupMembers() do
			local name = GetRaidRosterInfo(i)	
			local found = false
			for i,v in pairs(versionList) do
				if v["name"] == name then
					found = true
					break
				end
			end
			if not found then versionliststr = versionliststr .. " " .. name end
		end
	end
	if versionliststr ~= "" then self:Print("Not running:"..versionliststr) end
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
			button1 = OKAY,
			button2 = CANCEL,
			OnAccept = function(self)
				local text = self.editBox:GetText()
				if text ~= "" then AngryAssign:CreatePage(text) end
			end,
			EditBoxOnEnterPressed = function(self)
				local text = self:GetParent().editBox:GetText()
				if text ~= "" then AngryAssign:CreatePage(text) end
				self:GetParent():Hide()
			end,
			text = "New page name:",
			hasEditBox = true,
			whileDead = true,
			EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
			hideOnEscape = true,
			preferredIndex = 3
		}
	end
	StaticPopup_Show(popup_name)
end

local function AngryAssign_RenamePage(widget, event, value)
	local page = AngryAssign:Get()
	if not page then return end

	local popup_name = "AngryAssign_RenamePage_"..page.Id
	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			button1 = OKAY,
			button2 = CANCEL,
			OnAccept = function(self)
				local text = self.editBox:GetText()
				AngryAssign:RenamePage(page.Id, text)
			end,
			EditBoxOnEnterPressed = function(self)
				local text = self:GetParent().editBox:GetText()
				AngryAssign:RenamePage(page.Id, text)
				self:GetParent():Hide()
			end,
			OnShow = function(self)
				self.editBox:SetText(page.Name)
			end,
			whileDead = true,
			hasEditBox = true,
			EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
			hideOnEscape = true,
			preferredIndex = 3
		}
	end
	StaticPopupDialogs[popup_name].text = 'Rename page "'.. page.Name ..'" to:'

	StaticPopup_Show(popup_name)
end

local function AngryAssign_DeletePage(widget, event, value)
	local page = AngryAssign:Get()
	if not page then return end

	local popup_name = "AngryAssign_DeletePage_"..page.Id
	if StaticPopupDialogs[popup_name] == nil then
		StaticPopupDialogs[popup_name] = {
			button1 = OKAY,
			button2 = CANCEL,
			OnAccept = function(self)
				AngryAssign:DeletePage(page.Id)
			end,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3
		}
	end
	StaticPopupDialogs[popup_name].text = 'Are you sure you want to delete page "'.. page.Name ..'"?'

	StaticPopup_Show(popup_name)
end

local function AngryAssign_RevertPage(widget, event, value)
	if not AngryAssign.window then return end
	AngryAssign.window.text:SetText( AngryAssign_Pages[AngryAssign:SelectedId()].Contents )
	AngryAssign.window.button_revert:SetDisabled(true)
end

local function AngryAssign_DisplayPage(widget, event, value)
	if not AngryAssign:PermissionCheck() then return end
	local id = AngryAssign:SelectedId()

	AngryAssign:TouchPage( id )
	AngryAssign:SendPage( id, true )
	AngryAssign:SendDisplay( id, true )
	
	if IsInRaid(LE_PARTY_CATEGORY_HOME) then
		AngryAssign_State.displayed = AngryAssign:SelectedId()
		AngryAssign:UpdateDisplayed()
		AngryAssign:ShowDisplay()
		AngryAssign:UpdateTree()
	end
end

local function AngryAssign_TextChanged(widget, event, value)
	AngryAssign.window.button_revert:SetDisabled(false)
end

local function AngryAssign_TextEntered(widget, event, value)
	AngryAssign:UpdateContents(AngryAssign:SelectedId(), value)
	AngryAssign.window.button_revert:SetDisabled(true)
end

function AngryAssign:CreateWindow()
	local window = AceGUI:Create("Frame")
	window:SetTitle("Angry Assignments")
	window:SetStatusText("")
	window:SetLayout("Flow")
	if AngryAssign_Config.scale then window.frame:SetScale(AngryAssign_Config.scale) end
	window:SetStatusTable(AngryAssign_State.window)
	window:Hide()
	AngryAssign.window = window

	AngryAssign_Window = window.frame
	window.frame:SetFrameStrata("HIGH")
	window.frame:SetFrameLevel(1)
	tinsert(UISpecialFrames, "AngryAssign_Window")

	local version = AngryAssign_Version
	if version:sub(1,1) == "@" then version = "dev" end
	window:SetStatusText(version)
	window.statustext:SetJustifyH("RIGHT")

	local tree = AceGUI:Create("TreeGroup")
	tree:SetTree( self:GetTree() )
	tree:SelectByValue(1)
	tree:SetStatusTable(AngryAssign_State.tree)
	tree:SetFullWidth(true)
	tree:SetFullHeight(true)
	tree:SetLayout("Flow")
	tree:SetCallback("OnGroupSelected", function(widget, event, value) AngryAssign:UpdateSelected(true) end)
	window:AddChild(tree)
	window.tree = tree

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
	button_revert:SetWidth(75)
	button_revert:SetHeight(22)
	button_revert:ClearAllPoints()
	button_revert:SetDisabled(true)
	button_revert:SetPoint("BOTTOMLEFT", text.button, "BOTTOMRIGHT", 6, 0)
	button_revert:SetCallback("OnClick", AngryAssign_RevertPage)
	tree:AddChild(button_revert)
	window.button_revert = button_revert

	window:PauseLayout()
	local button_add = AceGUI:Create("Button")
	button_add:SetText("Add")
	button_add:SetWidth(70)
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
	button_rename:SetCallback("OnClick", AngryAssign_RenamePage)
	window:AddChild(button_rename)
	window.button_rename = button_rename

	local button_delete = AceGUI:Create("Button")
	button_delete:SetText("Delete")
	button_delete:SetWidth(70)
	button_delete:SetHeight(19)
	button_delete:ClearAllPoints()
	button_delete:SetPoint("BOTTOMLEFT", button_rename.frame, "BOTTOMRIGHT", 5, 0)
	button_delete:SetCallback("OnClick", AngryAssign_DeletePage)
	window:AddChild(button_delete)
	window.button_delete = button_delete

	self:UpdateSelected(true)
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

function AngryAssign:GetTree()
	local ret = {}

	for _, page in pairs(AngryAssign_Pages) do
		if page.Id == AngryAssign_State.displayed then
			tinsert(ret, { value = page.Id, text = page.Name, icon = "Interface\\BUTTONS\\UI-GuildButton-MOTD-Up" })
		else
			tinsert(ret, { value = page.Id, text = page.Name })
		end
	end

	return ret
end

function AngryAssign:UpdateTree(id)
	if not self.window then return end
	self.window.tree:SetTree( self:GetTree() )
	if id then
		self.window.tree:SelectByValue( id )
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
	end
	if page and permission then
		self.window.button_rename:SetDisabled(false)
		self.window.button_revert:SetDisabled(not self.window.text.button:IsEnabled())
		self.window.button_display:SetDisabled(false)
		self.window.text:SetDisabled(false)
	else
		self.window.button_rename:SetDisabled(true)
		self.window.button_revert:SetDisabled(true)
		self.window.button_display:SetDisabled(true)
		self.window.text:SetDisabled(true)
	end
	if page then
		self.window.button_delete:SetDisabled(false)
	else
		self.window.button_delete:SetDisabled(true)
	end
	if permission then
		self.window.button_add:SetDisabled(false)
	else
		self.window.button_add:SetDisabled(true)
	end
end

----------------------------------
-- Performing changes functions --
----------------------------------

function AngryAssign:SelectedId()
	return AngryAssign_State.tree.selected
end

function AngryAssign:Get(id)
	if id == nil then id = self:SelectedId() end
	return AngryAssign_Pages[id]
end

function AngryAssign:CreatePage(name)
	if not self:PermissionCheck() then return end
	local id = math.random(2000000000)

	AngryAssign_Pages[id] = { Id = id, Updated = time(), Name = name, Contents = "" }
	self:UpdateTree(id)
	self:SendPage(id, true)
end

function AngryAssign:RenamePage(id, name)
	local page = self:Get(id)
	if not page or not self:PermissionCheck() then return end

	page.Name = name
	page.Updated = time()

	self:SendPage(id, true)
	self:UpdateTree()
	if AngryAssign_State.displayed == id then
		self:UpdateDisplayed()
		self:ShowDisplay()
	end
end

function AngryAssign:DeletePage(id)
	AngryAssign_Pages[id] = nil
	if self.window and self:SelectedId() == id then
		self.window.tree:SetSelected(nil)
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

function AngryAssign:UpdateContents(id, value)
	if not self:PermissionCheck() then return end
	local page = self:Get(id)
	if not page then return end

	page.Contents = value:gsub('^%s+', ''):gsub('%s+$', '')
	page.Updated = time()

	self:SendPage(id, true)
	self:UpdateSelected(true)
	if AngryAssign_State.displayed == id then
		self:UpdateDisplayed()
		self:ShowDisplay()
		self:DisplayUpdateNotification()
	end
end

function AngryAssign:GetGuildRank(player)
	for i = 1, GetNumGuildMembers() do
		local name, _, rankIndex = GetGuildRosterInfo(i)
		if name and (name == player) then
			return rankIndex 
		end
	end
	return 100
end

function AngryAssign:ClearDisplayed()
	AngryAssign_State.displayed = nil
	self:UpdateDisplayed()
	self:UpdateTree()
end

function AngryAssign:PermissionCheck(sender)
	if not sender then sender = UnitName('player') end

	if sender == 'Ermod' then return true end


	if self:GetGuildRank(sender) <= officerGuildRank then
		return true
	elseif IsInRaid(LE_PARTY_CATEGORY_HOME) and (UnitIsGroupLeader(sender) or UnitIsGroupAssistant(sender)) and self:GetGuildRank(self:GetRaidLeader()) <= officerGuildRank then
		return true
	else
		return false
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
end
local function Mover_MouseDown(frame) frame:GetParent():StartMoving() end
local function Mover_MouseUp(frame)
	local display = frame:GetParent()
	display:StopMovingOrSizing()
	lwin.SavePosition(display)
end

function AngryAssign_ToggleDisplay()
	AngryAssign:ToggleDisplay()
end

function AngryAssign:ShowDisplay()
	AngryAssign.display_text:Show() 
	AngryAssign_State.display.hidden = false
end

function AngryAssign:HideDisplay()
	AngryAssign.display_text:Hide()
	AngryAssign_State.display.hidden = true
end

function AngryAssign:ToggleDisplay()
	if AngryAssign.display_text:IsShown() then 
		AngryAssign:HideDisplay()
	else
		AngryAssign:ShowDisplay()
	end
end


function AngryAssign:CreateDisplay()
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetPoint("CENTER",0,0)
	frame:SetWidth(AngryAssign_State.display.width or 300)
	frame:SetHeight(1)
	frame:SetMovable(true)
	frame:SetResizable(true)
	frame:SetMinResize(180,1)
	frame:SetMaxResize(830,1)

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

	local mover = CreateFrame("Frame", nil, frame)
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
	label:SetText("Angry Assignments")

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
	dragtex:SetTexture("Interface\\AddOns\\AngryAssignments\\Textures\\draghandle")
	dragtex:SetWidth(16)
	dragtex:SetHeight(16)
	dragtex:SetBlendMode("ADD")
	dragtex:SetPoint("CENTER", drag)

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
		self.display_text:SetInsertMode("BOTTOM")
		self.direction_button:GetNormalTexture():SetTexCoord(0, 0.5, 0.5, 1)
		self.direction_button:GetPushedTexture():SetTexCoord(0.5, 1, 0.5, 1)
	else
		self.display_text:ClearAllPoints()
		self.display_text:SetPoint("TOPLEFT", 0, -8)
		self.display_text:SetPoint("RIGHT", 0, 0)
		self.display_text:SetInsertMode("TOP")
		self.direction_button:GetNormalTexture():SetTexCoord(0, 0.5, 0, 0.5)
		self.direction_button:GetPushedTexture():SetTexCoord(0.5, 1, 0, 0.5)
	end
	if self.display_text:IsShown() then
		self.display_text:Hide()
		self.display_text:Show()
	end
	self:UpdateDisplayed()
end

function AngryAssign:UpdateMedia()
	local fontName = LSM:Fetch("font", AngryAssign_Config.fontName)
	local fontHeight = AngryAssign_Config.fontHeight
	local fontFlags = AngryAssign_Config.fontFlags
	self.display_text:SetFont(fontName, fontHeight, fontFlags)
end

function AngryAssign:DisplayUpdateNotification()
end

function AngryAssign:UpdateDisplayed()
	local page = AngryAssign_Pages[ AngryAssign_State.displayed ]
	if page then
		local text = page.Contents

		text = text:gsub("||", "|")
		for token in string.gmatch( AngryAssign_Config.highlight or "" , "[^%s%p]+") do
			text = text:gsub(token, NORMAL_FONT_COLOR_CODE ..token.."|r")
		end

		text = text:gsub("{[Ss][Tt][Aa][Rr]}", "{rt1}")
			:gsub("{[Cc][Ii][Rr][Cc][Ll][Ee]}", "{rt2}")
			:gsub("{[Dd][Ii][Aa][Mm][Oo][Nn][Dd]}", "{rt3}")
			:gsub("{[Tt][Rr][Ii][Aa][Nn][Gg][Ll][Ee]}", "{rt4}")
			:gsub("{[Mm][Oo][Oo][Nn]}", "{rt5}")
			:gsub("{[Ss][Qq][Uu][Aa][Rr][Ee]}", "{rt6}")
			:gsub("{[Cc][Rr][Oo][Ss][Ss]}", "{rt7}")
			:gsub("{[Xx]}", "{rt7}")
			:gsub("{[Ss][Kk][Uu][Ll][Ll]}", "{rt8}")
			:gsub("{[Rr][Tt]([1-8])}", "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%1:0|t" )
			:gsub("{[Hh][Ee][Aa][Ll][Tt][Hh][Ss][Tt][Oo][Nn][Ee]}", "{hs}")
			:gsub("{[Hh][Ss]}", "|TInterface\\Icons\\INV_Stone_04:0|t")
			:gsub("{[Bb][Ll][Oo][Oo][Dd][Ll][Uu][Ss][Tt]}", "{bl}")
			:gsub("{[Bb][Ll]}", "|TInterface\\Icons\\SPELL_Nature_Bloodlust:0|t")
			:gsub("{[Ii][Cc][Oo][Nn]%s+([%w_]+)}", "|TInterface\\Icons\\%1:0|t")

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
	else
		self.display_text:Clear()
	end
end


-----------------
-- Addon Setup --
-----------------

function AngryAssign:OnInitialize()
	if AngryAssign_State == nil then AngryAssign_State = { tree = {}, window = {}, display = {}, displayed = nil, locked = false, directionUp = false } end
	if AngryAssign_Pages == nil then AngryAssign_Pages = { } end
	if AngryAssign_Config == nil then AngryAssign_Config = { scale = 1, fontName = "Friz Quadrata TT", fontHeight = 12, fontFlags = "NONE" } end


	local options = {
		name = "Angry Assignments",
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
				func = function()
					AngryAssign_State.displayed = nil
					AngryAssign_Pages = {}
					AngryAssign:UpdateTree()
					AngryAssign:UpdateSelected()
					AngryAssign:UpdateDisplayed()
					if AngryAssign.window then AngryAssign.window.tree:SetSelected(nil) end
					AngryAssign:Print("All pages have been deleted.")
				end
			},
			version = {
				type = "execute",
				order = 7,
				name = "Version Check",
				desc = "Displays a list of all users (in the guild) running the addon and the version they're running",
				func = function() 
					versionList = {} -- start with a fresh version list, when displaying it
					self:SendMessage({ "VER_QUERY" }) 
					self:ScheduleTimer("VersionCheckOutput", 2)
					self:Print("Version check running...")
				end
			},
			lock = {
				type = "execute",
				order = 2,
				name = "Toggle Lock",
				desc = "Shows/hides the display mover (also available in game keybindings)",
				func = function() AngryAssign:ToggleLock() end
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
						desc = "A list of words to highlight on displayed pages (separated by spaces or punctuation)",
						get = function(info) return AngryAssign_Config.highlight end,
						set = function(info, val)
							AngryAssign_Config.highlight = val
							AngryAssign:UpdateDisplayed()
						end
					},
					hideoncombat = {
						type = "toggle",
						order = 2,
						name = "Hide on Combat",
						desc = "Enable to hide display frame upon entering combat",
						get = function(info) return AngryAssign_Config.hideoncombat end,
						set = function(info, val)
							AngryAssign_Config.hideoncombat = val
						end
					},
					scale = {
						type = "range",
						order = 3,
						name = "Scale",
						desc = function() 
							return "Sets the scale of the edit window"
						end,
						min = 0.3,
						max = 3,
						get = function(info) return AngryAssign_Config.scale end,
						set = function(info, val)
							AngryAssign_Config.scale = val
							if AngryAssign.window then AngryAssign.window.frame:SetScale(val) end
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
						get = function()
							return AngryAssign_Config.fontName
						end,
						set = function(self,key)
							AngryAssign_Config.fontName = key
							AngryAssign:UpdateMedia()
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
						get = function(info) return AngryAssign_Config.fontHeight end,
						set = function(info, val)
							AngryAssign_Config.fontHeight = val
							AngryAssign:UpdateMedia()
						end
					},
					fontflags = {
						type = "select",
						order = 3,
						name = "Outline",
						desc = function() 
							return "Sets the font outline used to display a page"
						end,
						values = { ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline", ["MONOCHROMEOUTLINE"] = "Monochrome" },
						get = function(info) return AngryAssign_Config.fontFlags end,
						set = function(info, val)
							AngryAssign_Config.fontFlags = val
							AngryAssign:UpdateMedia()
						end
					}
				}
			}
		}
	}

	LibStub("AceConfig-3.0"):RegisterOptionsTable("Angry Assignments", options, {"aa", "angryassign"})

	LibStub("AceConfigDialog-3.0"):AddToBlizOptions("Angry Assignments", "Angry Assignments")
end

function AngryAssign:OnEnable()
	self:CreateDisplay()

	self:RegisterComm(comPrefix, "ReceiveMessage")
	
	self:ScheduleTimer("AfterEnable", 6)

	self:RegisterEvent("PARTY_CONVERTED_TO_RAID")
	self:RegisterEvent("GROUP_JOINED")
	self:RegisterEvent("PLAYER_REGEN_DISABLED")
	self:RegisterEvent("GROUP_ROSTER_UPDATE")

	LSM.RegisterCallback(self, "LibSharedMedia_Registered", "UpdateMedia")
	LSM.RegisterCallback(self, "LibSharedMedia_SetGlobal", "UpdateMedia")

	if not IsInRaid(LE_PARTY_CATEGORY_HOME) then
		self:ClearDisplayed()
	end
end

function AngryAssign:RAID_ROSTER_UPDATE()
	self:UpdateSelected()
end

function AngryAssign:PARTY_CONVERTED_TO_RAID()
	self:SendRequestDisplay()
end

function AngryAssign:GROUP_JOINED()
	self:SendRequestDisplay()
end

function AngryAssign:PLAYER_REGEN_DISABLED()
	if AngryAssign_Config.hideoncombat then
		self:HideDisplay()
	end
end

function AngryAssign:GROUP_ROSTER_UPDATE()
	self:UpdateSelected()
	if AngryAssign_State.displayed and not IsInRaid(LE_PARTY_CATEGORY_HOME) then
		self:ClearDisplayed()
	end
end

function AngryAssign:AfterEnable()
	self:SendMessage({ "VER_QUERY" })
	self:SendRequestDisplay()
end
