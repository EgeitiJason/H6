$ErrorActionPreference = 'Stop'
$hdr = @{ Authorization = 'Bearer nbt_wYhD7idd1T2e.giwaKyYCbYU4ERU8Q3B3QEmIiYRYzjonptMPt22p'; Accept = 'application/json' }
$Base = 'http://10.0.10.21/api'

function NB($method, $path, $payload) {
    $p = @{ Uri = "$Base/$path"; Method = $method; Headers = $hdr; ContentType = 'application/json; charset=utf-8' }
    if ($payload) { $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 6)) }
    try { Invoke-RestMethod @p }
    catch {
        $msg = $_.ErrorDetails.Message
        if (-not $msg -and $_.Exception.Response) { $msg = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }
        throw "$method $path failed: $msg"
    }
}
function Find($path, $query) { $r = NB GET "$path/?$query" $null; if ($r.count -ge 1) { $r.results[0] } else { $null } }
function Ensure($path, $query, $payload) {
    $o = Find $path $query
    if ($o) { NB PATCH "$path/$($o.id)/" $payload | Out-Null; return (NB GET "$path/$($o.id)/" $null) }
    NB POST "$path/" $payload
}

$ubnt = Ensure 'dcim/manufacturers' 'slug=ubiquiti' @{ name = 'Ubiquiti'; slug = 'ubiquiti' }
$roleAp = Ensure 'dcim/device-roles' 'slug=access-point' @{ name = 'Access Point'; slug = 'access-point'; color = '00bcd4'; vm_role = $false }
$dtU7 = Ensure 'dcim/device-types' 'slug=unifi-u7-pro' @{ manufacturer = $ubnt.id; model = 'UniFi U7 Pro'; slug = 'unifi-u7-pro'; u_height = 0
    comments = 'Wi-Fi 7 access point, single 2.5GbE uplink with PoE+. Model taken from the LLDP/DHCP hostname U7-Pro.' }
$dtGen = Ensure 'dcim/device-types' 'slug=unifi-ap-unspecified' @{ manufacturer = $ubnt.id; model = 'UniFi AP (model unspecified)'; slug = 'unifi-ap-unspecified'; u_height = 0
    comments = 'Placeholder: the device reports only the Ubiquiti OUI, not a model. Replace with the real type once the UniFi controller has been checked.' }

$aps = @(
    @{ name = 'NW-AP-DC1-01'; site = 1; type = $dtGen.id; mac = '9C:05:D6:BA:C1:C9'; ip = '10.0.99.80/24'
       swIf = 30; sw = 'NW-ASW-DC1-01 Gi1/0/8'
       comments = 'UniFi AP Middelfart. Authenticates by MAB; PacketFence returns the interface template PF_UNIFI_AP, which turns the switch port into a trunk (native VLAN 99, tagged 20 and 100). Model not yet confirmed.' }
    @{ name = 'NW-AP-DC2-01'; site = 2; type = $dtU7.id; mac = '9C:05:D6:BA:BE:D5'; ip = $null
       swIf = 161; sw = 'NW-ASW-DC2-01 Gi1/0/45'
       comments = 'UniFi U7 Pro, Odense. Authenticates by MAB; PacketFence returns PF_UNIFI_AP. Last known addresses 10.10.99.125 and 10.0.99.127 (22 Sep 2026); no current DHCP lease, so no primary IP is recorded.' }
)

foreach ($a in $aps) {
    $dev = Ensure 'dcim/devices' ("name=" + [Uri]::EscapeDataString($a.name)) @{
        name = $a.name; device_type = $a.type; role = $roleAp.id; site = $a.site; status = 'active'; comments = $a.comments }
    Write-Host "device $($dev.id) $($dev.name)"

    $if = Ensure 'dcim/interfaces' "device_id=$($dev.id)&name=eth0" @{ device = $dev.id; name = 'eth0'; type = '2.5gbase-t'
        description = "Uplink to $($a.sw) (PoE)"; mode = 'tagged'; untagged_vlan = $(if ($a.site -eq 1) { 5 } else { 16 }) }
    $m = Find 'dcim/mac-addresses' ("mac_address=" + $a.mac + "&interface_id=" + $if.id)
    if (-not $m) { $m = NB POST 'dcim/mac-addresses/' @{ mac_address = $a.mac; assigned_object_type = 'dcim.interface'; assigned_object_id = $if.id } }
    NB PATCH "dcim/interfaces/$($if.id)/" @{ primary_mac_address = $m.id } | Out-Null

    if ($a.ip) {
        $ip = Find 'ipam/ip-addresses' ("address=" + [Uri]::EscapeDataString($a.ip))
        $body = @{ status = 'active'; assigned_object_type = 'dcim.interface'; assigned_object_id = $if.id; dns_name = "$($a.name.ToLower()).mfrace.internal"; description = "$($a.name) management" }
        if ($ip) { NB PATCH "ipam/ip-addresses/$($ip.id)/" $body | Out-Null } else { $body.address = $a.ip; $ip = NB POST 'ipam/ip-addresses/' $body }
        NB PATCH "dcim/devices/$($dev.id)/" @{ primary_ip4 = $ip.id } | Out-Null
        Write-Host "  ip $($a.ip)"
    }

    # cable to the switch port
    $sif = NB GET "dcim/interfaces/$($a.swIf)/" $null
    if (-not $sif.cable -and -not $if.cable) {
        NB POST 'dcim/cables/' @{ status = 'connected'; type = 'cat6'
            a_terminations = @(@{ object_type = 'dcim.interface'; object_id = $if.id })
            b_terminations = @(@{ object_type = 'dcim.interface'; object_id = $sif.id }) } | Out-Null
        Write-Host "  cable eth0 <-> $($a.sw)"
    } else { Write-Host "  cable already present" }
}
Write-Host 'DONE'
