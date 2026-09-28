<#
    The badge image as desktop and lock screen for every domain user and
    computer. It goes from ../../wallpapers into NETLOGON, where DFSR
    replicates it to every DC and clients read it by UNC path.

    Runs on the primary DC after Users, since it links to the same OUs.
#>
#Requires -Modules ActiveDirectory
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName,
    [string]$UserPassword
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"
. "$PSScriptRoot\..\Invoke-AsDomainAdmin.ps1"

# The local SYSVOL path is writable from the SSH session; only the UNC one
# needs network credentials.
$Netlogon = (Get-SmbShare -Name NETLOGON).Path
$Source   = "$PSScriptRoot\..\..\wallpapers\middlefart-lockscreen-badge-3840x2160.png"
$Target   = "$Netlogon\lockscreen.png"
if ((Test-Path $Target) -and (Get-FileHash $Target).Hash -eq (Get-FileHash $Source).Hash) {
    Write-Host "lockscreen.png already in NETLOGON"
} else {
    Copy-Item -Path $Source -Destination $Target -Force
    Write-Host "Copied $(Split-Path $Source -Leaf) to NETLOGON\lockscreen.png"
}
# The dannebrog desktop image an earlier version put there.
# ponytail: drop once every DC has run this since.
Remove-Item "$Netlogon\desktop.png" -ErrorAction SilentlyContinue

$Vars = @{
    GpoName     = 'GPO_MFRACE_Wallpaper'
    UsersOU     = "OU=Users,$($Config.OUBase)"
    ComputersOU = "OU=Computers,$($Config.OUBase)"
    Share       = "\\$($Config.DomainName)\NETLOGON"
}
Invoke-AsDomainAdmin -Label 'wallpaper-gpo' -Variables $Vars -Script {
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) {
        Write-Host "GPO $GpoName already exists"
    } else {
        New-GPO -Name $GpoName | Out-Null
        Write-Host "Created GPO $GpoName"
    }
    # "Desktop Wallpaper": the policy's own style numbers (0 Center, 2 Stretch,
    # 3 Fit, 4 Fill), not Control Panel's. Applied at the user's next logon.
    $Desktop = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-GPRegistryValue -Name $GpoName -Key $Desktop -ValueName 'Wallpaper' -Type String -Value "$Share\lockscreen.png" | Out-Null
    Set-GPRegistryValue -Name $GpoName -Key $Desktop -ValueName 'WallpaperStyle' -Type String -Value '4' | Out-Null
    # "Force a specific default lock screen image". Only honoured by
    # Enterprise, Education and Server editions - Pro ignores it.
    Set-GPRegistryValue -Name $GpoName -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization' `
        -ValueName 'LockScreenImage' -Type String -Value "$Share\lockscreen.png" | Out-Null
    Write-Host "Wallpaper policy set in $GpoName"

    foreach ($Target in $UsersOU, $ComputersOU) {
        if ((Get-GPInheritance -Target $Target).GpoLinks.DisplayName -contains $GpoName) {
            Write-Host "GPO already linked to $Target"
        } else {
            New-GPLink -Name $GpoName -Target $Target | Out-Null
            Write-Host "Linked GPO to $Target"
        }
    }
}
