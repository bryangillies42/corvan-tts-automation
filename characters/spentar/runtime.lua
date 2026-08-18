-- SPENTAR_RUNTIME
-- Adaptador atualizável do Spentar. Regras de personagem permanecem aqui;
-- o host físico compartilhado conhece apenas transações e grupos de dados.
local CHARACTER_ID = __CHARACTER_ID_LITERAL__
local CHARACTER_VERSION = __CHARACTER_VERSION_LITERAL__
local RUNTIME_MARKER = __RUNTIME_MARKER_LITERAL__
local UI_XML = __UI_XML_LITERAL__
local CHARACTER_JSON = __CHARACTER_JSON_LITERAL__

local STATE_SCHEMA_VERSION = 1
local RuntimeCore = CharacterRuntimeCore
local deepCopy = RuntimeCore.deepCopy
local finiteNumber = RuntimeCore.finiteNumber
local clamp = RuntimeCore.clamp
local parentGuid = nil
local CHARACTER = nil
local configurationError = nil
local state = nil
local diceHost = nil

local CONFIG = {
    characterId = CHARACTER_ID,
    runtimeVersion = CHARACTER_VERSION,
    allowLegacyIdentity = false,
    project = "corvan-tts-automation"
}
local AdapterApi = RuntimeCore.createRuntimeApi(CONFIG)

local function decodeCharacter()
    if type(JSON) ~= "table" or type(JSON.decode) ~= "function" then
        configurationError = "JSON.decode indisponível ao carregar o Spentar."
        return nil
    end
    local ok, decoded = pcall(function() return JSON.decode(CHARACTER_JSON) end)
    if not ok or type(decoded) ~= "table" or decoded.id ~= CHARACTER_ID
        or type(decoded.resources) ~= "table" or type(decoded.spells) ~= "table"
    then
        configurationError = "character.json do Spentar é inválido ou pertence a outro personagem."
        return nil
    end
    return decoded
end

CHARACTER = decodeCharacter()

local function integer(value, fallback)
    return math.floor(finiteNumber(value, fallback or 0))
end

local function boundedInteger(value, minimum, maximum, fallback)
    return math.floor(clamp(integer(value, fallback), minimum, maximum))
end

-- Funções puras, deliberadamente acessíveis ao harness MoonSharp.
SpentarRules = {}

function SpentarRules.calculateSpellDifficulty(character, currentState, spellId)
    if type(character) ~= "table" then return 0 end
    local spell = character.spells and character.spells[spellId] or nil
    local casting = character.spellcasting or {}
    local result = finiteNumber(casting.baseDifficulty, 0)
    if currentState and currentState.equipment and currentState.equipment.staffTwoHanded then
        result = result + finiteNumber(casting.staffDifficultyBonus, 0)
    end
    if spell and spell.school == "necromancia" then
        result = result + finiteNumber(casting.necromancyDifficultyBonus, 0)
    end
    return result
end

function SpentarRules.calculateDefenses(character, currentState)
    local base = character and character.defenses or {}
    local souls = currentState and currentState.souls and integer(currentState.souls.stored, 0) or 0
    local perSoul = character and character.powers and character.powers.chainFallen
        and finiteNumber(character.powers.chainFallen.defensePerSoul, 0) or 0
    local resistancePerSoul = character and character.powers and character.powers.chainFallen
        and finiteNumber(character.powers.chainFallen.resistancePerSoul, 0) or 0
    return {
        defense = finiteNumber(base.defense, 0) + souls * perSoul
            + finiteNumber(currentState and currentState.effects
                and currentState.effects.arcaneArmor, 0),
        fortitude = finiteNumber(base.fortitude, 0) + souls * resistancePerSoul,
        reflex = finiteNumber(base.reflex, 0) + souls * resistancePerSoul,
        will = finiteNumber(base.will, 0) + souls * resistancePerSoul
    }
end

function SpentarRules.spendMp(currentState, amount)
    amount = math.max(0, integer(amount, 0))
    local resources = currentState.resources
    local available = integer(resources.mp, 0) + integer(resources.temporaryMp, 0)
    if available < amount then return false, {temporary = 0, regular = 0} end
    local fromTemporary = math.min(integer(resources.temporaryMp, 0), amount)
    local fromRegular = amount - fromTemporary
    resources.temporaryMp = integer(resources.temporaryMp, 0) - fromTemporary
    resources.mp = integer(resources.mp, 0) - fromRegular
    return true, {temporary = fromTemporary, regular = fromRegular}
end

function SpentarRules.connectionCost(mode, circle)
    circle = math.max(0, integer(circle, 0))
    if mode == "doubled" then return circle * 2 end
    if mode == "normal" then return circle end
    return 0
end

function SpentarRules.undeadDamagePlan(character, currentState, count)
    count = boundedInteger(count, 0, 99, 0)
    local intelligence = character and character.attributes
        and finiteNumber(character.attributes.intelligence, 0) or 0
    return {
        label = "Mortos-vivos",
        groups = {{id = "undead", count = count, sides = 6,
            maximized = currentState.scene.profanar == true, damageType = "trevas"}},
        bonus = count * 2 + intelligence,
        count = count
    }
end

function SpentarRules.damagePlan(character, currentState, spellId)
    local spell = character.spells and character.spells[spellId] or nil
    if not spell then return nil, "magia desconhecida" end
    if spell.automation == "undead" then
        return SpentarRules.undeadDamagePlan(character, currentState,
            currentState.summons.undeadCount)
    end
    if type(spell.damage) ~= "table" then return nil, "magia sem dano automatizado" end
    local groups = {}
    local baseTrevas = spell.damageType == "trevas"
    table.insert(groups, {
        id = "base", count = integer(spell.damage.count, 0)
            + (spellId == "ballistic_spirit" and integer(currentState.casting.upgradeLevel, 0) or 0),
        sides = integer(spell.damage.sides, 0), damageType = spell.damageType,
        maximized = currentState.scene.profanar == true and baseTrevas
    })
    local released = 0
    if integer(spell.circle, 0) > 0 and spell.school ~= "poder" then
        released = boundedInteger(currentState.casting.releasedSouls, 0,
            currentState.souls.stored, 0)
    end
    if released > 0 then
        table.insert(groups, {
            id = "souls", count = released * 2, sides = 6, damageType = "trevas",
            maximized = currentState.scene.profanar == true
        })
    end
    return {label = spell.name, groups = groups,
        bonus = finiteNumber(spell.damage.bonus, 0), releasedSouls = released}
