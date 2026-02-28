-- -------------------------------------------------------------------------------
-- Angry Era: modules/core/bootstrap.lua
--
-- Creates the addon object and wires library references onto app.
-- -------------------------------------------------------------------------------

local _G = _G

local appName, app = ...

local GetAddOnMetadata = GetAddOnMetadata or C_AddOns.GetAddOnMetadata

---@class AngryAssign
---@field window? AceGUIFrame The main configuration window
---@field display_text? table fontstring/frame for display
local AngryAssign = LibStub("AceAddon-3.0"):NewAddon(appName, "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceTimer-3.0")
app.AngryAssign = AngryAssign

app.AceGUI = LibStub("AceGUI-3.0")
app.libS = LibStub("AceSerializer-3.0")
app.LibMustache = LibStub("LibMustache")
app.libC = LibStub("LibCompress")
app.libD = LibStub("LibDeflate")
app.lwin = LibStub("LibWindow-1.1")
app.libCE = app.libC:GetAddonEncodeTable()
app.LSM = LibStub("LibSharedMedia-3.0")
app.DDM = LibStub("LibDropDownMenu")

app._comStarted = false

app.Title = GetAddOnMetadata(appName, "Title")
app.Version = GetAddOnMetadata(appName, "Version")
app.Timestamp = GetAddOnMetadata(appName, "X-Timestamp")

_G["BINDING_HEADER_" .. appName] = "|cff0070DD" .. app.Title

_G["BINDING_NAME_" .. appName .. "_WINDOW"] = "Toggle Window"
_G["BINDING_NAME_" .. appName .. "_LOCK"] = "Toggle Lock"
_G["BINDING_NAME_" .. appName .. "_DISPLAY"] = "Toggle Display"
_G["BINDING_NAME_" .. appName .. "_SHOW_DISPLAY"] = "Show Display"
_G["BINDING_NAME_" .. appName .. "_HIDE_DISPLAY"] = "Hide Display"
_G["BINDING_NAME_" .. appName .. "_OUTPUT"] = "Output Assignment to Chat"
_G["BINDING_NAME_" .. appName .. "_PREV_PAGE"] = "Previous Page"
_G["BINDING_NAME_" .. appName .. "_NEXT_PAGE"] = "Next Page"
_G["BINDING_NAME_" .. appName .. "_FIRST_PAGE"] = "First Page"
