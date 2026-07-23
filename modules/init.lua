-- -------------------------------------------------------------------------------
-- Angry Era: modules/init.lua
--
-- Lifecycle: OnInitialize, OnEnable, AfterEnable, event handlers, slash command.
-- -------------------------------------------------------------------------------

local appName, app = ...
local AngryEra = app.AngryEra
local LSM = app.libs.LSM

AngryEra.Templates = app.Templates

local core = AngryEra.core
local isClassic = core.isClassic
local comPrefix = core.comPrefix

local colors = AngryEra.utils.colors
local RGBToHex = colors.RGBToHex
local HexToRGB = colors.HexToRGB

local AngryEra_Title = AngryEra.Title
local AngryEra_Version = AngryEra.Version

-- -----------------
-- Addon Setup --
-- -----------------

local blizOptionsPanel

-- class AngryEraState
-- field tree table Tree view state (collapsed nodes etc)
-- field window table Window position/size
-- field display table Display frame position/size
-- field displayed? number ID of the currently displayed page
-- field locked boolean Whether the display is locked
-- field directionUp boolean Growth direction

-- class AngryEraConfig
-- field scale number Scale of the edit window
-- field hideoncombat boolean Hide display in combat
-- field highlight string Comma/space separated words to highlight
-- field highlightColor string Hex color for highlights
-- field backdropShow boolean Show backdrop
-- field backdropColor string Hex color for backdrop
-- field glowColor string Hex color for update notification
-- field fontName string Font face
-- field fontHeight number Font size
-- field fontFlags string Font outline
-- field color string Normal text color

-- class AngryEraTemplatePage
-- field name string
-- field content string

-- class AngryEraTemplate
-- field name string
-- field pages AngryEraTemplatePage[]

-- type table<number, Page> Dictionary of pages key=Id
_G.AngryAssign_Pages = _G.AngryAssign_Pages

-- type table<number, Category> Dictionary of categories key=Id
_G.AngryAssign_Categories = _G.AngryAssign_Categories

-- type AngryEraState
_G.AngryAssign_State = _G.AngryAssign_State

-- type AngryEraConfig
_G.AngryAssign_Config = _G.AngryAssign_Config

-- type AngryEraTemplate[]
_G.AngryAssign_Templates = _G.AngryAssign_Templates

