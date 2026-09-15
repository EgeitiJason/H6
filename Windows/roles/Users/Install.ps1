<#
    Users, their department groups, home folders and the drive-mapping GPO.
    Replaces h5's Import_ADUsers (three copies of the same loop) and the AD
    half of Create-FileSrv. users.csv comes from ../../generate-users.py; the
    FileServer role reads the same file for the folders.

    Runs on the primary DC after OU-Structure, since it fills those OUs.
#>
#Requires -Modules ActiveDirectory
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName,
    [string]$UserPassword
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"
. "$PSScriptRoot\..\Invoke-AsDomainAdmin.ps1"
. "$PSScriptRoot\..\Get-Departments.ps1"

if (-not $UserPassword) { throw 'USER_INITIAL_PASSWORD is empty - set it in .env' }
$Password = ConvertTo-SecureString -String $UserPassword -AsPlainText -Force
$Users    = Import-Csv "$PSScriptRoot\users.csv"
$UsersOU  = "OU=Users,$($Config.OUBase)"
$GroupsOU = "OU=Fileshares,OU=Groups,$($Config.OUBase)"

foreach ($Dept in Get-Departments) {
    $Group = "SG-$Dept"
    if (Get-ADGroup -Filter "Name -eq '$Group'") {
        Write-Host "Group $Group already exists"
    } else {
        New-ADGroup -Name $Group -SamAccountName $Group -GroupScope Global `
            -GroupCategory Security -Path $GroupsOU
        Write-Host "Created group $Group"
    }
}

$Existing = @{}
Get-ADUser -Filter * | ForEach-Object { $Existing[$_.SamAccountName] = $true }

foreach ($User in $Users) {
    # Reapplied on every run, so a user created by a run that died still ends
    # up complete. The password is only ever set at creation.
    $Attributes = @{
        Department    = $User.department
        Title         = $User.title
        HomeDrive     = 'H:'
        HomeDirectory = "\\$($Config.FileServer)\Privat\$($User.sam)"
    }
    if ($Existing[$User.sam]) {
        Set-ADUser -Identity $User.sam @Attributes
        continue
    }
    $Name = "$($User.given_name) $($User.surname)"
    New-ADUser @Attributes -Name $Name -DisplayName $Name `
        -GivenName $User.given_name -Surname $User.surname `
        -SamAccountName $User.sam -UserPrincipalName "$($User.sam)@$($Config.DomainName)" `
        -Path "$($User.ou),$UsersOU" `
        -AccountPassword $Password -ChangePasswordAtLogon $true -Enabled $true
    Write-Host "Created user $($User.sam) ($Name)"
}
Write-Host "$($Users.Count) users in place"

foreach ($Dept in $Users | Group-Object department) {
    $Group   = "SG-$($Dept.Name)"
    $Members = @((Get-ADGroupMember -Identity $Group).SamAccountName)
    $Missing = @($Dept.Group.sam | Where-Object { $_ -notin $Members })
    if ($Missing) {
        Add-ADGroupMember -Identity $Group -Members $Missing
        Write-Host "Added $($Missing.Count) members to $Group"
    } else {
        Write-Host "$Group membership already complete"
    }
}

# Drive mapping. H: needs nothing more - Windows maps HomeDirectory at logon.
# The script goes into NETLOGON through its local path; the GPO itself lives
# in SYSVOL, which the key-based SSH logon cannot write, hence the task.
$ScriptName = 'map-drives.cmd'
Set-Content -Path "$((Get-SmbShare -Name NETLOGON).Path)\$ScriptName" -Encoding ascii -Value @(
    '@echo off'
    "net use F: \\$($Config.FileServer)\Faelles /persistent:no >nul 2>&1"
    "net use G: \\$($Config.FileServer)\Afdelinger /persistent:no >nul 2>&1"
)

$Vars = @{
    GpoName = 'GPO_MFRACE_Drev_Mapping'
    Target  = $UsersOU
    Command = "\\$($Config.DomainName)\NETLOGON\$ScriptName"
}
Invoke-AsDomainAdmin -Label 'drive-gpo' -Variables $Vars -Script {
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) {
        Write-Host "GPO $GpoName already exists"
    } else {
        New-GPO -Name $GpoName | Out-Null
        Write-Host "Created GPO $GpoName"
    }
    Set-GPRegistryValue -Name $GpoName -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' `
        -ValueName 'MapDrives' -Type String -Value $Command | Out-Null

    if ((Get-GPInheritance -Target $Target).GpoLinks.DisplayName -contains $GpoName) {
        Write-Host "GPO already linked to $Target"
    } else {
        New-GPLink -Name $GpoName -Target $Target | Out-Null
        Write-Host "Linked GPO to $Target"
    }
}
