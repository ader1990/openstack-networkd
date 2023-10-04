#ps1

$action = {
    Get-PnpDevice -Class NET | Where-Object {$_.Status -eq "Unknown"}).InstanceId | ForEach-Object {
        $instanceRegKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_)"
        Get-Item $instanceRegKeyPath | Select-Object -ExpandProperty Property | ForEach-Object {
            Remove-ItemProperty -Path $instanceRegKeyPath -Name $_
        }
    }
}

Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance isa 'Win32_NetworkAdapter'" -Action $action
