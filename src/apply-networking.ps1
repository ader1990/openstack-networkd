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


function Convert-IpAddressToPrefixLength {
    Param(
        $IPAddress
    )

    $maskLength = 0
    [IPAddress]$IPv4 = $IPAddress

    foreach ($Octet in ($IPv4.IPAddressToString.Split('.'))) {
        while ($Octet -ne 0) {
            $Octet = ($Octet -shl 1) -band [byte]::MaxValue
            $maskLength ++
        }
    }

    return $maskLength
}


function Set-Nameservers {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        $nameservers,
        $InterfaceAlias="*"
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
            Write-Log "Setting DNSses ${addresses} for interfaces aliases ${InterfaceAlias}"
            Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias `
                -ServerAddresses $addresses -Confirm:$false | Out-Null
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
                    throw "IPv4 MTU could not be set for link $($iface.name). Error: ${netshOut}"
                }
                $netshOut = $(netsh.exe interface ipv6 set subinterface "$($iface.name)" mtu="$($link.mtu)" store=persistent 2>&1)
                if ($LASTEXITCODE) {
                    Write-Log "IPv6 MTU could not be set for link $($iface.name). Error: ${netshOut}"
                }
            }
        }
    }
}


function Set-Network {
    param($Network)

    Write-Log "Configuring network for link $($network.link)"

    $iface = Get-NetAdapter | Where-Object { $_.Name -eq $network.link }
    if (!$iface -or ($iface | Measure-Object).Count -gt 1) {
        throw "No interface or multiple interfaces have been found with name $($network.link)"
    }

    $addressFamily = "IPv4"
    if ($network.type.IndexOf("ipv6") -gt -1) {
        $addressFamily = "IPv6"
    }

    if ($network.type.IndexOf('dhcp') -eq -1) {
        $ipAddress = $network.ip_address
        $netmask = $network.netmask
        $prefixLength = Convert-IpAddressToPrefixLength $netmask
        $nameservers = $network.services | Where-Object { $_.type -eq "dns" }
        $routes = $network.routes

        $addIpAddress = $true
        # Set network to static if DHCP was enabled
        $ipInterface = Get-NetIPInterface -InterfaceIndex $iface.ifIndex -AddressFamily $addressFamily
        if ($ipInterface.Dhcp -ne "Disabled") {
            Set-NetIPInterface -InterfaceIndex $iface.ifIndex -Dhcp "Disabled"
        } else {
            # Verify if there is the need to change the IP
            $ipAddresses = Get-NetIPAddress -InterfaceIndex $iface.ifIndex -AddressFamily $addressFamily
            if (($ipAddresses | Measure-Object).Count -eq 1) {
                # Check if there is the same IP
                if ($ipAddresses.IPAddress -eq $ipAddress -and $ipAddresses.PrefixLength -eq $prefixLength) {
                    $addIpAddress = $false
                }
            }
        }

        if ($addIpAddress) {
            Write-Log "Link $($network.link) has a different IP, remove it."
            Remove-NetIPAddress -InterfaceIndex $iface.ifIndex -Confirm:$false `
                -ErrorAction SilentlyContinue

            Write-Log "Set new IP on Link $($network.link)."
            New-NetIPAddress -IPAddress $ipAddress `
                 -PrefixLength $prefixLength `
                 -InterfaceIndex $iface.ifIndex `
                 -AddressFamily $addressFamily `
                 -Confirm:$false -ErrorAction "Stop" | Out-Null
        }

        if (!$routes) {
            Write-Log "Remove all routes for link $($network.link)"
            Remove-NetRoute -Confirm:$false -InterfaceIndex $iface.ifIndex `
                -ErrorAction SilentlyContinue -AddressFamily $addressFamily
        } else {
            $existentRoutes = Get-NetRoute -InterfaceIndex $iface.ifIndex -AddressFamily $addressFamily `
                -Protocol "NetMgmt" -ErrorAction SilentlyContinue
            $mapRoutesDesired = @()
            $mapRoutesExistent = @()
            foreach ($desiredRoute in $routes) {
                $prefixLengthR = Convert-IpAddressToPrefixLength $desiredRoute.netmask
                $nextHopR = $desiredRoute.gateway
                $networkR = $desiredRoute.network
                $mapRoutesDesired += @{
                    "initial" = @{
                        "DestinationPrefix" = "$networkR/$prefixLengthR";
                        "NextHop" = $nextHopR;
                    };
                    "for_comparison" = "$networkR/$prefixLengthR/$nextHopR";
                }
            }
            foreach ($existentRoute in $existentRoutes) {
                $mapRoutesExistent += @{
                    "initial" = @{
                        "DestinationPrefix" = $existentRoute.DestinationPrefix
                        "NextHop" = $existentRoute.NextHop;
                    };
                    "for_comparison" = $existentRoute.DestinationPrefix + "/" + $existentRoute.NextHop;
                }
            }
            $routesToRemove = $mapRoutesExistent | Where-Object { $mapRoutesDesired.for_comparison -NotContains $_.for_comparison }
            $routesToAdd = $mapRoutesDesired | Where-Object { $mapRoutesExistent.for_comparison -NotContains $_.for_comparison }
            foreach ($routeToRemove in $routesToRemove) {
                Write-Log "Removing route $($routeToRemove.for_comparison)"
                Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue `
                    -DestinationPrefix $routeToRemove.initial.DestinationPrefix `
                    -NextHop $routeToRemove.initial.NextHop `
                    -AddressFamily $addressFamily -InterfaceIndex $iface.ifIndex | Out-Null
            }
            foreach ($routeToAdd in $routesToAdd) {
                Write-Log "Adding route $($routeToAdd.for_comparison)"
                New-NetRoute -Confirm:$false -ErrorAction SilentlyContinue `
                    -DestinationPrefix $routeToAdd.initial.DestinationPrefix `
                    -NextHop $routeToAdd.initial.NextHop `
                    -AddressFamily $addressFamily -InterfaceIndex $iface.ifIndex | Out-Null
            }
        }

        Set-Nameservers $nameservers $network.link
    }

    if ($network.type.IndexOf("dhcp") -gt -1) {
        Write-Log "Enabling DHCP on interface $($network.link)"
        Set-NetIPInterface -InterfaceIndex $iface.ifIndex -Dhcp Enabled `
            -AddressFamily $addressFamily
    }
}

function Set-Networks {
    param($Networks)

    foreach ($network in $Networks) {
        Set-Network $network
    }
}


function Main {
    param($RawNetworkConfig)

    $networkConfig = Parse-NetworkConfig $RawNetworkConfig

    $links = $networkConfig.links
    $networks = $networkConfig.networks
    $nameservers = $networkConfig.services | Where-Object { $_.type -eq "dns" }

    Set-Links $links
    Set-Networks $networks
    Set-Nameservers $nameservers
}


# $RawNetworkConfig = Get-ExampleNetworkData -DataType "raw"

Main $RawNetworkConfig
