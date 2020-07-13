# Copyright 2020 Cloudbase Solutions Srl
param(
    $RawNetworkConfig
)

$ErrorActionPreference = "Stop"

$logFile = Join-Path "${env:ProgramFiles}\Cloudbase Solutions\Cloudbase-Init\log" "network-config.txt"

function Write-Log {
    <#
    .SYNOPSIS
     Writes timestamped logs to the console and log file
    #>
    Param($log)

    $logMessage = "{0} - {1}" -f @((Get-Date), $log)
    Write-Host $logMessage
    Add-Content -Value $logMessage -Path $logFile -Force -Encoding Ascii `
        -ErrorAction SilentlyContinue
}

function Execute-Retry {
    Param(
        [parameter(Mandatory=$true)]
        $command,
        [int]$MaxRetryCount=4,
        [int]$RetryInterval=4
    )

    $currErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $retryCount = 0
    while ($true) {
        try {
            $res = Invoke-Command -ScriptBlock $command
            $ErrorActionPreference = $currErrorActionPreference
            return $res
        } catch [System.Exception] {
            $retryCount++
            if ($retryCount -ge $MaxRetryCount) {
                $ErrorActionPreference = $currErrorActionPreference
                throw
            } else {
                if ($_) {
                    Write-Log $_
                }
                Start-Sleep $RetryInterval
            }
        }
    }
}


function Set-InterfaceSubnets {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [object]$Iface,
        [Parameter(Mandatory=$true)]
        [array]$Subnets
    )
    PROCESS {
        # Interfaces that only have manual subnet types will be disabled
        # Interfaces that are meant to be part of bond ports will be enabled
        # while setting up the bond port
        $isManual = $true
        try {
            Remove-NetIPAddress -InterfaceIndex $Iface.ifIndex -Confirm:$false
        } catch {
            Write-Log "Could not remove network IP addresses"
        }
        Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | `
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -DestinationPrefix "::/0" -ErrorAction SilentlyContinue | `
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        $subnets = $subnets | Sort-Object { !$_["public"]}
        foreach($subnet in $subnets) {
            switch ($subnet["type"]) {
                "static" {
                    Write-Log "Setting static subnet for iface $($Iface.ifIndex)"
                    # we have at least one static subnet on this interface
                    $isManual = $false
                    $cidr = $subnet["address"]
                    if (!$cidr) {
                        continue
                    }
                    $ip, $prefixLength = $cidr.Split("/")
                    $gateway = $subnet["gateway"]
                    $addressFamily = "ipv4"
                    if ($subnet["address_family"]) {
                        $addressFamily = $subnet["address_family"]
                    }

                    Set-NetIPInterface -InterfaceIndex $Iface.ifIndex -Dhcp Disabled
                    if ($gateway) {
                        if (!$subnet["public"]) {
                            $destPrefix = "10.0.0.0"
                            $netMask = "255.0.0.0"
                            $prefixLength = "30"
                            $metric = 261
                            New-NetIPAddress -IPAddress $ip `
                                     -PrefixLength $prefixLength `
                                     -InterfaceIndex $Iface.ifIndex `
                                     -AddressFamily $addressFamily `
                                     -Confirm:$false -ErrorAction "Stop" | Out-Null
                            Start-Sleep 15
                            $routeAddOutput = $(route -p add "$destPrefix" mask "$netMask" "$gateway" metric $metric 2>&1)
                            Write-Log "Route output: $routeAddOutput"
                            if ($routeAddOutput -like "*fail*") {
                                Start-Sleep 60
                                $routeAddOutput = $(route -p add "$destPrefix" mask "$netMask" "$gateway" metric $metric 2>&1)
                                Write-Log "Route output: $routeAddOutput"
                            }
                        } else {
                            New-NetIPAddress -IPAddress $ip `
                                     -PrefixLength $prefixLength `
                                     -InterfaceIndex $Iface.ifIndex `
                                     -AddressFamily $addressFamily `
                                     -DefaultGateway $gateway `
                                     -Confirm:$false -ErrorAction "Stop" | Out-Null
                        }
                    }

                    $nameservers = $subnet["dns_nameservers"]
                    if ($nameservers -and $nameservers.Count -gt 0) {
                        Set-DnsClientServerAddress -InterfaceIndex $Iface.ifIndex `
                            -ServerAddresses $nameservers -Confirm:$false | Out-Null
                    }
                }
                "dhcp4" {
                    # this is the default on Windows. However, if the main adapter has DHCP enabled and there is an alias
                    # with static address assigned, then DHCP will be disabled on the interface as a whole
                    $isManual = $false
                    Set-NetIPInterface -InterfaceIndex $Iface.ifIndex -Dhcp Enabled
                    continue
                }
            }
        }
        if($isManual) {
            Disable-NetAdapter -InputObject $Iface -Confirm:$false | Out-Null
        }
    }
}


function Set-Nameservers {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        $nameservers
    )

    PROCESS {
        $searchSuffix = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
        $addresses = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
        foreach ($nameserver in $nameservers) {
            if ($nameserver.search -and $nameserver.search.Count -gt 0){
                foreach ($s in $nameserver.search) {
                    $searchSuffix.Add($s)
                }
            }
            if ($nameserver.address) {
                $addresses.Add($nameserver.address)
            }
        }

        if ($searchSuffix.Count) {
            Write-Log "Setting global DNS Suffix to ${searchSuffix}"
            Set-DnsClientGlobalSetting -SuffixSearchList $searchSuffix -Confirm:$false | Out-null
        }

        if ($addresses) {
            Write-Log "Setting global DNSses to ${addresses}"
            Set-DnsClientServerAddress * -ServerAddresses $addresses -Confirm:$false | Out-Null
        }
    }
}


function Get-ExampleNetworkData {
    param($DataType = "raw")

    $txtData = '{"services": [{"type": "dns", "address": "8.8.8.8"}], "networks": [{"network_id": "81d5292e-790a-4b1a-8dff-f6dffec066fb", "type": "ipv4", "services": [{"type": "dns", "address": "8.8.8.8"}], "netmask": "255.255.255.0", "link": "tap854477c8-bb", "routes": [{"netmask": "0.0.0.0", "network": "0.0.0.0", "gateway": "192.168.5.1"}], "ip_address": "192.168.5.17", "id": "network0"}], "links": [{"ethernet_mac_address": "00:15:5D:64:98:60", "mtu": 1450, "type": "ovs", "id": "tap854477c8-bb", "vif_id": "854477c8-bbfe-48f5-894d-80f0cdfcca60"}]}'

    if ($DataType -eq "raw") {
        return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($txtData))
    }

    if ($DataType -eq "json") {
        return $txtData | ConvertFrom-Json
    }

    return $txtData
}


function Parse-NetworkConfig {
    param($RawNetworkConfig)

    $fromBase64 = [Text.Encoding]::Utf8.GetString([Convert]::FromBase64String($RawNetworkConfig))

    $networkConfig = $fromBase64 | ConvertFrom-Json

    return $networkConfig
}


function Set-Links {
    param($Links)

    foreach ($link in $Links) {
        $iface = Get-NetAdapter | Where-Object `
            { $_.MacAddress -eq ($link.ethernet_mac_address -Replace ":","-") }
        if (!$iface) {
            throw "Link with MAC address $($link.ethernet_mac_address) does not exist"
        }

        # Rename Link
        if ($link.id -and $iface.Name -ne $link.id) {
            Write-Log "Renaming link $($iface.Name) to $($link.id)"
            Rename-NetAdapter -InputObject $iface -NewName $link.id -Confirm:$false | Out-Null
            $iface = Get-NetAdapter | Where-Object `
                { $_.MacAddress -eq ($link.ethernet_mac_address -Replace ":","-") }
        }

        # Bring link up
        if ($iface.Status -ne "Up") {
            Write-Log "Enabling interface $($iface.Name)"
            $iface | Enable-NetAdapter | Out-Null
        }

        # Set link MTU
        if ($link.mtu) {
            Execute-Retry {
                $iface = Get-NetAdapter | Where-Object `
                    { $_.MacAddress -eq ($link.ethernet_mac_address -Replace ":","-") }
                Write-Log "Setting MTU $($link.mtu) for link $($iface.name)"
                $netshOut = $(netsh.exe interface ipv4 set subinterface "$($iface.name)" mtu="$($link.mtu)" store=persistent 2>&1)
                if ($LASTEXITCODE) {
                    throw "MTU could not be set for link $($iface.name). Error: ${netshOut}"
                }
            }
        }
    }
}


