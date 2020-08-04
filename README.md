# openstack-networkd
Agent for enforcing OpenStack network changes on the VMs.

For Linux:
  * create udev rules that fire on each net subsystem device add or remove to start src/openstack-networkd.sh
  * src/openstack-networkd.sh starts a python script src/cloud_init_apply_net.py
  * cloud_init_apply_net.py uses cloudinit Python package to execute only the relevant networking part
  * cloud_init_apply_net.py restarts the networking service (be it netplan, NetworkManager, networking)

The udev -> service -> bash wrapper -> Python wrapper has been chosen because:

  * udev events start only on device attach or detach (no overhead in polling every X seconds)
  * bash wrapper for simplicity and extra logging. We can remove it in the future.
  * Python wrapper for cloud-init is required for two main reasons.
    First, cloud-init cannot be configured to use a custom configuration path
    /etc/cloud, /var/run/cloud-init/, /var/lib/cloud are hardcoded.
    Secondly, if for some (wrong) reason, we could have backed up those directories and put them back after the run with
    the OpenStack service setting the network config, cloud-init cannot be configured to skip executing some plugins like
    user-data, vendor-data, which can break the environment.
    Running just the networking config part is not a pain point, as it is well decoupled and we can use all the cloud-init glue,
    logging and subprocess management. There will be two main versions of the code, as the cloud-init code has historically two
    interfaces for setting the network config for OpenStack (Debian interface file and the newer json config).
    For example, when Ubuntu 14.04 appeared, only the former was available in the OpenStack of that time.
    The Python wrapper also waits for cloud-init process to end so that no concurrency issues can be seen.
    TODO: Disable ConfigDrive's network set on reboot (as on some Ubuntu versions it tries to reset the networking, messing up with
    existing settings in netplan or /etc/network/interfaces).

# Status for the nic remove + add implementation using udev + cloud-init

Fundamental requirements:

  * kernel / udev needs to support consistent device naming (CNDN)
  * cloud-init needs to support network_data.json

