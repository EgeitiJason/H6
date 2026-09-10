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
    return
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

function New-ADSubnet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$Subnet,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$SiteName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Description,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Location
    )

    process {
        try {
            $ErrorActionPreference = 'Stop'

            $Configuration = ([ADSI]"LDAP://RootDSE").configurationNamingContext
            $SubnetsContainer = [ADSI]"LDAP://CN=Subnets,CN=Sites,$Configuration"

            if (Get-ADReplicationSubnet -Filter "Name -eq '$Subnet'" -ErrorAction SilentlyContinue) {
                Write-Host "Subnet $Subnet already exists"
                return
            }

            $SubnetObject = $SubnetsContainer.Create('subnet', "CN=$Subnet")
            $SubnetObject.Put("siteObject", "CN=$SiteName,CN=Sites,$Configuration")

            if ($Description) { $SubnetObject.Put("description", $Description) }
            if ($Location)    { $SubnetObject.Put("location", $Location) }

            $SubnetObject.SetInfo()
            Write-Host "Subnet $Subnet added to $SiteName"
        }
        catch {
            Write-Warning "Failed creating subnet $Subnet"
            $_.Exception.Message
        }
    }
}

$Subnets | New-ADSubnet
