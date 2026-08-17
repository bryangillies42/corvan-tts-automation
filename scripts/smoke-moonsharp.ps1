$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$candidateDlls = @()
if (${env:ProgramFiles(x86)}) {
    $candidateDlls += Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\Tabletop Simulator\Tabletop Simulator_Data\Managed\MoonSharp.Interpreter.dll'
}
if ($env:ProgramFiles) {
    $candidateDlls += Join-Path $env:ProgramFiles 'Steam\steamapps\common\Tabletop Simulator\Tabletop Simulator_Data\Managed\MoonSharp.Interpreter.dll'
}

$moonSharpDll = $candidateDlls | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $moonSharpDll) {
    throw 'MoonSharp.Interpreter.dll não encontrado na instalação padrão do Tabletop Simulator.'
}

& node (Join-Path $projectRoot 'scripts\build.mjs')
if ($LASTEXITCODE -ne 0) {
    throw 'O build falhou antes do smoke Lua.'
}

Add-Type -Path $moonSharpDll
$panelUiAsset = Join-Path $projectRoot 'assets\panel-board-ui.jpg'
if (-not (Test-Path -LiteralPath $panelUiAsset)) {
    throw 'Asset otimizado da moldura não foi encontrado.'
}
Add-Type -AssemblyName System.Drawing
$panelUiImage = [System.Drawing.Image]::FromFile($panelUiAsset)
try {
    if ($panelUiImage.Width -ne 1600 -or $panelUiImage.Height -ne 720) {
        throw "A moldura otimizada possui $($panelUiImage.Width)x$($panelUiImage.Height); esperado 1600x720."
    }
} finally {
    $panelUiImage.Dispose()
}
$panelUiSize = (Get-Item -LiteralPath $panelUiAsset).Length
if ($panelUiSize -gt 180KB) {
    throw "A moldura otimizada possui $panelUiSize bytes; esperado no máximo 180 KB."
}
$runtime = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\corvan-runtime.lua')
$savedObject = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\Corvan_Duras_Console.json') | ConvertFrom-Json
$manifest = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\manifest.json') | ConvertFrom-Json
$bootstrap = $savedObject.ObjectStates[0].LuaScript

$compiler = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$null = $compiler.LoadString($runtime)
$null = $compiler.LoadString($bootstrap)

$rulesHarness = @'
local character = {
    defense = 24,
    damageReduction = 8,
    weapons = {
        sword = {
            attack = 13,
            damage = {count = 1, sides = 8, bonus = 5},
            critical = {min = 18, multiplier = 2}
        },
        shield = {defenseModifier = 4}
    },
    skills = {fortitude = {modifier = 15, resistance = true}},
    powers = {
        duel = {
            attackModifier = 2, damageModifier = 2,
            upgradedAttackModifier = 3, upgradedDamageModifier = 3
        },
        combatDefensive = {attackModifier = -2, defenseModifier = 5},
        baluarte = {defenseModifier = 2, resistanceModifier = 2},
        solidity = {resistanceModifier = 4},
        duelistShielded = {damageReduction = 2, upgradedDamageReduction = 3}
    }
}
local state = {
    effects = {
        duel = 3,
        combatDefensiveArmed = true,
        combatDefensiveDefense = true,
        baluarte = 4,
        shieldGuardSuppressed = true
    }
}
assert(CorvanRules.formatRollResult('Iniciativa', 10, 1, 20, {7}, 3) ==
    'Iniciativa - 10 (d20[7] + 3)')
assert(CorvanRules.formatRollResult('Espada', 10, 1, 20, {12}, -2) ==
    'Espada - 10 (d20[12] - 2)')
assert(CorvanRules.formatRollResult('Escudo', 21, 1, 20, {13}, 8) ==
    'Escudo - 21 (d20[13] + 8)')
assert(CorvanRules.formatRollResult('Crítico', 13, 2, 8, {6, 3}, 4) ==
    'Crítico - 13 (2d8[6,3] + 4)')
assert(CorvanRules.formatChatRollResult('Corvan', 'Iniciativa', 10, 1, 20, {7}, 3) ==
    '[FF6464]Corvan[-] • Iniciativa  │ RESULTADO: [62B8FF]10[-]  │ CÁLCULO: d20(7) + 3')
for _ = 1, 100 do
    for face = 1, 20 do
        local message = CorvanRules.formatChatRollResult(
            'Corvan', 'Espada', face + 13, 1, 20, {face}, 13,
            face >= 18 and 'CRÍTICO' or nil)
        local withoutAllowedTags = message
            :gsub('%[FF6464%]', ''):gsub('%[62B8FF%]', ''):gsub('%[%-%]', '')
        assert(not string.find(withoutAllowedTags, '[', 1, true)
            and not string.find(withoutAllowedTags, ']', 1, true))
        assert(string.find(message, 'd20(' .. tostring(face) .. ')', 1, true))
        local _, redTags = string.gsub(message, '%[FF6464%]', '')
        local _, blueTags = string.gsub(message, '%[62B8FF%]', '')
        local _, closingTags = string.gsub(message, '%[%-%]', '')
        assert(redTags == (face >= 18 and 2 or 1))
        assert(blueTags == 1 and closingTags == redTags + blueTags)
    end
end
local damage = CorvanRules.calculateDamageSpec(character, state, 'sword', true)
return CorvanRules.calculateAttackModifier(character, state, 'sword'),
    CorvanRules.calculateDefense(character, state),
    CorvanRules.calculateSkillModifier(character, state, 'fortitude'),
    CorvanRules.calculateDamageReduction(character, state),
    damage.count, damage.sides, damage.bonus,
    CorvanRules.isThreat(character, 'sword', 18)
'@

$runner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$actual = $runner.DoString($runtime + "`n" + $rulesHarness).ToString()
$expected = '14, 29, 15, 11, 2, 8, 8, true'
if ($actual -ne $expected) {
    throw "Smoke de regras retornou '$actual'; esperado '$expected'."
}

$runtimeFlowHarness = @'
local attributes = {}
local publicChat = {}
local spectatorChat = {}
local publicChatTints = {}
local publicChatRichText = {}
local privateChat = {}
local diceByGuid = {}
local dieValues = {}
local dieSequence = 0
local parentObject = nil
local globalChatCalls = 0
local panelPosition = {x = 20, y = 1, z = 30}
local spawnPositions = {}
local launchCalls = 0
local torqueCalls = 0
local velocityFallbackCalls = 0
local angularFallbackCalls = 0
local appliedVelocities = {}
local frameCalls = 0
local panelPhysicalImage = 'legacy-panel.png'
local customObjectInspectionFails = false
local appliedUiXml = nil
local panelArtRequestFails = false
local panelArtRequests = 0

local function expectedPublicRoll(label, total, formula)
    return '[FF6464]Corvan[-] • ' .. label .. '  │ RESULTADO: [62B8FF]'
        .. tostring(total) .. '[-]'
        .. '  │ CÁLCULO: ' .. formula
