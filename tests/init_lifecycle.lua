local calls = {}

local function Record(name, value)
    calls[#calls + 1] = {
        Name = name,
        Value = value,
    }
end

local AngryEra = {
    Title = "Angry Era",
    Version = "3.0.1",
    core = {
        isClassic = false,
    },
    utils = {
        protocol = {
            PREFIX = "AngryEra3",
        },
        colors = {
            RGBToHex = function()
                return "ffffff"
            end,
            HexToRGB = function()
                return 1, 1, 1, 1
            end,
        },
        helpers = {
            RequestGuildRoster = function()
                Record("request-guild-roster")
            end,
        },
    },
}

local app = {
    AngryEra = AngryEra,
    Templates = {},
    libs = {
        LSM = {
            RegisterCallback = function(_, _, method)
                Record("media-callback", method)
            end,
        },
    },
}

assert(loadfile("modules/init.lua"))("AngryEra", app)

function AngryEra:ResetOfficerRank()
    Record("reset-officer-rank")
end

function AngryEra:CreateDisplay()
    Record("create-display")
end

function AngryEra:ClearDisplayed(publish)
    assert(publish ~= true, "startup and group-boundary clears must remain local-only")
    Record("clear-displayed", publish)
    return true
end

function AngryEra:StartProtocolSession()
    Record("start-protocol-session")
    return true
end

function AngryEra:ScheduleTimer(method, delay)
    Record("schedule", {
        Method = method,
        Delay = delay,
    })
    return {}
end

function AngryEra:RegisterEvent(event)
    Record("register-event", event)
end

function AngryEra:RegisterComm(prefix, method)
    Record("register-comm", {
        Prefix = prefix,
        Method = method,
    })
end

function AngryEra:ResetProtocolPeers()
    Record("reset-protocol-peers")
end

function AngryEra:SendProtocolVersionQuery(force)
    Record("version-query", force)
    return true, "query-id"
end

function AngryEra:UpdateDisplayedIfNewGroup()
    Record("update-group-display")
end

function AngryEra:PermissionsUpdated()
    Record("permissions-updated")
end

function AngryEra:PruneProtocolPeers()
    Record("prune-protocol-peers")
end

function AngryEra:RetryDisplayedNoteMarkers()
    Record("retry-displayed-markers")
end

function AngryEra:Print(message)
    Record("print", message)
end

function _G.IsInRaid()
    return true
end

function _G.IsInGroup()
    return true
end

AngryEra:OnEnable()

local createIndex
local startupClearIndex
local sessionIndex
for index, call in ipairs(calls) do
    if call.Name == "create-display" then
        createIndex = index
    elseif call.Name == "clear-displayed" then
        startupClearIndex = index
    elseif call.Name == "start-protocol-session" then
        sessionIndex = index
    end
end
assert(createIndex and startupClearIndex and sessionIndex, "startup should create, clear, and start protocol state")
assert(
    createIndex < startupClearIndex and startupClearIndex < sessionIndex,
    "startup must locally clear persisted display state before the new protocol session"
)

local clearCountBeforeJoin = 0
for _, call in ipairs(calls) do
    if call.Name == "clear-displayed" then
        clearCountBeforeJoin = clearCountBeforeJoin + 1
    end
end

calls = {}
AngryEra._protocolStarted = true
AngryEra:GROUP_JOINED()
assert(calls[1].Name == "clear-displayed", "group join must clear the prior display before all new-group work")
assert(calls[2].Name == "reset-protocol-peers", "group join should reset prior-group transport state after clearing")
assert(calls[3].Name == "version-query", "group discovery should begin only after the local clear")
assert(calls[#calls].Name == "schedule", "the new leader display request should be scheduled last")
assert(calls[#calls].Value.Method == "SendRequestDisplay", "group join should request the new leader's display")

calls = {}
AngryEra:AfterEnable()
for _, call in ipairs(calls) do
    assert(call.Name ~= "clear-displayed", "delayed setup must not duplicate the startup clear")
end

calls = {}
AngryEra:GROUP_ROSTER_UPDATE()
local markerRetryCount = 0
for _, call in ipairs(calls) do
    if call.Name == "retry-displayed-markers" then
        markerRetryCount = markerRetryCount + 1
    end
end
assert(markerRetryCount == 1, "a roster update should retry unresolved displayed-note marker targets once")

local totalClearCount = clearCountBeforeJoin + 1
assert(totalClearCount == 2, "startup and group join should each perform one local-only clear")

print("Initialization lifecycle tests passed.")