Distro status:

  * Ubuntu
    * Ubuntu 14.04
      * cloud-init version 0.7.5 does not support network_data.json
      * network_config from metadata does not have MTU
      * kernel / udev does not support consistent network device naming
      * supports add nic
      * does not support remove nic as the network_config comes with eth<N> info in dumb order,
        like this: eth0, eth1, eth2. If eth1 is removed by OpenStack, the network_config contains
        information for eth0 and eth1 (eth2 info is moved to eth1 info in metadata),
        whereas the system has eth0 and eth2.
        Cloud-init only does copy / paste of the network_config to the interfaces file.
        Only a reboot solves this issue because if the OS does not have udev rules for CNDN, eth2 becomes eth1 after reboot.
      * on reboot, interfaces get renamed to the lowest number. Ex: if eth1 is no more, eth2 becomes eth1 on reboot.
      * on the first boot, cloud-init rebuild initramfs
    * Ubuntu 16.04
      * cloud-init version 19.4-33 supports network_data.json
      * kernel / udev supports CNDN via unique names
      * supports add nic
      * supports remove nic with the following caveats:
        * the removal of the nic needs to be done after the network config for the add event has finished
        * the removal of the primary nic also removes the default route for the subnet.
          This leaves no way to access the metadata endpoint in this state.
          The interfaces file at this moment contains the removed interface settings and a network reset using the networking
          service takes a lot of time (more than 2 minutes). To overcome this issue, we can use the udev environment variables,
          the action and nic name to set the removed nic on allow-hotplug (from auto) and do a faster restart of the network
          using ifdown / ifup.
    * Ubuntu 18.04
      * cloud-init version 19.4-33 supports network_data.json
      * kernel / udev supports CNDN via unique names
      * supports add / remove nic with the following caveats:
        * udev systemd daemon is not allowed to access IPs. IPAddressDeny=any is set in /lib/systemd/system/udev.service
        * in the systemd udev config file, put IPAddressAllow=169.254.169.254
        * reload udev by running 'systemctl daemon-reload && systemctl restart udev'
  * Debian
    * Debian Jessie 8 (similar to Ubuntu 14.04)
      * cloud-init is broken - does not know to bring up interfaces correctly, as it runs ifup --all without running ifdown before :|
        Even on manual ifdown/ifup, no nameservers are applied.
      * cloud-init version 0.7.6 does not support network_data.json
      * kernel / udev does not support consistent network device naming (CNDN)
      * supports add nic
      * does not support remove nic (similar to Ubuntu 14.04)
      * on reboot, interfaces get renamed to the lowest number. Ex: if eth1 is no more, eth2 becomes eth1 on reboot.
    * Debian Stretch 9
      * cloud-init version 0.7.9 supports network_data.json
      * /etc/network/interfaces comes with a predefined setting for eth0/eth1/eth2: allow-hotplug with dhcp.
        cloud-init writes the config to /etc/network/interfaces.d/50-cloud-config.conf, but because both configs are taken
        into account, every network reset takes 2 minutes for each existent nic because the DHCP clients need to timeout.
      * cloud-init configdrive tries to rename the interfaces on each reboot, and has to be disabled from doing so.
      * supports add nic
      * kernel / udev does not support consistent network device naming (CNDN).
        Linux kernel supports the feature, which is on purpose disabled from grub.
      * does not support remove nic (similar to Ubuntu 14.04)
      * on reboot, interfaces get renamed to the lowest number. Ex: if eth1 is no more, eth2 becomes eth1 on reboot.
    * Debian Buster 10
      * cloud-init version 18.3 supports network_data.json
      * /etc/network/interfaces comes with a predefined setting for eth0/eth1/eth2: allow-hotplug with dhcp.
        cloud-init writes the config to /etc/network/interfaces.d/50-cloud-config.conf, but because both configs are taken
        into account, every network reset takes 2 minutes for each existent nic because the DHCP clients need to timeout.
      * cloud-init configdrive tries to rename the interfaces on each reboot, and has to be disabled from doing so.
      * supports add nic
      * kernel / udev does not support consistent network device naming.
        Linux kernel supports the feature, which is on purpose disabled from grub.
      * does not support remove nic (similar to Ubuntu 14.04)
      * on reboot, interfaces get renamed to the lowest number. Ex: if eth1 is no more, eth2 becomes eth1 on reboot.
      * udev created a rule for eth0, but on hot-add it doesn't create a rule for the new nic
  * CentOS
    * CentOS 6 (similar to Ubuntu 14.04)
      * first boot is slow as it tries to run dhclient on eth0
      * cloud-init version 0.7.5 does not support network_data.json
      * cloud-init rebuilds initrd on first boot
      * supports add nic
      * kernel / udev does not support consistent network device naming
      * does not support remove nic (similar to Ubuntu 14.04)
      * on reboot, interfaces get renamed to the lowest number. Ex: if eth1 is no more, eth2 becomes eth1 on reboot.
    * CentOS 7
      * cloud-init version 18.5 supports network_data.json
      * cloud-init does not set DNS
      * kernel / udev does not support consistent network device naming.
        Linux kernel supports the feature, which is on purpose disabled from grub.
      * supports add nic
      * does not support remove nic
      * on reboot, interfaces get renamed to the lowest number. Ex: if eth1 is no more, eth2 becomes eth1 on reboot.
      * udev created a rule for eth0, but on hot-add it doesn't create a rule for the new nic
    * CentOS 8
      * cloud-init version 18.5 supports network_data.json
      * kernel / udev does not support consistent network device naming.
        Linux kernel supports the feature, which is on purpose disabled from grub.
      * supports add nic
      * does not support remove nic
      * on reboot, interfaces get renamed to the lowest number. Ex: if eth1 is no more, eth2 becomes eth1 on reboot.
      * udev created a rule for eth0, but on hot-add it doesn't create a rule for the new nic


# Userdata example for Ubuntu 18.04

```bash
#!/bin/bash

set -e

git clone https://github.com/ader1990/openstack-networkd
bash openstack-networkd/scripts/install_under_udev.sh

```

# Notes

The udev approach will make unintended changes outside of the "change ip" functionality.

The udev "remove" event triggers before the metadata gets updated and this needs special attention.

The udev "add" event always triggers after the metadata gets updated. This is an assumption
as far as the tests went, but this does not mean it can get triggered after
if the metadata service is slower.

Unsupported distros: Ubuntu 14.04 Trusty, Debian 8 Jessie, CentOS 6. The reasons are:

  * set on the nova-compute nodes, in the nova.conf: flat_injected = true, so that the metadata will contain the legacy
    network information in Debian format.
  * the interfaces file provided by OpenStack does not contain MTU information.
    As a consequence, if the underlying OpenStack network has a smaller MTU, big packets protocols like ssh do not work.
    To change that, on the nova-compute nodes, add a line with the MTU to the network interface template:
    /usr/lib/python2.7/dist-packages/nova/virt/interfaces.template
  * a reboot is required, as the network device is called eth(N) and the metadata information
    comes for eth(N-1)
  * it cannot use the newer cloud-init version with latest metadata, as its kernel does not support
    consistent network device naming.

