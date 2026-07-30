-- CORVAN_RUNTIME
-- Runtime atualizável do helper invisível. Este arquivo é empacotado pelo build:
-- os dois marcadores abaixo viram literais Lua contendo o XML e o JSON da ficha.
local UI_XML = __UI_XML_LITERAL__
local CHARACTER_JSON = __CHARACTER_JSON_LITERAL__

local STATE_SCHEMA_VERSION = 1
local ROLL_TIMEOUT_SECONDS = 15
local SPAWN_TIMEOUT_SECONDS = 4
local DICE_STABLE_FRAMES = 12
local DICE_LAUNCH_DELAY_FRAMES = 3
local LEGACY_DICE_OFFSET = {x = 0, y = 2.5, z = -5}
local function chatColor()
    -- Use the positional Color table required by the TTS message API. Named
    -- RGBA fields can emit a dev-api event without rendering in the Game tab.
    return {0.905, 0.898, 0.172}
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
    version = "0.1.6",
    name = "Corvan Duras",
    shortName = "Corvan",
    resources = {hp = {max = 55}, mp = {max = 15}},
    defense = 20,
    damageReduction = 8,
    weapons = {
        sword = {
            name = "Espada Longa", chatName = "Espada", attack = 9,
            damage = {count = 1, sides = 8, bonus = 5},
            critical = {min = 19, multiplier = 2}
        },
        shield = {
            name = "Escudo Pesado", chatName = "Escudo", attack = 9,
            damage = {count = 1, sides = 6, bonus = 5},
            critical = {min = 20, multiplier = 2}
        }
    },
    skills = {
        initiative = {name = "Iniciativa", modifier = 3},
        fight = {name = "Luta", modifier = 9},
        intimidation = {name = "Intimidação", modifier = 7},
        perception = {name = "Percepção", modifier = 3},
        fortitude = {name = "Fortitude", modifier = 9, resistance = true},
        reflex = {name = "Reflexos", modifier = 5, resistance = true},
        will = {name = "Vontade", modifier = 5, resistance = true}
    },
    powers = {
        combatDefensive = {cost = 0, attackModifier = -2, defenseModifier = 5},
        duel = {cost = 2, attackModifier = 2, damageModifier = 2},
        baluarte = {
            cost = 1, upgradeCost = 1,
            defenseModifier = 2, resistanceModifier = 2,
            upgradedDefenseModifier = 4, upgradedResistanceModifier = 4
        },
        armedTower = {cost = 1, damageModifier = 5},
        provocation = {cost = 2, willDifficulty = 13}
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

-- Funções puras expostas para um harness Lua sem depender das APIs do TTS.
CorvanRules = {}
CorvanRules.clamp = clamp

function CorvanRules.calculateAttackModifier(character, currentState, weaponKey)
    local weapon = character.weapons[weaponKey]
    if not weapon then return 0 end
    local result = finiteNumber(weapon.attack, 0)
    local effects = currentState.effects or {}
    if effects.duel then
        result = result + finiteNumber(character.powers.duel.attackModifier, 0)
    end
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
        result = result + baluarteModifier(character, currentState,
            "upgradedResistanceModifier", "resistanceModifier")
    end
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
    if effects.duel then
        bonus = bonus + finiteNumber(character.powers.duel.damageModifier, 0)
    end
    if effects.armedTower then
        bonus = bonus + finiteNumber(character.powers.armedTower.damageModifier, 0)
    end
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
        armedTower = false,
        provocation = false
    }
end

local function defaultState()
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        runtimeVersion = CHARACTER.version,
        hp = finiteNumber(CHARACTER.resources.hp.max, 55),
        mp = finiteNumber(CHARACTER.resources.mp.max, 15),
        activeWeapon = "sword",
        effects = defaultEffects(),
        pendingThreat = nil,
        undo = nil,
        diceOffset = deepCopy(CHARACTER.diceOffset or {x = 0, y = 3.2, z = 0}),
        ownedDiceGuids = {},
        lastResult = "—",
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
            if key == "baluarte" then
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
    -- Ao subir do nível 4 para o 5, personagens que estavam com o recurso
    -- cheio também recebem o novo máximo. Valores gastos/ferimentos são
    -- preservados para não curar ou restaurar PM silenciosamente.
    if CHARACTER.version == "0.1.6" and source.runtimeVersion ~= "0.1.6" then
        if finiteNumber(source.hp or source.pv, 0) == 47 then normalized.hp = 55 end
        if finiteNumber(source.mp or source.pm, 0) == 12 then normalized.mp = 15 end
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
    normalized.settingsOpen = source.settingsOpen == true
    normalized.undo = nil
    normalized.ownedDiceGuids = {}
    return normalized
