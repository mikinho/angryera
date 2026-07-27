local createdWidgets = {}
local printed = {}
local parsedImportOptions

local function NewWidget(kind)
    local widget = {
        callbacks = {},
        children = {},
        frame = {},
        kind = kind,
    }
    if kind == "MultiLineEditBox" then
        widget.editBox = {
            SetFocus = function(editBox)
                editBox.focused = true
            end,
        }
    end

    function widget:SetCallback(event, callback)
        self.callbacks[event] = callback
    end
    function widget:AddChild(child)
        self.children[#self.children + 1] = child
    end
    function widget:SetLabel(value)
        self.label = value
    end
    function widget:SetText(value)
        self.text = value
    end
    function widget:SetValue(value)
        self.value = value
    end
    function widget:GetValue()
        return self.value
    end
    function widget:SetFocus()
        self.focused = true
    end
    function widget:HighlightText()
        self.highlighted = true
    end
    function widget:Hide()
        self.hidden = true
    end

    for _, method in ipairs({
        "DisableButton",
        "EnableResize",
        "SetFullHeight",
        "SetFullWidth",
        "SetHeight",
        "SetLayout",
        "SetTitle",
        "SetWidth",
    }) do
        widget[method] = function() end
    end

    createdWidgets[#createdWidgets + 1] = widget
    return widget
end

local function LatestWidget(kind)
    for index = #createdWidgets, 1, -1 do
        if createdWidgets[index].kind == kind then
            return createdWidgets[index]
        end
    end
end

local AceGUI = {}
function AceGUI:Create(kind)
    return NewWidget(kind)
end
function AceGUI:Release() end

local serialization = {}
function serialization.GetPageExportData(page, options)
    if options.includeVariables and page.Vars == "invalid" then
        return nil, "Page.Vars is invalid"
    end
    local variablesIncluded
    if not options.includeVariables then
        variablesIncluded = false
    end
    return {
        Name = page.Name,
        Contents = page.Contents,
        Vars = options.includeVariables and page.Vars or nil,
        VariablesIncluded = variablesIncluded,
    }
end
function serialization.EncodeExportString(data)
    return data.VariablesIncluded == false and "AA:Page:2:content-only" or "AA:Page:1:complete"
end
function serialization.ParseImportString()
    return true,
        {
            Name = "Imported",
            Contents = "Assignment",
            VariablesIncluded = nil,
            Vars = "MT=Zessy",
        },
        "Page"
end

local AngryEra = {
    utils = {
        json = {},
        serialization = serialization,
        helpers = {
            CompareIndexedEntries = function(left, right)
                return (left.Index or 0) < (right.Index or 0)
            end,
        },
    },
}

function AngryEra:Print(message)
    printed[#printed + 1] = message
end

local app = {
    AngryEra = AngryEra,
    libs = {
        AceGUI = AceGUI,
    },
}

AngryAssign_Pages = {
    [1] = {
        Id = 1,
        Name = "Exported",
        Contents = "Assignment",
        Vars = "MT=Zessy",
    },
}
AngryAssign_Categories = {}
rawset(_G, "UISpecialFrames", {})
rawset(_G, "tinsert", table.insert)
rawset(_G, "C_Timer", {
    After = function(_, callback)
        callback()
    end,
})

assert(loadfile("modules/ui/import_export.lua"))("AngryEra", app)

AngryEra:Export(1, "page", "Encoded AA")
local exportToggle = LatestWidget("CheckBox")
local exportText = LatestWidget("MultiLineEditBox")
assert(exportToggle.value == true, "Encoded AA export should include variables and metadata by default")
assert(exportText.text == "AA:Page:1:complete", "The default export should use the complete v1 payload")

exportToggle.value = false
exportToggle.callbacks.OnValueChanged(exportToggle, "OnValueChanged", false)
assert(exportText.text == "AA:Page:2:content-only", "Unchecking export variables should regenerate a v2 payload")

createdWidgets = {}
AngryAssign_Pages[1].Vars = "invalid"
AngryEra:Export(1, "page", "Encoded AA")
exportToggle = LatestWidget("CheckBox")
exportText = LatestWidget("MultiLineEditBox")
assert(exportToggle.value == false, "Invalid stored variables should fall back to a visibly content-only export")
assert(exportText.text == "AA:Page:2:content-only", "Fallback output should remain safely content-only")
assert(#printed > 0, "The content-only fallback should explain why variables were omitted")

exportToggle.value = true
exportToggle.callbacks.OnValueChanged(exportToggle, "OnValueChanged", true)
assert(exportToggle.value == false, "A failed full rebuild should revert the export checkbox")
assert(exportText.text == "AA:Page:2:content-only", "A failed full rebuild must not relabel the old content-only text")

function AngryEra:ConfirmImportPage(_, options)
    parsedImportOptions = options
end

createdWidgets = {}
AngryEra:ShowImportWindow()
local importToggle = LatestWidget("CheckBox")
local importText = LatestWidget("MultiLineEditBox")
assert(importToggle.value == true, "Encoded AA import should include variables and metadata by default")
importText.callbacks.OnTextChanged(importText, "OnTextChanged", "AA:Page:1:fixture")
assert(
    parsedImportOptions and parsedImportOptions.includeVariables == true,
    "The import window should retain its default variable choice"
)

createdWidgets = {}
parsedImportOptions = nil
AngryEra:ShowImportWindow()
importToggle = LatestWidget("CheckBox")
importText = LatestWidget("MultiLineEditBox")
importToggle:SetValue(false)
importText.callbacks.OnTextChanged(importText, "OnTextChanged", "AA:Page:1:fixture")
assert(
    parsedImportOptions and parsedImportOptions.includeVariables == false,
    "The import window should pass an explicit variable opt-out"
)

print("Import/export option UI tests passed.")