end

function SpentarRules.totalDamage(plan, rolledGroups)
    local total = integer(plan and plan.bonus, 0)
    for index, group in ipairs(plan and plan.groups or {}) do
        local rolled = rolledGroups and rolledGroups[index] or nil
        if type(rolled) == "table" and rolled.id ~= nil then
            for _, candidate in ipairs(rolledGroups) do
                if candidate.id == group.id then rolled = candidate break end
            end
        end
        if group.maximized then
            total = total + integer(group.count, 0) * integer(group.sides, 0)
        elseif type(rolled) == "table" then
            total = total + integer(rolled.total, 0)
        end
    end
    return total
end

function SpentarRules.captureSouls(character, currentState, defeated)
    defeated = math.max(0, integer(defeated, 0))
    local maximum = character.resources.souls.max
    local before = currentState.souls.stored
    currentState.souls.stored = boundedInteger(before + defeated, 0, maximum, before)
    return currentState.souls.stored - before
end

function SpentarRules.applyNecropotency(character, currentState, defeated)
    if currentState.scene.connectionMode ~= "doubled" then return 0 end
    defeated = math.max(0, integer(defeated, 0))
    local rule = character.powers.necropotency
    local remaining = math.max(0, integer(rule.maximumTemporaryMpPerScene, 0)
        - integer(currentState.scene.necropotencyGained, 0))
    local gained = math.min(remaining, defeated * integer(rule.temporaryMpPerDefeatedEnemy, 0))
    currentState.scene.necropotencyGained = currentState.scene.necropotencyGained + gained
    currentState.resources.temporaryMp = currentState.resources.temporaryMp + gained
    return gained
end

local function defaultCharacterState()
    return {
        resources = {hp = 20, mp = 48, temporaryHp = 0, temporaryMp = 0},
        equipment = {staffTwoHanded = true},
        scene = {
            profanar = false, connectionMode = "off", connectionCircle = 1,
            connectionPaidHp = 0, necropotencyGained = 0
        },
        souls = {stored = 0},
        summons = {
            undeadCount = 6, ballisticSpirits = 1,
            corpsePartner = "none", commandUsed = false
        },
        casting = {
            spellId = "inflict_wounds", upgrades = {}, upgradeLevel = 0, releasedSouls = 0,
            targets = 1, transaction = nil, sequence = 0, phase = "configure",
            failed = 0, defeated = 0, lastConfigurations = {}
        },
        effects = {},
        preferences = {
            automaticResourceSpending = true,
            physicalDice = true,
            detailedChat = true
        },
        undo = {},
        stateSchemaVersion = STATE_SCHEMA_VERSION,
        lastHandledEventId = nil
    }
end

local function defaultCoreState()
    return {
        page = "combat", diceOffset = deepCopy(CHARACTER and CHARACTER.diceOffset or {x=0,y=3.2,z=0}),
        ownedDice = {}, lastResult = "PRONTO", settingsOpen = false,
        healthStatus = "RUNTIME: PRONTO"
    }
end

local function normalizeCharacterState(candidate)
    local normalized = defaultCharacterState()
    if type(candidate) ~= "table" then return normalized end
    local resources = type(candidate.resources) == "table" and candidate.resources or {}
    normalized.resources.hp = boundedInteger(resources.hp, 0, CHARACTER.resources.hp.max, 20)
    normalized.resources.mp = boundedInteger(resources.mp, 0, CHARACTER.resources.mp.max, 48)
    normalized.resources.temporaryHp = math.max(0, integer(resources.temporaryHp, 0))
    normalized.resources.temporaryMp = boundedInteger(resources.temporaryMp, 0,
        CHARACTER.resources.necropotency.max, 0)
    local equipment = type(candidate.equipment) == "table" and candidate.equipment or {}
    normalized.equipment.staffTwoHanded = equipment.staffTwoHanded ~= false
    local scene = type(candidate.scene) == "table" and candidate.scene or {}
    normalized.scene.profanar = scene.profanar == true
    if scene.connectionMode == "normal" or scene.connectionMode == "doubled" then
        normalized.scene.connectionMode = scene.connectionMode
    end
    normalized.scene.connectionCircle = boundedInteger(scene.connectionCircle, 1,
        CHARACTER.spellcasting.maximumCircle, 1)
    normalized.scene.connectionPaidHp = math.max(0, integer(scene.connectionPaidHp, 0))
    normalized.scene.necropotencyGained = boundedInteger(scene.necropotencyGained, 0,
        CHARACTER.resources.necropotency.max, 0)
    local souls = type(candidate.souls) == "table" and candidate.souls or {}
    normalized.souls.stored = boundedInteger(souls.stored, 0, CHARACTER.resources.souls.max, 0)
    local summons = type(candidate.summons) == "table" and candidate.summons or {}
    normalized.summons.undeadCount = boundedInteger(summons.undeadCount, 0, 6, 6)
    normalized.summons.ballisticSpirits = boundedInteger(summons.ballisticSpirits, 1, 3, 1)
    if summons.corpsePartner == "novice" or summons.corpsePartner == "veteran" then
        normalized.summons.corpsePartner = summons.corpsePartner
    end
    normalized.summons.commandUsed = summons.commandUsed == true
    local casting = type(candidate.casting) == "table" and candidate.casting or {}
    if CHARACTER.spells[casting.spellId] then normalized.casting.spellId = casting.spellId end
    normalized.casting.upgrades = type(casting.upgrades) == "table" and deepCopy(casting.upgrades) or {}
    normalized.casting.upgradeLevel = boundedInteger(casting.upgradeLevel, 0, 2, 0)
    normalized.casting.releasedSouls = boundedInteger(casting.releasedSouls, 0,
        normalized.souls.stored, 0)
    normalized.casting.targets = boundedInteger(casting.targets, 1, 99, 1)
    normalized.casting.sequence = math.max(0, integer(casting.sequence, 0))
    normalized.casting.failed = boundedInteger(casting.failed, 0, normalized.casting.targets, 0)
    normalized.casting.defeated = boundedInteger(casting.defeated, 0, normalized.casting.targets, 0)
    normalized.casting.lastConfigurations = type(casting.lastConfigurations) == "table"
        and deepCopy(casting.lastConfigurations) or {}
    -- Transações em voo não sobrevivem a reload: nenhum custo é confirmado sem resultado.
    normalized.casting.transaction = nil
    normalized.casting.phase = casting.phase == "resolution" and "resolution" or "configure"
    normalized.effects = type(candidate.effects) == "table" and deepCopy(candidate.effects) or {}
    normalized.preferences.automaticResourceSpending = not (candidate.preferences
        and candidate.preferences.automaticResourceSpending == false)
    normalized.preferences.physicalDice = not (candidate.preferences
        and candidate.preferences.physicalDice == false)
    normalized.preferences.detailedChat = not (candidate.preferences
        and candidate.preferences.detailedChat == false)
    normalized.lastHandledEventId = candidate.lastHandledEventId
    return normalized