--- Addon initialization hook.
-- Creates saved variable tables, migrates legacy category data, and registers options.
function AngryEra:OnInitialize()
    if AngryAssign_State == nil then
        AngryAssign_State =
            { tree = {}, window = {}, display = {}, displayed = nil, locked = false, directionUp = false }
    end
    if AngryAssign_Pages == nil then
        AngryAssign_Pages = {}
    end
    if AngryAssign_Config == nil then
        AngryAssign_Config = {}
    end
    if AngryAssign_Templates == nil then
        AngryAssign_Templates = {}
    end
    if AngryAssign_Categories == nil then
        AngryAssign_Categories = {}
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

    local ver = AngryEra_Version
    if ver:sub(1, 1) == "@" then
        ver = "dev"
    end

    local options = {
        name = appName .. " " .. ver,
        handler = AngryEra,
        type = "group",
        args = {
            window = {
                type = "execute",
                order = 3,
                name = "Toggle Window",
                desc = "Shows/hides the edit window (also available in game keybindings)",
                func = function()
                    AngryEra_ToggleWindow()
                end,
            },
            help = {
                type = "execute",
                order = 99,
                name = "Help",
                hidden = true,
                func = function()
                    LibStub("AceConfigCmd-3.0").HandleCommand(self, "aa", "AngryEra", "")
                end,
            },
            toggle = {
                type = "execute",
                order = 1,
                name = "Toggle Display",
                desc = "Shows/hides the display frame (also available in game keybindings)",
                func = function()
                    AngryEra_ToggleDisplay()
                end,
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
                    if self.window then
                        self.window.tree:SetSelected(nil)
                    end
                    self:Print("All pages have been deleted.")
                end,
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
                end,
            },
            output = {
                type = "execute",
                name = "Output",
                desc = "Outputs currently displayed assignments to chat",
                order = 11,
                hidden = true,
                cmdHidden = false,
                confirm = true,
                func = function()
                    self:OutputDisplayed()
                end,
            },
            first = {
                type = "execute",
                name = "First Page",
                desc = "Toggles to and from the first page in the current category",
                order = 11.5,
                hidden = true,
                cmdHidden = false,
                func = function()
                    self:FirstPage()
                end,
            },
            send = {
                type = "input",
                name = "Send and Display",
                desc = "Sends page with specified name",
                order = 12,
                hidden = true,
                cmdHidden = false,
                confirm = true,
                get = function(info)
                    return ""
                end,
                set = function(info, val)
                    local result = self:DisplayPageByName(val:trim())
                    if result == false then
                        self:Print(
                            RED_FONT_COLOR_CODE .. "A page with the name \"" .. val:trim() .. "\" could not be found.|r"
                        )
                    elseif not result then
                        self:Print(RED_FONT_COLOR_CODE .. "You don't have permission to send a page.|r")
                    end
                end,
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
                    AngryEra._AngryEra_ClearPage()
                end,
            },
            backup = {
                type = "execute",
                order = 20,
                name = "Backup Pages",
                desc = "Creates a backup of all pages with their current contents",
                func = function()
                    self:CreateBackup()
                    self:Print("Created a backup of all pages.")
                end,
            },
            resetposition = {
                type = "execute",
                order = 22,
                name = "Reset Position",
                desc = "Resets position for the assignment display",
                func = function()
                    self:ResetPosition()
                end,
            },
            version = {
                type = "execute",
                order = 21,
                name = "Version Check",
                desc = "Displays a list of all users (in the raid) running the addon and the version they're running",
                func = function()
                    if IsInRaid() or IsInGroup() then
                        self:ResetVersionList() -- start with a fresh version list, when displaying it
                        self:SendOutMessage({ "VER_QUERY" })
                        self:ScheduleTimer("VersionCheckOutput", 3)
                        self:Print("Version check running...")
                    else
                        self:Print("You must be in a raid group to run the version check.")
                    end
                end,
            },
            lock = {
                type = "execute",
                order = 2,
                name = "Toggle Lock",
                desc = "Shows/hides the display mover (also available in game keybindings)",
                func = function()
                    self:ToggleLock()
                end,
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
                        desc = "A list of words to highlight on displayed pages (separated by spaces or punctuation)\n\nUse \"Group\" to highlight the current group you are in, ex. G2",
                        get = function(info)
                            return self:GetConfig("highlight")
                        end,
                        set = function(info, val)
                            self:SetConfig("highlight", val)
                            self:UpdateDisplayed()
                        end,
                    },
                    hideoncombat = {
                        type = "toggle",
                        order = 3,
                        name = "Hide on Combat",
                        desc = "Enable to hide display frame upon entering combat",
                        get = function(info)
                            return self:GetConfig("hideoncombat")
                        end,
                        set = function(info, val)
                            self:SetConfig("hideoncombat", val)
                        end,
                    },
                    chatoutput = {
                        type = "select",
                        order = 3.5,
                        name = "Chat Output Format",
                        desc = "How spells should be displayed when outputting to chat (e.g. {jol})",
                        values = { ["Name"] = "Spell Name", ["Acronym"] = "Acronym" },
                        get = function(info)
                            return self:GetConfig("chatoutput")
                        end,
                        set = function(info, val)
                            self:SetConfig("chatoutput", val)
                        end,
                    },
                    scale = {
                        type = "range",
                        order = 4,
                        name = "Scale",
                        desc = "Sets the scale of the edit window",
                        min = 0.3,
                        max = 3,
                        get = function(info)
                            return self:GetConfig("scale")
                        end,
                        set = function(info, val)
                            self:SetConfig("scale", val)
                            if AngryEra.window then
                                AngryEra.window.frame:SetScale(val)
                            end
                        end,
                    },
                    backdrop = {
                        type = "toggle",
                        order = 5,
                        name = "Display Backdrop",
                        desc = "Enable to display a backdrop behind the assignment display",
                        get = function(info)
                            return self:GetConfig("backdropShow")
                        end,
                        set = function(info, val)
                            self:SetConfig("backdropShow", val)
                            self:UpdateBackdrop()
                        end,
                    },
                    backdropcolor = {
                        type = "color",
                        order = 6,
                        name = "Backdrop Color",
                        desc = "The color used by the backdrop",
                        hasAlpha = true,
                        get = function(info)
                            local hex = self:GetConfig("backdropColor")
                            return HexToRGB(hex)
                        end,
                        set = function(info, r, g, b, a)
                            self:SetConfig("backdropColor", RGBToHex(r, g, b, a))
                            self:UpdateMedia()
                            self:UpdateDisplayed()
                        end,
                    },
                    updatecolor = {
                        type = "color",
                        order = 7,
                        name = "Update Notification Color",
                        desc = "The color used by the update notification glow",
                        get = function(info)
                            local hex = self:GetConfig("glowColor")
                            return HexToRGB(hex)
                        end,
                        set = function(info, r, g, b)
                            self:SetConfig("glowColor", RGBToHex(r, g, b))
                            self.display_glow:SetVertexColor(r, g, b)
                            self.display_glow2:SetVertexColor(r, g, b)
                        end,
                    },
                },
            },
            font = {
                type = "group",
                order = 6,
                name = "Font",
                inline = true,
                args = {
                    fontname = {
                        type = "select",
                        order = 1,
                        dialogControl = "LSM30_Font",
                        name = "Face",
                        desc = "Sets the font face used to display a page",
                        values = LSM:HashTable("font"),
                        get = function(info)
                            return self:GetConfig("fontName")
                        end,
                        set = function(info, val)
                            self:SetConfig("fontName", val)
                            self:UpdateMedia()
                        end,
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
                        get = function(info)
                            return self:GetConfig("fontHeight")
                        end,
                        set = function(info, val)
                            self:SetConfig("fontHeight", val)
                            self:UpdateMedia()
                        end,
                    },
                    fontflags = {
                        type = "select",
                        order = 3,
                        name = "Outline",
                        desc = "Sets the font outline used to display a page",
                        values = {
                            ["NONE"] = "None",
                            ["OUTLINE"] = "Outline",
                            ["THICKOUTLINE"] = "Thick Outline",
                            ["MONOCHROMEOUTLINE"] = "Monochrome",
                        },
                        get = function(info)
                            return self:GetConfig("fontFlags")
                        end,
                        set = function(info, val)
                            self:SetConfig("fontFlags", val)
                            self:UpdateMedia()
                        end,
                    },
                    color = {
                        type = "color",
                        order = 4,
                        name = "Normal Color",
                        desc = "The normal color used to display assignments",
                        get = function(info)
                            local hex = self:GetConfig("color")
                            return HexToRGB(hex)
                        end,
                        set = function(info, r, g, b)
                            self:SetConfig("color", RGBToHex(r, g, b))
                            self:UpdateMedia()
                            self:UpdateDisplayed()
                        end,
                    },
                    highlightcolor = {
                        type = "color",
                        order = 5,
                        name = "Highlight Color",
                        desc = "The color used to emphasize highlighted words",
                        get = function(info)
                            local hex = self:GetConfig("highlightColor")
                            return HexToRGB(hex)
                        end,
                        set = function(info, r, g, b)
                            self:SetConfig("highlightColor", RGBToHex(r, g, b))
                            self:UpdateDisplayed()
                        end,
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
                        get = function(info)
                            return self:GetConfig("lineSpacing")
                        end,
                        set = function(info, val)
                            self:SetConfig("lineSpacing", val)
                            self:UpdateMedia()
                            self:UpdateDisplayed()
                        end,
                    },
                    editBoxFont = {
                        type = "toggle",
                        order = 7,
                        name = "Change Edit Box Font",
                        desc = "Enable to set edit box font to display font",
                        get = function(info)
                            return self:GetConfig("editBoxFont")
                        end,
                        set = function(info, val)
                            self:SetConfig("editBoxFont", val)
                            self:UpdateMedia()
                        end,
                    },
                },
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
                        get = function(info)
                            return self:GetConfig("allowall")
                        end,
                        set = function(info, val)
                            self:SetConfig("allowall", val)
                            self:PermissionsUpdated()
                        end,
                    },
                    allowplayers = {
                        type = "input",
                        order = 2,
                        name = "Allow Players",
                        desc = "A list of players that when they are the raid leader to allow changes from all raid assistants",
                        get = function(info)
                            return self:GetConfig("allowplayers")
                        end,
                        set = function(info, val)
                            self:SetConfig("allowplayers", val)
                            self:PermissionsUpdated()
                        end,
                    },
                },
            },
        },
    }

    self:RegisterChatCommand("aa", "ChatCommand")
    LibStub("AceConfig-3.0"):RegisterOptionsTable("AngryEra", options)

    blizOptionsPanel = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("AngryEra", AngryEra_Title)
    blizOptionsPanel.default = function()
        self:RestoreDefaults()
    end
