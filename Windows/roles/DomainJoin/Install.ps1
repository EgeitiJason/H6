<#
    Joins a member server to the domain. Deliberately separate from BaseServer
    so a domain controller - which must not join anything - just omits it from
    its inventory role list.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"

if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    Write-Host "Already joined to $((Get-CimInstance Win32_ComputerSystem).Domain)"
    return
}

# The DC must be resolvable before Add-Computer will find it.
$Adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $Config.PrimaryDCIP

$Secure     = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force
$Credential = [PSCredential]::new("$($Config.DomainName)\Administrator", $Secure)

Write-Host "Joining $($Config.DomainName)"
Add-Computer -DomainName $Config.DomainName `
    -OUPath "OU=Servers,$($Config.OUBase)" `
    -Credential $Credential -Restart -Force
