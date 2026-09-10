<#
    File server role and SMB shares. h5 created one share hardcoded with
    -FullAccess Everyone; this drives shares.csv instead.

    The share list is a placeholder until the real layout is decided - NTFS
    ACLs against the OU-tree groups (IT, HR, Finans, Lager) still to come.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName
)
$ErrorActionPreference = 'Stop'

if (-not (Get-WindowsFeature -Name FS-FileServer).Installed) {
    Install-WindowsFeature -Name FS-FileServer -IncludeManagementTools
    Write-Host "File Server role installed"
} else {
    Write-Host "File Server role already installed"
}

foreach ($Share in Import-Csv "$PSScriptRoot\shares.csv") {
    if (-not (Test-Path $Share.path)) {
        New-Item -Path $Share.path -ItemType Directory -Force | Out-Null
        Write-Host "Created $($Share.path)"
    }

    if (Get-SmbShare -Name $Share.name -ErrorAction SilentlyContinue) {
        Write-Host "Share $($Share.name) already exists"
        continue
    }

    $Params = @{ Name = $Share.name; Path = $Share.path }
    if ($Share.full_access)   { $Params.FullAccess   = $Share.full_access -split ';' }
    if ($Share.change_access) { $Params.ChangeAccess = $Share.change_access -split ';' }
    if ($Share.read_access)   { $Params.ReadAccess   = $Share.read_access -split ';' }

    New-SmbShare @Params | Out-Null
    Write-Host "Created share $($Share.name) -> $($Share.path)"
}
