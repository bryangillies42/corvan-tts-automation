-- Corvan Combat Console - stable Tabletop Simulator bootstrap.
-- This file deliberately contains no character rules. The replaceable runtime lives
-- on an invisible helper so this visible panel never needs to be reloaded to update.

local BOOTSTRAP_VERSION = "1.0.2"
local STATE_SCHEMA_VERSION = 1
local MANIFEST_SCHEMA_VERSION = 1
local SEED_RUNTIME_VERSION = "0.1.7"
local SEED_UI = __SEED_UI_LITERAL__
local SEED_RUNTIME = __SEED_RUNTIME_LITERAL__

local RELEASE_API_URL = "https://api.github.com/repos/bryangillies42/corvan-tts-automation/releases/latest"
local TRUSTED_RUNTIME_PREFIX = "https://github.com/bryangillies42/corvan-tts-automation/releases/download/"
local RUNTIME_MARKER = "CORVAN_RUNTIME"
local MAX_RUNTIME_BYTES = 1572864
local HELPER_PROBE_INTERVAL = 0.25
local HELPER_HEALTH_TIMEOUT = 10
local WEB_REQUEST_TIMEOUT = 20

local PLAYER_COLORS = {
    "White", "Brown", "Red", "Orange", "Yellow", "Green", "Teal",
    "Blue", "Purple", "Pink", "Grey", "Black"
}

local UI_ATTRIBUTES = {
    active = true,
    colors = true,
    interactable = true,
    isOn = true,
    text = true,
}

local state = nil
local helperSpawnPending = false
local startupSerial = 0
local startupInstallAttempts = 0
local runtimeReadyPayload = nil
local uiReady = false
local uiLoadSerial = 0
local uiIds = {}
local uiAttributeValues = {}
local uiFallbackVisible = false
local pendingRefreshText = ""
local pendingRefreshBusy = false
local update = {
    active = false,
    serial = 0,
    playerColor = nil,
    phase = nil,
    snapshot = nil,
    candidate = nil,
    pendingUiXml = nil,
}

local ensureHelper
local beginStableRuntimeInstall
local beginReloadProbe
local rollbackUpdate

local function defaultState()
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        bootstrapVersion = BOOTSTRAP_VERSION,
        helperGuid = nil,
        releaseEtag = nil,
        runtimeVersion = SEED_RUNTIME_VERSION,
        runtimeCommitSha = nil,
        runtimeSource = SEED_RUNTIME,
        runtimeState = nil,
        uiXml = SEED_UI,
    }
end

local function shallowCopy(source)
    local copy = {}
    if type(source) == "table" then
        for key, value in pairs(source) do
            copy[key] = value
        end
    end
    return copy
end

local SHA256_CONSTANTS = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function uint32Bytes(value)
    return string.char(
        math.floor(value / 0x1000000) % 0x100,
        math.floor(value / 0x10000) % 0x100,
        math.floor(value / 0x100) % 0x100,
        value % 0x100
    )
end

-- MoonSharp exposes bit32, but some TTS builds coerce bit32 arguments through a
-- signed host integer. Keep every bit32 operand within 16 bits and reassemble the
-- unsigned 32-bit word in Lua's exactly-represented number range.
local function wordParts(value)
    local normalized = value % 0x100000000
    return math.floor(normalized / 0x10000), normalized % 0x10000
end

local function wordBand(left, right)
    local leftHigh, leftLow = wordParts(left)
    local rightHigh, rightLow = wordParts(right)
    return (bit32.band(leftHigh, rightHigh) * 0x10000) + bit32.band(leftLow, rightLow)
end

local function wordXor(left, right, third)
    local leftHigh, leftLow = wordParts(left)
    local rightHigh, rightLow = wordParts(right)
    local result = (bit32.bxor(leftHigh, rightHigh) * 0x10000) + bit32.bxor(leftLow, rightLow)
    if third ~= nil then
        return wordXor(result, third)
    end
    return result
end

local function wordNot(value)
    local high, low = wordParts(value)
    return (bit32.bxor(high, 0xffff) * 0x10000) + bit32.bxor(low, 0xffff)
end

local function wordRshift(value, amount)
    return math.floor((value % 0x100000000) / (2 ^ amount))
end

local function wordRrotate(value, amount)
    local normalized = value % 0x100000000
    local divisor = 2 ^ amount
    return math.floor(normalized / divisor) + ((normalized % divisor) * (2 ^ (32 - amount)))
end

