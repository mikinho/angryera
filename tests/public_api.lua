local libraries = {}
local newAddonCalls = 0

libraries["AceAddon-3.0"] = {
    NewAddon = function(_, appName)
        newAddonCalls = newAddonCalls + 1
        assert(appName == "AngryEra", "Bootstrap should create the expected AceAddon")
        return {}
    end,
}

for _, libraryName in ipairs({
    "AceGUI-3.0",
    "AceSerializer-3.0",
    "LibMustache",
    "LibCompress",
    "LibDeflate",
    "LibWindow-1.1",
    "LibSharedMedia-3.0",
    "LibDropDownMenu",
}) do
    libraries[libraryName] = {}
end

function _G.LibStub(libraryName)
    return assert(libraries[libraryName], "Unexpected library request: " .. tostring(libraryName))
end

function _G.GetAddOnMetadata(appName, field)
    assert(appName == "AngryEra", "Metadata should be requested for AngryEra")
    return ({
        Title = "Angry Era",
        Version = "3.0.0-test",
        ["X-Timestamp"] = "1234567890",
    })[field]
end

local bootstrap = assert(loadfile("modules/core/bootstrap.lua"))

local occupiedGlobal = { owner = "another addon" }
_G.AngryEra = occupiedGlobal
local loaded, loadError = pcall(bootstrap, "AngryEra", {})
assert(loaded == false, "Bootstrap must reject an occupied public API global")
assert(type(loadError) == "string" and loadError:find("_G.AngryEra", 1, true), "The conflict should be explicit")
assert(_G.AngryEra == occupiedGlobal, "Bootstrap must not overwrite an occupied global")
assert(newAddonCalls == 0, "A public API conflict should be detected before AceAddon registration")

_G.AngryEra = nil
local app = {}
bootstrap("AngryEra", app)

assert(type(app.AngryEra) == "table", "Bootstrap should retain its private addon namespace object")
assert(_G.AngryEra == app.AngryEra, "The public and private addon objects must be identical")
assert(newAddonCalls == 1, "Successful bootstrap should register one AceAddon object")

assert(loadfile("modules/identity.lua"))("AngryEra", app)
assert(loadfile("modules/utils/json.lua"))("AngryEra", app)
assert(loadfile("modules/utils/variables.lua"))("AngryEra", app)
assert(loadfile("modules/api.lua"))("AngryEra", app)

local publicApi = _G.AngryEra
assert(publicApi.NOTE_API_VERSION == 1, "The global API should support version feature detection")
assert(publicApi.NOTE_UPDATE_EVENT == "ANGRYERA_NOTE_UPDATE", "The global API should publish its event name")
assert(type(publicApi.GetDisplayedNote) == "function", "The global API should expose GetDisplayedNote")
assert(type(publicApi.GetDisplayedVars) == "function", "The global API should expose GetDisplayedVars")
assert(type(publicApi.GetDisplayedMeta) == "function", "The global API should expose GetDisplayedMeta")

publicApi:NotifyDisplayedNoteChanged({
    Page = {
        Name = "Patchwerk",
        Contents = "MT: {{MT}}",
    },
    RenderedText = "MT: Zessy",
    MergedVariables = {
        MT = "Zessy",
        ["$encounter"] = "Patchwerk",
    },
})

local note = publicApi:GetDisplayedNote()
local meta = publicApi:GetDisplayedMeta()
assert(note and note.Name == "Patchwerk", "The documented global getter should return the displayed note")
assert(note.Rendered == "MT: Zessy", "The documented global getter should return rendered text")
assert(meta and meta.encounter == "Patchwerk", "The documented WeakAuras metadata lookup should work")

print("Public API bootstrap tests passed.")
