#Requires -Modules ActiveDirectory
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName
)
$ErrorActionPreference = 'Stop'
$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"
$OUBase = $Config.DomainDN
# The hierarchy lives in ous.psd1, shared with the Users and FileServer roles.
$ouStructure = (Import-PowerShellDataFile "$PSScriptRoot\ous.psd1").OUs


function New-OUIfNotExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    # OneLevel: a same-named OU deeper down must not count as this one.
    $ou = Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $Path -SearchScope OneLevel
    
    if ($ou) {
        Write-Host "OU already exists: $Name"
    } else {
        $ou = New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true -PassThru
        Write-Host "Created OU: $Name"
    }
    return $ou.DistinguishedName
}


function New-OUHierarchy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Node
    )
        
    # Create or get this node's OU
    $currentPath = New-OUIfNotExists -Name $Node.Name -Path $ParentPath
    
    # Recurse into children (supports unlimited depth)
    if ($Node.Children -and $Node.Children.Count -gt 0) {
        foreach ($child in $Node.Children) {
            New-OUHierarchy -ParentPath $currentPath -Node $child
        }
    }
}


# Main execution
Write-Host "=== Creating Active Directory OU Structure ===" -ForegroundColor Cyan

# Create all OUs recursively. No try/catch: a failure must reach deploy.sh
# as a non-zero exit, not a message it cannot see.
foreach ($ou in $ouStructure) {
    New-OUHierarchy -ParentPath $OUBase -Node $ou
}

Write-Host "=== OU Structure Creation Complete ===" -ForegroundColor Cyan