For CentOS 7, the following issues appear with the remove / add NIC approach:

    * cloud-init does not remove the ifcfg-ethX for the removed interfaces
    * a random nameserver was set for no reason


# Windows


Proof of Concept using PowerShell and WMI events


Requirements:

  * Cloudbase-Init from https://github.com/ader1990/cloudbase-init-1/tree/fix_change_ip_quirks
  * Start a PowerShell script [reset-networking](src/reset-networking.ps1) under admin user
  * Custom Cloudbase-Init config from [cloudbase-init.conf](conf/cloudbase-init.conf) copied to 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\ipchange\conf\cloudbase-init.conf'
  * Custom Python notifier [windows-notify](src/windows-notify.py) copied to 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\ipchange\scripts\notify.py'

# Windows PowerShell config setter

The script [src/apply-networking](src/apply-networking.ps1) takes a base64 json OpenStack network config and applies it on the Windows machine.

Capabilities:

  * Link layer: rename and MTU set
  * IP Layer: set IP, per link DNS and routes (gateway is a special route)
  * Service layer: set global DNS
  * Support for Windows 2012 R2, Windows 2016 and Windows 2019

Example:

```powershell

$networkConfigB64 = "eyJzZXJ2aWNlcyI6IFt7InR5cGUiOiAiZG5zIiwgImFkZHJlc3MiOiAiOC44LjguOCJ9XSwgIm5ldHdvcmtzIjogW3sibmV0d29ya19pZCI6ICI4MWQ1MjkyZS03OTBhLTRiMWEtOGRmZi1mNmRmZmVjMDY2ZmIiLCAidHlwZSI6ICJpcHY0IiwgInNlcnZpY2VzIjogW3sidHlwZSI6ICJkbnMiLCAiYWRkcmVzcyI6ICI4LjguOC44In1dLCAibmV0bWFzayI6ICIyNTUuMjU1LjI1NS4wIiwgImxpbmsiOiAidGFwODU0NDc3YzgtYmIiLCAicm91dGVzIjogW3sibmV0bWFzayI6ICIwLjAuMC4wIiwgIm5ldHdvcmsiOiAiMC4wLjAuMCIsICJnYXRld2F5IjogIjE5Mi4xNjguNS4xIn1dLCAiaXBfYWRkcmVzcyI6ICIxOTIuMTY4LjUuMTciLCAiaWQiOiAibmV0d29yazAifV0sICJsaW5rcyI6IFt7ImV0aGVybmV0X21hY19hZGRyZXNzIjogIjAwOjE1OjVEOjY0Ojk4OjYwIiwgIm10dSI6IDE0NTAsICJ0eXBlIjogIm92cyIsICJpZCI6ICJ0YXA4NTQ0NzdjOC1iYiIsICJ2aWZfaWQiOiAiODU0NDc3YzgtYmJmZS00OGY1LTg5NGQtODBmMGNkZmNjYTYwIn1dfQ=="

powershell src/apply-networking.ps1 $networkConfigB64

#7/13/2020 1:16:22 PM - Setting MTU 1450 for link tap854477c8-bb
#7/13/2020 1:16:22 PM - Configuring network for link tap854477c8-bb
#7/13/2020 1:16:22 PM - Removing route 0.0.0.0/0/192.168.5.1
#7/13/2020 1:16:22 PM - Adding route 0.0.0.0/0/192.168.5.1
#7/13/2020 1:16:22 PM - Setting DNSses 8.8.8.8 for interfaces aliases tap854477c8-bb
#7/13/2020 1:16:22 PM - Setting DNSses 8.8.8.8 for interfaces aliases *

```
# Linux Python config setter

The script [src/apply-networking-linux.py](src/apply-networking-linux.py) takes a base64 json OpenStack network config and applies it on the Linux machine.

