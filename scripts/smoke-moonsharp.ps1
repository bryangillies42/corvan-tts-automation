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
$runtime = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\corvan-runtime.lua')
$savedObject = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\Corvan_Duras_Console.json') | ConvertFrom-Json
$manifest = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'dist\manifest.json') | ConvertFrom-Json
$bootstrap = $savedObject.ObjectStates[0].LuaScript

$compiler = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$null = $compiler.LoadString($runtime)
$null = $compiler.LoadString($bootstrap)

$rulesHarness = @'
local character = {
    defense = 20,
    weapons = {
        sword = {
            attack = 8,
            damage = {count = 1, sides = 8, bonus = 4},
            critical = {min = 19, multiplier = 2}
        }
    },
    skills = {fortitude = {modifier = 9, resistance = true}},
    powers = {
        duel = {attackModifier = 2, damageModifier = 2},
        combatDefensive = {attackModifier = -2, defenseModifier = 5},
        baluarte = {defenseModifier = 2, resistanceModifier = 2},
        armedTower = {damageModifier = 5}
    }
}
local state = {
    effects = {
        duel = true,
        combatDefensiveArmed = true,
        combatDefensiveDefense = true,
        baluarte = true,
        armedTower = true
    }
}
local damage = CorvanRules.calculateDamageSpec(character, state, 'sword', true)
return CorvanRules.calculateAttackModifier(character, state, 'sword'),
    CorvanRules.calculateDefense(character, state),
    CorvanRules.calculateSkillModifier(character, state, 'fortitude'),
    damage.count, damage.sides, damage.bonus,
    CorvanRules.isThreat(character, 'sword', 19)
'@

$runner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
$actual = $runner.DoString($runtime + "`n" + $rulesHarness).ToString()
$expected = '8, 27, 11, 2, 8, 11, true'
if ($actual -ne $expected) {
    throw "Smoke de regras retornou '$actual'; esperado '$expected'."
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

Write-Output "MoonSharp OK: runtime/bootstrap compilam; regras $actual; SHA-256 incremental em $integrityFrames frames"
