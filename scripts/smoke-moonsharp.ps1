$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

function ConvertTo-LuaLiteral($value) {
    if ($null -eq $value) { return 'nil' }
    if ($value -is [bool]) { return $(if ($value) { 'true' } else { 'false' }) }
    if ($value -is [string]) {
        return "'" + $value.Replace('\', '\\').Replace("'", "\'").Replace("`r", '\r').Replace("`n", '\n') + "'"
    }
    if ($value -is [System.Collections.IDictionary]) {
        $pairs = foreach ($key in $value.Keys) {
            "[" + (ConvertTo-LuaLiteral ([string]$key)) + "] = " + (ConvertTo-LuaLiteral $value[$key])
        }
        return '{' + ($pairs -join ', ') + '}'
    }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        $items = foreach ($item in $value) { ConvertTo-LuaLiteral $item }
        return '{' + ($items -join ', ') + '}'
    }
    if ($value -is [pscustomobject]) {
        $pairs = foreach ($property in $value.PSObject.Properties) {
            "[" + (ConvertTo-LuaLiteral $property.Name) + "] = " + (ConvertTo-LuaLiteral $property.Value)
        }
        return '{' + ($pairs -join ', ') + '}'
    }
    return ([System.Convert]::ToString($value, [System.Globalization.CultureInfo]::InvariantCulture))
}

function ConvertTo-LuaLongString([string]$value) {
    for ($level = 0; $level -le 16; $level++) {
        $equals = '=' * $level
        $close = "]$equals]"
        if (-not $value.Contains($close)) {
            return "[$equals[$value$close"
        }
    }
    throw 'Não foi possível criar um literal Lua longo sem colisão.'
}
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
& node (Join-Path $projectRoot 'scripts\build.mjs') --fixture arcane-test
if ($LASTEXITCODE -ne 0) {
    throw 'O build da fixture falhou antes do smoke Lua.'
}

Add-Type -Path $moonSharpDll
$panelUiAsset = Join-Path $projectRoot 'characters\corvan\assets\panel-board-ui.jpg'
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
$runtime = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\corvan\corvan-runtime.lua')
$legacyBootstrap = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'fixtures\legacy\corvan-v0.2.0-bootstrap.lua')
$characterData = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'characters\corvan\character.json') | ConvertFrom-Json
$characterConfigLiteral = ConvertTo-LuaLiteral $characterData
$runtimeConfigPrelude = "JSON = { decode = function(_) return $characterConfigLiteral end, encode = function(_) return '{}' end }"
$savedObject = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\corvan\Corvan_Duras_Console.json') | ConvertFrom-Json
$manifest = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\corvan\manifest.json') | ConvertFrom-Json
$fixtureRuntime = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\arcane-test\arcane-test-runtime.lua')
$fixtureSavedObject = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\arcane-test\Arcane_Test_Console.json') | ConvertFrom-Json
$fixtureBootstrap = $fixtureSavedObject.ObjectStates[0].LuaScript
$spentarRuntime = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\spentar\spentar-runtime.lua')
$spentarSavedObject = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\spentar\Spentar_Console.json') | ConvertFrom-Json
$spentarBootstrap = $spentarSavedObject.ObjectStates[0].LuaScript
$spentarCharacterData = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'characters\spentar\character.json') | ConvertFrom-Json
$spentarConfigLiteral = ConvertTo-LuaLiteral $spentarCharacterData
$bootstrap = $savedObject.ObjectStates[0].LuaScript

$fixturePanelAsset = Join-Path $projectRoot 'fixtures\characters\arcane-test\assets\panel-board.png'
if (-not (Test-Path -LiteralPath $fixturePanelAsset)) {
    throw 'Asset físico da fixture Arcane Test não foi encontrado.'
}
$fixturePanelImage = [System.Drawing.Image]::FromFile($fixturePanelAsset)
try {
    if ($fixturePanelImage.Width * 2 -ne $fixturePanelImage.Height * 3) {
        throw "Asset Arcane possui $($fixturePanelImage.Width)x$($fixturePanelImage.Height); esperado aspecto 3:2."
    }
} finally {
    $fixturePanelImage.Dispose()
}
if (($fixtureSavedObject.ObjectStates[0].CustomImage.ImageURL -match 'example\.invalid') -or
    ($fixtureSavedObject.ObjectStates[0].XmlUI -match 'example\.invalid')) {
    throw 'Saved Object Arcane ainda contém URL fictícia.'
}

$compiler = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$null = $compiler.LoadString($runtime)
$null = $compiler.LoadString($bootstrap)
$null = $compiler.LoadString($fixtureRuntime)
$null = $compiler.LoadString($fixtureBootstrap)
$null = $compiler.LoadString($spentarRuntime)
$null = $compiler.LoadString($spentarBootstrap)
$null = $compiler.LoadString($legacyBootstrap)

