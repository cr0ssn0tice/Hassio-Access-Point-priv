#!/usr/bin/with-contenv bashio

set -euo pipefail

HOSTAPD_CONF="/tmp/hostapd.conf"
DNSMASQ_CONF="/tmp/dnsmasq.conf"
HOSTAPD_ALLOW="/tmp/hostapd.allow"
HOSTAPD_DENY="/tmp/hostapd.deny"

HOSTAPD_PID=""
DNSMASQ_PID=""

term_handler() {
    logger "Stopping Hass.io Access Point" 0

    if [ -n "${HOSTAPD_PID}" ] && kill -0 "${HOSTAPD_PID}" 2>/dev/null; then
        kill "${HOSTAPD_PID}" 2>/dev/null || true
        wait "${HOSTAPD_PID}" 2>/dev/null || true
    fi

    if [ -n "${DNSMASQ_PID}" ] && kill -0 "${DNSMASQ_PID}" 2>/dev/null; then
        kill "${DNSMASQ_PID}" 2>/dev/null || true
        wait "${DNSMASQ_PID}" 2>/dev/null || true
    fi

    iptables_cleanup || true

    ip link set "${INTERFACE}" down 2>/dev/null || true
    ip addr flush dev "${INTERFACE}" 2>/dev/null || true

    exit 0
}

logger() {
    local msg="${1:-}"
    local level="${2:-0}"
    if [ "${DEBUG}" -ge "${level}" ]; then
        echo "${msg}"
    fi
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

get_dns_servers() {
    if [ -n "${CLIENT_DNS_OVERRIDE}" ]; then
        local dns_string="dhcp-option=6"
        local dns
        for dns in ${CLIENT_DNS_OVERRIDE}; do
            dns_string="${dns_string},${dns}"
        done
        echo "${dns_string}"
        return 0
    fi

    if have_command nmcli; then
        local dns_string="dhcp-option=6"
        local found=0
        while read -r dns; do
            [ -z "${dns}" ] && continue
            dns_string="${dns_string},${dns}"
            found=1
        done < <(nmcli device show 2>/dev/null | awk '/IP4\.DNS/ {print $2}')

        if [ "${found}" -eq 1 ]; then
            echo "${dns_string}"
            return 0
        fi
    fi

    if [ -f /etc/resolv.conf ]; then
        local dns_string="dhcp-option=6"
        local found=0
        while read -r dns; do
            [ -z "${dns}" ] && continue
            dns_string="${dns_string},${dns}"
            found=1
        done < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf)

        if [ "${found}" -eq 1 ]; then
            echo "${dns_string}"
            return 0
        fi
    fi

    return 1
}

is_masquerading_enabled() {
    iptables-nft -t nat -C POSTROUTING -o "${DEFAULT_ROUTE_INTERFACE}" -j MASQUERADE \
        -m comment --comment "ap-addon-inet" 2>/dev/null
}

is_forwarding_enabled() {
    iptables-nft -C FORWARD -i "${INTERFACE}" -o "${DEFAULT_ROUTE_INTERFACE}" -j ACCEPT \
        -m comment --comment "ap-addon-inet" 2>/dev/null
}

iptables_setup() {
    if bashio::config.true "client_internet_access"; then
        if ! is_masquerading_enabled; then
            logger "Adding NAT masquerade on ${DEFAULT_ROUTE_INTERFACE}" 1
            iptables-nft -t nat -A POSTROUTING -o "${DEFAULT_ROUTE_INTERFACE}" -j MASQUERADE \
                -m comment --comment "ap-addon-inet"
        fi

        if ! is_forwarding_enabled; then
            logger "Adding forwarding rules between ${INTERFACE} and ${DEFAULT_ROUTE_INTERFACE}" 1
            iptables-nft -A FORWARD -i "${INTERFACE}" -o "${DEFAULT_ROUTE_INTERFACE}" -j ACCEPT \
                -m comment --comment "ap-addon-inet"
            iptables-nft -A FORWARD -i "${DEFAULT_ROUTE_INTERFACE}" -o "${INTERFACE}" \
                -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
                -m comment --comment "ap-addon-inet"
        fi
    fi
}

