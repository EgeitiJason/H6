<#
    Runs once inside a freshly cloned VM, pushed in over the QEMU guest agent
    (see pve-bootstrap.sh). Its only job is to make the box reachable over SSH
    so deploy.sh can take over.

    Ends by rebooting, so invoke it with `qm guest exec --synchronous 0`.
#>
param (
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$Gateway,
    [Parameter(Mandatory = $true)][string]$Hostname,
    [Parameter(Mandatory = $true)][string]$PublicKey,
    [Parameter(Mandatory = $true)][string]$DnsServer,
    [int]$PrefixLength = 24
)

$ErrorActionPreference = 'Stop'

# 1. OpenSSH Server. DefaultShell is deliberately left at cmd.exe - setting it
#    to PowerShell breaks scp on Win32-OpenSSH.
if ((Get-WindowsCapability -Online -Name 'OpenSSH.Server*').State -ne 'Installed') {
    Write-Host "Installing OpenSSH Server"
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
}
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

# 2. PowerShell subsystem: this is what makes Enter-PSSession -HostName work,
#    as opposed to merely `ssh host powershell -File`.
$SshdConfig = 'C:\ProgramData\ssh\sshd_config'
$Subsystem  = 'Subsystem powershell powershell.exe -sshs -NoLogo -NoProfile'
if (-not (Select-String -Path $SshdConfig -Pattern 'Subsystem\s+powershell' -Quiet)) {
    Add-Content -Path $SshdConfig -Value $Subsystem
    Write-Host "Added powershell subsystem to sshd_config"
}

# 3. Authorized key. Admins use this machine-scoped file, not ~\.ssh, and sshd
#    ignores it silently unless only SYSTEM and Administrators can write it.
$KeyFile = 'C:\ProgramData\ssh\administrators_authorized_keys'
Set-Content -Path $KeyFile -Value $PublicKey -Encoding ascii
icacls.exe $KeyFile /inheritance:r /grant 'SYSTEM:F' /grant 'BUILTIN\Administrators:F' | Out-Null
Restart-Service -Name sshd

# 4. Network last - this cuts our own connectivity, so nothing above may need it.
if (-not (Get-NetIPAddress -IPAddress $IPAddress -ErrorAction SilentlyContinue)) {
    $Adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    Write-Host "Setting $IPAddress/$PrefixLength on $($Adapter.Name)"
    New-NetIPAddress -InterfaceIndex $Adapter.ifIndex `
        -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway
    # Points at the primary DC. Install-ADDSForest repoints the first DC at
    # itself during promotion, so this is correct for every host including it.
    Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $DnsServer
}

if ($env:COMPUTERNAME -ne $Hostname) {
    Write-Host "Renaming to $Hostname and rebooting"
    Rename-Computer -NewName $Hostname -Restart -Force
} else {
    Restart-Computer -Force
}