function Set-Networks {
    param($Networks)
    foreach ($network in $Networks) {
        Write-Log "Configuring network for link $($network.link)"

        $iface = Get-NetAdapter | Where-Object { $_.Name -eq $network.link }
        if (!$iface -or $iface.Count -gt 1) {
            throw "No interface or multiple interfaces have been found with name $($network.link)"
        }

        if ($network.type -eq "ipv4_dhcp" -or $network.type -eq "ipv6_dhcp") {
            $addressFamily = "IPv4"
            if ($network.type -eq "ipv6_dhcp") {
                $addressFamily = "IPv6"
            }
            Write-Log "Enabling DHCP on interface $($network.link)"
            Set-NetIPInterface -InterfaceIndex $iface.ifIndex -Dhcp Enabled `
                -AddressFamily $addressFamily
            continue
        }
    }
}


function Main {
    param($RawNetworkConfig)

    $networkConfig = Parse-NetworkConfig $RawNetworkConfig

    Write-Log $networkConfig
    $links = $networkConfig.links
    $networks = $networkConfig.networks
    $nameservers = $networkConfig.services | Where-Object { $_.type -eq "dns" }

    Set-Links $links
    Set-Networks $networks
    Set-Nameservers $nameservers
}


$RawNetworkConfig = Get-ExampleNetworkData -DataType "raw"
Main $RawNetworkConfig
