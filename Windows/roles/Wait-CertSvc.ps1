# Dot-sourced by the PKI roles.

# certsvc reports Running before its RPC interface answers, and everything that
# drives a CA - certutil -crl, Add-CATemplate, the OCSP configuration - then
# fails with 0x800706BA (RPC server unavailable). Call this after starting or
# restarting the service.
function Wait-CertSvc {
    param([int]$TimeoutSeconds = 150)
    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        certutil.exe -ping | Out-Null
        if (-not $LASTEXITCODE) { return }
        if ((Get-Date) -gt $Deadline) { throw "certsvc did not answer RPC within ${TimeoutSeconds}s (exit $LASTEXITCODE)" }
        Write-Host "Waiting for certsvc to answer RPC"
        Start-Sleep -Seconds 5
    }
}
