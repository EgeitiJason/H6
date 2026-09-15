<#
    File server: Faelles, Afdelinger and Privat on the data disk (D:), with a
    folder per department (leaf OU under Users, see ../Get-Departments.ps1)
    for its SG- group and a private folder per user.
    Rewrite of h5's Create-FileSrv, whose ACL helper also stripped SYSTEM and
    which left the Afdelinger and Privat roots inheriting the drive's default
    "Users may create folders".

    Private folders come from ../Users/users.csv; the groups and users must already
    exist in AD - SRV-ADDS-01 runs the Users role earlier in inventory.csv.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName,
    [string]$UserPassword
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"
$Users  = Import-Csv "$PSScriptRoot\..\Users\users.csv"
$Domain = $Config.DomainName.Split('.')[0].ToUpper()   # NetBIOS name
$Base   = 'D:\Shares'

. "$PSScriptRoot\..\Get-Departments.ps1"

$Feature = Install-WindowsFeature -Name FS-FileServer -IncludeManagementTools
Write-Host "File Server role: $($Feature.ExitCode)"
# A pending restart breaks what follows; take it, pass 2 carries on.
if ($Feature.RestartNeeded -eq 'Yes') { Restart-Computer -Force; exit 3010 }

if (-not (Test-Path 'D:\')) { throw 'D: does not exist - bring the data disk online and format it first' }

# Replaces the folder's ACL with SYSTEM + Administrators full control plus
# $Grant (icacls syntax). Local SIDs only for the fixed part: Domain Admins
# are in Administrators. Resolving domain names needs no user credentials -
# the lookup goes over the computer's own secure channel.
function Set-FolderAcl {
    param([string]$Path, [string[]]$Grant)
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' @Grant | Out-Null
    if ($LASTEXITCODE) { throw "icacls failed on $Path granting $Grant (exit $LASTEXITCODE) - does it exist in AD?" }
}

# Roots of Afdelinger and Privat: Domain Users may list, not write - no
# (OI)(CI), so it stops at the root. Access-based enumeration then hides the
# subfolders a user cannot open.
$Shares = @(
    @{ Name = 'Faelles';    Grant = "$Domain\Domain Users:(OI)(CI)M"; AccessBased = $false }
    @{ Name = 'Afdelinger'; Grant = "$Domain\Domain Users:RX";        AccessBased = $true }
    @{ Name = 'Privat';     Grant = "$Domain\Domain Users:RX";        AccessBased = $true }
)
foreach ($Share in $Shares) {
    $Path = "$Base\$($Share.Name)"
    Set-FolderAcl -Path $Path -Grant $Share.Grant

    if (Get-SmbShare -Name $Share.Name -ErrorAction SilentlyContinue) {
        Write-Host "Share $($Share.Name) already exists"
    } else {
        # Share permissions stay broad; NTFS does the real gating.
        New-SmbShare -Name $Share.Name -Path $Path `
            -FullAccess "$Domain\Domain Admins" -ChangeAccess "$Domain\Domain Users" | Out-Null
        Write-Host "Created share $($Share.Name) -> $Path"
    }
    if ($Share.AccessBased) {
        Set-SmbShare -Name $Share.Name -FolderEnumerationMode AccessBased -Force
    }
}

# One flat folder per department (leaf OU under Users), for its SG- group only.
foreach ($Dept in Get-Departments) {
    Set-FolderAcl -Path "$Base\Afdelinger\$Dept" -Grant "$Domain\SG-${Dept}:(OI)(CI)M"
    Write-Host "Afdelinger\$Dept -> SG-$Dept"
}

foreach ($User in $Users) {
    Set-FolderAcl -Path "$Base\Privat\$($User.sam)" -Grant "$Domain\$($User.sam):(OI)(CI)M"
}
Write-Host "$($Users.Count) private folders in place"
