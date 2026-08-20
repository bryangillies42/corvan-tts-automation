-- SPENTAR_RUNTIME
-- Adaptador atualizável do Spentar. Regras de personagem permanecem aqui;
-- o host físico compartilhado conhece apenas transações e grupos de dados.
local CHARACTER_ID = __CHARACTER_ID_LITERAL__
local CHARACTER_VERSION = __CHARACTER_VERSION_LITERAL__
local RUNTIME_MARKER = __RUNTIME_MARKER_LITERAL__
local UI_XML = __UI_XML_LITERAL__
local CHARACTER_JSON = __CHARACTER_JSON_LITERAL__

local STATE_SCHEMA_VERSION = 2
local RuntimeCore = CharacterRuntimeCore
local deepCopy = RuntimeCore.deepCopy
local finiteNumber = RuntimeCore.finiteNumber
local clamp = RuntimeCore.clamp
local parentGuid = nil
local CHARACTER = nil
local configurationError = nil
local state = nil
local diceHost = nil
local recentActions = {}
local SUPPORTED_DIE_SIDES = {[4]=true, [6]=true, [8]=true, [10]=true, [12]=true, [20]=true}

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

local function supportedDieSides(value, fallback)
    value = integer(value, fallback or 6)
    if SUPPORTED_DIE_SIDES[value] then return value end
    return SUPPORTED_DIE_SIDES[fallback] and fallback or 6
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
            maximized = currentState.scene.profanar == true
                and currentState.scene.profanarTargetsConfirmed == true,
            damageType = "trevas"}},
        bonus = count * 2 + intelligence,
        count = count
    }
end

function SpentarRules.damagePlan(character, currentState, spellId)
    local spell = character.spells and character.spells[spellId] or nil
    if not spell then return nil, "magia desconhecida" end
    local preparation = currentState and currentState.casting
        and currentState.casting.preparations
        and currentState.casting.preparations[spellId] or nil
    if type(preparation) ~= "table" then
        preparation = currentState and currentState.casting or {}
    end
    local damage = spell.damage or spell.baseDamage or spell.temporaryHp
    if type(damage) ~= "table" then return nil, "magia sem dados preparados" end
    local groups = {}
    local damageType = preparation.damageType or spell.damageType or damage.type
    local baseTrevas = preparation.darkness == true or damageType == "trevas"
    local profaneApplies = currentState.scene.profanar == true
        and currentState.scene.profanarTargetsConfirmed == true
    table.insert(groups, {
        id = "base", count = integer(preparation.diceCount, damage.count),
        sides = integer(preparation.diceSides, damage.sides), damageType = damageType,
        maximized = profaneApplies and baseTrevas
    })
    local released = 0
    if spell.supportsSouls == true then
        released = boundedInteger(preparation.releasedSouls, 0,
            currentState.souls.stored, 0)
    end
    if released > 0 then
        table.insert(groups, {
            id = "souls", count = released * 2, sides = 6, damageType = "trevas",
            maximized = profaneApplies
        })
    end
    return {label = spell.name, groups = groups,
        bonus = integer(preparation.bonus, damage.bonus or 0), releasedSouls = released,
        spellId = spellId, targets = boundedInteger(preparation.targets, 1, 99, 1),
        kind = type(spell.temporaryHp) == "table" and "temporary_hp" or nil}
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
    if defeated < 1 then return 0 end
    local rule = character.powers.necropotency
    local remaining = math.max(0, integer(rule.maximumTemporaryMpPerScene, 0)
        - integer(currentState.scene.necropotencyGained, 0))
    local gained = math.min(remaining, integer(rule.temporaryMpPerQualifyingCast, 2))
    currentState.scene.necropotencyGained = currentState.scene.necropotencyGained + gained
    currentState.resources.temporaryMp = currentState.resources.temporaryMp + gained
    return gained
end

local function defaultPreparation(spellId)
    local spell = CHARACTER and CHARACTER.spells and CHARACTER.spells[spellId] or {}
    local dice = spell.damage or spell.baseDamage or spell.temporaryHp or {}
    return {
        cost = integer(spell.baseCost, 0), targets = 1,
        diceCount = integer(dice.count, 0), diceSides = integer(dice.sides, 6),
        bonus = integer(dice.bonus, 0), releasedSouls = 0,
        damageType = spell.damageType or dice.type or "",
        darkness = (spell.damageType or dice.type) == "trevas",
        profaneTargets = false, effect = "", note = ""
    }
end

local function defaultPreparations()
    local result = {}
    for spellId in pairs(CHARACTER and CHARACTER.spells or {}) do
        result[spellId] = defaultPreparation(spellId)
    end
    return result
end

