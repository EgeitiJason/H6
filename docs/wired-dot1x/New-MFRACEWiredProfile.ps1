<#
    Creates the wired 802.1X LAN profile for Middelfart Racing and applies it locally.

    - EAP-TLS (computer certificate), server validation against srv-radius-01.mfrace.internal
    - Trusted root CA is looked up in the local computer store (CN contains MFRACE)
    - OneXEnforced = false  ("Fallback to unauthorized network access"), so the PC keeps
      working when PacketFence is unreachable and the switch authorizes the port through
      the critical VLAN.

    Run elevated. -ExportOnly writes the XML without applying it.
#>
[CmdletBinding()]
param(
    [string]$OutFile   = "$env:ProgramData\MFRACE\MFRACE-Wired.xml",
    [string]$ServerName = 'srv-radius-01.mfrace.internal',
    [string]$RootCaMatch = 'MFRACE',
    [switch]$ExportOnly
)

$ErrorActionPreference = 'Stop'

# --- root CA thumbprint -------------------------------------------------------
$roots = @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match $RootCaMatch })
if ($roots.Count -eq 0) {
    throw "No root CA found in Cert:\LocalMachine\Root matching '$RootCaMatch'. Is the CA certificate deployed?"
}
if ($roots.Count -gt 1) {
    Write-Warning "Several root CAs match '$RootCaMatch'; using the first one:"
    $roots | ForEach-Object { Write-Warning ("  {0}  {1}" -f $_.Thumbprint, $_.Subject) }
}
$root = $roots[0]
# netsh expects the thumbprint in pairs of two, separated by spaces
$thumb = ($root.Thumbprint.ToLower() -split '(..)' | Where-Object { $_ }) -join ' '
Write-Host "Root CA : $($root.Subject)"
Write-Host "Thumbprint: $thumb"

# --- profile XML --------------------------------------------------------------
$xml = @"
<?xml version="1.0" encoding="US-ASCII"?>
<LANProfile xmlns="http://www.microsoft.com/networking/LAN/profile/v1">
  <MSM>
    <security>
      <OneXEnforced>false</OneXEnforced>
      <OneXEnabled>true</OneXEnabled>
      <OneX xmlns="http://www.microsoft.com/networking/OneX/v1">
        <cacheUserData>true</cacheUserData>
        <authMode>machineOrUser</authMode>
        <EAPConfig>
          <EapHostConfig xmlns="http://www.microsoft.com/provisioning/EapHostConfig">
            <EapMethod>
              <Type xmlns="http://www.microsoft.com/provisioning/EapCommon">13</Type>
              <VendorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorId>
              <VendorType xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorType>
              <AuthorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</AuthorId>
            </EapMethod>
            <Config xmlns="http://www.microsoft.com/provisioning/EapHostConfig">
              <Eap xmlns="http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1">
                <Type>13</Type>
                <EapType xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV1">
                  <CredentialsSource>
                    <CertificateStore>
                      <SimpleCertSelection>true</SimpleCertSelection>
                    </CertificateStore>
                  </CredentialsSource>
                  <ServerValidation>
                    <DisableUserPromptForServerValidation>true</DisableUserPromptForServerValidation>
                    <ServerNames>$ServerName</ServerNames>
                    <TrustedRootCA>$thumb</TrustedRootCA>
                  </ServerValidation>
                  <DifferentUsername>false</DifferentUsername>
                  <PerformServerValidation xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV2">true</PerformServerValidation>
                  <AcceptServerName xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV2">true</AcceptServerName>
                  <TLSExtensions xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV2">
                    <FilteringInfo xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV3">
                      <EKUMapping>
                        <EKUMap>
                          <EKUName>Client Authentication</EKUName>
                          <EKUOID>1.3.6.1.5.5.7.3.2</EKUOID>
                        </EKUMap>
                      </EKUMapping>
                      <ClientAuthEKUList Enabled="true" />
                    </FilteringInfo>
                  </TLSExtensions>
                </EapType>
              </Eap>
            </Config>
          </EapHostConfig>
        </EAPConfig>
      </OneX>
    </security>
  </MSM>
</LANProfile>
"@

$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[IO.File]::WriteAllText($OutFile, $xml, [Text.ASCIIEncoding]::new())
Write-Host "Profile written: $OutFile"

if ($ExportOnly) { return }

# --- apply --------------------------------------------------------------------
if ((Get-Service dot3svc).StartType -ne 'Automatic') {
    Set-Service dot3svc -StartupType Automatic
}
if ((Get-Service dot3svc).Status -ne 'Running') { Start-Service dot3svc }

Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' } | ForEach-Object {
    Write-Host "Applying to interface '$($_.Name)'"
    netsh lan add profile filename="$OutFile" interface="$($_.Name)"
}

netsh lan show profiles
netsh lan show interfaces
