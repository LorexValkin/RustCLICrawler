[CmdletBinding(SupportsShouldProcess)]
param([string]$Time = '10:30', [switch]$HourlyGithub, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$name = if ($HourlyGithub) { 'RustCLI-RepoScout-GitHub-Hourly' } else { 'RustCLI-RepoScout-Daily' }
if ($Remove) {
    if ($PSCmdlet.ShouldProcess($name, 'Remove daily research task')) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
    return
}
$script = Join-Path $PSScriptRoot 'Run-RepoScout.ps1'
$shell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $script + '"'
if ($HourlyGithub) { $arguments += ' -RepositoriesOnly' }
$action = New-ScheduledTaskAction -Execute $shell -Argument $arguments -WorkingDirectory (Split-Path -Parent $PSScriptRoot)
if ($HourlyGithub) {
    $nextHour = (Get-Date).Date.AddHours((Get-Date).Hour + 1)
    $trigger = New-ScheduledTaskTrigger -Once -At $nextHour -RepetitionInterval (New-TimeSpan -Hours 1)
} else { $trigger = New-ScheduledTaskTrigger -Daily -At $Time }
# No UTC offset: keep 10:30 on the Windows local wall clock across DST changes.
$trigger.StartBoundary = ([DateTime]$trigger.StartBoundary).ToString("yyyy-MM-dd'T'HH:mm:ss")
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
if ($PSCmdlet.ShouldProcess($name, $(if ($HourlyGithub) { 'Register hourly GitHub-only collection' } else { "Register daily at $Time Windows local time" }))) {
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Read-only CPU research crawler. No AI, installs, repository execution, or outward site actions. Writes local RustCLI research inbox.' -Force | Out-Null
    Get-ScheduledTask -TaskName $name | Select-Object TaskName, State, Triggers, Actions
    Get-ScheduledTaskInfo -TaskName $name | Select-Object NextRunTime, LastTaskResult
}
