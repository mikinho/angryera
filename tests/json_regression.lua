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

local function load_json()
    local app = { AngryEra = { utils = {} } }
    local chunk, loadError = loadfile("modules/utils/json.lua")
    if not chunk then
        fail("Failed to load modules/utils/json.lua: " .. tostring(loadError))
    end

    local ok, runError = pcall(chunk, "AngryEra", app)
    if not ok then
        fail("Failed to initialize modules/utils/json.lua: " .. tostring(runError))
    end

    return app.AngryEra.utils.json
end

local json = load_json()

-- Decode should unescape newlines so imported page content renders with real line breaks.
do
    local decoded = json.JSON_TryDecode("{\"content\":\"# Trash\\n\\nLine2\"}")
    assert_truthy(decoded, "Expected JSON_TryDecode to parse valid JSON object")
    assert_equal(decoded.content, "# Trash\n\nLine2", "Expected escaped newlines to decode into real newlines")
end

-- Decode should preserve null entries in arrays.
do
    local decoded = json.JSON_TryDecode("[1,null,2]")
    assert_truthy(decoded, "Expected JSON_TryDecode to parse array with null")
    assert_equal(#decoded, 3, "Expected array length to include null placeholder")
    assert_equal(decoded[2], json.JSON_NULL, "Expected null array element to map to json.JSON_NULL")
end

-- Decode should preserve null object fields.
do
    local decoded = json.JSON_TryDecode("{\"name\":null,\"content\":\"x\"}")
    assert_truthy(decoded, "Expected JSON_TryDecode to parse object with null value")
    assert_equal(decoded.name, json.JSON_NULL, "Expected object null field to map to json.JSON_NULL")
end

-- Strict parser should reject trailing garbage.
do
    local decoded = json.JSON_TryDecode("{\"a\":1} trailing")
    assert_equal(decoded, nil, "Expected JSON_TryDecode to reject trailing non-whitespace")
end

-- Numeric parser should accept valid JSON exponent formats.
do
    local decoded = json.JSON_TryDecode("{\"a\":1e+2,\"b\":-2.5E-1}")
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
        local decoded = json.JSON_TryDecode(sample)
        assert_equal(decoded, nil, "Expected invalid JSON number to be rejected: " .. sample)
    end
end

-- Encode should preserve JSON null semantics and escaped newlines.
do
    local encoded = json.JSON_Encode({
        content = "# Trash\n\nLine2",
        name = json.JSON_NULL,
    })
    assert_truthy(encoded:find("\"name\":null", 1, true) ~= nil, "Expected JSON_Encode to write JSON null")
    assert_truthy(
        encoded:find("\"content\":\"# Trash\\n\\nLine2\"", 1, true) ~= nil,
        "Expected JSON_Encode to escape newlines"
    )

    local roundTrip = json.JSON_TryDecode(encoded)
    assert_truthy(roundTrip, "Expected encoded JSON to decode")
    assert_equal(roundTrip.name, json.JSON_NULL, "Expected encoded null to round-trip as json.JSON_NULL")
    assert_equal(roundTrip.content, "# Trash\n\nLine2", "Expected content newlines to survive encode/decode round-trip")
end

-- ParseVariables JSON path should preserve null + newline behavior.
do
    local parsed = json.ParseVariables("{\"x\":null,\"y\":\"a\\nb\"}")
    assert_equal(parsed.x, json.JSON_NULL, "Expected ParseVariables JSON path to preserve null values")
    assert_equal(parsed.y, "a\nb", "Expected ParseVariables JSON path to decode escaped newline")
end

-- Variable references should resolve recursively while preserving invalid references.
do
    local resolved = json.ResolveVariableReferences({
        LIP1 = "{{FURY12}}",
        FURY12 = "Blah",
        CHAIN1 = "{{CHAIN2}}",
        CHAIN2 = "{{FURY12}}",
        LABEL = "Tank: {{FURY12}}",
        UNKNOWN = "{{MISSING}}",
        CYCLE_A = "{{CYCLE_B}}",
        CYCLE_B = "{{CYCLE_A}}",
    })

    assert_equal(resolved.LIP1, "Blah", "Expected direct variable references to resolve")
    assert_equal(resolved.CHAIN1, "Blah", "Expected chained variable references to resolve")
    assert_equal(resolved.LABEL, "Tank: Blah", "Expected embedded variable references to resolve")
    assert_equal(resolved.UNKNOWN, "{{MISSING}}", "Expected unknown references to remain visible")
    assert_truthy(
        resolved.CYCLE_A:match("{{.-}}") and resolved.CYCLE_B:match("{{.-}}"),
        "Expected cyclic references to remain visible"
    )
end

-- Parser should reject excessively deep nesting.
do
    local deep = string.rep("[", 300) .. string.rep("]", 300)
    local decoded = json.JSON_TryDecode(deep)
    assert_equal(decoded, nil, "Expected excessively deep JSON to be rejected")
end

-- Parser should accept reasonably deep (but bounded) nesting.
do
    local depth = 100
    local nested = string.rep("[", depth) .. "0" .. string.rep("]", depth)
    local decoded = json.JSON_TryDecode(nested)
    assert_truthy(decoded ~= nil, "Expected bounded deep JSON to decode successfully")
end

io.write("JSON regression tests passed.\n")
