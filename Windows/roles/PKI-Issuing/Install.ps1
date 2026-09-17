<#
    Enterprise issuing CA. Gets its certificate signed by the offline root
    (SRV-PKI-01, over WinRM), serves both CAs' certificates and CRLs over HTTP,
    and hands every user and computer a certificate by autoenrollment.
    Shuts the root down as its last step whenever it finds it running.

    Runs after PKI-Root, and after the domain exists.
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
. "$PSScriptRoot\..\Wait-CertSvc.ps1"

$Root       = $Config.RootCA
$CertEnroll = 'C:\Windows\system32\CertSrv\CertEnroll'
$Work       = 'C:\PKI'
$CAReg      = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'

$Feature = Install-WindowsFeature -Name ADCS-Cert-Authority, ADCS-Online-Cert, Web-Server, RSAT-AD-PowerShell, GPMC -IncludeManagementTools
if ($Feature.RestartNeeded -eq 'Yes') { Restart-Computer -Force; exit 3010 }
New-Item -Path $CertEnroll, $Work -ItemType Directory -Force | Out-Null

# The HTTP location every certificate points at. Delta CRL names contain '+',
# which IIS refuses without double escaping.
Import-Module WebAdministration
if (-not (Get-WebVirtualDirectory -Site 'Default Web Site' -Name CertEnroll)) {
    New-WebVirtualDirectory -Site 'Default Web Site' -Name CertEnroll -PhysicalPath $CertEnroll | Out-Null
    Write-Host "Created http://$env:COMPUTERNAME/CertEnroll"
}
Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location 'Default Web Site/CertEnroll' `
    -Filter 'system.webServer/security/requestFiltering' -Name allowDoubleEscaping -Value $true

# The root is normally off. Explicit credentials, so the key-based SSH logon
# is enough here; the IP must be trusted since NTLM is all a workgroup box has.
$Trusted = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
if ($Root.IP -notin ($Trusted -split ',')) {
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $Root.IP -Concatenate -Force
}
$RootCred = [PSCredential]::new("$($Root.Name)\Administrator", (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
try {
    $Session = New-PSSession -ComputerName $Root.IP -Credential $RootCred `
        -SessionOption (New-PSSessionOption -OpenTimeout 10000)
    Write-Host "Root CA $($Root.Name) is online"
} catch {
    $Session = $null
    Write-Host "Root CA $($Root.Name) is offline ($($_.Exception.Message.Trim()))"
}

if ($Session) {
    # Its certificate and CRL, under the names its own URLs use.
    $Files = Invoke-Command -Session $Session { (Get-ChildItem C:\Windows\system32\CertSrv\CertEnroll -File).FullName }
    foreach ($File in $Files) {
        Copy-Item -FromSession $Session -Path $File -Destination $CertEnroll -Force
        certutil.exe -f -addstore Root "$CertEnroll\$(Split-Path $File -Leaf)" | Out-Null
        if ($LASTEXITCODE) { throw "certutil -addstore Root $File failed (exit $LASTEXITCODE)" }
    }
    Write-Host "Root certificate and CRL copied and trusted locally"
}
$RootCert = Get-ChildItem $CertEnroll -Filter "*_$($Root.CommonName).crt" | Select-Object -First 1
if (-not $RootCert) { throw "No root CA certificate in $CertEnroll - start $($Root.Name) and rerun" }

# Publishing the root to AD needs Enterprise Admin, and the SSH logon has no
# network credentials of its own.
Invoke-AsDomainAdmin -Label 'pki-publish-root' -Variables @{ RootCert = $RootCert.FullName } -Script {
    # RootCA container: every domain member trusts it at its next policy refresh.
    certutil.exe -f -dspublish $RootCert RootCA | Out-Null
    if ($LASTEXITCODE) { throw "certutil -dspublish failed (exit $LASTEXITCODE)" }
    Write-Host "Root certificate published to AD"
}

