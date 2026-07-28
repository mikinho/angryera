-- -------------------------------------------------------------------------------
-- Angry Era: modules/ui/settings.lua
--
-- Config accessors and orphaned state cleanup.
-- The AceConfig options table lives in init.lua (inside OnInitialize).
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

local core = AngryEra.core
local configDefaults = core.configDefaults

local CONFIG_STRING_LIMIT = 4096
local COMBAT_FADE_VISIBILITY_MIGRATION_VERSION = 1
local configSchema = {
    scale = { Type = "number", Min = 0.3, Max = 3 },
    hideoncombat = { Type = "boolean" },
    autoHide = { Type = "boolean" },
    fontName = { Type = "string", NonEmpty = true, MaxLength = 200 },
    fontHeight = { Type = "number", Min = 6, Max = 24 },
    fontFlags = {
        Type = "enum",
        Values = {
            NONE = true,
            OUTLINE = true,
            THICKOUTLINE = true,
            MONOCHROMEOUTLINE = true,
        },
    },
    highlight = { Type = "string", MaxLength = CONFIG_STRING_LIMIT },
    highlightColor = { Type = "color", Length = 6 },
    color = { Type = "color", Length = 6 },
    lineSpacing = { Type = "number", Min = 0, Max = 10 },
    receiveMode = {
        Type = "enum",
        Values = {
            standard = true,
            leaderOnly = true,
            ignoreShared = true,
        },
    },
    allowAllAssistants = { Type = "boolean" },
    trustedPublishers = { Type = "string", MaxLength = CONFIG_STRING_LIMIT },
    backdropShow = { Type = "boolean" },
    backdropColor = { Type = "color", Length = 8 },
    glowColor = { Type = "color", Length = 6 },
    editBoxFont = { Type = "boolean" },
    chatoutput = {
        Type = "enum",
        Values = {
            Name = true,
            Acronym = true,
        },
    },
    mouseoverHostileOnly = { Type = "boolean" },
    autoCleanReceivedPages = { Type = "boolean" },
}

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function NormalizeConfigValue(key, value)
    local schema = configSchema[key]
    if not schema then
        return nil
    end
    if schema.Type == "boolean" then
        if type(value) == "boolean" then
            return value
        end
        return nil
    end
    if schema.Type == "number" then
        if not IsFiniteNumber(value) or value < schema.Min or value > schema.Max then
            return nil
        end
        return value
    end
    if schema.Type == "string" then
        if
            type(value) ~= "string"
            or schema.NonEmpty and value == ""
            or schema.MaxLength and #value > schema.MaxLength
        then
            return nil
        end
        return value
    end
    if schema.Type == "enum" then
        return type(value) == "string" and schema.Values[value] and value or nil
    end
    if schema.Type == "color" then
        if type(value) ~= "string" or #value ~= schema.Length or value:match("^[%x]+$") == nil then
            return nil
        end
        return value:lower()
    end
    return nil
end

local function DefaultConfigValue(key)
    return NormalizeConfigValue(key, configDefaults[key])
end

local function SanitizeFiniteFields(source, fields)
    local sanitized = {}
    for _, key in ipairs(fields) do
        local value = source[key]
        if IsFiniteNumber(value) then
            sanitized[key] = value
        end
    end
    return sanitized
end