Capabilities:

  * Sets MTU, IP address and routes using "ip" command
  * Configures Debian interfaces file /etc/network/interfaces for Ubuntu 14.04 and Debian 8 Jessie
  * Configures Debian interfaces file /etc/network/interfaces.d/50-cloud-config.cfg for Ubuntu 16.04, Debian 9 Stretch, Debian 10 Buster
  * Configures netplan config file /etc/netplan/50-cloud-config.yaml for Ubuntu 18.04
  * Configures syconfig network config files /etc/sysconfig/network-scripts/ifcfg-%s for CentOS 6, 7 and 8
  * Supported Python version: vanilla Python2 and Python3
  * Supported distros: Ubuntu 14.04, Ubuntu 16.04, Ubuntu 18.04, Debian 8 Jessie, Debian 9 Stretch, Debian 10 Buster, CentOS (6, 7, 8)
  * TODO: Add support for DNS set on CentOS. Add support for extra routes or global dns.
  * Notes:
    * On CentOS 8, there is no Python in path, use /usr/libexec/platform-python
    * On Debians, DNS is not properly set by cloud-init
    * On Debians, etc/network/interfaces file sets first 3 interfaces to dhcp, which slows booting or network resets

Example:

```bash

networkConfigB64="eyJzZXJ2aWNlcyI6IFt7InR5cGUiOiAiZG5zIiwgImFkZHJlc3MiOiAiOC44LjguOCJ9XSwgIm5ldHdvcmtzIjogW3sibmV0d29ya19pZCI6ICI4MWQ1MjkyZS03OTBhLTRiMWEtOGRmZi1mNmRmZmVjMDY2ZmIiLCAidHlwZSI6ICJpcHY0IiwgInNlcnZpY2VzIjogW3sidHlwZSI6ICJkbnMiLCAiYWRkcmVzcyI6ICI4LjguOC44In1dLCAibmV0bWFzayI6ICIyNTUuMjU1LjI1NS4wIiwgImxpbmsiOiAidGFwODU0NDc3YzgtYmIiLCAicm91dGVzIjogW3sibmV0bWFzayI6ICIwLjAuMC4wIiwgIm5ldHdvcmsiOiAiMC4wLjAuMCIsICJnYXRld2F5IjogIjE5Mi4xNjguNS4xIn1dLCAiaXBfYWRkcmVzcyI6ICIxOTIuMTY4LjUuMTciLCAiaWQiOiAibmV0d29yazAifV0sICJsaW5rcyI6IFt7ImV0aGVybmV0X21hY19hZGRyZXNzIjogIjAwOjE1OjVEOjY0Ojk4OjYwIiwgIm10dSI6IDE0NTAsICJ0eXBlIjogIm92cyIsICJpZCI6ICJ0YXA4NTQ0NzdjOC1iYiIsICJ2aWZfaWQiOiAiODU0NDc3YzgtYmJmZS00OGY1LTg5NGQtODBmMGNkZmNjYTYwIn1dfQ=="

python src/apply-networking-linux.py $networkConfigB64

#Running on Ubuntu 14.04 trusty
#Processing network network0
#Processing network network1
#Writing config to /etc/network/interfaces
#Apply config for link eth0
#Apply network network0 for eth0
#Apply network network1 for eth0

```

# How to configure Qemu Guest Agents

## Common workflow for all operating systems

  - Install Qemu Guest Agent as a service
  - Configure Qemu Guest Agent to be able to execute commands
  - Configure the operating system to allow Qemu Guest Agent to execute commands
  - Download the scripts that implement the functionality to the required path

## For Windows Server (2012 R2, 2016, 2019)

```powershell
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$wc = New-Object System.Net.WebClient

# Download Fedora VirtIO ISO
$isoPath = "C:\fedora-virtio.iso"
$wc.downloadFile("https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.187-1/virtio-win-0.1.187.iso", $isoPath)

# mount iso and install agent
$mountResult = Mount-DiskImage $isoPath -PassThru
Get-PsDrive | Out-Null
$mountPoint = ($mountResult | Get-Volume).DriveLetter

Start-Process -FilePath "C:\Windows\System32\msiexec.exe" `
    -ArgumentList @("/i", "${mountPoint}:\guest-agent\qemu-ga-x86_64.msi", "/qn") `
    -NoNewWindow -Wait

Get-Service "qemu*" # there should be two services, one running

$scriptRoot = "C:\scripts"
mkdir $scriptRoot -Force
$scriptPath = "$scriptRoot\apply-network-config.ps1"

# Download PowerShell script that applies the network config
$wc.downloadFile("https://raw.githubusercontent.com/ader1990/openstack-networkd/master/src/apply-networking.ps1", $scriptPath)

# Set access rules only for LocalSystem and Administrators
$acl = Get-Acl $scriptPath
$acl.SetOwner([System.Security.Principal.NTAccount]"BUILTIN\Administrators")
$acl.SetGroup([System.Security.Principal.NTAccount]"BUILTIN\Administrators")
$acl.SetAccessRuleProtection($true, $true)

foreach ($rule in $acl.Access) {
    $acl.RemoveAccessRule($rule)
}

$localSystemAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "Allow")
$administratorsAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "Allow")
$acl.AddAccessRule($localSystemAccessRule)
$acl.AddAccessRule($administratorsAccessRule)

$acl | Set-Acl $scriptPath

````


## Install Qemu Guest Agent on Ubuntu 16.04, Ubuntu 18.04, Ubuntu 20.04, Debian 9, Debian 10

```bash
#!/bin/bash
apt update && apt install qemu-guest-agent -y