# The CA's own certificate. Deliberately *not* the usual pending install: when
# Install-AdcsCertificationAuthority generates the request itself, the only way
# to finish is `certutil -installcert`, which opens a dialog no service session
# can answer - it hangs forever, or fails with 0x8007000D under -silent. Making
# the key and the request here instead means the CA is installed in one step,
# from a certificate that already has its key.
$Subject = "CN=$($Config.IssuingCA.CommonName),$($Config.DomainDN)"
$Active  = (Get-ItemProperty $CAReg -Name Active -ErrorAction SilentlyContinue).Active
# Bit 0x8 of SetupStatus is "suspended": installed but still waiting for its
# certificate, the state certsvc refuses to start in.
if ($Active -and ((Get-ItemProperty "$CAReg\$Active").SetupStatus -band 0x8) -eq 0) {
    Write-Host "Issuing CA already installed"
} else {
    $Cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -like "CN=$($Config.IssuingCA.CommonName),*" -and $_.HasPrivateKey } |
        Select-Object -First 1
    if ($Cert) {
        Write-Host "CA certificate already in the machine store"
    } else {
        if (-not (Test-Path "$Work\ca.req")) {
            Set-Content -Path "$Work\ca.inf" -Encoding ascii -Value @"
[Version]
Signature="`$Windows NT`$"
[NewRequest]
Subject="$Subject"
KeyLength=4096
KeyAlgorithm=RSA
HashAlgorithm=SHA256
ProviderName="Microsoft Software Key Storage Provider"
MachineKeySet=true
RequestType=PKCS10
Exportable=false
KeyUsage=0x86
[Extensions]
2.5.29.19={text}ca=1
"@
            certreq.exe -q -new "$Work\ca.inf" "$Work\ca.req" | Out-Null
            if ($LASTEXITCODE) { throw "certreq -new failed (exit $LASTEXITCODE)" }
            Write-Host "Created the CA key and request"
        }

        # A certificate the root signed earlier belongs to the key beside it,
        # so reuse it - submitting again only makes the root issue another.
        # Delete ca.req and ca.crt to start over with a fresh key.
        if (-not (Test-Path "$Work\ca.crt")) {
            if (-not $Session) { throw "Issuing CA needs its certificate signed - start $($Root.Name) and rerun" }
            # A standalone CA holds every request pending: submit, approve, retrieve.
            Copy-Item -ToSession $Session -Path "$Work\ca.req" -Destination 'C:\Windows\Temp\ca.req' -Force
            Invoke-Command -Session $Session -ArgumentList $Root.CommonName {
                param($CommonName)
                $CA  = "$env:COMPUTERNAME\$CommonName"
                $Out = certreq.exe -q -config $CA -submit C:\Windows\Temp\ca.req 2>&1 | Out-String
                if ($Out -notmatch 'RequestId:\s*"?(\d+)') { throw "certreq -submit failed: $Out" }
                $Id = $Matches[1]
                certutil.exe -resubmit $Id | Out-Null
                if ($LASTEXITCODE) { throw "certutil -resubmit $Id failed (exit $LASTEXITCODE)" }
                certreq.exe -q -f -config $CA -retrieve $Id C:\Windows\Temp\ca.crt | Out-Null
                if ($LASTEXITCODE) { throw "certreq -retrieve $Id failed (exit $LASTEXITCODE)" }
                Write-Host "Root CA signed request $Id"
            }
            Copy-Item -FromSession $Session -Path 'C:\Windows\Temp\ca.crt' -Destination "$Work\ca.crt" -Force
        }

        # Binds the signed certificate to the key the request was made with.
        certreq.exe -q -accept -machine "$Work\ca.crt" | Out-Null
        if ($LASTEXITCODE) { throw "certreq -accept failed (exit $LASTEXITCODE)" }
        $Cert = Get-Item "Cert:\LocalMachine\My\$([System.Security.Cryptography.X509Certificates.X509Certificate2]::new("$Work\ca.crt").Thumbprint)"
        Write-Host "CA certificate accepted into the machine store"
    }

    # Read when the CA is configured: this one only keeps it from publishing the
    # default template set, since the templates below are ours.
    Set-Content -Path C:\Windows\CAPolicy.inf -Encoding ascii -Value @'