local function SanitizeTreeStatus(source)
    local tree = {}
    local groups = {}
    if type(source.groups) == "table" then
        for key, value in pairs(source.groups) do
            if
                (type(key) == "string" and #key <= CONFIG_STRING_LIMIT or IsFiniteNumber(key))
                and type(value) == "boolean"
            then
                groups[key] = value
            end
        end
    end
    tree.groups = groups
    if
        type(source.selected) == "string" and #source.selected <= CONFIG_STRING_LIMIT
        or IsFiniteNumber(source.selected)
    then
        tree.selected = source.selected
    end
    if IsFiniteNumber(source.scrollvalue) and source.scrollvalue >= 0 then
        tree.scrollvalue = math.floor(source.scrollvalue)
    end
    if IsFiniteNumber(source.treewidth) and source.treewidth >= 100 and source.treewidth <= 4000 then
        tree.treewidth = source.treewidth
    end
    if type(source.treesizable) == "boolean" then
        tree.treesizable = source.treesizable
    end
    return tree
end

local function SanitizeWindowStatus(source)
    local window = SanitizeFiniteFields(source, { "width", "height", "top", "left" })
    if window.width and (window.width < 200 or window.width > 4000) then
        window.width = nil
    end
    if window.height and (window.height < 100 or window.height > 4000) then
        window.height = nil
    end
    if window.top and math.abs(window.top) > 100000 then
        window.top = nil
    end
    if window.left and math.abs(window.left) > 100000 then
        window.left = nil
    end
    return window
end

local validAnchorPoints = {
    BOTTOM = true,
    BOTTOMLEFT = true,
    BOTTOMRIGHT = true,
    CENTER = true,
    LEFT = true,
    RIGHT = true,
    TOP = true,
    TOPLEFT = true,
    TOPRIGHT = true,
}

local function SanitizeDisplayStatus(source)
    local display = SanitizeFiniteFields(source, { "width", "x", "y", "scale" })
    if display.width and (display.width < 180 or display.width > 830) then
        display.width = nil
    end
    if display.x and math.abs(display.x) > 100000 then
        display.x = nil
    end
    if display.y and math.abs(display.y) > 100000 then
        display.y = nil
    end
    if display.scale and (display.scale < 0.1 or display.scale > 3) then
        display.scale = nil
    end
    if validAnchorPoints[source.point] then
        display.point = source.point
    end
    display.hidden = type(source.hidden) == "boolean" and source.hidden or false
    return display
end

--- Repairs the SavedVariables state container before UI code dereferences it.
-- The nested status tables are owned by AceGUI/LibWindow, so valid tables are
-- retained verbatim while hostile scalar replacements are discarded.
-- @treturn table state Normalized global state table.
function AngryEra:NormalizeSavedState()
    if type(AngryAssign_State) ~= "table" then
        AngryAssign_State = {}
    end
    local state = AngryAssign_State
    state.tree = SanitizeTreeStatus(type(state.tree) == "table" and state.tree or {})
    state.window = SanitizeWindowStatus(type(state.window) == "table" and state.window or {})
    state.display = SanitizeDisplayStatus(type(state.display) == "table" and state.display or {})
    if
        state.displayed ~= nil
        and (not IsFiniteNumber(state.displayed) or state.displayed < 1 or state.displayed % 1 ~= 0)
    then
        state.displayed = nil
    end
    if type(state.locked) ~= "boolean" then
        state.locked = false
    end
    if type(state.directionUp) ~= "boolean" then
        state.directionUp = false
    end
    return state
end

--- Drops invalid persisted values so every UI consumer receives a known type.
-- Unknown keys are retained for migration/forward compatibility.
-- @treturn number repaired Number of known values reset to defaults.
function AngryEra:SanitizeSavedConfig()
    if type(AngryAssign_Config) ~= "table" then
        AngryAssign_Config = {}
        return 1
    end
    local repaired = 0
    for key in pairs(configSchema) do
        local value = AngryAssign_Config[key]
        if value ~= nil then
            local normalized = NormalizeConfigValue(key, value)
            if normalized == nil then
                AngryAssign_Config[key] = nil
                repaired = repaired + 1
            elseif normalized == DefaultConfigValue(key) then
                AngryAssign_Config[key] = nil
            else
                AngryAssign_Config[key] = normalized
            end
        end
    end
    return repaired
end

--- Repairs the persisted hide left by the former Hide on Combat behavior.
-- There is no durable distinction between that automatic hide and a manual
-- hide, so installations with the option enabled are made visible once. The
-- completion marker ensures a later deliberate manual hide is never changed.
-- @treturn boolean restored Whether the display was made visible.
function AngryEra:MigrateCombatFadeVisibility()
    if type(AngryAssign_Meta) ~= "table" then
        return false
    end
    if type(AngryAssign_Meta.Migrations) ~= "table" then
        AngryAssign_Meta.Migrations = {}
    end
    local migrations = AngryAssign_Meta.Migrations
    local migrationVersion = migrations.CombatFadeVisibility
    if type(migrationVersion) == "number" and migrationVersion >= COMBAT_FADE_VISIBILITY_MIGRATION_VERSION then
        return false
    end

    local restored = self:GetConfig("hideoncombat") == true
        and type(AngryAssign_State) == "table"
        and type(AngryAssign_State.display) == "table"
        and AngryAssign_State.display.hidden == true
    if restored then
        AngryAssign_State.display.hidden = false
    end
    migrations.CombatFadeVisibility = COMBAT_FADE_VISIBILITY_MIGRATION_VERSION
    return restored
end

--- Gets a config value with fallback to defaults.
-- @tparam string key Config key.
-- @treturn any value
function AngryEra:GetConfig(key)
    if type(AngryAssign_Config) ~= "table" then
        AngryAssign_Config = {}
    end
    if configSchema[key] == nil then
        return AngryAssign_Config[key] ~= nil and AngryAssign_Config[key] or configDefaults[key]
    end
    local value = NormalizeConfigValue(key, AngryAssign_Config[key])
    if value == nil then
        AngryAssign_Config[key] = nil
        return DefaultConfigValue(key)
    end
    return value
end

--- Sets a config value, storing `nil` for default-equivalent values.
-- @tparam string key Config key.
-- @tparam any value Config value.
function AngryEra:SetConfig(key, value)
    if type(AngryAssign_Config) ~= "table" then
        AngryAssign_Config = {}
    end
    if configSchema[key] == nil then
        AngryAssign_Config[key] = configDefaults[key] == value and nil or value
        return
    end
    local normalized = NormalizeConfigValue(key, value)
    if normalized == nil or DefaultConfigValue(key) == normalized then
        AngryAssign_Config[key] = nil
    else
        AngryAssign_Config[key] = normalized
    end
end

--- Restores all config options to defaults and refreshes display/media.
function AngryEra:RestoreDefaults()
    AngryAssign_Config = {}
    self:UpdateMedia()
    self:UpdateDisplayed()
    if type(self.RefreshDisplayAutoHide) == "function" then
        self:RefreshDisplayAutoHide(false)
    end
    if type(self.RefreshDisplayCombatFade) == "function" then
        self:RefreshDisplayCombatFade()
    end
    LibStub("AceConfigRegistry-3.0"):NotifyChange("AngryEra")
end

function AngryEra:CleanupOrphanedStates()
    if not AngryAssign_State or not AngryAssign_State.tree or not AngryAssign_State.tree.groups then
        return
    end

    local count = 0
    -- Iterate over the saved "expanded/collapsed" state of the tree
    for id, _ in pairs(AngryAssign_State.tree.groups) do
        -- FIX: Check that id is a number before comparing it
        if type(id) == "number" and id < 0 then
            -- Check if the category actually exists (flip ID back to positive)
            if not AngryAssign_Categories[-id] then
                AngryAssign_State.tree.groups[id] = nil
                count = count + 1
            end
        end
    end
end
