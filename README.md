# To create a VPN Container on PVE as an Exit Node on Tailscale


## Overview
The idea is to connect a device to tailscale via an exit node, and the traffic is redirected through the VPN's ip.

### Additional Info
Some VPN providers, such as PureVPN, have rotating keys in their config. This means that if your container disconnects and is unable to connect via the `wireguard` config for a period of time, the current config must be renewed by obtaining a new config from the provider. This should probably be the first step in the bug-fixing steps if you encounter any issues.

---

## Steps

1. Create a Debian (or any Linux) container with either **Privilege** or **Unprivilege**. If **Unpivilege** was selected, move to step 2; otherwise, make sure nesting, tunneling, and keyctl is enabled, then move to step 4. Make note of the container id.
2. After the container is successfully made, run `nano /etc/pve/lxc/{container id}.conf`, where `{container id}` is the id noted in step 1. Add these lines to the bottom:
    ```bash
    features: nesting=1,keyctl=1
    lxc.cgroup2.devices.allow: c 10:200 rwm
    lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
    ```

3. Reboot the container.
4. Update the packages, and install the required packages:
    ```bash
    apt update
    apt-get install -y wireguard-tools iptables conntrack
    curl -fsSL https://tailscale.com/install.sh | sh
    ```
5. Enable IP forwarding. From [Tailscale's guide](https://tailscale.com/docs/features/subnet-routers#enable-ip-forwarding):
    If your Linux system has a /etc/sysctl.d directory, use:
  
    ```bash
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
    ```
  
    Otherwise, use:
    
    ```bash
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p /etc/sysctl.conf
    ```

6. Set up the VPN config:
    Obtain a `wireguard` config from your VPN provider. This should be something like `us1.conf`.

7. Either:

   **i)** download `setup.sh` in this repo and run directly:

     ```bash
     bash ./setup.sh {path_to_wg.conf}
     ```

   **ii)** run the script without downloading:

     ```bash
     sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Twigums/tailscale-vpn-setup/refs/heads/main/setup.sh) setup.sh {path_to_wg.conf}"`
     ```
  
    These files will be written by running this command:
    - env secrets: /etc/tsvpn/tsvpn.env
    - gateway script: /usr/local/sbin/tsvpn.sh
    - systemd service: /etc/systemd/system/tsvpn.service

    (Change `{path_to_wg.conf}` to where you saved the `wireguard` config in step 6.)