[Version]
Signature="$Windows NT$"
[Certsrv_Server]
RenewalKeyLength=4096
LoadDefaultTemplates=0
AlternateSignatureAlgorithm=0
'@

    # Installing the CA publishes it to AD, so this needs the domain admin too.
    Invoke-AsDomainAdmin -Label 'pki-ca' -Variables @{ Thumbprint = $Cert.Thumbprint } -TimeoutSeconds 600 -Script {
        Import-Module ADCSDeployment
        $Result = Install-AdcsCertificationAuthority -CAType EnterpriseSubordinateCA `
            -CertificateID $Thumbprint -Force
        if ($Result.ErrorId) { throw "Install-AdcsCertificationAuthority failed: $($Result.ErrorString)" }
        Write-Host "Issuing CA installed from the signed certificate"
    }
}
Start-Service -Name certsvc
Wait-CertSvc

# PacketFence can only check revocation over OCSP, so every certificate has to
# carry an OCSP URL in its AIA - and it is stamped in at issuance, so this must
# be set before the templates below hand any out. %1 is this server's DNS name.
if (((certutil.exe -getreg CA\CACertPublicationURLs) -join "`n") -notmatch '/ocsp') {
    certutil.exe -setreg 'CA\CACertPublicationURLs' '+32:http://%1/ocsp' | Out-Null
    if ($LASTEXITCODE) { throw "certutil -setreg CACertPublicationURLs failed (exit $LASTEXITCODE)" }
    Restart-Service -Name certsvc
    Wait-CertSvc
    Write-Host "OCSP URL added to the CA's AIA"
} else {
    Write-Host "OCSP URL already in the CA's AIA"
}

if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\OCSPSvc\Responder') {
    Write-Host "Online Responder already installed"
} else {
    Install-AdcsOnlineResponder -Force | Out-Null
    Write-Host "Online Responder installed"
}

