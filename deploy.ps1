[CmdletBinding()]
param(
    [string]$Config = (Join-Path $PSScriptRoot 'config.yaml'),
    [string]$File,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Minimal parser for the two-level "section: / key: value" layout used in config.yaml
function Read-SimpleYaml([string]$Path) {
    $result = @{}
    $section = $null
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw -replace '\s+#.*$', ''
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -notmatch '^(\s*)([\w.-]+):\s*(.*)$') { throw "Unsupported YAML line: $raw" }
        $indent = $Matches[1].Length
        $key = $Matches[2]
        $value = $Matches[3].Trim().Trim('"', "'")
        if ($indent -eq 0) {
            if ($value) { $result[$key] = $value; $section = $null }
            else { $section = @{}; $result[$key] = $section }
        }
        elseif ($null -ne $section) { $section[$key] = $value }
        else { throw "Indented key without a section: $raw" }
    }
    $result
}

function Invoke-Http($Task, [switch]$AllowNotFound) {
    $resp = $Task.GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ($AllowNotFound -and [int]$resp.StatusCode -eq 404) { return $null }
    if (-not $resp.IsSuccessStatusCode) {
        throw "HTTP $([int]$resp.StatusCode) $($resp.RequestMessage.RequestUri): $body"
    }
    $body | ConvertFrom-Json
}