$fixturePrelude = @'
JSON = {
    decode = function(_)
        return {
            id = 'arcane-test', version = '0.1.0',
            resources = {focus = {max = 12}}
        }
    end,
    encode = function(_) return '{}' end
}
local parentCalls = {}
local fixtureParent = {
    call = function(name, payload)
        parentCalls[#parentCalls + 1] = {name = name, payload = payload}
        return true
    end
}
function getObjectFromGUID(guid)
    if guid == 'arcane-panel' then return fixtureParent end
    return nil
end
'@
$fixtureAssertions = @'
assert(healthCheck({}).ok and healthCheck({}).characterId == 'arcane-test')
assert(registerParent({parentGuid = 'arcane-panel', characterId = 'arcane-test'}))
assert(not handleUiEvent({id = 'cast', playerColor = 'White', characterId = 'corvan', parentGuid = 'arcane-panel'}))
assert(handleUiEvent({
    id = 'cast', playerColor = 'White',
    characterId = 'arcane-test', parentGuid = 'arcane-panel'
}))
local exported = exportState()
assert(exported.characterId == 'arcane-test'
    and exported.character.focus == 11
    and exported.character.casts == 1)
assert(not importState({characterId = 'corvan', character = {focus = 99}}))
return exported.character.focus, exported.character.casts, #parentCalls
'@
$fixtureRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$fixtureResult = $fixtureRunner.DoString($fixturePrelude + "`n" + $fixtureRuntime + "`n" + $fixtureAssertions).ToString()
if ($fixtureResult -ne '11, 1, 8') {
    throw "Smoke da fixture retornou '$fixtureResult'; esperado '11, 1, 8'."
}

# Exercita as regras puras do Spentar e o ciclo save/load usando o runtime
# compilado real. O decoder distingue a configuração embutida do token salvo.
$spentarRulesPrelude = @"
local characterConfig = $spentarConfigLiteral
local savedEnvelope = nil
JSON = {
    decode = function(text)
        if text == 'SPENTAR_SAVED_STATE' then return savedEnvelope end
        return characterConfig
    end,
    encode = function(value)
        savedEnvelope = value
        return 'SPENTAR_SAVED_STATE'
    end
}
"@
$spentarRulesAssertions = @'

local currentState = {
    resources = {hp = 20, mp = 48, temporaryHp = 0, temporaryMp = 0},
    equipment = {staffTwoHanded = true},
    scene = {profanar = true, profanarTargetsConfirmed = true,
        connectionMode = 'off', connectionCircle = 1,
        connectionPaidHp = 0, necropotencyGained = 0},
    souls = {stored = 6},
    summons = {bodiesAvailable = 6, undeadCount = 6, ballisticSpirits = 1,
        ballisticDice = 2, corpsePartner = 'none',
        commandUsed = {undead = false, ballistic = false}},
    casting = {spellId = 'inflict_wounds', sequence = 0, phase = 'configure',
        preparations = {inflict_wounds = {cost = 1, targets = 1,
            diceCount = 3, diceSides = 8, bonus = 9, releasedSouls = 6,
            damageType = 'trevas', darkness = true, profaneTargets = true,
            effect = '', note = ''}}, pendingResolutions = {}},
    effects = {}, preferences = {automaticResourceSpending = true}, undo = {}
}

local undead = SpentarRules.undeadDamagePlan(characterConfig, currentState, 6)
assert(SpentarRules.totalDamage(undead, {}) == 54, 'Spentar: 6d6+18 sob Profanar deve ser 54')

currentState.casting.preparations.inflict_wounds.releasedSouls = 0
local wounds = SpentarRules.damagePlan(characterConfig, currentState, 'inflict_wounds')
assert(SpentarRules.totalDamage(wounds, {}) == 33, 'Spentar: 3d8+9 sob Profanar deve ser 33')

currentState.casting.preparations.inflict_wounds.releasedSouls = 6
local woundsWithSouls = SpentarRules.damagePlan(characterConfig, currentState, 'inflict_wounds')
assert(SpentarRules.totalDamage(woundsWithSouls, {}) == 105,
    'Spentar: Infligir Ferimentos com seis almas sob Profanar deve ser 105')
assert(SpentarRules.totalDamage({bonus=0, groups={{id='souls', count=12, sides=6, maximized=true}}}, {}) == 72,
    'Spentar: 12d6 sob Profanar deve ser 72')
currentState.scene.profanarTargetsConfirmed = false
local woundsOutsideProfane = SpentarRules.damagePlan(characterConfig, currentState, 'inflict_wounds')
assert(not woundsOutsideProfane.groups[1].maximized
    and not woundsOutsideProfane.groups[2].maximized,
    'Spentar: Profanar maximizou grupo sem confirmação de área')
currentState.scene.profanarTargetsConfirmed = true

local necropotencyState = {
    resources = {temporaryMp = 0},
    scene = {connectionMode = 'doubled', necropotencyGained = 0}
}
assert(SpentarRules.applyNecropotency(characterConfig, necropotencyState, 6) == 2
    and necropotencyState.resources.temporaryMp == 2,
    'Spentar: Necropotência multiplicou benefício pelos derrotados')
necropotencyState.scene.necropotencyGained = 6
assert(SpentarRules.applyNecropotency(characterConfig, necropotencyState, 1) == 1
    and necropotencyState.scene.necropotencyGained == 7,
    'Spentar: Necropotência ultrapassou ou ignorou o teto da cena')

assert(SpentarRules.calculateSpellDifficulty(characterConfig, currentState, 'arcane_armor') == 25)
currentState.equipment.staffTwoHanded = false
assert(SpentarRules.calculateSpellDifficulty(characterConfig, currentState, 'arcane_armor') == 24)
assert(SpentarRules.calculateSpellDifficulty(characterConfig, currentState, 'fear') == 22)

assert(importState({
    characterId = 'spentar', runtimeVersion = '0.1.0',
    core = {page = 'necromancy', lastResult = 'PERSISTIDO'},
    character = currentState
}), 'Spentar: estado próprio recusado')
local beforeSave = exportState()
assert(beforeSave.characterId == 'spentar' and beforeSave.core.page == 'necromancy'
    and beforeSave.character.souls.stored == 6)
local saved = onSave()
assert(saved == 'SPENTAR_SAVED_STATE' and savedEnvelope.characterId == 'spentar')
onLoad(saved)
local afterLoad = exportState()
assert(afterLoad.characterId == 'spentar' and afterLoad.core.page == 'necromancy'
    and afterLoad.character.souls.stored == 6)

assert(importState({
    characterId = 'spentar', runtimeVersion = '0.1.0', core = {page = 'settings'},
    character = {
        resources = {hp = 20, mp = 40, temporaryHp = 0, temporaryMp = 0},
        souls = {stored = 1},
        casting = {
            spellId = 'inflict_wounds', phase = 'rolling', releasedSouls = 5,
            transaction = {id = 'spentar-interrupted', snapshot = {
                core = {page = 'casting', lastResult = 'ANTES DA ROLAGEM'},
                character = {
                    resources = {hp = 20, mp = 48, temporaryHp = 0, temporaryMp = 0},
                    souls = {stored = 6},
                    casting = {spellId = 'inflict_wounds', phase = 'configure',
                        releasedSouls = 5, targets = 1, sequence = 3}
                }
            }}
        }
    }
}), 'Spentar recusou estado com transação interrompida recuperável')
local recovered = exportState()
assert(recovered.character.resources.mp == 48 and recovered.character.souls.stored == 6
    and recovered.character.casting.phase == 'configure'
    and recovered.character.casting.transaction == nil
    and recovered.core.page == 'casting',
    'Spentar não restaurou snapshot de transação interrompida')

assert(importState({
    characterId = 'spentar', runtimeVersion = '0.1.0',
    characterStateSchemaVersion = 1, core = {page = 'casting'},
    character = {
        resources = {hp = 13, mp = 31, temporaryHp = 4, temporaryMp = 1},
        souls = {stored = 4}, summons = {commandUsed = true},
        casting = {spellId = 'inflict_wounds', phase = 'resolution', sequence = 9,
            failed = 1, defeated = 2,
            lastConfigurations = {inflict_wounds = {targets = 3, releasedSouls = 2}}}
    }
}), 'Spentar recusou estado legado v1')
local migratedV2 = exportState()
assert(migratedV2.characterStateSchemaVersion == 2
    and migratedV2.character.resources.hp == 13
    and migratedV2.character.resources.mp == 31
    and migratedV2.character.resources.temporaryHp == 4
    and migratedV2.character.resources.temporaryMp == 1
    and migratedV2.character.souls.stored == 4
    and migratedV2.character.summons.bodiesAvailable == 0
    and migratedV2.character.summons.undeadCount == 0
    and migratedV2.character.summons.commandUsed.undead
    and migratedV2.character.summons.commandUsed.ballistic
    and migratedV2.character.casting.phase == 'configure'
    and migratedV2.character.casting.preparations.inflict_wounds.targets == 3
    and migratedV2.character.casting.preparations.inflict_wounds.releasedSouls == 2
    and migratedV2.character.casting.pendingResolution ~= nil,
    'Spentar não migrou estado v1 para a bancada v2')
assert(not importState({characterId = 'corvan', character = {}, core = {}}),
    'Spentar aceitou estado do Corvan')
assert(not importState({characterId = 'arcane-test', character = {}, core = {}}),
    'Spentar aceitou estado da fixture')

return SpentarRules.totalDamage(undead, {}), SpentarRules.totalDamage(wounds, {}),
    SpentarRules.totalDamage(woundsWithSouls, {}), afterLoad.character.souls.stored
'@
$spentarRulesRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$spentarRulesResult = $spentarRulesRunner.DoString(
    $spentarRulesPrelude + "`n" + $spentarRuntime + "`n" + $spentarRulesAssertions
).ToString()
if ($spentarRulesResult -ne '54, 33, 105, 6') {
    throw "Smoke de regras/estado do Spentar retornou '$spentarRulesResult'; esperado '54, 33, 105, 6'."
}

# Executa os três adaptadores em ambientes Lua isolados, como o TTS faz com
# objetos diferentes, mas sobre o mesmo mundo fake de painéis, helpers e dados.
# Isso torna observável qualquer travessia acidental de GUID ou characterId.
$corvanRuntimeLiteral = ConvertTo-LuaLongString $runtime
$fixtureRuntimeLiteral = ConvertTo-LuaLongString $fixtureRuntime
$spentarRuntimeLiteral = ConvertTo-LuaLongString $spentarRuntime
$sharedWorldHarness = @"
local corvanSource = $corvanRuntimeLiteral
local fixtureSource = $fixtureRuntimeLiteral
local spentarSource = $spentarRuntimeLiteral
local corvanConfig = $characterConfigLiteral
local fixtureConfig = {
    id = 'arcane-test', version = '0.1.0', name = 'Arcane Test', shortName = 'Arcane',
    resources = {focus = {max = 12}}, actions = {cast = {formula = '1d6+2'}}
}
local spentarConfig = $spentarConfigLiteral

local world = {crossCalls = 0, panels = {}, dice = {}, json = {}, jsonSerial = 0, nextDie = 0}

local function jsonEncode(value)
    world.jsonSerial = world.jsonSerial + 1
    local token = 'WORLD_JSON:' .. tostring(world.jsonSerial)
    world.json[token] = value
    return token
end

local function panel(guid, characterId)
    local value = {guid = guid, characterId = characterId, calls = 0, cache = nil, ui = nil}
    value.call = function(name, payload)
        value.calls = value.calls + 1
        if type(payload) == 'table' and payload.characterId ~= nil
            and payload.characterId ~= characterId then
            world.crossCalls = world.crossCalls + 1
            return false
        end
        if name == 'cacheRuntimeState' then value.cache = payload.state end
        if name == 'applyRuntimeUi' then value.ui = payload.xml end
        return true
    end
    value.positionToWorld = function(position) return position end
    value.getPosition = function() return {x = 0, y = 1, z = 0} end
    world.panels[guid] = value
    return value
end

local corvanPanel = panel('corvan-panel', 'corvan')
local arcanePanel = panel('arcane-panel', 'arcane-test')
local spentarPanel = panel('spentar-panel', 'spentar')
world.holdSpentarRoll = false

local function die(guid, metadata, rotationValue)
    local value = {guid = guid, metadata = metadata, notes = nil, destroyed = false,
        resting = true, rotationValue = rotationValue or 4}
    value.getGUID = function() return guid end
    value.getGMNotes = function() return value.notes or ('DIE:' .. guid) end
    value.setGMNotes = function(notes) value.notes = notes end
    value.setName = function(_) return true end
    value.setVelocity = function(_) value.resting = false end
    value.setAngularVelocity = function(_) return true end
    value.getRotationValue = function() return value.rotationValue end
    world.dice[guid] = value
    return value
end

local corvanDie = die('corvan-die', {
    project = 'corvan-tts-automation', characterId = 'corvan',
    kind = 'owned-die', ownerPanelGuid = 'corvan-panel'
})
local arcaneDie = die('arcane-die', {
    project = 'corvan-tts-automation', characterId = 'arcane-test',
    kind = 'owned-die', ownerPanelGuid = 'arcane-panel'
})
local spentarForeignDie = die('spentar-foreign-die', {
    project = 'corvan-tts-automation', characterId = 'spentar',
    kind = 'owned-die', ownerPanelGuid = 'another-spentar-panel'
})

local function runtimeEnvironment(source, label, helperGuid, config)
    local env = {}
    env._G = env
    setmetatable(env, {__index = _G})
    env.JSON = {
        decode = function(text)
            local dieGuid = type(text) == 'string' and string.match(text, '^DIE:(.+)$') or nil
            if dieGuid ~= nil and world.dice[dieGuid] ~= nil then
                return world.dice[dieGuid].metadata
            end
            if world.json[text] ~= nil then return world.json[text] end
            return config
        end,
        encode = jsonEncode
    }
    env.self = {
        getGUID = function() return helperGuid end,
        setGMNotes = function(_) return true end,
        getGMNotes = function() return '{}' end
    }
    env.getObjectFromGUID = function(guid)
        return world.panels[guid] or world.dice[guid]
    end
    env.getAllObjects = function()
        local values = {}
        for _, object in pairs(world.dice) do
            if not object.destroyed then table.insert(values, object) end
        end
        return values
    end
    env.destroyObject = function(object)
        object.destroyed = true
    end
    env.Wait = {
        frames = function(callback, _) callback() end,
        time = function(callback, _)
            if label == 'spentar-runtime' and world.holdSpentarRoll then return end
            callback()
        end,
        condition = function(callback, condition, _, timeout)
            -- Permite testar o cancelamento enquanto o host ainda aguarda os
            -- dados, sem deixar o smoke depender de um timeout artificial.
            if label == 'spentar-runtime' and world.holdSpentarRoll then return end
            for cycle = 1, 4 do
                for guid, object in pairs(world.dice) do
                    if object.spawned and not object.destroyed then
                        -- Modela spawns escalonados reais: o primeiro d6 pode
                        -- já ter parado quando o último começa a ser observado.
                        object.resting = cycle > 1 or guid == 'spentar-die-1'
                    end
                end
                if condition() then callback() return end
            end
            if timeout then timeout() end
        end
    }
    env.spawnObject = function(params)
        world.nextDie = world.nextDie + 1
        local object = die('spentar-die-' .. tostring(world.nextDie), nil, 4)
        object.spawned = true
        object.resting = true
        params.callback_function(object)
    end
    env.Player = {getPlayers = function() return {} end}
    env.printToAll = function(_, _) return true end
    env.printToColor = function(_, _, _) return true end
    env.log = function(_, _) return true end
    env.WebRequest = nil
    local chunk, loadError = load(source, label, 't', env)
    assert(chunk, loadError)
    chunk()
    return env
end

local corvan = runtimeEnvironment(corvanSource, 'corvan-runtime', 'corvan-helper', corvanConfig)
local arcane = runtimeEnvironment(fixtureSource, 'arcane-runtime', 'arcane-helper', fixtureConfig)
local spentar = runtimeEnvironment(spentarSource, 'spentar-runtime', 'spentar-helper', spentarConfig)

assert(corvan.registerParent({
    characterId = 'corvan', parentGuid = 'corvan-panel',
    state = {
        characterId = 'corvan', runtimeVersion = '0.2.1', schemaVersion = 1,
        characterStateSchemaVersion = 1,
        character = {hp = 70, mp = 17, runtimeVersion = '0.2.1', effects = {}},
        core = {
            ownedDiceOwnerGuid = 'corvan-panel',
            ownedDiceGuids = {'corvan-die', 'arcane-die'}
        }
    }
}), 'shared world: Corvan registerParent failed')
assert(arcane.registerParent({characterId = 'arcane-test', parentGuid = 'arcane-panel'}),
    'shared world: Arcane registerParent failed')
assert(spentar.registerParent({characterId = 'spentar', parentGuid = 'spentar-panel'}),
    'shared world: Spentar registerParent failed')

local corvanBefore = corvan.exportState()
local arcaneBefore = arcane.exportState()
local spentarBefore = spentar.exportState()
assert(corvanBefore.characterId == 'corvan' and corvanBefore.helperGuid == 'corvan-helper',
    'shared world: Corvan identity/helper mismatch')
assert(arcaneBefore.characterId == 'arcane-test'
    and arcane.healthCheck({}).parentGuid == 'arcane-panel',
    'shared world: Arcane identity/helper mismatch')
assert(spentarBefore.characterId == 'spentar'
    and spentar.healthCheck({}).parentGuid == 'spentar-panel',
    'shared world: Spentar identity/helper mismatch')
assert(corvanPanel.cache.characterId == 'corvan', 'shared world: Corvan cache mismatch')
assert(arcanePanel.cache.characterId == 'arcane-test', 'shared world: Arcane cache mismatch')
assert(spentarPanel.cache.characterId == 'spentar', 'shared world: Spentar cache mismatch')
assert(type(corvanPanel.ui) == 'string' and type(arcanePanel.ui) == 'string'
    and type(spentarPanel.ui) == 'string', 'shared world: runtime UI missing')
assert(corvanPanel.ui ~= arcanePanel.ui and corvanPanel.ui ~= spentarPanel.ui
    and arcanePanel.ui ~= spentarPanel.ui, 'shared world: runtime UI crossed characters')

assert(not corvan.handleUiEvent({
    characterId = 'arcane-test', parentGuid = 'corvan-panel', id = 'clear_dice'
}), 'shared world: Corvan accepted Arcane event')
assert(not arcane.handleUiEvent({
    characterId = 'corvan', parentGuid = 'arcane-panel', id = 'cast'
}), 'shared world: Arcane accepted Corvan event')
assert(not spentar.handleUiEvent({
    characterId = 'arcane-test', parentGuid = 'spentar-panel', id = 'nav_necromancy'
}), 'shared world: Spentar accepted Arcane event')
assert(not corvan.importState(arcaneBefore), 'shared world: Corvan accepted Arcane state')
assert(not arcane.importState(corvanBefore), 'shared world: Arcane accepted Corvan state')
assert(not spentar.importState(corvanBefore), 'shared world: Spentar accepted Corvan state')
assert(not spentar.importState(arcaneBefore), 'shared world: Spentar accepted Arcane state')

assert(arcane.handleUiEvent({
    characterId = 'arcane-test', parentGuid = 'arcane-panel', id = 'cast', playerColor = 'White'
}), 'shared world: Arcane cast failed')
local arcaneAfterCast = arcane.exportState()
assert(arcaneAfterCast.character.focus == 11 and arcaneAfterCast.character.casts == 1,
    'shared world: Arcane state did not mutate locally')

-- A bancada permite editar e salvar uma preparação sem cobrar recursos.
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'connection_doubled',
    playerColor = 'White', eventId = 'spentar-connection-doubled'
}), 'shared world: Spentar doubled connection failed')
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'quick_inflict_edit',
    playerColor = 'White', eventId = 'spentar-edit-1'
}), 'shared world: Spentar quick edit failed')
assert(not spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'prepare_cost', value = 'abc',
    playerColor = 'White', eventId = 'spentar-invalid-cost'
}), 'shared world: Spentar accepted invalid typed cost')
for _, input in ipairs({
    {id='prepare_cost', value='2'}, {id='prepare_targets', value='2'},
    {id='prepare_dice_count', value='4'}, {id='prepare_dice_sides', value='8'},
    {id='prepare_bonus', value='11'}, {id='prepare_note', value='preparo persistido'}
}) do
    input.characterId = 'spentar'; input.parentGuid = 'spentar-panel'
    input.playerColor = 'White'; input.eventId = 'spentar-input-' .. input.id
    assert(spentar.handleUiEvent(input), 'shared world: typed input failed: ' .. input.id)
