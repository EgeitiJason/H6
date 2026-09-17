<#
    Offline standalone root CA. Deliberately not domain-joined: it signs the
    issuing CA's certificate and its own CRL, and is otherwise powered off -
    PKI-Issuing shuts it down once it has what it needs.

    The CRL lasts 52 weeks. Once a year: start this VM, run
    `./deploy.sh SRV-PKI-01` (reissues the CRL), then
    `./deploy.sh SRV-PKI-02 PKI-Issuing` (copies it over, shuts this down).
#>
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName,
    [string]$UserPassword
)
$ErrorActionPreference = 'Stop'
$Config     = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"
. "$PSScriptRoot\..\Wait-CertSvc.ps1"
$CertEnroll = 'C:\Windows\system32\CertSrv\CertEnroll'
$Http       = "http://$($Config.IssuingCA.Name).$($Config.DomainName)/CertEnroll"

$Feature = Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools
if ($Feature.RestartNeeded -eq 'Yes') { Restart-Computer -Force; exit 3010 }

if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction SilentlyContinue) {
    Write-Host "Root CA already installed"
} else {
    # Read at install time. A root's own certificate carries no CDP or AIA.
    Set-Content -Path C:\Windows\CAPolicy.inf -Encoding ascii -Value @'
[Version]
Signature="$Windows NT$"
[Certsrv_Server]
RenewalKeyLength=4096
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=20
AlternateSignatureAlgorithm=0
[CRLDistributionPoint]
Empty=True
[AuthorityInformationAccess]
Empty=True
'@
    Install-AdcsCertificationAuthority -CAType StandaloneRootCA `
        -CACommonName $Config.RootCA.CommonName `
        -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
        -KeyLength 4096 -HashAlgorithmName SHA256 `
        -ValidityPeriod Years -ValidityPeriodUnits 20 -Force | Out-Null
    Write-Host "Installed standalone root CA $($Config.RootCA.CommonName)"
}

# Certificates it signs point at the issuing CA's web server for this CA's
# certificate and CRL - the defaults (ldap, file) mean nothing off the domain.
# ValidityPeriod caps the issuing CA's certificate.
$Settings = [ordered]@{
    CRLPublicationURLs     = "1:$CertEnroll\%3%8%9.crl\n2:$Http/%3%8%9.crl"
    CACertPublicationURLs  = "1:$CertEnroll\%1_%3%4.crt\n2:$Http/%1_%3%4.crt"
    CRLPeriod              = 'Weeks'
    CRLPeriodUnits         = '52'
    CRLDeltaPeriodUnits    = '0'
    ValidityPeriod         = 'Years'
    ValidityPeriodUnits    = '10'
}
foreach ($Key in $Settings.Keys) {
    certutil.exe -setreg "CA\$Key" $Settings[$Key] | Out-Null
    if ($LASTEXITCODE) { throw "certutil -setreg CA\$Key failed (exit $LASTEXITCODE)" }
}
Restart-Service -Name certsvc
Wait-CertSvc
certutil.exe -crl | Out-Null
if ($LASTEXITCODE) { throw "certutil -crl failed (exit $LASTEXITCODE)" }
Write-Host "CA settings applied, CRL published to $CertEnroll"

# PKI-Issuing reaches this box over WinRM as the local Administrator: give it
# the domain Administrator's password, and let only the issuing CA connect.
Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' } |
    Set-LocalUser -Password (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' | Set-NetFirewallRule -RemoteAddress $Config.IssuingCA.IP
Write-Host "WinRM open to $($Config.IssuingCA.IP) only"