end

local function normalizeCoreState(candidate)
    local core = defaultCoreState()
    if type(candidate) ~= "table" then return core end
    local pages = {combat=true, casting=true, necromancy=true, sheet=true, settings=true}
    if pages[candidate.page] then core.page = candidate.page end
    if type(candidate.diceOffset) == "table" then
        core.diceOffset = {
            x=finiteNumber(candidate.diceOffset.x, core.diceOffset.x),
            y=finiteNumber(candidate.diceOffset.y, core.diceOffset.y),
            z=finiteNumber(candidate.diceOffset.z, core.diceOffset.z)
        }
    end
    core.ownedDice = type(candidate.ownedDice) == "table" and deepCopy(candidate.ownedDice) or {}
    core.lastResult = type(candidate.lastResult) == "string" and candidate.lastResult or "PRONTO"
    core.settingsOpen = candidate.settingsOpen == true
    core.healthStatus = type(candidate.healthStatus) == "string"
        and candidate.healthStatus or "RUNTIME: PRONTO"
    return core
end

local coreState = defaultCoreState()

local function resolveParent()
    if type(parentGuid) ~= "string" or type(getObjectFromGUID) ~= "function" then return nil end
    local ok, object = pcall(getObjectFromGUID, parentGuid)
    return ok and object or nil
end

local function parentCall(name, payload)
    local parent = resolveParent()
    if parent == nil or type(parent.call) ~= "function" then return false end
    local ok, result = pcall(function() return parent.call(name, payload) end)
    return ok and result ~= false
end

local function privateError(message, playerColor)
    return parentCall("relayRuntimePrivate", {
        characterId=CHARACTER_ID, message=tostring(message), playerColor=playerColor or "White",
        tint={0.95,0.36,0.30}
    })
end

local function publicMessage(message, playerColor, richText)
    return parentCall("relayRuntimeChat", {
        characterId=CHARACTER_ID, message=tostring(message), playerColor=playerColor,
        tint={0.92,0.94,0.97}, richText=richText == true
    })
end

local function safeSet(id, attribute, value)
    return parentCall("setRuntimeUiAttribute", {
        characterId=CHARACTER_ID, id=id, attribute=attribute, value=tostring(value or "")
    })
end

local function snapshot()
    local copy = deepCopy(state)
    copy.undo = {}
    copy.casting.transaction = nil
    return {character=copy, core=deepCopy(coreState)}
end

local function pushUndo()
    table.insert(state.undo, snapshot())
    while #state.undo > 20 do table.remove(state.undo, 1) end
end

local function cacheState()
    parentCall("cacheRuntimeState", {characterId=CHARACTER_ID, state=exportState()})
end

local formatPlan

