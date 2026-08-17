-- CORVAN_RUNTIME
-- Runtime atualizável do helper invisível. Este arquivo é empacotado pelo build:
-- os marcadores abaixo viram literais com o XML, os dados e o asset físico esperado.
local UI_XML = __UI_XML_LITERAL__
local CHARACTER_JSON = __CHARACTER_JSON_LITERAL__
local PANEL_IMAGE_URL = __PANEL_IMAGE_URL_LITERAL__
local PANEL_UI_IMAGE_URL = __PANEL_UI_IMAGE_URL_LITERAL__

local STATE_SCHEMA_VERSION = 1
local ROLL_TIMEOUT_SECONDS = 15
local SPAWN_TIMEOUT_SECONDS = 4
local DICE_STABLE_FRAMES = 12
local DICE_LAUNCH_DELAY_FRAMES = 3
local LEGACY_DICE_OFFSET = {x = 0, y = 2.5, z = -5}
local function chatColor()
    -- Use the positional Color table required by the TTS message API. Named
    -- RGBA fields can emit a dev-api event without rendering in the Game tab.
    return {0.92, 0.94, 0.97}
end

local function errorColor()
    return {0.95, 0.36, 0.30}
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[deepCopy(key, seen)] = deepCopy(item, seen)
    end
    return result
end

