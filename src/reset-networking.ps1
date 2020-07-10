#ps1

$action = {
    Remove-ItemProperty -Name "NetworkConfigPlugin" -Path 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init\*\Plugins';
    & 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\Python\Scripts\cloudbase-init.exe' --config-file 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\ipchange\conf\cloudbase-init.conf'
    & 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\Python\python.exe' 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\ipchange\scripts\notify.py' "NIC_ADD"
}

Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance isa 'Win32_NetworkAdapter'" -Action $action