local function render()
    if not CHARACTER or not state then return end
    local defenses = SpentarRules.calculateDefenses(CHARACTER, state)
    safeSet("resource_hp", "text", "PV " .. state.resources.hp .. "/" .. CHARACTER.resources.hp.max)
    safeSet("resource_mp", "text", "PM " .. state.resources.mp .. "/" .. CHARACTER.resources.mp.max)
    safeSet("resource_temp_hp", "text", "PV TEMP " .. state.resources.temporaryHp)
    safeSet("resource_temp_mp", "text", "PM TEMP " .. state.resources.temporaryMp)
    safeSet("souls_value", "text", "ALMAS " .. state.souls.stored .. "/" .. CHARACTER.resources.souls.max)
    safeSet("profanar_value", "text", state.scene.profanar
        and "PROFANAR: ATIVO" or "PROFANAR: INATIVO")
    safeSet("defense_value", "text", defenses.defense)
    safeSet("fortitude_value", "text", defenses.fortitude)
    safeSet("reflex_value", "text", defenses.reflex)
    safeSet("will_value", "text", defenses.will)
    safeSet("general_dc", "text", SpentarRules.calculateSpellDifficulty(CHARACTER, state, "arcane_bolt"))
    safeSet("necro_dc", "text", SpentarRules.calculateSpellDifficulty(CHARACTER, state, "inflict_wounds"))
    safeSet("toggle_staff", "text", state.equipment.staffTwoHanded
        and "CAJADO\n2 MÃOS: SIM" or "CAJADO\n2 MÃOS: NÃO")
    safeSet("toggle_profanar", "text", state.scene.profanar
        and "PROFANAR\nATIVO" or "PROFANAR\nATIVAR")
    safeSet("undead_value", "text", state.summons.undeadCount)
    safeSet("ballistic_value", "text", state.summons.ballisticSpirits)
    safeSet("connection_value", "text", string.upper(state.scene.connectionMode)
        .. " C" .. state.scene.connectionCircle)
    safeSet("connection_circle_value", "text", state.scene.connectionCircle)
    safeSet("undead_formula", "text", tostring(state.summons.undeadCount) .. "d6 + "
        .. tostring(state.summons.undeadCount * 2 + CHARACTER.attributes.intelligence))
    safeSet("ballistic_formula", "text", tostring(state.summons.ballisticSpirits) .. "d6 + "
        .. tostring(state.summons.ballisticSpirits))
    safeSet("corpse_value", "text", string.upper(state.summons.corpsePartner))
    safeSet("command_value", "text", state.summons.commandUsed and "USADO" or "DISPONÍVEL")
    safeSet("necropotency_value", "text", tostring(state.scene.necropotencyGained)
        .. "/" .. tostring(CHARACTER.resources.necropotency.max))
    safeSet("necromancy_souls_detail", "text", "+" .. tostring(state.souls.stored * 2)
        .. " DEF/RES • " .. tostring(state.souls.stored * 2) .. "d6 ao liberar")
    safeSet("version_label", "text", "v" .. CHARACTER_VERSION)
    local selectedSpell = CHARACTER.spells[state.casting.spellId]
    local selectedCost = integer(selectedSpell.baseCost, 0)
        + (state.casting.spellId == "ballistic_spirit" and state.casting.upgradeLevel * 2 or 0)
    local selectedPlan = SpentarRules.damagePlan(CHARACTER, state, state.casting.spellId)
    safeSet("cast_spell_name", "text", selectedSpell.name)
    safeSet("cast_cost", "text", tostring(selectedCost) .. " PM")
    safeSet("cast_damage", "text", selectedPlan and formatPlan(selectedPlan, nil, 0) or "RESOLUÇÃO MANUAL")
    safeSet("cast_details", "text", "CD "
        .. tostring(SpentarRules.calculateSpellDifficulty(CHARACTER, state, state.casting.spellId))
        .. " • " .. tostring(selectedSpell.summary or ""))
    safeSet("cast_upgrade_value", "text", state.casting.upgradeLevel)
    safeSet("cast_targets_value", "text", state.casting.targets)
    safeSet("cast_souls_value", "text", state.casting.releasedSouls)
    safeSet("resolution_failed_value", "text", state.casting.failed)
    safeSet("resolution_defeated_value", "text", state.casting.defeated)
    safeSet("last_result", "text", coreState.lastResult)
    safeSet("offset_x_value", "text", string.format("%.1f", coreState.diceOffset.x))
    safeSet("offset_y_value", "text", string.format("%.1f", coreState.diceOffset.y))
    safeSet("offset_z_value", "text", string.format("%.1f", coreState.diceOffset.z))
    safeSet("toggle_auto_spend", "text", "GASTO AUTOMÁTICO: "
        .. (state.preferences.automaticResourceSpending and "SIM" or "NÃO"))
    safeSet("toggle_physical_dice", "text", "DADOS FÍSICOS: "
        .. (state.preferences.physicalDice and "SIM" or "NÃO"))
    safeSet("toggle_detailed_chat", "text", "DETALHAMENTO NO CHAT: "
        .. (state.preferences.detailedChat and "SIM" or "NÃO"))
    safeSet("health_status", "text", coreState.healthStatus)
    for _, page in ipairs({"combat","casting","necromancy","sheet","settings"}) do
        safeSet("page_" .. page, "active", page == coreState.page and "true" or "false")
    end
end

local function cacheAndRender()
    cacheState()
    render()
end

local function createDiceHost()
    if diceHost ~= nil or type(TtsRuntimeHost) ~= "table" or type(TtsRuntimeHost.create) ~= "function" then
        return diceHost
    end
    diceHost = TtsRuntimeHost.create({
        characterId=CHARACTER_ID,
        characterName=CHARACTER.shortName or CHARACTER.name,
        project="corvan-tts-automation"
    }, {
        getParent=resolveParent,
        getOwnerPanelGuid=function() return parentGuid end,
        getDiceOffset=function() return coreState.diceOffset end,
        render=cacheAndRender,
        privateError=privateError
    })
    return diceHost
end

local function restoreSnapshot(saved)
    if type(saved) ~= "table" then return false end
    state = normalizeCharacterState(saved.character)
    coreState = normalizeCoreState(saved.core)
    return true
end

formatPlan = function(plan, groups, total)
    local formulas = {}
    for index, group in ipairs(plan.groups or {}) do
        local rendered
        if group.maximized then
            rendered = tostring(group.count) .. "d" .. tostring(group.sides) .. " MAX"
        else
            local result = groups and groups[index] or nil
            rendered = tostring(group.count) .. "d" .. tostring(group.sides)
            if result and type(result.values) == "table" then
                rendered = rendered .. "(" .. table.concat(result.values, ",") .. ")"
            end
        end
        table.insert(formulas, rendered)
    end
    if plan.bonus and plan.bonus ~= 0 then table.insert(formulas, "+ " .. tostring(plan.bonus)) end
    return plan.label .. "  │ RESULTADO: " .. tostring(total)
        .. "  │ CÁLCULO: " .. table.concat(formulas, " + ")
end

local function finishRoll(transaction, result)
    if not state.casting.transaction or state.casting.transaction.id ~= transaction.id then return end
    coreState.ownedDice = result and result.ownedGuids or coreState.ownedDice
    local groups = result and result.groups or {}
    local total = SpentarRules.totalDamage(transaction.plan, groups)
    table.insert(state.undo, transaction.snapshot)
    while #state.undo > 20 do table.remove(state.undo, 1) end
    coreState.lastResult = transaction.plan.label .. ": " .. total
    state.casting.transaction = nil
    state.casting.phase = transaction.plan.kind == "check" and "configure" or "resolution"
    state.casting.failed = 0
    state.casting.defeated = 0
    local rich = "[FF6464]" .. RuntimeCore.chatSafeText(CHARACTER.shortName) .. "[-] • "
        .. RuntimeCore.chatSafeText(transaction.plan.label) .. "  │ RESULTADO: [62B8FF]"
        .. tostring(total) .. "[-]"
    if state.preferences.detailedChat then
        rich = rich .. "  │ " .. RuntimeCore.chatSafeText(formatPlan(transaction.plan, groups, total))
    end
    publicMessage(rich, transaction.playerColor, true)
    cacheAndRender()
end

