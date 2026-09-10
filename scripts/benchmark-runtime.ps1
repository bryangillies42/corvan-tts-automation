[CmdletBinding()]
param(
    [string] $CharacterId = 'corvan',
    [string] $BaselineRef = 'a8508135171fa42c2fef73d03e73060d2c342250',
    [string] $CandidateRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(1, 1000)][int] $Iterations = 100,
    [string] $ReportPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lua-test-utils.ps1')
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$candidateSha = (& git -C $CandidateRoot rev-parse HEAD).Trim()
$dirty = @(& git -C $CandidateRoot status --porcelain).Count -gt 0
$baselineSha = (& git -C $repositoryRoot rev-parse $BaselineRef).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Baseline ref unavailable' }
$benchmarkRoot = Join-Path ([IO.Path]::GetTempPath()) ('corvan-benchmark-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $benchmarkRoot
$archive = Join-Path $benchmarkRoot 'baseline.zip'
& git -C $repositoryRoot archive --format=zip --output=$archive $baselineSha
if ($LASTEXITCODE -ne 0) { throw 'Baseline archive failed' }
$baselineRoot = Join-Path $benchmarkRoot 'baseline'
Expand-Archive -LiteralPath $archive -DestinationPath $baselineRoot
$specs = @{}
foreach ($variant in @('before', 'after')) {
    $sourceRoot = if ($variant -eq 'before') { $baselineRoot } else { $CandidateRoot }
    $outputRoot = Join-Path $benchmarkRoot $variant
    & node (Join-Path $sourceRoot 'scripts/build.mjs') --root $sourceRoot --character $CharacterId --out $outputRoot
    if ($LASTEXITCODE -ne 0) { throw "$variant build failed" }
    $registry = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot 'characters/registry.json') | ConvertFrom-Json
    $profile = $registry.characters | Where-Object id -eq $CharacterId
    $object = Get-Content -Raw -LiteralPath (Join-Path $outputRoot $profile.files.savedObject) | ConvertFrom-Json
    $specs[$variant] = @{
        runtime = Get-Content -Raw -LiteralPath (Join-Path $outputRoot $profile.files.runtime)
        bootstrap = $object.ObjectStates[0].LuaScript
        ui = $object.ObjectStates[0].XmlUI
        config = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot ($profile.sourceDir + '/character.json')) | ConvertFrom-Json
    }
}
# Only load the interpreter DLL. No connection to the game, UI, or external API.
$dll = Join-Path ${env:ProgramFiles(x86)} 'Steam/steamapps/common/Tabletop Simulator/Tabletop Simulator_Data/Managed/MoonSharp.Interpreter.dll'
if (-not (Test-Path -LiteralPath $dll)) { throw 'Local MoonSharp interpreter DLL not found' }
Add-Type -Path $dll
$runner = [MoonSharp.Interpreter.Script]::new([MoonSharp.Interpreter.CoreModules]::Preset_Complete)
foreach ($variant in @('before', 'after')) {
    $prefix = $variant.ToUpperInvariant()
    foreach ($field in @('runtime', 'bootstrap', 'ui')) {
        $runner.Globals.Set($prefix + '_' + $field.ToUpperInvariant(), [MoonSharp.Interpreter.DynValue]::NewString($specs[$variant][$field]))
    }
    $literal = ConvertTo-LuaLiteral $specs[$variant].config
    $null = $runner.DoString("${prefix}_CONFIG = $literal")
}
$pages = @{}
$xml = [xml] ('<Root>' + $specs.before.ui + '</Root>')
foreach ($element in $xml.SelectNodes('//*[@id]')) {
    $ancestor = $element.ParentNode
    while ($null -ne $ancestor) {
        if ($ancestor.id -like 'page_*') { $pages[$element.id] = $ancestor.id.Substring(5); break }
        $ancestor = $ancestor.ParentNode
    }
}
$null = $runner.DoString('UI_PAGES = ' + (ConvertTo-LuaLiteral $pages))
$runner.Globals.Set('ITERATIONS', [MoonSharp.Interpreter.DynValue]::NewNumber($Iterations))
$null = $runner.DoString((Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'tests/lua/runtime-world.lua')))
try {
    $result = $runner.DoString((Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'tests/lua/runtime-benchmark.lua'))).String
} catch {
    $cause = $_.Exception.InnerException
    if ($cause.DecoratedMessage) { throw $cause.DecoratedMessage }
    throw
}
$rows = @($result | ConvertFrom-Csv -Delimiter "`t" | ForEach-Object {
    $before = [int] $_.before
    $after = [int] $_.after
    [ordered]@{scenario=$_.scenario; metric=$_.metric; before=$before; after=$after;
        reductionPercent=if ($before -gt 0) { [math]::Round(100 * ($before - $after) / $before, 2) } else { $null }}
})
$report = [ordered]@{characterId=$CharacterId; baselineCommit=$baselineSha; candidateCommit=$candidateSha;
    candidateDirty=$dirty; iterations=$Iterations; semanticEquivalence=$true;
    methodology='Offline MoonSharp, real built sources, deterministic queued host, warm caches; counts are not FPS or wall-clock speed. copyTables counts table allocations inside Core.deepCopy; equivalence-check exports are excluded.';
    sourceHashes=@{runtime=(Get-FileHash -LiteralPath (Join-Path $benchmarkRoot ('after/' + $profile.files.runtime)) -Algorithm SHA256).Hash;
        bootstrap=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($specs.after.bootstrap)))};
    results=$rows}
$json = $report | ConvertTo-Json -Depth 10
if ($ReportPath) {
    $reportFullPath = [IO.Path]::GetFullPath($ReportPath)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $reportFullPath) -Force
    [IO.File]::WriteAllText($reportFullPath, $json + "`n")
}
$rows | ForEach-Object { [pscustomobject] $_ } | Format-Table -AutoSize
Write-Output "Semantic equivalence passed. Baseline: $baselineSha. Sources: $benchmarkRoot"
