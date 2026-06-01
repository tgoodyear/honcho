<#
.SYNOPSIS
    Refreshes the Azure OpenAI AD token used by Honcho containers.

.DESCRIPTION
    Acquires an Entra ID token for cognitiveservices.azure.com from az CLI
    (MSIT tenant). If the token in ~/honcho/.env is already current, the
    script is a fast no-op. Otherwise it atomically updates .env and
    force-recreates the api and deriver containers so they pick up the
    new token.

    Notes on why this is idempotent + cadence-tolerant:
    - `az account get-access-token` returns the cached MSAL token until
      ~5 min before expiry. Calling it every few minutes is cheap and
      most calls return the same token.
    - The script compares the new token's JWT `exp` claim against the
      current .env token's exp. If unchanged AND there's still meaningful
      lifetime left, it exits without restarting containers.
    - When MSAL finally hands us a fresh token, we restart promptly,
      minimizing the window the container holds an expired token.

    Designed to run as a Windows Scheduled Task every 5 minutes.
    Token TTL is ~89 min; cadence + idempotency keeps the outage window
    bounded by one cycle.

.NOTES
    Log file: ~/honcho/token-refresh.log
    Task name: HonchoTokenRefresh
    Lock:     mutex Global\HonchoTokenRefresh (prevents concurrent runs)
#>

[CmdletBinding()]
param(
    [switch]$SkipContainerRestart,
    [switch]$Force  # bypass idempotency check; always update + restart
)

$ErrorActionPreference = 'Stop'

$honchoDir = Join-Path $env:USERPROFILE 'honcho'
$envPath   = Join-Path $honchoDir '.env'
$logPath   = Join-Path $honchoDir 'token-refresh.log'

# Hard skip restart if the freshly acquired token has less than this many
# minutes of life left. Avoids restarting containers with garbage we just
# pulled from a borderline cache.
$MinTtlMinutesToRestart = 15

# If the current .env token still has more than this many minutes of life,
# treat as up-to-date and skip even if a new token would also be valid.
$NoOpIfCurrentTtlAbove = 10

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $logPath -Value $entry -Encoding UTF8
    if ($Level -eq 'ERROR') { Write-Error $Message }
    else { Write-Host $entry }
}

function Get-JwtExp {
    param([string]$Token)
    if (-not $Token -or $Token -notmatch '^eyJ') { return $null }
    $parts = $Token.Split('.')
    if ($parts.Length -lt 2) { return $null }
    try {
        $payload = $parts[1]
        $pad = (4 - ($payload.Length % 4)) % 4
        $payload += '=' * $pad
        $bytes = [System.Convert]::FromBase64String($payload.Replace('-','+').Replace('_','/'))
        $json = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$json.exp).UtcDateTime
    } catch {
        return $null
    }
}