local function rollbackRoll(transaction, reason)
    if transaction and transaction.snapshot then restoreSnapshot(transaction.snapshot) end
    coreState.lastResult = "ROLAGEM CANCELADA"
    privateError("Rolagem cancelada; recursos e almas foram restaurados. " .. tostring(reason or ""),
        transaction and transaction.playerColor or "White")
    cacheAndRender()
end

local function beginDamageRoll(plan, cost, playerColor)
    if state.casting.transaction ~= nil then return false end
    local diceCount = 0
    for _, group in ipairs(plan.groups or {}) do diceCount = diceCount + integer(group.count, 0) end
    if diceCount < 1 then privateError("Nenhum dado configurado para esta rolagem.", playerColor) return false end
    local before = snapshot()
    if state.preferences.automaticResourceSpending then
        local paid = SpentarRules.spendMp(state, cost)
        if not paid then privateError("PM insuficientes.", playerColor) return false end
    end
    local released = integer(plan.releasedSouls, 0)
    if released > state.souls.stored then restoreSnapshot(before) return false end
    state.souls.stored = state.souls.stored - released
    state.casting.sequence = state.casting.sequence + 1
    local transaction = {
        id=CHARACTER_ID .. "-" .. tostring(state.casting.sequence), plan=deepCopy(plan),
        snapshot=before, playerColor=playerColor
    }
    state.casting.transaction = transaction
    state.casting.phase = "rolling"
    if state.preferences.physicalDice == false then
        local result = {groups={}, ownedGuids=coreState.ownedDice}
        for _, group in ipairs(plan.groups or {}) do
            local values = {}
            local total = 0
            for _ = 1, integer(group.count, 0) do
                local value = group.maximized and integer(group.sides, 0)
                    or math.random(1, integer(group.sides, 1))
                table.insert(values, value)
                total = total + value
            end
            table.insert(result.groups, {id=group.id, values=values, total=total})
        end
        finishRoll(transaction, result)
        return true
    end
    local host = createDiceHost()
    if host == nil or type(host.roll) ~= "function" then
        rollbackRoll(transaction, "host físico indisponível")
        return false
    end
    local rejectionReason = nil
    local ok, accepted = pcall(function()
        return host.roll({
            transactionId=transaction.id, playerColor=playerColor,
            groups=deepCopy(plan.groups), rollback=deepCopy(before)
        }, {
            onComplete=function(result) finishRoll(transaction, result) end,
            onRollback=function(_, reason) rollbackRoll(transaction, reason) end,
            onFailure=function(reason) rejectionReason = reason end
        })
    end)
    if not ok or accepted == false then
        rollbackRoll(transaction, ok and (rejectionReason or "host recusou a rolagem") or accepted)
        return false
    end
    cacheAndRender()
    return true
end

local function selectedSpellCost()
    local spell = CHARACTER.spells[state.casting.spellId]
    local cost = integer(spell and spell.baseCost, 0)
    for _, upgrade in pairs(state.casting.upgrades or {}) do
        if type(upgrade) == "table" then cost = cost + integer(upgrade.cost, 0) end
    end
    if state.casting.spellId == "ballistic_spirit" then
        cost = cost + state.casting.upgradeLevel * 2
    end
    return cost
end

local function beginSelectedCast(playerColor)
    local spell = CHARACTER.spells[state.casting.spellId]
    if not spell then return false end
    if state.casting.phase ~= "configure" or state.casting.transaction ~= nil then
        privateError("Conclua ou cancele a resolução atual antes de conjurar novamente.", playerColor)
        return false
    end
    if spell.automation == "toggle" and state.casting.spellId == "profane" then
        if state.scene.profanar then return false end
        pushUndo()
        if state.preferences.automaticResourceSpending then
            local paid = SpentarRules.spendMp(state, selectedSpellCost())
            if not paid then table.remove(state.undo) privateError("PM insuficientes.", playerColor) return false end
        end
        state.scene.profanar = true
        coreState.lastResult = "PROFANAR ATIVO"
        cacheAndRender()
        return true
    end
    if spell.automation == "effect" and state.casting.spellId == "arcane_armor" then
        local before = snapshot()
        if state.preferences.automaticResourceSpending then
            local paid = SpentarRules.spendMp(state, selectedSpellCost())
            if not paid then privateError("PM insuficientes.", playerColor) return false end
        end
        table.insert(state.undo, before)
        while #state.undo > 20 do table.remove(state.undo, 1) end
        state.effects.arcaneArmor = integer(spell.defenseBonus, 4)
        state.casting.phase = "resolution"
        state.casting.failed = 0
        state.casting.defeated = 0
        coreState.lastResult = spell.name .. ": +" .. state.effects.arcaneArmor .. " DEFESA"
        publicMessage(CHARACTER.shortName .. " • " .. spell.name .. "  │ +"
            .. state.effects.arcaneArmor .. " Defesa até o fim da cena.", playerColor, false)
        cacheAndRender()
        return true
    end
    local plan, reason = SpentarRules.damagePlan(CHARACTER, state, state.casting.spellId)
    if plan then return beginDamageRoll(plan, selectedSpellCost(), playerColor) end
    -- Magias de referência ainda têm custo seguro e aguardam a resolução manual.
    local before = snapshot()
    if state.preferences.automaticResourceSpending then
        local paid = SpentarRules.spendMp(state, selectedSpellCost())
        if not paid then privateError("PM insuficientes.", playerColor) return false end
    end
    table.insert(state.undo, before)
    while #state.undo > 20 do table.remove(state.undo, 1) end
    state.casting.sequence = state.casting.sequence + 1
    state.casting.phase = "resolution"
    state.casting.failed = 0
    state.casting.defeated = 0
    coreState.lastResult = spell.name .. ": RESOLUÇÃO MANUAL"
    publicMessage(CHARACTER.shortName .. " • " .. spell.name .. "  │ " .. spell.summary,
        playerColor, false)
    cacheAndRender()
    return reason ~= nil or before ~= nil
end

