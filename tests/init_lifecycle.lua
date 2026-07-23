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
            DISPLAY_PREFIX = "AngryEra3D",
            ACTIVE_PAGE_PREFIX = "AngryEra3P",
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

assert(loadfile("modules/debug.lua"))("AngryEra", app)
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

function AngryEra:ResetDisplayPublicationState()
    Record("reset-display-publication")
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

local function CommandInput(value)
    return {
        trim = function()
            return value
        end,
    }
end

function _G.IsInRaid()
    return true
end

function _G.IsInGroup()
    return true
end

assert(not AngryEra:IsSyncDebugEnabled(), "sync debug should be disabled by default")
AngryEra:ChatCommand(CommandInput("debug"))
assert(AngryEra:IsSyncDebugEnabled(), "bare debug command should enable tracing")
AngryEra:ChatCommand(CommandInput("debug status"))
assert(calls[#calls].Name == "print", "debug status should print its current state")
AngryEra:ChatCommand(CommandInput("debug off"))
assert(not AngryEra:IsSyncDebugEnabled(), "debug off should disable tracing")
calls = {}

AngryEra:OnEnable()

local createIndex
local startupClearIndex
local sessionIndex
local registeredPrefixes = {}
local registrationOrder = {}
for index, call in ipairs(calls) do
    if call.Name == "create-display" then
        createIndex = index
    elseif call.Name == "clear-displayed" then
        startupClearIndex = index
    elseif call.Name == "start-protocol-session" then
        sessionIndex = index
    elseif call.Name == "register-comm" then
        registeredPrefixes[call.Value.Prefix] = call.Value.Method
        registrationOrder[#registrationOrder + 1] = {
            Index = index,
            Prefix = call.Value.Prefix,
        }
    end
end
assert(createIndex and startupClearIndex and sessionIndex, "startup should create, clear, and start protocol state")
assert(
    createIndex < startupClearIndex and startupClearIndex < sessionIndex,
    "startup must locally clear persisted display state before the new protocol session"
)
assert(registeredPrefixes.AngryEra3 == "ReceiveProtocolMessage", "startup should register the data prefix")
assert(registeredPrefixes.AngryEra3D == "ReceiveProtocolMessage", "startup should register the display prefix")
assert(registeredPrefixes.AngryEra3P == "ReceiveProtocolMessage", "startup should register the active-page prefix")
assert(#registrationOrder == 3, "startup should register exactly three protocol prefixes")
assert(
    sessionIndex < registrationOrder[1].Index
        and registrationOrder[1].Prefix == "AngryEra3"
        and registrationOrder[2].Prefix == "AngryEra3D"
        and registrationOrder[3].Prefix == "AngryEra3P",
    "the protocol session must start before ordered data, display, and active-page registration"
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
    assert(call.Name ~= "register-comm", "delayed setup must not leave a startup receive blind spot")
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

calls = {}
AngryEra:PARTY_LEADER_CHANGED()
assert(
    calls[1].Name == "reset-display-publication" and calls[2].Name == "permissions-updated",
    "leader changes must reset queued publication state before reevaluating permissions"
)

local totalClearCount = clearCountBeforeJoin + 1
assert(totalClearCount == 2, "startup and group join should each perform one local-only clear")

local successfulStartProtocolSession = AngryEra.StartProtocolSession
function AngryEra:StartProtocolSession()
    Record("start-protocol-session")
    return false, "test-session-failure"
end

calls = {}
AngryEra._protocolStarted = true
AngryEra:OnEnable()
assert(not AngryEra._protocolStarted, "a failed protocol session must leave transport disabled")
for _, call in ipairs(calls) do
    assert(call.Name ~= "register-comm", "a failed protocol session must not register comm prefixes")
end

calls = {}
AngryEra:AfterEnable()
for _, call in ipairs(calls) do
    assert(call.Name ~= "version-query", "delayed setup must not discover peers after session failure")
    assert(
        call.Name ~= "schedule" or call.Value.Method ~= "SendRequestDisplay",
        "delayed setup must not request display state after session failure"
    )
end
AngryEra.StartProtocolSession = successfulStartProtocolSession

print("Initialization lifecycle tests passed.")
