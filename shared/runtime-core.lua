-- Biblioteca comum dos runtimes de personagens.
--
-- Contrato:
--   * Este arquivo e estatico e pode ser concatenado antes de um adaptador de
--     personagem. Ele nao depende das APIs do Tabletop Simulator.
--   * A unica variavel global criada e CharacterRuntimeCore.
--   * As funcoes nao alteram os argumentos recebidos e nao executam codigo
--     dinamico (nao usam require, load ou loadstring).
--   * Os identificadores de personagem sao slugs minusculos em kebab-case.

CharacterRuntimeCore = {}

local Core = CharacterRuntimeCore

local function configCharacterId(config)
    if type(config) ~= "table" then return nil end
    return config.characterId or config.id
end

local function configVersion(config)
    if type(config) ~= "table" then return nil end
    return config.runtimeVersion or config.version
end

-- Copia tabelas, inclusive chaves-tabela e ciclos, para que o runtime de um
-- personagem nunca compartilhe referencias mutaveis com outro personagem.
function Core.deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[Core.deepCopy(key, seen)] = Core.deepCopy(item, seen)
    end
    return copy
end

-- Retorna o numero quando ele e finito; para nil, NaN e infinitos retorna o
-- fallback. O fallback tambem pode ser nil.
function Core.finiteNumber(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end

function Core.clamp(value, minimum, maximum)
    minimum = Core.finiteNumber(minimum, 0)
    maximum = Core.finiteNumber(maximum, minimum)
    value = Core.finiteNumber(value, minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

-- Colchetes de texto variavel sao convertidos para a forma fullwidth, pois o
-- chat do TTS interpreta colchetes ASCII como tags de cor.
function Core.chatSafeText(value)
    return tostring(value):gsub("%[", "［"):gsub("%]", "］")
end

local function allowedColorTag(tag)
    return tag == "[FF6464]" or tag == "[62B8FF]"
end

-- Preserva somente [FF6464], [62B8FF] e [-]. Tags desconhecidas, tags fora de
-- ordem e tags nao fechadas fazem a mensagem inteira cair para texto seguro.
function Core.chatSafeRichText(value)
    local text = tostring(value)
    local position = 1
    local colorOpen = false
    while position <= #text do
        local openAt = string.find(text, "[", position, true)
        local closeAt = string.find(text, "]", position, true)
        if closeAt ~= nil and (openAt == nil or closeAt < openAt) then
            return Core.chatSafeText(text)
        end
        if openAt == nil then break end
        local tagEnd = string.find(text, "]", openAt + 1, true)
        if tagEnd == nil then return Core.chatSafeText(text) end
        local tag = string.sub(text, openAt, tagEnd)
        if allowedColorTag(tag) then
            if colorOpen then return Core.chatSafeText(text) end
            colorOpen = true
        elseif tag == "[-]" then
            if not colorOpen then return Core.chatSafeText(text) end
            colorOpen = false
        else
            return Core.chatSafeText(text)
        end
        position = tagEnd + 1
    end
    if colorOpen then return Core.chatSafeText(text) end
    return text
end

local function diceNumber(value, fallback)
    return Core.finiteNumber(value, fallback)
end

function Core.formatDice(count, sides, values)
    count = diceNumber(count, 1)
    sides = diceNumber(sides, 20)
    local prefix = count == 1 and "" or tostring(count)
    local rendered = {}
    if type(values) == "table" then
        for _, value in ipairs(values) do
            table.insert(rendered, tostring(value))
        end
    end
    return prefix .. "d" .. tostring(sides) .. "["
        .. table.concat(rendered, ",") .. "]"
end

function Core.formatModifier(value)
    value = Core.finiteNumber(value, 0)
    if value > 0 then return " + " .. tostring(value) end
    if value < 0 then return " - " .. tostring(math.abs(value)) end
    return ""
end

local function formatChatDice(count, sides, values)
    count = diceNumber(count, 1)
    sides = diceNumber(sides, 20)
    local prefix = count == 1 and "" or tostring(count)
    local rendered = {}
    if type(values) == "table" then
        for _, value in ipairs(values) do
            table.insert(rendered, tostring(value))
        end
    end
    -- Parentheses sao intencionais: no chat eles nao iniciam tags do TTS.
    return prefix .. "d" .. tostring(sides) .. "(" .. table.concat(rendered, ",") .. ")"
end

local function colorSegment(hex, value)
    return "[" .. hex .. "]" .. Core.chatSafeText(value) .. "[-]"
end

-- Mantem o formato publico do Corvan e serve como contrato visual para novos
-- adaptadores: somente o nome e o resultado recebem destaque cromatico.
function Core.formatChatRollResult(shortName, label, total, count, sides, values, modifier, suffix)
    local formula = formatChatDice(count, sides, values) .. Core.formatModifier(modifier)
    local result = colorSegment("FF6464", shortName) .. " • "
        .. Core.chatSafeText(label) .. "  │ RESULTADO: "
        .. colorSegment("62B8FF", total) .. "  │ CÁLCULO: "
        .. Core.chatSafeText(formula)
    if type(suffix) == "string" and suffix ~= "" then
        local renderedSuffix = suffix == "CRÍTICO"
            and colorSegment("FF6464", suffix) or Core.chatSafeText(suffix)
        result = result .. "  │ " .. renderedSuffix
    end
    return result
end

-- Garante o contrato de identidade de personagem. Retorna apenas booleano;
-- nao normaliza nem altera o slug recebido.
function Core.validateCharacterId(slug)
    if type(slug) ~= "string" or slug == "" then return false end
    if string.sub(slug, 1, 1) == "-" or string.sub(slug, -1) == "-" then
        return false
    end
    if string.find(slug, "--", 1, true) ~= nil then return false end
    return string.match(slug, "^[a-z0-9%-]+$") ~= nil
end

-- Envelopa o estado especifico do personagem. O primeiro retorno e nil mais
-- uma mensagem quando a configuracao nao possui uma identidade valida.
function Core.envelopeState(config, flatState, coreFields)
    local characterId = configCharacterId(config)
    if not Core.validateCharacterId(characterId) then
        return nil, "invalid characterId"
    end
    return {
        characterId = characterId,
        runtimeVersion = configVersion(config),
        core = Core.deepCopy(coreFields or {}),
        character = Core.deepCopy(flatState or {})
    }
end

-- Desfaz envelopeState. Retornos: characterState, coreFields, errorMessage.
-- Saves legados sem characterId sao aceitos somente quando o perfil declara
-- allowLegacyIdentity=true; um ID divergente nunca e aceito.
function Core.unwrapState(config, payload)
    local characterId = configCharacterId(config)
    if not Core.validateCharacterId(characterId) then
        return nil, nil, "invalid characterId"
    end
    if type(payload) ~= "table" then
        return nil, nil, "invalid state payload"
    end

    -- Alguns contratos de exportacao envolvem o estado uma segunda vez em
    -- {state = ...}; aceitar essa camada nao altera a identidade validada.
    if type(payload.state) == "table"
        and payload.character == nil and payload.characterId == nil then
        payload = payload.state
    end

    if payload.characterId ~= nil then
        if payload.characterId ~= characterId then
            return nil, nil, "characterId mismatch"
        end
        if type(payload.character) ~= "table" then
            return nil, nil, "missing character state"
        end
        return Core.deepCopy(payload.character), Core.deepCopy(payload.core or {}), nil
    end

    if config.allowLegacyIdentity ~= true then
        return nil, nil, "legacy identity is not allowed"
    end
    if type(payload.character) == "table" then
        return Core.deepCopy(payload.character), Core.deepCopy(payload.core or {}), nil
    end
    return Core.deepCopy(payload), {}, nil
end

-- Metadados sao usados por dados fisicos, GM Notes e objetos auxiliares. O
-- projeto legado e opcional e so e emitido quando o perfil o configura.
function Core.metadata(config, kind, ownerPanelGuid)
    local characterId = configCharacterId(config)
    local result = {
        characterId = characterId,
        kind = kind,
        ownerPanelGuid = ownerPanelGuid
    }
    local project = type(config) == "table" and config.project or nil
    if project ~= nil then result.project = project end
    return result
end

-- Valida metadados sem aceitar objetos de outro personagem. Metadados legados
-- sem characterId somente passam quando legacyProject foi explicitamente
-- configurado no perfil.
function Core.metadataMatches(config, metadata, kind, ownerPanelGuid)
    if type(config) ~= "table" or type(metadata) ~= "table" then return false end
    local characterId = configCharacterId(config)
    if not Core.validateCharacterId(characterId) then return false end
    if metadata.kind ~= kind or metadata.ownerPanelGuid ~= ownerPanelGuid then
        return false
    end
    if metadata.characterId ~= nil then
        if metadata.characterId ~= characterId then return false end
        if config.project ~= nil and metadata.project ~= nil
            and metadata.project ~= config.project then
            return false
        end
        return true
    end
    local legacyProject = config.legacyProject
    if type(legacyProject) ~= "string" or legacyProject == "" then return false end
    return metadata.project == legacyProject
end

-- API fechada consumida pelos adaptadores. O host é injetado pelo runtime e
-- pode oferecer ui, publicChat, privateError, rollDice, clearDice, cache e
-- render. O core mantém identidade, cópias defensivas e a forma dos payloads;
-- nenhuma regra do personagem entra neste contrato.
function Core.createRuntimeApi(config, host)
    host = type(host) == "table" and host or {}
    local api = {}

    api.state = {
        envelope = function(characterState, coreState)
            return Core.envelopeState(config, characterState, coreState)
        end,
        unwrap = function(payload)
            return Core.unwrapState(config, payload)
        end
    }

    api.chat = {
        formatRoll = Core.formatChatRollResult,
        public = function(payload)
            if type(host.publicChat) ~= "function" then return false end
            return host.publicChat(Core.deepCopy(payload)) == true
        end,
        privateError = function(payload)
            if type(host.privateError) ~= "function" then return false end
            return host.privateError(Core.deepCopy(payload)) == true
        end
    }

    api.ui = {
        apply = function(payload)
            if type(host.applyUi) ~= "function" then return false end
            local request = Core.deepCopy(payload or {})
            request.characterId = configCharacterId(config)
            request.runtimeVersion = configVersion(config)
            return host.applyUi(request) == true
        end,
        set = function(id, attribute, value)
            if type(host.setUiAttribute) ~= "function" then return false end
            return host.setUiAttribute({
                characterId = configCharacterId(config),
                id = id,
                attribute = attribute,
                value = tostring(value or "")
            }) == true
        end
    }

    api.dice = {
        metadata = function(ownerPanelGuid)
            return Core.metadata(config, "owned-die", ownerPanelGuid)
        end,
        owns = function(metadata, ownerPanelGuid)
            return Core.metadataMatches(config, metadata, "owned-die", ownerPanelGuid)
        end,
        roll = function(specification)
            if type(host.rollDice) ~= "function" then return false end
            return host.rollDice(Core.deepCopy(specification)) == true
        end,
        clear = function(guids, ownerPanelGuid)
            if type(host.clearDice) ~= "function" then return 0 end
            local removed = host.clearDice(Core.deepCopy(guids or {}), ownerPanelGuid)
            return math.max(0, math.floor(Core.finiteNumber(removed, 0)))
        end
    }

    api.undo = {
        capture = function(characterState)
            local snapshot = Core.deepCopy(characterState or {})
            snapshot.undo = nil
            return snapshot
        end,
        restore = function(snapshot)
            return Core.deepCopy(snapshot)
        end
    }

    api.cache = function(characterState, coreState)
        local envelope, stateError = Core.envelopeState(config, characterState, coreState)
        if envelope == nil then return false, stateError end
        if type(host.cache) ~= "function" then return true, envelope end
        return host.cache(Core.deepCopy(envelope)) == true, envelope
    end

    api.render = function()
        if type(host.render) ~= "function" then return false end
        return host.render() == true
    end

    return api
end
