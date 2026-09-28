<#
    802.1X on the clients: EAP-TLS with the certificates PKI-Issuing hands out,
    using the built-in Wired and Wireless Network policies rather than netsh
    profiles. GPMC has no cmdlets for either - it stores each policy as an XML
    blob on an AD object under the GPO, which is what this writes.

    One GPO per SSID, since a GPO holds only one wireless policy; each is
    filtered to its own computer group, so a test machine gets exactly one
    wireless network. Wired is one GPO for every computer, and deliberately
    not enforced, so a laptop still works on a home port.

    Runs on the issuing CA after PKI-Issuing: it needs the root CA certificate
    that PKI-Issuing put in CertEnroll, whose thumbprint the clients pin.
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName,
    [string]$UserPassword
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"
. "$PSScriptRoot\..\Invoke-AsDomainAdmin.ps1"

$Dot1x = $Config.Dot1x
$Work  = 'C:\PKI\dot1x'
New-Item -Path $Work -ItemType Directory -Force | Out-Null

# What the client pins as the trusted root, in the same lowercase-pairs form
# the policy editor writes.
$RootCert = Get-ChildItem 'C:\Windows\system32\CertSrv\CertEnroll' -Filter "*_$($Config.RootCA.CommonName).crt" |
    Select-Object -First 1
if (-not $RootCert) { throw "No root CA certificate in CertEnroll - run PKI-Issuing first" }
$Hash       = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($RootCert.FullName).Thumbprint
$Thumbprint = (($Hash.ToLower() -split '(..)' -ne '') -join ' ')
$Eap        = (Get-Content "$PSScriptRoot\eap-tls.xml" -Raw).Trim().
    Replace('{{RADIUS}}', $Dot1x.RadiusServer).Replace('{{THUMBPRINT}}', $Thumbprint)

# A policy keeps its GUID across runs or clients treat it as a new one, and
# the name is the only stable thing to derive it from.
function Get-PolicyGuid {
    param([string]$Name)
    $Md5 = [System.Security.Cryptography.MD5]::Create()
    "{$([guid]::new($Md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Name))))}"
}

function Write-PolicyFile {
    param([string]$Template, [string]$Out, [hashtable]$Values)
    $Xml = Get-Content "$PSScriptRoot\$Template" -Raw
    foreach ($Key in $Values.Keys) { $Xml = $Xml.Replace("{{$Key}}", $Values[$Key]) }
    Set-Content -Path $Out -Value $Xml -Encoding ascii
    $Out
}

