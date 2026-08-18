-- __RUNTIME_MARKER__
-- Adaptador mínimo. Substitua os eventos e o estado pelos contratos da ficha.
local CHARACTER_ID = __CHARACTER_ID_LITERAL__
local CHARACTER_VERSION = __CHARACTER_VERSION_LITERAL__
local RUNTIME_MARKER = __RUNTIME_MARKER_LITERAL__
local UI_XML = __UI_XML_LITERAL__
local CHARACTER_JSON = __CHARACTER_JSON_LITERAL__
local parentGuid = nil
local state = {events = 0, stateSchemaVersion = 1}

local CONFIG = {
    characterId = CHARACTER_ID,
    runtimeVersion = CHARACTER_VERSION,
    allowLegacyIdentity = false,
    project = "corvan-tts-automation"
}
local AdapterApi = CharacterRuntimeCore.createRuntimeApi(CONFIG)

local function parentCall(name, payload)
    if type(parentGuid) ~= "string" or type(getObjectFromGUID) ~= "function" then return false end
    local ok, parent = pcall(getObjectFromGUID, parentGuid)
    if not ok or parent == nil or type(parent.call) ~= "function" then return false end
    local called, result = pcall(function() return parent.call(name, payload) end)
    return called and result ~= false
end

function exportState()
    local envelope = AdapterApi.state.envelope(state, {})
    envelope.schemaVersion = 1
    envelope.characterStateSchemaVersion = 1
    envelope.parentGuid = parentGuid
    envelope.rollInProgress = false
    return envelope
end

function importState(payload)
    if type(payload) == "table" and type(payload.state) == "table" then payload = payload.state end
    local characterState, _, stateError = AdapterApi.state.unwrap(payload)
    if stateError ~= nil then return false end
    state.events = math.max(0, math.floor(CharacterRuntimeCore.finiteNumber(characterState.events, 0)))
    parentCall("cacheRuntimeState", {characterId = CHARACTER_ID, state = exportState()})
    return true
end

function handleUiEvent(payload)
    if type(payload) ~= "table"
        or payload.characterId ~= CHARACTER_ID
        or payload.parentGuid ~= parentGuid
    then
        return false
    end
    return false
end

function healthCheck(_)
    return {
        ok = true,
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
    if type(payload.state) == "table" and not importState(payload.state) then return false end
    parentCall("applyRuntimeUi", {xml = UI_XML, characterId = CHARACTER_ID, version = CHARACTER_VERSION})
    parentCall("cacheRuntimeState", {characterId = CHARACTER_ID, state = exportState()})
    parentCall("runtimeReady", {
        characterId = CHARACTER_ID,
        version = CHARACTER_VERSION,
        parentGuid = parentGuid,
        health = healthCheck({})
    })
    return true
end

function onLoad(_)
end

function onSave()
    if type(JSON) ~= "table" or type(JSON.encode) ~= "function" then return "" end
    local ok, encoded = pcall(function() return JSON.encode(exportState()) end)
    return ok and encoded or ""
end