end
assert(not spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'prepare_dice_sides',
    value = '7', playerColor = 'White', eventId = 'spentar-invalid-d7'
}), 'shared world: Spentar accepted a die unsupported by the physical host')
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'prepare_save',
    playerColor = 'White', eventId = 'spentar-save-1'
}), 'shared world: saving preparation failed')
local spentarPrepared = spentar.exportState()
local savedPreparation = spentarPrepared.character.casting.preparations.inflict_wounds
assert(spentarPrepared.core.page == 'casting'
    and spentarPrepared.character.resources.mp == 48
    and spentarPrepared.character.resources.hp == 18
    and spentarPrepared.character.souls.stored == 0
    and savedPreparation.cost == 2 and savedPreparation.targets == 2
    and savedPreparation.diceCount == 4 and savedPreparation.diceSides == 8
    and savedPreparation.bonus == 11 and savedPreparation.note == 'preparo persistido'
    and spentarPrepared.character.casting.transaction == nil
    and #spentarPrepared.core.ownedDice == 0,
    'shared world: editing/saving mutated resources or lost preparation')

-- Rolar último usa exatamente o preparo salvo, cobra uma vez e cria uma
-- resolução persistente sem bloquear o restante do painel.
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'quick_inflict_roll',
    playerColor = 'White', eventId = 'spentar-roll-1'
}), 'shared world: Spentar quick roll failed')
assert(not spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'quick_inflict_roll',
    playerColor = 'White', eventId = 'spentar-roll-1'
}), 'shared world: duplicate event charged or rolled twice')
local spentarAfterRoll = spentar.exportState()
assert(spentarAfterRoll.character.resources.mp == 46
    and spentarAfterRoll.character.casting.phase == 'configure'
    and spentarAfterRoll.character.casting.transaction == nil
    and spentarAfterRoll.character.casting.pendingResolution ~= nil,
    'shared world: quick roll did not finish into a nonblocking resolution')
assert(#spentarAfterRoll.core.ownedDice == 4,
    'shared world: saved preparation did not create four d8')
assert(spentar.importState(spentarAfterRoll),
    'shared world: pending resolution state did not import')
local spentarResolutionReloaded = spentar.exportState()
assert(spentarResolutionReloaded.core.page == 'casting'
    and spentarResolutionReloaded.character.casting.phase == 'configure'
    and spentarResolutionReloaded.character.casting.pendingResolution ~= nil
    and spentarResolutionReloaded.character.resources.mp == 46,
    'shared world: pending resolution did not survive save/load')
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'nav_necromancy',
    playerColor = 'White', eventId = 'spentar-pending-nav'
}), 'shared world: pending resolution blocked navigation')

