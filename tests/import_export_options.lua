local createdWidgets = {}
local releasedWidgets = {}
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
function AceGUI:Release(widget)
    assert(not releasedWidgets[widget], "tracked windows must be released exactly once")
    releasedWidgets[widget] = true
end

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

local function CountSpecialFrame(name)
    local count = 0
    for _, registered in ipairs(UISpecialFrames) do
        if registered == name then
            count = count + 1
        end
    end
    return count
end

AngryEra:Export(1, "page", "Encoded AA")
local firstExportWindow = AngryEra._generalExportWindow
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
assert(releasedWidgets[firstExportWindow], "reopening export should release the prior pooled window")
assert(CountSpecialFrame("AngryEra_GeneralExportWindow") == 1, "export should have one Escape registration")
exportToggle = LatestWidget("CheckBox")
exportText = LatestWidget("MultiLineEditBox")
assert(exportToggle.value == false, "Invalid stored variables should fall back to a visibly content-only export")
assert(exportText.text == "AA:Page:2:content-only", "Fallback output should remain safely content-only")
assert(#printed > 0, "The content-only fallback should explain why variables were omitted")

exportToggle.value = true
exportToggle.callbacks.OnValueChanged(exportToggle, "OnValueChanged", true)
assert(exportToggle.value == false, "A failed full rebuild should revert the export checkbox")
assert(exportText.text == "AA:Page:2:content-only", "A failed full rebuild must not relabel the old content-only text")

local processedOutputPages = {}
function AngryEra:ProcessPageForOutput(page)
    processedOutputPages[#processedOutputPages + 1] = page
    return page.OutputFixture
end

AngryAssign_Pages[1].OutputFixture = "Zessy: {SKULL} {X} {SQUARE} {rt8}"
createdWidgets = {}
AngryEra:Export(1, "page", "Output")
local pageOutputWindow = AngryEra._generalExportWindow
exportText = LatestWidget("MultiLineEditBox")
assert(
    #processedOutputPages == 1 and processedOutputPages[1] == AngryAssign_Pages[1],
    "page Output export should process the selected page"
)
assert(
    exportText.text == AngryAssign_Pages[1].OutputFixture,
    "page Output export should display ProcessPageForOutput text without rewriting marker tokens"
)

AngryAssign_Categories[2] = {
    Id = 2,
    Name = "Ordered Output",
}
AngryAssign_Pages[2] = {
    Id = 2,
    Name = "Second",
    CategoryId = 2,
    Index = 2,
    OutputFixture = "Second: {SQUARE}",
}
AngryAssign_Pages[3] = {
    Id = 3,
    Name = "First",
    CategoryId = 2,
    Index = 1,
    OutputFixture = "First: {SKULL}",
}
processedOutputPages = {}
createdWidgets = {}
AngryEra:Export(2, "category", "Output")
exportText = LatestWidget("MultiLineEditBox")
assert(releasedWidgets[pageOutputWindow], "opening category Output should release the prior page Output window")
assert(
    #processedOutputPages == 2
        and processedOutputPages[1] == AngryAssign_Pages[3]
        and processedOutputPages[2] == AngryAssign_Pages[2],
    "category Output should process pages in visible order"
)
assert(
    exportText.text == "First: {SKULL}\n\nSecond: {SQUARE}",
    "category Output should concatenate processed text without rewriting marker tokens"
)

function AngryEra:ConfirmImportPage(_, options)
    parsedImportOptions = options
end

createdWidgets = {}
AngryEra:ShowImportWindow()
local firstImportWindow = AngryEra._encodedImportWindow
local importToggle = LatestWidget("CheckBox")
local importText = LatestWidget("MultiLineEditBox")
assert(importToggle.value == true, "Encoded AA import should include variables and metadata by default")
importText.callbacks.OnTextChanged(importText, "OnTextChanged", "AA:Page:1:fixture")
assert(
    parsedImportOptions and parsedImportOptions.includeVariables == true,
    "The import window should retain its default variable choice"
)
assert(releasedWidgets[firstImportWindow], "a completed import should release its pooled window")
assert(CountSpecialFrame("AngryEra_ImportWindow") == 0, "completed import should remove its Escape registration")

createdWidgets = {}
parsedImportOptions = nil
AngryEra:ShowImportWindow()
local secondImportWindow = AngryEra._encodedImportWindow
importToggle = LatestWidget("CheckBox")
importText = LatestWidget("MultiLineEditBox")
importToggle:SetValue(false)
importText.callbacks.OnTextChanged(importText, "OnTextChanged", "AA:Page:1:fixture")
assert(
    parsedImportOptions and parsedImportOptions.includeVariables == false,
    "The import window should pass an explicit variable opt-out"
)
assert(releasedWidgets[secondImportWindow], "every completed import should release exactly once")

AngryEra:ShowImportWindow()
local escapeClosedImportWindow = AngryEra._encodedImportWindow
escapeClosedImportWindow.callbacks.OnClose(escapeClosedImportWindow)
assert(
    releasedWidgets[escapeClosedImportWindow]
        and AngryEra._encodedImportWindow == nil
        and CountSpecialFrame("AngryEra_ImportWindow") == 0,
    "Escape/window-close should release the tracked AceGUI window and unregister it"
)
escapeClosedImportWindow.callbacks.OnClose(escapeClosedImportWindow)
assert(
    releasedWidgets[escapeClosedImportWindow],
    "a repeated close callback should remain idempotent instead of releasing the pooled window twice"
)

AngryEra:ShowImportWindow()
local disabledImportWindow = AngryEra._encodedImportWindow
assert(CountSpecialFrame("AngryEra_ImportWindow") == 1, "an open import should have one Escape registration")
assert(AngryEra:CloseImportExportWindows(), "addon teardown should close tracked import/export windows")
assert(releasedWidgets[disabledImportWindow], "addon teardown should release the open import window")
assert(
    CountSpecialFrame("AngryEra_ImportWindow") == 0
        and CountSpecialFrame("AngryEra_GeneralExportWindow") == 0
        and AngryEra._encodedImportWindow == nil
        and AngryEra._generalExportWindow == nil,
    "addon teardown should remove every tracked window and Escape global"
)
assert(not AngryEra:CloseImportExportWindows(), "repeated teardown should be idempotent")

print("Import/export option UI tests passed.")
