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

function Set-PhysicalAdapters {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.List[object]]$Data
    )
    PROCESS {
        foreach($nic in $Data) {
            $mac = $nic.mac
            if (!$mac) {
                Write-Log "MAC address is not present in the data"
                continue
            }
            $Iface = Get-NetAdapter | Where-Object {$_.MacAddress -eq ($mac -Replace ":","-")}
            if (!$Iface) {
                Write-Log ("Net adapter with MAC {0} could not be found" -f $mac)
                continue
            }
            $Iface | Enable-NetAdapter | Out-Null
            if ($nic.name -and ($nic.Name -ne $Iface.Name)) {
                Rename-NetAdapter -InputObject $Iface -NewName $nic.name -Confirm:$false `
                    -ErrorAction SilentlyContinue | Out-Null
            }
            if ($nic["mtu"]) {
                netsh interface ipv4 set subinterface $nic["name"] mtu=$nic["mtu"] store=persistent 2>&1 | Out-Null
            }
            if ($nic["subnets"] -and $nic["subnets"].Count -gt 0) {
                Set-InterfaceSubnets -Iface $Iface -Subnets $nic["subnets"] | Out-Null
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
        [System.Collections.Generic.List[object]]$nameservers
    )
    PROCESS {
        $searchSuffix = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
        $addresses = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
        foreach ($i in $nameservers) {
            if($i["search"] -and $i["search"].Count -gt 0){
                foreach($s in $i["search"]) {
                    $searchSuffix.Add($s)
                }
            }
            if($i["address"]){
                $addresses.Add($i["address"])
            }
        }
        if($searchSuffix.Count) {
            Set-DnsClientGlobalSetting -SuffixSearchList $searchSuffix -Confirm:$false | out-null
        }
        Set-DnsClientServerAddress * -ServerAddresses $addresses -Confirm:$false | out-null
    }
}

function Get-AdaptersFromList {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [array]$Ifaces
    )
    PROCESS {
        $interfaces = Get-NetAdapter | Where-Object {$_.Name -in $Ifaces}
        if($interfaces.Count -ne $Ifaces.Count) {
            return
        }
        return $interfaces
    }
}

function Check-NetworkConnectivity {
    Param($TeamNicName)

    $adapter = Get-NetAdapter -Name $teamNicName -ErrorAction SilentlyContinue
    if ((!$adapter) -or ($adapter.Status -ne "Up") -or ($adapter.InterfaceOperationalStatus -ne 1) `
        -or ($adapter.AdminStatus -ne 'Up') -or ($adapter.MediaConnectionState -ne "Connected")) {
        throw "Bond ${bondName}: bond nic state is not up"
    } else {
        Write-Log "Bond ${bondName}: bond nic state is up"
    }
    $testConnectionServers = @("google.com", "packet.net")
    foreach ($testConnectionServer in $testConnectionServers) {
        Write-Log "Testing connection to server: ${testConnectionServer}"
        $result = Test-NetConnection $testConnectionServer
        if (!$result.PingSucceeded) {
            throw "Failed to connect to $testConnectionServer"
        } else {
            Write-Log "Successfully connected to server: $testConnectionServer ($($result.RemoteAddress))"
        }
    }
}

function Set-BondInterfaces {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [array]$Data
    )
    PROCESS {
        $haveLbfo = Get-Command *NetLbfo*
        if (!$haveLbfo) {
            Write-Log "NET_LBFO is not supported on this OS."
            return
        }
        $required = @(
            "name",
            "mac_address",
            "bond_interfaces",
            "params"
        )
        foreach ($bond in $data) {
            $bondName = "bond_" + $bond["name"]
            $teamNicName = $bond["name"]
            $team = try {
                Get-NetLbfoTeam -Name $bondName -ErrorAction SilentlyContinue
            } catch {
                Write-Log $_
            }
            if ($team) {

                try {
                    Execute-Retry {
                        Check-NetworkConnectivity $teamNicName
                    } -MaxRetryCount 5 -RetryInterval 1
                    continue
                } catch {
                    Write-Log "Bond nic ${teamNicName} does not have connectivity"
                }

                Write-Log "Trying to reset bond members"
                try {
                    $Ifaces = Get-AdaptersFromList $bond["bond_interfaces"]
                    $Ifaces | Disable-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                    $Ifaces | Enable-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
                    Execute-Retry {
                        Check-NetworkConnectivity $teamNicName
                    } -MaxRetryCount 5 -RetryInterval 1
                    continue
                } catch {
                    Write-Log "Bond nic ${teamNicName} does not have connectivity"
                }

                Write-Log "Trying to reset bond nic mac address"
                try {
                    $Ifaces = Get-AdaptersFromList $bond["bond_interfaces"]
                    $primary = $Ifaces | Where-Object {$_.MacAddress -eq ($bond["mac_address"] -Replace ":","-")}
                    $bondIface = Get-NetAdapter $teamNicName
                    if ($bondIface.MacAddress -ne $primary.MacAddress) {
                        $registryNics = Get-childItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}'`
                            -ErrorAction SilentlyContinue
                        $bondRegistryNic = $registryNics | Where-Object {((Get-ItemProperty -Path $_.name.Replace('HKEY_LOCAL_MACHINE\',"hklm://") `
                            -Name "DriverDesc" -ErrorAction SilentlyContinue) | Select-Object "DriverDesc").DriverDesc `
                            -eq 'Microsoft Network Adapter Multiplexor Driver'}
                        New-ItemProperty -Force -Path $bondRegistryNic.Name.Replace('HKEY_LOCAL_MACHINE\',"hklm://") `
                            -Name "NetworkAddress" -Type String -Value $primary.MacAddress.replace("-","") `
                            -ErrorAction SilentlyContinue

                        Disable-NetAdapter -Name $teamNicName -Confirm:$false -ErrorAction SilentlyContinue
                        Enable-NetAdapter -Name $teamNicName -Confirm:$false -ErrorAction SilentlyContinue

                        Execute-Retry {
                            Check-NetworkConnectivity $teamNicName
                        } -MaxRetryCount 5 -RetryInterval 1
                        continue
                    } else {
                        Write-Log "Bond nic has the same MAC address as the primary NIC"
                    }
                } catch {
                    Write-Log "Bond nic ${teamNicName} does not have connectivity"
                }

                Write-Log "Removing bond to be recreated, as all the saving steps failed"
                $team | Remove-NetLbfoTeam -Confirm:$false
            }

            $missing = $false
            foreach ($req in $required) {
                if ($req -notin $bond.Keys) {
                    $missing = $true
                }
            }
            if ($missing) {
                Write-Log "There are missing parameters in the bonding information"
                continue
            }
            # get interfaces
            $Ifaces = Get-AdaptersFromList $bond["bond_interfaces"]
            if (!$Ifaces) {
                Write-Log "Failed to get the bonding network adapters"
                continue
            }

            # Enable net adapters
            $Ifaces | Enable-NetAdapter | Out-Null

            # get Primary / secondary Iface
            $primary = $Ifaces | Where-Object {$_.MacAddress -eq ($bond["mac_address"] -Replace ":","-")}
            if (!$primary -or !$primary.MacAddress) {
                throw "Failed to retrieve primary interface"
            } else {
                Write-Log "Primary mac address for bond is: $($primary.MacAddress)"
            }

            $secondary = $Ifaces | Where-Object {
                ($_.MacAddress -ne $primary.MacAddress) -and ($bond["bond_interfaces"] -contains $_.Name)
            }
            if (!$secondary -or !$secondary.MacAddress) {
                throw "Failed to retrieve secondary interface"
            } else {
                Write-Log "Secondary mac address for bond is: $($secondary.MacAddress)"
            }

            # select proper mode. Default to Switch independent
            $mode = "SwitchIndependent"
            if ($bond["params"]["bond-mode"] -eq "802.3ad") {
                $mode = "Lacp"
            }

            $lbAlgo = "Dynamic"
            switch($bond["params"]["bond-xmit_hash_policy"]){
                "layer2" {
                    $lbAlgo = "MacAddresses"
                }
                "layer2+3" {
                    $lbAlgo = "IPAddresses"
                }
                "layer3+4" {
                    $lbAlgo = "TransportPorts"
                }
                default {
                    $lbAlgo = "Dynamic"
                }
            }
            if ($mode) {
                Execute-Retry {
                    Write-Log "Cleaning up bond $bondName"
                    Get-NetLbfoTeam -Name $bondName -ErrorAction SilentlyContinue | `
                        Remove-NetLbfoTeam -Confirm:$false

                    Write-Log "Creating bond $bondName"
                    New-NetLbfoTeam -Name $bondName `
                                    -TeamMembers ($primary.Name) `
                                    -TeamNicName $teamNicName `
                                    -TeamingMode $mode `
                                    -LoadBalancingAlgorithm $lbAlgo `
                                    -Confirm:$false | Out-Null

                    Execute-Retry {
                        if ((Get-NetLbfoTeam -Name $bondName).Status -ne "Up") {
                            throw "Bond ${bondName}: bond status is not up"
                        } else {
                            Write-Log "Bond ${bondName}: bond status is up"
                        }
                    } -MaxRetryCount 20 -RetryInterval 10

                    Execute-Retry {
                        $adapter = Get-NetAdapter -Name $teamNicName
                        if (($adapter.Status -ne "Up") -or ($adapter.InterfaceOperationalStatus -ne 1) `
                            -or ($adapter.AdminStatus -ne 'Up') -or ($adapter.MediaConnectionState -ne "Connected")) {
                            throw "Bond ${bondName}: bond nic state is not up"
                        } else {
                            Write-Log "Bond ${bondName}: bond nic state is up"
                        }
                    } -MaxRetryCount 10 -RetryInterval 10

                    Start-Sleep 10

                    Add-NetLbfoTeamMember -Team $bondName `
                                          -Name $secondary.Name `
                                          -Confirm:$false | Out-Null
                    Execute-Retry {
                        $adapter = Get-NetAdapter -Name $teamNicName
                        if (($adapter.Status -ne "Up") -or ($adapter.InterfaceOperationalStatus -ne 1) `
                            -or ($adapter.AdminStatus -ne 'Up') -or ($adapter.MediaConnectionState -ne "Connected")) {
                            throw "Bond ${bondName}: bond nic state is not up"
                        } else {
                            Write-Log "Bond ${bondName}: bond nic state is up"
                        }
                    } -MaxRetryCount 10 -RetryInterval 10
                }
            }

            $bondIface = Get-NetAdapter -Name $teamNicName -ErrorAction SilentlyContinue
            if ($bond["subnets"] -and $bond["subnets"].Count -gt 0 -and $bondIface) {
                Execute-Retry {
                    Set-InterfaceSubnets -Iface $bondIface -Subnets $bond["subnets"] | Out-Null
                }
            }
            if($bond["mtu"]) {
                netsh interface ipv4 set subinterface $bondName mtu=$bond["mtu"] store=persistent 2>&1 | Out-Null
            }
        }
    }
}

function Set-VlanInterfaces {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [array]$Data
    )
    PROCESS {
        $haveLbfo = Get-Command *NetLbfo*
        if(!$haveLbfo) {
            # most probably we are on a version of Nano that does not have support for this
            return
        }
        foreach ($nic in $Data) {
            $link = $nic["vlan_link"]
            $name = $nic["name"]
            $id = $nic["vlan_id"]
            $linkIsBond = try { Get-NetLbfoTeam -Name $link -ErrorAction SilentlyContinue }catch {}
            if(!$linkIsBond) {
                # For now only VLANs set on bonds are supported
                continue
            }
            $exists = Get-NetLbfoTeamNic -Name $name -Team $link -ErrorAction SilentlyContinue
            if($exists) {
                continue
            }
            Add-NetLbfoTeamNic -Team $link -Name $name -VlanID $id -Confirm:$false | Out-Null

            # wait for NIC to come up
            $count = 0
            while($count -lt 30) {
                $Iface = Get-NetAdapter $name -ErrorAction SilentlyContinue
                if($Iface) {
                    break
                }
                $count += 1
                Start-Sleep 2
            }
            if($Iface) {
                if($nic["subnets"] -and $nic["subnets"].Count -gt 0){
                    Set-InterfaceSubnets -Iface $Iface -Subnets $nic["subnets"]
                }
                if($nic["mtu"]) {
                    netsh interface ipv4 set subinterface $name mtu=$nic["mtu"] store=persistent 2>&1 | Out-Null
                }
            }
        }
    }
}

function Set-NetworkConfig {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$NetworkConfig
    )
    PROCESS {
        $data = [System.Collections.Generic.Dictionary[string, object]](New-Object "System.Collections.Generic.Dictionary[string, object]")
        $cfg = [System.IO.File]::ReadAllText($NetworkConfig) | ConvertFrom-Json
        if ($cfg.network) {
            $networkInfo = $cfg.network
            if ($networkInfo.interfaces) {
                $data['physical'] = $networkInfo.interfaces
                if ($networkInfo.bonding) {
                    $data['bond'] = @()
                    $bond = @{}
                    $bond['bond_interfaces'] = $networkInfo.interfaces.name
                    $bond['name'] = 'bond0'
                    $bond['mac_address'] = $networkInfo.interfaces[0].mac
                    $bond['params'] = @{}
                    if ($networkInfo.bonding.mode -eq 4) {
                        $bond['params']['bond-mode'] = "802.3ad"
                    } elseif ($networkInfo.bonding.mode -eq 5) {
                       $bond['params']['bond-mode'] = "tlb"
                       $bond['name'] = $networkInfo.interfaces[0].name
                    }
                    if ($networkInfo.addresses) {
                        $bond["subnets"] = @()
                        foreach ($packetSubnet in $networkInfo.addresses) {
                            $subnet = @{
                                "type" = "static";
                                "netmask" = $packetSubnet.netmask;
                                "address" = ($packetSubnet.address + "/" + $packetSubnet.cidr);
                                "address_family" = ("ipv" + $packetSubnet.address_family);
                                "gateway" = $packetSubnet.gateway;
                                "public" = $packetSubnet.public;
                                "network" = $packetSubnet.network
                            }
                            $bond["subnets"]  += $subnet
                        }
                    }
                    $data['bond'] += $bond
                }
                $data["nameserver"] = @(@{"address"="147.75.207.207"}, @{"address"="147.75.207.208"}, @{"address"="2001:4860:4860::8888"}, @{"address"="2001:4860:4860::8844"})
            }
        } else {
            throw "Network configuration could not be found."
        }

        # take care of the physical devices first
        if ($data["physical"]) {
            Write-Log "Setting physical network adapters"
            Set-PhysicalAdapters $data["physical"]
        }

        # take care of bonds
        if ($data["bond"]) {
            Write-Log "Setting bond network adapters"
            Set-BondInterfaces $data["bond"]
        }

        # Set VLAN links. NIC teams only for now
        if($data["vlan"]) {
            Write-Log "Setting vlan network adapters"
            Set-VlanInterfaces $data["vlan"]
        }

        # set nameservers
        if ($data["nameserver"]) {
            Write-Log "Setting nameservers"
            Set-Nameservers $data["nameserver"]
        }
    }
}


function Get-ExampleNetworkData {
    param($DataType = "raw")

    $txtData = '{"services": [{"type": "dns", "address": "8.8.8.8"}], "networks": [{"network_id": "94d81ebe-cfbb-4aa2-8081-97c025afac71", "link": "tap854477c8-bb", "type": "ipv4_dhcp", "id": "network0"}], "links": [{"ethernet_mac_address": "00:15:5D:64:98:60", "mtu": 1450, "type": "ovs", "id": "tap854477c8-bb", "vif_id": "854477c8-bbfe-48f5-894d-80f0cdfcca60"}]}'

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


function Main {
    param($RawNetworkConfig)

    $networkConfig = Parse-NetworkConfig $RawNetworkConfig

    Write-Log $networkConfig
    # Set-NetworkConfig $networkConfig
}


$RawNetworkConfig = Get-ExampleNetworkData -DataType "raw"
Main $RawNetworkConfig