end

WebRequest = {
    get = function(url, callback)
        assert(url == PANEL_UI_IMAGE_URL)
        panelArtRequests = panelArtRequests + 1
        callback({is_error = panelArtRequestFails, response_code = panelArtRequestFails and 0 or 200})
    end
}

JSON = {
    encode = function(value)
        if type(value) == 'table' and value.kind == 'owned-die' then
            return 'owned-die|' .. tostring(value.ownerPanelGuid)
        end
        return '{}'
    end,
    decode = function(value)
        local owner = type(value) == 'string' and string.match(value, '^owned%-die|(.+)$') or nil
        if owner then
            return {project = 'corvan-tts-automation', kind = 'owned-die', ownerPanelGuid = owner}
        end
        return {}
    end
}

print = function(message) table.insert(publicChat, message) end

local whitePlayer = {
    steam_id = 'steam-white',
    color = 'White',
    print = function(message, _) table.insert(publicChat, message) end
}
local greyPlayer = {
    steam_id = 'steam-grey',
    color = 'Grey',
    print = function(message, _) table.insert(spectatorChat, message) end
}
Player = {
    getPlayers = function() return {whitePlayer} end,
    -- White aparece de novo para provar que a entrega é deduplicada.
    getSpectators = function() return {greyPlayer, whitePlayer} end
}

parentObject = {
    positionToWorld = function(position)
        return {
            x = panelPosition.x + position.x,
            y = panelPosition.y + position.y,
            z = panelPosition.z + position.z
        }
    end,
    getPosition = function() return panelPosition end,
    getCustomObject = function()
        if customObjectInspectionFails then error('custom object unavailable') end
        return {image = panelPhysicalImage}
    end,
    call = function(name, payload)
        if name == 'setRuntimeUiAttribute' then
            attributes[payload.id] = payload.value
        elseif name == 'applyRuntimeUi' then
            appliedUiXml = payload.xml
        elseif name == 'relayRuntimeChat' then
            table.insert(publicChat, payload.message)
            table.insert(spectatorChat, payload.message)
            table.insert(publicChatTints, payload.tint)
            table.insert(publicChatRichText, payload.richText)
        elseif name == 'relayRuntimePrivate' then
            table.insert(privateChat, payload.message)
        end
        return true
    end
}
self = {
    getGUID = function() return 'helper1' end
}
getObjectFromGUID = function(guid)
    if guid == 'panel1' or guid == 'panel-copy' then return parentObject end
    return diceByGuid[guid]
end
destroyObject = function(object)
    diceByGuid[object.getGUID()] = nil
end
printToAll = function(message, _)
    globalChatCalls = globalChatCalls + 1
    table.insert(publicChat, message)
end
printToColor = function(message, color, _)
    if string.sub(message, 1, 10) == 'Corvan •' then
        if color == 'White' then
            table.insert(publicChat, message)
        elseif color == 'Grey' then
            table.insert(spectatorChat, message)
        else
            error('unexpected public chat color: ' .. tostring(color))
        end
    else
        table.insert(privateChat, message)
    end
end
Wait = {
    condition = function(callback, condition, _, timeout)
        if condition() then error('runtime accepted initial resting face before motion') end
        for _, die in pairs(diceByGuid) do die.resting = false end
        if condition() then error('runtime accepted a die that is still moving') end
        for _, die in pairs(diceByGuid) do die.resting = true end
        local stable = false
        for _ = 1, 60 do
            if condition() then stable = true; break end
        end
        if stable then callback() elseif timeout then timeout() end
    end,
    time = function(callback, _) callback() end,
    frames = function(callback, frames)
        assert(frames == 3)
        frameCalls = frameCalls + 1
        callback()
    end
}
spawnObject = function(params)
    dieSequence = dieSequence + 1
    local guid = 'die' .. tostring(dieSequence)
    local value = table.remove(dieValues, 1)
    table.insert(spawnPositions, params.position)
    local notes = ''
    local die = {
        resting = true,
        getGUID = function() return guid end,
        getGMNotes = function() return notes end,
        setGMNotes = function(value) notes = value end,
        setName = function(_) end,
        roll = function() end,
        setVelocity = function(force)
            assert(force.y >= DICE_VERTICAL_SPEED_MIN and force.y <= DICE_VERTICAL_SPEED_MAX)
            if guid == 'die3' then error('simulated setVelocity failure') end
            table.insert(appliedVelocities, force)
            velocityFallbackCalls = velocityFallbackCalls + 1
        end,
        addForce = function(force, forceType)
            assert(guid == 'die3' and forceType == 4)
            assert(force.y >= DICE_VERTICAL_SPEED_MIN and force.y <= DICE_VERTICAL_SPEED_MAX)
            table.insert(appliedVelocities, force)
            launchCalls = launchCalls + 1
        end,
        setAngularVelocity = function(torque)
            assert(torque.x ~= nil and torque.y ~= nil and torque.z ~= nil)
            if guid == 'die4' then error('simulated setAngularVelocity failure') end
            angularFallbackCalls = angularFallbackCalls + 1
        end,
        addTorque = function(torque, forceType)
            assert(guid == 'die4' and forceType == 4)
            assert(torque.x ~= nil and torque.y ~= nil and torque.z ~= nil)
            torqueCalls = torqueCalls + 1
        end,
        getRotationValue = function() return value end
    }
    diceByGuid[guid] = die
    params.callback_function(die)
end

assert(registerParent({parentGuid = 'panel1'}))
assert(randomRange(DICE_VERTICAL_SPEED_MIN, DICE_VERTICAL_SPEED_MAX, 0) == 13.5)
assert(randomRange(DICE_VERTICAL_SPEED_MIN, DICE_VERTICAL_SPEED_MAX, 0.5) == 16)
assert(randomRange(DICE_VERTICAL_SPEED_MIN, DICE_VERTICAL_SPEED_MAX, 1) == 18.5)
assert(string.find(appliedUiXml, 'id="panelBoardArt" active="false"', 1, true),
    'legacy panel did not start with safe inactive UI art')
assert(attributes.panelBoardArt == 'true')
panelPhysicalImage = PANEL_IMAGE_URL
assert(registerParent({parentGuid = 'panel1'}))
assert(string.find(appliedUiXml, 'id="panelBoardArt" active="false"', 1, true),
    'current physical art did not start with safe inactive UI art')
assert(attributes.panelBoardArt == 'true', 'current physical art was not covered by aligned UI art')
customObjectInspectionFails = true
assert(registerParent({parentGuid = 'panel1'}))
assert(string.find(appliedUiXml, 'id="panelBoardArt" active="false"', 1, true),
    'inspection failure did not keep UI art safe during preflight')
