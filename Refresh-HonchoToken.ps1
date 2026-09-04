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

    CREDENTIAL COMPARTMENT
    This script never reads the shared default az profile (~/.Azure). It pins
    AZURE_CONFIG_DIR to -AzureConfigDir (default ~/.azure-msit) so interactive
    work in other tenants (studemo, gov) cannot take Honcho down. Sibling
    compartments already in use: .azure-studemo, .azure-gov, .azure-devops.

    To (re)authenticate this compartment:
        $env:AZURE_CONFIG_DIR = "$env:USERPROFILE\.azure-msit"
        az login --tenant 72f988bf-86f1-41af-91ab-2d7cd011db47
    AZURE_CONFIG_DIR must be set in the SAME process as the az call.
#>

[CmdletBinding()]
param(
    [switch]$SkipContainerRestart,
    [switch]$Force,  # bypass idempotency check; always update + restart

    # Dedicated az CLI credential compartment. Honcho MUST NOT read the shared
    # default profile (~/.Azure): any interactive `az login` or `az account set`
    # to another tenant silently repoints it, every refresh then fails
    # AADSTS50020, and semantic search 500s until a human notices.
    [string]$AzureConfigDir = (Join-Path $env:USERPROFILE '.azure-msit')
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

# Read the token the RUNNING container actually holds. Podman bakes env at container
# CREATE time, so a plain restart (reboot, `podman start`, the Start-Podman task) leaves
# a stale token baked in while .env looks perfectly current. Without this probe the
# script no-ops forever and Honcho's embedding calls 401 silently.
function Get-ContainerToken {
    param([string]$Container = 'honcho-api-1')
    try {
        $t = podman exec $Container printenv AZURE_OPENAI_AD_TOKEN 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $t) { return $null }
        return ($t | Select-Object -First 1).Trim()
    } catch { return $null }
}

# Trim log to last 200 lines to prevent unbounded growth
# Wrapped defensively: this runs before the mutex is acquired below, so a run
# that overlaps a still-writing prior instance can hit a transient file-sharing
# violation here. With $ErrorActionPreference = 'Stop' that would otherwise be
# a terminating error before this run ever reaches Write-Log or the mutex -
# exactly the kind of unattributable, log-free failure this script must never
# produce.
try {
    if (Test-Path $logPath) {
        $lines = Get-Content $logPath -Tail 200 -ErrorAction SilentlyContinue
        if ($lines) { Set-Content $logPath -Value $lines -Encoding UTF8 }
    }
} catch {}

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

    # On Windows `az` is az.cmd, a batch wrapper. Every invocation spawns a cmd.exe
    # child, which paints a console window in the interactive session even though the
    # task launches us under conhost --headless (that only covers this process, not
    # grandchildren). az.cmd does nothing but exec "%~dp0\..\python.exe" -IBm azure.cli,
    # so call that directly and skip the batch layer. Falls back to az.cmd if absent.
    $azPy = Join-Path (Split-Path (Split-Path $azPath.Source -Parent) -Parent) 'python.exe'
    if (Test-Path $azPy) {
        $azExe = $azPy
        $azPre = @('-IBm', 'azure.cli')
    } else {
        $azExe = $azPath.Source
        $azPre = @()
    }

    # 1b. Pin az to Honcho's own credential compartment before any az call.
    #     Reading the shared default profile is what took search down on
    #     2026-08-19: a studemo `az login` repointed ~/.Azure and refresh failed
    #     AADSTS50020 every 5 min for 3.5h. Isolation makes that impossible.
    if (-not (Test-Path $AzureConfigDir)) {
        Write-Log "az credential compartment not found: $AzureConfigDir" 'ERROR'
        Write-Log "Create it with:  `$env:AZURE_CONFIG_DIR='$AzureConfigDir'; az login --tenant 72f988bf-86f1-41af-91ab-2d7cd011db47" 'ERROR'
        exit 1
    }
    $env:AZURE_CONFIG_DIR = $AzureConfigDir
    $azIdentity = (& $azExe @azPre account show --query 'user.name' -o tsv 2>$null)
    Write-Log "az compartment: $AzureConfigDir (identity: $(if ($azIdentity) { $azIdentity } else { '<none>' }))"

    # 2. Inspect the token currently in .env AND the one baked into the running container.
    #    These diverge whenever something other than this script restarts the containers
    #    (machine reboot, `podman start`, the Start-Podman-and-Honcho task): podman bakes
    #    env at CREATE time, so the container keeps a stale token while .env is current.
    $currentToken = Get-EnvToken -Path $envPath
    $currentExp   = Get-JwtExp -Token $currentToken
    $now          = [DateTime]::UtcNow
    $currentTtlMin = if ($currentExp) { [int]($currentExp - $now).TotalMinutes } else { -1 }

    $containerToken  = Get-ContainerToken
    $containerExp    = Get-JwtExp -Token $containerToken
    $containerTtlMin = if ($containerExp) { [int]($containerExp - $now).TotalMinutes } else { -1 }

    # Container is stale if we couldn't read it, it's already expired, or it's older
    # than what .env holds. Any of these means a recreate is required regardless of
    # how healthy .env looks.
    $containerStale = $false
    if ($containerToken) {
        if (-not $containerExp -or $containerExp -lt $now -or ($currentExp -and $containerExp -lt $currentExp)) {
            $containerStale = $true
        }
        Write-Log "Container token exp: $(if ($containerExp) { $containerExp.ToString('s') + 'Z' } else { '<unparseable>' }) (${containerTtlMin} min left)$(if ($containerStale) { ' [STALE - recreate required]' })"
    } else {
        $containerStale = $true
        Write-Log 'HONCTOK-007 container token unreadable; forcing api/deriver recreate.' 'WARN'
    }

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
        $currentCloud = (& $azExe @azPre cloud show --query name -o tsv 2>$null) ?? 'AzureCloud'
        if ($currentCloud -ne 'AzureCloud') {
            Write-Log "Switching from $currentCloud to AzureCloud for token acquisition"
            & $azExe @azPre cloud set --name AzureCloud 2>$null | Out-Null
        }

        $freshToken = & $azExe @azPre account get-access-token `
            --resource "https://cognitiveservices.azure.com" `
            --tenant "72f988bf-86f1-41af-91ab-2d7cd011db47" `
            --query accessToken -o tsv 2>&1

        if ($currentCloud -ne 'AzureCloud') {
            Write-Log "Restoring cloud to $currentCloud"
            & $azExe @azPre cloud set --name $currentCloud 2>$null | Out-Null
        }

        if ($LASTEXITCODE -ne 0 -or -not $freshToken -or $freshToken -match 'ERROR') {
            Write-Log "az CLI returned error: $freshToken" 'ERROR'
            if ("$freshToken" -match 'AADSTS50020') {
                Write-Log "Compartment $AzureConfigDir holds a non-MSIT identity. Re-auth it with:  `$env:AZURE_CONFIG_DIR='$AzureConfigDir'; az login --tenant 72f988bf-86f1-41af-91ab-2d7cd011db47" 'ERROR'
            }
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
    if (-not $Force -and -not $containerStale) {
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
    #    without solving the problem. EXCEPTION: if the container is holding an
    #    already-expired token, even a short-lived fresh one is strictly better than
    #    leaving Honcho's embeddings 401-ing until the next tick.
    if ($freshTtlMin -ge 0 -and $freshTtlMin -lt $MinTtlMinutesToRestart -and -not $containerStale) {
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
