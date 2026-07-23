-- -------------------------------------------------------------------------------
-- Angry Era: modules/core/bootstrap.lua
--
-- Creates the addon object and wires library references onto AngryEra.
-- -------------------------------------------------------------------------------

local _G = _G

local appName, app = ...
local PUBLIC_API_NAME = "AngryEra"

local GetAddOnMetadata = GetAddOnMetadata or C_AddOns.GetAddOnMetadata

if rawget(_G, PUBLIC_API_NAME) ~= nil then
    error(PUBLIC_API_NAME .. " cannot load because _G." .. PUBLIC_API_NAME .. " is already defined")
end

-- class AngryEra
-- field window? AceGUIFrame The main configuration window
-- field display_text? table fontstring/frame for display
local AngryEra =
    LibStub("AceAddon-3.0"):NewAddon(appName, "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceTimer-3.0")
app.AngryEra = AngryEra

app.libs = {}
app.libs.AceGUI = LibStub("AceGUI-3.0")
app.libs.libS = LibStub("AceSerializer-3.0")
app.libs.LibMustache = LibStub("LibMustache")
app.libs.libC = LibStub("LibCompress")
app.libs.libD = LibStub("LibDeflate")
app.libs.lwin = LibStub("LibWindow-1.1")
app.libs.LSM = LibStub("LibSharedMedia-3.0")
app.libs.DDM = LibStub("LibDropDownMenu")

AngryEra._protocolStarted = false

AngryEra.Title = GetAddOnMetadata(appName, "Title")
AngryEra.Version = GetAddOnMetadata(appName, "Version")
AngryEra.Timestamp = GetAddOnMetadata(appName, "X-Timestamp")

_G["BINDING_HEADER_" .. appName] = "|cff0070DD" .. AngryEra.Title

_G["BINDING_NAME_" .. appName .. "_WINDOW"] = "Toggle Window"
_G["BINDING_NAME_" .. appName .. "_LOCK"] = "Toggle Lock"
_G["BINDING_NAME_" .. appName .. "_DISPLAY"] = "Toggle Display"
_G["BINDING_NAME_" .. appName .. "_SHOW_DISPLAY"] = "Show Display"
_G["BINDING_NAME_" .. appName .. "_HIDE_DISPLAY"] = "Hide Display"
_G["BINDING_NAME_" .. appName .. "_OUTPUT"] = "Output Assignment to Chat"
_G["BINDING_NAME_" .. appName .. "_PREV_PAGE"] = "Previous Page"
_G["BINDING_NAME_" .. appName .. "_NEXT_PAGE"] = "Next Page"
_G["BINDING_NAME_" .. appName .. "_FIRST_PAGE"] = "First Page"

-- Stable entry point for WeakAuras and other addons. Keep this identical to the
-- private addon-namespace object so internal and external callers share state.
_G[PUBLIC_API_NAME] = AngryEra
