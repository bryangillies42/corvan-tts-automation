-- ARCANE_TEST_RUNTIME
-- Adaptador técnico deliberadamente diferente do Corvan.
local CHARACTER_ID = __CHARACTER_ID_LITERAL__
local CHARACTER_VERSION = __CHARACTER_VERSION_LITERAL__
local RUNTIME_MARKER = __RUNTIME_MARKER_LITERAL__
local UI_XML = __UI_XML_LITERAL__
local CHARACTER_JSON = __CHARACTER_JSON_LITERAL__
local CHARACTER = nil
local characterLoaded = false
local parentGuid = nil
local state = nil

local CONFIG = {
    characterId = CHARACTER_ID,
    runtimeVersion = CHARACTER_VERSION,
    allowLegacyIdentity = false,
    project = "corvan-tts-automation"
}
local AdapterApi = CharacterRuntimeCore.createRuntimeApi(CONFIG)

local function decodeCharacter()
    if type(JSON) ~= "table" or type(JSON.decode) ~= "function" then return end
    local ok, decoded = pcall(function() return JSON.decode(CHARACTER_JSON) end)
    if ok and type(decoded) == "table" and decoded.id == CHARACTER_ID then
        CHARACTER = decoded
        characterLoaded = true
    end
end

decodeCharacter()

local function defaultCharacterState()
    local maximum = characterLoaded and CHARACTER.resources.focus.max or 0
    return {focus = maximum, casts = 0, stateSchemaVersion = 1}
end

local function normalizeCharacterState(candidate)
    local normalized = defaultCharacterState()
    if type(candidate) ~= "table" then return normalized end
    local maximum = characterLoaded and CHARACTER.resources.focus.max or 0
    normalized.focus = CharacterRuntimeCore.clamp(candidate.focus, 0, maximum)
    normalized.casts = math.max(0, math.floor(CharacterRuntimeCore.finiteNumber(candidate.casts, 0)))
    return normalized
end

local function resolveParent()
    if type(parentGuid) ~= "string" or type(getObjectFromGUID) ~= "function" then return nil end
    local ok, object = pcall(getObjectFromGUID, parentGuid)
    return ok and object or nil
end

local function parentCall(name, payload)
    local object = resolveParent()
    if object == nil or type(object.call) ~= "function" then return false end
    local ok, result = pcall(function() return object.call(name, payload) end)
    return ok and result ~= false
end

local function render()
    if not characterLoaded then return end
    parentCall("setRuntimeUiAttribute", {
        id = "arcaneFocus", attribute = "text",
        value = "FOCO " .. tostring(state.focus) .. "/" .. tostring(CHARACTER.resources.focus.max)
    })
    parentCall("setRuntimeUiAttribute", {
        id = "arcaneCasts", attribute = "text",
        value = "CONJURAÇÕES " .. tostring(state.casts)
    })
end

function exportState()
    local envelope = AdapterApi.state.envelope(state, {fixture = true})
    envelope.schemaVersion = 1
    envelope.characterStateSchemaVersion = 1
    envelope.parentGuid = parentGuid
    envelope.rollInProgress = false
    return envelope
end

local function acceptState(payload)
    local characterState, _, stateError = AdapterApi.state.unwrap(payload)
    if stateError ~= nil then return false end
    state = normalizeCharacterState(characterState)
    return true
end

function importState(payload)
    if type(payload) == "table" and type(payload.state) == "table" then payload = payload.state end
    if not acceptState(payload) then return false end
    parentCall("cacheRuntimeState", {state = exportState()})
    render()
    return true
end

function handleUiEvent(payload)
    if type(payload) ~= "table" then return false end
    if payload.id == "cast" and state.focus > 0 then
        state.focus = state.focus - 1
        state.casts = state.casts + 1
    elseif payload.id == "reset_fixture" then
        state = defaultCharacterState()
    else
        return false
    end
    parentCall("cacheRuntimeState", {state = exportState()})
    render()
    return true
end

function healthCheck(_)
    return {
        ok = characterLoaded,
        characterId = CHARACTER_ID,
        runtimeMarker = RUNTIME_MARKER,
        version = CHARACTER_VERSION,
        parentGuid = parentGuid,
        rollInProgress = false
    }
end

function registerParent(payload)
    if type(payload) ~= "table" or payload.characterId ~= CHARACTER_ID then return false end
    parentGuid = payload.parentGuid
    if type(parentGuid) ~= "string" or parentGuid == "" then return false end
    if type(payload.state) == "table" and not acceptState(payload.state) then return false end
    parentCall("applyRuntimeUi", {xml = UI_XML, characterId = CHARACTER_ID, version = CHARACTER_VERSION})
    parentCall("cacheRuntimeState", {state = exportState()})
    render()
    parentCall("runtimeReady", {
        characterId = CHARACTER_ID,
        version = CHARACTER_VERSION,
        parentGuid = parentGuid,
        health = healthCheck({})
    })
    return true
end

function onLoad(savedData)
    state = defaultCharacterState()
    if type(savedData) == "string" and savedData ~= "" and type(JSON) == "table" then
        local ok, decoded = pcall(function() return JSON.decode(savedData) end)
        if ok and type(decoded) == "table" then acceptState(decoded) end
    end
end

function onSave()
    if type(JSON) ~= "table" or type(JSON.encode) ~= "function" then return "" end
    local ok, encoded = pcall(function() return JSON.encode(exportState()) end)
    return ok and encoded or ""
end

state = defaultCharacterState()
