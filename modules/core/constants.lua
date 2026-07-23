-- -------------------------------------------------------------------------------
-- Angry Era: modules/core/constants.lua
--
-- Protocol constants, config defaults, and platform flags.
-- -------------------------------------------------------------------------------

local appName, app = ...
local AngryEra = app.AngryEra

AngryEra.core = AngryEra.core or {}
local core = AngryEra.core

-- Platform detection
core.isClassicVanilla = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
core.isClassicTBC = WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
core.isClassicWrath = WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC
core.isClassic = core.isClassicVanilla or core.isClassicTBC or core.isClassicWrath

-- Protocol
core.protocolVersion = 1
core.comPrefix = appName .. 1
core.updateFrequency = 2

-- Communication size limits
core.MAX_COMM_ENCODED_BYTES = 256 * 1024
core.MAX_COMM_DECODED_BYTES = 256 * 1024
core.MAX_COMM_SERIALIZED_BYTES = 1024 * 1024

-- Import size limits
core.MAX_IMPORT_ENCODED_BYTES = 2 * 1024 * 1024
core.MAX_IMPORT_DECODED_BYTES = 2 * 1024 * 1024
core.MAX_IMPORT_SERIALIZED_BYTES = 8 * 1024 * 1024

-- Message field indices
core.COMMAND = 1
core.PAGE_Id = 2
core.PAGE_Updated = 3
core.PAGE_Name = 4
core.PAGE_Contents = 5
core.PAGE_UpdateId = 6
core.PAGE_Vars = 7
core.REQUEST_PAGE_Id = 2
core.DISPLAY_Id = 2
core.DISPLAY_Updated = 3
core.DISPLAY_UpdateId = 4
core.VERSION_Version = 2
core.VERSION_Timestamp = 3
core.VERSION_ValidRaid = 4

-- Config defaults
core.configDefaults = {
    scale = 1,
    hideoncombat = false,
    fontName = "Friz Quadrata TT",
    fontHeight = 12,
    fontFlags = "NONE",
    highlight = "",
    highlightColor = "ffd200",
    color = "ffffff",
    lineSpacing = 0,
    receiveMode = "standard",
    allowAllAssistants = false,
    trustedPublishers = "",
    backdropShow = false,
    backdropColor = "00000080",
    glowColor = "FF0000",
    editBoxFont = false,
    chatoutput = "Acronym",
}
