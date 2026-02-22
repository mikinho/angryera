local function fail(message)
    io.stderr:write(message .. "\n")
    os.exit(1)
end

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s (expected: %s, got: %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assert_truthy(value, message)
    if not value then
        fail(message)
    end
end

local function load_app()
    if type(_G.GetBuildInfo) ~= "function" then
        _G.GetBuildInfo = function()
            return "1.15.0", "build", "builddate", 11500
        end
    end

    local app = {}
    local chunk, loadError = loadfile("Data.lua")
    if not chunk then
        fail("Failed to load Data.lua: " .. tostring(loadError))
    end

    local ok, runError = pcall(chunk, "AngryEra", app)
    if not ok then
        fail("Failed to initialize Data.lua: " .. tostring(runError))
    end

    return app
end

local app = load_app()

-- Decode should unescape newlines so imported page content renders with real line breaks.
do
    local decoded = app.JSON_TryDecode("{\"content\":\"# Trash\\n\\nLine2\"}")
    assert_truthy(decoded, "Expected JSON_TryDecode to parse valid JSON object")
    assert_equal(decoded.content, "# Trash\n\nLine2", "Expected escaped newlines to decode into real newlines")
end

-- Decode should preserve null entries in arrays.
do
    local decoded = app.JSON_TryDecode("[1,null,2]")
    assert_truthy(decoded, "Expected JSON_TryDecode to parse array with null")
    assert_equal(#decoded, 3, "Expected array length to include null placeholder")
    assert_equal(decoded[2], app.JSON_NULL, "Expected null array element to map to app.JSON_NULL")
end

-- Decode should preserve null object fields.
do
    local decoded = app.JSON_TryDecode("{\"name\":null,\"content\":\"x\"}")
    assert_truthy(decoded, "Expected JSON_TryDecode to parse object with null value")
    assert_equal(decoded.name, app.JSON_NULL, "Expected object null field to map to app.JSON_NULL")
end

-- Strict parser should reject trailing garbage.
do
    local decoded = app.JSON_TryDecode("{\"a\":1} trailing")
    assert_equal(decoded, nil, "Expected JSON_TryDecode to reject trailing non-whitespace")
end

-- Numeric parser should accept valid JSON exponent formats.
do
    local decoded = app.JSON_TryDecode("{\"a\":1e+2,\"b\":-2.5E-1}")
    assert_truthy(decoded, "Expected JSON_TryDecode to parse valid exponent numbers")
    assert_equal(decoded.a, 100, "Expected 1e+2 to decode to 100")
    assert_equal(decoded.b, -0.25, "Expected -2.5E-1 to decode to -0.25")
end

-- Numeric parser should reject invalid JSON number formats.
do
    local invalid = {
        "{\"a\":1e}",
        "{\"a\":-}",
        "{\"a\":01}",
        "[1e]",
    }
    for _, sample in ipairs(invalid) do
        local decoded = app.JSON_TryDecode(sample)
        assert_equal(decoded, nil, "Expected invalid JSON number to be rejected: " .. sample)
    end
end

-- Encode should preserve JSON null semantics and escaped newlines.
do
    local encoded = app.JSON_Encode({
        content = "# Trash\n\nLine2",
        name = app.JSON_NULL,
    })
    assert_truthy(encoded:find("\"name\":null", 1, true) ~= nil, "Expected JSON_Encode to write JSON null")
    assert_truthy(encoded:find("\"content\":\"# Trash\\n\\nLine2\"", 1, true) ~= nil, "Expected JSON_Encode to escape newlines")

    local roundTrip = app.JSON_TryDecode(encoded)
    assert_truthy(roundTrip, "Expected encoded JSON to decode")
    assert_equal(roundTrip.name, app.JSON_NULL, "Expected encoded null to round-trip as app.JSON_NULL")
    assert_equal(roundTrip.content, "# Trash\n\nLine2", "Expected content newlines to survive encode/decode round-trip")
end

-- ParseVariables JSON path should preserve null + newline behavior.
do
    local parsed = app.ParseVariables("{\"x\":null,\"y\":\"a\\nb\"}")
    assert_equal(parsed.x, app.JSON_NULL, "Expected ParseVariables JSON path to preserve null values")
    assert_equal(parsed.y, "a\nb", "Expected ParseVariables JSON path to decode escaped newline")
end

-- Parser should reject excessively deep nesting.
do
    local deep = string.rep("[", 300) .. string.rep("]", 300)
    local decoded = app.JSON_TryDecode(deep)
    assert_equal(decoded, nil, "Expected excessively deep JSON to be rejected")
end

-- Parser should accept reasonably deep (but bounded) nesting.
do
    local depth = 100
    local nested = string.rep("[", depth) .. "0" .. string.rep("]", depth)
    local decoded = app.JSON_TryDecode(nested)
    assert_truthy(decoded ~= nil, "Expected bounded deep JSON to decode successfully")
end

io.write("JSON regression tests passed.\n")