iptables_cleanup() {
    if is_masquerading_enabled; then
        iptables-nft -t nat -D POSTROUTING -o "${DEFAULT_ROUTE_INTERFACE}" -j MASQUERADE \
            -m comment --comment "ap-addon-inet" || true
    fi

    if is_forwarding_enabled; then
        iptables-nft -D FORWARD -i "${INTERFACE}" -o "${DEFAULT_ROUTE_INTERFACE}" -j ACCEPT \
            -m comment --comment "ap-addon-inet" || true
        iptables-nft -D FORWARD -i "${DEFAULT_ROUTE_INTERFACE}" -o "${INTERFACE}" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
            -m comment --comment "ap-addon-inet" || true
    fi
}

trap 'term_handler' SIGTERM SIGINT

SSID="$(bashio::config 'ssid')"
WPA_PASSPHRASE="$(bashio::config 'wpa_passphrase')"
CHANNEL="$(bashio::config 'channel')"
ADDRESS="$(bashio::config 'address')"
NETMASK="$(bashio::config 'netmask')"
BROADCAST="$(bashio::config 'broadcast')"
INTERFACE="$(bashio::config 'interface')"
DHCP_START_ADDR="$(bashio::config 'dhcp_start_addr')"
DHCP_END_ADDR="$(bashio::config 'dhcp_end_addr')"
ALLOW_MAC_ADDRESSES="$(bashio::config 'allow_mac_addresses')"
DENY_MAC_ADDRESSES="$(bashio::config 'deny_mac_addresses')"
DEBUG="$(bashio::config 'debug')"
HT_CAPAB="$(bashio::config 'ht_capab' '[HT40][SHORT-GI-20][DSSS_CCK-40]')"
HOSTAPD_CONFIG_OVERRIDE="$(bashio::config 'hostapd_config_override')"
CLIENT_DNS_OVERRIDE="$(bashio::config 'client_dns_override')"
DNSMASQ_CONFIG_OVERRIDE="$(bashio::config 'dnsmasq_config_override')"

HIDE_SSID=0
if bashio::config.true "hide_ssid"; then
    HIDE_SSID=1
fi

DEFAULT_ROUTE_INTERFACE="$(ip route show default | awk '/^default/ { print $5; exit }')"

echo "Starting Hass.io Access Point Addon"

required_vars=(ssid wpa_passphrase channel address netmask broadcast interface)
for required_var in "${required_vars[@]}"; do
    bashio::config.require "${required_var}" "An AP cannot be created without this information"
done

if [ "${#WPA_PASSPHRASE}" -lt 8 ]; then
    bashio::exit.nok "The WPA password must be at least 8 characters long!"
fi

if ! ip link show "${INTERFACE}" >/dev/null 2>&1; then
    bashio::exit.nok "Interface ${INTERFACE} not found. Check your selected WiFi interface."
fi

rm -f "${HOSTAPD_CONF}" "${DNSMASQ_CONF}" "${HOSTAPD_ALLOW}" "${HOSTAPD_DENY}"
touch "${HOSTAPD_CONF}"

logger "# Preparing interface ${INTERFACE}" 1

rfkill unblock all 2>/dev/null || true

if have_command nmcli; then
    logger "Run command: nmcli dev set ${INTERFACE} managed no" 1
    nmcli dev set "${INTERFACE}" managed no || true
else
    logger "nmcli not found, skipping NetworkManager handling" 1
fi

logger "Run command: ip link set ${INTERFACE} down" 1
ip link set "${INTERFACE}" down || true

logger "Run command: ip addr flush dev ${INTERFACE}" 1
ip addr flush dev "${INTERFACE}" || true

logger "Run command: ip addr add ${ADDRESS} dev ${INTERFACE}" 1
ip addr add "${ADDRESS}" broadcast "${BROADCAST}" dev "${INTERFACE}" || true

