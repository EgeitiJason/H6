<#
    Baseline every Windows server gets. Ported from h5's Server_Basis_Setup.ps1,
    minus two things: the domain join (now the DomainJoin role, so a DC can
    simply not list it) and the self-resuming scheduled task (now deploy.sh's
    job, where you can watch it fail). Hostname and IP are bootstrap.ps1's.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"

if ((Get-TimeZone).Id -ne $Config.TimeZone) {
    Set-TimeZone -Name $Config.TimeZone
    Write-Host "Time zone set to $($Config.TimeZone)"
} else {
    Write-Host "Time zone already $($Config.TimeZone)"
}

$TSPath = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
if ((Get-ItemProperty -Path $TSPath -Name fDenyTSConnections).fDenyTSConnections -ne 0) {
    Set-ItemProperty -Path $TSPath -Name fDenyTSConnections -Value 0
    Set-ItemProperty -Path "$TSPath\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    Write-Host "RDP enabled with NLA"
} else {
    Write-Host "RDP already enabled"
}

# Drive letters, in two passes. Optical drives get pushed to the end of the
# alphabet so data volumes can take D: onwards - the file server expects D:.
$PossibleDrives = [char[]](68..90)   # D..Z
$UsedDrives = { (Get-Volume).DriveLetter | Where-Object { $_ } }

Get-CimInstance -ClassName Win32_Volume -Filter "DriveType = 5" | ForEach-Object {
    $Free = $PossibleDrives | Where-Object { $_ -notin (& $UsedDrives) } | Select-Object -Last 1
    if ($Free -and $_.DriveLetter -ne "${Free}:") {
        Write-Host "Moving optical drive $($_.DriveLetter) to ${Free}:"
        $_ | Set-CimInstance -Property @{ DriveLetter = "${Free}:" }
    }
}

Get-Disk | Where-Object PartitionStyle -eq 'RAW' | ForEach-Object {
    $Free = $PossibleDrives | Where-Object { $_ -notin (& $UsedDrives) } | Select-Object -First 1
    Write-Host "Initialising disk $($_.Number) as ${Free}:"
    Initialize-Disk -Number $_.Number -PartitionStyle GPT | Out-Null
    New-Partition -DiskNumber $_.Number -UseMaximumSize -DriveLetter $Free |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Data' -Confirm:$false | Out-Null
}

Write-Host "BaseServer complete"