-- Corpos e invocações são entradas independentes e continuam utilizáveis
-- enquanto a resolução anterior aguarda as informações da mesa.
for _, input in ipairs({
    {id='bodies_available', value='5'}, {id='undead_count', value='2'},
    {id='ballistic_count', value='1'}, {id='ballistic_dice', value='2'},
    {id='corpse_partner', value='Cadáver magivocador'}
}) do
    input.characterId = 'spentar'; input.parentGuid = 'spentar-panel'
    input.playerColor = 'White'; input.eventId = 'spentar-necro-' .. input.id
    assert(spentar.handleUiEvent(input), 'shared world: necromancy input failed: ' .. input.id)
end
local independentSummons = spentar.exportState().character.summons
assert(independentSummons.bodiesAvailable == 5 and independentSummons.undeadCount == 2
    and independentSummons.ballisticSpirits == 1 and independentSummons.ballisticDice == 2
    and independentSummons.corpsePartner == 'Cadáver magivocador',
    'shared world: corpses and summons crossed state')
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'necro_undead_roll',
    playerColor = 'White', eventId = 'spentar-direct-undead'
}), 'shared world: pending resolution blocked undead roll')
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'necro_ballistic_roll',
    playerColor = 'White', eventId = 'spentar-direct-ballistic'
}), 'shared world: pending resolution blocked ballistic roll')

-- Consequências são aplicadas uma vez: cajado +10 PV temporários,
-- Necropotência +2 PM temporários e almas limitadas pelo estoque máximo.
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'pending_failed', value = '2',
    playerColor = 'White', eventId = 'spentar-pending-failed'
}), 'shared world: pending failed input failed')
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'pending_defeated', value = '2',
    playerColor = 'White', eventId = 'spentar-pending-defeated'
}), 'shared world: pending defeated input failed')
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'pending_apply',
    playerColor = 'White', eventId = 'spentar-pending-apply'
}), 'shared world: pending resolution did not apply')
local spentarResolved = spentar.exportState()
assert(spentarResolved.character.resources.temporaryHp == 10
    and spentarResolved.character.resources.temporaryMp == 2
    and spentarResolved.character.souls.stored == 2
    and spentarResolved.character.casting.pendingResolution == nil,
    'shared world: resolution consequences were not applied once')
assert(not spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'pending_apply',
    playerColor = 'White', eventId = 'spentar-pending-apply-again'
}), 'shared world: resolution consequences applied twice')
local spentarBeforeCorvanClear = spentar.exportState()
assert(corvan.handleUiEvent({
    characterId = 'corvan', parentGuid = 'corvan-panel', id = 'clear_dice', playerColor = 'White'
}), 'shared world: Corvan clear failed')
assert(corvanDie.destroyed == true, 'shared world: Corvan die survived own clear')
assert(arcaneDie.destroyed == false, 'shared world: Arcane die was destroyed by Corvan')
for _, guid in ipairs(spentarBeforeCorvanClear.core.ownedDice) do
    assert(world.dice[guid] and not world.dice[guid].destroyed,
        'shared world: Corvan destroyed Spentar physical die ' .. tostring(guid))
end
local arcaneAfterCorvanClear = arcane.exportState()
assert(arcaneAfterCorvanClear.character.focus == 11 and arcaneAfterCorvanClear.character.casts == 1,
    'shared world: Corvan clear changed Arcane state')
assert(arcanePanel.cache.characterId == 'arcane-test', 'shared world: Arcane cache was replaced')

local spentarBeforeClear = spentar.exportState()
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'clear_dice',
    playerColor = 'White', eventId = 'spentar-clear-1'
}), 'shared world: Spentar clear failed')
for _, guid in ipairs(spentarBeforeClear.core.ownedDice) do
    assert(world.dice[guid].destroyed == true, 'shared world: Spentar die survived own clear')
end
assert(arcaneDie.destroyed == false, 'shared world: Spentar destroyed Arcane die')
assert(spentarForeignDie.destroyed == false, 'shared world: Spentar destroyed die from another panel')

assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'end_turn',
    playerColor = 'White', eventId = 'spentar-direct-reset-command'
}), 'shared world: direct summon command did not reset')

-- Uma limpeza durante Rolando cancela a transação, restaura o snapshot e
-- remove somente os dados do Spentar.
world.holdSpentarRoll = true
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'quick_inflict_roll',
    playerColor = 'White', eventId = 'spentar-roll-2'
}), 'shared world: Spentar second roll did not enter host')
local spentarRolling = spentar.exportState()
assert(spentarRolling.character.casting.phase == 'rolling'
    and spentarRolling.character.resources.mp == 46
    and spentarRolling.character.resources.temporaryMp == 0
    and spentarRolling.character.casting.transaction ~= nil,
    'shared world: Spentar second roll did not remain cancellable phase='
        .. tostring(spentarRolling.character.casting.phase)
        .. ' mp=' .. tostring(spentarRolling.character.resources.mp)
        .. ' transaction=' .. tostring(spentarRolling.character.casting.transaction))
assert(spentar.handleUiEvent({
    characterId = 'spentar', parentGuid = 'spentar-panel', id = 'clear_dice',
    playerColor = 'White', eventId = 'spentar-clear-rolling'
}), 'shared world: Spentar rolling clear did not cancel')
world.holdSpentarRoll = false
local spentarAfterCancel = spentar.exportState()
assert(spentarAfterCancel.character.casting.phase == 'configure'
    and spentarAfterCancel.character.casting.transaction == nil
    and spentarAfterCancel.character.resources.mp == 46
    and spentarAfterCancel.character.resources.temporaryMp == 2,
    'shared world: Spentar rolling clear did not restore snapshot phase='
        .. tostring(spentarAfterCancel.character.casting.phase)
        .. ' mp=' .. tostring(spentarAfterCancel.character.resources.mp)
        .. ' transaction=' .. tostring(spentarAfterCancel.character.casting.transaction))
assert(arcaneDie.destroyed == false,
    'shared world: Spentar cancellation destroyed an Arcane die')
assert(spentarForeignDie.destroyed == false,
    'shared world: Spentar cancellation destroyed a foreign Spentar die')

-- Controles visíveis possuem dispatch real e as rotas especiais não deixam
-- custo sem efeito: Vitalidade aplica PV temporários e Espírito invoca.
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='combat_edit_last',
    playerColor='White', eventId='spentar-edit-last'
}), 'shared world: Editar último não abriu o preparo usado')
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='mark_command_used',
    playerColor='White', eventId='spentar-mark-commands'
}), 'shared world: marcador manual de comandos falhou')
local markedCommands = spentar.exportState().character.summons.commandUsed
assert(markedCommands.undead and markedCommands.ballistic,
    'shared world: marcador manual não marcou ambos os comandos')
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='mark_command_used',
    playerColor='White', eventId='spentar-release-commands'
}), 'shared world: liberação manual de comandos falhou')

assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='toggle_physical_dice',
    playerColor='White', eventId='spentar-virtual-dice'
}), 'shared world: não foi possível desligar dados físicos')
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_select_phantom_vitality',
    playerColor='White', eventId='spentar-select-vitality'
}), 'shared world: Vitalidade Fantasma não abriu')
local beforeVitality = spentar.exportState()
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_roll',
    playerColor='White', eventId='spentar-roll-vitality'
}), 'shared world: Vitalidade Fantasma não rolou')
local afterVitality = spentar.exportState()
assert(afterVitality.character.resources.temporaryHp
        > beforeVitality.character.resources.temporaryHp
    and afterVitality.character.casting.pendingResolution == nil,
    'shared world: Vitalidade não aplicou PV temporários diretamente')
local vitalityMp = afterVitality.character.resources.mp
local vitalityTemporaryMp = afterVitality.character.resources.temporaryMp
assert(not spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_apply',
    playerColor='White', eventId='spentar-apply-vitality'
}), 'shared world: Vitalidade aceitou aplicação sem resultado de dados')
local afterInvalidVitality = spentar.exportState()
assert(afterInvalidVitality.character.resources.mp == vitalityMp
    and afterInvalidVitality.character.resources.temporaryMp == vitalityTemporaryMp,
    'shared world: Vitalidade inválida cobrou PM')

assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_select_ballistic_spirit',
    playerColor='White', eventId='spentar-select-ballistic'
}), 'shared world: Espírito Balístico não abriu')
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_targets', value='2',
    playerColor='White', eventId='spentar-ballistic-targets'
}), 'shared world: configuração de espíritos falhou')
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_roll',
    playerColor='White', eventId='spentar-conjure-ballistic'
}), 'shared world: conjuração de Espírito Balístico falhou')
assert(spentar.exportState().character.summons.ballisticSpirits == 2,
    'shared world: Rolar/Conjurar não criou os espíritos configurados')

-- Sem eventId (como no bootstrap distribuído), o debounce impede cobrança
-- dupla em ações síncronas.
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_select_profane',
    playerColor='White', eventId='spentar-select-profane-debounce'
}), 'shared world: Profanar não abriu para teste de debounce')
local beforeProfane = spentar.exportState()
assert(spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_apply',
    playerColor='White'
}), 'shared world: primeira aplicação sem eventId falhou')
assert(not spentar.handleUiEvent({
    characterId='spentar', parentGuid='spentar-panel', id='prepare_apply',
    playerColor='White'
}), 'shared world: duplo clique sem eventId foi aceito')
local afterProfane = spentar.exportState()
assert((beforeProfane.character.resources.mp + beforeProfane.character.resources.temporaryMp)
        - (afterProfane.character.resources.mp + afterProfane.character.resources.temporaryMp) == 1,
    'shared world: duplo clique cobrou Profanar mais de uma vez')
assert(corvanPanel.cache.characterId == 'corvan' and arcanePanel.cache.characterId == 'arcane-test'
    and spentarPanel.cache.characterId == 'spentar', 'shared world: cache crossed characters')