assert(attributes.panelBoardArt == 'true')
customObjectInspectionFails = false
panelPhysicalImage = 'legacy-panel.png'
panelArtRequestFails = true
assert(registerParent({parentGuid = 'panel1'}))
assert(attributes.panelBoardArt == 'false', 'network failure exposed the white image fallback')
panelArtRequestFails = false
assert(registerParent({parentGuid = 'panel1'}))
assert(attributes.panelBoardArt == 'true' and panelArtRequests == 5)
local legacyState = exportState()
legacyState.runtimeVersion = '0.1.5'
legacyState.hp = 47
legacyState.mp = 12
legacyState.diceOffset = {x = 0, y = 2.5, z = -5}
assert(importState(legacyState))
local migratedOffset = exportState().diceOffset
assert(exportState().hp == 78 and exportState().mp == 21,
    'direct level 4 to 7 full-resource migration failed')
assert(migratedOffset.x == 0 and migratedOffset.y == 3.2 and migratedOffset.z == 0,
    'legacy offset migration failed: ' .. tostring(migratedOffset.x) .. ','
        .. tostring(migratedOffset.y) .. ',' .. tostring(migratedOffset.z))
local level5State = exportState()
level5State.runtimeVersion = '0.1.7'
level5State.hp = 55
level5State.mp = 15
assert(importState(level5State))
assert(exportState().hp == 78 and exportState().mp == 21,
    'level 5 to 7 full-resource migration failed')
local woundedLevel5State = exportState()
woundedLevel5State.runtimeVersion = '0.1.7'
woundedLevel5State.hp = 54
woundedLevel5State.mp = 14
assert(importState(woundedLevel5State))
assert(exportState().hp == 54 and exportState().mp == 14,
    'spent level 5 resources were restored during migration')
local level6State = exportState()
level6State.runtimeVersion = '0.1.9'
level6State.hp = 69
level6State.mp = 18
assert(importState(level6State))
assert(exportState().hp == 78 and exportState().mp == 21,
    'level 6 to 7 full-resource migration failed')
local woundedLevel6State = exportState()
woundedLevel6State.runtimeVersion = '0.1.9'
woundedLevel6State.hp = 68
woundedLevel6State.mp = 17
assert(importState(woundedLevel6State))
assert(exportState().hp == 68 and exportState().mp == 17,
    'spent level 6 resources were restored during migration')
level5State.runtimeVersion = '0.1.7'
assert(importState(level5State))
assert(handleUiEvent({id = 'power_duel', playerColor = 'White'}))
local afterDuel = exportState()
assert(afterDuel.mp == 19 and afterDuel.effects.duel == 2)
assert(handleUiEvent({id = 'power_duel', playerColor = 'White'}))
assert(exportState().mp == 18 and exportState().effects.duel == 3)
assert(not handleUiEvent({id = 'power_duel', playerColor = 'White'}))
assert(exportState().mp == 18)
assert(handleUiEvent({id = 'power_baluarte', playerColor = 'White'}))
assert(exportState().effects.baluarte == 2 and exportState().mp == 17)
assert(handleUiEvent({id = 'power_baluarte', playerColor = 'White'}))
assert(exportState().effects.baluarte == 4 and exportState().mp == 16)
assert(handleUiEvent({id = 'power_baluarte_allies', playerColor = 'White'}))
assert(exportState().effects.baluarteShared and exportState().mp == 14)
assert(not handleUiEvent({id = 'power_baluarte_allies', playerColor = 'White'}))
assert(CorvanRules.calculateDefense(CHARACTER, exportState()) == 28)
assert(CorvanRules.calculateSkillModifier(CHARACTER, exportState(), 'fortitude') == 19)
assert(not handleUiEvent({id = 'power_baluarte', playerColor = 'White'}))
assert(exportState().mp == 14)
assert(handleUiEvent({id = 'end_turn', playerColor = 'White'}))
local afterTurn = exportState()
assert(afterTurn.effects.duel == 3 and not afterTurn.effects.baluarte
    and not afterTurn.effects.baluarteShared)
assert(handleUiEvent({id = 'end_scene', playerColor = 'White'}))
assert(not exportState().effects.duel and exportState().mp == 14)