function Get-EnvToken {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    $m = [regex]::Match($raw, 'AZURE_OPENAI_AD_TOKEN=([^\r\n]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Trim log to last 200 lines to prevent unbounded growth
if (Test-Path $logPath) {
    $lines = Get-Content $logPath -Tail 200 -ErrorAction SilentlyContinue
    if ($lines) { Set-Content $logPath -Value $lines -Encoding UTF8 }
}

# Single-instance lock so the scheduled task and a manual run can't collide.
$mutex = New-Object System.Threading.Mutex($false, 'Global\HonchoTokenRefresh')
$haveLock = $false
try {
    $haveLock = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
    if (-not $haveLock) {
        Write-Log 'Another refresh run holds the mutex; exiting.' 'WARN'
        exit 0
    }

    Write-Log '--- Token refresh started ---'

    # 1. Validate prerequisites
    if (-not (Test-Path $envPath)) {
        Write-Log ".env not found at $envPath" 'ERROR'
        exit 1
    }

    $azPath = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azPath) {
        Write-Log 'az CLI not found in PATH' 'ERROR'
        exit 1
    }

    # 2. Inspect the token currently in .env (proxy for what the containers run with;
    #    valid because this script is the sole writer and we always restart when we write).
    $currentToken = Get-EnvToken -Path $envPath
    $currentExp   = Get-JwtExp -Token $currentToken
    $now          = [DateTime]::UtcNow
    $currentTtlMin = if ($currentExp) { [int]($currentExp - $now).TotalMinutes } else { -1 }

    if (-not $Force -and $currentExp -and $currentTtlMin -gt $NoOpIfCurrentTtlAbove) {
        # .env token still has meaningful life. Peek at az to see if MSAL has minted a
        # newer one already (early proactive refresh). If exp matches, we're done — no
        # disk write, no container restart, no log spam.
        # (This only happens on the cheap path; we still call az below in the normal path.)
    }

    # 3. Acquire token from az (must use MSIT/commercial cloud)
    Write-Log "Current .env token exp: $(if ($currentExp) { $currentExp.ToString('s') + 'Z' } else { '<none>' }) (${currentTtlMin} min left)"
    Write-Log 'Acquiring token from az CLI (MSIT tenant)...'
    try {
        $currentCloud = (az cloud show --query name -o tsv 2>$null) ?? 'AzureCloud'
        if ($currentCloud -ne 'AzureCloud') {
            Write-Log "Switching from $currentCloud to AzureCloud for token acquisition"
            az cloud set --name AzureCloud 2>$null | Out-Null
        }

        $freshToken = az account get-access-token `
            --resource "https://cognitiveservices.azure.com" `
            --tenant "72f988bf-86f1-41af-91ab-2d7cd011db47" `
            --query accessToken -o tsv 2>&1

        if ($currentCloud -ne 'AzureCloud') {
            Write-Log "Restoring cloud to $currentCloud"
            az cloud set --name $currentCloud 2>$null | Out-Null
        }

        if ($LASTEXITCODE -ne 0 -or -not $freshToken -or $freshToken -match 'ERROR') {
            Write-Log "az CLI returned error: $freshToken" 'ERROR'
            exit 1
        }

        if ($freshToken -notmatch '^eyJ') {
            Write-Log "Token does not look like a JWT: $($freshToken.Substring(0,20))..." 'ERROR'
            exit 1
        }
    } catch {
        Write-Log "Failed to acquire token: $_" 'ERROR'
        exit 1
    }

    $freshExp = Get-JwtExp -Token $freshToken
    $freshTtlMin = if ($freshExp) { [int]($freshExp - $now).TotalMinutes } else { -1 }
    Write-Log "Token acquired ($($freshToken.Length) chars, exp $(if ($freshExp) { $freshExp.ToString('s') + 'Z' } else { '<unknown>' }), ${freshTtlMin} min left)"

    # 4. Idempotency: if the .env already has this exact token (same exp) and
    #    there's still life in it, do nothing.
    if (-not $Force) {
        if ($currentToken -and $freshToken -eq $currentToken) {
            Write-Log "No-op: .env already has this token (${currentTtlMin} min left)."
            Write-Log '--- Token refresh completed (no-op) ---'
            exit 0
        }
        if ($currentExp -and $freshExp -and $freshExp -eq $currentExp -and $currentTtlMin -gt $NoOpIfCurrentTtlAbove) {
            Write-Log "No-op: same exp as .env and ${currentTtlMin} min still left."
            Write-Log '--- Token refresh completed (no-op) ---'
            exit 0
        }
    }

    # 5. Refuse to install a near-expired token — that would just create churn
    #    without solving the problem.
    if ($freshTtlMin -ge 0 -and $freshTtlMin -lt $MinTtlMinutesToRestart) {
        Write-Log "Fresh token has only ${freshTtlMin} min left (< ${MinTtlMinutesToRestart}). Skipping update; will retry next tick." 'WARN'
        Write-Log '--- Token refresh completed (skipped) ---'
        exit 0
    }

    # 6. Update .env atomically (write to temp then move).
    Write-Log 'Updating .env...'
    try {
        $envContent = Get-Content $envPath -Raw
        if ($envContent -match 'AZURE_OPENAI_AD_TOKEN=') {
            $envContent = $envContent -replace 'AZURE_OPENAI_AD_TOKEN=.*', "AZURE_OPENAI_AD_TOKEN=$freshToken"
        } else {
            $envContent += "`nAZURE_OPENAI_AD_TOKEN=$freshToken`n"
        }
        $tmpPath = "$envPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $envContent, [System.Text.UTF8Encoding]::new($false))
        Move-Item -Path $tmpPath -Destination $envPath -Force
        Write-Log '.env updated successfully'
    } catch {
        Write-Log "Failed to update .env: $_" 'ERROR'
        exit 1
    }

    # 7. Force-recreate api and deriver containers
    if (-not $SkipContainerRestart) {
        Write-Log 'Force-recreating api and deriver containers...'
        try {
            Push-Location $honchoDir
            $output = podman compose up -d --force-recreate api deriver 2>&1
            Pop-Location

            if ($LASTEXITCODE -ne 0) {
                Write-Log "podman compose failed (exit $LASTEXITCODE): $output" 'ERROR'
                exit 1
            } else {
                Write-Log "Containers recreated successfully (new token valid for ${freshTtlMin} min)"
            }
        } catch {
            Pop-Location -ErrorAction SilentlyContinue
            Write-Log "Container restart failed: $_" 'ERROR'
            exit 1
        }
    }

    Write-Log '--- Token refresh completed ---'
}
finally {
    if ($haveLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
