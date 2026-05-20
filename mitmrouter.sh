#!/bin/bash

set -euo pipefail

DNSMASQ_CONF="tmp_dnsmasq.conf"
HOSTAPD_CONF="tmp_hostapd.conf"

if [ "$#" -ne 1 ]; then
    echo "missing required argument"
    echo "usage: $0 <up|down|refresh>"
    exit 1
fi

ACTION="$1"
case "$ACTION" in
    up|down|refresh) ;;
    *)
        echo "unknown action: $ACTION"
        echo "usage: $0 <up|down|refresh>"
        exit 1
        ;;
esac

SCRIPT_RELATIVE_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "$SCRIPT_RELATIVE_DIR"

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
sudo pkill -x wpa_supplicant || true
sudo pkill -x dnsmasq || true

if [ "$ACTION" != "refresh" ]; then
    echo "== reset all network interfaces"
    sudo ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
    sudo ip link set dev "$LAN_IFACE" down 2>/dev/null || true
    sudo ip addr flush dev "$BR_IFACE" 2>/dev/null || true
    sudo ip link set dev "$BR_IFACE" down 2>/dev/null || true
    sudo ip addr flush dev "$WIFI_IFACE" 2>/dev/null || true
    sudo ip link set dev "$WIFI_IFACE" down 2>/dev/null || true
    sudo ip link delete "$BR_IFACE" type bridge 2>/dev/null || true
fi

case "$ACTION" in
    up|refresh)
        echo "== create dnsmasq config file"
        cat > "$DNSMASQ_CONF" <<EOF
interface=${BR_IFACE}
dhcp-range=${LAN_DHCP_START},${LAN_DHCP_END},${LAN_SUBNET},12h
dhcp-option=6,${LAN_DNS_SERVER}
EOF

        echo "== create hostapd config file"
        cat > "$HOSTAPD_CONF" <<EOF
interface=${WIFI_IFACE}
bridge=${BR_IFACE}
ssid=${WIFI_SSID}
country_code=US
hw_mode=g
channel=11
wpa=2
wpa_passphrase=${WIFI_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
ieee80211n=1
#ieee80211w=1 # PMF
EOF

        if [ "$ACTION" != "refresh" ]; then
            echo "== bring up interfaces and bridge"
            sudo ip link set dev "$WIFI_IFACE" up
            sudo ip link set dev "$WAN_IFACE" up
            sudo ip link set dev "$LAN_IFACE" up
            sudo ip link add name "$BR_IFACE" type bridge
            sudo ip link set dev "$LAN_IFACE" master "$BR_IFACE"
            sudo ip link set dev "$BR_IFACE" up
        fi

        echo "== ensure bridge netfilter module is loaded"
        sudo modprobe br_netfilter
        sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
        sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1

        echo "== setup iptables"
        sudo iptables --flush
        sudo iptables -t nat --flush
        sudo iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
        sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        sudo iptables -A FORWARD -i "$BR_IFACE" -o "$WAN_IFACE" -j ACCEPT
        # optional mitm rules
        #sudo iptables -t nat -A PREROUTING -i "$BR_IFACE" -p tcp -d 1.2.3.4 --dport 443 -j REDIRECT --to-ports 8081

        echo "== setting static IP on bridge interface"
        sudo ip addr add "$LAN_IP/$LAN_PREFIX" dev "$BR_IFACE"

        echo "== starting dnsmasq"
        sudo dnsmasq -C "$DNSMASQ_CONF"

        echo "== starting hostapd"
        sudo hostapd "$HOSTAPD_CONF"
        ;;
esac
