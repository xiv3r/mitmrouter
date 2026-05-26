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

LAN_ENABLED="${LAN_ENABLED:-1}"
WIFI_ENABLED="${WIFI_ENABLED:-1}"
if [ "$LAN_ENABLED" != "1" ] && [ "$WIFI_ENABLED" != "1" ]; then
    echo "both LAN_ENABLED and WIFI_ENABLED are 0 in $CONFIG_FILE; at least one must be 1"
    exit 1
fi

echo "== stop router services"
sudo pkill -x wpa_supplicant || true
sudo pkill -x dnsmasq || true

if [ "$ACTION" != "refresh" ]; then
    echo "== reset all network interfaces"
    if [ "$LAN_ENABLED" = "1" ]; then
        sudo ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
        sudo ip link set dev "$LAN_IFACE" down 2>/dev/null || true
    fi
    sudo ip addr flush dev "$BR_IFACE" 2>/dev/null || true
    sudo ip link set dev "$BR_IFACE" down 2>/dev/null || true
    if [ "$WIFI_ENABLED" = "1" ]; then
        sudo ip addr flush dev "$WIFI_IFACE" 2>/dev/null || true
        sudo ip link set dev "$WIFI_IFACE" down 2>/dev/null || true
    fi
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

        if [ "$WIFI_ENABLED" = "1" ]; then
            echo "== create hostapd config file"
            cat > "$HOSTAPD_CONF" <<EOF
interface=${WIFI_IFACE}
bridge=${BR_IFACE}
ssid=${WIFI_SSID}
country_code=${WIFI_COUNTRY}
hw_mode=${WIFI_HW_MODE}
channel=${WIFI_CHANNEL}
wpa=${WIFI_WPA}
wpa_passphrase=${WIFI_PASSWORD}
wpa_key_mgmt=${WIFI_WPA_KEY_MGMT}
wpa_pairwise=${WIFI_WPA_PAIRWISE}
ieee80211n=${WIFI_IEEE80211N}
ieee80211w=${WIFI_IEEE80211W}
EOF
        fi

        if [ "$ACTION" != "refresh" ]; then
            echo "== bring up interfaces and bridge"
            if [ "$WIFI_ENABLED" = "1" ]; then
                sudo ip link set dev "$WIFI_IFACE" up
            fi
            sudo ip link set dev "$WAN_IFACE" up
            sudo ip link add name "$BR_IFACE" type bridge
            if [ "$LAN_ENABLED" = "1" ]; then
                sudo ip link set dev "$LAN_IFACE" up
                sudo ip link set dev "$LAN_IFACE" master "$BR_IFACE"
            fi
            sudo ip link set dev "$BR_IFACE" up
        fi

        echo "== ensure bridge netfilter module is loaded"
        sudo modprobe br_netfilter
        sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
        sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1

        echo "== setup nftables ruleset"
        sudo nft delete table inet mitmrouter 2>/dev/null || true
        sudo nft -f - <<EOF
table inet mitmrouter {
    chain forward {
        type filter hook forward priority filter; policy accept;
        ct state related,established accept
        iifname "$BR_IFACE" oifname "$WAN_IFACE" accept
    }
    chain prerouting {
        type nat hook prerouting priority dstnat;
        # optional mitm rules
        # iifname "$BR_IFACE" ip daddr 1.2.3.4 tcp dport 443 redirect to :8081
    }
    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "$WAN_IFACE" masquerade
    }
}
EOF

        echo "== setting static IP on bridge interface"
        sudo ip addr add "$LAN_IP/$LAN_PREFIX" dev "$BR_IFACE"

        echo "== starting dnsmasq"
        sudo dnsmasq -C "$DNSMASQ_CONF"

        if [ "$WIFI_ENABLED" = "1" ]; then
            echo "== starting hostapd"
            sudo hostapd "$HOSTAPD_CONF"
        fi
        ;;
esac
