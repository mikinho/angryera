local AngryEra = {
    utils = {},
}
local app = {
    AngryEra = AngryEra,
}

assert(loadfile("modules/utils/bounded_deflate.lua"))("AngryEra", app)
local boundedDeflate = assert(AngryEra.utils.boundedDeflate)

local function AssertEqual(actual, expected, message)
    assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function AssertFailure(value, errorCode, expectedError, message)
    assert(value == nil, message .. " should fail")
    AssertEqual(errorCode, expectedError, message)
end

local Writer = {}
Writer.__index = Writer

function Writer:WriteBits(value, count)
    for _ = 1, count do
        local bit = value % 2
        value = (value - bit) / 2
        self.Byte = self.Byte + bit * (2 ^ self.BitCount)
        self.BitCount = self.BitCount + 1
        if self.BitCount == 8 then
            self.Bytes[#self.Bytes + 1] = string.char(self.Byte)
            self.Byte = 0
            self.BitCount = 0
        end
    end
end

function Writer:AlignToByte()
    if self.BitCount > 0 then
        self.Bytes[#self.Bytes + 1] = string.char(self.Byte)
        self.Byte = 0
        self.BitCount = 0
    end
end

function Writer:WriteByte(value)
    assert(self.BitCount == 0, "WriteByte requires byte alignment")
    self.Bytes[#self.Bytes + 1] = string.char(value)
end

function Writer:Finish()
    self:AlignToByte()
    return table.concat(self.Bytes)
end

local function NewWriter()
    return setmetatable({
        BitCount = 0,
        Byte = 0,
        Bytes = {},
    }, Writer)
end

local function ReverseBits(value, count)
    local reversed = 0
    for _ = 1, count do
        local bit = value % 2
        value = (value - bit) / 2
        reversed = reversed * 2 + bit
    end
    return reversed
end

local function BuildEncoder(lengths, maximumSymbol, maximumBits)
    local counts = {}
    for symbol = 0, maximumSymbol do
        local length = lengths[symbol] or 0
        if length > 0 then
            counts[length] = (counts[length] or 0) + 1
        end
    end

    local nextCode = {}
    local code = 0
    for bits = 1, maximumBits do
        code = (code + (counts[bits - 1] or 0)) * 2
        nextCode[bits] = code
    end

    local encoder = {}
    for symbol = 0, maximumSymbol do
        local length = lengths[symbol] or 0
        if length > 0 then
            local symbolCode = nextCode[length]
            nextCode[length] = symbolCode + 1
            encoder[symbol] = {
                Bits = ReverseBits(symbolCode, length),
                Length = length,
            }
        end
    end
    return encoder
end

local function WriteSymbol(writer, encoder, symbol)
    local encoded = assert(encoder[symbol], "missing test encoder symbol")
    writer:WriteBits(encoded.Bits, encoded.Length)
end

local fixedLiteralLengths = {}
for symbol = 0, 143 do
    fixedLiteralLengths[symbol] = 8
end
for symbol = 144, 255 do
    fixedLiteralLengths[symbol] = 9
end
for symbol = 256, 279 do
    fixedLiteralLengths[symbol] = 7
end
for symbol = 280, 287 do
    fixedLiteralLengths[symbol] = 8
end
local fixedDistanceLengths = {}
for symbol = 0, 31 do
    fixedDistanceLengths[symbol] = 5
end
local fixedLiteralEncoder = BuildEncoder(fixedLiteralLengths, 287, 15)
local fixedDistanceEncoder = BuildEncoder(fixedDistanceLengths, 31, 15)

local lengthBase = {
    [257] = 3,
    [258] = 4,
    [259] = 5,
    [260] = 6,
    [261] = 7,
    [262] = 8,
    [263] = 9,
    [264] = 10,
    [265] = 11,
    [266] = 13,
    [267] = 15,
    [268] = 17,
    [269] = 19,
    [270] = 23,
    [271] = 27,
    [272] = 31,
    [273] = 35,
    [274] = 43,
    [275] = 51,
    [276] = 59,
    [277] = 67,
    [278] = 83,
    [279] = 99,
    [280] = 115,
    [281] = 131,
    [282] = 163,
    [283] = 195,
    [284] = 227,
    [285] = 258,
}
local lengthExtra = {
    [257] = 0,
    [258] = 0,
    [259] = 0,
    [260] = 0,
    [261] = 0,
    [262] = 0,
    [263] = 0,
    [264] = 0,
    [265] = 1,
    [266] = 1,
    [267] = 1,
    [268] = 1,
    [269] = 2,
    [270] = 2,
    [271] = 2,
    [272] = 2,
    [273] = 3,
    [274] = 3,
    [275] = 3,
    [276] = 3,
    [277] = 4,
    [278] = 4,
    [279] = 4,
    [280] = 4,
    [281] = 5,
    [282] = 5,
    [283] = 5,
    [284] = 5,
    [285] = 0,
}

local function WriteLength(writer, length)
    for symbol = 257, 285 do
        local extraBits = lengthExtra[symbol]
        local maximum = lengthBase[symbol] + (2 ^ extraBits) - 1
        if symbol == 285 then
            maximum = 258
        end
        if length >= lengthBase[symbol] and length <= maximum then
            WriteSymbol(writer, fixedLiteralEncoder, symbol)
            if extraBits > 0 then
                writer:WriteBits(length - lengthBase[symbol], extraBits)
            end
            return
        end
    end
    error("unsupported test match length")
end

local function BuildStoredRaw(value, finalBlock)
    assert(#value <= 65535, "test stored block is too large")
    local writer = NewWriter()
    writer:WriteBits(finalBlock == false and 0 or 1, 1)
    writer:WriteBits(0, 2)
    writer:AlignToByte()
    local length = #value
    local complement = 65535 - length
    writer:WriteByte(length % 256)
    writer:WriteByte(math.floor(length / 256))
    writer:WriteByte(complement % 256)
    writer:WriteByte(math.floor(complement / 256))
    for index = 1, length do
        writer:WriteByte(value:byte(index))
    end
    return writer:Finish()
end

local function BuildFixedLiteralRaw(value)
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(1, 2)
    for index = 1, #value do
        WriteSymbol(writer, fixedLiteralEncoder, value:byte(index))
    end
    WriteSymbol(writer, fixedLiteralEncoder, 256)
    return writer:Finish()
end

local function BuildRepeatedFixedRaw(outputBytes)
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(1, 2)

    local remaining = outputBytes
    if remaining > 0 then
        WriteSymbol(writer, fixedLiteralEncoder, string.byte("A"))
        remaining = remaining - 1
    end
    while remaining > 0 do
        if remaining < 3 then
            WriteSymbol(writer, fixedLiteralEncoder, string.byte("A"))
            remaining = remaining - 1
        else
            local length = math.min(remaining, 258)
            WriteLength(writer, length)
            WriteSymbol(writer, fixedDistanceEncoder, 0)
            remaining = remaining - length
        end
    end

    WriteSymbol(writer, fixedLiteralEncoder, 256)
    return writer:Finish()
end

local function BuildFixedThenStoredRaw()
    local writer = NewWriter()
    writer:WriteBits(0, 1)
    writer:WriteBits(1, 2)
    WriteSymbol(writer, fixedLiteralEncoder, string.byte("X"))
    WriteSymbol(writer, fixedLiteralEncoder, 256)

    writer:WriteBits(1, 1)
    writer:WriteBits(0, 2)
    writer:AlignToByte()
    writer:WriteByte(1)
    writer:WriteByte(0)
    writer:WriteByte(254)
    writer:WriteByte(255)
    writer:WriteByte(string.byte("Y"))
    return writer:Finish()
end

local function BuildCrossBlockMatchRaw()
    local writer = NewWriter()
    writer:WriteBits(0, 1)
    writer:WriteBits(1, 2)
    for index = 1, 5 do
        WriteSymbol(writer, fixedLiteralEncoder, ("ABCDE"):byte(index))
    end
    WriteSymbol(writer, fixedLiteralEncoder, 256)

    writer:WriteBits(1, 1)
    writer:WriteBits(1, 2)
    WriteLength(writer, 5)
    WriteSymbol(writer, fixedDistanceEncoder, 4)
    writer:WriteBits(0, 1)
    WriteSymbol(writer, fixedLiteralEncoder, 256)
    return writer:Finish()
end

local function BuildMaximumDistanceRaw()
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(1, 2)
    local source = {}
    for index = 1, 32768 do
        local value = (index - 1) % 251
        source[index] = string.char(value)
        WriteSymbol(writer, fixedLiteralEncoder, value)
    end
    WriteLength(writer, 258)
    WriteSymbol(writer, fixedDistanceEncoder, 29)
    writer:WriteBits(8191, 13)
    WriteSymbol(writer, fixedLiteralEncoder, 256)

    local sourceText = table.concat(source)
    return writer:Finish(), sourceText .. sourceText:sub(1, 258)
end

local codeLengthOrder = {
    16,
    17,
    18,
    0,
    8,
    7,
    9,
    6,
    10,
    5,
    11,
    4,
    12,
    3,
    13,
    2,
    14,
    1,
    15,
}

local function BuildDynamicRaw()
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(2, 2)
    writer:WriteBits(1, 5)
    writer:WriteBits(3, 5)
    writer:WriteBits(14, 4)

    local codeLengthLengths = {
        [0] = 2,
        [1] = 3,
        [2] = 3,
        [16] = 3,
        [17] = 3,
        [18] = 2,
    }
    for index = 1, 18 do
        writer:WriteBits(codeLengthLengths[codeLengthOrder[index]] or 0, 3)
    end
    local codeLengthEncoder = BuildEncoder(codeLengthLengths, 18, 7)

    WriteSymbol(writer, codeLengthEncoder, 18)
    writer:WriteBits(51, 7)
    WriteSymbol(writer, codeLengthEncoder, 17)
    writer:WriteBits(0, 3)
    WriteSymbol(writer, codeLengthEncoder, 1)
    WriteSymbol(writer, codeLengthEncoder, 18)
    writer:WriteBits(127, 7)
    WriteSymbol(writer, codeLengthEncoder, 18)
    writer:WriteBits(41, 7)
    WriteSymbol(writer, codeLengthEncoder, 2)
    WriteSymbol(writer, codeLengthEncoder, 2)
    WriteSymbol(writer, codeLengthEncoder, 16)
    writer:WriteBits(0, 2)
    WriteSymbol(writer, codeLengthEncoder, 2)

    local literalLengths = {
        [65] = 1,
        [256] = 2,
        [257] = 2,
    }
    local distanceLengths = {
        [0] = 2,
        [1] = 2,
        [2] = 2,
        [3] = 2,
    }
    local literalEncoder = BuildEncoder(literalLengths, 257, 15)
    local distanceEncoder = BuildEncoder(distanceLengths, 3, 15)
    WriteSymbol(writer, literalEncoder, 65)
    WriteSymbol(writer, literalEncoder, 257)
    WriteSymbol(writer, distanceEncoder, 0)
    WriteSymbol(writer, literalEncoder, 256)
    return writer:Finish()
end

local function BuildMaximumHdistRaw()
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(2, 2)
    writer:WriteBits(0, 5)
    writer:WriteBits(31, 5)
    writer:WriteBits(14, 4)

    local codeLengthLengths = {
        [0] = 1,
        [1] = 1,
    }
    for index = 1, 18 do
        writer:WriteBits(codeLengthLengths[codeLengthOrder[index]] or 0, 3)
    end
    local codeLengthEncoder = BuildEncoder(codeLengthLengths, 18, 7)
    for symbol = 0, 256 do
        WriteSymbol(writer, codeLengthEncoder, (symbol == 65 or symbol == 256) and 1 or 0)
    end
    for _ = 1, 32 do
        WriteSymbol(writer, codeLengthEncoder, 0)
    end

    local literalEncoder = BuildEncoder({
        [65] = 1,
        [256] = 1,
    }, 256, 15)
    WriteSymbol(writer, literalEncoder, 65)
    WriteSymbol(writer, literalEncoder, 256)
    return writer:Finish()
end

local function BuildInvalidFixedDistanceRaw(distanceSymbol)
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(1, 2)
    WriteSymbol(writer, fixedLiteralEncoder, string.byte("A"))
    WriteSymbol(writer, fixedLiteralEncoder, 257)
    WriteSymbol(writer, fixedDistanceEncoder, distanceSymbol)
    return writer:Finish()
end

local function BuildReservedLengthRaw()
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(1, 2)
    WriteSymbol(writer, fixedLiteralEncoder, 286)
    return writer:Finish()
end

local function BuildLeadingRepeatRaw()
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(2, 2)
    writer:WriteBits(0, 5)
    writer:WriteBits(0, 5)
    writer:WriteBits(0, 4)
    local codeLengthLengths = {
        [0] = 1,
        [16] = 1,
    }
    for index = 1, 4 do
        writer:WriteBits(codeLengthLengths[codeLengthOrder[index]] or 0, 3)
    end
    local encoder = BuildEncoder(codeLengthLengths, 18, 7)
    WriteSymbol(writer, encoder, 16)
    return writer:Finish()
end

local function BuildMissingEndCodeRaw()
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(2, 2)
    writer:WriteBits(0, 5)
    writer:WriteBits(0, 5)
    writer:WriteBits(14, 4)
    local codeLengthLengths = {
        [0] = 1,
        [1] = 1,
    }
    for index = 1, 18 do
        writer:WriteBits(codeLengthLengths[codeLengthOrder[index]] or 0, 3)
    end
    local encoder = BuildEncoder(codeLengthLengths, 18, 7)
    for symbol = 0, 256 do
        WriteSymbol(writer, encoder, symbol == 65 and 1 or 0)
    end
    WriteSymbol(writer, encoder, 1)
    return writer:Finish()
end

local function BuildInvalidCodeLengthTreeRaw(lengths)
    local writer = NewWriter()
    writer:WriteBits(1, 1)
    writer:WriteBits(2, 2)
    writer:WriteBits(0, 5)
    writer:WriteBits(0, 5)
    writer:WriteBits(0, 4)
    for index = 1, 4 do
        writer:WriteBits(lengths[codeLengthOrder[index]] or 0, 3)
    end
    return writer:Finish()
end

local function Adler32(value)
    local first = 1
    local second = 0
    for index = 1, #value do
        first = (first + value:byte(index)) % 65521
        second = (second + first) % 65521
    end
    return second * 65536 + first
end

local function BigEndian32(value)
    local fourth = value % 256
    value = (value - fourth) / 256
    local third = value % 256
    value = (value - third) / 256
    local second = value % 256
    value = (value - second) / 256
    local first = value % 256
    return string.char(first, second, third, fourth)
end

local function DecodeHex(value)
    return (value:gsub("%x%x", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function BuildZlib(raw, output)
    return string.char(120, 156) .. raw .. BigEndian32(Adler32(output))
end

local function AssertRaw(raw, expected, label)
    local output, trailing = boundedDeflate.DecompressDeflate(raw, #expected)
    AssertEqual(output, expected, label .. " exact output")
    AssertEqual(trailing, 0, label .. " exact trailing bytes")

    if #expected > 0 then
        local oversized
        local oversizedError
        oversized, oversizedError = boundedDeflate.DecompressDeflate(raw, #expected - 1)
        AssertFailure(oversized, oversizedError, "output-too-large", label .. " under-limit")
    end
end

local storedValue = "\000stored\255"
local storedRaw = BuildStoredRaw(storedValue)
AssertRaw(storedRaw, storedValue, "stored block")

local fixedValue = "\000fixed literals\255"
local fixedRaw = BuildFixedLiteralRaw(fixedValue)
AssertRaw(fixedRaw, fixedValue, "fixed block")

local multipleBlocks = BuildStoredRaw("first-", false) .. BuildFixedLiteralRaw("second")
AssertRaw(multipleBlocks, "first-second", "multiple blocks")
AssertRaw(BuildFixedThenStoredRaw(), "XY", "unaligned multiple blocks")
AssertRaw(BuildCrossBlockMatchRaw(), "ABCDEABCDE", "cross-block match")
local maximumDistanceRaw, maximumDistanceValue = BuildMaximumDistanceRaw()
AssertRaw(maximumDistanceRaw, maximumDistanceValue, "maximum-distance match")

local dynamicRaw = BuildDynamicRaw()
AssertRaw(dynamicRaw, "AAAA", "dynamic block")
AssertRaw(BuildMaximumHdistRaw(), "A", "maximum HDIST block")

local emptyRaw = BuildFixedLiteralRaw("")
local emptyOutput, emptyTrailing = boundedDeflate.DecompressDeflate(emptyRaw, 0)
AssertEqual(emptyOutput, "", "empty stream at zero limit")
AssertEqual(emptyTrailing, 0, "empty stream trailing bytes")
local nonemptyAtZero, nonemptyAtZeroError = boundedDeflate.DecompressDeflate(fixedRaw, 0)
AssertFailure(nonemptyAtZero, nonemptyAtZeroError, "output-too-large", "non-empty stream at zero limit")

for _, size in ipairs({ 32768, 32769, 65535, 65536, 65537 }) do
    local boundaryRaw = BuildRepeatedFixedRaw(size)
    local boundaryOutput, boundaryTrailing = boundedDeflate.DecompressDeflate(boundaryRaw, size)
    assert(boundaryOutput and #boundaryOutput == size, "window boundary should decode at " .. size)
    assert(boundaryOutput:match("^A+$"), "window boundary output should retain repeated bytes at " .. size)
    AssertEqual(boundaryTrailing, 0, "window boundary trailing bytes at " .. size)
    local boundaryOversized, boundaryError = boundedDeflate.DecompressDeflate(boundaryRaw, size - 1)
    AssertFailure(boundaryOversized, boundaryError, "output-too-large", "window boundary under-limit at " .. size)
end

local bombRaw = BuildRepeatedFixedRaw(4 * 1024 * 1024)
assert(#bombRaw < 65536, "high-ratio test stream should stay compact")
local bombOutput, bombError = boundedDeflate.DecompressDeflate(bombRaw, 1024)
AssertFailure(bombOutput, bombError, "output-too-large", "high-ratio bomb")

local rawWithTrailing = dynamicRaw .. "tail"
local trailingOutput, trailingBytes = boundedDeflate.DecompressDeflate(rawWithTrailing, 4)
AssertEqual(trailingOutput, "AAAA", "raw trailing output")
AssertEqual(trailingBytes, 4, "raw trailing count")

local zlib = BuildZlib(dynamicRaw, "AAAA")
local zlibOutput, zlibTrailing = boundedDeflate.DecompressZlib(zlib, 4)
AssertEqual(zlibOutput, "AAAA", "zlib output")
AssertEqual(zlibTrailing, 0, "zlib trailing count")
local zlibOversized, zlibOversizedError = boundedDeflate.DecompressZlib(zlib, 3)
AssertFailure(zlibOversized, zlibOversizedError, "output-too-large", "zlib under-limit")
local zlibWithTrailing = zlib .. "after"
zlibOutput, zlibTrailing = boundedDeflate.DecompressZlib(zlibWithTrailing, 4)
AssertEqual(zlibOutput, "AAAA", "zlib trailing output")
AssertEqual(zlibTrailing, 5, "zlib trailing count")

local smallWindowZlib = string.char(8, 29) .. dynamicRaw .. BigEndian32(Adler32("AAAA"))
local smallWindowOutput, smallWindowTrailing = boundedDeflate.DecompressZlib(smallWindowZlib, 4)
AssertEqual(smallWindowOutput, "AAAA", "zlib advertised small window output")
AssertEqual(smallWindowTrailing, 0, "zlib advertised small window trailing bytes")
local undersizedWindowZlib = string.char(8, 29) .. maximumDistanceRaw .. BigEndian32(Adler32(maximumDistanceValue))
local undersizedWindowOutput, undersizedWindowError =
    boundedDeflate.DecompressZlib(undersizedWindowZlib, #maximumDistanceValue)
AssertFailure(
    undersizedWindowOutput,
    undersizedWindowError,
    "invalid-distance",
    "distance beyond advertised zlib window"
)

local knownFixedZlib = DecodeHex("78dacb48cdc9c90700062c0215")
local knownFixedOutput, knownFixedTrailing = boundedDeflate.DecompressZlib(knownFixedZlib, 5)
AssertEqual(knownFixedOutput, "hello", "independent fixed zlib fixture")
AssertEqual(knownFixedTrailing, 0, "independent fixed zlib fixture trailing bytes")

local knownDynamicZlib = DecodeHex(
    "78daedcbc10980301403d0bb5374b52f162d562de8c9e96de7f01d1202e1456d5ba4393f91d6388e484bae7de776977"
        .. "a9de91dc7c8b38d2e57af3d5a8b294010044110044110044110044110044110044110044110044110044110044110fc"
        .. "2bfc00ab191239"
)
local knownDynamicValue = string.rep("alpha beta gamma delta epsilon zeta eta theta iota kappa\n", 200)
local knownDynamicRawOutput, knownDynamicRawTrailing =
    boundedDeflate.DecompressDeflate(knownDynamicZlib:sub(3, -5), #knownDynamicValue)
assert(knownDynamicRawOutput, "independent dynamic raw fixture failed: " .. tostring(knownDynamicRawTrailing))
AssertEqual(knownDynamicRawOutput, knownDynamicValue, "independent dynamic raw fixture")
AssertEqual(knownDynamicRawTrailing, 0, "independent dynamic raw fixture trailing bytes")
local knownDynamicOutput, knownDynamicTrailing = boundedDeflate.DecompressZlib(knownDynamicZlib, #knownDynamicValue)
assert(knownDynamicOutput, "independent dynamic zlib fixture failed: " .. tostring(knownDynamicTrailing))
AssertEqual(knownDynamicOutput, knownDynamicValue, "independent dynamic zlib fixture")
AssertEqual(knownDynamicTrailing, 0, "independent dynamic zlib fixture trailing bytes")

local badChecksum = zlib:sub(1, -2) .. string.char((zlib:byte(-1) + 1) % 256)
local checksumOutput, checksumError = boundedDeflate.DecompressZlib(badChecksum, 4)
AssertFailure(checksumOutput, checksumError, "checksum-mismatch", "bad zlib checksum")

local badHeader = string.char(120, 0) .. zlib:sub(3)
local headerOutput, headerError = boundedDeflate.DecompressZlib(badHeader, 4)
AssertFailure(headerOutput, headerError, "invalid-zlib-header", "bad zlib header")
local dictionaryHeader = string.char(120, 32) .. zlib:sub(3)
local dictionaryOutput, dictionaryError = boundedDeflate.DecompressZlib(dictionaryHeader, 4)
AssertFailure(dictionaryOutput, dictionaryError, "unsupported-dictionary", "zlib preset dictionary")

local invalidBlockOutput, invalidBlockError = boundedDeflate.DecompressDeflate(string.char(7), 1)
AssertFailure(invalidBlockOutput, invalidBlockError, "invalid-block-type", "reserved block type")

local reservedLengthOutput, reservedLengthError = boundedDeflate.DecompressDeflate(BuildReservedLengthRaw(), 1)
AssertFailure(reservedLengthOutput, reservedLengthError, "invalid-length-code", "reserved fixed length code")

local reservedDistanceOutput, reservedDistanceError =
    boundedDeflate.DecompressDeflate(BuildInvalidFixedDistanceRaw(30), 4)
AssertFailure(reservedDistanceOutput, reservedDistanceError, "invalid-distance-code", "reserved fixed distance code")
local tooFarDistanceOutput, tooFarDistanceError = boundedDeflate.DecompressDeflate(BuildInvalidFixedDistanceRaw(1), 4)
AssertFailure(tooFarDistanceOutput, tooFarDistanceError, "invalid-distance", "distance beyond produced output")

local leadingRepeatOutput, leadingRepeatError = boundedDeflate.DecompressDeflate(BuildLeadingRepeatRaw(), 1)
AssertFailure(leadingRepeatOutput, leadingRepeatError, "invalid-code-length-repeat", "leading code-length repeat")

local missingEndOutput, missingEndError = boundedDeflate.DecompressDeflate(BuildMissingEndCodeRaw(), 1)
AssertFailure(missingEndOutput, missingEndError, "missing-end-code", "dynamic tree without end code")

local invalidStored = storedRaw:sub(1, 3) .. string.char((storedRaw:byte(4) + 1) % 256) .. storedRaw:sub(5)
local invalidStoredOutput, invalidStoredError = boundedDeflate.DecompressDeflate(invalidStored, #storedValue)
AssertFailure(invalidStoredOutput, invalidStoredError, "invalid-stored-length", "stored length complement")

local oversubscribedRaw = BuildInvalidCodeLengthTreeRaw({
    [16] = 1,
    [17] = 1,
    [18] = 1,
})
local oversubscribedOutput, oversubscribedError = boundedDeflate.DecompressDeflate(oversubscribedRaw, 1)
AssertFailure(
    oversubscribedOutput,
    oversubscribedError,
    "oversubscribed-huffman-tree",
    "oversubscribed code-length tree"
)

local incompleteRaw = BuildInvalidCodeLengthTreeRaw({
    [0] = 1,
})
local incompleteOutput, incompleteError = boundedDeflate.DecompressDeflate(incompleteRaw, 1)
AssertFailure(incompleteOutput, incompleteError, "incomplete-huffman-tree", "incomplete code-length tree")

for index = 0, #dynamicRaw - 1 do
    local truncated = dynamicRaw:sub(1, index)
    local ok, value, errorCode = pcall(boundedDeflate.DecompressDeflate, truncated, 4)
    assert(ok, "truncated raw stream must not throw at byte " .. index)
    assert(value == nil and type(errorCode) == "string", "truncated raw stream must fail at byte " .. index)
end

for index = 0, #zlib - 1 do
    local truncated = zlib:sub(1, index)
    local ok, value, errorCode = pcall(boundedDeflate.DecompressZlib, truncated, 4)
    assert(ok, "truncated zlib stream must not throw at byte " .. index)
    assert(value == nil and type(errorCode) == "string", "truncated zlib stream must fail at byte " .. index)
end

for index = 1, #zlib do
    local mutatedByte = (zlib:byte(index) + 1) % 256
    local mutated = zlib:sub(1, index - 1) .. string.char(mutatedByte) .. zlib:sub(index + 1)
    local ok, value, status = pcall(boundedDeflate.DecompressZlib, mutated, 4)
    assert(ok, "mutated zlib stream must not throw at byte " .. index)
    if value ~= nil then
        assert(#value <= 4, "mutated zlib stream must remain output-bounded")
        assert(type(status) == "number" and status >= 0, "mutated success must report trailing bytes")
    else
        assert(type(status) == "string", "mutated failure must report an error code")
    end
end

for _, invalidLimit in ipairs({
    -1,
    0.5,
    math.huge,
    "4",
    {},
}) do
    local value, errorCode = boundedDeflate.DecompressDeflate(emptyRaw, invalidLimit)
    AssertFailure(value, errorCode, "invalid-output-limit", "invalid raw output limit")
    value, errorCode = boundedDeflate.DecompressZlib(zlib, invalidLimit)
    AssertFailure(value, errorCode, "invalid-output-limit", "invalid zlib output limit")
end
local nan = 0 / 0
local nanValue, nanError = boundedDeflate.DecompressDeflate(emptyRaw, nan)
AssertFailure(nanValue, nanError, "invalid-output-limit", "NaN output limit")
local invalidInput, invalidInputError = boundedDeflate.DecompressDeflate({}, 0)
AssertFailure(invalidInput, invalidInputError, "invalid-input", "invalid raw input")
invalidInput, invalidInputError = boundedDeflate.DecompressZlib({}, 0)
AssertFailure(invalidInput, invalidInputError, "invalid-input", "invalid zlib input")

print("Bounded DEFLATE tests passed.")
