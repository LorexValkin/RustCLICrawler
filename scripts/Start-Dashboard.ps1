[CmdletBinding()]
param([int]$Port = 8765)
$ErrorActionPreference = 'Stop'
$url = "http://localhost:$Port"
try {
    $health = Invoke-RestMethod "$url/api/v1/health" -TimeoutSec 2
    if ($health.service -eq 'rustcli-repo-scout') { Write-Output "Dashboard already running: $url"; return }
    throw 'Port is occupied by another application'
} catch {
    if ($_.Exception.Message -eq 'Port is occupied by another application') { throw }
}
$runtime = Join-Path (Split-Path -Parent $PSScriptRoot) '.dashboard'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$shell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$server = Join-Path $PSScriptRoot 'Serve-Dashboard.ps1'
$process = Start-Process -FilePath $shell -ArgumentList ('-NoLogo -NoProfile -NonInteractive -File "' + $server + '" -Port ' + $Port) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runtime 'stdout.log') -RedirectStandardError (Join-Path $runtime 'stderr.log')
$process.Id | Set-Content (Join-Path $runtime 'server.pid')
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 250
    try { $health = Invoke-RestMethod "$url/api/v1/health" -TimeoutSec 1; if ($health.service -eq 'rustcli-repo-scout') { Write-Output "Dashboard ready: $url"; return } } catch { }
    if ($process.HasExited) { throw "Dashboard exited. See $runtime/stderr.log" }
}
throw "Dashboard did not become ready. See $runtime/stderr.log"
