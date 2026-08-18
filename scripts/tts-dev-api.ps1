[CmdletBinding()]
param(
    [ValidateSet("list", "exec")]
    [string] $Action = "list",

    [string] $Guid,

    [string] $Lua,

    [string] $CharacterId,

    [int] $TimeoutMs = 8000
)

$ErrorActionPreference = "Stop"

if ($Action -eq "exec" -and ([string]::IsNullOrWhiteSpace($Guid) -or [string]::IsNullOrWhiteSpace($Lua))) {
    throw "The exec action requires both -Guid and -Lua."
}

function Send-TtsMessage {
    param([hashtable] $Message)

    $json = $Message | ConvertTo-Json -Compress -Depth 20
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $client = [System.Net.Sockets.TcpClient]::new()

    try {
        $client.Connect("127.0.0.1", 39999)
        $stream = $client.GetStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    finally {
        $client.Dispose()
    }
}

function Read-TtsMessage {
    param([System.Net.Sockets.TcpListener] $Listener)

    $client = $Listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        try {
            $json = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $client.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json
}

function Get-PropertyValue {
    param(
        [object] $InputObject,
        [string[]] $Names
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function Convert-GmNotesToMetadata {
    param([object] $State)

    $rawNotes = Get-PropertyValue -InputObject $State -Names @(
        "GMNotes", "gmNotes", "gm_notes", "notes"
    )

    $notes = $rawNotes
    if ($rawNotes -is [string] -and -not [string]::IsNullOrWhiteSpace($rawNotes)) {
        try {
            $notes = $rawNotes | ConvertFrom-Json
        }
        catch {
            $notes = $null
        }
    }

    $characterId = [string] (Get-PropertyValue -InputObject $notes -Names @(
        "characterId", "characterID", "character_id"
    ))
    $project = [string] (Get-PropertyValue -InputObject $notes -Names @(
        "project", "repository"
    ))
    $version = [string] (Get-PropertyValue -InputObject $notes -Names @(
        "version", "runtimeVersion"
    ))

    # Releases anteriores à identidade multi-personagem só carregavam o
    # projeto nas GM Notes. Mantemos esses objetos descobríveis sem depender
    # do nome visível do Saved Object.
    $legacyManaged = [string]::Equals($project, "corvan-tts-automation", [System.StringComparison]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($characterId) -and $legacyManaged) {
        $characterId = "corvan"
    }

    [pscustomobject]@{
        managed = (-not [string]::IsNullOrWhiteSpace($characterId)) -or $legacyManaged
        characterId = if ([string]::IsNullOrWhiteSpace($characterId)) { $null } else { $characterId }
        project = if ([string]::IsNullOrWhiteSpace($project)) { $null } else { $project }
        version = if ([string]::IsNullOrWhiteSpace($version)) { $null } else { $version }
        gmNotes = if ($null -eq $rawNotes) { $null } elseif ($rawNotes -is [string]) { $rawNotes } else { $rawNotes | ConvertTo-Json -Compress -Depth 20 }
    }
}

$listener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Parse("127.0.0.1"),
    39998
)
$messages = [System.Collections.Generic.List[object]]::new()
$deadline = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $listener.Start()

    if ($Action -eq "list") {
        Send-TtsMessage -Message @{ messageID = 0 }
    }
    else {
        Send-TtsMessage -Message @{
            messageID = 3
            guid = $Guid
            script = $Lua
        }
    }

    while ($deadline.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 25
            continue
        }

        $message = Read-TtsMessage -Listener $listener
        if ($null -eq $message) {
            continue
        }

        $messages.Add($message)

        if ($Action -eq "list" -and $message.messageID -eq 1) {
            $managedStates = @(
                @($message.scriptStates) |
                    ForEach-Object {
                        $metadata = Convert-GmNotesToMetadata -State $_
                        if (-not $metadata.managed) {
                            return
                        }
                        if (-not [string]::IsNullOrWhiteSpace($CharacterId) -and
                            -not [string]::Equals($metadata.characterId, $CharacterId, [System.StringComparison]::OrdinalIgnoreCase)) {
                            return
                        }

                        [pscustomobject]@{
                            name = Get-PropertyValue -InputObject $_ -Names @("name", "Name")
                            guid = Get-PropertyValue -InputObject $_ -Names @("guid", "GUID")
                            characterId = $metadata.characterId
                            version = $metadata.version
                            project = $metadata.project
                            gmNotes = $metadata.gmNotes
                            scriptLength = ([string] (Get-PropertyValue -InputObject $_ -Names @("script", "LuaScript"))).Length
                            uiLength = ([string] (Get-PropertyValue -InputObject $_ -Names @("ui", "XmlUI"))).Length
                        }
                    }
            )

            $managedStates | ConvertTo-Json -Depth 8
            exit 0
        }

        if ($Action -eq "exec" -and $message.messageID -in @(2, 3, 5)) {
            $message | ConvertTo-Json -Compress -Depth 20
            if (
                $message.messageID -in @(3, 5) -or
                ($message.messageID -eq 2 -and ([string] $message.message).StartsWith("CODEX:"))
            ) {
                exit 0
            }
        }
    }

    $summary = @(
        $messages | ForEach-Object {
            [pscustomobject]@{
                messageID = $_.messageID
                guid = $_.guid
                message = $_.message
                returnValue = $_.returnValue
            }
        }
    )
    throw "Timed out after $TimeoutMs ms. Messages received: $($summary | ConvertTo-Json -Compress -Depth 10)"
}
finally {
    $listener.Stop()
}
