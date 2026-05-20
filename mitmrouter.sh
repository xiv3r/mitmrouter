#!/bin/bash

DNSMASQ_CONF="tmp_dnsmasq.conf"
HOSTAPD_CONF="tmp_hostapd.conf"

if [ "$1" != "up" ] && [ "$1" != "down" ] && [ "$1" != "refresh" ] || [ $# != 1 ]; then
    echo "missing required argument"
    echo "$0: <up/down/refresh>"
    exit
fi

SCRIPT_RELATIVE_DIR=$(dirname "${BASH_SOURCE[0]}")
cd $SCRIPT_RELATIVE_DIR

CONFIG_FILE="mitmrouter.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "${CONFIG_FILE}.example" ]; then
        cp "${CONFIG_FILE}.example" "$CONFIG_FILE"
        echo "created $CONFIG_FILE from example. edit it and re-run."
        exit 1
    fi
    echo "missing $CONFIG_FILE and ${CONFIG_FILE}.example"
    exit 1
fi
source "$CONFIG_FILE"

echo "== stop router services"
sudo killall wpa_supplicant
sudo killall dnsmasq

if [ $1 != "refresh" ]; then
    echo "== reset all network interfaces"
    sudo ifconfig $LAN_IFACE 0.0.0.0
    sudo ifconfig $LAN_IFACE down
    sudo ifconfig $BR_IFACE 0.0.0.0
    sudo ifconfig $BR_IFACE down
    sudo ifconfig $WIFI_IFACE 0.0.0.0
    sudo ifconfig $WIFI_IFACE down
    sudo brctl delbr $BR_IFACE
fi

if [ $1 = "up" ] || [ $1 = "refresh" ]; then

    echo "== create dnsmasq config file"
    echo "interface=${BR_IFACE}" > $DNSMASQ_CONF
    echo "dhcp-range=${LAN_DHCP_START},${LAN_DHCP_END},${LAN_SUBNET},12h" >> $DNSMASQ_CONF
    echo "dhcp-option=6,${LAN_DNS_SERVER}" >> $DNSMASQ_CONF
    
    echo "create hostapd config file"
    echo "interface=${WIFI_IFACE}" > $HOSTAPD_CONF
    echo "bridge=${BR_IFACE}" >> $HOSTAPD_CONF
    echo "ssid=${WIFI_SSID}" >> $HOSTAPD_CONF
    echo "country_code=US" >> $HOSTAPD_CONF
    echo "hw_mode=g" >> $HOSTAPD_CONF
    echo "channel=11" >> $HOSTAPD_CONF
    echo "wpa=2" >> $HOSTAPD_CONF
    echo "wpa_passphrase=${WIFI_PASSWORD}" >> $HOSTAPD_CONF
    echo "wpa_key_mgmt=WPA-PSK" >> $HOSTAPD_CONF
    echo "wpa_pairwise=CCMP" >> $HOSTAPD_CONF
    echo "ieee80211n=1" >> $HOSTAPD_CONF
    #echo "ieee80211w=1" >> $HOSTAPD_CONF # PMF
    
    if [ $1 != "refresh" ]; then
        echo "== bring up interfaces and bridge"
        sudo ifconfig $WIFI_IFACE up
        sudo ifconfig $WAN_IFACE up
        sudo ifconfig $LAN_IFACE up
        sudo brctl addbr $BR_IFACE
        sudo brctl addif $BR_IFACE $LAN_IFACE
        sudo ifconfig $BR_IFACE up
    fi

    echo "== ensure bridge netfilter module is loaded"
    sudo modprobe br_netfilter
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
    sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1

    echo "== setup iptables"
    sudo iptables --flush
    sudo iptables -t nat --flush
    sudo iptables -t nat -A POSTROUTING -o $WAN_IFACE -j MASQUERADE
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A FORWARD -i $BR_IFACE -o $WAN_IFACE -j ACCEPT
    # optional mitm rules
    #sudo iptables -t nat -A PREROUTING -i $BR_IFACE -p tcp -d 1.2.3.4 --dport 443 -j REDIRECT --to-ports 8081
    
    
    echo "== setting static IP on bridge interface"
    sudo ifconfig $BR_IFACE inet $LAN_IP netmask $LAN_SUBNET
    
    echo "== starting dnsmasq"
    sudo dnsmasq -C $DNSMASQ_CONF
    
    echo "== starting hostapd"
    sudo hostapd $HOSTAPD_CONF
fi

