# Nightly backup to the external SSD.
#   -Part all   : VPS export + local folder (what the scheduled task runs)
#   -Part vps   : VPS export only
#   -Part local : local folder only (output hidden: no file names anywhere)
# Contains no secret. Passwords are read from %USERPROFILE%\.restic\*.pw by restic itself.
param([ValidateSet('all', 'vps', 'local')][string]$Part = 'all')
$ErrorActionPreference = 'Continue'

$R          = Join-Path $env:USERPROFILE '.restic'
$Log        = Join-Path $R 'backup.log'
$Staging    = Join-Path $env:LOCALAPPDATA 'backup-staging-vps'
$StagingWsl = '/mnt/' + $Staging.Substring(0, 1).ToLower() + ($Staging.Substring(2) -replace '\\', '/')
$PullScript = '/mnt/' + $PSScriptRoot.Substring(0, 1).ToLower() + ($PSScriptRoot.Substring(2) -replace '\\', '/') + '/pull-export.sh'
$Local      = Join-Path $env:USERPROFILE 'my-folder'   # the local folder to protect
$Keep       = @('--keep-daily', '30', '--keep-weekly', '12', '--keep-monthly', '12')

function Log([string]$m) {
    $line = (Get-Date -Format 's') + ' [' + $Part + '] ' + $m
    Add-Content -Path $Log -Value $line -Encoding ascii
    Write-Host $line
}

function Kuma([string]$status, [string]$msg) {
    $f = Join-Path $R 'kuma-push.url'
    if (-not (Test-Path $f)) { return }
    $u = (Get-Content $f -Raw).Trim().Split('?')[0]
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri ($u + '?status=' + $status + '&msg=' + [uri]::EscapeDataString($msg) + '&ping=') | Out-Null
    } catch { Log 'Kuma: heartbeat could not be sent' }
}

# One run at a time
$lockFile = Join-Path $R 'backup.lock'
try { $lock = [IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None') } catch { Log 'Already running, exiting.'; exit 0 }

# restic: winget installs it without a PATH link
$restic = $null
$cmd = Get-Command restic -ErrorAction SilentlyContinue
if ($cmd) { $restic = $cmd.Source } else {
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'restic*.exe' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { $restic = $found.FullName }
}
if (-not $restic) { Log 'FAILED: restic not found.'; if ($Part -eq 'all') { Kuma 'down' 'restic not found' }; exit 2 }

# The SSD is recognised by its marker file, never by its drive letter
$target = $null
foreach ($d in Get-PSDrive -PSProvider FileSystem) {
    if (Test-Path (Join-Path $d.Root 'backups\.backup-target-marker')) { $target = Join-Path $d.Root 'backups'; break }
}
if (-not $target) { Log 'FAILED: SSD not found (no marker). Nothing written.'; if ($Part -eq 'all') { Kuma 'down' 'SSD not found' }; exit 2 }
Log ('Start. SSD: ' + $target)

$ok = $true

if ($Part -eq 'all' -or $Part -eq 'vps') {
    $repo = Join-Path $target 'restic-vps'
    Log 'VPS: pull and hash check'
    & wsl.exe -d Ubuntu-24.04 -- bash $PullScript $StagingWsl 2>&1 | ForEach-Object { Log ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) {
        Log ('FAILED VPS: pull or hashes (code ' + $LASTEXITCODE + ')'); $ok = $false
    } else {
        & $restic backup $Staging -r $repo --password-file (Join-Path $R 'vps.pw') --tag vps --host my-pc 2>&1 | ForEach-Object { Log ('  ' + $_) }
        if ($LASTEXITCODE -ne 0) { Log ('FAILED VPS: restic backup (code ' + $LASTEXITCODE + ')'); $ok = $false } else {
            & $restic forget -r $repo --password-file (Join-Path $R 'vps.pw') --tag vps @Keep --prune --quiet 2>&1 | ForEach-Object { Log ('  ' + $_) }
            if ($LASTEXITCODE -ne 0) { Log ('WARNING VPS: forget/prune (code ' + $LASTEXITCODE + ')') }
            Log 'VPS: OK'
        }
    }
    # Nothing stays in clear on the internal disk
    if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }
}

if ($Part -eq 'all' -or $Part -eq 'local') {
    $repo = Join-Path $target 'restic-local'
    if (-not (Test-Path $Local)) { Log 'FAILED local: source folder missing'; $ok = $false } else {
        Log 'Local: backup (output hidden, no file names)'
        & $restic backup $Local -r $repo --password-file (Join-Path $R 'local.pw') --tag local --host my-pc --quiet *> $null
        $code = $LASTEXITCODE
        if ($code -ne 0) { Log ('FAILED local: code ' + $code); $ok = $false } else {
            & $restic forget -r $repo --password-file (Join-Path $R 'local.pw') --tag local @Keep --prune --quiet *> $null
            if ($LASTEXITCODE -ne 0) { Log ('WARNING local: forget/prune (code ' + $LASTEXITCODE + ')') }
            Log 'Local: OK'
        }
    }
}

if ($ok) { Log 'Done: OK'; if ($Part -eq 'all') { Kuma 'up' 'OK' }; $rc = 0 }
else     { Log 'Done: FAILED'; if ($Part -eq 'all') { Kuma 'down' 'failed, see backup.log' }; $rc = 1 }
$lock.Close()
exit $rc
