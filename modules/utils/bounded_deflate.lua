-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/bounded_deflate.lua
--
-- Small, dependency-free DEFLATE/zlib decoder with a mandatory output bound.
-- The decoder reserves output capacity before literals, repeated matches, and
-- stored blocks so hostile compressed input cannot allocate beyond that bound.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.boundedDeflate = {}
local boundedDeflate = AngryEra.utils.boundedDeflate

local MAX_SAFE_INTEGER = 9007199254740991
local WINDOW_BYTES = 32768
local OUTPUT_CHUNK_BYTES = 8192
local ADLER_MODULUS = 65521

local CODE_LENGTH_ORDER = {
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

local LENGTH_BASE = {
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

local LENGTH_EXTRA = {
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

local DISTANCE_BASE = {
    [0] = 1,
    [1] = 2,
    [2] = 3,
    [3] = 4,
    [4] = 5,
    [5] = 7,
    [6] = 9,
    [7] = 13,
    [8] = 17,
    [9] = 25,
    [10] = 33,
    [11] = 49,
    [12] = 65,
    [13] = 97,
    [14] = 129,
    [15] = 193,
    [16] = 257,
    [17] = 385,
    [18] = 513,
    [19] = 769,
    [20] = 1025,
    [21] = 1537,
    [22] = 2049,
    [23] = 3073,
    [24] = 4097,
    [25] = 6145,
    [26] = 8193,
    [27] = 12289,
    [28] = 16385,
    [29] = 24577,
}

local DISTANCE_EXTRA = {
    [0] = 0,
    [1] = 0,
    [2] = 0,
    [3] = 0,
    [4] = 1,
    [5] = 1,
    [6] = 2,
    [7] = 2,
    [8] = 3,
    [9] = 3,
    [10] = 4,
    [11] = 4,
    [12] = 5,
    [13] = 5,
    [14] = 6,
    [15] = 6,
    [16] = 7,
    [17] = 7,
    [18] = 8,
    [19] = 8,
    [20] = 9,
    [21] = 9,
    [22] = 10,
    [23] = 10,
    [24] = 11,
    [25] = 11,
    [26] = 12,
    [27] = 12,
    [28] = 13,
    [29] = 13,
}

local function IsValidOutputLimit(value)
    return type(value) == "number"
        and value == value
        and value >= 0
        and value <= MAX_SAFE_INTEGER
        and value == math.floor(value)
end

local Reader = {}
Reader.__index = Reader

function Reader:ReadBits(count)
    while self.BitCount < count do
        if self.Position > self.Length then
            return nil, "truncated-input"
        end
        self.BitBuffer = self.BitBuffer + self.Input:byte(self.Position) * (2 ^ self.BitCount)
        self.BitCount = self.BitCount + 8
        self.Position = self.Position + 1
    end

    local divisor = 2 ^ count
    local value = self.BitBuffer % divisor
    self.BitBuffer = (self.BitBuffer - value) / divisor
    self.BitCount = self.BitCount - count
    return value
end

function Reader:AlignToByte()
    local discarded = self.BitCount % 8
    if discarded > 0 then
        local divisor = 2 ^ discarded
        self.BitBuffer = (self.BitBuffer - self.BitBuffer % divisor) / divisor
        self.BitCount = self.BitCount - discarded
    end
end

function Reader:RemainingWholeBytes()
    return self.Length - self.Position + 1 + math.floor(self.BitCount / 8)
end

local function NewReader(input, position)
    return setmetatable({
        BitBuffer = 0,
        BitCount = 0,
        Input = input,
        Length = #input,
        Position = position or 1,
    }, Reader)
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

local function BuildHuffman(lengths, maximumSymbol, maximumBits, options)
    local counts = {}
    local total = 0
    local longest = 0
    for symbol = 0, maximumSymbol do
        local length = lengths[symbol] or 0
        if type(length) ~= "number" or length < 0 or length > maximumBits or length ~= math.floor(length) then
            return nil, "invalid-huffman-length"
        end
        if length > 0 then
            counts[length] = (counts[length] or 0) + 1
            total = total + 1
            if length > longest then
                longest = length
            end
        end
    end

    if total == 0 then
        if options and options.AllowEmpty then
            return {
                Lookup = {},
                Longest = 0,
                Total = 0,
            }
        end
        return nil, "empty-huffman-tree"
    end

    local remaining = 1
    for bits = 1, maximumBits do
        remaining = remaining * 2 - (counts[bits] or 0)
        if remaining < 0 then
            return nil, "oversubscribed-huffman-tree"
        end
    end
    if remaining > 0 and not (options and options.AllowSingle and total == 1 and longest == 1) then
        return nil, "incomplete-huffman-tree"
    end

    local nextCode = {}
    local code = 0
    for bits = 1, maximumBits do
        code = (code + (counts[bits - 1] or 0)) * 2
        nextCode[bits] = code
    end

    local lookup = {}
    for symbol = 0, maximumSymbol do
        local length = lengths[symbol] or 0
        if length > 0 then
            local symbolCode = nextCode[length]
            nextCode[length] = symbolCode + 1
            lookup[length] = lookup[length] or {}
            lookup[length][ReverseBits(symbolCode, length)] = symbol
        end
    end

    return {
        Lookup = lookup,
        Longest = longest,
        Total = total,
    }
end

local function DecodeSymbol(reader, tree)
    if tree.Total == 0 then
        return nil, "invalid-huffman-code"
    end

    local code = 0
    local multiplier = 1
    for length = 1, tree.Longest do
        local bit, bitError = reader:ReadBits(1)
        if bit == nil then
            return nil, bitError
        end
        code = code + bit * multiplier
        local byLength = tree.Lookup[length]
        local symbol = byLength and byLength[code]
        if symbol ~= nil then
            return symbol
        end
        multiplier = multiplier * 2
    end
    return nil, "invalid-huffman-code"
end

local function NewOutput(maximumBytes, windowBytes)
    return {
        Chunks = {},
        MaximumBytes = maximumBytes,
        Pending = {},
        PendingCount = 0,
        Produced = 0,
        Window = {},
        WindowBytes = windowBytes,
    }
end

local function CanAppend(output, count)
    return count <= output.MaximumBytes - output.Produced
end

local function FlushOutput(output)
    if output.PendingCount == 0 then
        return
    end
    output.Chunks[#output.Chunks + 1] = table.concat(output.Pending, "", 1, output.PendingCount)
    output.Pending = {}
    output.PendingCount = 0
end

local function AppendByte(output, value)
    local nextPosition = output.Produced + 1
    output.Produced = nextPosition
    output.Window[(nextPosition - 1) % output.WindowBytes + 1] = value
    output.PendingCount = output.PendingCount + 1
    output.Pending[output.PendingCount] = value
    if output.PendingCount >= OUTPUT_CHUNK_BYTES then
        FlushOutput(output)
    end
end

local function CopyMatch(output, distance, length)
    if distance < 1 or distance > output.WindowBytes or distance > output.Produced then
        return nil, "invalid-distance"
    end
    if not CanAppend(output, length) then
        return nil, "output-too-large"
    end

    for _ = 1, length do
        local sourceIndex = (output.Produced - distance) % output.WindowBytes + 1
        local value = output.Window[sourceIndex]
        if value == nil then
            return nil, "invalid-distance"
        end
        AppendByte(output, value)
    end
    return true
end

local function FinishOutput(output)
    FlushOutput(output)
    return table.concat(output.Chunks)
end

local fixedLiteralTree
local fixedDistanceTree

local function FixedTrees()
    if fixedLiteralTree and fixedDistanceTree then
        return fixedLiteralTree, fixedDistanceTree
    end

    local literalLengths = {}
    for symbol = 0, 143 do
        literalLengths[symbol] = 8
    end
    for symbol = 144, 255 do
        literalLengths[symbol] = 9
    end
    for symbol = 256, 279 do
        literalLengths[symbol] = 7
    end
    for symbol = 280, 287 do
        literalLengths[symbol] = 8
    end

    local distanceLengths = {}
    for symbol = 0, 31 do
        distanceLengths[symbol] = 5
    end

    fixedLiteralTree = assert(BuildHuffman(literalLengths, 287, 15))
    fixedDistanceTree = assert(BuildHuffman(distanceLengths, 31, 15))
    return fixedLiteralTree, fixedDistanceTree
end

local function ReadDynamicTrees(reader)
    local hlitValue, hlitError = reader:ReadBits(5)
    if hlitValue == nil then
        return nil, nil, hlitError
    end
    local hdistValue, hdistError = reader:ReadBits(5)
    if hdistValue == nil then
        return nil, nil, hdistError
    end
    local hclenValue, hclenError = reader:ReadBits(4)
    if hclenValue == nil then
        return nil, nil, hclenError
    end

    local literalCount = hlitValue + 257
    local distanceCount = hdistValue + 1
    local codeLengthCount = hclenValue + 4
    if literalCount > 286 or distanceCount > 32 then
        return nil, nil, "invalid-dynamic-count"
    end

    local codeLengthLengths = {}
    for index = 1, codeLengthCount do
        local length, lengthError = reader:ReadBits(3)
        if length == nil then
            return nil, nil, lengthError
        end
        codeLengthLengths[CODE_LENGTH_ORDER[index]] = length
    end
    local codeLengthTree, codeLengthError = BuildHuffman(codeLengthLengths, 18, 7)
    if not codeLengthTree then
        return nil, nil, codeLengthError
    end

    local combined = {}
    local totalCount = literalCount + distanceCount
    local cursor = 0
    local previous
    while cursor < totalCount do
        local symbol, symbolError = DecodeSymbol(reader, codeLengthTree)
        if symbol == nil then
            return nil, nil, symbolError
        end

        if symbol <= 15 then
            combined[cursor] = symbol
            previous = symbol
            cursor = cursor + 1
        elseif symbol == 16 then
            if previous == nil then
                return nil, nil, "invalid-code-length-repeat"
            end
            local extra, extraError = reader:ReadBits(2)
            if extra == nil then
                return nil, nil, extraError
            end
            local count = extra + 3
            if cursor + count > totalCount then
                return nil, nil, "invalid-code-length-repeat"
            end
            for _ = 1, count do
                combined[cursor] = previous
                cursor = cursor + 1
            end
        elseif symbol == 17 or symbol == 18 then
            local extraBits = symbol == 17 and 3 or 7
            local base = symbol == 17 and 3 or 11
            local extra, extraError = reader:ReadBits(extraBits)
            if extra == nil then
                return nil, nil, extraError
            end
            local count = base + extra
            if cursor + count > totalCount then
                return nil, nil, "invalid-code-length-repeat"
            end
            for _ = 1, count do
                combined[cursor] = 0
                cursor = cursor + 1
            end
            previous = 0
        else
            return nil, nil, "invalid-code-length-repeat"
        end
    end

    local literalLengths = {}
    for symbol = 0, literalCount - 1 do
        literalLengths[symbol] = combined[symbol] or 0
    end
    if (literalLengths[256] or 0) == 0 then
        return nil, nil, "missing-end-code"
    end

    local distanceLengths = {}
    for symbol = 0, distanceCount - 1 do
        distanceLengths[symbol] = combined[literalCount + symbol] or 0
    end

    local literalTree, literalError = BuildHuffman(literalLengths, literalCount - 1, 15, { AllowSingle = true })
    if not literalTree then
        return nil, nil, literalError
    end
    local distanceTree, distanceError = BuildHuffman(distanceLengths, distanceCount - 1, 15, {
        AllowEmpty = true,
        AllowSingle = true,
    })
    if not distanceTree then
        return nil, nil, distanceError
    end
    return literalTree, distanceTree
end

local function DecodeCompressedBlock(reader, output, literalTree, distanceTree)
    while true do
        local symbol, symbolError = DecodeSymbol(reader, literalTree)
        if symbol == nil then
            return nil, symbolError
        end

        if symbol < 256 then
            if not CanAppend(output, 1) then
                return nil, "output-too-large"
            end
            AppendByte(output, string.char(symbol))
        elseif symbol == 256 then
            return true
        elseif symbol >= 257 and symbol <= 285 then
            local extraLengthBits = LENGTH_EXTRA[symbol]
            local extraLength = 0
            if extraLengthBits > 0 then
                local extra, extraError = reader:ReadBits(extraLengthBits)
                if extra == nil then
                    return nil, extraError
                end
                extraLength = extra
            end
            local length = LENGTH_BASE[symbol] + extraLength

            local distanceSymbol, distanceSymbolError = DecodeSymbol(reader, distanceTree)
            if distanceSymbol == nil then
                return nil, distanceSymbolError
            end
            if distanceSymbol > 29 then
                return nil, "invalid-distance-code"
            end
            local extraDistanceBits = DISTANCE_EXTRA[distanceSymbol]
            local extraDistance = 0
            if extraDistanceBits > 0 then
                local extra, extraError = reader:ReadBits(extraDistanceBits)
                if extra == nil then
                    return nil, extraError
                end
                extraDistance = extra
            end
            local distance = DISTANCE_BASE[distanceSymbol] + extraDistance
            local copied, copyError = CopyMatch(output, distance, length)
            if not copied then
                return nil, copyError
            end
        else
            return nil, "invalid-length-code"
        end
    end
end

local function DecodeStoredBlock(reader, output)
    reader:AlignToByte()
    local length, lengthError = reader:ReadBits(16)
    if length == nil then
        return nil, lengthError
    end
    local complement, complementError = reader:ReadBits(16)
    if complement == nil then
        return nil, complementError
    end
    if (length + complement) % 65536 ~= 65535 then
        return nil, "invalid-stored-length"
    end
    if reader:RemainingWholeBytes() < length then
        return nil, "truncated-input"
    end
    if not CanAppend(output, length) then
        return nil, "output-too-large"
    end

    for _ = 1, length do
        local value, valueError = reader:ReadBits(8)
        if value == nil then
            return nil, valueError
        end
        AppendByte(output, string.char(value))
    end
    return true
end

local function Inflate(input, maximumOutputBytes, startPosition, windowBytes)
    local reader = NewReader(input, startPosition)
    local output = NewOutput(maximumOutputBytes, windowBytes)
    local finalBlock = false

    while not finalBlock do
        local finalValue, finalError = reader:ReadBits(1)
        if finalValue == nil then
            return nil, nil, finalError
        end
        finalBlock = finalValue == 1

        local blockType, blockTypeError = reader:ReadBits(2)
        if blockType == nil then
            return nil, nil, blockTypeError
        end

        local decoded
        local decodeError
        if blockType == 0 then
            decoded, decodeError = DecodeStoredBlock(reader, output)
        elseif blockType == 1 then
            local literalTree, distanceTree = FixedTrees()
            decoded, decodeError = DecodeCompressedBlock(reader, output, literalTree, distanceTree)
        elseif blockType == 2 then
            local literalTree
            local distanceTree
            literalTree, distanceTree, decodeError = ReadDynamicTrees(reader)
            if literalTree then
                decoded, decodeError = DecodeCompressedBlock(reader, output, literalTree, distanceTree)
            end
        else
            return nil, nil, "invalid-block-type"
        end

        if not decoded then
            return nil, nil, decodeError
        end
    end

    reader:AlignToByte()
    return FinishOutput(output), reader.Position
end

local function Adler32(value)
    local first = 1
    local second = 0
    local processed = 0
    for index = 1, #value do
        first = first + value:byte(index)
        second = second + first
        processed = processed + 1
        if processed == 5552 then
            first = first % ADLER_MODULUS
            second = second % ADLER_MODULUS
            processed = 0
        end
    end
    first = first % ADLER_MODULUS
    second = second % ADLER_MODULUS
    return second * 65536 + first
end

--- Decompresses one raw DEFLATE stream without exceeding an output budget.
-- The second successful return is the number of whole input bytes following
-- the final DEFLATE block. Malformed or oversized input returns an error code.
-- @tparam string input Raw DEFLATE bytes.
-- @tparam number maximumOutputBytes Non-negative integer output ceiling.
-- @treturn string|nil output
-- @treturn number|string trailingBytesOrError
function boundedDeflate.DecompressDeflate(input, maximumOutputBytes)
    if type(input) ~= "string" then
        return nil, "invalid-input"
    end
    if not IsValidOutputLimit(maximumOutputBytes) then
        return nil, "invalid-output-limit"
    end

    local output, nextPosition, inflateError = Inflate(input, maximumOutputBytes, 1, WINDOW_BYTES)
    if output == nil then
        return nil, inflateError
    end
    return output, #input - nextPosition + 1
end

--- Decompresses one zlib-wrapped DEFLATE stream within an output budget.
-- CM/FLG, optional-dictionary rejection, DEFLATE structure, and Adler-32 are
-- validated. The second successful return counts bytes after the checksum.
-- @tparam string input Zlib stream bytes.
-- @tparam number maximumOutputBytes Non-negative integer output ceiling.
-- @treturn string|nil output
-- @treturn number|string trailingBytesOrError
function boundedDeflate.DecompressZlib(input, maximumOutputBytes)
    if type(input) ~= "string" then
        return nil, "invalid-input"
    end
    if not IsValidOutputLimit(maximumOutputBytes) then
        return nil, "invalid-output-limit"
    end
    if #input < 2 then
        return nil, "truncated-input"
    end

    local compression = input:byte(1)
    local flags = input:byte(2)
    if compression % 16 ~= 8 or math.floor(compression / 16) > 7 then
        return nil, "invalid-zlib-header"
    end
    if (compression * 256 + flags) % 31 ~= 0 then
        return nil, "invalid-zlib-header"
    end
    if math.floor(flags / 32) % 2 == 1 then
        return nil, "unsupported-dictionary"
    end

    local windowBytes = 2 ^ (math.floor(compression / 16) + 8)
    local output, checksumPosition, inflateError = Inflate(input, maximumOutputBytes, 3, windowBytes)
    if output == nil then
        return nil, inflateError
    end
    if checksumPosition + 3 > #input then
        return nil, "truncated-input"
    end

    local expected = input:byte(checksumPosition) * 16777216
        + input:byte(checksumPosition + 1) * 65536
        + input:byte(checksumPosition + 2) * 256
        + input:byte(checksumPosition + 3)
    if Adler32(output) ~= expected then
        return nil, "checksum-mismatch"
    end
    return output, #input - checksumPosition - 3
end