end

--- Slash command entry point (`/aa`).
-- @tparam string input Raw slash command arguments.
function AngryEra:ChatCommand(input)
    if not input or input:trim() == "" then
        if Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(AngryEra_Title)
        else
            InterfaceOptionsFrame_OpenToCategory(blizOptionsPanel)
        end
    else
        local command = input:trim():lower()
        if command == "first" then
            self:FirstPage()
        else
            LibStub("AceConfigCmd-3.0").HandleCommand(self, "aa", "AngryEra", input)
        end
    end
end

--- Addon enable hook.
-- Initializes display and core event listeners.
function AngryEra:OnEnable()
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

function AngryEra:PARTY_LEADER_CHANGED()
    self:PermissionsUpdated()
    if AngryAssign_State.displayed and not (self:IsGuildRaid() or self:IsValidRaid()) then
        self:ClearDisplayed()
    end
end

function AngryEra:PARTY_CONVERTED_TO_RAID()
    self:SendRequestDisplay()
    self:SendVerQuery()
    self:UpdateDisplayedIfNewGroup()
end

function AngryEra:GROUP_JOINED()
    self:ResetVersionList() -- Reset version tracking when joining a new group
    self:SendVerQuery()
    self:UpdateDisplayedIfNewGroup()
    self:ScheduleTimer("SendRequestDisplay", 0.5)
