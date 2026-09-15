# Dot-sourced by roles that need the domain Administrator: expects $Config and
# $AdminPassword in the calling script.

# The SSH session logs in with a key, which gives it no network credentials:
# anything touching AD or the partner server is refused. So those steps run as
# a one-off scheduled task under the domain Administrator's password.
#
# The task unregisters itself as its very last step, and only when the work
# succeeded. A task still registered afterwards therefore means it failed or
# hung - it is then removed here (it holds the password) and this role fails.
function Invoke-AsDomainAdmin {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Script,
        [hashtable]$Variables = @{},
        [int]$TimeoutSeconds = 300
    )
    $TaskName = "deploy-$Label-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $Dir  = 'C:\deploy\tasks'
    $Body = "$Dir\$TaskName.ps1"
    $Log  = "$Dir\$TaskName.log"

    # The body carries the variables, secrets included: admins and SYSTEM only.
    New-Item -Path $Dir -ItemType Directory -Force | Out-Null
    icacls.exe $Dir /inheritance:r /grant 'SYSTEM:(OI)(CI)F' /grant 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null

    $Assignments = foreach ($Key in $Variables.Keys) {
        "`$$Key = '$(([string]$Variables[$Key]) -replace "'", "''")'"
    }
    Set-Content -Path $Body -Encoding ascii -Value @"
`$ErrorActionPreference = 'Stop'
$($Assignments -join "`r`n")
try {
    & {
$Script
    } *>&1 | Out-File -FilePath '$Log' -Append -Encoding ascii
    Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false
} catch {
    "ERROR: `$(`$_ | Out-String)" | Out-File -FilePath '$Log' -Append -Encoding ascii
    exit 1
}
"@

    try {
        $Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Body`""
        Register-ScheduledTask -TaskName $TaskName -Action $Action -RunLevel Highest `
            -User "$($Config.DomainName)\Administrator" -Password $AdminPassword | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Running '$Label' as $($Config.DomainName)\Administrator (task $TaskName)"

        $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $Deadline) {
            $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            # Gone means it removed itself: success. Back to Ready while still
            # registered means it finished without getting there: failure.
            if (-not $Task -or $Task.State -eq 'Ready') { break }
            Start-Sleep -Seconds 2
        }

        if (Test-Path $Log) { Get-Content $Log | ForEach-Object { Write-Host "   $_" } }

        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            $Result = (Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            throw "Task $TaskName did not remove itself (last result $Result) - '$Label' failed, see output above"
        }
        Write-Host "'$Label' done, task removed itself"
    } finally {
        Remove-Item -Path $Body, $Log -Force -ErrorAction SilentlyContinue
    }
}
