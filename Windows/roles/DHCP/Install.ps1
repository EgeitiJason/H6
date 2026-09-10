<#
    DHCP, for both servers of the pair. h5 had four near-identical
    DHCP_Scope_*.ps1 files sitting next to a New_DHCP_Scope.ps1 that already
    generalised them but was never wired to data - so this keeps the function
    and drives it from scopes.csv.

    Which server does what is decided from $Config.DhcpServers, not from the
    inventory: the first one owns the scopes, any other one joins failover and
    receives them by replication. Creating scopes locally on the partner first
    would make Add-DhcpServerv4Failover fail.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"

if (-not $SelfName) { $SelfName = $env:COMPUTERNAME }
$Primary = $Config.DhcpServers[0]
$IsPrimary = $SelfName -eq $Primary

if (-not (Get-WindowsFeature -Name DHCP).Installed) {
    Write-Host "Installing DHCP"
    Install-WindowsFeature -Name DHCP -IncludeManagementTools
} else {
    Write-Host "DHCP already installed"
}

$Fqdn = "$SelfName.$($Config.DomainName)"
if (-not (Get-DhcpServerInDC | Where-Object DnsName -eq $Fqdn)) {
    Add-DhcpServerInDC -DnsName $Fqdn
    Write-Host "Authorised $Fqdn in AD"
} else {
    Write-Host "$Fqdn already authorised in AD"
}

function New-DHCPScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Scope_Id,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Name,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Start,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$End,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Gateway,
        [Parameter(ValueFromPipelineByPropertyName)][string]$Lease = '01:00:00',
        [string]$SubnetMask = '255.255.255.0',
        [string]$DomainName,
        [string]$DnsServer
    )

    process {
        if (Get-DhcpServerv4Scope -ScopeId $Scope_Id -ErrorAction SilentlyContinue) {
            Write-Host "Scope $Name ($Scope_Id) already exists"
            return
        }

        Write-Host "Creating scope $Name ($Scope_Id)"
        Add-DhcpServerv4Scope -Name $Name -ScopeId $Scope_Id `
            -StartRange $Start -EndRange $End -SubnetMask $SubnetMask -State Active

        Set-DhcpServerv4OptionValue -ScopeId $Scope_Id -OptionId 1  -Value $SubnetMask
        Set-DhcpServerv4OptionValue -ScopeId $Scope_Id -OptionId 15 -Value $DomainName
        Set-DhcpServerv4OptionValue -ScopeId $Scope_Id -OptionId 6  -Value $DnsServer
        Set-DhcpServerv4OptionValue -ScopeId $Scope_Id -OptionId 3  -Value $Gateway
        Set-DhcpServerv4Scope -ScopeId $Scope_Id -LeaseDuration $Lease
    }
}

if ($IsPrimary) {
    Import-Csv "$PSScriptRoot\scopes.csv" |
        New-DHCPScope -DomainName $Config.DomainName -DnsServer $Config.PrimaryDCIP
} else {
    Write-Host "$SelfName is not the scope owner ($Primary is); joining failover instead"

    $Existing = Get-DhcpServerv4Failover -ErrorAction SilentlyContinue
    if ($Existing) {
        Write-Host "Failover relationship '$($Existing.Name)' already exists"
        return
    }

    $PartnerFqdn = "$Primary.$($Config.DomainName)"
    $ScopeIds = (Get-DhcpServerv4Scope -ComputerName $PartnerFqdn).ScopeId
    if (-not $ScopeIds) {
        Write-Warning "$PartnerFqdn has no scopes yet - deploy it first, then re-run"
        return
    }

    $Secret = ConvertTo-SecureString -String $FailoverSecret -AsPlainText -Force
    Write-Host "Creating 50/50 failover with $PartnerFqdn over $($ScopeIds.Count) scopes"
    Add-DhcpServerv4Failover -ComputerName $PartnerFqdn -PartnerServer $Fqdn `
        -Name "$Primary-$SelfName" -ScopeId $ScopeIds `
        -LoadBalancePercent 50 -SharedSecret $Secret -Force
}
