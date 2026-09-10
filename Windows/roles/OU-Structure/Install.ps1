#Requires -Modules ActiveDirectory
param(
    [string]$AdminPassword,
    [string]$FailoverSecret,
    [string]$SelfName
)

$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"
$OUBase = $Config.DomainDN

# Define OU hierarchy - modify this structure to change OUs
$ouStructure = @(
    @{
        Name = "Middelfart Racing"
        Children = @(
            @{
                Name = "Computers"
                Children = @()
            },
            @{
                Name = "Groups"
                Children = @(
                    @{ Name = "Apps" },
                    @{ Name = "Fileshares" }
                )
            },
            @{
                Name = "Servers"
                Children = @()
            },
            @{
                Name = "Users"
                Children = @(
                    @{ Name = "Admin" },
                    @{ 
                        Name = "Administration" 
                        Children = @(
                            @{ Name = "IT" },
                            @{ Name = "HR" },
                            @{ Name = "Finans" }
                        )
                    },
                    @{ Name = "Lager" },
                    @{ Name = "Service Accounts" }
                )
            }
        )
    }
)


function New-OUIfNotExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $ou = Get-ADOrganizationalUnit -Filter {Name -eq $Name} -SearchBase $Path
    
    if ($ou) {
        Write-Host "✓ OU already exists: $Name"
        return $ou.DistinguishedName
    } else {
        try {
            New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true -ErrorAction Stop
            Write-Host "✓ Created OU: $Name"
            # Query AD immediately to ensure we get the actual DistinguishedName
            $newOU = Get-ADOrganizationalUnit -Filter {Name -eq $Name} -SearchBase $Path
            return $newOU.DistinguishedName
        } catch {
            Write-Error "Failed to create OU '$Name' at '$Path': $_"
            throw $_
        }
    }
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
    if (-not $currentPath) {
        throw "Failed to create or retrieve OU '$($Node.Name)' under '$ParentPath'"
    }
    
    # Recurse into children (supports unlimited depth)
    if ($Node.Children -and $Node.Children.Count -gt 0) {
        foreach ($child in $Node.Children) {
            New-OUHierarchy -ParentPath $currentPath -Node $child
        }
    }
}


# Main execution
Write-Host "=== Creating Active Directory OU Structure ===" -ForegroundColor Cyan

# Create all OUs recursively
foreach ($ou in $ouStructure) {
    try {
        New-OUHierarchy -ParentPath $OUBase -Node $ou
    } catch {
        Write-Error "Failed to create OU '$($ou.Name)': $_"
    }
}

Write-Host "=== OU Structure Creation Complete ===" -ForegroundColor Cyan
