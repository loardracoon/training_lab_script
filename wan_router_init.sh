#!/bin/bash

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root." 
   exit 1
fi

### INTERFACE CONFIGURATION ###

# Define interfaces (adjust according to your environment)
IF_INTERNET="ens18"
IF_WAN01="ens19"
IF_WAN02="ens20"

echo "Configuring network interfaces..."
# Configure static IPs persistently using Netplan
cat <<EOF > /etc/netplan/99-custom-network.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $IF_WAN01:
      dhcp4: no
      addresses: [10.1.1.1/24]
    $IF_WAN02:
      dhcp4: no
      addresses: [10.2.2.1/24]
EOF

# Apply Netplan configuration
netplan apply


### ENABLE ROUTING ###
echo "Enabling routing..."
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf


### CONFIGURE NAT AND FIREWALL ###
echo "Configuring NAT and firewall..."

# Install package for persistence
apt-get update
apt-get install -y iptables-persistent
apt-get install -y iputils-ping
apt-get install -y traceroute
apt-get install -y tcpdump
apt-get install python3
apt-get install python3-rich
apt-get install python3-questionary

# Clear old rules
iptables -t nat -F
iptables -F

# NAT for WAN01 -> INTERNET
iptables -t nat -A POSTROUTING -s 10.1.1.0/24 -o $IF_INTERNET -j MASQUERADE

# NAT for WAN02 -> INTERNET
iptables -t nat -A POSTROUTING -s 10.2.2.0/24 -o $IF_INTERNET -j MASQUERADE

# Allow forwarding traffic to the Internet
iptables -A FORWARD -i $IF_WAN01 -o $IF_INTERNET -j ACCEPT
iptables -A FORWARD -i $IF_WAN02 -o $IF_INTERNET -j ACCEPT
iptables -A FORWARD -i $IF_INTERNET -o $IF_WAN01 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i $IF_INTERNET -o $IF_WAN02 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Allow traffic between WAN01 and WAN02
iptables -A FORWARD -i $IF_WAN01 -o $IF_WAN02 -j ACCEPT
iptables -A FORWARD -i $IF_WAN02 -o $IF_WAN01 -j ACCEPT


# Save iptables rules
netfilter-persistent save


### CONFIGURE NETEM (Latency, Jitter and Loss) ###
echo "Configuring netem (latency, jitter, loss)..."

# Clear previous configurations if they exist
tc qdisc del dev $IF_WAN01 root 2>/dev/null
tc qdisc del dev $IF_WAN02 root 2>/dev/null

# Examples (adjust as needed):
# WAN01: 100ms latency and 1% packet loss
tc qdisc add dev $IF_WAN01 root netem delay 100ms loss 1%

# WAN02: 50ms latency with 10ms jitter (normal distribution)
tc qdisc add dev $IF_WAN02 root netem delay 50ms 10ms distribution normal


### CONFIGURE DHCP SERVER ON WAN01 ###
echo "Installing and configuring DHCP server..."

apt-get install -y isc-dhcp-server

# Configure DHCP to listen on WAN02
sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$IF_WAN01\"/" /etc/default/isc-dhcp-server

# DHCP configuration file
cat <<EOF > /etc/dhcp/dhcpd.conf
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 10.1.1.0 netmask 255.255.255.0 {
    range 10.1.1.100 10.1.1.200;
    option routers 10.1.1.1;
    option subnet-mask 255.255.255.0;
    option domain-name-servers 8.8.8.8, 1.1.1.1;
}
EOF

# Restart and enable DHCP on boot
systemctl restart isc-dhcp-server
systemctl enable isc-dhcp-server


### COMPLETION ###
echo "#########################################"
echo "# Configuration completed successfully. #"
echo "#########################################"
