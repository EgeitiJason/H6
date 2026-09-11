@{
    DomainName   = 'mfrace.internal'
    DomainDN     = 'DC=mfrace,DC=internal'
    OUBase       = 'OU=Middelfart Racing,DC=mfrace,DC=internal'
    PrimaryDCIP  = '10.0.10.10'
    DNSForwarder = '8.8.8.8'
    TimeZone     = 'Romance Standard Time'
    PrimarySite  = 'Middelfart'
    Sites        = @('Odense')
    SiteLinkName = 'MiddelfartRace-Site-Link'
    DhcpServers  = @('SRV-DHCP-01', 'SRV-DHCP-02')

    # Template each PVE datacenter clones from. Must exist on shared storage
    # for a cluster, local storage for a standalone host.
    Templates    = @{
        'PROD-1'   = 9000
        'BACKUP-1' = 9000
    }
}