# Writes one policy object under the GPO, links it, and filters it to a group.
# Everything here needs AD, so it runs as the domain Administrator.
$Policy = {
    Import-Module ActiveDirectory, GroupPolicy
    $Xml = (Get-Content $XmlFile -Raw).Trim()

    if ($GroupName -and -not (Get-ADGroup -Filter "Name -eq '$GroupName'")) {
        New-ADGroup -Name $GroupName -SamAccountName $GroupName -GroupScope Global `
            -GroupCategory Security -Path $GroupsOU
        Write-Host "Created group $GroupName - add the test machines to it"
    }

    $Gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
    if (-not $Gpo) {
        $Gpo = New-GPO -Name $GpoName
        Write-Host "Created GPO $GpoName"
    }

    # Wired AutoConfig is manual by default, and a stopped dot3svc ignores the
    # policy entirely. Set-GPRegistryValue also registers the registry CSE.
    if ($Wired) {
        Set-GPRegistryValue -Name $GpoName -Key 'HKLM\SYSTEM\CurrentControlSet\Services\dot3svc' `
            -ValueName Start -Type DWord -Value 2 | Out-Null
    }

    # The policy object lives in CN=Windows,CN=Microsoft,CN=Machine under the
    # GPO; GPMC creates those containers, so create them if this GPO is new.
    $Container = "CN=Machine,CN={$($Gpo.Id)},CN=Policies,CN=System,$DomainDN"
    foreach ($Name in 'Microsoft', 'Windows') {
        if (-not (Get-ADObject -Filter "cn -eq '$Name'" -SearchBase $Container -SearchScope OneLevel)) {
            New-ADObject -Name $Name -Type container -Path $Container
        }
        $Container = "CN=$Name,$Container"
    }

    $Existing = Get-ADObject -Filter "objectClass -eq '$Class'" -SearchBase $Container -Properties "$Prefix-GP-PolicyData"
    $Dirty    = $false
    if (-not $Existing) {
        New-ADObject -Name $GpoName -Type $Class -Path $Container -OtherAttributes @{
            "$Prefix-GP-PolicyGUID" = $PolicyGuid
            "$Prefix-GP-PolicyData" = $Xml
        }
        $Dirty = $true
        Write-Host "Wrote the $Class policy into $GpoName"
    } elseif ($Existing."$Prefix-GP-PolicyData" -ne $Xml) {
        Set-ADObject -Identity $Existing.DistinguishedName -Replace @{ "$Prefix-GP-PolicyData" = $Xml }
        $Dirty = $true
        Write-Host "Updated the $Class policy in $GpoName"
    } else {
        Write-Host "$Class policy in $GpoName is already current"
    }

    # Clients only run a CSE the GPO lists. The pair is the extension and the
    # snap-in that owns it; both policies sit under Security Settings.
    $Ad  = Get-ADObject -Identity $Gpo.Path -Properties gPCMachineExtensionNames, versionNumber
    $Ext = [string]$Ad.gPCMachineExtensionNames
    if ($Ext -notmatch [regex]::Escape($Cse)) {
        # Sorted by CSE guid, like every other pair in the attribute.
        $Pairs = @([regex]::Matches($Ext, '\[[^\]]*\]') | ForEach-Object { $_.Value }) + $Cse
        $Ext   = ($Pairs | Sort-Object) -join ''
        $Dirty = $true
    }

    if ($Dirty) {
        # Computer settings are the low 16 bits; AD and GPT.INI must agree or
        # clients skip the change.
        $Version = $Ad.versionNumber + 1
        Set-ADObject -Identity $Gpo.Path -Replace @{ gPCMachineExtensionNames = $Ext; versionNumber = $Version }
        $Ini = "\\$DomainName\SYSVOL\$DomainName\Policies\{$($Gpo.Id)}\GPT.INI"
        (Get-Content $Ini) -replace '^Version=\d+', "Version=$Version" | Set-Content $Ini -Encoding ascii
        Write-Host "$GpoName now at version $Version"
    }

    if ((Get-GPInheritance -Target $ComputersOU).GpoLinks.DisplayName -contains $GpoName) {
        Write-Host "GPO already linked to $ComputersOU"
    } else {
        New-GPLink -Name $GpoName -Target $ComputersOU | Out-Null
        Write-Host "Linked $GpoName to $ComputersOU"
    }

    # Security filtering. Authenticated Users keeps Read - without it (MS16-072)
    # the computer cannot read the GPO at all and nothing applies.
    if ($GroupName) {
        Set-GPPermission -Name $GpoName -TargetName 'Authenticated Users' -TargetType Group `
            -PermissionLevel GpoRead -Replace | Out-Null
        Set-GPPermission -Name $GpoName -TargetName $GroupName -TargetType Group `
            -PermissionLevel GpoApply | Out-Null
        Write-Host "$GpoName applies to $GroupName only"
    }
}

$Common = @{
    DomainDN    = $Config.DomainDN
    DomainName  = $Config.DomainName
    ComputersOU = "OU=Computers,$($Config.OUBase)"
    GroupsOU    = "OU=Wifi,OU=Groups,$($Config.OUBase)"
}

# Wired: every computer, no group, not enforced.
$Guid = Get-PolicyGuid $Dot1x.WiredGpo
$Vars = $Common + @{
    GpoName   = $Dot1x.WiredGpo
    GroupName = ''
    Wired     = $true
    Class     = 'ms-net-ieee-8023-GroupPolicy'
    Prefix    = 'ms-net-ieee-8023'
    Cse       = '[{B587E2B1-4D59-4E7E-AED9-22B9DF11D053}{53D6AB1B-2488-11D1-A28C-00C04FB94F17}]'
    PolicyGuid = $Guid
    XmlFile   = Write-PolicyFile -Template 'wired-policy.xml' -Out "$Work\wired.xml" -Values @{
        POLICYNAME = $Dot1x.WiredGpo; POLICYGUID = $Guid; EAPCONFIG = $Eap
    }
}
Invoke-AsDomainAdmin -Label 'dot1x-wired' -Variables $Vars -Script $Policy

# Wireless: one GPO, one policy and one group per SSID.
foreach ($Network in $Dot1x.Networks) {
    $Guid = Get-PolicyGuid $Network.Gpo
    $Vars = $Common + @{
        GpoName   = $Network.Gpo
        GroupName = $Network.Group
        Wired     = ''
        Class     = 'ms-net-ieee-80211-GroupPolicy'
        Prefix    = 'ms-net-ieee-80211'
        Cse       = '[{0ACDD40C-75AC-47AB-BAA0-BF6DE7E7FE63}{53D6AB1B-2488-11D1-A28C-00C04FB94F17}]'
        PolicyGuid = $Guid
        XmlFile   = Write-PolicyFile -Template 'wireless-policy.xml' -Out "$Work\$($Network.SSID).xml" -Values @{
            POLICYNAME = $Network.Gpo; POLICYGUID = $Guid; SSID = $Network.SSID; EAPCONFIG = $Eap
        }
    }
    Invoke-AsDomainAdmin -Label "dot1x-$($Network.SSID)" -Variables $Vars -Script $Policy
}