function Write-Step([string]$Message) { $script:stage = $Message; Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[FAILED] $Message" -ForegroundColor Red }

function Wait-Operation([string]$Url) {
    $deadline = (Get-Date).AddSeconds($timeout)
    while ($true) {
        $status = Invoke-Http $client.GetAsync($Url)
        $state = "$($status.state)".ToLower()
        Write-Host "  state: $state" -ForegroundColor DarkGray
        if ($state -in 'success', 'failure') { return $status }
        if ((Get-Date) -ge $deadline) { throw "Timed out after ${timeout}s waiting for $Url" }
        Start-Sleep -Seconds $interval
    }
}

function Get-Versions {
    # 404 means the workflow app is not installed yet
    $result = Invoke-Http $client.GetAsync("$baseUrl/ops/std/bpm/containers/$containerEnc/versions?size=1000") -AllowNotFound
    if ($result) { @($result.versions) } else { @() }
}

function Get-EnvVars([string]$Version) {
    $result = Invoke-Http $client.GetAsync("$baseUrl/ops/std/bpm/containers/$containerEnc/versions/$([uri]::EscapeDataString($Version))/env_vars")
    @($result.pairs)
}

$logDir = Join-Path $PSScriptRoot 'logs'
[void](New-Item -ItemType Directory -Path $logDir -Force)
$stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$logFile = Join-Path $logDir "deploy-$stamp.log"
Start-Transcript -LiteralPath $logFile | Out-Null

$failed = $false
$stage = 'Startup'
$package = $null
$snapshotName = $null
$client = $null

try {
    Write-Step 'Reading config'
    $cfg = Read-SimpleYaml $Config
    $baseUrl = $cfg.server.base_url.TrimEnd('/')
    if (-not $cfg.app.container) { throw 'app.container (workflow app acronym) is missing in config' }
    $containerEnc = [uri]::EscapeDataString($cfg.app.container)
    $interval = if ($cfg.poll.interval_seconds) { [int]$cfg.poll.interval_seconds } else { 10 }
    $timeout = if ($cfg.poll.timeout_seconds) { [int]$cfg.poll.timeout_seconds } else { 1800 }
    Write-Ok "Config loaded: $Config"

    $passwordEnv = if ($cfg.auth.password_env) { $cfg.auth.password_env } else { 'PASSWORD' }
    $password = [Environment]::GetEnvironmentVariable($passwordEnv)
    if (-not $password) {
        $secure = Read-Host "Password for $($cfg.auth.username)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    Write-Step 'Selecting package'
    if ($File) {
        $package = Get-Item -LiteralPath $File
    }
    else {
        $dir = if ($cfg.package.directory) { $cfg.package.directory } else { '.' }
        if (-not [IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $PSScriptRoot $dir }
        $pattern = if ($cfg.package.pattern) { $cfg.package.pattern } else { '*.zip' }
        $package = Get-ChildItem -LiteralPath $dir -Filter $pattern -File |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $package) { throw "No files matching '$pattern' found in $dir" }
    }
    Write-Ok "Package: $($package.FullName)"

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($cfg.auth.username):$password"))
    $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Basic', $basic)
    $client.DefaultRequestHeaders.Accept.Add((New-Object System.Net.Http.Headers.MediaTypeWithQualityHeaderValue('application/json')))

    Write-Step 'Logging in'
    $loginBody = @{
        refresh_groups     = $cfg.login.refresh_groups -eq 'true'
        requested_lifetime = [int]$cfg.login.requested_lifetime
    } | ConvertTo-Json
    $json = New-Object System.Net.Http.StringContent($loginBody, [Text.Encoding]::UTF8, 'application/json')
    $login = Invoke-Http $client.PostAsync("$baseUrl/ops/system/login", $json)
    if (-not $login.csrf_token) { throw 'Login succeeded but no csrf_token returned' }
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('BPMCSRFToken', $login.csrf_token)
    Write-Ok "Logged in as $($cfg.auth.username)"

    Write-Step 'Reading current default snapshot'
    $before = Get-Versions
    $old = $before | Where-Object { $_.is_default -and $_.active } | Select-Object -First 1
    if ($old) { Write-Ok "Current default snapshot: $($old.version_name) ($($old.version))" }
    else { Write-Warn 'No active default snapshot found; env var sync will be skipped' }

    $query = ($cfg.install.GetEnumerator() | ForEach-Object {
        "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString($_.Value))"
    }) -join '&'

    if ($DryRun) {
        Write-Warn "[dry run] Would install $($package.Name) with: $query"
        if ($old) { Write-Warn "[dry run] Would sync env vars from $($old.version) to the new snapshot" }
        return
    }

    Write-Step "Installing $($package.Name)"
    $stream = [IO.File]::OpenRead($package.FullName)
    try {
        $fileContent = New-Object System.Net.Http.StreamContent($stream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/x-zip-compressed')
        $form = New-Object System.Net.Http.MultipartFormDataContent
        $form.Add($fileContent, 'install_file', $package.Name)
        $submit = Invoke-Http $client.PostAsync("$baseUrl/ops/std/bpm/containers/install?$query", $form)
    }
    finally { $stream.Dispose() }
    if (-not $submit.url) { throw 'Install submitted but no status url returned' }
    Write-Host "Status url: $($submit.url)"

    $status = Wait-Operation $submit.url
    if ($status.result.details) { Write-Host $status.result.details }
    if ($status.result.details -match 'Snapshot:\s*(\S+)') { $snapshotName = $Matches[1] }
    if ($status.state -ne 'success') { throw 'Install finished with state failure' }
    Write-Ok 'Install succeeded'

    if (-not $old) { return }
    Write-Step 'Detecting new snapshot'
    $beforeIds = @($before | ForEach-Object { $_.id })
    $new = Get-Versions | Where-Object { $_.id -notin $beforeIds } |
        Sort-Object creation_date -Descending | Select-Object -First 1
    if (-not $new) {
        Write-Warn 'No new snapshot detected after install; env var sync skipped'
        return
    }
    $snapshotName = $new.version_name
    Write-Ok "New snapshot: $($new.version_name) ($($new.version))"

    Write-Step "Syncing env vars $($old.version) -> $($new.version)"
    $syncUrl = "$baseUrl/ops/std/bpm/containers/$containerEnc/versions/$([uri]::EscapeDataString($old.version))/env_vars/sync?target_version=$([uri]::EscapeDataString($new.version))"
    $sync = Invoke-Http $client.PostAsync($syncUrl, $null)
    if (-not $sync.url) { throw 'Env var sync submitted but no status url returned' }
    $syncStatus = Wait-Operation $sync.url
    if ($syncStatus.state -ne 'success') { throw 'Env var sync finished with state failure' }
    Write-Ok 'Env var sync succeeded'

    Write-Step 'Verifying env vars'
    $oldVars = @{}
    Get-EnvVars $old.version | ForEach-Object { $oldVars["$($_.container_acronym)/$($_.name)"] = $_.value }
    $rows = Get-EnvVars $new.version | ForEach-Object {
        $key = "$($_.container_acronym)/$($_.name)"
        $check = if (-not $oldVars.ContainsKey($key)) { 'NEW' } elseif ($oldVars[$key] -eq $_.value) { 'OK' } else { 'DIFF' }
        # Keep likely secrets out of the log file
        $secret = $_.name -match 'pass|pwd|secret|token|key'
        [pscustomobject]@{
            Check     = $check
            Container = $_.container_acronym
            Name      = $_.name
            Value     = if ($secret) { '****' } else { $_.value }
            OldValue  = if ($check -ne 'DIFF') { '' } elseif ($secret) { '****' } else { $oldVars[$key] }
        }
    }
    Write-Host "Env vars on $($new.version) (compared with $($old.version)):"
    foreach ($line in ($rows | Format-Table -AutoSize | Out-String -Stream -Width 300)) {
        $color = switch -Regex ($line) { '^DIFF' { 'Yellow' } '^NEW' { 'Cyan' } '^OK' { 'Green' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
    $diffs = @($rows | Where-Object Check -eq 'DIFF').Count
    if ($diffs) { Write-Warn "$diffs env var(s) differ from $($old.version)" }
    else { Write-Ok 'Env vars match the previous snapshot' }
}
catch {
    $failed = $true
    Write-Fail "$stage - $($_.Exception.Message)"
}
finally {
    if ($client) { $client.Dispose() }
    if ($failed) { Write-Host "`nDEPLOYMENT FAILED" -ForegroundColor Red }
    elseif ($DryRun) { Write-Host "`nDRY RUN COMPLETED" -ForegroundColor Green }
    else { Write-Host "`nDEPLOYMENT SUCCEEDED" -ForegroundColor Green }
    Stop-Transcript | Out-Null
    $suffix = if ($snapshotName) { $snapshotName } elseif ($package) { $package.BaseName } else { 'unknown' }
    if ($DryRun) { $suffix += '-dryrun' }
    if ($failed) { $suffix += '-FAILED' }
    $finalLog = Join-Path $logDir ("deploy-$stamp-" + ($suffix -replace '[^\w.-]+', '_') + '.log')
    Move-Item -LiteralPath $logFile -Destination $finalLog
    Write-Host "Log file: $finalLog"
}
if ($failed) { exit 1 }