# Needed for Debian 9, Debian 10, Ubuntu 20.04
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent
```

## Install Qemu Guest Agent on Debian 8

```bash
#!/bin/bash

# Install the legacy version for daemon installation
apt update && apt install qemu-guest-agent -y

# !Make sure you blacklist the qemu-guest-agent from future updates

# Build the required qemu guest agent from source >= 2.5
  apt-get install -y git gcc libaio-dev libbluetooth-dev libbrlapi-dev \
    libbz2-dev zlib1g-dev build-essential pkg-config libglib2.0-dev \
    binutils-dev libboost-all-dev autoconf libtool libssl-dev libpixman-1-dev libpython-dev

git clone git://git.qemu-project.org/qemu.git
cd qemu
git checkout v2.5.1.1
./configure --disable-system --enable-guest-agent --prefix=/
make qemu-ga -j16
systemctl stop qemu-guest-agent
cp qemu-ga /usr/sbin/qemu-ga
systemctl start qemu-guest-agent
```

##  Install Qemu Guest Agent on CentOS 7 and CentOS 8

```bash
#!/bin/bash
yum install qemu-guest-agent -y
systemctl start qemu-guest-agent
systemctl enable qemu-guest-agent

# Update in /etc/sysconfig/qemu-ga or remove the line completely
# BLACKLIST_RPC=
sed -i '/^BLACKLIST_RPC=/d' /etc/sysconfig/qemu-ga

systemctl restart qemu-guest-agent
```

Because of selinux policies, the scripts will not run unless you:

  - disable selinux
  - disable selinux for qemu-ga -> `semanage permissive -a virt_qemu_ga_t`
  - apply the required policies for qemu-ga (Recommended)

```bash
# To apply the required policy (no need to disable selinux)
yum install -y selinux-policy-devel

# For Centos 7
curl "https://raw.githubusercontent.com/ader1990/openstack-networkd/master/selinux/qemu-ga-centos7.te" -o /tmp/qemu-ga.te

# For Centos 8
curl "https://raw.githubusercontent.com/ader1990/openstack-networkd/master/selinux/qemu-ga-centos8.te" -o /tmp/qemu-ga.te

# Build and install the policy
pushd /tmp
make -f /usr/share/selinux/devel/Makefile qemu-ga.pp
semodule -i qemu-ga.pp

# How to create the policy from scratch (advanced)

# Disable noaudit rules
semodule -DB

# Set permissive for qemu-ga only
semanage permissive -a virt_qemu_ga_t

# From Horizon, run all the desired operations (add, update or remove IP)
# Make sure all the operations finish successfully

# Generate policy
grep virt_qemu_ga_t /var/log/audit/audit.log | audit2allow -a -M qemu-ga

# Now you will have the binary qemu-ga.pp file and the declarative qemu-ga.te file
# If you have the .te file, you need to compile it into a .pp file to apply with semodule -i

```


## Download required executables for Linux

```
#!/bin/bash

mkdir /scripts
args="-o"
download_cmd=$(which curl)

if [ $? -ne 0 ]; then
    download_cmd=$(which wget)
    args="-O"
fi
$download_cmd https://raw.githubusercontent.com/ader1990/openstack-networkd/master/src/apply-networking-linux.py "${args}" /scripts/apply-networking-linux.py
$download_cmd https://raw.githubusercontent.com/ader1990/openstack-networkd/master/src/apply-networking-linux "${args}" /scripts/apply-network-config
chmod a+x /scripts/apply-network-config
```