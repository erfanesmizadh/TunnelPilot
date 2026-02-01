# TunnelPilot

**TunnelPilot** is a professional **Bash script** to manage **GRE Tunnels** (IPv4 + IPv6 private) and **iptables NAT tunnels**.  
Provides an interactive menu for easy tunnel creation, deletion, MTU adjustments, and TCP BBR/BBR2 configuration.

---

## Features

- Create and rebuild **GRE Tunnel** between servers
- Support **IPv4 Private** and **IPv6 ULA**
- MTU configuration for GRE Tunnel
- Ping test after tunnel creation (IPv4 + IPv6)
- Enable **TCP BBR / BBR2 / Cubic**
- Create **iptables NAT Tunnel** (TCP/UDP)
- Remove GRE Tunnel or NAT Tunnel safely
- Single script for both Iran and overseas servers
- Logs saved at `/var/log/tunnelpilot.log`

---

## Menu Options

1. **Create / Rebuild GRE Tunnel**  
   - Prompts for peer server public IP, private IPv4/IPv6, and MTU  
   - Performs ping test after setup

2. **Remove GRE Tunnel**  
   - Removes GRE tunnel and assigned IPs

3. **Enable TCP BBR / BBR2 / Cubic**  
   - Select TCP congestion algorithm  
   - Applies permanently via sysctl

4. **Create IP-based NAT Tunnel (iptables)**  
   - Prompts for remote IP, local port, and remote port  
   - Creates NAT tunnel using iptables

5. **Remove IP-based NAT Tunnel**  
   - Clears iptables NAT rules

0. **Exit**  
   - Quit script

---

## Usage

```bash
wget https://raw.githubusercontent.com/erfanesmizadh/gre-smart-manager/main/tunnelpilot.sh -O tunnelpilot.sh
chmod +x tunnelpilot.sh
sudo ./tunnelpilot.sh