end

function AngryEra:PLAYER_REGEN_DISABLED()
    if AngryEra:GetConfig("hideoncombat") then
        self:HideDisplay()
    end
end

function AngryEra:GROUP_ROSTER_UPDATE()
    self:UpdateSelected()
    if not (IsInRaid() or IsInGroup()) then
        if AngryAssign_State.displayed then
            self:ClearDisplayed()
        end
        self:ResetCurrentGroup()
        self:ResetPermissionWarning()
    else
        self:UpdateDisplayedIfNewGroup()
    end
end

function AngryEra:PLAYER_GUILD_UPDATE()
    self:ResetOfficerRank()
    self:PermissionsUpdated()
end

local guildUpdatePending = false
function AngryEra:GUILD_ROSTER_UPDATE(...)
    local canRequestRosterUpdate = ...
    self:ResetOfficerRank()
    self:UpdateGuildColors()

    if not guildUpdatePending then
        guildUpdatePending = true
        C_Timer.After(2, function()
            guildUpdatePending = false
            self:UpdateDisplayed()
        end)
    end

    if canRequestRosterUpdate and isClassic then
        GuildRoster()
    end
end

--- Post-enable delayed setup hook for communication/event wiring.
function AngryEra:AfterEnable()
    self:RegisterComm(comPrefix, "ReceiveMessage")
    AngryEra._comStarted = true

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
