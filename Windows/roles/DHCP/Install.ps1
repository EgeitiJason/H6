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

$Feature = Install-WindowsFeature -Name DHCP -IncludeManagementTools
# A pending restart breaks what follows; take it, pass 2 carries on.
if ($Feature.RestartNeeded -eq 'Yes') { Restart-Computer -Force; exit 3010 }

# What Server Manager's "Complete DHCP configuration" does: the local DHCP
# groups, then mark it done so the post-deployment flag goes away.
$SmRole = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
if ((Get-ItemProperty $SmRole -ErrorAction SilentlyContinue).ConfigurationState -ne 2) {
    netsh dhcp add securitygroups | Out-Null
    Restart-Service DHCPServer
    Set-ItemProperty $SmRole -Name ConfigurationState -Value 2
    Write-Host "DHCP post-deployment configuration done"
} else {
    Write-Host "DHCP post-deployment configuration already done"
}

# The SSH session logs in with a key, which gives it no network credentials:
# anything touching AD or the partner server is refused. So those steps run as
# a one-off scheduled task under the domain Administrator's password.
#
# The task unregisters itself as its very last step, and only when the work
# succeeded. A task still registered afterwards therefore means it failed or
# hung - it is then removed here (it holds the password) and this role fails.
function Invoke-AsDomainAdmin {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Script,
        [hashtable]$Variables = @{},
        [int]$TimeoutSeconds = 300
    )
    $TaskName = "deploy-$Label-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $Dir  = 'C:\deploy\tasks'
    $Body = "$Dir\$TaskName.ps1"
    $Log  = "$Dir\$TaskName.log"

    # The body carries the variables, secrets included: admins and SYSTEM only.
    New-Item -Path $Dir -ItemType Directory -Force | Out-Null
    icacls.exe $Dir /inheritance:r /grant 'SYSTEM:(OI)(CI)F' /grant 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null

    $Assignments = foreach ($Key in $Variables.Keys) {
        "`$$Key = '$(([string]$Variables[$Key]) -replace "'", "''")'"
    }
    Set-Content -Path $Body -Encoding ascii -Value @"
`$ErrorActionPreference = 'Stop'
$($Assignments -join "`r`n")
try {
    & {
$Script
    } *>&1 | Out-File -FilePath '$Log' -Append -Encoding ascii
    Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false
} catch {
    "ERROR: `$(`$_ | Out-String)" | Out-File -FilePath '$Log' -Append -Encoding ascii
    exit 1
}
"@

    try {
        $Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Body`""
        Register-ScheduledTask -TaskName $TaskName -Action $Action -RunLevel Highest `
            -User "$($Config.DomainName)\Administrator" -Password $AdminPassword | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Running '$Label' as $($Config.DomainName)\Administrator (task $TaskName)"

        $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $Deadline) {
            $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            # Gone means it removed itself: success. Back to Ready while still
            # registered means it finished without getting there: failure.
            if (-not $Task -or $Task.State -eq 'Ready') { break }
            Start-Sleep -Seconds 2
        }

        if (Test-Path $Log) { Get-Content $Log | ForEach-Object { Write-Host "   $_" } }

        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            $Result = (Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            throw "Task $TaskName did not remove itself (last result $Result) - '$Label' failed, see output above"
        }
        Write-Host "'$Label' done, task removed itself"
    } finally {
        Remove-Item -Path $Body, $Log -Force -ErrorAction SilentlyContinue
    }
}

$Fqdn = "$SelfName.$($Config.DomainName)"
Invoke-AsDomainAdmin -Label 'dhcp-authorise' -Variables @{ Fqdn = $Fqdn } -Script {
    if (-not (Get-DhcpServerInDC | Where-Object DnsName -eq $Fqdn)) {
        Add-DhcpServerInDC -DnsName $Fqdn
        Write-Host "Authorised $Fqdn in AD"
    } else {
        Write-Host "$Fqdn already authorised in AD"
    }
}

# The AD entry alone is not enough: the service checks it at startup and then
# only about hourly, so it keeps refusing clients until restarted. Verify the
# service's own view, not just AD's. A restart seconds after authorising can
# still come up unauthorised (seen on SRV-DHCP-02: restart 7s after, refused;
# restart 2 min after, fine), so keep restarting for a while.
foreach ($Attempt in 1..10) {
    if ((Get-DhcpServerSetting).IsAuthorized) { break }
    Write-Host "Restarting DHCPServer so it picks up the authorisation (attempt $Attempt/10)"
    Restart-Service DHCPServer -WarningAction SilentlyContinue
    foreach ($i in 1..15) {
        if ((Get-DhcpServerSetting).IsAuthorized) { break }
        Start-Sleep -Seconds 2
    }
}
if (-not (Get-DhcpServerSetting).IsAuthorized) {
    throw "DHCPServer still not authorised after 5 minutes of restarts - check System log for DHCP-Server events 1046/1059"
}
Write-Host "DHCP service reports itself authorised"

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
            Write-Host "Scope $Name ($Scope_Id) already exists, reapplying options"
        } else {
            # No -ScopeId here: the scope id is derived from StartRange and SubnetMask.
            Write-Host "Creating scope $Name ($Scope_Id)"
            Add-DhcpServerv4Scope -Name $Name `
                -StartRange $Start -EndRange $End -SubnetMask $SubnetMask -State Active
        }

        # Always (re)set, so a run that died after creating the scope still
        # ends up with options. The mask is the scope's own, not option 1.
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

    $Vars = @{
        PartnerFqdn    = "$Primary.$($Config.DomainName)"
        Fqdn           = $Fqdn
        RelationName   = "$Primary-$SelfName"
        FailoverSecret = $FailoverSecret
    }
    Invoke-AsDomainAdmin -Label 'dhcp-failover' -Variables $Vars -Script {
        $ScopeIds = (Get-DhcpServerv4Scope -ComputerName $PartnerFqdn).ScopeId
        if (-not $ScopeIds) {
            # A throw, not a warning: returning 0 would count as deployed.
            throw "$PartnerFqdn has no scopes yet - deploy it first, then re-run"
        }
        $Secret = ConvertTo-SecureString -String $FailoverSecret -AsPlainText -Force
        Write-Host "Creating 50/50 failover with $PartnerFqdn over $($ScopeIds.Count) scopes"
        Add-DhcpServerv4Failover -ComputerName $PartnerFqdn -PartnerServer $Fqdn `
            -Name $RelationName -ScopeId $ScopeIds `
            -LoadBalancePercent 50 -SharedSecret $Secret -Force
    }
}