assert(handleUiEvent({id = 'pv_adjust', value = '10', playerColor = 'White'}))
assert(handleUiEvent({id = 'pv_subtract', playerColor = 'White'}))
assert(exportState().hp == 68 and attributes.pv_adjust == '')
assert(handleUiEvent({id = 'pv_adjust', value = '5', playerColor = 'White'}))
assert(handleUiEvent({id = 'pv_add', playerColor = 'White'}))
assert(exportState().hp == 73 and attributes.pv_adjust == '')
assert(handleUiEvent({id = 'pv_adjust', value = 'texto', playerColor = 'White'}))
assert(not handleUiEvent({id = 'pv_subtract', playerColor = 'White'}))
assert(exportState().hp == 73 and attributes.pv_adjust == 'texto')
assert(handleUiEvent({id = 'pv_adjust', value = '0', playerColor = 'White'}))
assert(not handleUiEvent({id = 'pv_add', playerColor = 'White'}))
assert(attributes.pv_adjust == '0')
assert(handleUiEvent({id = 'pv_adjust', value = '', playerColor = 'White'}))
assert(not handleUiEvent({id = 'pv_subtract', playerColor = 'White'}))
assert(attributes.pv_adjust == '')
assert(handleUiEvent({id = 'pv_adjust', value = '10.5', playerColor = 'White'}))
assert(not handleUiEvent({id = 'pv_add', playerColor = 'White'}))
assert(attributes.pv_adjust == '10.5')
assert(handleUiEvent({id = 'pv_adjust', value = '-5', playerColor = 'White'}))
assert(handleUiEvent({id = 'pv_add', playerColor = 'White'}))
assert(exportState().hp == 78 and attributes.pv_adjust == '')
local undoAtMaximum = state.undo
assert(handleUiEvent({id = 'pv_adjust', value = '999', playerColor = 'White'}))
assert(handleUiEvent({id = 'pv_add', playerColor = 'White'}))
assert(exportState().hp == 78 and attributes.pv_adjust == '' and state.undo == undoAtMaximum)
assert(handleUiEvent({id = 'pm_adjust', value = '-5', playerColor = 'White'}))
assert(handleUiEvent({id = 'pm_subtract', playerColor = 'White'}))
assert(exportState().mp == 9 and attributes.pm_adjust == '')
assert(handleUiEvent({id = 'pm_adjust', value = '999', playerColor = 'White'}))
assert(handleUiEvent({id = 'pm_add', playerColor = 'White'}))
assert(exportState().mp == 21)
dieValues = {6}
assert(handleUiEvent({id = 'roll_damage', playerColor = 'White'}))
local afterDamage = exportState()
assert(afterDamage.lastResult == 'Dano - 11 (d8[6] + 5)')
assert(publicChat[#publicChat] == expectedPublicRoll('Dano', 11, 'd8(6) + 5'))
assert(publicChatRichText[#publicChatRichText] == true)

assert(handleUiEvent({id = 'power_combat_defensive', playerColor = 'White'}))
assert(CorvanRules.calculateAttackModifier(CHARACTER, exportState(), 'sword') == 11)
assert(CorvanRules.calculateDefense(CHARACTER, exportState()) == 29)
assert(handleUiEvent({id = 'power_baluarte', playerColor = 'White'}))
assert(CorvanRules.calculateDefense(CHARACTER, exportState()) == 31)
assert(handleUiEvent({id = 'power_baluarte', playerColor = 'White'}))
assert(CorvanRules.calculateDefense(CHARACTER, exportState()) == 33)
dieValues = {18}
assert(handleUiEvent({id = 'roll_attack', playerColor = 'White'}))
local afterAttack = exportState()
assert(afterAttack.effects.combatDefensiveDefense and not afterAttack.effects.combatDefensiveArmed)
assert(afterAttack.pendingThreat and afterAttack.pendingThreat.natural == 18)
assert(CorvanRules.calculateDefense(CHARACTER, afterAttack) == 33)
assert(afterAttack.lastResult == 'Espada - 29 (d20[18] + 11) • crítico')
assert(publicChat[#publicChat] == expectedPublicRoll('Espada', 29, 'd20(18) + 11')
    .. '  │ [FF6464]CRÍTICO[-]')
assert(publicChatTints[#publicChatTints][1] == 0.92
    and publicChatTints[#publicChatTints][2] == 0.94
    and publicChatTints[#publicChatTints][3] == 0.97)
assert(#afterAttack.ownedDiceGuids == 1 and afterAttack.ownedDiceOwnerGuid == 'panel1')
local attackDieGuid = afterAttack.ownedDiceGuids[1]
assert(diceByGuid[attackDieGuid].getGMNotes() == 'owned-die|panel1')
local publicBeforeClear = #publicChat
local privateBeforeClear = #privateChat
local undoBeforeClear = state.undo
assert(handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
local afterAttackClear = exportState()
assert(#afterAttackClear.ownedDiceGuids == 0 and diceByGuid[attackDieGuid] == nil)
assert(afterAttackClear.lastResult == afterAttack.lastResult)
assert(afterAttackClear.pendingThreat and afterAttackClear.pendingThreat.natural == 18)
assert(afterAttackClear.mp == afterAttack.mp
    and afterAttackClear.effects.combatDefensiveDefense == afterAttack.effects.combatDefensiveDefense)
assert(state.undo == undoBeforeClear)
assert(#publicChat == publicBeforeClear and #privateChat == privateBeforeClear)
assert(attributes.clear_dice == 'false')

dieValues = {6, 3}
assert(handleUiEvent({id = 'roll_critical', playerColor = 'White'}))
local afterCritical = exportState()
assert(afterCritical.pendingThreat == nil and afterCritical.lastResult == 'Crítico - 14 (2d8[6,3] + 5)')
assert(publicChat[#publicChat] == expectedPublicRoll('Crítico', 14, '2d8(6,3) + 5'))
assert(#afterCritical.ownedDiceGuids == 2)
local criticalDieOne = afterCritical.ownedDiceGuids[1]
local criticalDieTwo = afterCritical.ownedDiceGuids[2]
assert(handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
assert(diceByGuid[criticalDieOne] == nil and diceByGuid[criticalDieTwo] == nil)
assert(#exportState().ownedDiceGuids == 0 and exportState().lastResult == afterCritical.lastResult)
assert(handleUiEvent({id = 'end_turn', playerColor = 'White'}))
assert(CorvanRules.calculateDefense(CHARACTER, exportState()) == 24)

local rollbackState = normalizeState(exportState())
rollbackState.effects.combatDefensiveArmed = true
rollbackState.effects.combatDefensiveDefense = true
rollbackState.effects.shieldGuardSuppressed = false
state.effects.combatDefensiveArmed = false
state.effects.combatDefensiveDefense = false
state.effects.shieldGuardSuppressed = true
currentRoll = {token = 998, playerColor = 'White', rollback = rollbackState}
rollInProgress = true
finishRollFailure(998, 'falha simulada.')
assert(exportState().effects.combatDefensiveArmed and exportState().effects.combatDefensiveDefense
    and not exportState().effects.shieldGuardSuppressed)
assert(CorvanRules.calculateDefense(CHARACTER, exportState()) == 29)
assert(handleUiEvent({id = 'end_turn', playerColor = 'White'}))

local privateBeforeBusyActions = #privateChat
rollInProgress = true
assert(not handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
assert(not handleUiEvent({id = 'reset_state', playerColor = 'White'}))
assert(#privateChat == privateBeforeBusyActions + 2)
rollInProgress = false

dieValues = {7}
panelPosition = {x = 35, y = 4, z = 42}
assert(handleUiEvent({id = 'skill_iniciativa', playerColor = 'White'}))
local afterInitiative = exportState()
assert(afterInitiative.lastResult == 'Iniciativa - 10 (d20[7] + 3)')
assert(publicChat[#publicChat] == expectedPublicRoll('Iniciativa', 10, 'd20(7) + 3'))

dieValues = {11}
assert(handleUiEvent({id = 'skill_luta', playerColor = 'White'}))
assert(exportState().lastResult == 'Luta - 23 (d20[11] + 12)')
assert(publicChat[#publicChat] == expectedPublicRoll('Luta', 23, 'd20(11) + 12'))

dieValues = {9}
assert(handleUiEvent({id = 'skill_percepcao', playerColor = 'White'}))
assert(exportState().lastResult == 'Percepção - 17 (d20[9] + 8)')
assert(publicChat[#publicChat] == expectedPublicRoll('Percepção', 17, 'd20(9) + 8'))

dieValues = {8}
assert(handleUiEvent({id = 'skill_cavalgar', playerColor = 'White'}))
assert(exportState().lastResult == 'Cavalgar - 15 (d20[8] + 7)')
dieValues = {6}
assert(handleUiEvent({id = 'skill_diplomacia', playerColor = 'White'}))
assert(exportState().lastResult == 'Diplomacia - 16 (d20[6] + 10)')
dieValues = {12}
assert(handleUiEvent({id = 'skill_guerra', playerColor = 'White'}))
assert(exportState().lastResult == 'Guerra - 20 (d20[12] + 8)')
dieValues = {13}
assert(handleUiEvent({id = 'skill_pontaria', playerColor = 'White'}))
assert(exportState().lastResult == 'Pontaria - 20 (d20[13] + 7)')
assert(#publicChat == 11 and #spectatorChat == 11 and globalChatCalls == 0)
local latestSpawn = spawnPositions[#spawnPositions]
assert(latestSpawn.x == 35 and math.abs(latestSpawn.y - 7.2) < 0.001 and latestSpawn.z == 42,
    'spawn did not follow panel: ' .. tostring(latestSpawn.x) .. ','
        .. tostring(latestSpawn.y) .. ',' .. tostring(latestSpawn.z))
assert(launchCalls == 1 and torqueCalls == 1 and frameCalls == 11
        and velocityFallbackCalls == 10 and angularFallbackCalls == 10,
    'unexpected launch counts: ' .. tostring(launchCalls) .. ','
        .. tostring(torqueCalls) .. ',' .. tostring(frameCalls) .. ','
        .. tostring(velocityFallbackCalls) .. ',' .. tostring(angularFallbackCalls))
assert(#appliedVelocities == 11)
for _, velocity in ipairs(appliedVelocities) do
    assert(velocity.y >= DICE_VERTICAL_SPEED_MIN and velocity.y <= DICE_VERTICAL_SPEED_MAX)
    assert(math.abs(velocity.x) <= 1.4 and math.abs(velocity.z) <= 1.4)
end

assert(handleUiEvent({id = 'weapon_shield', playerColor = 'White'}))
dieValues = {12}
assert(handleUiEvent({id = 'roll_attack', playerColor = 'White'}))
local afterShieldAttack = exportState()
assert(afterShieldAttack.lastResult == 'Escudo - 24 (d20[12] + 12)')
assert(afterShieldAttack.effects.shieldGuardSuppressed)
assert(CorvanRules.calculateDefense(CHARACTER, afterShieldAttack) == 20)
assert(CorvanRules.calculateSkillModifier(CHARACTER, afterShieldAttack, 'fortitude') == 11)
assert(CorvanRules.calculateSkillModifier(CHARACTER, afterShieldAttack, 'reflex') == 3)
assert(CorvanRules.calculateSkillModifier(CHARACTER, afterShieldAttack, 'will') == 4)
assert(CorvanRules.calculateDamageReduction(CHARACTER, afterShieldAttack) == 8)
assert(handleUiEvent({id = 'end_turn', playerColor = 'White'}))
assert(not exportState().effects.shieldGuardSuppressed)
assert(CorvanRules.calculateDefense(CHARACTER, exportState()) == 24)

local chatBeforeFailure = #publicChat
currentRoll = {token = 999, playerColor = 'White'}
rollInProgress = true
finishRollFailure(999, 'a rolagem expirou.')
assert(#publicChat == chatBeforeFailure)

assert(handleUiEvent({id = 'pm_adjust', value = '999', playerColor = 'White'}))
assert(handleUiEvent({id = 'pm_subtract', playerColor = 'White'}))
assert(exportState().mp == 0)
assert(not handleUiEvent({id = 'power_duel', playerColor = 'White'}))
local undoBeforeToggle = state.undo
assert(handleUiEvent({id = 'automatic_resource_spending', value = 'False', playerColor = 'White'}))
assert(not exportState().automaticResourceSpending and state.undo == undoBeforeToggle)
assert(handleUiEvent({id = 'power_duel', playerColor = 'White'}))
assert(handleUiEvent({id = 'power_provocacao', playerColor = 'White'}))
assert(handleUiEvent({id = 'power_baluarte', playerColor = 'White'}))
assert(handleUiEvent({id = 'power_baluarte', playerColor = 'White'}))
assert(handleUiEvent({id = 'power_baluarte_allies', playerColor = 'White'}))
assert(exportState().mp == 0 and exportState().effects.baluarte == 4
    and exportState().effects.baluarteShared)
assert(handleUiEvent({id = 'undo', playerColor = 'White'}))
assert(not exportState().automaticResourceSpending and exportState().effects.baluarte == 4
    and not exportState().effects.baluarteShared)
local persistedAutomation = exportState()
assert(importState(persistedAutomation) and not exportState().automaticResourceSpending)
assert(handleUiEvent({id = 'end_turn', playerColor = 'White'}))
assert(exportState().effects.duel and exportState().effects.provocation
    and not exportState().effects.baluarte)

local legacyGuid = 'legacy-reset-die'
diceByGuid[legacyGuid] = {
    getGUID = function() return legacyGuid end,
    getGMNotes = function() return '' end
}
state.ownedDiceGuids = {legacyGuid}
state.ownedDiceOwnerGuid = 'panel1'
state.mp = 3
assert(handleUiEvent({id = 'reset_state', playerColor = 'White'}))
assert(diceByGuid[legacyGuid] == nil and #exportState().ownedDiceGuids == 0)
assert(exportState().mp == 21 and exportState().undo ~= nil
    and not exportState().automaticResourceSpending)
assert(handleUiEvent({id = 'undo', playerColor = 'White'}))
assert(exportState().mp == 3 and #exportState().ownedDiceGuids == 0
    and not exportState().automaticResourceSpending)

local originalGuid = 'original-panel-die'
local originalNotes = 'owned-die|panel1'
diceByGuid[originalGuid] = {
    getGUID = function() return originalGuid end,
    getGMNotes = function() return originalNotes end
}
local inheritedState = exportState()
inheritedState.parentGuid = 'panel1'
inheritedState.ownedDiceOwnerGuid = 'panel1'
inheritedState.ownedDiceGuids = {originalGuid}
assert(registerParent({parentGuid = 'panel-copy', state = inheritedState}))
assert(exportState().ownedDiceOwnerGuid == 'panel-copy' and #exportState().ownedDiceGuids == 0)
assert(not exportState().automaticResourceSpending)
assert(handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
assert(diceByGuid[originalGuid] ~= nil, 'panel copy removed a die owned by the original')

local sameOwnerLegacyGuid = 'same-owner-legacy-die'
diceByGuid[sameOwnerLegacyGuid] = {
    getGUID = function() return sameOwnerLegacyGuid end,
    getGMNotes = function() return '' end
}
assert(registerParent({parentGuid = 'panel1', state = {
    schemaVersion = 1,
    runtimeVersion = '0.1.6',
    parentGuid = 'panel1',
    ownedDiceGuids = {sameOwnerLegacyGuid}
}}))
assert(exportState().automaticResourceSpending, 'old saves must default automatic spending to on')
assert(handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
assert(diceByGuid[sameOwnerLegacyGuid] == nil, 'same-owner legacy die was not removed')
local foreignGuid = 'foreign-owned-die'
diceByGuid[foreignGuid] = {
    getGUID = function() return foreignGuid end,
    getGMNotes = function() return 'owned-die|another-panel' end
}
state.ownedDiceGuids = {foreignGuid}
state.ownedDiceOwnerGuid = 'panel1'
assert(handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
assert(diceByGuid[foreignGuid] ~= nil, 'metadata from another panel was ignored')
state.ownedDiceGuids = {'missing-die'}
state.ownedDiceOwnerGuid = 'panel1'
assert(handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
assert(#exportState().ownedDiceGuids == 0)
assert(#privateChat >= 5)

return afterDuel.mp, afterTurn.mp, afterDamage.lastResult, afterAttack.pendingThreat.natural,
    afterCritical.lastResult, #publicChat, globalChatCalls, #privateChat
'@

$runtimeFlowRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
try {
    $runtimeFlowResult = $runtimeFlowRunner.DoString($runtime + "`n" + $runtimeFlowHarness).ToString()
} catch {
    $moonSharpError = $_.Exception.InnerException
    if ($moonSharpError -and $moonSharpError.DecoratedMessage) {
        throw $moonSharpError.DecoratedMessage
    }
    throw
}
$expectedRuntimeFlow = '19, 14, "Dano - 11 (d8[6] + 5)", 18, "Crítico - 14 (2d8[6,3] + 5)", 14, 0, 12'
if ($runtimeFlowResult -ne $expectedRuntimeFlow) {
    throw "Smoke do fluxo de combate retornou '$runtimeFlowResult'; esperado '$expectedRuntimeFlow'."
}

$chatFallbackHarness = @'
local directCalls = 0
local colorFallbackCalls = 0
local globalFallbackCalls = 0
local hostPrintCalls = 0
local diagnostics = 0
local failedPlayer = {
    steam_id = 'steam-failed',
    color = 'Blue',
    print = function(_, _) directCalls = directCalls + 1; error('direct chat unavailable') end
}
Player = {
    Blue = failedPlayer,
    getPlayers = function() return {failedPlayer} end,
    getSpectators = function() return {failedPlayer} end
}
printToColor = function(message, color, tint)
    assert(message == 'Corvan: fallback por cor' and color == 'Blue')
    assert(tint[1] == 1.0 and tint[2] == 0.39 and tint[3] == 0.39)
    colorFallbackCalls = colorFallbackCalls + 1
end
printToAll = function(_, _) globalFallbackCalls = globalFallbackCalls + 1 end
local printFails = true
print = function(_)
    hostPrintCalls = hostPrintCalls + 1
    if printFails then error('global print unavailable') end
end
log = function(_, _) diagnostics = diagnostics + 1 end

printToAll = function(_, _) error('global chat unavailable') end
assert(publicMessage('Corvan: fallback por cor', nil, {1.0, 0.39, 0.39}))
assert(directCalls == 0 and colorFallbackCalls == 1 and globalFallbackCalls == 0)

local hostPlayer = {
    steam_id = 'steam-host',
    color = 'White',
    host = true,
    print = function(_, _) directCalls = directCalls + 1 end
}
printFails = false
printToColor = function(_, _, _) error('color route unavailable') end
Player = {
    White = hostPlayer,
    getPlayers = function() return {hostPlayer} end,
    getSpectators = function() return {} end
}
assert(publicMessage('Corvan: rota visível do host'))
assert(directCalls == 1 and hostPrintCalls == 0)

Player = nil
printFails = true
printToAll = function(_, _) globalFallbackCalls = globalFallbackCalls + 1 end
assert(publicMessage('Corvan: fallback global'))
assert(globalFallbackCalls == 1)

printToAll = function(_, _) error('global chat unavailable') end
assert(not publicMessage('Corvan: falha total'))
assert(hostPrintCalls == 1 and diagnostics == 2)
return directCalls, colorFallbackCalls, globalFallbackCalls, hostPrintCalls, diagnostics
'@

$chatFallbackRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$chatFallbackResult = $chatFallbackRunner.DoString($runtime + "`n" + $chatFallbackHarness).ToString()
$expectedChatFallback = '1, 1, 1, 1, 2'
if ($chatFallbackResult -ne $expectedChatFallback) {
    throw "Smoke dos fallbacks de chat retornou '$chatFallbackResult'; esperado '$expectedChatFallback'."
}

$chatRelayHarness = @'
local relayed = {}
printToAll = function(message, tint)
    assert(tint[1] == 0.92 and tint[2] == 0.94 and tint[3] == 0.97)
    table.insert(relayed, message)
end
assert(relayRuntimeChat({
    message = '[FF6464]Corvan[-] • Espada  │ RESULTADO: [62B8FF]17[-]  │ CÁLCULO: d20(4) + 13',
    richText = true
}))
assert(relayed[1] == '[FF6464]Corvan[-] • Espada  │ RESULTADO: [62B8FF]17[-]  │ CÁLCULO: d20(4) + 13')
assert(relayRuntimeChat({message = '[b]não permitido[/b] [FF6464]permitido[-]', richText = true}))
assert(relayed[2] == '［b］não permitido［/b］ ［FF6464］permitido［-］')
assert(relayRuntimeChat({message = '[FF6464]texto comum[-]', richText = false}))
assert(relayed[3] == '［FF6464］texto comum［-］')
assert(relayRuntimeChat({message = '[FF6464]tag aberta', richText = true}))
assert(relayed[4] == '［FF6464］tag aberta')
assert(relayRuntimeChat({message = '[FF6464][62B8FF]aninhado[-]', richText = true}))
assert(relayed[5] == '［FF6464］［62B8FF］aninhado［-］')
assert(relayRuntimeChat({message = '[FF6464]__CORVAN_CHAT_BLUE__[-]', richText = true}))
assert(relayed[6] == '[FF6464]__CORVAN_CHAT_BLUE__[-]')
assert(relayRuntimeChat({message = 'fechamento [-] isolado', richText = true}))
assert(relayed[7] == 'fechamento ［-］ isolado')
return #relayed
'@

$chatRelayRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$chatRelayResult = $chatRelayRunner.DoString($bootstrap + "`n" + $chatRelayHarness).Number
if ($chatRelayResult -ne 7) {
    throw "Smoke do relay rico de chat retornou '$chatRelayResult'; esperado '7'."
}

$integrityHarness = @'
Wait = {
    frames = function(callback, _)
        table.insert(__frameQueue, callback)
    end
}
__frameQueue = {}
update.active = true
update.serial = 77
local verified = nil
local failure = nil
verifyRuntimeIntegrityAsync(77, HASH_INPUT, HASH_SIZE, HASH_EXPECTED, function(ok, reason)
    verified = ok
    failure = reason
end)
local frames = 0
while #__frameQueue > 0 do
    frames = frames + 1
    if frames > 3600 then error('integrity frame loop exceeded') end
    local callback = table.remove(__frameQueue, 1)
    callback()
end
return verified, failure, frames
'@

$integrityRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$integrityRunner.Globals.Set('HASH_INPUT', [MoonSharp.Interpreter.DynValue]::NewString($runtime))
$integrityRunner.Globals.Set('HASH_SIZE', [MoonSharp.Interpreter.DynValue]::NewNumber($manifest.runtime.size))
$integrityRunner.Globals.Set('HASH_EXPECTED', [MoonSharp.Interpreter.DynValue]::NewString($manifest.runtime.sha256))
$integrityResult = $integrityRunner.DoString($bootstrap + "`n" + $integrityHarness)
if (-not $integrityResult.Tuple[0].Boolean) {
    throw "Verificação incremental de integridade falhou: $($integrityResult.Tuple[1])"
}
$integrityFrames = [int]$integrityResult.Tuple[2].Number

$onLoadHarness = @'
local timeQueue = {}
local frameQueue = {}
local conditionQueue = {}
local attributeCalls = 0
local invalidAttributeCalls = 0
local xmlSetCalls = 0
local installedXml = ''
local helper = nil

JSON = {
    encode = function(_) return '{"parentGuid":"panel1"}' end,
    decode = function(_) return {parentGuid = 'panel1'} end
}
Wait = {
    time = function(callback, _) table.insert(timeQueue, callback) end,
    frames = function(callback, _) table.insert(frameQueue, callback) end,
    condition = function(callback, condition, _, timeout)
        table.insert(conditionQueue, {callback = callback, condition = condition, timeout = timeout})
    end
}
self = {
    UI = {
        loading = false,
        setXml = function(xml)
            xmlSetCalls = xmlSetCalls + 1
            installedXml = xml
            self.UI.loading = true
        end,
        getXml = function() return installedXml end,
        setAttribute = function(id, _, _)
            attributeCalls = attributeCalls + 1
            if self.UI.loading or (id ~= 'refresh' and id ~= 'refreshStatus' and id ~= 'versionLabel') then
                invalidAttributeCalls = invalidAttributeCalls + 1
                error('invalid UI reference: ' .. tostring(id))
            end
        end
    },
    getGUID = function() return 'panel1' end,
    positionToWorld = function(_) return {0, -2.5, 0} end,
    getPosition = function() return {x = 0, y = 1, z = 0} end,
    createButton = function(_) end,
    clearButtons = function() end
}
getAllObjects = function() return {} end
getObjectFromGUID = function(guid)
    if helper and guid == helper.getGUID() then return helper end
    return nil
end
spawnObject = function(params)
    helper = {
        getGUID = function() return 'helper1' end,
        getGMNotes = function() return '{"parentGuid":"panel1"}' end,
        setGMNotes = function(_) end,
        setName = function(_) end,
        setDescription = function(_) end,
        setLock = function(_) end,
        setInvisibleTo = function(_) end,
        setLuaScript = function(_) end,
        reload = function()
            local accepted = applyRuntimeUi({
                xml = '<Panel id="root"><Button id="refresh"/><Text id="refreshStatus"/><Text id="versionLabel"/></Panel>'
            })
            if not accepted then error('bootstrap rejected valid UI') end
            setRuntimeUiAttribute({id = 'versionLabel', attribute = 'text', value = 'v0.2.1'})
            setRuntimeUiAttribute({id = 'missing', attribute = 'text', value = 'must stay queued'})
            return helper
        end,
        call = function(name, _)
            if name == 'healthCheck' then
                return {ok = true, version = '0.2.1', parentGuid = 'panel1'}
            elseif name == 'exportState' then
                return {schemaVersion = 1, runtimeVersion = '0.2.1'}
            end
            return true
        end
    }
    params.callback_function(helper)
end
printToColor = function(...) end
log = function(...) end

onLoad('')
if attributeCalls ~= 0 then error('onLoad touched UI before loading finished') end
local eventCycles = 0
while #frameQueue > 0 or #conditionQueue > 0 or #timeQueue > 0 do
    eventCycles = eventCycles + 1
    if eventCycles > 100 then error('onLoad event loop exceeded') end

    -- TTS commits setXml on a later frame. Every simulated event cycle starts
    -- after that commit so UI.loading and getXml expose the installed tree.
    self.UI.loading = false
    if #frameQueue > 0 then
        local callback = table.remove(frameQueue, 1)
        callback()
    elseif #conditionQueue > 0 then
        local pending = table.remove(conditionQueue, 1)
        if pending.condition() then pending.callback() elseif pending.timeout then pending.timeout() end
    else
        local callback = table.remove(timeQueue, 1)
        callback()
    end
end
if invalidAttributeCalls ~= 0 then error('bootstrap attempted an invalid UI attribute') end
local info = getBootstrapInfo()
return xmlSetCalls, attributeCalls, invalidAttributeCalls, info.helperGuid, info.runtimeVersion
'@

$onLoadRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$onLoadResult = $onLoadRunner.DoString($bootstrap + "`n" + $onLoadHarness).ToString()
$expectedOnLoad = '2, 5, 0, "helper1", "0.2.1"'
if ($onLoadResult -ne $expectedOnLoad) {
    throw "Smoke de onLoad retornou '$onLoadResult'; esperado '$expectedOnLoad'."
}

$copyPersistenceHarness = @'
local timeQueue = {}
local helper = nil
local helperState = nil
local defaultRuntimeState = {schemaVersion = 1, runtimeVersion = '0.2.1', mp = 21, effects = {duel = false}}
local persistedRuntimeState = {schemaVersion = 1, runtimeVersion = '0.1.2', mp = 10, effects = {duel = true}}

JSON = {
    encode = function(_) return '{"parentGuid":"panel-copy"}' end,
    decode = function(_) return {parentGuid = 'panel-copy'} end
}
Wait = {
    time = function(callback, _) table.insert(timeQueue, callback) end,
    frames = function(callback, _) callback() end,
    condition = function(callback, condition, _, timeout)
        if condition() then callback() elseif timeout then timeout() end
    end
}
self = {
    getGUID = function() return 'panel-copy' end,
    positionToWorld = function(_) return {0, -2.5, 0} end,
    getPosition = function() return {x = 0, y = 1, z = 0} end
}
getAllObjects = function() return helper and {helper} or {} end
getObjectFromGUID = function(guid)
    if helper and guid == helper.getGUID() then return helper end
    return nil
end
spawnObject = function(params)
    helper = {
        getGUID = function() return 'helper-copy' end,
        getGMNotes = function() return '{"parentGuid":"panel-copy"}' end,
        setGMNotes = function(_) end,
        setName = function(_) end,
        setDescription = function(_) end,
        setLock = function(_) end,
        setInvisibleTo = function(_) end,
        setLuaScript = function(_) end,
        reload = function()
            -- Reproduz a corrida real: o helper recém-recarregado publica seu
            -- estado padrão antes de o bootstrap terminar o health check.
            helperState = defaultRuntimeState
            cacheRuntimeState({state = defaultRuntimeState})
            return helper
        end,
        call = function(name, payload)
            if name == 'registerParent' then
                if type(payload) == 'table' and type(payload.state) == 'table' then
                    helperState = payload.state
                end
                cacheRuntimeState({state = helperState or defaultRuntimeState})
                return true
            elseif name == 'healthCheck' then
                return {ok = true, version = '0.2.1', parentGuid = 'panel-copy'}
            elseif name == 'importState' then
                helperState = payload
                return true
            elseif name == 'exportState' then
                return helperState
            end
            return true
        end
    }
    params.callback_function(helper)
end
printToColor = function(...) end
log = function(...) end

state = defaultState()
state.runtimeState = persistedRuntimeState
startupInstallAttempts = 0
helperSpawnPending = false
ensureHelper()
local cycles = 0
while #timeQueue > 0 do
    cycles = cycles + 1
    if cycles > 100 then error('copy persistence event loop exceeded') end
    local callback = table.remove(timeQueue, 1)
    callback()
end

if not state.runtimeState or state.runtimeState.mp ~= 10 then
    error('copied panel lost persisted MP during helper replacement')
end
if not state.runtimeState.effects or state.runtimeState.effects.duel ~= true then
    error('copied panel lost persisted effects during helper replacement')
end
return state.runtimeState.mp, state.runtimeState.effects.duel, state.helperGuid
'@

$copyPersistenceRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$copyPersistenceResult = $copyPersistenceRunner.DoString($bootstrap + "`n" + $copyPersistenceHarness).ToString()
$expectedCopyPersistence = '10, true, "helper-copy"'
if ($copyPersistenceResult -ne $expectedCopyPersistence) {
    throw "Smoke de persistência da cópia retornou '$copyPersistenceResult'; esperado '$expectedCopyPersistence'."
}

$webRequestHarness = @'
local timers = {}
local networkCallback = nil
local callbackCount = 0
local disposed = 0
local lastError = nil
Wait = {
    time = function(callback, _) table.insert(timers, callback) end
}
WebRequest = {
    custom = function(_, _, _, _, _, callback)
        networkCallback = callback
        return {dispose = function() disposed = disposed + 1 end}
    end
}
webGet('https://example.invalid', {}, function(response)
    callbackCount = callbackCount + 1
    lastError = response.error
end)
if #timers ~= 1 then error('network watchdog was not scheduled') end
timers[1]()
networkCallback({is_error = false, response_code = 200, text = 'late'})
return callbackCount, disposed, lastError
'@

$webRequestRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$webRequestResult = $webRequestRunner.DoString($bootstrap + "`n" + $webRequestHarness).ToString()
$expectedWebRequest = '1, 1, "timeout de rede"'
if ($webRequestResult -ne $expectedWebRequest) {
    throw "Smoke de WebRequest retornou '$webRequestResult'; esperado '$expectedWebRequest'."
}

$transactionHarness = @'
local oldXml = '<Panel id="root"><Button id="refresh"/><Text id="refreshStatus"/><Text id="versionLabel"/></Panel>'
local candidateXml = '<Panel id="root"><Button id="refresh"/><Text id="refreshStatus"/><Text id="versionLabel"/><Text id="activeWeaponLabel"/></Panel>'
local candidateSource = '-- CORVAN_RUNTIME candidate v0.2.1'
local oldSource = SEED_RUNTIME
local timers = {}
local currentGuid = 'helper1'
local activeVersion = '0.1.2'
local loadedSource = oldSource
local installedXml = oldXml
local currentState = {schemaVersion = 1, runtimeVersion = '0.1.2', hp = 23}
local helper = nil

JSON = {
    encode = function(_) return '{"parentGuid":"panel1"}' end,
    decode = function(_) return {parentGuid = 'panel1'} end
}
Wait = {
    time = function(callback, _) table.insert(timers, callback) end,
    condition = function(callback, condition, _, timeout)
        if condition() then callback() elseif timeout then timeout() end
    end,
    frames = function(callback, _) callback() end
}
self = {
    UI = {
        loading = false,
        setXml = function(xml) installedXml = xml; self.UI.loading = false end,
        getXml = function() return installedXml end,
        setAttribute = function(_, _, _) end
    },
    getGUID = function() return 'panel1' end,
    createButton = function(_) end,
    clearButtons = function() end
}
printToColor = function(...) end
log = function(...) end
getObjectFromGUID = function(guid)
    if guid == currentGuid then return helper end
    return nil
end

helper = {
    getGUID = function() return currentGuid end,
    getGMNotes = function() return '{"parentGuid":"panel1"}' end,
    setGMNotes = function(_) end,
    setName = function(_) end,
    setDescription = function(_) end,
    setLock = function(_) end,
    setInvisibleTo = function(_) end,
    setLuaScript = function(source) loadedSource = source end,
    reload = function()
        if loadedSource == candidateSource then
            currentGuid = 'candidate-guid'
            activeVersion = CANDIDATE_HEALTH_OK and '0.2.1' or 'broken'
            applyRuntimeUi({xml = candidateXml})
        else
            currentGuid = 'rollback-guid'
            activeVersion = '0.1.2'
            applyRuntimeUi({xml = oldXml})
        end
        return helper
    end,
    call = function(name, payload)
        if name == 'healthCheck' then
            return {ok = true, version = activeVersion, parentGuid = 'panel1'}
        elseif name == 'exportState' then
            return currentState
        elseif name == 'importState' then
            currentState = payload
            return true
        end
        return true
    end
}

state = defaultState()
state.helperGuid = currentGuid
state.runtimeVersion = '0.1.2'
state.runtimeSource = oldSource
state.runtimeState = currentState
state.uiXml = oldXml
uiReady = true
uiIds = collectUiIds(oldXml)
uiAttributeValues = {}
update.active = true
update.serial = 9
update.playerColor = 'White'
update.phase = 'install'

installCandidate(9, {
    manifest = {version = '0.2.1', commitSha = '0123456789abcdef0123456789abcdef01234567'},
    source = candidateSource,
    etag = 'etag-2'
})

local iterations = 0
while #timers > 0 do
    iterations = iterations + 1
    if iterations > 100 then error('transaction timer loop exceeded') end
    local callback = table.remove(timers, 1)
    callback()
end

return state.runtimeVersion,
    state.runtimeSource == candidateSource,
    state.runtimeSource == oldSource,
    update.active,
    currentGuid,
    currentState.hp,
    state.uiXml == candidateXml,
    state.uiXml == oldXml
'@

function Invoke-TransactionSmoke([bool]$healthy) {
    $runner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
    $runner.Globals.Set('CANDIDATE_HEALTH_OK', [MoonSharp.Interpreter.DynValue]::NewBoolean($healthy))
    return $runner.DoString($bootstrap + "`n" + $transactionHarness).ToString()
}

$updateSuccess = Invoke-TransactionSmoke $true
$expectedUpdateSuccess = '"0.2.1", true, false, false, "candidate-guid", 23, true, false'
if ($updateSuccess -ne $expectedUpdateSuccess) {
    throw "Smoke de update retornou '$updateSuccess'; esperado '$expectedUpdateSuccess'."
}

$updateRollback = Invoke-TransactionSmoke $false
$expectedUpdateRollback = '"0.1.2", false, true, false, "rollback-guid", 23, false, true'
if ($updateRollback -ne $expectedUpdateRollback) {
    throw "Smoke de rollback retornou '$updateRollback'; esperado '$expectedUpdateRollback'."
}

Write-Output "MoonSharp OK: runtime/bootstrap compilam; combate $runtimeFlowResult; SHA-256 em $integrityFrames frames; onLoad, cópia persistente, watchdog, update e rollback seguros"