local function adjustResource(key, delta)
    local maximum = key == "hp" and CHARACTER.resources.hp.max
        or key == "mp" and CHARACTER.resources.mp.max
        or key == "temporaryMp" and CHARACTER.resources.necropotency.max or 9999
    local before = integer(state.resources[key], 0)
    local after = boundedInteger(before + delta, 0, maximum, before)
    if after == before then return false end
    pushUndo()
    state.resources[key] = after
    return true
end

local function selectConnection(mode)
    if mode == "off" then
        if state.scene.connectionMode == "off" then return false end
        pushUndo()
        state.scene.connectionMode = "off"
        state.scene.connectionPaidHp = 0
        return true
    end
    local desired = SpentarRules.connectionCost(mode, state.scene.connectionCircle)
    local additional = math.max(0, desired - state.scene.connectionPaidHp)
    if state.resources.hp < additional then return false end
    pushUndo()
    state.resources.hp = state.resources.hp - additional
    state.scene.connectionMode = mode
    state.scene.connectionPaidHp = math.max(state.scene.connectionPaidHp, desired)
    return true
end

local function applyResolution()
    if state.casting.phase ~= "resolution" then return false end
    pushUndo()
    local spell = CHARACTER.spells[state.casting.spellId]
    if spell and integer(spell.circle, 0) > 0 and spell.school ~= "poder"
        and type(spell.resistance) == "string" and state.casting.failed > 0
        and state.equipment.staffTwoHanded then
        state.resources.temporaryHp = state.resources.temporaryHp
            + CHARACTER.equipment.staff.temporaryHpOnAnyFailedResistance
    end
    local captured, temporaryMp = 0, 0
    local canDefeat = spell and (type(spell.damage) == "table" or spell.automation == "undead")
    if canDefeat and spell.school == "necromancia" and state.casting.defeated > 0 then
        captured = SpentarRules.captureSouls(CHARACTER, state, state.casting.defeated)
        temporaryMp = SpentarRules.applyNecropotency(CHARACTER, state, state.casting.defeated)
    end
    coreState.lastResult = "RESOLVIDO • +" .. captured .. " ALMAS • +"
        .. temporaryMp .. " PM TEMP"
    state.casting.phase = "configure"
    state.casting.failed = 0
    state.casting.defeated = 0
    state.casting.releasedSouls = 0
    cacheAndRender()
    return true
end

function exportState()
    local envelope = AdapterApi.state.envelope(state, coreState)
    envelope.schemaVersion = 1
    envelope.characterStateSchemaVersion = STATE_SCHEMA_VERSION
    envelope.parentGuid = parentGuid
    envelope.rollInProgress = diceHost ~= nil and type(diceHost.isRolling) == "function"
        and diceHost.isRolling() or false
    return envelope
end

local function acceptState(payload)
    local characterState, nextCore, stateError = AdapterApi.state.unwrap(payload)
    if stateError ~= nil then return false end
    -- Salvar/recarregar durante uma rolagem não pode confirmar um custo sem
    -- resultado. A transação persiste o snapshot anterior justamente para
    -- recuperar PM, almas e UI nesse cenário.
    local pending = type(characterState.casting) == "table"
        and characterState.casting.transaction or nil
    if type(pending) == "table" and type(pending.snapshot) == "table"
        and type(pending.snapshot.character) == "table" then
        characterState = pending.snapshot.character
        if type(pending.snapshot.core) == "table" then nextCore = pending.snapshot.core end
    end
    state = normalizeCharacterState(characterState)
    coreState = normalizeCoreState(nextCore)
    return true
end

function importState(payload)
    if type(payload) == "table" and type(payload.state) == "table" then payload = payload.state end
    if not acceptState(payload) then return false end
    cacheAndRender()
    return true
end

local NAVIGATION = {
    nav_combat="combat", nav_casting="casting", nav_necromancy="necromancy",
    nav_sheet="sheet", nav_settings="settings"
}

local SKILL_IDS = {
    skill_initiative="initiative", skill_fortitude="fortitude",
    skill_reflex="reflex", skill_will="will", skill_mysticism="mysticism",
    skill_perception="perception", skill_acrobatics="acrobatics",
    skill_knowledge="knowledge", skill_healing="healing",
    skill_investigation="investigation", skill_deception="deception",
    skill_intimidation="intimidation", skill_stealth="stealth",
    skill_survival="survival", skill_fight="fight", skill_archery="aim"
}

local function beginSkillCheck(skillId, playerColor)
    if state.casting.phase ~= "configure" or state.casting.transaction ~= nil then return false end
    local skill = CHARACTER.skills[skillId]
    if type(skill) ~= "table" then return false end
    local modifier = integer(skill.modifier, 0)
    if skillId == "fortitude" or skillId == "reflex" or skillId == "will" then
        modifier = integer(SpentarRules.calculateDefenses(CHARACTER, state)[skillId], modifier)
    end
    return beginDamageRoll({kind="check", label=skill.name,
        groups={{id="check", count=1, sides=20, maximized=false}}, bonus=modifier},
        0, playerColor)
end