end

local function normalizeState(source)
    local normalized = normalizeSnapshot(source or {}) or defaultState()
    if type(source) == "table" then
        normalized.undo = normalizeSnapshot(source.undo)
        if type(source.ownedDiceGuids) == "table" then
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
local parentGuid = nil
local parent = nil
local rollInProgress = false
local currentRoll = nil
local rollSequence = 0
local chatAudit = {}
local chatAuditSequence = 0

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

function CorvanRules.formatRollResult(label, total, count, sides, values, modifier, suffix)
    local result = tostring(label) .. " - " .. tostring(total) .. " ("
        .. formatDice(count, sides, values) .. formatModifier(modifier) .. ")"
    if type(suffix) == "string" and suffix ~= "" then
        result = result .. " • " .. suffix
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
    if state.effects.combatDefensiveArmed then table.insert(labels, "Combate Defensivo: próximo ataque") end
    if state.effects.combatDefensiveDefense then table.insert(labels, "Combate Defensivo: +5 DEF") end
    if state.effects.duel then table.insert(labels, "Duelo") end
    local baluarte = finiteNumber(state.effects.baluarte, state.effects.baluarte == true and 2 or 0)
    if baluarte > 0 then table.insert(labels, "Baluarte +" .. tostring(baluarte)) end
    if state.effects.armedTower then table.insert(labels, "Torre Armada") end
    if state.effects.provocation then table.insert(labels, "Provocação") end
    if #labels == 0 then return "Nenhum efeito ativo" end
    return table.concat(labels, " • ")
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
    safeSetAttribute("rdValue", "text", CHARACTER.damageReduction)
    safeSetAttribute("lastResult", "text", state.lastResult)
    safeSetAttribute("activeEffects", "text", effectsLabel())
    safeSetAttribute("activePowersLabel", "text", effectsLabel())
    safeSetAttribute("pvCurrent", "text", state.hp)
    safeSetAttribute("pvMax", "text", CHARACTER.resources.hp.max)
    safeSetAttribute("pmCurrent", "text", state.mp)
    safeSetAttribute("pmMax", "text", CHARACTER.resources.mp.max)
    safeSetAttribute("pv_input", "text", state.hp)
    safeSetAttribute("pm_input", "text", state.mp)
    safeSetAttribute("offset_x", "text", state.diceOffset.x)
    safeSetAttribute("offset_y", "text", state.diceOffset.y)
    safeSetAttribute("offset_z", "text", state.diceOffset.z)
    safeSetAttribute("versionLabel", "text", "v" .. tostring(CHARACTER.version))
    safeSetAttribute("settingsPanel", "active", state.settingsOpen and "true" or "false")
    safeSetAttribute("toggle_settings", "text", state.settingsOpen and "FECHAR" or "CONFIG")
    safeSetAttribute("roll_critical", "interactable", state.pendingThreat and "true" or "false")
    local baluarte = finiteNumber(state.effects.baluarte, state.effects.baluarte == true and 2 or 0)
    local baluarteText = "BALUARTE  •  1/2 PM\n+2 ou +4 DEF e resistências\naté fim do turno"
    if baluarte == 2 then
        baluarteText = "BALUARTE +2  •  ATIVO\nclique novamente: +4 (+1 PM)\naté fim do turno"
    elseif baluarte >= 4 then
        baluarteText = "BALUARTE +4  •  ATIVO\nDEF e resistências\naté fim do turno"
    end
    safeSetAttribute("power_baluarte", "text", baluarteText)
    safeSetAttribute("weapon_sword", "colors", state.activeWeapon == "sword" and "#75591D|#98752B|#4F3B13|#22222288" or "#22282E|#303A43|#151A1F|#22222288")
    safeSetAttribute("weapon_shield", "colors", state.activeWeapon == "shield" and "#75591D|#98752B|#4F3B13|#22222288" or "#22282E|#303A43|#151A1F|#22222288")
    local powerColors = {
        power_combat_defensive = state.effects.combatDefensiveArmed or state.effects.combatDefensiveDefense,
        power_duel = state.effects.duel,
        power_baluarte = state.effects.baluarte,
        power_torre_armada = state.effects.armedTower,
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
    local ok, accepted = safeParentCall("applyRuntimeUi", {xml = UI_XML, version = CHARACTER.version})
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
local function chatSafeMessage(message)
    return tostring(message):gsub("%[", "［"):gsub("%]", "］")
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

local function printToPlayerColor(color, message)
    -- No TTS real, tanto printToAll quanto Player.print podem retornar sem erro
    -- e ainda assim não inserir a linha depois de várias rolagens. A função
    -- global direcionada é a rota que efetivamente chega ao chat do cliente.
    if type(printToColor) == "function" and type(color) == "string" and color ~= "" then
        local ok = pcall(function() printToColor(message, color, chatColor()) end)
        if ok then return true, "printToColor:" .. color end
    end
    if Player ~= nil and type(color) == "string" and color ~= "" then
        local ok = pcall(function() Player[color].print(message, chatColor()) end)
        if ok then return true, "player-print:" .. color end
    end
    return false, "none"
end

local function publicMessage(message, preferredColor)
    message = chatSafeMessage(message)
    -- A rota primária passa pelo bootstrap do painel visível. O TTS pode
    -- aceitar silenciosamente chamadas de chat feitas pelo helper invisível
    -- sem inseri-las no cliente, enquanto o mesmo envio pelo painel funciona.
    local relayOk, relayAccepted = safeParentCall("relayRuntimeChat", {
        message = message,
        playerColor = preferredColor
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
            local ok, route = printToPlayerColor(color, message)
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
        local ok, failure = pcall(function() printToAll(message, chatColor()) end)
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

local function clearOwnedDice()
    for _, guid in ipairs(state.ownedDiceGuids or {}) do
        local object = nil
        if type(getObjectFromGUID) == "function" then
            local ok, found = pcall(function() return getObjectFromGUID(guid) end)
            if ok then object = found end
        end
        if object and type(destroyObject) == "function" then
            pcall(function() destroyObject(object) end)
        end
    end
    state.ownedDiceGuids = {}
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
            roll.count, roll.sides, values, roll.modifier, threat and "ameaça" or nil)
        publicMessage(CHARACTER.shortName .. ": " .. state.lastResult, roll.playerColor)
    elseif roll.kind == "skill" then
        local total = values[1] + roll.modifier
        state.lastResult = CorvanRules.formatRollResult(
            roll.label, total, roll.count, roll.sides, values, roll.modifier)
        publicMessage(CHARACTER.shortName .. ": " .. state.lastResult, roll.playerColor)
    elseif roll.kind == "damage" then
        local total = roll.bonus
        for _, value in ipairs(values) do total = total + value end
        local label = roll.critical and "Crítico" or "Dano"
        state.pendingThreat = nil
        state.lastResult = CorvanRules.formatRollResult(
            label, total, roll.count, roll.sides, values, roll.bonus)
        publicMessage(CHARACTER.shortName .. ": " .. state.lastResult, roll.playerColor)
    elseif roll.kind == "calibration" then
        state.lastResult = CorvanRules.formatRollResult(
            "Calibração", values[1], roll.count, roll.sides, values, 0)
        publicMessage(CHARACTER.shortName .. ": " .. state.lastResult, roll.playerColor)
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
    if state.effects.combatDefensiveArmed then
        -- Rollback técnico preserva o undo anterior; o novo snapshot só passa a
        -- valer se a rolagem realmente conseguir começar.
        rollback = normalizeState(state)
        pushUndo()
        state.effects.combatDefensiveArmed = false
        state.effects.combatDefensiveDefense = true
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
    local rollback = nil
    if state.effects.armedTower then
        rollback = normalizeState(state)
        pushUndo()
        state.effects.armedTower = false
    end
    return startPhysicalRoll({kind = "damage", count = spec.count, sides = spec.sides, bonus = spec.bonus,
        critical = critical, weaponKey = weaponKey, playerColor = playerColor, rollback = rollback})
end

local function rollSkill(playerColor, skillKey)
    if not canRoll(playerColor) then return false end
    local skill = CHARACTER.skills[skillKey]
    if not skill then return false end
    return startPhysicalRoll({kind = "skill", count = 1, sides = 20,
        modifier = CorvanRules.calculateSkillModifier(CHARACTER, state, skillKey),
        label = skill.name, playerColor = playerColor})
end

local function activatePower(playerColor, effectKey, configKey, announcement)
    if state.effects[effectKey] then
        privateError(playerColor, "esse poder já está ativo.")
        return false
    end
    local power = CHARACTER.powers[configKey]
    local cost = finiteNumber(power and power.cost, 0)
    if state.mp < cost then
        privateError(playerColor, "PM insuficiente.")
        return false
    end
    pushUndo()
    state.mp = state.mp - cost
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
    if state.mp < cost then
        privateError(playerColor, "PM insuficiente.")
        return false
    end
    pushUndo()
    state.mp = state.mp - cost
    state.effects.baluarte = target
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
    cacheAndRender()
    return true
end

local function changeResource(playerColor, resource, value, absolute)
    local maximum = CHARACTER.resources[resource].max
    local current = state[resource]
    local target = absolute and finiteNumber(value, nil) or current + value
    if target == nil then
        privateError(playerColor, "valor inválido.")
        return false
    end
    target = math.floor(clamp(target, 0, maximum))
    if target == current then return true end
    pushUndo()
    state[resource] = target
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
        state.effects.baluarte or state.effects.armedTower or state.effects.provocation or state.pendingThreat ~= nil
    if not changed then return true end
    pushUndo()
    state.effects.combatDefensiveArmed = false
    state.effects.combatDefensiveDefense = false
    state.effects.baluarte = false
    state.effects.armedTower = false
    state.effects.provocation = false
    state.pendingThreat = nil
    cacheAndRender()
    return true
end

local function endScene()
    local changed = state.effects.duel or state.effects.combatDefensiveArmed or
        state.effects.combatDefensiveDefense or state.effects.baluarte or
        state.effects.armedTower or state.effects.provocation or state.pendingThreat ~= nil
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
    local restored = normalizeState(state.undo)
    restored.undo = nil
    restored.ownedDiceGuids = dice
    state = restored
    cacheAndRender()
    return true
end

local ID_ALIASES = {
    select_weapon_sword = "weapon_sword", weapon_espada = "weapon_sword",
    select_weapon_shield = "weapon_shield", weapon_escudo = "weapon_shield",
    attack = "roll_attack", damage = "roll_damage", critical = "roll_critical",
    hp_minus_5 = "pv_m5", hp_minus_1 = "pv_m1", hp_plus_1 = "pv_p1", hp_plus_5 = "pv_p5",
    hp_input = "pv_input", mp_minus_5 = "pm_m5", mp_minus_1 = "pm_m1",
    mp_plus_1 = "pm_p1", mp_plus_5 = "pm_p5", mp_input = "pm_input",
    skill_initiative = "skill_iniciativa", skill_fight = "skill_luta",
    skill_intimidation = "skill_intimidacao", skill_perception = "skill_percepcao",
    skill_reflex = "skill_reflexos", skill_will = "skill_vontade",
    settings_toggle = "toggle_settings", settings_test_die = "calibrate_roll",
    power_armed_tower = "power_torre_armada", power_provocation = "power_provocacao"
}

local SKILL_IDS = {
    skill_iniciativa = "initiative", skill_luta = "fight", skill_intimidacao = "intimidation",
    skill_percepcao = "perception", skill_fortitude = "fortitude",
    skill_reflexos = "reflex", skill_vontade = "will"
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
    if id == "power_duel" then return activatePower(playerColor, "duel", "duel") end
    if id == "power_baluarte" then return activateBaluarte(playerColor) end
    if id == "power_torre_armada" then return activatePower(playerColor, "armedTower", "armedTower") end
    if id == "power_provocacao" then
        local cd = CHARACTER.powers.provocation.willDifficulty
        return activatePower(playerColor, "provocation", "provocation",
            CHARACTER.shortName .. ": Provocação - Vontade CD " .. tostring(cd))
    end
    local resourceButtons = {
        pv_m5 = {"hp", -5}, pv_m1 = {"hp", -1}, pv_p1 = {"hp", 1}, pv_p5 = {"hp", 5},
        pm_m5 = {"mp", -5}, pm_m1 = {"mp", -1}, pm_p1 = {"mp", 1}, pm_p5 = {"mp", 5}
    }
    if resourceButtons[id] then
        return changeResource(playerColor, resourceButtons[id][1], resourceButtons[id][2], false)
    end
    if id == "pv_input" then return changeResource(playerColor, "hp", value, true) end
    if id == "pm_input" then return changeResource(playerColor, "mp", value, true) end
    if id == "end_turn" then return endTurn() end
    if id == "end_scene" then return endScene() end
    if id == "undo" then return undoLast(playerColor) end
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
        pushUndo()
        local previous = state.undo
        state = defaultState()
        state.undo = previous
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
