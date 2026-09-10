<#
    Replica domain controller. Both DCs live in the Middelfart AD site, so
    -Site defaults to the primary site rather than naming a second location.

    Prereq: this host's DNS must resolve the domain, i.e. point at
    $Config.PrimaryDCIP and not 127.0.0.1. bootstrap.ps1 sets that.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName,
    [string]$Site
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"

if (-not $Site) { $Site = $Config.PrimarySite }
$ValidSites = @($Config.PrimarySite) + $Config.Sites
if ($Site -notin $ValidSites) {
    throw "Site '$Site' is not one of: $($ValidSites -join ', ')"
}

if ((Get-WindowsFeature -Name AD-Domain-Services).Installed) {
    Write-Host "AD-Domain-Services already installed"
    return
}

$Password   = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force
$Credential = [PSCredential]::new("$($Config.DomainName)\Administrator", $Password)

Write-Host "Installing AD-Domain-Services and promoting into $($Config.DomainName), site $Site"
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
Install-ADDSDomainController -InstallDns `
    -DomainName $Config.DomainName `
    -SiteName $Site `
    -Credential $Credential `
    -SafeModeAdministratorPassword $Password -Force
