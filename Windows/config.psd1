@{
    DomainName   = 'mfrace.internal'
    DomainDN     = 'DC=mfrace,DC=internal'
    OUBase       = 'OU=Middelfart Racing,DC=mfrace,DC=internal'
    PrimaryDCIP  = '10.0.10.10'
    SecondaryDCIP = '10.0.10.11'
    DNSForwarder = '8.8.8.8'
    TimeZone     = 'Romance Standard Time'
    PrimarySite  = 'Middelfart'
    Sites        = @('Odense')
    SiteLinkName = 'MiddelfartRace-Site-Link'
    DhcpServers  = @('SRV-DHCP-01', 'SRV-DHCP-02')
    FileServer   = 'SRV-FILE-01'

    # Two-tier PKI: an offline, non-joined root that signs only the issuing
    # CA, which serves the root's certificate and CRL over HTTP.
    RootCA       = @{ Name = 'SRV-PKI-01'; IP = '10.0.10.17'; CommonName = 'MFRACE-Root-CA' }
    IssuingCA    = @{ Name = 'SRV-PKI-02'; IP = '10.0.10.18'; CommonName = 'MFRACE-Issuing-CA' }

    # 802.1X client policies. One GPO per SSID, each filtered to its own
    # computer group, so a test machine gets exactly one wireless network.
    Dot1x        = @{
        RadiusServer = 'srv-radius-01.mfrace.internal'
        WiredGpo     = 'GPO_MFRACE_Dot1x_Wired'
        Networks     = @(
            @{ SSID = 'MFRACE-MID'; Group = 'SG-Wifi-MID'; Gpo = 'GPO_MFRACE_Wifi_MID' }
            @{ SSID = 'MFRACE-ODE'; Group = 'SG-Wifi-ODE'; Gpo = 'GPO_MFRACE_Wifi_ODE' }
        )
    }

    # Template each PVE datacenter clones from. Must exist on shared storage
    # for a cluster, local storage for a standalone host.
    Templates    = @{
        'PROD-1'   = 9000
        'BACKUP-1' = 9000
        'BACKUP-2' = 9000
    }
}
