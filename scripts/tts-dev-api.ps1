[CmdletBinding()]
param(
    [ValidateSet("list", "exec")]
    [string] $Action = "list",

    [string] $Guid,

    [string] $Lua,

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
            $corvanStates = @(
                $message.scriptStates |
                    Where-Object { $_.name -like "*Corvan*" } |
                    ForEach-Object {
                        [pscustomobject]@{
                            name = $_.name
                            guid = $_.guid
                            scriptLength = ([string] $_.script).Length
                            uiLength = ([string] $_.ui).Length
                        }
                    }
            )

            $corvanStates | ConvertTo-Json -Depth 5
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