assert(world.crossCalls == 0, 'shared world: parent received cross-character callback')

return corvanPanel.cache.characterId, arcanePanel.cache.characterId, spentarPanel.cache.characterId,
    corvanDie.destroyed, arcaneDie.destroyed,
    spentarForeignDie.destroyed, arcaneAfterCorvanClear.character.focus,
    spentarAfterRoll.character.resources.mp, world.crossCalls
"@

$sharedWorldRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$sharedWorldResult = $sharedWorldRunner.DoString($sharedWorldHarness).ToString()
$expectedSharedWorld = '"corvan", "arcane-test", "spentar", true, false, false, 11, 46, 0'
if ($sharedWorldResult -ne $expectedSharedWorld) {
    throw "Smoke multi-personagem compartilhado retornou '$sharedWorldResult'; esperado '$expectedSharedWorld'."
}

# O segundo mundo compartilhado executa os três bootstraps completos. Cada
# painel enxerga os helpers anteriores e precisa manter identidade, GM Notes e
# binding independentes.
$corvanBootstrapLiteral = ConvertTo-LuaLongString $bootstrap
$fixtureBootstrapLiteral = ConvertTo-LuaLongString $fixtureBootstrap
$spentarBootstrapLiteral = ConvertTo-LuaLongString $spentarBootstrap
$sharedBootstrapHarness = @"
local corvanBootstrapSource = $corvanBootstrapLiteral
local arcaneBootstrapSource = $fixtureBootstrapLiteral
local spentarBootstrapSource = $spentarBootstrapLiteral
local world = {helpers = {}, json = {}, jsonSerial = 0, crossBindings = 0}

local function jsonEncode(value)
    world.jsonSerial = world.jsonSerial + 1
    local token = 'JSON:' .. tostring(world.jsonSerial)
    world.json[token] = value
    return token
end

local function jsonDecode(value)
    return world.json[value]
end

local function livingHelpers()
    local values = {}
    for _, helper in ipairs(world.helpers) do
        if not helper.destroyed then table.insert(values, helper) end
    end
    return values
end