local function finiteNumber(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end

local function clamp(value, minimum, maximum)
    value = finiteNumber(value, minimum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local DEFAULT_CHARACTER = {
    schemaVersion = 1,
    version = "0.2.0",
    name = "Corvan Duras",
    shortName = "Corvan",
    resources = {hp = {max = 78}, mp = {max = 21}},
    defense = 24,
    damageReduction = 8,
    weapons = {
        sword = {
            name = "Espada Longa", chatName = "Espada", attack = 13,
            damage = {count = 1, sides = 8, bonus = 5},
            critical = {min = 18, multiplier = 2}
        },
        shield = {
            name = "Escudo Pesado", chatName = "Escudo", attack = 12, defenseModifier = 4,
            damage = {count = 1, sides = 6, bonus = 5},
            critical = {min = 20, multiplier = 2}
        }
    },
    skills = {
        initiative = {name = "Iniciativa", modifier = 3},
        fight = {name = "Luta", modifier = 12},
        intimidation = {name = "Intimidação", modifier = 6},
        perception = {name = "Percepção", modifier = 8},
        fortitude = {name = "Fortitude", modifier = 15, resistance = true},
        reflex = {name = "Reflexos", modifier = 7, resistance = true},
        will = {name = "Vontade", modifier = 8, resistance = true},
        riding = {name = "Cavalgar", modifier = 7},
        diplomacy = {name = "Diplomacia", modifier = 10},
        warfare = {name = "Guerra", modifier = 8},
        aim = {name = "Pontaria", modifier = 7}
    },
    powers = {
        combatDefensive = {cost = 0, attackModifier = -2, defenseModifier = 5},
        duel = {
            cost = 2, upgradeCost = 1,
            attackModifier = 2, damageModifier = 2,
            upgradedAttackModifier = 3, upgradedDamageModifier = 3
        },
        baluarte = {
            cost = 1, upgradeCost = 1, sharedCost = 2,
            defenseModifier = 2, resistanceModifier = 2,
            upgradedDefenseModifier = 4, upgradedResistanceModifier = 4
        },
        provocation = {cost = 2, willDifficulty = 16},
        solidity = {resistanceModifier = 4},
        duelistShielded = {damageReduction = 2, upgradedDamageReduction = 3},
        weaponAndShieldStyle = {shieldDefenseModifier = 4}
    },
    diceOffset = {x = 0, y = 3.2, z = 0}
}

local characterLoaded = false
local function decodeCharacter()
    if type(JSON) ~= "table" or type(JSON.decode) ~= "function" then
        return deepCopy(DEFAULT_CHARACTER)
    end
    local ok, decoded = pcall(function() return JSON.decode(CHARACTER_JSON) end)
    if not ok or type(decoded) ~= "table" or type(decoded.weapons) ~= "table" then
        return deepCopy(DEFAULT_CHARACTER)
    end
    characterLoaded = true
    return decoded
end

local CHARACTER = decodeCharacter()
local parentGuid = nil

-- Funções puras expostas para um harness Lua sem depender das APIs do TTS.
CorvanRules = {}
CorvanRules.clamp = clamp

local function duelModifier(character, currentState, upgradedField, baseField, powerKey)
    local active = currentState.effects and currentState.effects.duel
    local power = character.powers[powerKey or "duel"] or {}
    if active == true then return finiteNumber(power[baseField], 0) end
    local value = finiteNumber(active, 0)
    local upgraded = finiteNumber(power[upgradedField], 3)
    local base = finiteNumber(power[baseField], 2)
    if value >= upgraded then return upgraded end
    if value >= base then return base end
    return 0
end

function CorvanRules.calculateAttackModifier(character, currentState, weaponKey)
    local weapon = character.weapons[weaponKey]
    if not weapon then return 0 end
    local result = finiteNumber(weapon.attack, 0)
    local effects = currentState.effects or {}
    result = result + duelModifier(character, currentState,
        "upgradedAttackModifier", "attackModifier")
    if effects.combatDefensiveArmed then
        result = result + finiteNumber(character.powers.combatDefensive.attackModifier, 0)
    end
    return result
end

local function baluarteModifier(character, currentState, upgradedField, baseField)
    local active = currentState.effects and currentState.effects.baluarte
    if active == true then return finiteNumber(character.powers.baluarte[baseField], 0) end
    local value = finiteNumber(active, 0)
    local upgraded = finiteNumber(character.powers.baluarte[upgradedField], 4)
    local base = finiteNumber(character.powers.baluarte[baseField], 2)
    if value >= upgraded then return upgraded end
    if value >= base then return base end
    return 0
end

function CorvanRules.calculateDefense(character, currentState)
    local result = finiteNumber(character.defense, 0)
    local effects = currentState.effects or {}
    if effects.shieldGuardSuppressed then
        result = result - finiteNumber(character.weapons.shield.defenseModifier, 0)
    end
    if effects.combatDefensiveDefense then
        result = result + finiteNumber(character.powers.combatDefensive.defenseModifier, 0)
    end
    result = result + baluarteModifier(character, currentState,
        "upgradedDefenseModifier", "defenseModifier")
    return result
end

function CorvanRules.calculateSkillModifier(character, currentState, skillKey)
    local skill = character.skills[skillKey]
    if not skill then return 0 end
    local result = finiteNumber(skill.modifier, 0)
    if skill.resistance then
        if currentState.effects and currentState.effects.shieldGuardSuppressed then
            result = result - finiteNumber(character.powers.solidity.resistanceModifier, 0)
        end
        result = result + baluarteModifier(character, currentState,
            "upgradedResistanceModifier", "resistanceModifier")
    end
    return result
end

function CorvanRules.calculateDamageReduction(character, currentState)
    local result = finiteNumber(character.damageReduction, 0)
    result = result + duelModifier(character, currentState,
        "upgradedDamageReduction", "damageReduction", "duelistShielded")
    return result
end

function CorvanRules.calculateDamageSpec(character, currentState, weaponKey, critical)
    local weapon = character.weapons[weaponKey]
    if not weapon then return nil end
    local count = finiteNumber(weapon.damage.count, 1)
    if critical then
        -- T20: o multiplicador afeta apenas a quantidade de dados da arma.
        count = count * finiteNumber(weapon.critical.multiplier, 2)
    end
    local bonus = finiteNumber(weapon.damage.bonus, 0)
    local effects = currentState.effects or {}
    bonus = bonus + duelModifier(character, currentState,
        "upgradedDamageModifier", "damageModifier")
    return {count = count, sides = finiteNumber(weapon.damage.sides, 6), bonus = bonus}
end

function CorvanRules.isThreat(character, weaponKey, naturalResult)
    local weapon = character.weapons[weaponKey]
    if not weapon then return false end
    return finiteNumber(naturalResult, 0) >= finiteNumber(weapon.critical.min, 20)
end

local function defaultEffects()
    return {
        combatDefensiveArmed = false,
        combatDefensiveDefense = false,
        duel = false,
        baluarte = false,
        baluarteShared = false,
        shieldGuardSuppressed = false,
        provocation = false
    }
end

local function defaultState()
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        runtimeVersion = CHARACTER.version,
        hp = finiteNumber(CHARACTER.resources.hp.max, 78),
        mp = finiteNumber(CHARACTER.resources.mp.max, 21),
        activeWeapon = "sword",
        effects = defaultEffects(),
        pendingThreat = nil,
        undo = nil,
        diceOffset = deepCopy(CHARACTER.diceOffset or {x = 0, y = 3.2, z = 0}),
        ownedDiceGuids = {},
        ownedDiceOwnerGuid = parentGuid,
        lastResult = "—",
        automaticResourceSpending = true,
        settingsOpen = false
    }
end

local function normalizeSnapshot(source)
    if type(source) ~= "table" then return nil end
    local normalized = defaultState()
    normalized.hp = math.floor(clamp(source.hp or source.pv, 0, CHARACTER.resources.hp.max))
    normalized.mp = math.floor(clamp(source.mp or source.pm, 0, CHARACTER.resources.mp.max))
    if CHARACTER.weapons[source.activeWeapon] then normalized.activeWeapon = source.activeWeapon end
    if type(source.effects) == "table" then
        for key in pairs(normalized.effects) do
            if key == "duel" then
                local saved = source.effects.duel
                local base = finiteNumber(CHARACTER.powers.duel.attackModifier, 2)
                local upgraded = finiteNumber(CHARACTER.powers.duel.upgradedAttackModifier, 3)
                if saved == true then normalized.effects.duel = base
                elseif finiteNumber(saved, 0) >= upgraded then normalized.effects.duel = upgraded
                elseif finiteNumber(saved, 0) >= base then normalized.effects.duel = base end
            elseif key == "baluarte" then
                local saved = source.effects.baluarte
                local base = finiteNumber(CHARACTER.powers.baluarte.defenseModifier, 2)
                local upgraded = finiteNumber(CHARACTER.powers.baluarte.upgradedDefenseModifier, 4)
                if saved == true then normalized.effects.baluarte = base
                elseif finiteNumber(saved, 0) >= upgraded then normalized.effects.baluarte = upgraded
                elseif finiteNumber(saved, 0) >= base then normalized.effects.baluarte = base end
            else
                normalized.effects[key] = source.effects[key] == true
            end
        end
    end
    -- Nas mudanças de nível, somente recursos que estavam cheios recebem o
    -- novo máximo. Valores gastos ou ferimentos são preservados para não
    -- curar nem restaurar PM silenciosamente. A ordem permite atualizar
    -- diretamente da v0.1.5 (nível 4) até o nível 7.
    if (CHARACTER.version == "0.1.6" or CHARACTER.version == "0.1.7"
            or CHARACTER.version == "0.1.8" or CHARACTER.version == "0.1.9"
            or CHARACTER.version == "0.2.0")
        and source.runtimeVersion ~= "0.1.6"
        and source.runtimeVersion ~= "0.1.7"
        and source.runtimeVersion ~= "0.1.8"
        and source.runtimeVersion ~= "0.1.9"
        and source.runtimeVersion ~= "0.2.0" then
        if finiteNumber(source.hp or source.pv, 0) == 47 then normalized.hp = 55 end
        if finiteNumber(source.mp or source.pm, 0) == 12 then normalized.mp = 15 end
    end
    if (CHARACTER.version == "0.1.8" or CHARACTER.version == "0.1.9"
            or CHARACTER.version == "0.2.0")
        and source.runtimeVersion ~= "0.1.8"
        and source.runtimeVersion ~= "0.1.9"
        and source.runtimeVersion ~= "0.2.0" then
        if normalized.hp == 55 then normalized.hp = 69 end
        if normalized.mp == 15 then normalized.mp = 18 end
    end
    if CHARACTER.version == "0.2.0" and source.runtimeVersion ~= "0.2.0" then
        if normalized.hp == 69 then normalized.hp = 78 end
        if normalized.mp == 18 then normalized.mp = 21 end
    end
    if type(source.pendingThreat) == "table" and CHARACTER.weapons[source.pendingThreat.weaponKey] then
        normalized.pendingThreat = {
            weaponKey = source.pendingThreat.weaponKey,
            natural = finiteNumber(source.pendingThreat.natural, 0)
        }
    end
    if type(source.diceOffset) == "table" then
        normalized.diceOffset.x = finiteNumber(source.diceOffset.x, normalized.diceOffset.x)
        normalized.diceOffset.y = finiteNumber(source.diceOffset.y, normalized.diceOffset.y)
        normalized.diceOffset.z = finiteNumber(source.diceOffset.z, normalized.diceOffset.z)
        -- A v0.1.2 salvava um offset diante do painel. Ao atualizar, migramos
        -- somente esse valor exato; qualquer calibração personalizada é mantida.
        if normalized.diceOffset.x == LEGACY_DICE_OFFSET.x
            and normalized.diceOffset.y == LEGACY_DICE_OFFSET.y
            and normalized.diceOffset.z == LEGACY_DICE_OFFSET.z then
            normalized.diceOffset = deepCopy(CHARACTER.diceOffset or {x = 0, y = 3.2, z = 0})
        end
    end
    if type(source.lastResult) == "string" then normalized.lastResult = source.lastResult end
    -- Campo opcional no schema 1: saves anteriores não o possuem e continuam
    -- com o comportamento histórico de desconto automático.
    normalized.automaticResourceSpending = source.automaticResourceSpending ~= false
    normalized.settingsOpen = source.settingsOpen == true
    normalized.undo = nil
    normalized.ownedDiceGuids = {}
    normalized.ownedDiceOwnerGuid = nil
    return normalized
end

local function normalizeState(source)
    local normalized = normalizeSnapshot(source or {}) or defaultState()
    normalized.ownedDiceOwnerGuid = parentGuid
    if type(source) == "table" then
        normalized.undo = normalizeSnapshot(source.undo)
        -- A v0.1.6 já exportava parentGuid, então ele funciona como ownership
        -- legado. Cópias do painel recebem outro GUID e descartam as referências
        -- herdadas sem tocar nos dados físicos do objeto original.
        local sourceOwner = source.ownedDiceOwnerGuid
        if type(sourceOwner) ~= "string" or sourceOwner == "" then
            sourceOwner = source.parentGuid
        end
        if type(parentGuid) == "string" and parentGuid ~= ""
            and sourceOwner == parentGuid and type(source.ownedDiceGuids) == "table" then
            for _, guid in ipairs(source.ownedDiceGuids) do
                if type(guid) == "string" and #normalized.ownedDiceGuids < 32 then
                    table.insert(normalized.ownedDiceGuids, guid)
                end
            end
        end
    end
    return normalized
end

local state = defaultState()
-- Texto digitado é estado transitório da interface. Ele não participa de
-- save/load, Refresh ou Desfazer; somente a aplicação válida altera a ficha.
local resourceAdjustments = {hp = "", mp = ""}
local parent = nil
local rollInProgress = false
local currentRoll = nil
local rollSequence = 0
local chatAudit = {}
local chatAuditSequence = 0
local panelBoardArtNeeded = false
local panelBoardArtReady = false
local panelBoardArtRequestSerial = 0

local function recordChatAudit(message, route, accepted)
    chatAuditSequence = chatAuditSequence + 1
    table.insert(chatAudit, {
        sequence = chatAuditSequence,
        message = tostring(message),
        route = tostring(route),
        accepted = accepted == true
    })
    while #chatAudit > 24 do table.remove(chatAudit, 1) end
end

local function safeObjectGuid(object)
    if not object then return nil end
    local ok, guid = pcall(function() return object.getGUID() end)
    if ok then return guid end
    return nil
end

local function resolveParent()
    if not parentGuid or type(getObjectFromGUID) ~= "function" then return nil end
    local ok, object = pcall(function() return getObjectFromGUID(parentGuid) end)
    if ok then parent = object end
    return parent
end

local function safeParentCall(functionName, payload)
    if not parent then resolveParent() end
    if not parent then return false, nil end
    local ok, result = pcall(function() return parent.call(functionName, payload) end)
    return ok, result
end

local function safeSetAttribute(id, attribute, value)
    local ok, accepted = safeParentCall("setRuntimeUiAttribute", {
        id = id,
        attribute = attribute,
        value = tostring(value)
    })
    return ok and accepted ~= false
end

local function signed(value)
    value = finiteNumber(value, 0)
    if value >= 0 then return "+" .. tostring(value) end
    return tostring(value)
end

local function formatDice(count, sides, values)
    local prefix = count == 1 and "" or tostring(count)
    local strings = {}
    for _, value in ipairs(values) do table.insert(strings, tostring(value)) end
    return prefix .. "d" .. tostring(sides) .. "[" .. table.concat(strings, ",") .. "]"
end

local function formatModifier(value)
    value = finiteNumber(value, 0)
    if value > 0 then return " + " .. tostring(value) end
    if value < 0 then return " - " .. tostring(math.abs(value)) end
    return ""
end

-- O chat do TTS usa colchetes ASCII para BBCode. Conteúdo variável precisa
-- usar colchetes fullwidth para nunca ser interpretado como uma tag de cor.
local function chatSafeText(value)
    return tostring(value):gsub("%[", "［"):gsub("%]", "］")
end

local function formatChatDice(count, sides, values)
    local prefix = count == 1 and "" or tostring(count)
    local strings = {}
    for _, value in ipairs(values) do table.insert(strings, tostring(value)) end
    return prefix .. "d" .. tostring(sides) .. "(" .. table.concat(strings, ",") .. ")"
end

local function chatColorSegment(hex, value)
    return "[" .. hex .. "]" .. chatSafeText(value) .. "[-]"
end

-- Apenas as duas cores abaixo podem atravessar o relay. Qualquer outro
-- colchete continua sendo convertido antes de chegar ao parser do TTS.
local function chatSafeRichText(value)
    local text = tostring(value)
    local position = 1
    local colorOpen = false
    while position <= #text do
        local openAt = string.find(text, "[", position, true)
        local strayCloseAt = string.find(text, "]", position, true)
        if strayCloseAt and (not openAt or strayCloseAt < openAt) then
            return chatSafeText(text)
        end
        if not openAt then break end
        local closeAt = string.find(text, "]", openAt + 1, true)
        if not closeAt then return chatSafeText(text) end
        local tag = string.sub(text, openAt, closeAt)
        if tag == "[FF6464]" or tag == "[62B8FF]" then
            if colorOpen then return chatSafeText(text) end
            colorOpen = true
        elseif tag == "[-]" then
            if not colorOpen then return chatSafeText(text) end
            colorOpen = false
        else
            return chatSafeText(text)
        end
        position = closeAt + 1
    end
    if colorOpen then return chatSafeText(text) end
    return text
end

function CorvanRules.formatRollResult(label, total, count, sides, values, modifier, suffix)
    local result = tostring(label) .. " - " .. tostring(total) .. " ("
        .. formatDice(count, sides, values) .. formatModifier(modifier) .. ")"
    if type(suffix) == "string" and suffix ~= "" then
        result = result .. " • " .. suffix
    end
    return result
end

function CorvanRules.formatChatRollResult(shortName, label, total, count, sides, values, modifier, suffix)
    local formula = formatChatDice(count, sides, values) .. formatModifier(modifier)
    -- Duas tags curtas preservam a hierarquia visual sem recriar as sete cores
    -- e os blocos de negrito que tornavam o renderer do chat frágil.
    local result = chatColorSegment("FF6464", shortName) .. " • " .. chatSafeText(label)
        .. "  │ RESULTADO: " .. chatColorSegment("62B8FF", total)
        .. "  │ CÁLCULO: " .. chatSafeText(formula)
    if type(suffix) == "string" and suffix ~= "" then
        local renderedSuffix = suffix == "CRÍTICO"
            and chatColorSegment("FF6464", suffix) or chatSafeText(suffix)
        result = result .. "  │ " .. renderedSuffix
    end
    return result
end

local function damageFormula(spec)
    if not spec then return "—" end
    local dice = (spec.count == 1 and "" or tostring(spec.count)) .. "d" .. tostring(spec.sides)
    if spec.bonus == 0 then return dice end
    return dice .. signed(spec.bonus)
end

local function criticalFormula(weapon)
    local minimum = finiteNumber(weapon.critical.min, 20)
    local range = minimum == 20 and "20" or tostring(minimum) .. "–20"
    return range .. "/x" .. tostring(weapon.critical.multiplier)
end

local function effectsLabel()
    local labels = {}
    if state.effects.combatDefensiveArmed then
        table.insert(labels, "Combate Defensivo: −2 ataque, +5 DEF")
    elseif state.effects.combatDefensiveDefense then
        table.insert(labels, "Combate Defensivo: +5 DEF")
    end
    local duel = duelModifier(CHARACTER, state, "upgradedAttackModifier", "attackModifier")
    if duel > 0 then
        table.insert(labels, "Duelo: +" .. tostring(duel) .. " ataque/dano e RD")
    end
    local baluarte = finiteNumber(state.effects.baluarte, state.effects.baluarte == true and 2 or 0)
    if baluarte > 0 then
        local shared = state.effects.baluarteShared and " (aliados)" or ""
        table.insert(labels, "Baluarte +" .. tostring(baluarte) .. shared)
    end
    if state.effects.shieldGuardSuppressed then
        table.insert(labels, "Escudo: −4 DEF e resistências")
    end
    if state.effects.provocation then table.insert(labels, "Provocação") end
    if #labels == 0 then return "Nenhum efeito ativo" end
    return table.concat(labels, " • ")
end

local function panelBoardOverlayNeeded()
    -- A moldura da UI é a referência de alinhamento do painel. Ela também deve
    -- cobrir objetos novos: o TTS mantém um cache por URL e pode reutilizar uma
    -- versão física antiga mesmo quando CustomImage aponta para o asset atual.
    -- A textura do Custom_Tile permanece abaixo como fallback offline.
    return true
end

local function panelBoardOverlayActive()
    return panelBoardArtNeeded and panelBoardArtReady
end

local function preparePanelBoardArt()
    panelBoardArtRequestSerial = panelBoardArtRequestSerial + 1
    local serial = panelBoardArtRequestSerial
    panelBoardArtNeeded = panelBoardOverlayNeeded()
    panelBoardArtReady = false
    safeSetAttribute("panelBoardArt", "active", "false")
    if not panelBoardArtNeeded or WebRequest == nil then return end

    -- Uma URL direta inválida faz o Image do TTS ficar branco. Primeiro
    -- verificamos se o JPEG responde; em erro, a camada permanece inativa e a
    -- textura física antiga continua sendo o fallback visual do painel.
    local started = pcall(function()
        WebRequest.get(PANEL_UI_IMAGE_URL, function(request)
            if serial ~= panelBoardArtRequestSerial then return end
            local status = finiteNumber(request and request.response_code, 0)
            if request and not request.is_error and status >= 200 and status < 300 then
                panelBoardArtReady = true
                safeSetAttribute("panelBoardArt", "active", "true")
            end
        end)
    end)
    if not started then panelBoardArtReady = false end
end

local function renderNow()
    if not parent then return end
    local weapon = CHARACTER.weapons[state.activeWeapon]
    local attack = CorvanRules.calculateAttackModifier(CHARACTER, state, state.activeWeapon)
    local damage = CorvanRules.calculateDamageSpec(CHARACTER, state, state.activeWeapon, false)
    safeSetAttribute("activeWeaponLabel", "text", weapon.name)
    safeSetAttribute("attackValue", "text", signed(attack))
    safeSetAttribute("damageValue", "text", damageFormula(damage))
    safeSetAttribute("criticalValue", "text", criticalFormula(weapon))
    safeSetAttribute("defenseValue", "text", CorvanRules.calculateDefense(CHARACTER, state))
    safeSetAttribute("calculatedDefenseValue", "text", CorvanRules.calculateDefense(CHARACTER, state))
    safeSetAttribute("rdValue", "text", CorvanRules.calculateDamageReduction(CHARACTER, state))
    safeSetAttribute("lastResult", "text", state.lastResult)
    safeSetAttribute("activeEffects", "text", effectsLabel())
    safeSetAttribute("activePowersLabel", "text", effectsLabel())
    safeSetAttribute("pvCurrent", "text", state.hp)
    safeSetAttribute("pvMax", "text", CHARACTER.resources.hp.max)
    safeSetAttribute("pmCurrent", "text", state.mp)
    safeSetAttribute("pmMax", "text", CHARACTER.resources.mp.max)
    safeSetAttribute("pv_adjust", "text", resourceAdjustments.hp)
    safeSetAttribute("pm_adjust", "text", resourceAdjustments.mp)
    safeSetAttribute("automatic_resource_spending", "isOn",
        state.automaticResourceSpending and "true" or "false")
    safeSetAttribute("panelBoardArt", "active", panelBoardOverlayActive() and "true" or "false")
    safeSetAttribute("offset_x", "text", state.diceOffset.x)
    safeSetAttribute("offset_y", "text", state.diceOffset.y)
    safeSetAttribute("offset_z", "text", state.diceOffset.z)
    safeSetAttribute("versionLabel", "text", "v" .. tostring(CHARACTER.version))
    safeSetAttribute("settingsPanel", "active", state.settingsOpen and "true" or "false")
    safeSetAttribute("toggle_settings", "text", state.settingsOpen and "FECHAR" or "CONFIG")
    safeSetAttribute("roll_critical", "interactable", state.pendingThreat and "true" or "false")
    safeSetAttribute("clear_dice", "interactable",
        not rollInProgress and #(state.ownedDiceGuids or {}) > 0 and "true" or "false")
    local baluarte = finiteNumber(state.effects.baluarte, state.effects.baluarte == true and 2 or 0)
    local baluarteText = "BALUARTE  •  1/2 PM\n+2 ou +4 DEF e resistências\naté o próximo turno"
    if baluarte == 2 then
        baluarteText = "BALUARTE +2  •  ATIVO\nclique novamente: +4 (+1 PM)\naté o próximo turno"
    elseif baluarte >= 4 then
        baluarteText = "BALUARTE +4  •  ATIVO\nDEF e resistências\naté o próximo turno"
    end
    safeSetAttribute("power_baluarte", "text", baluarteText)
    local sharedText = "ALIADOS  •  +2 PM\ncompartilha o Baluarte\ncom adjacentes"
    if state.effects.baluarteShared then
        sharedText = "ALIADOS  •  ATIVO\nBaluarte +" .. tostring(baluarte) .. " compartilhado\naté o próximo turno"
    elseif baluarte <= 0 then
        sharedText = "ALIADOS  •  +2 PM\native Baluarte primeiro\npara compartilhar"
    end
    safeSetAttribute("power_baluarte_allies", "text", sharedText)
    safeSetAttribute("power_baluarte_allies", "interactable", baluarte > 0 and "true" or "false")
    local duel = duelModifier(CHARACTER, state, "upgradedAttackModifier", "attackModifier")
    local duelText = "DUELO  •  2/3 PM\n+2 ou +3 ataque, dano e RD\naté o fim da cena"
    if duel == 2 then
        duelText = "DUELO +2  •  ATIVO\nclique novamente: +3 (+1 PM)\naté o fim da cena"
    elseif duel >= 3 then
        duelText = "DUELO +3  •  ATIVO\nataque, dano e RD\naté o fim da cena"
    end
    safeSetAttribute("power_duel", "text", duelText)
    safeSetAttribute("weapon_sword", "colors", state.activeWeapon == "sword" and "#75591D|#98752B|#4F3B13|#22222288" or "#22282E|#303A43|#151A1F|#22222288")
    safeSetAttribute("weapon_shield", "colors", state.activeWeapon == "shield" and "#75591D|#98752B|#4F3B13|#22222288" or "#22282E|#303A43|#151A1F|#22222288")
    local powerColors = {
        power_combat_defensive = state.effects.combatDefensiveArmed or state.effects.combatDefensiveDefense,
        power_duel = state.effects.duel,
        power_baluarte = state.effects.baluarte,
        power_baluarte_allies = state.effects.baluarteShared,
        power_provocacao = state.effects.provocation
    }
    for id, active in pairs(powerColors) do
        safeSetAttribute(id, "colors", active and "#73402F|#93543D|#4E2B20|#22222288" or "#1C252C|#2B373F|#11171B|#22222288")
    end
end

local function scheduleRender()
    if not parent then return end
    -- O bootstrap mantém o último valor de cada atributo e o aplica somente
    -- depois que o XML termina de carregar. Assim o runtime nunca toca
    -- diretamente em parent.UI, cuja exceção Unity não é capturada por pcall.
    renderNow()
end

local function applyUi()
    if not parent then return false end
    -- O XML completo também carrega o valor atual do toggle. Isso mantém a
    -- preferência sincronizada até em painéis importados com um bootstrap
    -- anterior, cujo whitelist ainda não conhecia o atributo isOn.
    local toggleValue = state.automaticResourceSpending and "true" or "false"
    local renderedXml = UI_XML:gsub(
        'id="automatic_resource_spending" isOn="[^"]*"',
        'id="automatic_resource_spending" isOn="' .. toggleValue .. '"', 1)
    -- A camada sempre começa inativa. Ela só é exibida após o preflight HTTP
    -- confirmar a imagem, evitando o retângulo branco do fallback do Unity.
    local overlayValue = "false"
    renderedXml = renderedXml:gsub(
        'id="panelBoardArt" active="[^"]*"',
        'id="panelBoardArt" active="' .. overlayValue .. '"', 1)
    local ok, accepted = safeParentCall("applyRuntimeUi", {xml = renderedXml, version = CHARACTER.version})
    preparePanelBoardArt()
    scheduleRender()
    return ok and accepted ~= false
end

local function snapshotState()
    local snapshot = normalizeSnapshot(state)
    snapshot.undo = nil
    return snapshot
end

local function pushUndo()
    state.undo = snapshotState()
end

local function cacheAndRender()
    safeParentCall("cacheRuntimeState", {state = exportState()})
    scheduleRender()
end

local function chatDiagnostic(message)
    if type(log) == "function" then
        pcall(function() log(message, "Corvan chat") end)
    elseif type(print) == "function" then
        pcall(function() print("Corvan chat: " .. message) end)
    end
end

-- O chat do TTS interpreta [HEX] como BBCode de cor. Resultados como d20[18]
-- abrem uma tag e podem tornar o restante desta e das próximas mensagens
-- invisível. Os colchetes fullwidth preservam a leitura sem acionar o parser.
local function chatSafeMessage(message, richText)
    if richText == true then return chatSafeRichText(message) end
    return chatSafeText(message)
end

local function playerProperty(player, property)
    local ok, value = pcall(function() return player[property] end)
    if ok then return value end
    return nil
end

local function recipientKey(player)
    local steamId = playerProperty(player, "steam_id")
    if steamId ~= nil and tostring(steamId) ~= "" and tostring(steamId) ~= "0" then
        return "steam:" .. tostring(steamId)
    end
    local color = playerProperty(player, "color")
    if type(color) == "string" and color ~= "" then return "color:" .. color end
    return "object:" .. tostring(player)
end

local function connectedPlayers()
    if Player == nil then return {}, false end
    local players = {}
    local seen = {}
    local managerAvailable = false
    for _, functionName in ipairs({"getPlayers", "getSpectators"}) do
        -- TTS expõe Player como userdata; indexar suas funções precisa ser
        -- protegido e não pode depender de type(Player) == "table".
        local readOk, managerFunction = pcall(function() return Player[functionName] end)
        if readOk and type(managerFunction) == "function" then
            managerAvailable = true
            local ok, list = pcall(function() return managerFunction() end)
            if ok and type(list) == "table" then
                for _, player in ipairs(list) do
                    local key = recipientKey(player)
                    if not seen[key] then
                        seen[key] = true
                        table.insert(players, player)
                    end
                end
            end
        end
    end
    return players, managerAvailable
end

local function recipientColors(preferredColor)
    local colors = {}
    local seen = {}
    local function add(color)
        if type(color) == "string" and color ~= "" and not seen[color] then
            seen[color] = true
            table.insert(colors, color)
        end
    end

    -- O evento da UI sempre fornece a cor de quem clicou. Incluí-la primeiro
    -- garante o chat local mesmo quando o Player Manager do TTS enumera uma
    -- lista vazia em single player/offline.
    add(preferredColor)
    if type(getSeatedPlayers) == "function" then
        local ok, seated = pcall(function() return getSeatedPlayers() end)
        if ok and type(seated) == "table" then
            for _, color in ipairs(seated) do add(color) end
        end
    end

    local players, managerAvailable = connectedPlayers()
    for _, player in ipairs(players) do add(playerProperty(player, "color")) end
    return colors, managerAvailable
end

local function printToPlayerColor(color, message, tint)
    -- No TTS real, tanto printToAll quanto Player.print podem retornar sem erro
    -- e ainda assim não inserir a linha depois de várias rolagens. A função
    -- global direcionada é a rota que efetivamente chega ao chat do cliente.
    if type(printToColor) == "function" and type(color) == "string" and color ~= "" then
        local ok = pcall(function() printToColor(message, color, tint) end)
        if ok then return true, "printToColor:" .. color end
    end
    if Player ~= nil and type(color) == "string" and color ~= "" then
        local ok = pcall(function() Player[color].print(message, tint) end)
        if ok then return true, "player-print:" .. color end
    end
    return false, "none"
end

local function publicMessage(message, preferredColor, messageTint, richText)
    message = chatSafeMessage(message, richText)
    local tint = type(messageTint) == "table" and messageTint or chatColor()
    -- A rota primária passa pelo bootstrap do painel visível. O TTS pode
    -- aceitar silenciosamente chamadas de chat feitas pelo helper invisível
    -- sem inseri-las no cliente, enquanto o mesmo envio pelo painel funciona.
    local relayOk, relayAccepted = safeParentCall("relayRuntimeChat", {
        message = message,
        playerColor = preferredColor,
        tint = tint,
        richText = richText == true
    })
    if relayOk and relayAccepted == true then
        recordChatAudit(message, "parent-relay", true)
        return true
    end

    local colors, managerAvailable = recipientColors(preferredColor)
    if #colors > 0 then
        local delivered = 0
        local routes = {}
        for _, color in ipairs(colors) do
            local ok, route = printToPlayerColor(color, message, tint)
            table.insert(routes, route)
            if ok then delivered = delivered + 1 end
        end
        recordChatAudit(message,
            "colors:" .. tostring(delivered) .. "/" .. tostring(#colors) .. ":" .. table.concat(routes, ","),
            delivered == #colors)
        if delivered == #colors then return true end
        chatDiagnostic("falha ao entregar para " .. tostring(#colors - delivered) .. " jogador(es).")
        return delivered > 0
    end

    -- Compatibility fallback for builds/harnesses where Player manager cannot
    -- enumerate clients. This remains chat-only.
    if type(printToAll) == "function" then
        local ok, failure = pcall(function() printToAll(message, tint) end)
        recordChatAudit(message, ok and "printToAll" or ("printToAll-error:" .. tostring(failure)), ok)
        if ok then return true end
        chatDiagnostic("printToAll rejeitou a mensagem: " .. tostring(failure))
    end

    -- Host-only debug fallback. Its route is deliberately explicit in the
    -- audit because this is not considered successful public delivery.
    if type(print) == "function" then
        local ok = pcall(function() print(message) end)
        recordChatAudit(message, "print-host-debug", false)
        if ok then chatDiagnostic("mensagem enviada apenas ao host por print().") end
    end

    recordChatAudit(message, "none", false)
    chatDiagnostic("nenhuma API pública de chat aceitou a mensagem.")
    return false
end

local function publicRollResult(label, total, count, sides, values, modifier, suffix, playerColor)
    return publicMessage(CorvanRules.formatChatRollResult(
        CHARACTER.shortName, label, total, count, sides, values, modifier, suffix),
        playerColor, nil, true)
end

local function privateError(playerColor, message)
    local relayed, accepted = safeParentCall("relayRuntimePrivate", {
        message = "Corvan • " .. message,
        playerColor = playerColor
    })
    if relayed and accepted == true then return end
    if type(playerColor) == "table" then playerColor = playerColor.color end
    if type(printToColor) == "function" and type(playerColor) == "string" and playerColor ~= "" then
        local ok = pcall(function() printToColor("Corvan • " .. message, playerColor, errorColor()) end)
        if ok then return end
    end
    if type(print) == "function" then print("Corvan • " .. message) end
end

local function ownedDieMetadata(object)
    if not object or type(JSON) ~= "table" or type(JSON.decode) ~= "function" then return nil, false end
    local notesOk, notes = pcall(function() return object.getGMNotes() end)
    if not notesOk or type(notes) ~= "string" or notes == "" then return nil, false end
    local decodedOk, metadata = pcall(function() return JSON.decode(notes) end)
    if not decodedOk or type(metadata) ~= "table" then return nil, true end
    return metadata, true
end

local function dieBelongsToParent(object)
    local metadata, hasNotes = ownedDieMetadata(object)
    if hasNotes then
        return metadata ~= nil
            and metadata.project == "corvan-tts-automation"
            and metadata.kind == "owned-die"
            and metadata.ownerPanelGuid == parentGuid
    end
    -- Dados criados até a v0.1.6 não possuíam metadados próprios. Eles só são
    -- aceitos quando o owner persistido (migrado de parentGuid) ainda coincide.
    return type(parentGuid) == "string" and state.ownedDiceOwnerGuid == parentGuid
end

local function markOwnedDie(object)
    if not object or type(JSON) ~= "table" or type(JSON.encode) ~= "function" then return false end
    local encodedOk, notes = pcall(function()
        return JSON.encode({
            project = "corvan-tts-automation",
            kind = "owned-die",
            ownerPanelGuid = parentGuid
        })
    end)
    if not encodedOk or type(notes) ~= "string" then return false end
    return pcall(function() object.setGMNotes(notes) end)
end

local function clearOwnedDice()
    local removed = 0
    for _, guid in ipairs(state.ownedDiceGuids or {}) do
        local object = nil
        if type(getObjectFromGUID) == "function" then
            local ok, found = pcall(function() return getObjectFromGUID(guid) end)
            if ok then object = found end
        end
        if object and dieBelongsToParent(object) and type(destroyObject) == "function" then
            local destroyed = pcall(function() destroyObject(object) end)
            if destroyed then removed = removed + 1 end
        end
    end
    state.ownedDiceGuids = {}
    state.ownedDiceOwnerGuid = parentGuid
    return removed
end

local function diceType(sides)
    local types = {[6] = "Die_6", [8] = "Die_8", [20] = "Die_20"}
    return types[sides]
end

local function localDicePosition(index, count)
    local offset = state.diceOffset
    local localPosition = {
        x = offset.x + (index - ((count + 1) / 2)) * 1.35,
        y = offset.y,
        z = offset.z
    }
    if parent then
        local ok, world = pcall(function() return parent.positionToWorld(localPosition) end)
        if ok and world then return world end
        local okPosition, position = pcall(function() return parent.getPosition() end)
        if okPosition and position then
            return {x = position.x + localPosition.x, y = position.y + localPosition.y, z = position.z + localPosition.z}
        end
    end
    return localPosition
end

local function localDirectionToWorld(localDirection, magnitude)
    if parent then
        local ok, origin, target = pcall(function()
            return parent.positionToWorld({x = 0, y = 0, z = 0}),
                parent.positionToWorld(localDirection)
        end)
        if ok and origin and target then
            local direction = {
                x = finiteNumber(target.x, 0) - finiteNumber(origin.x, 0),
                y = finiteNumber(target.y, 0) - finiteNumber(origin.y, 0),
                z = finiteNumber(target.z, 0) - finiteNumber(origin.z, 0)
            }
            local length = math.sqrt(direction.x * direction.x
                + direction.y * direction.y + direction.z * direction.z)
            if length > 0.001 then
                magnitude = finiteNumber(magnitude, 8.5)
                return {
                    x = direction.x / length * magnitude,
                    y = direction.y / length * magnitude,
                    z = direction.z / length * magnitude
                }
            end
        end
    end
    return {x = localDirection.x, y = localDirection.y, z = localDirection.z}
end

local function finishRollFailure(token, message)
    if not currentRoll or currentRoll.token ~= token then return end
    local rollback = currentRoll.rollback
    local playerColor = currentRoll.playerColor
    currentRoll = nil
    rollInProgress = false
    clearOwnedDice()
    if rollback then
        state = normalizeState(rollback)
        state.ownedDiceGuids = {}
        state.ownedDiceOwnerGuid = parentGuid
    end
    cacheAndRender()
    privateError(playerColor, message or "a rolagem falhou.")
end

local function completeRoll(token)
    if not currentRoll or currentRoll.token ~= token then return end
    local roll = currentRoll
    local values = {}
    for index = 1, roll.count do
        local object = roll.objects[index]
        local ok, value = pcall(function() return object.getRotationValue() end)
        value = ok and tonumber(value) or nil
        if not value then
            finishRollFailure(token, "um dado foi removido antes do resultado.")
            return
        end
        table.insert(values, value)
    end

    currentRoll = nil
    rollInProgress = false
    if roll.kind == "attack" then
        local natural = values[1]
        local total = natural + roll.modifier
        local threat = CorvanRules.isThreat(CHARACTER, roll.weaponKey, natural)
        state.pendingThreat = threat and {weaponKey = roll.weaponKey, natural = natural} or nil
        state.lastResult = CorvanRules.formatRollResult(
            CHARACTER.weapons[roll.weaponKey].chatName, total,
            roll.count, roll.sides, values, roll.modifier, threat and "crítico" or nil)
        publicRollResult(CHARACTER.weapons[roll.weaponKey].chatName, total,
            roll.count, roll.sides, values, roll.modifier,
            threat and "CRÍTICO" or nil, roll.playerColor)
    elseif roll.kind == "skill" then
        local total = values[1] + roll.modifier
        state.lastResult = CorvanRules.formatRollResult(
            roll.label, total, roll.count, roll.sides, values, roll.modifier)
        publicRollResult(roll.label, total, roll.count, roll.sides,
            values, roll.modifier, nil, roll.playerColor)
    elseif roll.kind == "damage" then
        local total = roll.bonus
        for _, value in ipairs(values) do total = total + value end
        local label = roll.critical and "Crítico" or "Dano"
        state.pendingThreat = nil
        state.lastResult = CorvanRules.formatRollResult(
            label, total, roll.count, roll.sides, values, roll.bonus)
        publicRollResult(label, total, roll.count, roll.sides,
            values, roll.bonus, nil, roll.playerColor)
    elseif roll.kind == "calibration" then
        state.lastResult = CorvanRules.formatRollResult(
            "Calibração", values[1], roll.count, roll.sides, values, 0)
        publicRollResult("Calibração", values[1], roll.count, roll.sides,
            values, 0, nil, roll.playerColor)
    end
    cacheAndRender()
end

local function diceHaveSettled(token)
    if not currentRoll or currentRoll.token ~= token then return true end
    local allRestingAfterMotion = true
    for index = 1, currentRoll.count do
        local object = currentRoll.objects[index]
        if not object then return false end
        local guid = safeObjectGuid(object)
        if not guid then
            currentRoll.objectMissing = true
            return true
        end
        if type(getObjectFromGUID) == "function" then
            local aliveOk, alive = pcall(function() return getObjectFromGUID(guid) end)
            if not aliveOk or not alive then
                currentRoll.objectMissing = true
                return true
            end
        end
        local ok, resting = pcall(function() return object.resting end)
        if not ok then
            currentRoll.objectMissing = true
            return true
        end
        if not resting then
            -- Logo após object.roll(), o TTS pode manter resting=true durante
            -- um frame. Só aceitamos o repouso depois de observar movimento
            -- real, evitando registrar a face inicial antes da física começar.
            currentRoll.motionObserved[index] = true
            currentRoll.stableRestFrames[index] = 0
            currentRoll.lastRestingValues[index] = nil
            allRestingAfterMotion = false
        elseif not currentRoll.motionObserved[index] then
            currentRoll.stableRestFrames[index] = 0
            currentRoll.lastRestingValues[index] = nil
            allRestingAfterMotion = false
        else
            local valueOk, value = pcall(function() return object.getRotationValue() end)
            value = valueOk and tonumber(value) or nil
            if not value then
                currentRoll.stableRestFrames[index] = 0
                currentRoll.lastRestingValues[index] = nil
                allRestingAfterMotion = false
            else
                if currentRoll.lastRestingValues[index] == value then
                    currentRoll.stableRestFrames[index] = currentRoll.stableRestFrames[index] + 1
                else
                    currentRoll.lastRestingValues[index] = value
                    currentRoll.stableRestFrames[index] = 1
                end
                if currentRoll.stableRestFrames[index] < DICE_STABLE_FRAMES then
                    allRestingAfterMotion = false
                end
            end
        end
    end
    return allRestingAfterMotion
end

local function waitForDice(token)
    if not currentRoll or currentRoll.token ~= token then return end
    local scheduled = pcall(function()
        Wait.condition(function()
            if currentRoll and currentRoll.token == token and currentRoll.objectMissing then
                finishRollFailure(token, "um dado foi removido durante a rolagem.")
            else
                completeRoll(token)
            end
        end, function() return diceHaveSettled(token) end, ROLL_TIMEOUT_SECONDS,
        function() finishRollFailure(token, "os dados não pararam a tempo.") end)
    end)
    if not scheduled then
        finishRollFailure(token, "não foi possível acompanhar os dados.")
    end
end

local function launchDie(token, index)
    if not currentRoll or currentRoll.token ~= token then return end
    local object = currentRoll.objects[index]
    if not object then
        finishRollFailure(token, "um dado desapareceu antes do lançamento.")
        return
    end

    -- Cada eixo é normalizado separadamente: o painel usa escala X/Z maior
    -- que Y, e transformar o vetor inteiro inclinava o lançamento para os lados.
    local up = localDirectionToWorld({x = 0, y = 1, z = 0}, 1)
    local right = localDirectionToWorld({x = 1, y = 0, z = 0}, 1)
    local forward = localDirectionToWorld({x = 0, y = 0, z = 1}, 1)
    local horizontalRight = (math.random() * 2 - 1) * 1.4
    local horizontalForward = (math.random() * 2 - 1) * 1.4
    local worldVelocity = {
        x = up.x * 16 + right.x * horizontalRight + forward.x * horizontalForward,
        y = up.y * 16 + right.y * horizontalRight + forward.y * horizontalForward,
        z = up.z * 16 + right.z * horizontalRight + forward.z * horizontalForward
    }
    -- setVelocity é determinístico depois do congelamento inicial do spawn.
    -- addForce pode retornar sem erro enquanto o TTS ainda ignora o impulso.
    local launched = pcall(function() object.setVelocity(worldVelocity) end)
    if not launched then
        launched = pcall(function() object.addForce(worldVelocity, 4) end)
    end

    local angularVelocity = {
        x = (math.random() * 2 - 1) * 24,
        y = (math.random() * 2 - 1) * 24,
        z = (math.random() * 2 - 1) * 24
    }
    local spinning = pcall(function() object.setAngularVelocity(angularVelocity) end)
    if not spinning then
        spinning = pcall(function() object.addTorque(angularVelocity, 4) end)
    end
    if not launched then
        -- Mantém compatibilidade com builds antigos, mas não aceita uma face
        -- parada como resultado caso a API de física também falhe.
        launched = pcall(function() object.roll() end)
    end
    if not launched then
        finishRollFailure(token, "não foi possível lançar o dado.")
        return
    end

    if not currentRoll or currentRoll.token ~= token then return end
    currentRoll.pendingLaunches = currentRoll.pendingLaunches - 1
    if currentRoll.pendingSpawns == 0 and currentRoll.pendingLaunches == 0 then
        waitForDice(token)
    end
end

local function onDieSpawned(token, index, object)
    if not currentRoll or currentRoll.token ~= token then
        -- Um callback pode chegar depois do timeout. O objeto ainda é nosso e deve
        -- ser removido para não deixar um dado órfão na mesa.
        if object and type(destroyObject) == "function" then
            pcall(function() destroyObject(object) end)
        end
        return
    end
    if not object then
        finishRollFailure(token, "não foi possível criar o dado.")
        return
    end
    currentRoll.objects[index] = object
    currentRoll.pendingSpawns = currentRoll.pendingSpawns - 1
    local guid = safeObjectGuid(object)
    state.ownedDiceOwnerGuid = parentGuid
    markOwnedDie(object)
    if guid then table.insert(state.ownedDiceGuids, guid) end
    pcall(function() object.setName("Corvan • dado da ferramenta") end)
    -- O TTS congela objetos recém-criados por um frame. Aplicar a força no
    -- callback imediato faz o dado nascer sem movimento em algumas sessões.
    local scheduled = pcall(function()
        Wait.frames(function() launchDie(token, index) end, DICE_LAUNCH_DELAY_FRAMES)
    end)
    if not scheduled then
        finishRollFailure(token, "não foi possível agendar o lançamento do dado.")
    end
end

local function canRoll(playerColor)
    if rollInProgress then
        privateError(playerColor, "aguarde a rolagem atual terminar.")
        return false
    end
    if not parent and not resolveParent() then
        privateError(playerColor, "o painel não está disponível.")
        return false
    end
    if type(spawnObject) ~= "function" then
        privateError(playerColor, "não foi possível criar dados físicos.")
        return false
    end
    return true
end

local function startPhysicalRoll(parameters)
    clearOwnedDice()
    rollSequence = rollSequence + 1
    local token = rollSequence
    parameters.token = token
    parameters.objects = {}
    parameters.motionObserved = {}
    parameters.stableRestFrames = {}
    parameters.lastRestingValues = {}
    parameters.pendingSpawns = parameters.count
    parameters.pendingLaunches = parameters.count
    currentRoll = parameters
    rollInProgress = true
    cacheAndRender()

    local objectType = diceType(parameters.sides)
    if not objectType then
        finishRollFailure(token, "tipo de dado não suportado.")
        return false
    end
    for index = 1, parameters.count do
        local spawnIndex = index
        local ok = pcall(function()
            spawnObject({
                type = objectType,
                position = localDicePosition(spawnIndex, parameters.count),
                rotation = {x = math.random(0, 359), y = math.random(0, 359), z = math.random(0, 359)},
                sound = true,
                callback_function = function(object) onDieSpawned(token, spawnIndex, object) end
            })
        end)
        if not ok then
            finishRollFailure(token, "não foi possível criar os dados.")
            return false
        end
    end
    local spawnTimeoutScheduled = pcall(function()
        Wait.time(function()
            if currentRoll and currentRoll.token == token and currentRoll.pendingSpawns > 0 then
                finishRollFailure(token, "a criação dos dados expirou.")
            end
        end, SPAWN_TIMEOUT_SECONDS)
    end)
    if not spawnTimeoutScheduled then
        finishRollFailure(token, "não foi possível iniciar o temporizador dos dados.")
        return false
    end
    return true
end

local function rollAttack(playerColor)
    if not canRoll(playerColor) then return false end
    local modifier = CorvanRules.calculateAttackModifier(CHARACTER, state, state.activeWeapon)
    local rollback = nil
    local consumesCombatDefensive = state.effects.combatDefensiveArmed
    local suppressesShieldGuard = state.activeWeapon == "shield"
        and not state.effects.shieldGuardSuppressed
    if consumesCombatDefensive or suppressesShieldGuard then
        -- Rollback técnico preserva o undo anterior; o novo snapshot só passa a
        -- valer se a rolagem realmente conseguir começar.
        rollback = normalizeState(state)
        pushUndo()
        if consumesCombatDefensive then state.effects.combatDefensiveArmed = false end
        if suppressesShieldGuard then state.effects.shieldGuardSuppressed = true end
    end
    return startPhysicalRoll({kind = "attack", count = 1, sides = 20, modifier = modifier,
        weaponKey = state.activeWeapon, playerColor = playerColor, rollback = rollback})
end

local function rollDamage(playerColor, critical)
    if critical and not state.pendingThreat then
        privateError(playerColor, "não há ameaça de crítico pendente.")
        return false
    end
    if not canRoll(playerColor) then return false end
    local weaponKey = critical and state.pendingThreat.weaponKey or state.activeWeapon
    local spec = CorvanRules.calculateDamageSpec(CHARACTER, state, weaponKey, critical)
    return startPhysicalRoll({kind = "damage", count = spec.count, sides = spec.sides, bonus = spec.bonus,
        critical = critical, weaponKey = weaponKey, playerColor = playerColor})
end

local function rollSkill(playerColor, skillKey)
    if not canRoll(playerColor) then return false end
    local skill = CHARACTER.skills[skillKey]
    if not skill then return false end
    return startPhysicalRoll({kind = "skill", count = 1, sides = 20,
        modifier = CorvanRules.calculateSkillModifier(CHARACTER, state, skillKey),
        label = skill.name, playerColor = playerColor})
end

local function canSpendPowerResource(playerColor, power, cost)
    if not state.automaticResourceSpending then return true end
    local resource = power and power.resource or "mp"
    local resourceLabel = resource == "hp" and "PV" or string.upper(resource)
    local amount = math.max(0, finiteNumber(cost, 0))
    if state[resource] == nil or not CHARACTER.resources[resource] then
        privateError(playerColor, "recurso do poder inválido.")
        return false
    end
    if state[resource] < amount then
        privateError(playerColor, resourceLabel .. " insuficiente.")
        return false
    end
    return true
end

local function spendPowerResource(power, cost)
    if not state.automaticResourceSpending then return end
    local resource = power and power.resource or "mp"
    state[resource] = state[resource] - math.max(0, finiteNumber(cost, 0))
end

local function activatePower(playerColor, effectKey, configKey, announcement)
    if state.effects[effectKey] then
        privateError(playerColor, "esse poder já está ativo.")
        return false
    end
    local power = CHARACTER.powers[configKey]
    local cost = finiteNumber(power and power.cost, 0)
    if not canSpendPowerResource(playerColor, power, cost) then return false end
    pushUndo()
    spendPowerResource(power, cost)
    state.effects[effectKey] = true
    cacheAndRender()
    if announcement then publicMessage(announcement, playerColor) end
    return true
end

local function activateBaluarte(playerColor)
    local power = CHARACTER.powers.baluarte
    local base = finiteNumber(power.defenseModifier, 2)
    local upgraded = finiteNumber(power.upgradedDefenseModifier, 4)
    local current = finiteNumber(state.effects.baluarte, state.effects.baluarte == true and base or 0)
    local cost
    local target
    if current <= 0 then
        cost = finiteNumber(power.cost, 1)
        target = base
    elseif current < upgraded then
        cost = finiteNumber(power.upgradeCost, 1)
        target = upgraded
    else
        privateError(playerColor, "Baluarte +4 já está ativo.")
        return false
    end
    if not canSpendPowerResource(playerColor, power, cost) then return false end
    pushUndo()
    spendPowerResource(power, cost)
    state.effects.baluarte = target
    cacheAndRender()
    return true
end

local function activateBaluarteAllies(playerColor)
    local power = CHARACTER.powers.baluarte
    local base = finiteNumber(power.defenseModifier, 2)
    local current = finiteNumber(state.effects.baluarte, state.effects.baluarte == true and base or 0)
    if current <= 0 then
        privateError(playerColor, "ative Baluarte antes de compartilhar com os aliados.")
        return false
    end
    if state.effects.baluarteShared then
        privateError(playerColor, "Baluarte já está compartilhado com os aliados adjacentes.")
        return false
    end
    local cost = finiteNumber(power.sharedCost, 2)
    if not canSpendPowerResource(playerColor, power, cost) then return false end
    pushUndo()
    spendPowerResource(power, cost)
    state.effects.baluarteShared = true
    cacheAndRender()
    publicMessage(CHARACTER.shortName .. ": Baluarte +" .. tostring(current)
        .. " compartilhado com aliados adjacentes até o próximo turno.", playerColor)
    return true
end

local function activateDuel(playerColor)
    local power = CHARACTER.powers.duel
    local base = finiteNumber(power.attackModifier, 2)
    local upgraded = finiteNumber(power.upgradedAttackModifier, 3)
    local current = duelModifier(CHARACTER, state, "upgradedAttackModifier", "attackModifier")
    local cost
    local target
    if current <= 0 then
        cost = finiteNumber(power.cost, 2)
        target = base
    elseif current < upgraded then
        cost = finiteNumber(power.upgradeCost, 1)
        target = upgraded
    else
        privateError(playerColor, "Duelo +3 já está ativo.")
        return false
    end
    if not canSpendPowerResource(playerColor, power, cost) then return false end
    pushUndo()
    spendPowerResource(power, cost)
    state.effects.duel = target
    cacheAndRender()
    return true
end

local function activateCombatDefensive(playerColor)
    if state.effects.combatDefensiveArmed or state.effects.combatDefensiveDefense then
        privateError(playerColor, "Combate Defensivo já está ativo.")
        return false
    end
    pushUndo()
    state.effects.combatDefensiveArmed = true
    state.effects.combatDefensiveDefense = true
    cacheAndRender()
    return true
end

local function storeResourceAdjustment(resource, value)
    resourceAdjustments[resource] = tostring(value or "")
    scheduleRender()
    return true
end

local function resourceAdjustmentMagnitude(resource)
    local number = finiteNumber(resourceAdjustments[resource], nil)
    if number == nil then return nil end
    number = math.abs(number)
    if number ~= math.floor(number) or number < 1 or number > 999 then return nil end
    return number
end

local function applyResourceAdjustment(playerColor, resource, direction)
    local magnitude = resourceAdjustmentMagnitude(resource)
    if magnitude == nil then
        privateError(playerColor, "informe um ajuste inteiro maior que zero (até 999).")
        scheduleRender()
        return false
    end
    local maximum = CHARACTER.resources[resource].max
    local current = state[resource]
    local target = math.floor(clamp(current + direction * magnitude, 0, maximum))
    if target ~= current then
        pushUndo()
        state[resource] = target
    end
    resourceAdjustments[resource] = ""
    cacheAndRender()
    return true
end

local function chooseWeapon(weaponKey)
    if not CHARACTER.weapons[weaponKey] or state.activeWeapon == weaponKey then return false end
    pushUndo()
    state.activeWeapon = weaponKey
    state.pendingThreat = nil
    cacheAndRender()
    return true
end

local function endTurn()
    local changed = state.effects.combatDefensiveArmed or state.effects.combatDefensiveDefense or
        state.effects.baluarte or state.effects.baluarteShared or
        state.effects.shieldGuardSuppressed or state.pendingThreat ~= nil
    if not changed then return true end
    pushUndo()
    state.effects.combatDefensiveArmed = false
    state.effects.combatDefensiveDefense = false
    state.effects.baluarte = false
    state.effects.baluarteShared = false
    state.effects.shieldGuardSuppressed = false
    state.pendingThreat = nil
    cacheAndRender()
    return true
end

local function endScene()
    local changed = state.effects.duel or state.effects.combatDefensiveArmed or
        state.effects.combatDefensiveDefense or state.effects.baluarte or state.effects.baluarteShared or
        state.effects.shieldGuardSuppressed or state.effects.provocation or state.pendingThreat ~= nil
    if not changed then return true end
    pushUndo()
    state.effects = defaultEffects()
    state.pendingThreat = nil
    cacheAndRender()
    return true
end

local function undoLast(playerColor)
    if not state.undo then
        privateError(playerColor, "não há ação para desfazer.")
        return false
    end
    local dice = state.ownedDiceGuids
    local diceOwner = state.ownedDiceOwnerGuid
    local automaticResourceSpending = state.automaticResourceSpending
    local restored = normalizeState(state.undo)
    restored.undo = nil
    restored.ownedDiceGuids = dice
    restored.ownedDiceOwnerGuid = diceOwner
    restored.automaticResourceSpending = automaticResourceSpending
    state = restored
    cacheAndRender()
    return true
end

local ID_ALIASES = {
    select_weapon_sword = "weapon_sword", weapon_espada = "weapon_sword",
    select_weapon_shield = "weapon_shield", weapon_escudo = "weapon_shield",
    attack = "roll_attack", damage = "roll_damage", critical = "roll_critical",
    skill_initiative = "skill_iniciativa", skill_fight = "skill_luta",
    skill_intimidation = "skill_intimidacao", skill_perception = "skill_percepcao",
    skill_reflex = "skill_reflexos", skill_will = "skill_vontade",
    settings_toggle = "toggle_settings", settings_test_die = "calibrate_roll",
    power_provocation = "power_provocacao"
}

local SKILL_IDS = {
    skill_iniciativa = "initiative", skill_luta = "fight", skill_intimidacao = "intimidation",
    skill_percepcao = "perception", skill_fortitude = "fortitude",
    skill_reflexos = "reflex", skill_vontade = "will", skill_cavalgar = "riding",
    skill_diplomacia = "diplomacy", skill_guerra = "warfare", skill_pontaria = "aim"
}

function handleUiEvent(payload)
    payload = type(payload) == "table" and payload or {}
    local id = tostring(payload.id or ""):lower():gsub("%-", "_"):gsub("%s+", "_")
    id = ID_ALIASES[id] or id
    local playerColor = payload.playerColor
    local value = payload.value

    if id == "weapon_sword" then return chooseWeapon("sword") end
    if id == "weapon_shield" then return chooseWeapon("shield") end
    if id == "roll_attack" then return rollAttack(playerColor) end
    if id == "roll_damage" then return rollDamage(playerColor, false) end
    if id == "roll_critical" then return rollDamage(playerColor, true) end
    if SKILL_IDS[id] then return rollSkill(playerColor, SKILL_IDS[id]) end
    if id == "power_combat_defensive" then return activateCombatDefensive(playerColor) end
    if id == "power_duel" then return activateDuel(playerColor) end
    if id == "power_baluarte" then return activateBaluarte(playerColor) end
    if id == "power_baluarte_allies" then return activateBaluarteAllies(playerColor) end
    if id == "power_provocacao" then
        local cd = CHARACTER.powers.provocation.willDifficulty
        return activatePower(playerColor, "provocation", "provocation",
            CHARACTER.shortName .. ": Provocação - Vontade CD " .. tostring(cd))
    end
    local resourceInputs = {pv_adjust = "hp", pm_adjust = "mp"}
    if resourceInputs[id] then
        return storeResourceAdjustment(resourceInputs[id], value)
    end
    local resourceButtons = {
        pv_subtract = {"hp", -1}, pv_add = {"hp", 1},
        pm_subtract = {"mp", -1}, pm_add = {"mp", 1}
    }
    if resourceButtons[id] then
        return applyResourceAdjustment(playerColor, resourceButtons[id][1], resourceButtons[id][2])
    end
    if id == "automatic_resource_spending" then
        local enabled = value == true or tostring(value):lower() == "true" or tostring(value) == "1"
        state.automaticResourceSpending = enabled
        safeParentCall("cacheRuntimeState", {state = exportState()})
        applyUi()
        return true
    end
    if id == "end_turn" then return endTurn() end
    if id == "end_scene" then return endScene() end
    if id == "undo" then return undoLast(playerColor) end
    if id == "clear_dice" then
        if rollInProgress then
            privateError(playerColor, "aguarde a rolagem atual terminar.")
            return false
        end
        clearOwnedDice()
        cacheAndRender()
        return true
    end
    if id == "toggle_settings" then
        state.settingsOpen = not state.settingsOpen
        cacheAndRender()
        return true
    end
    if id == "offset_x" or id == "offset_y" or id == "offset_z" then
        local axis = id:sub(-1)
        local number = finiteNumber(value, nil)
        if number == nil then privateError(playerColor, "offset inválido."); return false end
        if state.diceOffset[axis] ~= number then
            pushUndo()
            state.diceOffset[axis] = number
            cacheAndRender()
        end
        return true
    end
    if id == "calibrate_roll" then
        if not canRoll(playerColor) then return false end
        return startPhysicalRoll({kind = "calibration", count = 1, sides = 20, playerColor = playerColor})
    end
    if id == "reset_state" or id == "settings_reset" then
        if rollInProgress then
            privateError(playerColor, "aguarde a rolagem atual terminar.")
            return false
        end
        pushUndo()
        local previous = state.undo
        local automaticResourceSpending = state.automaticResourceSpending
        clearOwnedDice()
        state = defaultState()
        state.undo = previous
        state.automaticResourceSpending = automaticResourceSpending
        resourceAdjustments = {hp = "", mp = ""}
        cacheAndRender()
        return true
    end
    -- refresh é deliberadamente propriedade do bootstrap estável.
    if id == "refresh" or id == "settings_refresh" or id:match("^bootstrap_") then return false end
    return false
end

function exportState()
    local exported = deepCopy(state)
    exported.schemaVersion = STATE_SCHEMA_VERSION
    exported.runtimeVersion = CHARACTER.version
    exported.parentGuid = parentGuid
    exported.rollInProgress = rollInProgress
    exported.helperGuid = safeObjectGuid(self)
    return exported
end

function importState(payload)
    if rollInProgress then return false end
    if type(payload) == "string" and type(JSON) == "table" then
        local ok, decoded = pcall(function() return JSON.decode(payload) end)
        if not ok then return false end
        payload = decoded
    end
    if type(payload) ~= "table" then return false end
    if type(payload.state) == "table" then payload = payload.state end
    if finiteNumber(payload.schemaVersion, 1) > STATE_SCHEMA_VERSION then return false end
    state = normalizeState(payload)
    resourceAdjustments = {hp = "", mp = ""}
    currentRoll = nil
    rollInProgress = false
    cacheAndRender()
    return true
end

function healthCheck(_)
    return {
        ok = characterLoaded,
        version = tostring(CHARACTER.version),
        schemaVersion = STATE_SCHEMA_VERSION,
        parentGuid = parentGuid,
        rollInProgress = rollInProgress
    }
end

function getChatAudit()
    return deepCopy(chatAudit)
end

local function notifyReady()
    safeParentCall("runtimeReady", {
        parentGuid = parentGuid,
        version = CHARACTER.version,
        health = healthCheck({})
    })
end

local function persistParentNotes()
    if not self or type(self.setGMNotes) ~= "function" or type(JSON) ~= "table" then return end
    pcall(function() self.setGMNotes(JSON.encode({parentGuid = parentGuid})) end)
end

function registerParent(payload)
    if type(payload) == "string" then
        parentGuid = payload
    elseif type(payload) == "table" then
        parentGuid = payload.parentGuid or payload.guid or parentGuid
    end
    if type(parentGuid) ~= "string" or parentGuid == "" then return false end
    parent = nil
    if not resolveParent() then return false end
    persistParentNotes()
    if type(payload) == "table" and type(payload.state) == "table" then
        state = normalizeState(payload.state)
    end
    applyUi()
    cacheAndRender()
    notifyReady()
    return true
end

local function readParentNotes()
    if not self or type(self.getGMNotes) ~= "function" or type(JSON) ~= "table" then return end
    local ok, notes = pcall(function() return self.getGMNotes() end)
    if not ok or type(notes) ~= "string" or notes == "" then return end
    local decodedOk, decoded = pcall(function() return JSON.decode(notes) end)
    if decodedOk and type(decoded) == "table" and type(decoded.parentGuid) == "string" then
        parentGuid = decoded.parentGuid
    end
end

local function bindWithRetry(remaining)
    if resolveParent() then
        applyUi()
        cacheAndRender()
        notifyReady()
        return
    end
    if remaining > 0 then
        pcall(function()
            Wait.time(function() bindWithRetry(remaining - 1) end, 0.5)
        end)
    end
end

function onLoad(savedData)
    readParentNotes()
    if type(savedData) == "string" and savedData ~= "" and type(JSON) == "table" then
        local ok, decoded = pcall(function() return JSON.decode(savedData) end)
        if ok and type(decoded) == "table" then state = normalizeState(decoded.state or decoded) end
    end
    bindWithRetry(8)
end

function onSave()
    if type(JSON) ~= "table" or type(JSON.encode) ~= "function" then return "" end
    local ok, encoded = pcall(function() return JSON.encode(exportState()) end)
    return ok and encoded or ""
end