local function defaultCharacterState()
    return {
        resources = {hp = 20, mp = 48, temporaryHp = 0, temporaryMp = 0},
        equipment = {staffTwoHanded = true},
        scene = {
            profanar = false, connectionMode = "off", connectionCircle = 1,
            connectionPaidHp = 0, necropotencyGained = 0,
            profanarTargetsConfirmed = false, arcaneArmor = false
        },
        souls = {stored = 0},
        summons = {
            bodiesAvailable = 0, undeadCount = 0, ballisticSpirits = 0,
            ballisticDice = 2, corpsePartner = "none",
            commandUsed = {undead=false, ballistic=false}
        },
        casting = {
            spellId = "inflict_wounds", preparations = defaultPreparations(),
            draft = defaultPreparation("inflict_wounds"),
            transaction = nil, sequence = 0, phase = "configure",
            pendingResolution = nil, pendingResolutions = {}, lastUsedSpellId = nil
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
    normalized.scene.profanarTargetsConfirmed = scene.profanarTargetsConfirmed == true
    normalized.scene.arcaneArmor = scene.arcaneArmor == true
    local souls = type(candidate.souls) == "table" and candidate.souls or {}
    normalized.souls.stored = boundedInteger(souls.stored, 0, CHARACTER.resources.souls.max, 0)
    local summons = type(candidate.summons) == "table" and candidate.summons or {}
    normalized.summons.bodiesAvailable = boundedInteger(summons.bodiesAvailable, 0, 99, 0)
    normalized.summons.undeadCount = boundedInteger(summons.undeadCount, 0, 6, 0)
    normalized.summons.ballisticSpirits = boundedInteger(summons.ballisticSpirits, 0, 2, 0)
    normalized.summons.ballisticDice = boundedInteger(summons.ballisticDice, 1, 2, 2)
    if type(summons.corpsePartner) == "string" and summons.corpsePartner ~= "" then
        normalized.summons.corpsePartner = string.sub(summons.corpsePartner, 1, 80)
    end
    if type(summons.commandUsed) == "table" then
        normalized.summons.commandUsed.undead = summons.commandUsed.undead == true
        normalized.summons.commandUsed.ballistic = summons.commandUsed.ballistic == true
    elseif summons.commandUsed == true then
        -- Migração v1: o comando único bloqueava ambas as invocações.
        normalized.summons.commandUsed.undead = true
        normalized.summons.commandUsed.ballistic = true
    end
    local casting = type(candidate.casting) == "table" and candidate.casting or {}
    if CHARACTER.spells[casting.spellId] then normalized.casting.spellId = casting.spellId end
    normalized.casting.sequence = math.max(0, integer(casting.sequence, 0))
    if CHARACTER.spells[casting.lastUsedSpellId] then
        normalized.casting.lastUsedSpellId = casting.lastUsedSpellId
    end
    local savedPreparations = type(casting.preparations) == "table"
        and casting.preparations or casting.lastConfigurations
    for spellId in pairs(CHARACTER.spells) do
        local source = type(savedPreparations) == "table" and savedPreparations[spellId] or nil
        local prep = normalized.casting.preparations[spellId]
        if type(source) == "table" then
            prep.cost = boundedInteger(source.cost, 0, 99,
                CHARACTER.spells[spellId].baseCost or 0)
            prep.targets = boundedInteger(source.targets, 1,
                CHARACTER.spells[spellId].maximumTargets or 99, 1)
            prep.diceCount = boundedInteger(source.diceCount, 0, 99, prep.diceCount)
            prep.diceSides = supportedDieSides(source.diceSides, prep.diceSides)
            prep.bonus = boundedInteger(source.bonus, -999, 999, prep.bonus)
            prep.releasedSouls = boundedInteger(source.releasedSouls, 0,
                normalized.souls.stored, 0)
            prep.damageType = type(source.damageType) == "string" and source.damageType
                or prep.damageType
            if type(source.darkness) == "boolean" then prep.darkness = source.darkness end
            if type(source.profaneTargets) == "boolean" then
                prep.profaneTargets = source.profaneTargets
            end
            prep.effect = type(source.effect) == "string" and string.sub(source.effect, 1, 160) or ""
            prep.note = type(source.note) == "string" and string.sub(source.note, 1, 240) or ""
        end
    end
    -- Migração direcionada do rascunho v1 para a preparação selecionada.
    if type(casting.preparations) ~= "table" then
        local prep = normalized.casting.preparations[normalized.casting.spellId]
        prep.targets = boundedInteger(casting.targets, 1, 99, prep.targets)
        prep.releasedSouls = boundedInteger(casting.releasedSouls, 0,
            normalized.souls.stored, prep.releasedSouls)
    end
    local draftSource = type(casting.draft) == "table" and casting.draft
        or normalized.casting.preparations[normalized.casting.spellId]
    normalized.casting.draft = deepCopy(draftSource)
    local draftDefault = defaultPreparation(normalized.casting.spellId)
    normalized.casting.draft.cost = boundedInteger(draftSource.cost, 0, 99, draftDefault.cost)
    normalized.casting.draft.targets = boundedInteger(draftSource.targets, 1,
        CHARACTER.spells[normalized.casting.spellId].maximumTargets or 99, draftDefault.targets)
    normalized.casting.draft.diceCount = boundedInteger(draftSource.diceCount, 0, 99, draftDefault.diceCount)
    normalized.casting.draft.diceSides = supportedDieSides(draftSource.diceSides, draftDefault.diceSides)
    normalized.casting.draft.bonus = boundedInteger(draftSource.bonus, -999, 999, draftDefault.bonus)
    normalized.casting.draft.releasedSouls = boundedInteger(draftSource.releasedSouls, 0,
        normalized.souls.stored, draftDefault.releasedSouls)
    normalized.casting.draft.damageType = type(draftSource.damageType) == "string"
        and draftSource.damageType or draftDefault.damageType
    normalized.casting.draft.darkness = type(draftSource.darkness) == "boolean"
        and draftSource.darkness or draftDefault.darkness
    normalized.casting.draft.profaneTargets = type(draftSource.profaneTargets) == "boolean"
        and draftSource.profaneTargets or draftDefault.profaneTargets
    normalized.casting.draft.effect = type(draftSource.effect) == "string"
        and string.sub(draftSource.effect, 1, 160) or ""
    normalized.casting.draft.note = type(draftSource.note) == "string"
        and string.sub(draftSource.note, 1, 240) or ""
    -- Transações em voo não sobrevivem a reload: nenhum custo é confirmado sem resultado.
    normalized.casting.transaction = nil
    normalized.casting.phase = "configure"
    if type(casting.pendingResolution) == "table" then
        local pending = deepCopy(casting.pendingResolution)
        pending.failed = boundedInteger(pending.failed, 0, pending.targets or 99, 0)
        pending.defeated = boundedInteger(pending.defeated, 0, pending.targets or 99, 0)
        normalized.casting.pendingResolution = pending
    elseif casting.phase == "resolution" then
        -- Resoluções v1 viram pendências não bloqueantes.
        normalized.casting.pendingResolution = {
            id="legacy-" .. tostring(normalized.casting.sequence),
            spellId=normalized.casting.spellId,
            targets=normalized.casting.preparations[normalized.casting.spellId].targets,
            failed=boundedInteger(casting.failed, 0, 99, 0),
            defeated=boundedInteger(casting.defeated, 0, 99, 0)
        }
    end
    if type(casting.pendingResolutions) == "table" then
        for _, source in ipairs(casting.pendingResolutions) do
            if type(source) == "table" then
                local pending = deepCopy(source)
                pending.targets = boundedInteger(pending.targets, 1, 99, 1)
                pending.failed = boundedInteger(pending.failed, 0, pending.targets, 0)
                pending.defeated = boundedInteger(pending.defeated, 0, pending.targets, 0)
                table.insert(normalized.casting.pendingResolutions, pending)
            end
        end
    end
    if normalized.casting.pendingResolution == nil
        and #normalized.casting.pendingResolutions > 0 then
        normalized.casting.pendingResolution = table.remove(
            normalized.casting.pendingResolutions, 1)
    end
    normalized.effects = type(candidate.effects) == "table" and deepCopy(candidate.effects) or {}
    normalized.preferences.automaticResourceSpending = not (candidate.preferences
        and candidate.preferences.automaticResourceSpending == false)
    normalized.preferences.physicalDice = not (candidate.preferences
        and candidate.preferences.physicalDice == false)
    normalized.preferences.detailedChat = not (candidate.preferences
        and candidate.preferences.detailedChat == false)
    normalized.undo = type(candidate.undo) == "table" and deepCopy(candidate.undo) or {}
    while #normalized.undo > 20 do table.remove(normalized.undo, 1) end
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
local enqueueResolution

local function tableHasEntries(candidate)
    if type(candidate) ~= "table" then return false end
    for _ in pairs(candidate) do return true end
    return false
end

local function formatPlanPreview(plan)
    if type(plan) ~= "table" then return "RESOLUÇÃO GUIADA SEM DADOS" end
    local parts = {}
    for _, group in ipairs(plan.groups or {}) do
        local part = tostring(integer(group.count, 0)) .. "d" .. tostring(integer(group.sides, 0))
        if group.maximized then part = part .. " MAX" end
        table.insert(parts, part)
    end
    local bonus = integer(plan.bonus, 0)
    local formula = table.concat(parts, " + ")
    if bonus > 0 then formula = formula .. (#parts > 0 and " + " or "") .. tostring(bonus) end
    if bonus < 0 then formula = formula .. (#parts > 0 and " - " or "-") .. tostring(math.abs(bonus)) end
    return formula ~= "" and formula or "RESOLUÇÃO GUIADA SEM DADOS"
end

local function selectedPreparation()
    return state.casting.draft
end

local function preparationPlan(spellId, preparation)
    local shadow = deepCopy(state)
    shadow.casting.preparations[spellId] = deepCopy(preparation)
    shadow.scene.profanarTargetsConfirmed = preparation.profaneTargets == true
    return SpentarRules.damagePlan(CHARACTER, shadow, spellId)
end

local function quickPreview(spellId)
    if spellId == "animate_dead" then
        local shadow = deepCopy(state)
        local preparation = state.casting.preparations.animate_dead
            or defaultPreparation("animate_dead")
        shadow.scene.profanarTargetsConfirmed = preparation.profaneTargets == true
        return formatPlanPreview(SpentarRules.undeadDamagePlan(CHARACTER, shadow,
            state.summons.undeadCount))
    end
    if spellId == "ballistic_spirit" then
        local count = state.summons.ballisticSpirits * state.summons.ballisticDice
        return tostring(count) .. "d6 + "
            .. tostring(state.summons.ballisticSpirits * 7)
    end
    return formatPlanPreview(preparationPlan(spellId,
        state.casting.preparations[spellId]))
end

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
        and "PROFANAR\nATIVO" or "PREPARAR\nPROFANAR")
    safeSet("connection_value", "text", string.upper(state.scene.connectionMode)
        .. " C" .. state.scene.connectionCircle)
    safeSet("connection_circle_value", "text", state.scene.connectionCircle)
    safeSet("connection_cost", "text", "PV PAGOS NA CENA: "
        .. tostring(state.scene.connectionPaidHp))
    safeSet("undead_formula", "text", tostring(state.summons.undeadCount) .. "d6 + "
        .. tostring(state.summons.undeadCount * 2 + CHARACTER.attributes.intelligence))
    safeSet("ballistic_formula", "text", tostring(state.summons.ballisticSpirits
        * state.summons.ballisticDice) .. "d6 + "
        .. tostring(state.summons.ballisticSpirits * 7))
    safeSet("corpse_value", "text", string.upper(state.summons.corpsePartner))
    safeSet("command_value", "text", (state.summons.commandUsed.undead
        and "MORTOS: USADO" or "MORTOS: LIVRE") .. " • "
        .. (state.summons.commandUsed.ballistic and "ESPÍRITOS: USADO" or "ESPÍRITOS: LIVRE"))
    safeSet("mark_command_used", "text",
        (state.summons.commandUsed.undead and state.summons.commandUsed.ballistic)
            and "LIBERAR COMANDOS" or "MARCAR TODOS USADOS")
    safeSet("necropotency_value", "text", tostring(state.scene.necropotencyGained)
        .. "/" .. tostring(CHARACTER.resources.necropotency.max))
    safeSet("necromancy_souls_detail", "text", "+" .. tostring(state.souls.stored * 2)
        .. " DEF/RES • " .. tostring(state.souls.stored * 2) .. "d6 ao liberar")
    safeSet("version_label", "text", "v" .. CHARACTER_VERSION)
    local selectedSpell = CHARACTER.spells[state.casting.spellId]
    local preparation = selectedPreparation()
    local selectedPlan = preparationPlan(state.casting.spellId, preparation)
    safeSet("prepare_cost", "text", preparation.cost)
    safeSet("prepare_targets", "text", preparation.targets)
    safeSet("prepare_dice_count", "text", preparation.diceCount)
    safeSet("prepare_dice_sides", "text", preparation.diceSides)
    safeSet("prepare_bonus", "text", preparation.bonus)
    safeSet("prepare_souls", "text", preparation.releasedSouls)
    safeSet("prepare_note", "text", preparation.note)
    safeSet("prepare_effect", "text", preparation.effect)
    safeSet("prepare_darkness", "text", preparation.darkness and "TREVAS: SIM" or "TREVAS: NÃO")
    safeSet("prepare_profane_targets", "text", preparation.profaneTargets
        and "ALVOS NO PROFANAR: SIM" or "ALVOS NO PROFANAR: NÃO")
    safeSet("prepare_formula", "text", formatPlanPreview(selectedPlan))
    safeSet("prepare_spell_name", "text", selectedSpell.name)
    safeSet("quick_inflict_formula", "text", quickPreview("inflict_wounds"))
    safeSet("quick_arcane_bolt_formula", "text", quickPreview("arcane_bolt"))
    safeSet("quick_undead_formula", "text", quickPreview("animate_dead"))
    safeSet("quick_ballistic_formula", "text", quickPreview("ballistic_spirit"))
    local lastUsedSpellId = state.casting.lastUsedSpellId or state.casting.spellId
    local lastUsedSpell = CHARACTER.spells[lastUsedSpellId]
    local lastUsedPreparation = state.casting.preparations[lastUsedSpellId]
        or defaultPreparation(lastUsedSpellId)
    safeSet("combat_last_preparation", "text", lastUsedSpell.name .. " • "
        .. formatPlanPreview(preparationPlan(lastUsedSpellId, lastUsedPreparation)))
    safeSet("bodies_available", "text", state.summons.bodiesAvailable)
    safeSet("undead_count", "text", state.summons.undeadCount)
    safeSet("ballistic_count", "text", state.summons.ballisticSpirits)
    safeSet("ballistic_dice", "text", state.summons.ballisticDice)
    safeSet("corpse_partner", "text", state.summons.corpsePartner)
    local pending = state.casting.pendingResolution
    safeSet("pending_resolution", "active", pending and "true" or "false")
    safeSet("pending_failed", "text", pending and pending.failed or 0)
    safeSet("pending_defeated", "text", pending and pending.defeated or 0)
    safeSet("pending_summary", "text", pending and
        ((CHARACTER.spells[pending.spellId] and CHARACTER.spells[pending.spellId].name
            or "Ação") .. " • resolução opcional"
            .. (#state.casting.pendingResolutions > 0
                and " • +" .. #state.casting.pendingResolutions .. " na fila" or "")) or "")
    local phase = state.casting.phase
    local rollingDiceCount = 0
    if type(state.casting.transaction) == "table"
        and type(state.casting.transaction.plan) == "table" then
        for _, group in ipairs(state.casting.transaction.plan.groups or {}) do
            if not group.maximized then
                rollingDiceCount = rollingDiceCount + math.max(0, integer(group.count, 0))
            end
        end
    end
    safeSet("prepare_status", "text", phase == "rolling"
        and coreState.lastResult .. "\n" .. tostring(rollingDiceCount)
            .. " DADOS FÍSICOS • AGUARDANDO ESTABILIZAÇÃO"
            .. "\nRecursos serão restaurados se a rolagem falhar."
        or "PREPARO EDITÁVEL • nenhuma alteração gasta recursos")
    safeSet("prepare_preview", "text", "CD "
        .. tostring(SpentarRules.calculateSpellDifficulty(CHARACTER, state, state.casting.spellId))
        .. " • " .. tostring(selectedSpell.resistance or "SEM RESISTÊNCIA")
        .. " • " .. tostring(selectedSpell.summary or ""))
    safeSet("prepare_cost_warning", "text",
        state.preferences.automaticResourceSpending
            and "O custo será cobrado somente ao rolar ou aplicar."
            or "Gasto automático desligado.")
    safeSet("prepare_roll", "text",
        state.casting.spellId == "ballistic_spirit" and "CONJURAR"
            or (selectedPlan and "ROLAR" or "APLICAR"))
    local configuring = phase ~= "rolling"
    local canSelectSpell = configuring
    for spellId in pairs(CHARACTER.spells) do
        safeSet("prepare_select_" .. spellId, "interactable", canSelectSpell and "true" or "false")
    end
    local rolling = state.casting.transaction ~= nil or phase == "rolling"
    local canClearDice = rolling or tableHasEntries(coreState.ownedDice)
    local mutableOutsideCasting = phase ~= "rolling"
    for _, id in ipairs({"resource_hp_sub", "resource_hp_add", "resource_mp_sub",
        "resource_mp_add", "resource_temp_hp_sub", "resource_temp_hp_add",
        "resource_temp_mp_sub", "resource_temp_mp_add", "toggle_staff",
        "end_turn", "end_scene", "end_day"}) do
        safeSet(id, "interactable", mutableOutsideCasting and "true" or "false")
    end
    safeSet("toggle_profanar", "interactable", mutableOutsideCasting and "true" or "false")
    safeSet("necro_undead_roll", "interactable",
        (mutableOutsideCasting and not state.summons.commandUsed.undead) and "true" or "false")
    safeSet("necro_ballistic_roll", "interactable",
        (mutableOutsideCasting and not state.summons.commandUsed.ballistic) and "true" or "false")
    safeSet("clear_dice", "text", rolling and "CANCELAR E LIMPAR" or "LIMPAR DADOS")
    safeSet("clear_dice", "interactable", canClearDice and "true" or "false")
    safeSet("undo", "text", "DESFAZER ÚLTIMA AÇÃO")
    safeSet("undo", "interactable",
        (mutableOutsideCasting and #state.undo > 0) and "true" or "false")
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
    safeSet("settings_status", "text", "IDENTIDADE: SPENTAR • SCHEMA "
        .. tostring(STATE_SCHEMA_VERSION) .. " • ISOLADO")
    for _, page in ipairs({"combat","casting","necromancy","sheet","settings"}) do
        safeSet("page_" .. page, "active", page == coreState.page and "true" or "false")
        safeSet("nav_" .. page, "interactable",
            (phase ~= "rolling" and page ~= coreState.page) and "true" or "false")
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
    state.casting.phase = "configure"
    if transaction.plan.kind == "temporary_hp" then
        state.resources.temporaryHp = state.resources.temporaryHp + total
        coreState.lastResult = transaction.plan.label .. ": +" .. total .. " PV TEMP"
    end
    local requiresResolution = transaction.plan.kind ~= "check"
        and transaction.plan.kind ~= "direct"
        and transaction.plan.kind ~= "temporary_hp"
    if requiresResolution then
        enqueueResolution({
            id=transaction.id, spellId=transaction.plan.spellId or state.casting.spellId,
            targets=transaction.plan.targets or 1, failed=0, defeated=0,
            result=total
        })
    end
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
    if transaction and transaction.snapshot then
        local previousUndo = state.undo
        restoreSnapshot(transaction.snapshot)
        state.undo = previousUndo
    end
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
    coreState.lastResult = "ROLANDO • " .. tostring(plan.label)
    -- A página e o estado de rolagem precisam aparecer antes de qualquer dado
    -- ser criado; a transação persistida também permite rollback em save/load.
    cacheAndRender()
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
    return boundedInteger(selectedPreparation().cost, 0, 99, 0)
end

enqueueResolution = function(pending)
    if state.casting.pendingResolution == nil then
        state.casting.pendingResolution = pending
    else
        table.insert(state.casting.pendingResolutions, pending)
    end
end

local function nextPendingResolution()
    if #state.casting.pendingResolutions < 1 then return nil end
    return table.remove(state.casting.pendingResolutions, 1)
end

local function validateSelectedCast(playerColor)
    local spell = CHARACTER.spells[state.casting.spellId]
    if not spell then
        privateError("Selecione uma magia válida antes de continuar.", playerColor)
        return false
    end
    local preparation = selectedPreparation()
    if preparation.releasedSouls > state.souls.stored then
        privateError("A quantidade de almas liberadas não está mais disponível.", playerColor)
        return false
    end
    local cost = selectedSpellCost()
    if state.preferences.automaticResourceSpending
        and state.resources.mp + state.resources.temporaryMp < cost then
        privateError("PM insuficientes para esta configuração.", playerColor)
        return false
    end
    local plan = preparationPlan(state.casting.spellId, preparation)
    if plan then
        local diceCount = 0
        for _, group in ipairs(plan.groups or {}) do
            if not SUPPORTED_DIE_SIDES[integer(group.sides, 0)] then
                privateError("Use dados d4, d6, d8, d10, d12 ou d20.", playerColor)
                return false
            end
            diceCount = diceCount + math.max(0, integer(group.count, 0))
        end
        if diceCount < 1 then
            privateError("Esta configuração não possui dados para rolar.", playerColor)
            return false
        end
    end
    return true
end

local function applyPreparedEffect(spellId, preparation, playerColor)
    local spell = CHARACTER.spells[spellId]
    if not spell then return false end
    if type(spell.temporaryHp) == "table" then
        privateError("Vitalidade Fantasma precisa ser rolada para calcular os PV temporários.",
            playerColor)
        return false
    end
    local before = snapshot()
    if state.preferences.automaticResourceSpending then
        local paid = SpentarRules.spendMp(state, preparation.cost)
        if not paid then privateError("PM insuficientes.", playerColor) return false end
    end
    if preparation.releasedSouls > state.souls.stored then
        restoreSnapshot(before); privateError("Almas insuficientes.", playerColor); return false
    end
    state.souls.stored = state.souls.stored - preparation.releasedSouls
    table.insert(state.undo, before)
    while #state.undo > 20 do table.remove(state.undo, 1) end
    state.casting.sequence = state.casting.sequence + 1
    if spellId == "profane" then state.scene.profanar = true end
    if spellId == "arcane_armor" then
        state.scene.arcaneArmor = true
        state.effects.arcaneArmor = integer(spell.defenseBonus, 4)
    elseif spellId == "animate_dead" then
        local requested = boundedInteger(preparation.targets, 0, 6, 0)
        local created = math.min(requested, state.summons.bodiesAvailable)
        state.summons.undeadCount = created
        state.summons.bodiesAvailable = state.summons.bodiesAvailable - created
    elseif spellId == "ballistic_spirit" then
        state.summons.ballisticSpirits = boundedInteger(preparation.targets, 0, 2, 0)
        state.summons.ballisticDice = boundedInteger(preparation.diceCount, 1, 2, 2)
    end
    coreState.lastResult = spell.name .. ": APLICADO"
    if type(spell.resistance) == "string" then
        enqueueResolution({
            id=CHARACTER_ID .. "-" .. tostring(state.casting.sequence), spellId=spellId,
            targets=preparation.targets, failed=0, defeated=0
        })
    end
    publicMessage(CHARACTER.shortName .. " • " .. spell.name .. "  │ "
        .. (preparation.effect ~= "" and preparation.effect or spell.summary), playerColor, false)
    cacheAndRender()
    return true
end

local function beginSelectedCast(playerColor)
    local spell = CHARACTER.spells[state.casting.spellId]
    if not spell then return false end
    if state.casting.phase == "rolling" or state.casting.transaction ~= nil then
        privateError("Aguarde a rolagem atual.", playerColor)
        return false
    end
    if not validateSelectedCast(playerColor) then return false end
    local preparation = selectedPreparation()
    if state.casting.spellId == "ballistic_spirit" then
        return applyPreparedEffect(state.casting.spellId, preparation, playerColor)
    end
    local plan = preparationPlan(state.casting.spellId, preparation)
    if plan then return beginDamageRoll(plan, selectedSpellCost(), playerColor) end
    return applyPreparedEffect(state.casting.spellId, preparation, playerColor)
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
    local pending = state.casting.pendingResolution
    if type(pending) ~= "table" then return false end
    pushUndo()
    local spell = CHARACTER.spells[pending.spellId]
    if spell and integer(spell.circle, 0) > 0 and spell.school ~= "poder"
        and type(spell.resistance) == "string" and pending.failed > 0
        and state.equipment.staffTwoHanded then
        state.resources.temporaryHp = state.resources.temporaryHp
            + CHARACTER.equipment.staff.temporaryHpOnAnyFailedResistance
    end
    local captured, temporaryMp = 0, 0
    if pending.spellId == "phantom_vitality" and integer(pending.result, 0) > 0 then
        state.resources.temporaryHp = state.resources.temporaryHp + integer(pending.result, 0)
    end
    local canDefeat = spell and (type(spell.damage) == "table"
        or type(spell.baseDamage) == "table" or spell.automation == "undead")
    if canDefeat and spell.school == "necromancia" and pending.defeated > 0 then
        captured = SpentarRules.captureSouls(CHARACTER, state, pending.defeated)
        temporaryMp = SpentarRules.applyNecropotency(CHARACTER, state, pending.defeated)
    end
    coreState.lastResult = "RESOLVIDO • +" .. captured .. " ALMAS • +"
        .. temporaryMp .. " PM TEMP"
    state.casting.pendingResolution = nextPendingResolution()
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
        local previousUndo = type(characterState.undo) == "table"
            and deepCopy(characterState.undo) or {}
        characterState = pending.snapshot.character
        characterState.undo = previousUndo
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

local function selectSpellForConfiguration(spellId)
    if not CHARACTER.spells[spellId] then return false end
    if state.casting.phase == "rolling" or state.casting.transaction ~= nil then return false end
    state.casting.spellId = spellId
    state.casting.draft = deepCopy(state.casting.preparations[spellId])
    coreState.page = "casting"
    return true
end

local function beginSkillCheck(skillId, playerColor)
    if state.casting.phase == "rolling" or state.casting.transaction ~= nil then return false end
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

local function parseInputInteger(payload, minimum, maximum, label)
    local numeric = tonumber(payload.value)
    if numeric == nil or numeric ~= math.floor(numeric) or numeric < minimum or numeric > maximum then
        privateError(label .. " deve ser um inteiro entre " .. minimum .. " e " .. maximum .. ".",
            payload.playerColor)
        return nil
    end
    return numeric
end

local function nowSeconds()
    if Time ~= nil then
        local ok, value = pcall(function() return Time.time end)
        if ok and type(value) == "number" then return value end
    end
    if type(os) == "table" and type(os.clock) == "function" then
        local ok, value = pcall(os.clock)
        if ok and type(value) == "number" then return value end
    end
    return nil
end

local DEBOUNCED_ACTIONS = {
    prepare_roll=true, cast_confirm=true, prepare_apply=true,
    quick_inflict_roll=true, quick_arcane_bolt_roll=true,
    quick_undead_roll=true, quick_ballistic_roll=true,
    necro_undead_roll=true, undead_roll=true,
    necro_ballistic_roll=true, ballistic_roll=true,
    corpse_novice=true, corpse_veteran=true, calibrate_roll=true
}

local function isDuplicateAction(id, playerColor)
    if not DEBOUNCED_ACTIONS[id] then return false end
    local now = nowSeconds()
    if now == nil then return false end
    local key = tostring(playerColor or "White") .. ":" .. id
    local previous = recentActions[key]
    recentActions[key] = now
    return type(previous) == "number" and now - previous < 0.45
end

local function beginPrepared(spellId, preparation, playerColor)
    if state.casting.transaction ~= nil then return false end
    if preparation.releasedSouls > state.souls.stored then
        privateError("O preparo salvo exige mais almas do que as disponíveis.", playerColor)
        return false
    end
    if state.preferences.automaticResourceSpending
        and preparation.cost > state.resources.mp + state.resources.temporaryMp then
        privateError("PM insuficientes para o preparo salvo.", playerColor)
        return false
    end
    state.casting.lastUsedSpellId = spellId
    local plan = preparationPlan(spellId, preparation)
    if plan then return beginDamageRoll(plan, preparation.cost, playerColor) end
    return applyPreparedEffect(spellId, preparation, playerColor)
end

local function beginUndeadRoll(playerColor)
    if state.summons.commandUsed.undead then
        privateError("O comando dos mortos-vivos já foi usado nesta rodada.", playerColor)
        return false
    end
    local shadow = deepCopy(state)
    local preparation = state.casting.preparations.animate_dead
        or defaultPreparation("animate_dead")
    shadow.scene.profanarTargetsConfirmed = preparation.profaneTargets == true
    local plan = SpentarRules.undeadDamagePlan(CHARACTER, shadow, state.summons.undeadCount)
    plan.kind = "direct"
    state.casting.lastUsedSpellId = "animate_dead"
    local started = beginDamageRoll(plan, 0, playerColor)
    if started then state.summons.commandUsed.undead = true; cacheAndRender() end
    return started
end

local function beginBallisticRoll(playerColor)
    if state.summons.commandUsed.ballistic then
        privateError("O comando dos espíritos já foi usado nesta rodada.", playerColor)
        return false
    end
    local spirits = state.summons.ballisticSpirits
    local plan = {label="Espíritos Balísticos", groups={{id="ballistic",
        count=spirits * state.summons.ballisticDice, sides=6, maximized=false}},
        bonus=spirits * 7, kind="direct"}
    state.casting.lastUsedSpellId = "ballistic_spirit"
    local started = beginDamageRoll(plan, 0, playerColor)
    if started then state.summons.commandUsed.ballistic = true; cacheAndRender() end
    return started
end

function handleUiEvent(payload)
    if type(payload) ~= "table" or payload.characterId ~= CHARACTER_ID
        or payload.parentGuid ~= parentGuid or configurationError ~= nil then return false end
    local id = payload.id
    if type(id) ~= "string" then return false end
    if payload.eventId ~= nil and state.lastHandledEventId == payload.eventId then return false end
    if payload.eventId ~= nil then state.lastHandledEventId = payload.eventId end
    if payload.eventId == nil and isDuplicateAction(id, payload.playerColor) then return false end
    if state.casting.transaction ~= nil and id ~= "clear_dice" and id ~= "nav_casting" then
        privateError("Aguarde os dados ou use Limpar Dados para cancelar.", payload.playerColor)
        return false
    end
    if NAVIGATION[id] then
        coreState.page = NAVIGATION[id]
    elseif SKILL_IDS[id] then
        return beginSkillCheck(SKILL_IDS[id], payload.playerColor)
    elseif id == "toggle_staff" then
        pushUndo(); state.equipment.staffTwoHanded = not state.equipment.staffTwoHanded
    elseif id == "toggle_profanar" then
        if state.scene.profanar then pushUndo(); state.scene.profanar = false
        elseif not selectSpellForConfiguration("profane") then return false end
    elseif id == "souls_add" or id == "souls_sub" then
        pushUndo(); state.souls.stored = boundedInteger(state.souls.stored
            + (id == "souls_add" and 1 or -1), 0, CHARACTER.resources.souls.max, 0)
        state.casting.draft.releasedSouls = math.min(state.casting.draft.releasedSouls,
            state.souls.stored)
    elseif string.match(id, "^resource_.+_[as][du][db]$") then
        local mapping = {resource_hp="hp", resource_mp="mp",
            resource_temp_hp="temporaryHp", resource_temp_mp="temporaryMp"}
        local prefix, operation = string.match(id, "^(resource_.+)_(add)$")
        if not prefix then prefix, operation = string.match(id, "^(resource_.+)_(sub)$") end
        local key = mapping[prefix]
        local amount = boundedInteger(payload.value, 1, 999, 1)
        if not key or not adjustResource(key, operation == "add" and amount or -amount) then return false end
    elseif string.match(id, "^prepare_select_") or string.match(id, "^cast_select_") then
        local prefix = string.match(id, "^prepare_select_") and "prepare_select_" or "cast_select_"
        if not selectSpellForConfiguration(string.sub(id, #prefix + 1)) then return false end
    elseif id == "prepare_cost" or id == "prepare_targets" or id == "prepare_dice_count"
        or id == "prepare_dice_sides" or id == "prepare_bonus" or id == "prepare_souls" then
        local limits = {
            prepare_cost={0,99,"Custo"}, prepare_targets={1,99,"Alvos"},
            prepare_dice_count={0,99,"Quantidade de dados"},
            prepare_dice_sides={2,100,"Faces"}, prepare_bonus={-999,999,"Bônus"},
            prepare_souls={0,state.souls.stored,"Almas"}
        }
        local spec = limits[id]
        local value = parseInputInteger(payload, spec[1], spec[2], spec[3])
        if value == nil then return false end
        if id == "prepare_dice_sides" and not SUPPORTED_DIE_SIDES[value] then
            privateError("Faces deve ser 4, 6, 8, 10, 12 ou 20.", payload.playerColor)
            return false
        end
        local field = ({prepare_cost="cost", prepare_targets="targets",
            prepare_dice_count="diceCount", prepare_dice_sides="diceSides",
            prepare_bonus="bonus", prepare_souls="releasedSouls"})[id]
        state.casting.draft[field] = value
    elseif id == "prepare_note" or id == "prepare_effect" then
        local field = id == "prepare_note" and "note" or "effect"
        state.casting.draft[field] = string.sub(tostring(payload.value or ""), 1,
            field == "note" and 240 or 160)
    elseif id == "prepare_darkness" then
        state.casting.draft.darkness = not state.casting.draft.darkness
    elseif id == "prepare_profane_targets" then
        state.casting.draft.profaneTargets = not state.casting.draft.profaneTargets
    elseif id == "prepare_save" then
        pushUndo()
        state.casting.preparations[state.casting.spellId] = deepCopy(state.casting.draft)
        coreState.lastResult = "PREPARO SALVO • " .. CHARACTER.spells[state.casting.spellId].name
    elseif id == "prepare_reset" then
        state.casting.draft = defaultPreparation(state.casting.spellId)
    elseif id == "prepare_roll" or id == "cast_confirm" then
        if not validateSelectedCast(payload.playerColor) then return false end
        state.casting.lastUsedSpellId = state.casting.spellId
        return beginSelectedCast(payload.playerColor)
    elseif id == "prepare_apply" then
        state.casting.lastUsedSpellId = state.casting.spellId
        return applyPreparedEffect(state.casting.spellId, state.casting.draft, payload.playerColor)
    elseif id == "quick_inflict_edit" or id == "quick_arcane_bolt_edit"
        or id == "quick_undead_edit" or id == "quick_ballistic_edit" then
        local mapping = {quick_inflict_edit="inflict_wounds",
            quick_arcane_bolt_edit="arcane_bolt", quick_undead_edit="animate_dead",
            quick_ballistic_edit="ballistic_spirit"}
        if not selectSpellForConfiguration(mapping[id]) then return false end
    elseif id == "combat_edit_last" then
        if not selectSpellForConfiguration(state.casting.lastUsedSpellId
            or state.casting.spellId) then return false end
    elseif id == "quick_inflict_roll" or id == "quick_arcane_bolt_roll" then
        local spellId = id == "quick_inflict_roll" and "inflict_wounds" or "arcane_bolt"
        return beginPrepared(spellId, deepCopy(state.casting.preparations[spellId]), payload.playerColor)
    elseif id == "quick_undead_roll" or id == "necro_undead_roll" or id == "undead_roll" then
        return beginUndeadRoll(payload.playerColor)
    elseif id == "quick_ballistic_roll" or id == "necro_ballistic_roll" or id == "ballistic_roll" then
        return beginBallisticRoll(payload.playerColor)
    elseif id == "pending_failed" or id == "pending_defeated" then
        local pending = state.casting.pendingResolution
        if not pending then return false end
        local value = parseInputInteger(payload, 0, pending.targets or 99,
            id == "pending_failed" and "Falhas" or "Derrotados")
        if value == nil then return false end
        pending[id == "pending_failed" and "failed" or "defeated"] = value
    elseif id == "pending_apply" or id == "resolution_apply" then
        return applyResolution()
    elseif id == "pending_discard" then
        if not state.casting.pendingResolution then return false end
        state.casting.pendingResolution = nextPendingResolution()
        coreState.lastResult = "RESOLUÇÃO DESCARTADA"
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
    elseif id == "bodies_available" or id == "undead_count" or id == "ballistic_count"
        or id == "ballistic_dice" then
        local specs = {bodies_available={"bodiesAvailable",0,99},
            undead_count={"undeadCount",0,6}, ballistic_count={"ballisticSpirits",0,2},
            ballistic_dice={"ballisticDice",1,2}}
        local spec = specs[id]
        local value = parseInputInteger(payload, spec[2], spec[3], id)
        if value == nil then return false end
        pushUndo(); state.summons[spec[1]] = value
    elseif id == "corpse_partner" then
        local value = string.sub(tostring(payload.value or ""), 1, 80)
        if value == "" then value = "none" end
        pushUndo(); state.summons.corpsePartner = value
    elseif id == "undead_add" or id == "undead_sub" then
        pushUndo(); state.summons.undeadCount = boundedInteger(state.summons.undeadCount
            + (id == "undead_add" and 1 or -1), 0, 6, 0)
    elseif id == "ballistic_add" or id == "ballistic_sub" then
        pushUndo(); state.summons.ballisticSpirits = boundedInteger(state.summons.ballisticSpirits
            + (id == "ballistic_add" and 1 or -1), 0, 2, 0)
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
    elseif id == "mark_command_used" then
        pushUndo()
        local release = state.summons.commandUsed.undead
            and state.summons.commandUsed.ballistic
        state.summons.commandUsed = {undead=not release, ballistic=not release}
    elseif id == "end_turn" then
        pushUndo(); state.summons.commandUsed = {undead=false, ballistic=false}
    elseif id == "end_scene" then
        pushUndo()
        state.scene.profanar = false
        state.scene.connectionMode = "off"
        state.scene.connectionPaidHp = 0
        state.scene.necropotencyGained = 0
        state.resources.temporaryHp = 0
        state.resources.temporaryMp = 0
        state.effects = {}
        state.scene.arcaneArmor = false
        state.scene.profanarTargetsConfirmed = false
        state.summons.commandUsed = {undead=false, ballistic=false}
    elseif id == "end_day" then
        pushUndo(); state.souls.stored = 0
        state.casting.draft.releasedSouls = 0
        for _, preparation in pairs(state.casting.preparations) do
            preparation.releasedSouls = 0
        end
    elseif string.match(id, "^offset_[xyz]_[as][du][db]$") then
        local axis, operation = string.match(id, "^offset_([xyz])_(add)$")
        if not axis then axis, operation = string.match(id, "^offset_([xyz])_(sub)$") end
        if not axis then return false end
        pushUndo()
        local minimum = axis == "y" and 0.5 or -10
        coreState.diceOffset[axis] = clamp(coreState.diceOffset[axis]
            + (operation == "add" and 0.5 or -0.5), minimum, 10)
    elseif id == "calibrate_roll" then
        if state.casting.phase == "rolling" or state.casting.transaction ~= nil then return false end
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
        if state.casting.phase == "rolling" or state.casting.transaction ~= nil then return false end
        local saved = table.remove(state.undo)
        if not saved then return false end
        local remaining = state.undo
        restoreSnapshot(saved)
        state.undo = remaining
    elseif id == "clear_dice" then
        local host = createDiceHost()
        if not host or type(host.clear) ~= "function" then return false end
        if state.casting.transaction ~= nil and type(host.cancel) == "function" then
            return host.cancel("rolagem cancelada pelo jogador")
        end
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