logger "Run command: ip link set ${INTERFACE} up" 1
ip link set "${INTERFACE}" up

logger "# Building hostapd config" 1
cat > "${HOSTAPD_CONF}" <<EOF
interface=${INTERFACE}
driver=nl80211
ssid=${SSID}
wpa_passphrase=${WPA_PASSPHRASE}
channel=${CHANNEL}
hw_mode=g
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
auth_algs=1
ignore_broadcast_ssid=${HIDE_SSID}
ieee80211n=1
wmm_enabled=1
ht_capab=${HT_CAPAB}
EOF

if [ -n "${ALLOW_MAC_ADDRESSES}" ]; then
    logger "# Setting allow-list MAC filtering" 1
    echo "macaddr_acl=1" >> "${HOSTAPD_CONF}"
    : > "${HOSTAPD_ALLOW}"
    for mac in ${ALLOW_MAC_ADDRESSES}; do
        echo "${mac}" >> "${HOSTAPD_ALLOW}"
        logger "Allowed MAC: ${mac}" 0
    done
    echo "accept_mac_file=${HOSTAPD_ALLOW}" >> "${HOSTAPD_CONF}"
elif [ -n "${DENY_MAC_ADDRESSES}" ]; then
    logger "# Setting deny-list MAC filtering" 1
    echo "macaddr_acl=0" >> "${HOSTAPD_CONF}"
    : > "${HOSTAPD_DENY}"
    for mac in ${DENY_MAC_ADDRESSES}; do
        echo "${mac}" >> "${HOSTAPD_DENY}"
        logger "Denied MAC: ${mac}" 0
    done
    echo "deny_mac_file=${HOSTAPD_DENY}" >> "${HOSTAPD_CONF}"
else
    echo "macaddr_acl=0" >> "${HOSTAPD_CONF}"
fi

if [ -n "${HOSTAPD_CONFIG_OVERRIDE}" ]; then
    logger "# Applying custom hostapd overrides" 0
    for override in ${HOSTAPD_CONFIG_OVERRIDE}; do
        echo "${override}" >> "${HOSTAPD_CONF}"
        logger "hostapd override: ${override}" 0
    done
fi

if bashio::config.true "dhcp"; then
    logger "# DHCP enabled, building dnsmasq config" 1
    cat > "${DNSMASQ_CONF}" <<EOF
interface=${INTERFACE}
bind-interfaces
dhcp-range=${DHCP_START_ADDR},${DHCP_END_ADDR},12h
EOF

    if dns_line="$(get_dns_servers)"; then
        echo "${dns_line}" >> "${DNSMASQ_CONF}"
        logger "DNS config: ${dns_line}" 0
    else
        logger "No DNS servers could be determined automatically. Consider using client_dns_override." 0
    fi

    if [ -n "${DNSMASQ_CONFIG_OVERRIDE}" ]; then
        logger "# Applying custom dnsmasq overrides" 0
        for override in ${DNSMASQ_CONFIG_OVERRIDE}; do
            echo "${override}" >> "${DNSMASQ_CONF}"
            logger "dnsmasq override: ${override}" 0
        done
    fi
else
    logger "# DHCP disabled, skipping dnsmasq" 1
fi

if [ -z "${DEFAULT_ROUTE_INTERFACE}" ] && bashio::config.true "client_internet_access"; then
    bashio::exit.nok "No default route interface found, but client_internet_access is enabled."
fi

iptables_setup

if bashio::config.true "dhcp"; then
    logger "## Starting dnsmasq daemon" 1
    dnsmasq -C "${DNSMASQ_CONF}" -k &
    DNSMASQ_PID=$!
fi

logger "## Starting hostapd daemon" 1
if [ "${DEBUG}" -gt 1 ]; then
    hostapd -d "${HOSTAPD_CONF}" &
else
    hostapd "${HOSTAPD_CONF}" &
fi
HOSTAPD_PID=$!

wait "${HOSTAPD_PID}"