function handleUiEvent(payload)
    if type(payload) ~= "table" or payload.characterId ~= CHARACTER_ID
        or payload.parentGuid ~= parentGuid or configurationError ~= nil then return false end
    local id = payload.id
    if type(id) ~= "string" then return false end
    if state.casting.transaction ~= nil and not NAVIGATION[id] then
        privateError("Aguarde a conclusão dos dados antes de alterar o estado.", payload.playerColor)
        return false
    end
    if payload.eventId ~= nil and state.lastHandledEventId == payload.eventId then return false end
    if payload.eventId ~= nil then state.lastHandledEventId = payload.eventId end
    if NAVIGATION[id] then
        coreState.page = NAVIGATION[id]
    elseif SKILL_IDS[id] then
        return beginSkillCheck(SKILL_IDS[id], payload.playerColor)
    elseif id == "toggle_staff" then
        pushUndo(); state.equipment.staffTwoHanded = not state.equipment.staffTwoHanded
    elseif id == "toggle_profanar" then
        pushUndo(); state.scene.profanar = not state.scene.profanar
    elseif id == "souls_add" or id == "souls_sub" then
        pushUndo(); state.souls.stored = boundedInteger(state.souls.stored
            + (id == "souls_add" and 1 or -1), 0, CHARACTER.resources.souls.max, 0)
        state.casting.releasedSouls = math.min(state.casting.releasedSouls, state.souls.stored)
    elseif string.match(id, "^resource_.+_[as][du][db]$") then
        local mapping = {resource_hp="hp", resource_mp="mp",
            resource_temp_hp="temporaryHp", resource_temp_mp="temporaryMp"}
        local prefix, operation = string.match(id, "^(resource_.+)_(add)$")
        if not prefix then prefix, operation = string.match(id, "^(resource_.+)_(sub)$") end
        local key = mapping[prefix]
        local amount = boundedInteger(payload.value, 1, 999, 1)
        if not key or not adjustResource(key, operation == "add" and amount or -amount) then return false end
    elseif string.match(id, "^cast_select_") then
        if state.casting.phase ~= "configure" then return false end
        local spellId = string.sub(id, #"cast_select_" + 1)
        if not CHARACTER.spells[spellId] then return false end
        state.casting.spellId = spellId
        local remembered = state.casting.lastConfigurations[spellId]
        if type(remembered) == "table" then
            state.casting.releasedSouls = boundedInteger(remembered.releasedSouls, 0, state.souls.stored, 0)
            state.casting.targets = boundedInteger(remembered.targets, 1, 99, 1)
            state.casting.upgrades = deepCopy(remembered.upgrades or {})
            state.casting.upgradeLevel = boundedInteger(remembered.upgradeLevel, 0, 2, 0)
        end
        state.casting.phase = "configure"
    elseif id == "cast_upgrade_add" or id == "cast_upgrade_sub" then
        if state.casting.spellId ~= "ballistic_spirit" then return false end
        local nextLevel = boundedInteger(state.casting.upgradeLevel
            + (id == "cast_upgrade_add" and 1 or -1), 0, 2, 0)
        if nextLevel == state.casting.upgradeLevel then return false end
        state.casting.upgradeLevel = nextLevel
    elseif id == "cast_targets_add" or id == "cast_targets_sub" then
        local spell = CHARACTER.spells[state.casting.spellId]
        local maximum = integer(spell.maximumTargets, 20)
        local nextTargets = boundedInteger(state.casting.targets
            + (id == "cast_targets_add" and 1 or -1), 1, maximum, 1)
        if nextTargets == state.casting.targets then return false end
        state.casting.targets = nextTargets
        state.casting.failed = math.min(state.casting.failed, nextTargets)
        state.casting.defeated = math.min(state.casting.defeated, nextTargets)
    elseif id == "cast_souls_add" or id == "cast_souls_sub" then
        local nextSouls = boundedInteger(state.casting.releasedSouls
            + (id == "cast_souls_add" and 1 or -1), 0, state.souls.stored, 0)
        if nextSouls == state.casting.releasedSouls then return false end
        state.casting.releasedSouls = nextSouls
    elseif id == "cast_configure" then
        if state.casting.phase ~= "configure" then return false end
        state.casting.phase = "configure"
    elseif id == "quick_arcane_bolt" or id == "quick_inflict_wounds"
        or id == "quick_animate_dead" then
        if state.casting.phase ~= "configure" then return false end
        local quickSpells = {quick_arcane_bolt="arcane_bolt",
            quick_inflict_wounds="inflict_wounds", quick_animate_dead="animate_dead"}
        state.casting.spellId = quickSpells[id]
        state.casting.phase = "configure"
        return beginSelectedCast(payload.playerColor)
    elseif id == "cast_now" or id == "cast_confirm" then
        return beginSelectedCast(payload.playerColor)
    elseif id == "resolution_failed_add" or id == "resolution_failed_sub" then
        state.casting.failed = boundedInteger(state.casting.failed
            + (id == "resolution_failed_add" and 1 or -1), 0, state.casting.targets, 0)
    elseif id == "resolution_defeated_add" or id == "resolution_defeated_sub" then
        state.casting.defeated = boundedInteger(state.casting.defeated
            + (id == "resolution_defeated_add" and 1 or -1), 0, state.casting.targets, 0)
    elseif id == "resolution_apply" then
        return applyResolution()
    elseif id == "connection_off" or id == "connection_normal" or id == "connection_doubled" then
        if not selectConnection(string.sub(id, #"connection_" + 1)) then return false end
    elseif id == "connection_circle_add" or id == "connection_circle_sub" then
        local nextCircle = boundedInteger(state.scene.connectionCircle
            + (id == "connection_circle_add" and 1 or -1), 1,
            CHARACTER.spellcasting.maximumCircle, 1)
        if nextCircle == state.scene.connectionCircle then return false end
        local previous = state.scene.connectionCircle
        local before = snapshot()
        state.scene.connectionCircle = nextCircle
        if state.scene.connectionMode ~= "off" then
            local desired = SpentarRules.connectionCost(state.scene.connectionMode, nextCircle)
            local additional = math.max(0, desired - state.scene.connectionPaidHp)
            if state.resources.hp < additional then
                state.scene.connectionCircle = previous
                return false
            end
            state.resources.hp = state.resources.hp - additional
            state.scene.connectionPaidHp = math.max(state.scene.connectionPaidHp, desired)
        end
        table.insert(state.undo, before)
    elseif id == "undead_add" or id == "undead_sub" then
        pushUndo(); state.summons.undeadCount = boundedInteger(state.summons.undeadCount
            + (id == "undead_add" and 1 or -1), 0, 6, 0)
    elseif id == "undead_roll" then
        if state.summons.commandUsed then
            privateError("O comando de invocação já foi usado nesta rodada.", payload.playerColor)
            return false
        end
        local started = beginDamageRoll(SpentarRules.undeadDamagePlan(CHARACTER, state,
            state.summons.undeadCount), 0, payload.playerColor)
        if started then state.summons.commandUsed = true; cacheAndRender() end
        return started
    elseif id == "ballistic_add" or id == "ballistic_sub" then
        pushUndo(); state.summons.ballisticSpirits = boundedInteger(state.summons.ballisticSpirits
            + (id == "ballistic_add" and 1 or -1), 1, 3, 1)
    elseif id == "ballistic_roll" then
        if state.summons.commandUsed then
            privateError("O comando de invocação já foi usado nesta rodada.", payload.playerColor)
            return false
        end
        local plan = {label="Espíritos Balísticos", groups={{id="ballistic",
            count=state.summons.ballisticSpirits, sides=6, maximized=false}},
            bonus=state.summons.ballisticSpirits}
        local started = beginDamageRoll(plan, 0, payload.playerColor)
        if started then state.summons.commandUsed = true; cacheAndRender() end
        return started
    elseif id == "corpse_none" or id == "corpse_novice" or id == "corpse_veteran" then
        local nextPartner = string.sub(id, #"corpse_" + 1)
        if nextPartner == state.summons.corpsePartner then return false end
        local before = snapshot()
        if nextPartner ~= "none" and state.preferences.automaticResourceSpending then
            local cost = nextPartner == "veteran"
                and CHARACTER.powers.animateCorpse.veteranCost
                or CHARACTER.powers.animateCorpse.noviceCost
            local paid = SpentarRules.spendMp(state, cost)
            if not paid then privateError("PM insuficientes para Animar Cadáver.", payload.playerColor) return false end
        end
        table.insert(state.undo, before)
        while #state.undo > 20 do table.remove(state.undo, 1) end
        state.summons.corpsePartner = nextPartner
    elseif id == "end_turn" then
        pushUndo(); state.summons.commandUsed = false
    elseif id == "end_scene" then
        pushUndo()
        state.scene.profanar = false
        state.scene.connectionMode = "off"
        state.scene.connectionPaidHp = 0
        state.scene.necropotencyGained = 0
        state.resources.temporaryHp = 0
        state.resources.temporaryMp = 0
        state.effects = {}
        state.summons.commandUsed = false
    elseif id == "end_day" then
        pushUndo(); state.souls.stored = 0; state.casting.releasedSouls = 0
    elseif string.match(id, "^offset_[xyz]_[as][du][db]$") then
        local axis, operation = string.match(id, "^offset_([xyz])_(add)$")
        if not axis then axis, operation = string.match(id, "^offset_([xyz])_(sub)$") end
        if not axis then return false end
        pushUndo()
        local minimum = axis == "y" and 0.5 or -10
        coreState.diceOffset[axis] = clamp(coreState.diceOffset[axis]
            + (operation == "add" and 0.5 or -0.5), minimum, 10)
    elseif id == "calibrate_roll" then
        if state.casting.phase ~= "configure" or state.casting.transaction ~= nil then return false end
        return beginDamageRoll({kind="check", label="Calibração",
            groups={{id="calibration", count=1, sides=20, maximized=false}}, bonus=0},
            0, payload.playerColor)
    elseif id == "toggle_auto_spend" then
        pushUndo()
        state.preferences.automaticResourceSpending = not state.preferences.automaticResourceSpending
    elseif id == "toggle_physical_dice" then
        if state.casting.transaction ~= nil then return false end
        pushUndo(); state.preferences.physicalDice = not state.preferences.physicalDice
    elseif id == "toggle_detailed_chat" then
        pushUndo(); state.preferences.detailedChat = not state.preferences.detailedChat
    elseif id == "health_check" then
        local health = healthCheck({})
        coreState.healthStatus = health.ok and "RUNTIME: OK • SPENTAR v" .. CHARACTER_VERSION
            or "RUNTIME: ERRO • " .. tostring(health.error or "desconhecido")
        coreState.lastResult = coreState.healthStatus
    elseif id == "undo" then
        local saved = table.remove(state.undo)
        if not saved then return false end
        local remaining = state.undo
        restoreSnapshot(saved)
        state.undo = remaining
    elseif id == "clear_dice" then
        local host = createDiceHost()
        if not host or type(host.clear) ~= "function" then return false end
        local ok, result = pcall(function() return host.clear(coreState.ownedDice) end)
        if not ok or result == false then return false end
        coreState.ownedDice = {}
    elseif id == "reset_state" then
        local host = createDiceHost()
        if not host or type(host.clear) ~= "function" then return false end
        local cleared, result = pcall(function() return host.clear(coreState.ownedDice) end)
        if not cleared or result == false then return false end
        pushUndo()
        local undo = state.undo
        state = defaultCharacterState()
        state.undo = undo
        coreState = defaultCoreState()
    elseif id == "refresh" or string.match(id, "^bootstrap_") then
        return false
    else
        return false
    end
    state.casting.lastConfigurations[state.casting.spellId] = {
        releasedSouls=state.casting.releasedSouls, targets=state.casting.targets,
        upgrades=deepCopy(state.casting.upgrades), upgradeLevel=state.casting.upgradeLevel
    }
    cacheAndRender()
    return true
end

function healthCheck(_)
    return {
        ok = configurationError == nil and CHARACTER ~= nil,
        characterId = CHARACTER_ID,
        runtimeMarker = RUNTIME_MARKER,
        version = CHARACTER_VERSION,
        parentGuid = parentGuid,
        rollInProgress = diceHost ~= nil and type(diceHost.isRolling) == "function"
            and diceHost.isRolling() or false,
        stateSchemaVersion = STATE_SCHEMA_VERSION,
        error = configurationError
    }
end

function registerParent(payload)
    if type(payload) ~= "table" or payload.characterId ~= CHARACTER_ID
        or configurationError ~= nil then return false end
    parentGuid = payload.parentGuid
    if type(parentGuid) ~= "string" or parentGuid == "" then return false end
    if type(payload.state) == "table" and not acceptState(payload.state) then return false end
    createDiceHost()
    parentCall("applyRuntimeUi", {xml=UI_XML, characterId=CHARACTER_ID, version=CHARACTER_VERSION})
    cacheAndRender()
    parentCall("runtimeReady", {
        characterId=CHARACTER_ID, version=CHARACTER_VERSION, parentGuid=parentGuid,
        health=healthCheck({})
    })
    return true
end

function onLoad(savedData)
    state = defaultCharacterState()
    coreState = defaultCoreState()
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
coreState = defaultCoreState()
