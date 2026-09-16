<#
    Users, their department groups and the drive-mapping GPO.
    Replaces h5's Import_ADUsers (three copies of the same loop) and the AD
    half of Create-FileSrv. users.csv comes from ../../generate-users.py.

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
        Department = $User.department
        Title      = $User.title
    }
    if ($Existing[$User.sam]) {
        # The home attributes would map H: ahead of the GPO; it owns H: now.
        Set-ADUser -Identity $User.sam @Attributes -Clear homeDrive, homeDirectory
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

# Drive mapping via Group Policy Preferences: F: Faelles, G: Afdelinger and
# H: the user's own Privat\%LogonUser%, which the GPO's logon script creates
# as the user (FileServer grants create-folder on the Privat root).
# GPMC has no cmdlets for preferences or scripts, so the files go straight
# into SYSVOL - which the key-based SSH logon cannot write, hence the task.
Remove-Item "$((Get-SmbShare -Name NETLOGON).Path)\map-drives.cmd" -ErrorAction SilentlyContinue

$Vars = @{
    GpoName     = 'GPO_MFRACE_Drev_Mapping'
    UsersOU     = $UsersOU
    ComputersOU = "OU=Computers,$($Config.OUBase)"
    DomainName  = $Config.DomainName
    FileServer  = $Config.FileServer
}
Invoke-AsDomainAdmin -Label 'drive-gpo' -Variables $Vars -Script {
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) {
        Write-Host "GPO $GpoName already exists"
    } else {
        New-GPO -Name $GpoName | Out-Null
        Write-Host "Created GPO $GpoName"
    }
    # Deletes the old map-drives.cmd Run entry on clients that already got it.
    # ponytail: drop once every client has logged on since.
    Set-GPRegistryValue -Name $GpoName -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' `
        -ValueName 'MapDrives' -Disable | Out-Null
    # Asynchronous logon scripts start five minutes after logon, so H: would
    # turn up late; synchronous ones finish before the desktop appears.
    Set-GPRegistryValue -Name $GpoName -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System' `
        -ValueName 'RunLogonScriptSync' -Type DWord -Value 1 | Out-Null
    # Computer side, hence the second link: the logon script runs on an admin's
    # elevated token, and without this Explorer on the filtered token never
    # sees the H: it mapped. Takes a client reboot.
    Set-GPRegistryValue -Name $GpoName -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -ValueName 'EnableLinkedConnections' -Type DWord -Value 1 | Out-Null

    # Fixed uids and timestamp, so a rerun writes identical files and the
    # version only moves when something really changed.
    $Changed = '2026-09-16 00:00:00'
    $Drives = @(
        @{ Letter = 'F'; Label = 'Faelles';    Path = "\\$FileServer\Faelles";            Uid = '{9CDD0D09-4C4A-4486-BAD1-E4C5BC0EF6C9}' }
        @{ Letter = 'G'; Label = 'Afdelinger'; Path = "\\$FileServer\Afdelinger";         Uid = '{A02CC8F9-1CB9-4B0B-B080-26E26678513E}' }
        @{ Letter = 'H'; Label = 'Privat';     Path = "\\$FileServer\Privat\%LogonUser%"; Uid = '{96CE6445-A1AB-4568-AE17-900424288FCB}' }
    ) | ForEach-Object {
        "  <Drive clsid=`"{935D1B74-9CB8-4e3c-9914-7DD559B7A417}`" name=`"$($_.Letter):`" status=`"$($_.Letter):`" image=`"2`" changed=`"$Changed`" uid=`"$($_.Uid)`" userContext=`"1`" removePolicy=`"1`">"
        "    <Properties action=`"U`" thisDrive=`"SHOW`" allDrives=`"NOCHANGE`" userName=`"`" path=`"$($_.Path)`" label=`"$($_.Label)`" persistent=`"0`" useLetter=`"1`" letter=`"$($_.Letter)`"/>"
        '  </Drive>'
    }
    # The logon script is a bare cmd.exe line rather than a .cmd file: a script
    # run from \\<domain> is Internet zone and prompts before it starts.
    # It also maps H: if the drive map failed: Drive Maps always runs before
    # logon scripts, so on a user's first logon the folder did not exist yet.
    # scripts.ini must be UTF-16.
    $Files = @{
        'Scripts\scripts.ini' = @{ Encoding = 'unicode'; Value = @(
            '[Logon]'
            '0CmdLine=cmd.exe'
            "0Parameters=/c mkdir `"\\$FileServer\Privat\%USERNAME%`" 2>nul & if not exist H:\ net use H: `"\\$FileServer\Privat\%USERNAME%`" /persistent:no >nul 2>&1"
        ) -join "`r`n" }
        'Preferences\Drives\Drives.xml' = @{ Encoding = 'utf8'; Value = @(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">'
            $Drives
            '</Drives>'
        ) -join "`r`n" }
    }

    $Gpo   = Get-GPO -Name $GpoName
    $Root  = "\\$DomainName\SYSVOL\$DomainName\Policies\{$($Gpo.Id)}"
    $Dirty = $false
    foreach ($File in $Files.GetEnumerator()) {
        $Path = "$Root\User\$($File.Key)"
        if ((Test-Path $Path) -and (Get-Content $Path -Raw) -eq $File.Value.Value) { continue }
        New-Item -Path (Split-Path $Path) -ItemType Directory -Force | Out-Null
        Set-Content -Path $Path -Value $File.Value.Value -Encoding $File.Value.Encoding -NoNewline
        $Dirty = $true
    }

    # Clients only run a CSE listed here, pairs sorted by CSE guid: the zero
    # guid lists the preference tools, then Registry (kept as
    # Set-GPRegistryValue wrote it), Scripts, Drive Maps.
    $Ad = Get-ADObject -Identity $Gpo.Path -Properties gPCUserExtensionNames, versionNumber
    $Registry = [regex]::Match([string]$Ad.gPCUserExtensionNames, '\[\{35378EAC[^\]]*\]').Value
    $Extensions = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]' +
        $Registry +
        '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B66650-4972-11D1-A7CA-0000F87571E3}]' +
        '[{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]'
    if ($Extensions -ne $Ad.gPCUserExtensionNames) { $Dirty = $true }

    if ($Dirty) {
        # User version is the high 16 bits; AD and GPT.INI must agree or
        # clients skip the change.
        $Version = $Ad.versionNumber + 65536
        Set-ADObject -Identity $Gpo.Path -Replace @{ gPCUserExtensionNames = $Extensions; versionNumber = $Version }
        $Ini = "$Root\GPT.INI"
        (Get-Content $Ini) -replace '^Version=\d+', "Version=$Version" | Set-Content $Ini -Encoding ascii
        Write-Host "Drive maps and logon script written to $GpoName (version $Version)"
    } else {
        Write-Host "Drive maps already in $GpoName"
    }

    foreach ($Target in $UsersOU, $ComputersOU) {
        if ((Get-GPInheritance -Target $Target).GpoLinks.DisplayName -contains $GpoName) {
            Write-Host "GPO already linked to $Target"
        } else {
            New-GPLink -Name $GpoName -Target $Target | Out-Null
            Write-Host "Linked GPO to $Target"
        }
    }
}
