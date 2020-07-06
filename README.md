# openstack-networkd
Agent for enforcing OpenStack network changes on the VMs.

For Linux:
  * create a service called openstack-networkd that starts src/openstack-networkd.sh
  * create udev rules that fire on each net subsystem device add or remove to start the service
  * src/openstack-networkd.sh starts a python script src/cloud_init_apply_net.py
  * cloud_init_apply_net.py uses cloudinit Python package to execute only the relevant networking part
  * cloud_init_apply_net.py restarts the networking service (be it netplan, NetworkManager, networking)

Currently supports Ubuntu 16.04 or higher with netplan or networking service installed.

Support for Ubuntu 14.04, Debian 7->10, CentOS 6->8 will be added in the future.

The udev -> service -> bash wrapper -> Python wrapper has been chosen because:

  * udev events start only on device attach or detach (no overhead in polling every X seconds)
  * Because udev runs a command in a peculiar execution env (no profile, no home, no binaries in path),
    it is simpler to start a service which will run under user root (and this it has binaries in path, etc.)
    cloud-init has hardcoded wrapped executables with no full path (ex: netplan, systemctl).
    The service also helps us with running just one instance of the configuration setter.
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

# Dependencies for Linux:

  * systemd
  * cloud-init

# Userdata example for Ubuntu 18.04

```bash
#!/bin/bash

set -e

git clone https://github.com/ader1990/openstack-networkd
bash openstack-networkd/scripts/install_service.sh

```
