$bad = 0
Get-ChildItem -Path . -Recurse -Filter *.ps1 | ForEach-Object {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
    if ($errors) {
        $script:bad = 1
        Write-Host "PARSE FAIL $($_.Name)"
        $errors | ForEach-Object { Write-Host "   line $($_.Extent.StartLineNumber): $($_.Message)" }
    } else {
        Write-Host "ok   parse $($_.Directory.Name)/$($_.Name)"
    }
}
$c = Import-PowerShellDataFile ./config.psd1
Write-Host "ok   config loads: domain=$($c.DomainName) dhcp=$($c.DhcpServers -join ',') tmplPROD1=$($c.Templates['PROD-1'])"
exit $bad