local function bootstrapEnvironment(source, label, characterId, panelGuid, version, marker)
    local env = {}
    env._G = env
    setmetatable(env, {__index = _G})
    local installedXml = ''
    env.JSON = {encode = jsonEncode, decode = jsonDecode}
    env.Wait = {
        frames = function(callback, _) callback() end,
        time = function(callback, _) callback() end,
        condition = function(callback, condition, _, timeout)
            if condition() then callback() elseif timeout then timeout() end
        end
    }
    env.self = {
        UI = {
            loading = false,
            setXml = function(xml) installedXml = xml end,
            getXml = function() return installedXml end,
            setAttribute = function(_, _, _) return true end
        },
        getGUID = function() return panelGuid end,
        positionToWorld = function(position) return position end,
        getPosition = function() return {x = 0, y = 1, z = 0} end,
        createButton = function(_) return true end,
        clearButtons = function() return true end
    }
    env.getAllObjects = livingHelpers
    env.getObjectFromGUID = function(guid)
        for _, helper in ipairs(world.helpers) do
            if not helper.destroyed and helper.getGUID() == guid then return helper end
        end
        return nil
    end
    env.destroyObject = function(object) object.destroyed = true end
    env.spawnObject = function(params)
        local helperGuid = characterId .. '-helper-' .. tostring(#world.helpers + 1)
        local helper = {
            destroyed = false,
            notes = '',
            boundCharacterId = nil,
            boundParentGuid = nil
        }
        helper.getGUID = function() return helperGuid end
        helper.getGMNotes = function() return helper.notes end
        helper.setGMNotes = function(notes) helper.notes = notes end
        helper.setName = function(_) return true end
        helper.setDescription = function(_) return true end
        helper.setLock = function(_) return true end
        helper.setInvisibleTo = function(_) return true end
        helper.setLuaScript = function(_) return true end
        helper.reload = function() return helper end
        helper.call = function(name, payload)
            if name == 'registerParent' then
                if payload.characterId ~= characterId or payload.parentGuid ~= panelGuid then
                    world.crossBindings = world.crossBindings + 1
                    return false
                end
                helper.boundCharacterId = payload.characterId
                helper.boundParentGuid = payload.parentGuid
                return true
            elseif name == 'healthCheck' then
                return {
                    ok = true, characterId = characterId, runtimeMarker = marker,
                    version = version, parentGuid = panelGuid, rollInProgress = false
                }
            elseif name == 'exportState' then
                return {
                    characterId = characterId, runtimeVersion = version,
                    parentGuid = panelGuid, character = {}, core = {}
                }
            elseif name == 'importState' then
                return type(payload) == 'table'
                    and (payload.characterId == nil or payload.characterId == characterId)
            end
            return true
        end
        table.insert(world.helpers, helper)
        params.callback_function(helper)
    end
    env.Player = {getPlayers = function() return {} end}
    env.printToColor = function(_, _, _) return true end
    env.log = function(_, _) return true end
    local chunk, loadError = load(source, label, 't', env)
    assert(chunk, loadError)
    chunk()
    return env
end

local corvan = bootstrapEnvironment(
    corvanBootstrapSource, 'corvan-bootstrap', 'corvan', 'corvan-panel', '0.2.3', 'CORVAN_RUNTIME')
local arcane = bootstrapEnvironment(
    arcaneBootstrapSource, 'arcane-bootstrap', 'arcane-test', 'arcane-panel', '0.1.0', 'ARCANE_TEST_RUNTIME')
local spentar = bootstrapEnvironment(
    spentarBootstrapSource, 'spentar-bootstrap', 'spentar', 'spentar-panel', '0.1.0', 'SPENTAR_RUNTIME')

corvan.onLoad('')
assert(#world.helpers == 1, 'shared bootstrap: Corvan did not create exactly one helper')
local corvanHelper = world.helpers[1]
arcane.onLoad('')
assert(#world.helpers == 2, 'shared bootstrap: Arcane adopted Corvan helper or spawned more than one')
local arcaneHelper = world.helpers[2]
spentar.onLoad('')
assert(#world.helpers == 3, 'shared bootstrap: Spentar adopted another helper or spawned more than one')
local spentarHelper = world.helpers[3]

local corvanInfo = corvan.getBootstrapInfo()
local arcaneInfo = arcane.getBootstrapInfo()
local spentarInfo = spentar.getBootstrapInfo()
assert(corvanInfo.characterId == 'corvan' and corvanInfo.helperGuid == corvanHelper.getGUID(),
    'shared bootstrap: Corvan helper binding mismatch')
assert(arcaneInfo.characterId == 'arcane-test' and arcaneInfo.helperGuid == arcaneHelper.getGUID(),
    'shared bootstrap: Arcane helper binding mismatch')
assert(spentarInfo.characterId == 'spentar' and spentarInfo.helperGuid == spentarHelper.getGUID(),
    'shared bootstrap: Spentar helper binding mismatch')
assert(corvanHelper.boundCharacterId == 'corvan' and corvanHelper.boundParentGuid == 'corvan-panel')
assert(arcaneHelper.boundCharacterId == 'arcane-test' and arcaneHelper.boundParentGuid == 'arcane-panel')
assert(spentarHelper.boundCharacterId == 'spentar' and spentarHelper.boundParentGuid == 'spentar-panel')

local corvanNotes = jsonDecode(corvanHelper.getGMNotes())
local arcaneNotes = jsonDecode(arcaneHelper.getGMNotes())
local spentarNotes = jsonDecode(spentarHelper.getGMNotes())
assert(corvanNotes.characterId == 'corvan' and corvanNotes.parentGuid == 'corvan-panel')
assert(arcaneNotes.characterId == 'arcane-test' and arcaneNotes.parentGuid == 'arcane-panel')
assert(spentarNotes.characterId == 'spentar' and spentarNotes.parentGuid == 'spentar-panel')
assert(world.crossBindings == 0, 'shared bootstrap: cross-character registerParent occurred')

corvan.onDestroy()
assert(corvanHelper.destroyed == true, 'shared bootstrap: Corvan helper survived panel destruction')
assert(arcaneHelper.destroyed == false, 'shared bootstrap: Corvan destroyed Arcane helper')
assert(spentarHelper.destroyed == false, 'shared bootstrap: Corvan destroyed Spentar helper')
assert(arcane.getBootstrapInfo().helperGuid == arcaneHelper.getGUID())
assert(spentar.getBootstrapInfo().helperGuid == spentarHelper.getGUID())

return corvanInfo.characterId, arcaneInfo.characterId, spentarInfo.characterId,
    corvanHelper.destroyed, arcaneHelper.destroyed, spentarHelper.destroyed, world.crossBindings
"@

$sharedBootstrapRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$sharedBootstrapResult = $sharedBootstrapRunner.DoString($sharedBootstrapHarness).ToString()
$expectedSharedBootstrap = '"corvan", "arcane-test", "spentar", true, false, false, 0'
if ($sharedBootstrapResult -ne $expectedSharedBootstrap) {
    throw "Smoke de bootstraps compartilhados retornou '$sharedBootstrapResult'; esperado '$expectedSharedBootstrap'."
}

$rulesHarness = @'
local character = {
    defense = 24,
    damageReduction = 10,
    weapons = {
        sword = {
            attack = 13,
            damage = {count = 2, sides = 8, bonus = 10},
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
local baseDamage = CorvanRules.calculateDamageSpec(character, {effects = {}}, 'sword', false)
local duelTwoDamage = CorvanRules.calculateDamageSpec(
    character, {effects = {duel = 2}}, 'sword', false)
local duelTwoCritical = CorvanRules.calculateDamageSpec(
    character, {effects = {duel = 2}}, 'sword', true)
local duelThreeDamage = CorvanRules.calculateDamageSpec(
    character, {effects = {duel = 3}}, 'sword', false)
local duelThreeCritical = CorvanRules.calculateDamageSpec(
    character, {effects = {duel = 3}}, 'sword', true)
assert(baseDamage.count == 2 and baseDamage.sides == 8 and baseDamage.bonus == 10)
assert(duelTwoDamage.count == 2 and duelTwoDamage.bonus == 12)
assert(duelTwoCritical.count == 4 and duelTwoCritical.bonus == 12)
assert(duelThreeDamage.count == 2 and duelThreeDamage.bonus == 13)
assert(duelThreeCritical.count == 4 and duelThreeCritical.bonus == 13)
return CorvanRules.calculateAttackModifier(character, state, 'sword'),
    CorvanRules.calculateDefense(character, state),
    CorvanRules.calculateSkillModifier(character, state, 'fortitude'),
    CorvanRules.calculateDamageReduction(character, state),
    damage.count, damage.sides, damage.bonus,
    CorvanRules.isThreat(character, 'sword', 18)
'@

$runner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$actual = $runner.DoString($runtimeConfigPrelude + "`n" + $runtime + "`n" + $rulesHarness).ToString()
$expected = '14, 29, 15, 13, 4, 8, 13, true'
if ($actual -ne $expected) {
    throw "Smoke de regras retornou '$actual'; esperado '$expected'."
}

$invalidConfigurationHarness = @'
local health = healthCheck({})
assert(not health.ok and health.characterId == 'corvan')
assert(type(health.error) == 'string' and health.error ~= '')
assert(not registerParent({parentGuid = 'other-panel', characterId = 'arcane-test'}))
assert(not handleUiEvent({id = 'roll_attack', playerColor = 'White'}))
assert(exportState() == nil)
assert(not importState({characterId = 'corvan', character = {}}))
return health.characterId, health.ok, exportState() == nil
'@
$invalidConfigurationPrelude = "JSON = { decode = function(_) return {id = 'outro'} end, encode = function(_) return '{}' end }"
$invalidConfigurationRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$invalidConfigurationResult = $invalidConfigurationRunner.DoString(
    $invalidConfigurationPrelude + "`n" + $runtime + "`n" + $invalidConfigurationHarness
).ToString()
if ($invalidConfigurationResult -ne '"corvan", false, true') {
    throw "Smoke de configuração inválida retornou '$invalidConfigurationResult'."
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

assert(not registerParent({parentGuid = 'foreign-panel', characterId = 'arcane-test'}))
-- Contrato exato do bootstrap 1.0.2 congelado: tabela sem characterId.
assert(registerParent({parentGuid = 'panel1', state = {
    schemaVersion = 1,
    runtimeVersion = '0.2.0',
    hp = 70,
    mp = 17,
    effects = {duel = 2}
}}))
local legacyBootstrapBinding = exportState()
assert(legacyBootstrapBinding.characterId == 'corvan'
    and legacyBootstrapBinding.parentGuid == 'panel1'
    and legacyBootstrapBinding.character.hp == 70
    and legacyBootstrapBinding.character.mp == 17
    and legacyBootstrapBinding.character.effects.duel == 2)
assert(randomRange(DICE_VERTICAL_SPEED_MIN, DICE_VERTICAL_SPEED_MAX, 0) == 13.5)
assert(randomRange(DICE_VERTICAL_SPEED_MIN, DICE_VERTICAL_SPEED_MAX, 0.5) == 16)
assert(randomRange(DICE_VERTICAL_SPEED_MIN, DICE_VERTICAL_SPEED_MAX, 1) == 18.5)
assert(string.find(appliedUiXml, 'id="panelBoardArt" active="false"', 1, true),
    'legacy panel did not start with safe inactive UI art')
assert(attributes.panelBoardArt == 'true')
panelPhysicalImage = PANEL_IMAGE_URL
assert(registerParent({parentGuid = 'panel1', characterId = 'corvan'}))
assert(string.find(appliedUiXml, 'id="panelBoardArt" active="false"', 1, true),
    'current physical art did not start with safe inactive UI art')
assert(attributes.panelBoardArt == 'true', 'current physical art was not covered by aligned UI art')
customObjectInspectionFails = true
assert(registerParent({parentGuid = 'panel1', characterId = 'corvan'}))
assert(string.find(appliedUiXml, 'id="panelBoardArt" active="false"', 1, true),
    'inspection failure did not keep UI art safe during preflight')
assert(attributes.panelBoardArt == 'true')
customObjectInspectionFails = false
panelPhysicalImage = 'legacy-panel.png'
panelArtRequestFails = true
assert(registerParent({parentGuid = 'panel1', characterId = 'corvan'}))
assert(attributes.panelBoardArt == 'false', 'network failure exposed the white image fallback')
panelArtRequestFails = false
assert(registerParent({parentGuid = 'panel1', characterId = 'corvan'}))
assert(attributes.panelBoardArt == 'true' and panelArtRequests == 5)
assert(not handleUiEvent({
    id = 'power_duel', playerColor = 'White',
    characterId = 'arcane-test', parentGuid = 'panel1'
}))
assert(not handleUiEvent({
    id = 'power_duel', playerColor = 'White',
    characterId = 'corvan', parentGuid = 'foreign-panel'
}))
local isolatedHandleUiEvent = handleUiEvent
function handleUiEvent(payload)
    payload.characterId = 'corvan'
    payload.parentGuid = parentGuid
    return isolatedHandleUiEvent(payload)
end
-- O restante deste harness histórico opera sobre o estado plano das versões
-- antigas. Preserve essa visão somente no teste, enquanto a função nativa fica
-- disponível para validar o novo envelope ao final.
local nativeExportState = exportState
function exportState()
    local envelope = nativeExportState()
    local flat = deepCopy(envelope.character)
    for key, value in pairs(envelope.core or {}) do flat[key] = deepCopy(value) end
    flat.parentGuid = envelope.parentGuid
    flat.rollInProgress = envelope.rollInProgress
    return flat
end
local legacy020 = exportState()
legacy020.runtimeVersion = '0.2.0'
legacy020.hp = 31
legacy020.mp = 6
legacy020.effects.duel = 3
legacy020.effects.baluarte = 4
legacy020.effects.provocation = true
legacy020.automaticResourceSpending = false
legacy020.diceOffset = {x = 1.25, y = 4.5, z = -2.75}
legacy020.lastResult = 'resultado preservado'
legacy020.parentGuid = 'panel1'
legacy020.ownedDiceOwnerGuid = 'panel1'
legacy020.ownedDiceGuids = {'legacy-020-die'}
legacy020.undo = deepCopy(legacy020)
legacy020.undo.hp = 44
legacy020.undo.mp = 9
legacy020.undo.undo = nil
assert(importState(legacy020))
local migrated020 = exportState()
assert(migrated020.hp == 31 and migrated020.mp == 6)
assert(migrated020.effects.duel == 3 and migrated020.effects.baluarte == 4
    and migrated020.effects.provocation)
assert(not migrated020.automaticResourceSpending)
assert(migrated020.diceOffset.x == 1.25 and migrated020.diceOffset.y == 4.5
    and migrated020.diceOffset.z == -2.75)
assert(migrated020.lastResult == 'resultado preservado')
assert(#migrated020.ownedDiceGuids == 1 and migrated020.ownedDiceGuids[1] == 'legacy-020-die')
assert(migrated020.undo ~= nil and migrated020.undo.hp == 44 and migrated020.undo.mp == 9)
local legacy021 = deepCopy(migrated020)
legacy021.runtimeVersion = '0.2.1'
legacy021.hp = 29
legacy021.mp = 4
legacy021.effects.duel = 2
legacy021.effects.baluarte = 4
legacy021.effects.provocation = true
legacy021.automaticResourceSpending = false
legacy021.diceOffset = {x = -1.5, y = 5.25, z = 2.75}
legacy021.lastResult = 'resultado 0.2.1 preservado'
legacy021.ownedDiceOwnerGuid = 'panel1'
legacy021.ownedDiceGuids = {'legacy-021-die'}
legacy021.undo = deepCopy(legacy021)
legacy021.undo.hp = 38
legacy021.undo.mp = 8
legacy021.undo.undo = nil
assert(importState(legacy021))
local migrated021 = exportState()
assert(migrated021.hp == 29 and migrated021.mp == 4)
assert(migrated021.effects.duel == 2 and migrated021.effects.baluarte == 4
    and migrated021.effects.provocation)
assert(not migrated021.automaticResourceSpending)
assert(migrated021.diceOffset.x == -1.5 and migrated021.diceOffset.y == 5.25
    and migrated021.diceOffset.z == 2.75)
assert(migrated021.lastResult == 'resultado 0.2.1 preservado')
assert(#migrated021.ownedDiceGuids == 1 and migrated021.ownedDiceGuids[1] == 'legacy-021-die')
assert(migrated021.undo ~= nil and migrated021.undo.hp == 38 and migrated021.undo.mp == 8)
local legacyState = defaultState()
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
dieValues = {6, 4}
assert(handleUiEvent({id = 'roll_damage', playerColor = 'White'}))
local afterDamage = exportState()
assert(afterDamage.lastResult == 'Dano - 20 (2d8[6,4] + 10)')
assert(publicChat[#publicChat] == expectedPublicRoll('Dano', 20, '2d8(6,4) + 10'))
assert(publicChatRichText[#publicChatRichText] == true)
assert(#afterDamage.ownedDiceGuids == 2)

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

dieValues = {6, 3, 8, 1}
assert(handleUiEvent({id = 'roll_critical', playerColor = 'White'}))
local afterCritical = exportState()
assert(afterCritical.pendingThreat == nil and afterCritical.lastResult == 'Crítico - 28 (4d8[6,3,8,1] + 10)')
assert(publicChat[#publicChat] == expectedPublicRoll('Crítico', 28, '4d8(6,3,8,1) + 10'))
assert(#afterCritical.ownedDiceGuids == 4)
local criticalDieOne = afterCritical.ownedDiceGuids[1]
local criticalDieTwo = afterCritical.ownedDiceGuids[2]
local criticalDieThree = afterCritical.ownedDiceGuids[3]
local criticalDieFour = afterCritical.ownedDiceGuids[4]
assert(handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
assert(diceByGuid[criticalDieOne] == nil and diceByGuid[criticalDieTwo] == nil
    and diceByGuid[criticalDieThree] == nil and diceByGuid[criticalDieFour] == nil)
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
assert(launchCalls == 1 and torqueCalls == 1 and frameCalls == 14
        and velocityFallbackCalls == 13 and angularFallbackCalls == 13,
    'unexpected launch counts: ' .. tostring(launchCalls) .. ','
        .. tostring(torqueCalls) .. ',' .. tostring(frameCalls) .. ','
        .. tostring(velocityFallbackCalls) .. ',' .. tostring(angularFallbackCalls))
assert(#appliedVelocities == 14)
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
assert(CorvanRules.calculateDamageReduction(CHARACTER, afterShieldAttack) == 10)
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
assert(registerParent({parentGuid = 'panel-copy', characterId = 'corvan', state = inheritedState}))
assert(exportState().ownedDiceOwnerGuid == 'panel-copy' and #exportState().ownedDiceGuids == 0)
assert(not exportState().automaticResourceSpending)
assert(handleUiEvent({id = 'clear_dice', playerColor = 'White'}))
assert(diceByGuid[originalGuid] ~= nil, 'panel copy removed a die owned by the original')

local sameOwnerLegacyGuid = 'same-owner-legacy-die'
diceByGuid[sameOwnerLegacyGuid] = {
    getGUID = function() return sameOwnerLegacyGuid end,
    getGMNotes = function() return '' end
}
assert(registerParent({parentGuid = 'panel1', characterId = 'corvan', state = {
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
local nativeEnvelope = nativeExportState()
assert(nativeEnvelope.characterId == 'corvan'
    and nativeEnvelope.runtimeVersion == '0.2.3'
    and type(nativeEnvelope.core) == 'table'
    and type(nativeEnvelope.character) == 'table')

return afterDuel.mp, afterTurn.mp, afterDamage.lastResult, afterAttack.pendingThreat.natural,
    afterCritical.lastResult, #publicChat, globalChatCalls, #privateChat
'@

$runtimeFlowRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
try {
    $runtimeFlowResult = $runtimeFlowRunner.DoString($runtimeConfigPrelude + "`n" + $runtime + "`n" + $runtimeFlowHarness).ToString()
} catch {
    $moonSharpError = $_.Exception.InnerException
    if ($moonSharpError -and $moonSharpError.DecoratedMessage) {
        throw $moonSharpError.DecoratedMessage
    }
    throw
}
$expectedRuntimeFlow = '19, 14, "Dano - 20 (2d8[6,4] + 10)", 18, "Crítico - 28 (4d8[6,3,8,1] + 10)", 14, 0, 12'
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
$chatFallbackResult = $chatFallbackRunner.DoString($runtimeConfigPrelude + "`n" + $runtime + "`n" + $chatFallbackHarness).ToString()
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
assert(not relayRuntimeChat({
    characterId = 'outro-personagem',
    message = 'não pode atravessar identidade',
    richText = false
}))
assert(#relayed == 0)
assert(not setRuntimeUiAttribute({
    characterId = 'outro-personagem',
    id = 'versionLabel',
    attribute = 'text',
    value = 'não autorizado'
}))
assert(not relayRuntimePrivate({
    characterId = 'outro-personagem',
    playerColor = 'White',
    message = 'não autorizado'
}))
assert(not cacheRuntimeState({
    characterId = 'outro-personagem',
    state = {characterId = 'corvan'}
}))
assert(cacheRuntimeState({
    characterId = 'corvan',
    state = {characterId = 'corvan'}
}))
assert(relayRuntimeChat({
    characterId = 'corvan',
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

$manifestValidationHarness = @"
local function manifest()
    return {
        schemaVersion = $($manifest.schemaVersion),
        characterId = '$($manifest.characterId)',
        releaseTag = '$($manifest.releaseTag)',
        version = '$($manifest.version)',
        minBootstrapVersion = '$($manifest.minBootstrapVersion)',
        commitSha = '$($manifest.commitSha)',
        runtime = {
            url = '$($manifest.runtime.url)',
            size = $($manifest.runtime.size),
            sha256 = '$($manifest.runtime.sha256)'
        }
    }
end
local valid, reason = validateManifest(manifest(), '$($manifest.releaseTag)')
assert(valid, reason)
local wrongCharacter = manifest(); wrongCharacter.characterId = 'arcane-test'
assert(not validateManifest(wrongCharacter, '$($manifest.releaseTag)'))
local wrongTag = manifest(); wrongTag.releaseTag = 'v9.9.9'
assert(not validateManifest(wrongTag, '$($manifest.releaseTag)'))
local wrongUrl = manifest(); wrongUrl.runtime.url = 'https://evil.invalid/runtime.lua'
assert(not validateManifest(wrongUrl, '$($manifest.releaseTag)'))
local wrongSize = manifest(); wrongSize.runtime.size = 999999999
assert(not validateManifest(wrongSize, '$($manifest.releaseTag)'))
local wrongHash = manifest(); wrongHash.runtime.sha256 = 'abc'
assert(not validateManifest(wrongHash, '$($manifest.releaseTag)'))
assert(runtimeSourceIsValid(ACTUAL_RUNTIME_SOURCE))
assert(not runtimeSourceIsValid('-- WRONG_RUNTIME\nfunction healthCheck() return {ok=true} end'))
assert(not healthIsValid({ok = true, characterId = 'arcane-test', runtimeMarker = 'CORVAN_RUNTIME', version = '$($manifest.version)'}, '$($manifest.version)'))
assert(not healthIsValid({ok = true, characterId = 'corvan', runtimeMarker = 'OTHER_RUNTIME', version = '$($manifest.version)'}, '$($manifest.version)'))
return valid, true
"@
$manifestValidationRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$manifestValidationRunner.Globals.Set('ACTUAL_RUNTIME_SOURCE', [MoonSharp.Interpreter.DynValue]::NewString($runtime))
$manifestValidationResult = $manifestValidationRunner.DoString($bootstrap + "`n" + $manifestValidationHarness).ToString()
if ($manifestValidationResult -ne 'true, true') {
    throw "Validação negativa de identidade/integridade retornou '$manifestValidationResult'."
}

$legacyIntegrityRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$legacyIntegrityRunner.Globals.Set('HASH_INPUT', [MoonSharp.Interpreter.DynValue]::NewString($runtime))
$legacyIntegrityRunner.Globals.Set('HASH_SIZE', [MoonSharp.Interpreter.DynValue]::NewNumber($manifest.runtime.size))
$legacyIntegrityRunner.Globals.Set('HASH_EXPECTED', [MoonSharp.Interpreter.DynValue]::NewString($manifest.runtime.sha256))
$legacyIntegrityResult = $legacyIntegrityRunner.DoString($legacyBootstrap + "`n" + $integrityHarness)
if (-not $legacyIntegrityResult.Tuple[0].Boolean) {
    throw "Bootstrap congelado 1.0.2 rejeitou a integridade do runtime v0.2.3: $($legacyIntegrityResult.Tuple[1])"
}

$legacyManifestHarness = @"
local manifest = {
    schemaVersion = $($manifest.schemaVersion),
    version = '$($manifest.version)',
    minBootstrapVersion = '$($manifest.minBootstrapVersion)',
    commitSha = '$($manifest.commitSha)',
    runtime = {
        url = '$($manifest.runtime.url)',
        size = $($manifest.runtime.size),
        sha256 = '$($manifest.runtime.sha256)'
    }
}
local valid, reason = validateManifest(manifest, '$($manifest.releaseTag)')
assert(valid, reason)
assert(runtimeSourceIsValid(ACTUAL_RUNTIME_SOURCE))
manifest.runtime.url = manifest.runtime.url .. '.untrusted'
assert(not validateManifest(manifest, '$($manifest.releaseTag)'))
return valid, runtimeSourceIsValid(ACTUAL_RUNTIME_SOURCE)
"@
$legacyManifestRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$legacyManifestRunner.Globals.Set('ACTUAL_RUNTIME_SOURCE', [MoonSharp.Interpreter.DynValue]::NewString($runtime))
$legacyManifestResult = $legacyManifestRunner.DoString($legacyBootstrap + "`n" + $legacyManifestHarness).ToString()
if ($legacyManifestResult -ne 'true, true') {
    throw "Contrato do manifesto v0.2.3 falhou no bootstrap congelado 1.0.2: '$legacyManifestResult'."
}

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
            setRuntimeUiAttribute({id = 'versionLabel', attribute = 'text', value = 'v0.2.3'})
            setRuntimeUiAttribute({id = 'missing', attribute = 'text', value = 'must stay queued'})
            return helper
        end,
        call = function(name, _)
            if name == 'healthCheck' then
                return {ok = true, version = '0.2.3', parentGuid = 'panel1'}
            elseif name == 'exportState' then
                return {schemaVersion = 1, runtimeVersion = '0.2.3'}
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
$expectedOnLoad = '2, 5, 0, "helper1", "0.2.3"'
if ($onLoadResult -ne $expectedOnLoad) {
    throw "Smoke de onLoad retornou '$onLoadResult'; esperado '$expectedOnLoad'."
}

$copyPersistenceHarness = @'
local timeQueue = {}
local helper = nil
local helperState = nil
local defaultRuntimeState = {schemaVersion = 1, runtimeVersion = '0.2.3', mp = 21, effects = {duel = false}}
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
                return {ok = true, version = '0.2.3', parentGuid = 'panel-copy'}
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
local candidateSource = '-- CORVAN_RUNTIME candidate v0.2.3'
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
            activeVersion = CANDIDATE_HEALTH_OK and '0.2.3' or 'broken'
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
    manifest = {version = '0.2.3', commitSha = '0123456789abcdef0123456789abcdef01234567'},
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

function Invoke-TransactionSmoke([bool]$healthy, [string]$bootstrapSource = $bootstrap) {
    $runner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
    $runner.Globals.Set('CANDIDATE_HEALTH_OK', [MoonSharp.Interpreter.DynValue]::NewBoolean($healthy))
    return $runner.DoString($bootstrapSource + "`n" + $transactionHarness).ToString()
}

$updateSuccess = Invoke-TransactionSmoke $true
$expectedUpdateSuccess = '"0.2.3", true, false, false, "candidate-guid", 23, true, false'
if ($updateSuccess -ne $expectedUpdateSuccess) {
    throw "Smoke de update retornou '$updateSuccess'; esperado '$expectedUpdateSuccess'."
}

$updateRollback = Invoke-TransactionSmoke $false
$expectedUpdateRollback = '"0.1.2", false, true, false, "rollback-guid", 23, false, true'
if ($updateRollback -ne $expectedUpdateRollback) {
    throw "Smoke de rollback retornou '$updateRollback'; esperado '$expectedUpdateRollback'."
}

$legacyUpdateSuccess = Invoke-TransactionSmoke $true $legacyBootstrap
if ($legacyUpdateSuccess -ne $expectedUpdateSuccess) {
    throw "Bootstrap congelado 1.0.2 não instalou a transação v0.2.3: '$legacyUpdateSuccess'."
}

$legacyLatestShortCircuitHarness = @'
local manifestDownloads = 0
local downloadedTag = nil
local finishMessage = nil
local finishError = nil

local release = {
    tag_name = 'v0.2.0', draft = false, prerelease = false,
    assets = {{
        name = MANIFEST_ASSET_NAME,
        browser_download_url = TRUSTED_RUNTIME_PREFIX .. 'v0.2.0/' .. MANIFEST_ASSET_NAME
    }}
}

JSON = {
    decode = function(text)
        if text == 'LATEST_V020' then return release end
        return nil
    end,
    encode = function(_) return '{}' end
}
Wait = {time = function(callback, _) callback() end}
WebRequest = {
    custom = function(url, _, _, _, _, complete)
        assert(url == RELEASE_LATEST_API_URL)
        complete({
            is_error = false, response_code = 200, text = 'LATEST_V020',
            getResponseHeader = function(name)
                if name == 'ETag' then return 'legacy-v020-etag' end
                return nil
            end
        })
        return {dispose = function() end}
    end
}

downloadManifest = function(_, _, releaseTag, _)
    manifestDownloads = manifestDownloads + 1
    downloadedTag = releaseTag
end
finishUpdate = function(_, message, isError)
    finishMessage = message
    finishError = isError
end

local function run(installedVersion, serial, storedEtag)
    state = defaultState()
    state.runtimeVersion = installedVersion
    state.releaseEtag = storedEtag
    update.active = true
    update.serial = serial
    finishMessage = nil
    finishError = nil
    beginLatestReleaseLookup(serial)
    return finishMessage, finishError
end

local newerMessage, newerError = run('0.2.1', 71, 'stale-legacy-etag')
assert(manifestDownloads == 0)
assert(newerMessage == 'versão instalada é mais recente que a release estável.')
assert(newerError == false and state.releaseEtag == nil)

local equalMessage, equalError = run('0.2.0', 72)
assert(manifestDownloads == 0)
assert(equalMessage == 'já está na versão mais recente.')
assert(equalError == false and state.releaseEtag == 'legacy-v020-etag')

local oldMessage, oldError = run('0.1.9', 73)
assert(oldMessage == nil and oldError == nil)
assert(manifestDownloads == 1 and downloadedTag == 'v0.2.0')

return manifestDownloads, downloadedTag, newerError, equalError
'@

$legacyLatestShortCircuitRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$legacyLatestShortCircuitResult = $legacyLatestShortCircuitRunner.DoString(
    $bootstrap + "`n" + $legacyLatestShortCircuitHarness
).ToString()
if ($legacyLatestShortCircuitResult -ne '1, "v0.2.0", false, false') {
    throw "Smoke de Latest legado retornou '$legacyLatestShortCircuitResult'."
}

$releaseDiscoveryHarness = @'
local selectedTag = nil
local failureReason = nil
local responseMode = 'normal'

local function manifestAsset(tag)
    return {
        name = 'arcane-test-manifest.json',
        browser_download_url = TRUSTED_RUNTIME_PREFIX .. tag .. '/arcane-test-manifest.json'
    }
end

local function stable(tag)
    return {tag_name = tag, draft = false, prerelease = false, assets = {manifestAsset(tag)}}
end

local pageOne = {}
pageOne[1] = stable('arcane-test-v1.5.0')
for index = 2, 100 do
    pageOne[index] = stable('outro-v0.0.' .. tostring(index))
end
local pageTwo = {
    stable('arcane-test-v1.10.0'),
    {tag_name = 'arcane-test-v9.0.0', draft = true, prerelease = false, assets = {manifestAsset('arcane-test-v9.0.0')}},
    {tag_name = 'arcane-test-v8.0.0', draft = false, prerelease = true, assets = {manifestAsset('arcane-test-v8.0.0')}},
    stable('arcane-test-v2.0.0'),
    {tag_name = 'arcane-test-v3.0.0', draft = false, prerelease = false,
        assets = {{name = 'arcane-test-manifest.json', browser_download_url = 'https://evil.invalid/manifest.json'}}},
    stable('arcane-testing-v99.0.0')
}
local fullPage = {}
for index = 1, 100 do fullPage[index] = stable('outro-v9.9.' .. tostring(index)) end

JSON = {
    decode = function(text)
        if text == 'PAGE_ONE' then return pageOne end
        if text == 'PAGE_TWO' then return pageTwo end
        if text == 'FULL_PAGE' then return fullPage end
        return nil
    end,
    encode = function(_) return '{}' end
}
Wait = {time = function(callback, _) callback() end}
WebRequest = {
    custom = function(url, _, _, _, _, complete)
        if responseMode == 'rate-limit' then
            complete({is_error = false, response_code = 403, text = ''})
        elseif responseMode == 'malformed' then
            complete({is_error = false, response_code = 200, text = 'MALFORMED'})
        elseif responseMode == 'full' then
            complete({is_error = false, response_code = 200, text = 'FULL_PAGE'})
        elseif string.find(url, '&page=1', 1, true) then
            complete({is_error = false, response_code = 200, text = 'PAGE_ONE'})
        else
            complete({is_error = false, response_code = 200, text = 'PAGE_TWO'})
        end
        return {dispose = function() end}
    end
}

downloadManifest = function(_, _, releaseTag, _)
    selectedTag = releaseTag
end
finishUpdate = function(_, reason, _)
    failureReason = reason
end
state = defaultState()
update.active = true
update.serial = 41
beginNamespacedReleasePage(41, 1, nil, nil)
assert(selectedTag == 'arcane-test-v2.0.0')

responseMode = 'rate-limit'
selectedTag = nil
failureReason = nil
update.active = true
update.serial = 42
beginNamespacedReleasePage(42, 1, nil, nil)
assert(selectedTag == nil and string.find(failureReason, 'HTTP 403', 1, true))

responseMode = 'malformed'
failureReason = nil
update.active = true
update.serial = 43
beginNamespacedReleasePage(43, 1, nil, nil)
assert(string.find(failureReason, 'JSON', 1, true) or string.find(failureReason, 'inválid', 1, true))

responseMode = 'full'
failureReason = nil
update.active = true
update.serial = 44
beginNamespacedReleasePage(44, 1, nil, nil)
assert(string.find(failureReason, 'releases demais', 1, true))
return 'arcane-test-v2.0.0', failureReason ~= nil
'@
$releaseDiscoveryRunner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$releaseDiscoveryResult = $releaseDiscoveryRunner.DoString($fixtureBootstrap + "`n" + $releaseDiscoveryHarness).ToString()
if ($releaseDiscoveryResult -ne '"arcane-test-v2.0.0", true') {
    throw "Smoke de descoberta retornou '$releaseDiscoveryResult'."
}

Write-Output "MoonSharp OK: runtimes/bootstraps Corvan+Arcane+Spentar compilam; regras, estado, UI, helpers, cache e dados dos 3 personagens isolados; combate $runtimeFlowResult; SHA-256 em $integrityFrames frames; onLoad, cópia persistente, watchdog, update e rollback seguros"
