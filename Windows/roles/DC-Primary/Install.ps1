<#
    Forest root DC: ADDS + DNS, forward and reverse zones, forwarder, sites and
    subnets. Safe to re-run - the first pass promotes and reboots, the second
    does everything below the promotion.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName
)
$ErrorActionPreference = 'Stop'
$Config   = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"
$Password = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force
$Subnets  = Import-Csv "$PSScriptRoot\subnets.csv"

# Install ADDS and DNS. Install-ADDSForest reboots on its own when it finishes,
# so there is deliberately no Restart-Computer here - one owner for the reboot.
if (-not (Get-WindowsFeature -Name AD-Domain-Services).Installed) {
    Write-Host "Installing AD-Domain-Services and DNS"
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
    Install-WindowsFeature -Name DNS -IncludeManagementTools
    Import-Module ADDSDeployment
    Install-ADDSForest -DomainName $Config.DomainName `
        -SafeModeAdministratorPassword $Password -Force
    # It returns before the reboot starts; 3010 tells deploy.sh to wait it out.
    exit 3010
}
Write-Host "AD-Domain-Services already installed"

if (-not (Get-DnsServerZone -Name $Config.DomainName -ErrorAction SilentlyContinue)) {
    Add-DnsServerPrimaryZone -Name $Config.DomainName -ReplicationScope 'Domain'
    Write-Host "Forward lookup zone created for $($Config.DomainName)"
} else {
    Write-Host "Forward lookup zone already exists"
}

# One reverse lookup zone per subnet in subnets.csv
# ponytail: /24 only - the reversed-octet zone name assumes a 3-octet prefix.
# Handle /16 and /8 when a non-/24 row actually shows up in the CSV.
foreach ($Entry in $Subnets) {
    $Octets = $Entry.subnet.Split('/')[0].Split('.')
    $Zone   = "$($Octets[2]).$($Octets[1]).$($Octets[0]).in-addr.arpa"

    if (-not (Get-DnsServerZone -Name $Zone -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkID $Entry.subnet -ReplicationScope 'Domain'
        Write-Host "Reverse lookup zone created for $($Entry.subnet)"
    } else {
        Write-Host "Reverse lookup zone $Zone already exists"
    }
}

$ExistingForwarders = (Get-DnsServerForwarder).IPAddress.IPAddressToString
if ($Config.DNSForwarder -notin $ExistingForwarders) {
    Set-DnsServerForwarder -IPAddress $Config.DNSForwarder
    Write-Host "DNS forwarder set to $($Config.DNSForwarder)"
} else {
    Write-Host "DNS forwarder $($Config.DNSForwarder) already exists"
}

$SiteLink = Get-ADReplicationSiteLink -Filter 'Name -eq "DEFAULTIPSITELINK"'
if ($SiteLink) {
    Write-Host "Renaming default site link to $($Config.SiteLinkName)"
    Rename-ADObject -Identity $SiteLink.DistinguishedName -NewName $Config.SiteLinkName
} else {
    Write-Host "Default site link is already renamed"
}

# Keep the AD objects, not just their names: Rename-ADObject needs a
# DistinguishedName, and a bare string array has no .Name to test against.
$ExistingSites = Get-ADObject `
    -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
    -Filter "objectClass -eq 'site'"

$DefaultSite = $ExistingSites | Where-Object Name -eq 'Default-First-Site-Name'
if ($DefaultSite) {
    Write-Host "Renaming default site to $($Config.PrimarySite)"
    Rename-ADObject -Identity $DefaultSite.DistinguishedName -NewName $Config.PrimarySite
    $ExistingSites = Get-ADObject `
        -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
        -Filter "objectClass -eq 'site'"
} else {
    Write-Host "Default site is already renamed"
}

foreach ($Site in $Config.Sites) {
    if ($Site -notin $ExistingSites.Name) {
        Write-Host "Creating site: $Site"
        New-ADReplicationSite -Name $Site
    } else {
        Write-Host "Site $Site already exists"
    }
}

foreach ($Entry in $Subnets) {
    if (Get-ADReplicationSubnet -Filter "Name -eq '$($Entry.subnet)'") {
        Write-Host "Subnet $($Entry.subnet) already exists"
        continue
    }
    $Params = @{ Name = $Entry.subnet; Site = $Entry.site_name }
    if ($Entry.description) { $Params.Description = $Entry.description }
    if ($Entry.location)    { $Params.Location    = $Entry.location }
    New-ADReplicationSubnet @Params
    Write-Host "Subnet $($Entry.subnet) added to $($Entry.site_name)"
}
