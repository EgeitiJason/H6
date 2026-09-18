<#
    Web server. Installs IIS with its management tools and nothing else - no
    sites, bindings or certificates yet, so the default site on :80 is what you
    get. DMZ hosts are not domain-joined, so there is nothing here that needs AD.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName,
    [string]$UserPassword
)
$ErrorActionPreference = 'Stop'

$Feature = Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Write-Host "IIS: $($Feature.ExitCode)"
if ($Feature.RestartNeeded -eq 'Yes') { Restart-Computer -Force; exit 3010 }
