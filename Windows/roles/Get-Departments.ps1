# Dot-sourced by the Users and FileServer roles. Departments are the leaf OUs
# under Users in OU-Structure/ous.psd1, except those marked Department = $false.
# Same-named leaves under different parents collapse into one department.
function Get-Departments {
    function Get-Leaves([hashtable]$Node) {
        if ($Node.Children) {
            foreach ($Child in $Node.Children) { Get-Leaves $Child }
        } elseif ($Node.Department -ne $false) {
            $Node.Name
        }
    }
    $Tree  = Import-PowerShellDataFile "$PSScriptRoot\OU-Structure\ous.psd1"
    $Users = $Tree.OUs.Children | Where-Object Name -eq 'Users'
    $Users.Children | ForEach-Object { Get-Leaves $_ } | Sort-Object -Unique
}