# Templates, publishing them on this CA, the OCSP revocation configuration and
# the autoenrollment GPO.
$Vars = @{
    GpoName    = 'GPO_MFRACE_PKI_AutoEnrollment'
    DomainDN   = $Config.DomainDN
    IssuingCN  = $Config.IssuingCA.CommonName
    CertEnroll = $CertEnroll
    OUBase     = $Config.OUBase
}
Invoke-AsDomainAdmin -Label 'pki-templates' -Variables $Vars -TimeoutSeconds 600 -Script {
    Import-Module ActiveDirectory
    $PKS       = "CN=Public Key Services,CN=Services,$((Get-ADRootDSE).configurationNamingContext)"
    $Templates = "CN=Certificate Templates,$PKS"
    $OidRoot   = Get-ADObject "CN=OID,$PKS" -Properties 'msPKI-Cert-Template-OID'
    $ForestOid = $OidRoot.'msPKI-Cert-Template-OID'
    if (-not $ForestOid) {
        # What the Certificate Templates console generates on first open.
        $ForestOid = '1.3.6.1.4.1.311.21.8.' + ((1..6 | ForEach-Object { Get-Random -Minimum 1000000 -Maximum 16777215 }) -join '.')
        Set-ADObject $OidRoot -Replace @{ 'msPKI-Cert-Template-OID' = $ForestOid }
    }

    # The built-in User and Computer templates are version 1, which cannot be
    # autoenrolled - so each gets a version 2 copy. No cmdlet duplicates a
    # template; this is what the console writes.
    $Enrollment = "CN=$IssuingCN,CN=Enrollment Services,$PKS"
    $Enroll     = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
    $AutoEnroll = [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
    $Copy = 'msPKI-Enrollment-Flag', 'msPKI-Private-Key-Flag', 'pKICriticalExtensions', 'pKIDefaultCSPs',
        'pKIDefaultKeySpec', 'pKIExpirationPeriod', 'pKIExtendedKeyUsage', 'pKIKeyUsage',
        'pKIMaxIssuingDepth', 'pKIOverlapPeriod'
    # MFRACE-RADIUS is for PacketFence, which is not in the domain: its CSR is
    # signed by hand (see README), so it only needs publishing, no autoenroll.
    # WebServer supplies subject and SAN from the request. Domain Admins get
    # Enroll from the schema's default ACL. OCSPResponseSigning is built in and
    # already version 3 - this server's own computer account enrolls it.
    $Wanted = @(
        @{ Name = 'MFRACE-User';        Source = 'User';      Enrollees = 'Domain Users';                          AutoEnroll = $true }
        # Client Authentication only: the Machine template also carries Server
        # Authentication, which a workstation has no use for - that belongs to
        # MFRACE-RADIUS, on the one host that answers as a server.
        @{ Name = 'MFRACE-Computer';    Source = 'Machine';   Enrollees = 'Domain Computers', 'Domain Controllers'; AutoEnroll = $true; Eku = '1.3.6.1.5.5.7.3.2' }
        @{ Name = 'MFRACE-RADIUS';      Source = 'WebServer'; Enrollees = @();                                      AutoEnroll = $false }
        # Server Authentication for servers, requested by the ACRS policy
        # below. The built-in v1 Machine template, because ACRS can request
        # nothing else; its stock ACL already lets Domain Computers enroll.
        @{ Name = 'Machine';            Source = $null;       Enrollees = @();                                      AutoEnroll = $false }
        @{ Name = 'OCSPResponseSigning'; Source = $null;      Enrollees = "$env:COMPUTERNAME`$";                    AutoEnroll = $true }
    )
    foreach ($T in $Wanted) {
        if (-not $T.Source) {
            Write-Host "Template $($T.Name) is built in"
        } elseif (Get-ADObject -SearchBase $Templates -Filter "cn -eq '$($T.Name)'") {
            Write-Host "Template $($T.Name) already exists"
        } else {
            $Src = Get-ADObject "CN=$($T.Source),$Templates" -Properties *
            $Oid = "$ForestOid.$(Get-Random -Minimum 10000000 -Maximum 99999999).$(Get-Random -Minimum 10000000 -Maximum 99999999)"
            $Attrs = @{
                displayName                            = $T.Name
                revision                               = 100
                'msPKI-Template-Schema-Version'        = 2
                'msPKI-Template-Minor-Revision'        = 0
                'msPKI-RA-Signature'                   = 0
                'msPKI-Minimal-Key-Size'               = 2048
                'msPKI-Cert-Template-OID'              = $Oid
                'msPKI-Certificate-Application-Policy' = [string[]]$(if ($T.Eku) { $T.Eku } else { $Src.pKIExtendedKeyUsage })
                # Not a built-in default any more, and no e-mail: the users
                # have no mail attribute, so requiring one fails every request.
                flags                                  = ($Src.flags -band -bnot 0x10002) -bor 0x20000
                'msPKI-Certificate-Name-Flag'          = $Src.'msPKI-Certificate-Name-Flag' -band -bnot 0x24000000
            }
            foreach ($Name in $Copy) {
                $Value = $Src.$Name
                if ($null -eq $Value) { continue }
                if ($Value -is [Microsoft.ActiveDirectory.Management.ADPropertyValueCollection]) { $Value = [string[]]$Value }
                $Attrs[$Name] = $Value
            }
            if ($T.AutoEnroll) {
                $Attrs.flags = $Attrs.flags -bor 0x20
                $Attrs['msPKI-Enrollment-Flag'] = $Attrs['msPKI-Enrollment-Flag'] -bor 0x20
            }

            New-ADObject -Path "CN=OID,$PKS" -Type 'msPKI-Enterprise-Oid' `
                -Name "$($Oid.Split('.')[-1]).$([guid]::NewGuid().ToString('N'))" `
                -OtherAttributes @{ displayName = $T.Name; flags = 1; 'msPKI-Cert-Template-OID' = $Oid }
            New-ADObject -Path $Templates -Type pKICertificateTemplate -Name $T.Name -OtherAttributes $Attrs
            Write-Host "Created template $($T.Name) from $($T.Source)"
        }

        # Enforced on every run, not just at creation, so a template that
        # already exists with the wrong usage is corrected. Bumping revision is
        # what makes the CA and the clients pick the change up.
        if ($T.Eku) {
            $Obj = Get-ADObject "CN=$($T.Name),$Templates" -Properties pKIExtendedKeyUsage, revision
            if (Compare-Object @($Obj.pKIExtendedKeyUsage) @($T.Eku)) {
                Set-ADObject $Obj.DistinguishedName -Replace @{
                    pKIExtendedKeyUsage                    = [string[]]$T.Eku
                    'msPKI-Certificate-Application-Policy' = [string[]]$T.Eku
                    revision                               = $Obj.revision + 1
                }
                Write-Host "$($T.Name) usage set to $($T.Eku -join ', ')"
            } else {
                Write-Host "$($T.Name) usage already correct"
            }
        }

        # Adding a rule already present is a no-op, so this is safe to repeat.
        # sAMAccountName rather than Get-ADGroup: one enrollee is a computer.
        if ($T.Enrollees) {
            $Rights = if ($T.AutoEnroll) { $Enroll, $AutoEnroll } else { , $Enroll }
            $Path   = "AD:\CN=$($T.Name),$Templates"
            $Acl    = Get-Acl $Path
            foreach ($Name in $T.Enrollees) {
                $Sid = (Get-ADObject -Filter "sAMAccountName -eq '$Name'" -Properties objectSid).objectSid
                if (-not $Sid) { throw "No account named $Name to grant enrollment on $($T.Name)" }
                foreach ($Right in $Rights) {
                    $Acl.AddAccessRule([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Sid, 'ExtendedRight', 'Allow', $Right))
                }
            }
            Set-Acl -Path $Path -AclObject $Acl
            Write-Host "$($T.Enrollees -join ', ') may enroll $($T.Name)"
        }

        # Publishing is one attribute on the CA's own AD object. Add-CATemplate
        # would be the obvious cmdlet, but it validates against a cached
        # template list and rejects anything newer than the cache with "the
        # template does not exist in the domain" - for hours.
        if ($T.Name -in @((Get-ADObject $Enrollment -Properties certificateTemplates).certificateTemplates)) {
            Write-Host "$($T.Name) already published on the CA"
        } else {
            Set-ADObject $Enrollment -Add @{ certificateTemplates = $T.Name }
            Write-Host "Published $($T.Name) on the CA"
        }
    }

    # The Online Responder's revocation configuration is the one piece here
    # that is not scripted. Its only API is the CertAdm.OCSPAdmin COM object,
    # which behaves differently from PowerShell and from VBScript, reports
    # saves that do not persist, and leaves a half-written configuration that
    # throws on every later read. The wizard writes it correctly in six clicks,
    # once, so this only checks and tells you - it does not fail the deploy.
    $Responder = 'HKLM:\SYSTEM\CurrentControlSet\Services\OCSPSvc\Responder'
    if (Test-Path "$Responder\$IssuingCN") {
        Write-Host "OCSP revocation configuration for $IssuingCN is present"
    } else {
        Write-Host ""
        Write-Host "ACTION NEEDED: add the OCSP revocation configuration by hand, once."
        Write-Host "  ocsp.msc on $env:COMPUTERNAME - Revocation Configuration - Add:"
        Write-Host "    name            $IssuingCN"
        Write-Host "    CA certificate  from AD, $IssuingCN"
        Write-Host "    signing cert    automatically selected, template OCSPResponseSigning"
        Write-Host "  Until then PacketFence gets no revocation answers."
        Write-Host ""
    }

    # Servers need Server Authentication (LDAPS, RDP, IIS, WinRM over HTTPS)
    # and workstations must not have it. A template's permissions name groups,
    # never OUs, so the scoping is done by an Automatic Certificate Request
    # Settings policy linked to the Servers OU: only computers there request
    # it. ACRS is why the v1 Machine template is published above - it can
    # request no other kind.
    $ServerGpo = 'GPO_MFRACE_PKI_ServerCert'
    $Gpo = Get-GPO -Name $ServerGpo -ErrorAction SilentlyContinue
    if (-not $Gpo) {
        $Gpo = New-GPO -Name $ServerGpo
        Write-Host "Created GPO $ServerGpo"
    }
    $ServersOU = "OU=Servers,$OUBase"
    if ((Get-GPInheritance -Target $ServersOU).GpoLinks.DisplayName -contains $ServerGpo) {
        Write-Host "GPO $ServerGpo already linked to $ServersOU"
    } else {
        New-GPLink -Name $ServerGpo -Target $ServersOU | Out-Null
        Write-Host "Linked $ServerGpo to $ServersOU"
    }
    # GPMC writes the ACRS entry itself as an undocumented object under the
    # GPO, so it is added by hand once, like the OCSP configuration.
    $MachineDN = "CN=Machine,CN={$($Gpo.Id)},CN=Policies,CN=System,$DomainDN"
    if (Get-ADObject -SearchBase $MachineDN -Filter "objectClass -ne 'container'" -SearchScope Subtree) {
        Write-Host "$ServerGpo carries its certificate request policy"
    } else {
        Write-Host ""
        Write-Host "ACTION NEEDED: add the automatic certificate request, once."
        Write-Host "  gpmc.msc - edit $ServerGpo - Computer Configuration - Policies -"
        Write-Host "  Windows Settings - Security Settings - Public Key Policies -"
        Write-Host "  Automatic Certificate Request Settings - New - pick 'Computer'."
        Write-Host "  Until then the servers get no Server Authentication certificate."
        Write-Host ""
    }

    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) {
        Write-Host "GPO $GpoName already exists"
    } else {
        New-GPO -Name $GpoName | Out-Null
        Write-Host "Created GPO $GpoName"
    }
    # "Certificate Services Client - Auto-Enrollment": 7 = enrolled, renews
    # and updates certificates when templates change.
    foreach ($Hive in 'HKLM', 'HKCU') {
        Set-GPRegistryValue -Name $GpoName -Key "$Hive\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" `
            -ValueName AEPolicy -Type DWord -Value 7 | Out-Null
    }
    # The domain root, so every user and computer gets one - Servers and the
    # default Computers container included.
    if ((Get-GPInheritance -Target $DomainDN).GpoLinks.DisplayName -contains $GpoName) {
        Write-Host "GPO already linked to $DomainDN"
    } else {
        New-GPLink -Name $GpoName -Target $DomainDN | Out-Null
        Write-Host "Linked GPO to $DomainDN"
    }
}

# The CA caches its template list; a restart is the deterministic way to make
# it serve what was just published.
Restart-Service -Name certsvc
Wait-CertSvc

# Offline is the root's resting state. Wait for it to go, or deploy.sh's second
# pass can still find it half shut down.
if ($Session) {
    Invoke-Command -Session $Session { shutdown.exe /s /t 0 /c 'Offline root CA - PKI-Issuing done' }
    Remove-PSSession $Session -ErrorAction SilentlyContinue
    for ($i = 0; Test-WSMan -ComputerName $Root.IP -ErrorAction SilentlyContinue; $i++) {
        if ($i -ge 24) { throw "Root CA $($Root.Name) did not shut down" }
        Start-Sleep -Seconds 5
    }
    Write-Host "Root CA $($Root.Name) is shut down"
}