local function uint32Hex(value)
    local alphabet = "0123456789abcdef"
    local output = {}
    for shift = 28, 0, -4 do
        local nibble = math.floor(value / (2 ^ shift)) % 0x10
        output[#output + 1] = string.sub(alphabet, nibble + 1, nibble + 1)
    end
    return table.concat(output)
end

local function codepointUtf8(codepoint)
    if codepoint <= 0x7f then
        return string.char(codepoint)
    elseif codepoint <= 0x7ff then
        return string.char(
            0xc0 + math.floor(codepoint / 0x40),
            0x80 + (codepoint % 0x40)
        )
    elseif codepoint <= 0xffff then
        return string.char(
            0xe0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return string.char(
        0xf0 + math.floor(codepoint / 0x40000),
        0x80 + (math.floor(codepoint / 0x1000) % 0x40),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

local function utf8BytesSlice(input, startIndex, characterLimit)
    local output = {}
    local inputLength = #input
    local index = startIndex
    local processed = 0
    while index <= inputLength and processed < characterLimit do
        local codepoint = string.byte(input, index, index)
        -- MoonSharp's string.byte maps non-Latin-1 characters to '?'. Only pay
        -- for string.unicode when the byte is ambiguous or genuinely non-ASCII.
        if codepoint == 0x3f or codepoint >= 0x80 then
            codepoint = string.unicode(input, index, index)
        end
        if codepoint >= 0xd800 and codepoint <= 0xdbff and index < inputLength then
            local lowSurrogate = string.unicode(input, index + 1, index + 1)
            if lowSurrogate >= 0xdc00 and lowSurrogate <= 0xdfff then
                codepoint = 0x10000 + ((codepoint - 0xd800) * 0x400) + (lowSurrogate - 0xdc00)
                index = index + 1
            else
                codepoint = 0xfffd
            end
        elseif codepoint >= 0xd800 and codepoint <= 0xdfff then
            codepoint = 0xfffd
        end
        output[#output + 1] = codepointUtf8(codepoint)
        index = index + 1
        processed = processed + 1
    end
    return table.concat(output), index
end

local function utf8Bytes(input)
    if type(input) ~= "string" or type(string.unicode) ~= "function" then
        return nil, "codificação UTF-8 indisponível neste host"
    end
    local output = {}
    local index = 1
    while index <= #input do
        local chunk = nil
        chunk, index = utf8BytesSlice(input, index, 2048)
        output[#output + 1] = chunk
    end
    return table.concat(output), nil
end

local function sha256Message(bytes)
    local bitLength = #bytes * 8
    local highLength = math.floor(bitLength / 0x100000000)
    local lowLength = bitLength % 0x100000000
    local zeroPaddingLength = (56 - ((#bytes + 1) % 64)) % 64
    return bytes
        .. string.char(0x80)
        .. string.rep(string.char(0), zeroPaddingLength)
        .. uint32Bytes(highLength)
        .. uint32Bytes(lowLength)
end

local function sha256InitialHash()
    return {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }
end

local function sha256ProcessBlock(message, chunkStart, hash, words)
    for index = 0, 15 do
        local offset = chunkStart + (index * 4)
        local first, second, third, fourth = string.byte(message, offset, offset + 3)
        words[index] = (first * 0x1000000) + (second * 0x10000) + (third * 0x100) + fourth
    end
    for index = 16, 63 do
        local previous15 = words[index - 15]
        local previous2 = words[index - 2]
        local sigma0 = wordXor(
            wordRrotate(previous15, 7),
            wordRrotate(previous15, 18),
            wordRshift(previous15, 3)
        )
        local sigma1 = wordXor(
            wordRrotate(previous2, 17),
            wordRrotate(previous2, 19),
            wordRshift(previous2, 10)
        )
        words[index] = (words[index - 16] + sigma0 + words[index - 7] + sigma1) % 0x100000000
    end

    local a, b, c, d = hash[1], hash[2], hash[3], hash[4]
    local e, f, g, h = hash[5], hash[6], hash[7], hash[8]
    for index = 0, 63 do
        local upperSigma1 = wordXor(
            wordRrotate(e, 6),
            wordRrotate(e, 11),
            wordRrotate(e, 25)
        )
        local choose = wordXor(wordBand(e, f), wordBand(wordNot(e), g))
        local temporary1 = (h + upperSigma1 + choose + SHA256_CONSTANTS[index + 1] + words[index]) % 0x100000000
        local upperSigma0 = wordXor(
            wordRrotate(a, 2),
            wordRrotate(a, 13),
            wordRrotate(a, 22)
        )
        local majority = wordXor(wordBand(a, b), wordBand(a, c), wordBand(b, c))
        local temporary2 = (upperSigma0 + majority) % 0x100000000

        h = g
        g = f
        f = e
        e = (d + temporary1) % 0x100000000
        d = c
        c = b
        b = a
        a = (temporary1 + temporary2) % 0x100000000
    end

    hash[1] = (hash[1] + a) % 0x100000000
    hash[2] = (hash[2] + b) % 0x100000000
    hash[3] = (hash[3] + c) % 0x100000000
    hash[4] = (hash[4] + d) % 0x100000000
    hash[5] = (hash[5] + e) % 0x100000000
    hash[6] = (hash[6] + f) % 0x100000000
    hash[7] = (hash[7] + g) % 0x100000000
    hash[8] = (hash[8] + h) % 0x100000000
end

local function sha256Digest(hash)
    local digest = {}
    for index = 1, 8 do
        digest[index] = uint32Hex(hash[index])
    end
    return table.concat(digest)
end

local function sha256Hex(input, encodedInput)
    if type(input) ~= "string"
        or type(bit32) ~= "table"
        or type(bit32.band) ~= "function"
        or type(bit32.bxor) ~= "function"
    then
        return nil, "SHA-256 indisponível neste host"
    end
    local bytes = encodedInput
    if type(bytes) ~= "string" then
        local encodingError = nil
        bytes, encodingError = utf8Bytes(input)
        if bytes == nil then
            return nil, encodingError
        end
    end
    local message = sha256Message(bytes)
    local hash = sha256InitialHash()
    local words = {}
    for chunkStart = 1, #message, 64 do
        sha256ProcessBlock(message, chunkStart, hash, words)
    end
    return sha256Digest(hash), nil
end

local function safeDecode(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local ok, decoded = pcall(JSON.decode, text)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

local function safeEncode(value)
    local ok, encoded = pcall(JSON.encode, value)
    if ok and type(encoded) == "string" then
        return encoded
    end
    return ""
end

local function runtimeSourceIsValid(source)
    return type(source) == "string"
        and #source > 0
        and #source <= MAX_RUNTIME_BYTES
        and string.find(source, RUNTIME_MARKER, 1, true) ~= nil
end

local function sanitizePersistedState(decoded)
    local clean = defaultState()
    if type(decoded) ~= "table" then
        return clean
    end

    if type(decoded.helperGuid) == "string" and decoded.helperGuid ~= "" then
        clean.helperGuid = decoded.helperGuid
    end
    local persistedRuntimeIsValid = runtimeSourceIsValid(decoded.runtimeSource)
        and type(decoded.runtimeVersion) == "string"
        and string.match(decoded.runtimeVersion, "^%d+%.%d+%.%d+$") ~= nil
    if persistedRuntimeIsValid then
        clean.runtimeSource = decoded.runtimeSource
        clean.runtimeVersion = decoded.runtimeVersion
        if type(decoded.runtimeCommitSha) == "string"
            and #decoded.runtimeCommitSha >= 7
            and #decoded.runtimeCommitSha <= 40
            and string.match(decoded.runtimeCommitSha, "^[0-9a-fA-F]+$")
        then
            clean.runtimeCommitSha = decoded.runtimeCommitSha
        end
        if type(decoded.releaseEtag) == "string" and decoded.releaseEtag ~= "" then
            clean.releaseEtag = decoded.releaseEtag
        end
    end
    if type(decoded.runtimeState) == "table" then
        clean.runtimeState = decoded.runtimeState
    end
    if type(decoded.uiXml) == "string" then
        clean.uiXml = decoded.uiXml
    end
    return clean
end

local function playerColorOf(player)
    if type(player) == "string" and player ~= "" then
        return player
    end
    if type(player) == "table" or type(player) == "userdata" then
        local ok, color = pcall(function()
            return player.color
        end)
        if ok and type(color) == "string" and color ~= "" then
            return color
        end
    end
    return "Black"
end

local function tell(playerColor, message, tint)
    local color = playerColorOf(playerColor)
    pcall(printToColor, "Corvan • " .. message, color, tint or {0.80, 0.68, 0.38})
end

-- O helper invisível delega o chat ao objeto visível. Em algumas sessões do
-- TTS, as APIs de chat aceitam chamadas feitas pelo helper sem exibir a linha;
-- uma única chamada global feita pelo bootstrap evita confirmações individuais
-- enganosas e garante exatamente uma entrada por resultado para cada cliente.
function relayRuntimeChat(payload)
    if type(payload) ~= "table" or type(payload.message) ~= "string" or payload.message == "" then
        return false
    end
    local tint = {0.905, 0.898, 0.172}
    if type(printToAll) == "function" then
        return pcall(printToAll, payload.message, tint)
    end
    return false
end

function relayRuntimePrivate(payload)
    if type(payload) ~= "table" or type(payload.message) ~= "string" then return false end
    local color = playerColorOf(payload.playerColor)
    if color == "Black" then return false end
    return pcall(printToColor, payload.message, color, {1.0, 0.38, 0.30})
end

local function collectUiIds(xml)
    local ids = {}
    for id in string.gmatch(xml, "id%s*=%s*\"([^\"]+)\"") do
        ids[id] = true
    end
    for id in string.gmatch(xml, "id%s*=%s*'([^']+)'") do
        ids[id] = true
    end
    return ids
end

local function clearUiFallback()
    if not uiFallbackVisible then
        return
    end
    pcall(function()
        self.clearButtons()
    end)
    uiFallbackVisible = false
end

local function showUiFallback(reason)
    if uiFallbackVisible then
        return
    end
    local created = pcall(function()
        self.createButton({
            click_function = "recoverUi",
            function_owner = self,
            label = "CARREGAR PAINEL",
            position = {0, 0.4, 0},
            rotation = {0, 0, 0},
            scale = {0.7, 0.7, 0.7},
            width = 1200,
            height = 320,
            font_size = 110,
            color = {0.10, 0.12, 0.14, 0.98},
            font_color = {0.90, 0.72, 0.34, 1},
            hover_color = {0.18, 0.22, 0.25, 1},
            press_color = {0.30, 0.22, 0.10, 1},
            tooltip = "Recarregar a interface do Console do Corvan",
        })
    end)
    if created then
        uiFallbackVisible = true
    end
    log("Corvan bootstrap: " .. tostring(reason) .. " Use o botão CARREGAR PAINEL.")
end

local function installedUiMatches(xml)
    local ok, installed = pcall(function()
        return self.UI.getXml()
    end)
    if not ok or type(installed) ~= "string" or installed == "" then
        return false
    end
    for id in pairs(collectUiIds(xml)) do
        if string.find(installed, 'id="' .. id .. '"', 1, true) == nil
            and string.find(installed, "id='" .. id .. "'", 1, true) == nil
        then
            return false
        end
    end
    return true
end

local function applyUiAttribute(id, attribute, value)
    if not uiReady or uiIds[id] ~= true then
        return false
    end
    local loadingOk, loading = pcall(function()
        return self.UI.loading
    end)
    if loadingOk and loading == true then
        return false
    end
    local ok = pcall(function()
        self.UI.setAttribute(id, attribute, tostring(value))
    end)
    return ok
end

local function setUiAttribute(id, attribute, value)
    if type(id) ~= "string" or UI_ATTRIBUTES[attribute] ~= true then
        return false
    end
    uiAttributeValues[id] = uiAttributeValues[id] or {}
    uiAttributeValues[id][attribute] = tostring(value)
    return applyUiAttribute(id, attribute, value)
end

local function setRefreshFeedback(text, busy)
    pendingRefreshText = text or ""
    pendingRefreshBusy = busy == true
    setUiAttribute(
        "refreshStatus",
        "text",
        pendingRefreshText == "" and "ATUALIZAÇÃO  •  pronta" or ("ATUALIZAÇÃO  •  " .. pendingRefreshText)
    )
    setUiAttribute("refresh", "interactable", pendingRefreshBusy and "false" or "true")
end

local function installUiXml(xml)
    if type(xml) ~= "string" or xml == "" then
        return false
    end

    local nextUiIds = collectUiIds(xml)
    if nextUiIds.refresh == nil or nextUiIds.refreshStatus == nil then
        log("Corvan bootstrap: interface recusada por não declarar os controles estáveis.")
        return false
    end

    local previousUiIds = uiIds
    local previousUiReady = uiReady
    uiReady = false
    uiLoadSerial = uiLoadSerial + 1
    local serial = uiLoadSerial
    local installed = pcall(function()
        self.UI.setXml(xml)
    end)
    if not installed then
        uiIds = previousUiIds
        uiReady = previousUiReady
        return false
    end
    uiIds = nextUiIds

    local function finishLoading()
        if serial ~= uiLoadSerial then
            return
        end
        if not installedUiMatches(xml) then
            uiReady = false
            showUiFallback("a interface carregada não corresponde ao XML esperado.")
            return
        end
        uiReady = true
        clearUiFallback()
        for id, attributes in pairs(uiAttributeValues) do
            for attribute, value in pairs(attributes) do
                applyUiAttribute(id, attribute, value)
            end
        end
        setRefreshFeedback(pendingRefreshText, pendingRefreshBusy)
    end

    local function hasFinishedLoading()
        local ok, loading = pcall(function()
            return self.UI.loading
        end)
        return ok and loading == false
    end

    -- Wait é um proxy do host no TTS, não uma table Lua. Uma checagem rígida de
    -- tipo desativa justamente o caminho real do jogo.
    local scheduled = pcall(function()
        -- setXml agenda o carregamento para um frame posterior. Consultar
        -- UI.loading no mesmo frame pode devolver false para a UI antiga e
        -- validar XML obsoleto. Dois frames cobrem tanto o início quanto um
        -- carregamento que já tenha terminado.
        Wait.frames(function()
            Wait.condition(finishLoading, hasFinishedLoading, 5, function()
                showUiFallback("a interface não terminou de carregar.")
            end)
        end, 2)
    end)
    if not scheduled then
        showUiFallback("não foi possível aguardar o carregamento da interface.")
    end
    return true
end

local function isCurrentUpdate(serial)
    return update.active and update.serial == serial
end

local function verifyRuntimeIntegrityAsync(serial, source, expectedSize, expectedSha256, callback)
    if type(source) ~= "string"
        or type(string.unicode) ~= "function"
        or type(bit32) ~= "table"
        or type(bit32.band) ~= "function"
        or type(bit32.bxor) ~= "function"
    then
        callback(false, "SHA-256 indisponível neste host")
        return
    end

    local job = {
        phase = "encode",
        source = source,
        sourceIndex = 1,
        encodedChunks = {},
        encodedLength = 0,
        frames = 0,
        message = nil,
        hash = nil,
        words = nil,
        blockStart = 1,
        finished = false,
    }
    local runStep = nil

    local function finish(ok, reason)
        if job.finished then
            return
        end
        job.finished = true
        if isCurrentUpdate(serial) then
            callback(ok, reason)
        end
    end

    local function schedule()
        Wait.frames(function()
            if job.finished or not isCurrentUpdate(serial) then
                return
            end
            local ok, errorMessage = pcall(runStep)
            if not ok then
                finish(false, "falha ao calcular SHA-256: " .. tostring(errorMessage))
            end
        end, 1)
    end

    runStep = function()
        job.frames = job.frames + 1
        if job.frames > 3600 then
            finish(false, "timeout ao calcular SHA-256")
            return
        end

        if job.phase == "encode" then
            local encodedChunk = nil
            encodedChunk, job.sourceIndex = utf8BytesSlice(job.source, job.sourceIndex, 512)
            job.encodedChunks[#job.encodedChunks + 1] = encodedChunk
            job.encodedLength = job.encodedLength + #encodedChunk
            if job.sourceIndex <= #job.source then
                schedule()
                return
            end
            if job.encodedLength ~= expectedSize then
                finish(false, "runtime veio com tamanho diferente")
                return
            end
            local encodedSource = table.concat(job.encodedChunks)
            job.source = nil
            job.encodedChunks = nil
            job.message = sha256Message(encodedSource)
            job.hash = sha256InitialHash()
            job.words = {}
            job.phase = "hash"
            schedule()
            return
        end

        local processed = 0
        while job.blockStart <= #job.message and processed < 4 do
            sha256ProcessBlock(job.message, job.blockStart, job.hash, job.words)
            job.blockStart = job.blockStart + 64
            processed = processed + 1
        end
        if job.blockStart <= #job.message then
            schedule()
            return
        end
        local actualSha256 = sha256Digest(job.hash)
        if string.lower(actualSha256) ~= string.lower(expectedSha256) then
            finish(false, "SHA-256 do runtime não confere")
            return
        end
        finish(true, nil)
    end

    schedule()
end

local function finishUpdate(serial, message, isError)
    if not isCurrentUpdate(serial) then
        return
    end
    local playerColor = update.playerColor
    update.active = false
    update.phase = nil
    update.snapshot = nil
    update.candidate = nil
    update.pendingUiXml = nil
    setRefreshFeedback(isError and "Falha ao atualizar" or "Atualizado", false)
    tell(playerColor, message, isError and {1.0, 0.38, 0.30} or {0.42, 0.85, 0.48})
    Wait.time(function()
        if not update.active then
            setRefreshFeedback("", false)
        end
    end, 3)
end

local function safeObjectCall(object, functionName, parameters)
    if object == nil then
        return false, nil
    end
    local ok, result = pcall(function()
        return object.call(functionName, parameters)
    end)
    return ok, result
end

local function helperNotes(helper)
    if helper == nil then
        return nil
    end
    local ok, notes = pcall(function()
        return helper.getGMNotes()
    end)
    if not ok then
        return nil
    end
    return safeDecode(notes)
end

local function ownsHelper(helper)
    local notes = helperNotes(helper)
    return notes ~= nil and notes.parentGuid == self.getGUID()
end

local function helperFromState()
    if state == nil or type(state.helperGuid) ~= "string" then
        return nil
    end
    local helper = getObjectFromGUID(state.helperGuid)
    if helper ~= nil and ownsHelper(helper) then
        return helper
    end
    return nil
end

local function findOwnedHelper()
    local current = helperFromState()
    if current ~= nil then
        return current
    end
    local objects = getAllObjects()
    for _, object in ipairs(objects) do
        if object ~= self and ownsHelper(object) then
            return object
        end
    end
    return nil
end

local function helperPosition()
    local ok, position = pcall(function()
        return self.positionToWorld({0, -2.5, 0})
    end)
    if ok and position ~= nil then
        return position
    end
    local ownPosition = self.getPosition()
    return {ownPosition.x or ownPosition[1], (ownPosition.y or ownPosition[2]) - 2.5, ownPosition.z or ownPosition[3]}
end

local function configureHelper(helper)
    if helper == nil then
        return
    end
    pcall(function()
        helper.setGMNotes(safeEncode({parentGuid = self.getGUID()}))
        helper.setName("Corvan Runtime Helper [" .. self.getGUID() .. "]")
        helper.setDescription("Gerenciado automaticamente pelo Console de Combate do Corvan.")
        helper.setLock(true)
        helper.setInvisibleTo(PLAYER_COLORS)
        helper.interactable = false
        helper.drag_selectable = false
        helper.tooltip = false
    end)
    state.helperGuid = helper.getGUID()
end

local function healthIsValid(health, expectedVersion)
    if health == true then
        return expectedVersion == nil
    end
    if type(health) ~= "table" or health.ok ~= true then
        return false
    end
    if health.parentGuid ~= nil and health.parentGuid ~= self.getGUID() then
        return false
    end
    if expectedVersion ~= nil and health.version ~= expectedVersion then
        return false
    end
    return true
end

local function registerHelper(helper, runtimeState)
    configureHelper(helper)
    local payload = {parentGuid = self.getGUID()}
    if type(runtimeState) == "table" then
        -- A freshly spawned/reloaded helper starts from its own default state and
        -- may report that state back immediately. Seed it atomically while binding
        -- the parent so a copied panel cannot lose its persisted resources/effects.
        payload.state = runtimeState
    end
    safeObjectCall(helper, "registerParent", payload)
end

local function restoreRuntimeState(helper, runtimeState)
    if type(runtimeState) ~= "table" then
        return true
    end
    local ok, result = safeObjectCall(helper, "importState", runtimeState)
    if not ok or result == false then
        return false
    end
    return true
end

local function cacheExportedState(helper)
    local ok, exported = safeObjectCall(helper, "exportState", {})
    if ok and type(exported) == "table" then
        state.runtimeState = exported
        return exported
    end
    return nil
end

local function acceptStableHelper(helper, expectedVersion, runtimeState)
    registerHelper(helper, runtimeState)
    if not restoreRuntimeState(helper, runtimeState) then
        return false
    end
    startupInstallAttempts = 0
    local exported = cacheExportedState(helper)
    if exported == nil and type(runtimeState) == "table" then
        state.runtimeState = runtimeState
    end
    if expectedVersion ~= nil then
        state.runtimeVersion = expectedVersion
    end
    return true
end

local function probeExistingHelper(helperGuid, serial, attemptsRemaining, runtimeStateToRestore)
    if serial ~= startupSerial or update.active then
        return
    end
    local helper = getObjectFromGUID(helperGuid)
    if helper == nil or not ownsHelper(helper) then
        ensureHelper(runtimeStateToRestore)
        return
    end
    registerHelper(helper, runtimeStateToRestore)
    local ok, health = safeObjectCall(helper, "healthCheck", {})
    if ok and healthIsValid(health, state.runtimeVersion) then
        acceptStableHelper(helper, state.runtimeVersion, runtimeStateToRestore)
        return
    end
    if attemptsRemaining > 0 then
        Wait.time(function()
            probeExistingHelper(helperGuid, serial, attemptsRemaining - 1, runtimeStateToRestore)
        end, HELPER_PROBE_INTERVAL)
        return
    end
    beginStableRuntimeInstall(helper, runtimeStateToRestore)
end

beginStableRuntimeInstall = function(helper, runtimeStateToRestore)
    if update.active or helper == nil then
        return
    end
    local source = state.runtimeSource
    if not runtimeSourceIsValid(source) then
        source = SEED_RUNTIME
        state.runtimeSource = source
        state.runtimeVersion = SEED_RUNTIME_VERSION
        state.runtimeCommitSha = nil
    end
    if startupInstallAttempts >= 1 and source ~= SEED_RUNTIME then
        source = SEED_RUNTIME
        state.runtimeSource = SEED_RUNTIME
        state.runtimeVersion = SEED_RUNTIME_VERSION
        state.runtimeCommitSha = nil
    elseif startupInstallAttempts >= 2 then
        log("Corvan bootstrap: runtime seed falhou no health check; recuperação automática interrompida.")
        return
    end
    startupInstallAttempts = startupInstallAttempts + 1
    local desiredRuntimeState = runtimeStateToRestore
    if desiredRuntimeState == nil then
        desiredRuntimeState = state.runtimeState
    end
    registerHelper(helper, desiredRuntimeState)
    local ok, reloaded = pcall(function()
        helper.setLuaScript(source)
        return helper.reload()
    end)
    if not ok then
        log("Corvan bootstrap: não foi possível instalar o runtime estável.")
        return
    end
    if reloaded ~= nil then
        state.helperGuid = reloaded.getGUID()
    end
    startupSerial = startupSerial + 1
    local serial = startupSerial
    Wait.time(function()
        probeExistingHelper(
            state.helperGuid,
            serial,
            math.floor(HELPER_HEALTH_TIMEOUT / HELPER_PROBE_INTERVAL),
            desiredRuntimeState
        )
    end, HELPER_PROBE_INTERVAL)
end

local function spawnHelper(runtimeStateToRestore)
    if helperSpawnPending then
        return
    end
    helperSpawnPending = true
    spawnObject({
        type = "ScriptingTrigger",
        position = helperPosition(),
        rotation = {0, 0, 0},
        scale = {0.05, 0.05, 0.05},
        sound = false,
        snap_to_grid = false,
        callback_function = function(helper)
            helperSpawnPending = false
            if helper == nil then
                log("Corvan bootstrap: falha ao criar helper.")
                return
            end
            configureHelper(helper)
            beginStableRuntimeInstall(helper, runtimeStateToRestore)
        end,
    })
end

ensureHelper = function(runtimeStateToRestore)
    if runtimeStateToRestore == nil then
        runtimeStateToRestore = state.runtimeState
    end
    local helper = findOwnedHelper()
    if helper == nil then
        -- A copied panel still contains the original helper GUID in its saved state.
        -- Ownership notes prevent it from ever taking over that helper.
        state.helperGuid = nil
        spawnHelper(runtimeStateToRestore)
        return nil
    end
    configureHelper(helper)
    startupSerial = startupSerial + 1
    local serial = startupSerial
    Wait.time(function()
        probeExistingHelper(helper.getGUID(), serial, 4, runtimeStateToRestore)
    end, HELPER_PROBE_INTERVAL)
    return helper
end

local function parseSemver(version)
    if type(version) ~= "string" then
        return nil
    end
    local major, minor, patch = string.match(version, "^v?(%d+)%.(%d+)%.(%d+)$")
    if major == nil then
        return nil
    end
    return {tonumber(major), tonumber(minor), tonumber(patch)}
end

local function compareSemver(left, right)
    local a = parseSemver(left)
    local b = parseSemver(right)
    if a == nil or b == nil then
        return nil
    end
    for index = 1, 3 do
        if a[index] < b[index] then
            return -1
        elseif a[index] > b[index] then
            return 1
        end
    end
    return 0
end

local function responseStatus(request)
    return tonumber(request and request.response_code) or 0
end

local function responseEtag(request)
    if request == nil then
        return nil
    end
    local ok, value = pcall(function()
        return request.getResponseHeader("ETag")
    end)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function requestFailure(request, expectedStatus)
    if request == nil then
        return "sem resposta"
    end
    if request.is_error then
        return request.error or "erro de rede"
    end
    local status = responseStatus(request)
    if status ~= expectedStatus then
        return "HTTP " .. tostring(status)
    end
    return nil
end

local function webGet(url, headers, callback)
    local requestHeaders = shallowCopy(headers)
    requestHeaders.Accept = requestHeaders.Accept or "application/vnd.github+json"
    requestHeaders["User-Agent"] = "corvan-tts-automation/" .. BOOTSTRAP_VERSION
    local completed = false
    local request = nil

    local function complete(result)
        if completed then
            return
        end
        completed = true
        callback(result)
    end

    local ok, errorMessage = pcall(function()
        -- TTS order is data before headers; a GET has an empty request body.
        request = WebRequest.custom(url, "GET", true, "", requestHeaders, complete)
    end)
    if not ok then
        complete({is_error = true, error = tostring(errorMessage), response_code = 0, text = ""})
        return
    end

    local timeoutScheduled = pcall(function()
        Wait.time(function()
            if completed then
                return
            end
            if request ~= nil then
                pcall(function()
                    request.dispose()
                end)
            end
            complete({is_error = true, error = "timeout de rede", response_code = 0, text = ""})
        end, WEB_REQUEST_TIMEOUT)
    end)
    if not timeoutScheduled then
        if request ~= nil then
            pcall(function()
                request.dispose()
            end)
        end
        complete({is_error = true, error = "timeout indisponível", response_code = 0, text = ""})
    end
end

local function findManifestUrl(release)
    if type(release) ~= "table" or type(release.assets) ~= "table" then
        return nil
    end
    for _, asset in ipairs(release.assets) do
        if type(asset) == "table"
            and asset.name == "manifest.json"
            and type(asset.browser_download_url) == "string"
        then
            return asset.browser_download_url
        end
    end
    return nil
end

local function manifestRuntime(manifest)
    if type(manifest.runtime) == "table" then
        return manifest.runtime.url, manifest.runtime.size, manifest.runtime.sha256
    end
    return manifest.runtimeUrl, manifest.runtimeSize, manifest.runtimeSha256
end

local function validateManifest(manifest, releaseTag)
    if type(manifest) ~= "table" then
        return false, "manifesto inválido"
    end
    if manifest.schemaVersion ~= MANIFEST_SCHEMA_VERSION then
        return false, "schema do manifesto incompatível"
    end
    if parseSemver(manifest.version) == nil then
        return false, "versão inválida"
    end
    if parseSemver(manifest.minBootstrapVersion) == nil then
        return false, "minBootstrapVersion inválida"
    end
    if compareSemver(BOOTSTRAP_VERSION, manifest.minBootstrapVersion) < 0 then
        return false, "bootstrap precisa ser atualizado manualmente"
    end
    if type(releaseTag) == "string" and compareSemver(manifest.version, releaseTag) ~= 0 then
        return false, "release e manifesto não correspondem"
    end
    if type(manifest.commitSha) ~= "string"
        or not string.match(manifest.commitSha, "^[0-9a-fA-F]+$")
        or #manifest.commitSha < 7
        or #manifest.commitSha > 40
    then
        return false, "commitSha inválido"
    end
    local runtimeUrl, runtimeSize, runtimeSha256 = manifestRuntime(manifest)
    local expectedRuntimeUrl = TRUSTED_RUNTIME_PREFIX .. "v" .. manifest.version .. "/corvan-runtime.lua"
    if runtimeUrl ~= expectedRuntimeUrl then
        return false, "URL do runtime não confiável"
    end
    if type(runtimeSize) ~= "number" or runtimeSize < 1 or runtimeSize > MAX_RUNTIME_BYTES or runtimeSize ~= math.floor(runtimeSize) then
        return false, "tamanho do runtime inválido"
    end
    if type(runtimeSha256) ~= "string" or not string.match(runtimeSha256, "^[0-9a-fA-F]+$") or #runtimeSha256 ~= 64 then
        return false, "SHA-256 do runtime inválido"
    end
    return true, nil
end

local function exportedRuntimeIsBusy(exported)
    return type(exported) == "table"
        and (exported.rollInProgress == true or exported.busy == true)
end

local function applyDeferredUi(xml)
    if type(xml) ~= "string" then
        return false
    end
    if not installUiXml(xml) then
        return false
    end
    state.uiXml = xml
    return true
end

local function commitUpdate(serial, helper, health)
    if not isCurrentUpdate(serial) then
        return
    end
    local candidate = update.candidate
    local snapshot = update.snapshot
    if candidate == nil or snapshot == nil then
        rollbackUpdate(serial, "transação incompleta")
        return
    end
    if not restoreRuntimeState(helper, snapshot.runtimeState) then
        rollbackUpdate(serial, "estado incompatível com a nova versão")
        return
    end

    local exportedOk, exported = safeObjectCall(helper, "exportState", {})
    if not exportedOk or type(exported) ~= "table" then
        rollbackUpdate(serial, "novo runtime não exportou o estado")
        return
    end
    if update.pendingUiXml == nil or not applyDeferredUi(update.pendingUiXml) then
        rollbackUpdate(serial, "novo runtime não forneceu uma interface válida")
        return
    end
    state.helperGuid = helper.getGUID()
    state.runtimeSource = candidate.source
    state.runtimeVersion = candidate.manifest.version
    state.runtimeCommitSha = candidate.manifest.commitSha
    state.releaseEtag = candidate.etag or state.releaseEtag
    state.runtimeState = exported
    finishUpdate(serial, "atualizado para v" .. state.runtimeVersion .. ".", false)
end

beginReloadProbe = function(serial, mode, expectedVersion, attemptsRemaining)
    if not isCurrentUpdate(serial) then
        return
    end
    local snapshot = update.snapshot
    local helperGuid = state.helperGuid
    local helper = getObjectFromGUID(helperGuid)
    if helper ~= nil and ownsHelper(helper) then
        registerHelper(helper)
        local ok, health = safeObjectCall(helper, "healthCheck", {})
        if ok and healthIsValid(health, expectedVersion) then
            if mode == "install" then
                commitUpdate(serial, helper, health)
            else
                local restored = restoreRuntimeState(helper, snapshot.runtimeState)
                state.runtimeSource = snapshot.runtimeSource
                state.runtimeVersion = snapshot.runtimeVersion
                state.runtimeCommitSha = snapshot.runtimeCommitSha
                state.runtimeState = snapshot.runtimeState
                state.uiXml = snapshot.uiXml
                state.helperGuid = helper.getGUID()
                if type(snapshot.uiXml) == "string" and snapshot.uiXml ~= "" then
                    installUiXml(snapshot.uiXml)
                end
                if restored then
                    finishUpdate(serial, "atualização cancelada; versão anterior restaurada.", true)
                else
                    finishUpdate(serial, "rollback carregou, mas não restaurou todo o estado.", true)
                end
            end
            return
        end
    end

    if attemptsRemaining > 0 then
        Wait.time(function()
            beginReloadProbe(serial, mode, expectedVersion, attemptsRemaining - 1)
        end, HELPER_PROBE_INTERVAL)
        return
    end
    if mode == "install" then
        rollbackUpdate(serial, "health check expirou")
    else
        finishUpdate(serial, "falha crítica no rollback; salve a mesa e tente novamente.", true)
    end
end

local function reloadHelperForUpdate(serial, source, mode, expectedVersion)
    if not isCurrentUpdate(serial) then
        return false
    end
    local helper = helperFromState()
    if helper == nil then
        return false
    end
    registerHelper(helper)
    runtimeReadyPayload = nil
    update.pendingUiXml = nil
    local ok, reloaded = pcall(function()
        helper.setLuaScript(source)
        return helper.reload()
    end)
    if not ok then
        return false
    end
    if reloaded ~= nil then
        state.helperGuid = reloaded.getGUID()
    end
    update.phase = mode
    Wait.time(function()
        beginReloadProbe(serial, mode, expectedVersion, math.floor(HELPER_HEALTH_TIMEOUT / HELPER_PROBE_INTERVAL))
    end, HELPER_PROBE_INTERVAL)
    return true
end

rollbackUpdate = function(serial, reason)
    if not isCurrentUpdate(serial) then
        return
    end
    local snapshot = update.snapshot
    if snapshot == nil or not runtimeSourceIsValid(snapshot.runtimeSource) then
        finishUpdate(serial, reason .. "; não há runtime anterior para restaurar.", true)
        return
    end
    update.phase = "rollback"
    update.pendingUiXml = nil
    setRefreshFeedback("Revertendo...", true)
    if not reloadHelperForUpdate(serial, snapshot.runtimeSource, "rollback", snapshot.runtimeVersion) then
        finishUpdate(serial, reason .. "; falha ao iniciar rollback.", true)
    end
end

local function installCandidate(serial, candidate)
    if not isCurrentUpdate(serial) then
        return
    end
    local helper = helperFromState()
    if helper == nil then
        finishUpdate(serial, "helper indisponível; nenhuma alteração aplicada.", true)
        ensureHelper()
        return
    end
    local exported = cacheExportedState(helper)
    if exported == nil then
        finishUpdate(serial, "não foi possível salvar o estado atual.", true)
        return
    end
    if exportedRuntimeIsBusy(exported) then
        finishUpdate(serial, "aguarde a rolagem terminar antes de atualizar.", true)
        return
    end
    update.snapshot = {
        runtimeSource = state.runtimeSource,
        runtimeVersion = state.runtimeVersion,
        runtimeCommitSha = state.runtimeCommitSha,
        runtimeState = exported,
        uiXml = state.uiXml,
    }
    update.candidate = candidate
    setRefreshFeedback("Aplicando...", true)
    if not reloadHelperForUpdate(serial, candidate.source, "install", candidate.manifest.version) then
        rollbackUpdate(serial, "não foi possível recarregar o novo runtime")
    end
end

local function downloadRuntime(serial, manifest, etag)
    local runtimeUrl, runtimeSize, expectedSha256 = manifestRuntime(manifest)
    setRefreshFeedback("Baixando runtime...", true)
    webGet(runtimeUrl, {Accept = "text/plain"}, function(request)
        if not isCurrentUpdate(serial) then
            return
        end
        local failure = requestFailure(request, 200)
        if failure ~= nil then
            finishUpdate(serial, "download falhou (" .. failure .. "); versão atual preservada.", true)
            return
        end
        local source = request.text
        if not runtimeSourceIsValid(source) then
            finishUpdate(serial, "runtime inválido; versão atual preservada.", true)
            return
        end
        setRefreshFeedback("Verificando integridade...", true)
        verifyRuntimeIntegrityAsync(serial, source, runtimeSize, expectedSha256, function(ok, reason)
            if not isCurrentUpdate(serial) then
                return
            end
            if not ok then
                finishUpdate(serial, reason .. "; versão atual preservada.", true)
                return
            end
            installCandidate(serial, {manifest = manifest, source = source, etag = etag})
        end)
    end)
end

local function downloadManifest(serial, manifestUrl, releaseTag, etag)
    setRefreshFeedback("Validando release...", true)
    webGet(manifestUrl, {Accept = "application/json"}, function(request)
        if not isCurrentUpdate(serial) then
            return
        end
        local failure = requestFailure(request, 200)
        if failure ~= nil then
            finishUpdate(serial, "manifesto indisponível (" .. failure .. ").", true)
            return
        end
        local manifest = safeDecode(request.text)
        local valid, reason = validateManifest(manifest, releaseTag)
        if not valid then
            finishUpdate(serial, reason .. "; versão atual preservada.", true)
            return
        end
        local comparison = compareSemver(manifest.version, state.runtimeVersion)
        if comparison == nil then
            finishUpdate(serial, "não foi possível comparar as versões.", true)
            return
        end
        if comparison <= 0 then
            state.releaseEtag = etag or state.releaseEtag
            finishUpdate(serial, comparison == 0 and "já está na versão mais recente." or "downgrade recusado.", comparison < 0)
            return
        end
        downloadRuntime(serial, manifest, etag)
    end)
end

local function beginReleaseLookup(serial)
    local headers = {}
    if type(state.releaseEtag) == "string" and state.releaseEtag ~= "" then
        headers["If-None-Match"] = state.releaseEtag
    end
    webGet(RELEASE_API_URL, headers, function(request)
        if not isCurrentUpdate(serial) then
            return
        end
        local status = responseStatus(request)
        if not request.is_error and status == 304 then
            finishUpdate(serial, "já está na versão mais recente.", false)
            return
        end
        local failure = requestFailure(request, 200)
        if failure ~= nil then
            finishUpdate(serial, "não foi possível consultar o GitHub (" .. failure .. ").", true)
            return
        end
        local release = safeDecode(request.text)
        if release == nil or release.draft == true or release.prerelease == true or parseSemver(release.tag_name) == nil then
            finishUpdate(serial, "resposta de release inválida.", true)
            return
        end
        local manifestUrl = findManifestUrl(release)
        if manifestUrl == nil then
            finishUpdate(serial, "release sem manifest.json.", true)
            return
        end
        downloadManifest(serial, manifestUrl, release.tag_name, responseEtag(request))
    end)
end

function onLoad(savedData)
    state = sanitizePersistedState(safeDecode(savedData))
    state.bootstrapVersion = BOOTSTRAP_VERSION
    state.schemaVersion = STATE_SCHEMA_VERSION
    startupInstallAttempts = 0
    if type(state.uiXml) == "string" and state.uiXml ~= "" then
        installUiXml(state.uiXml)
    end
    setRefreshFeedback("", false)
    ensureHelper()
end

function recoverUi(_, playerColor, _)
    local color = playerColorOf(playerColor)
    local xml = state and state.uiXml or SEED_UI
    if installUiXml(xml) then
        tell(color, "recarregando a interface...", {0.80, 0.68, 0.38})
    else
        tell(color, "não foi possível recarregar a interface.", {1.0, 0.38, 0.30})
    end
end

function onSave()
    if state == nil then
        state = defaultState()
    end
    local helper = helperFromState()
    if helper ~= nil and not update.active then
        cacheExportedState(helper)
    end
    state.bootstrapVersion = BOOTSTRAP_VERSION
    state.schemaVersion = STATE_SCHEMA_VERSION
    return safeEncode(state)
end

function onDestroy()
    local helper = state and helperFromState() or nil
    if helper ~= nil then
        pcall(destroyObject, helper)
    end
end

function dispatch(player, value, id)
    local playerColor = playerColorOf(player)
    if id == "refresh" or id == "settings_refresh" or id == "bootstrap_refresh" then
        refresh(playerColor, value, id)
        return
    end
    if update.active then
        tell(playerColor, "atualização em andamento; aguarde.", {1.0, 0.72, 0.28})
        return
    end
    local helper = helperFromState()
    if helper == nil then
        tell(playerColor, "runtime iniciando; tente novamente em instantes.", {1.0, 0.72, 0.28})
        ensureHelper()
        return
    end
    local ok = safeObjectCall(helper, "handleUiEvent", {
        playerColor = playerColor,
        value = value,
        id = id,
    })
    if not ok then
        tell(playerColor, "ação indisponível; runtime será recuperado.", {1.0, 0.38, 0.30})
        beginStableRuntimeInstall(helper)
    end
end

function refresh(player, value, id)
    local playerColor = playerColorOf(player)
    if update.active then
        tell(playerColor, "atualização já está em andamento.", {1.0, 0.72, 0.28})
        return
    end
    local helper = helperFromState()
    if helper == nil then
        tell(playerColor, "runtime ainda está iniciando.", {1.0, 0.72, 0.28})
        ensureHelper()
        return
    end
    local exported = cacheExportedState(helper)
    if exported == nil then
        tell(playerColor, "não foi possível salvar o estado atual.", {1.0, 0.38, 0.30})
        return
    end
    if exportedRuntimeIsBusy(exported) then
        tell(playerColor, "aguarde a rolagem terminar antes de atualizar.", {1.0, 0.72, 0.28})
        return
    end
    update.active = true
    update.serial = update.serial + 1
    update.playerColor = playerColor
    update.phase = "release"
    update.snapshot = nil
    update.candidate = nil
    update.pendingUiXml = nil
    setRefreshFeedback("Consultando GitHub...", true)
    beginReleaseLookup(update.serial)
end

function runtimeReady(payload)
    if type(payload) == "table" and payload.parentGuid ~= nil and payload.parentGuid ~= self.getGUID() then
        return false
    end
    runtimeReadyPayload = payload
    return true
end

function cacheRuntimeState(payload)
    if state == nil then
        state = defaultState()
    end
    local candidate = payload
    if type(payload) == "table" and type(payload.state) == "table" then
        candidate = payload.state
    end
    if type(candidate) ~= "table" then
        return false
    end
    if update.active then
        -- Candidate/rollback callbacks are not stable until the transaction settles.
        return true
    end
    state.runtimeState = candidate
    return true
end

function applyRuntimeUi(payload)
    if state == nil then
        state = defaultState()
    end
    local xml = payload
    if type(payload) == "table" then
        xml = payload.xml
    end
    if type(xml) ~= "string" or xml == "" then
        return false
    end
    if update.active then
        update.pendingUiXml = xml
        return true
    end
    return applyDeferredUi(xml)
end

function setRuntimeUiAttribute(payload)
    if type(payload) ~= "table"
        or type(payload.id) ~= "string"
        or type(payload.attribute) ~= "string"
    then
        return false
    end
    return setUiAttribute(payload.id, payload.attribute, payload.value or "")
end

function getBootstrapInfo()
    return {
        bootstrapVersion = BOOTSTRAP_VERSION,
        schemaVersion = STATE_SCHEMA_VERSION,
        runtimeVersion = state and state.runtimeVersion or SEED_RUNTIME_VERSION,
        helperGuid = state and state.helperGuid or nil,
        updating = update.active,
    }
end
