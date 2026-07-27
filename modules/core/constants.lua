-- -------------------------------------------------------------------------------
-- Angry Era: modules/core/constants.lua
--
-- Protocol constants, config defaults, and platform flags.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

AngryEra.core = AngryEra.core or {}
local core = AngryEra.core

-- Platform detection
core.isClassicVanilla = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
core.isClassicTBC = WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
core.isClassicWrath = WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC
core.isClassic = core.isClassicVanilla or core.isClassicTBC or core.isClassicWrath

-- Synchronization publication throttle
core.updateFrequency = 2

-- Import size limits
core.MAX_IMPORT_ENCODED_BYTES = 2 * 1024 * 1024
core.MAX_IMPORT_DECODED_BYTES = 2 * 1024 * 1024
core.MAX_IMPORT_SERIALIZED_BYTES = 8 * 1024 * 1024

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
    mouseoverHostileOnly = true,
    autoApplyRaidLayouts = false,
    autoCleanReceivedPages = false,
}
