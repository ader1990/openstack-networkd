#ps1

# Cleaning the ghost / hidden network devices
$action = {
    (Get-PnpDevice -Class NET | Where-Object {$_.Status -eq "Unknown"}).InstanceId | ForEach-Object {
        $instanceRegKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_)"
        Get-Item $instanceRegKeyPath | Select-Object -ExpandProperty Property | ForEach-Object {
            Remove-ItemProperty -Path $instanceRegKeyPath -Name $_
        }
    }
}

# InstanceDeletionEvents are not triggered on live detach
# Register-WmiEvent -Query "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance isa 'Win32_NetworkAdapter'" -Action $action

# This will work only if the detach is done before the attach
Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance isa 'Win32_NetworkAdapter'" -Action $action

# Best way / safest way is to use ipconfig /release and /renew at boot time
# If running as LocalScript or Userdata using cloudbase-init

# ps1
ipconfig /release
ipconfig /renew
# 1002 - don’t reboot now and run the plugin again on next boot
exit 1002
