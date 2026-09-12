#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly WG_DIR="/etc/wireguard"
readonly PARAMS_FILE="${WG_DIR}/params"

die() {
	echo "Error: $*" >&2
	exit 1
}

require_root() {
	[[ ${EUID} -eq 0 ]] || die "run this script as root"
	[[ ${PWD} == "${HOME}" ]] || die "run this script from root's home directory (${HOME})"
}

load_params() {
	[[ -f ${PARAMS_FILE} ]] || die "missing ${PARAMS_FILE}; install the server first"
	# The installer writes this root-only file with shell-escaped values.
	# shellcheck disable=SC1090
	source "${PARAMS_FILE}"

	: "${SERVER_PUB_IP:?missing SERVER_PUB_IP in ${PARAMS_FILE}}"
	: "${SERVER_PUB_NIC:?missing SERVER_PUB_NIC in ${PARAMS_FILE}}"
	: "${SERVER_WG_NIC:?missing SERVER_WG_NIC in ${PARAMS_FILE}}"
	: "${SERVER_WG_IPV4:?missing SERVER_WG_IPV4 in ${PARAMS_FILE}}"
	: "${SERVER_WG_IPV6:?missing SERVER_WG_IPV6 in ${PARAMS_FILE}}"
	: "${SERVER_PORT:?missing SERVER_PORT in ${PARAMS_FILE}}"
	: "${SERVER_PUB_KEY:?missing SERVER_PUB_KEY in ${PARAMS_FILE}}"

	# Older versions of the upstream script did not persist the network CIDRs.
	SERVER_WG_IPV4_NETWORK="${SERVER_WG_IPV4_NETWORK:-${SERVER_WG_IPV4%.*}.0/24}"
	SERVER_WG_IPV6_NETWORK="${SERVER_WG_IPV6_NETWORK:-${SERVER_WG_IPV6%::*}::/64}"
}

next_client_number() {
	local number ipv4 ipv6

	for number in {2..254}; do
		ipv4="${SERVER_WG_IPV4%.*}.${number}"
		ipv6="${SERVER_WG_IPV6%::*}::${number}"

		if [[ ! -e "${HOME}/${SERVER_WG_NIC}-client-${number}.conf" ]] &&
			! grep -Fq "AllowedIPs = ${ipv4}/32, ${ipv6}/128" "${WG_DIR}/${SERVER_WG_NIC}.conf"; then
			printf '%s\n' "${number}"
			return
		fi
	done

	die "no unused client addresses remain in the configured /24 subnet"
}

add_client() {
	local client_number client_ipv4 client_ipv6 client_private_key
	local client_public_key client_preshared_key endpoint client_file

	load_params
	[[ -f "${WG_DIR}/${SERVER_WG_NIC}.conf" ]] ||
		die "missing ${WG_DIR}/${SERVER_WG_NIC}.conf; the server installation is incomplete"

	if [[ ${SERVER_PUB_IP} == *:* ]]; then
		endpoint="[${SERVER_PUB_IP}]:${SERVER_PORT}"
	else
		endpoint="${SERVER_PUB_IP}:${SERVER_PORT}"
	fi

	client_number="$(next_client_number)"
	client_ipv4="${SERVER_WG_IPV4%.*}.${client_number}"
	client_ipv6="${SERVER_WG_IPV6%::*}::${client_number}"
	client_file="${HOME}/${SERVER_WG_NIC}-client-${client_number}.conf"

	printf '\nCreating WireGuard client %s\n' "$((client_number - 1))"
	echo "IPv4 address: ${client_ipv4}"
	echo "IPv6 address: ${client_ipv6}"

	client_private_key="$(wg genkey)"
	client_public_key="$(printf '%s' "${client_private_key}" | wg pubkey)"
	client_preshared_key="$(wg genpsk)"

	cat >"${client_file}" <<EOF
[Interface]
PrivateKey = ${client_private_key}
Address = ${client_ipv4}/32, ${client_ipv6}/128
DNS = ${SERVER_WG_IPV4}, ${SERVER_WG_IPV6}
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${client_preshared_key}
Endpoint = ${endpoint}
AllowedIPs = ${SERVER_WG_IPV4_NETWORK}, ${SERVER_WG_IPV6_NETWORK}
PersistentKeepalive = 25
EOF

	cat >>"${WG_DIR}/${SERVER_WG_NIC}.conf" <<EOF

[Peer]
PublicKey = ${client_public_key}
PresharedKey = ${client_preshared_key}
AllowedIPs = ${client_ipv4}/32, ${client_ipv6}/128
EOF

	systemctl restart "wg-quick@${SERVER_WG_NIC}"

	echo
	echo "Scan this QR code with the WireGuard client:"
	qrencode -t ansiutf8 -l L <"${client_file}"
	echo
	echo "Client profile: ${client_file}"
	echo "Treat this file and QR code as secrets; they contain the client's private key."
}

detect_os() {
	[[ -r /etc/os-release ]] || die "cannot identify this operating system"
	# shellcheck disable=SC1091
	source /etc/os-release

	case "${ID}" in
	ubuntu | debian)
		return
		;;
	*)
		die "this Oracle Cloud installer supports Ubuntu and Debian only (detected ${ID})"
		;;
	esac
}

install_packages() {
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		dnsutils \
		iptables \
		qrencode \
		wireguard \
		wireguard-tools
}

is_ipv4() {
	local address=$1 octet
	local -a octets

	IFS=. read -r -a octets <<<"${address}"
	[[ ${#octets[@]} -eq 4 ]] || return 1
	for octet in "${octets[@]}"; do
		[[ ${octet} =~ ^[0-9]{1,3}$ ]] || return 1
		((10#${octet} <= 255)) || return 1
	done
}

validate_settings() {
	[[ ${SERVER_PUB_IP} =~ ^[A-Za-z0-9._:%-]+$ ]] ||
		die "the endpoint must be an IP address or hostname without spaces"
	[[ ${SERVER_PUB_NIC} =~ ^[A-Za-z0-9_.+-]{1,15}$ ]] ||
		die "invalid public interface name: ${SERVER_PUB_NIC}"
	[[ ${SERVER_WG_NIC} =~ ^[A-Za-z0-9_.+-]{1,15}$ ]] ||
		die "invalid WireGuard interface name: ${SERVER_WG_NIC}"
	is_ipv4 "${SERVER_WG_IPV4}" ||
		die "invalid WireGuard IPv4 address: ${SERVER_WG_IPV4}"
	[[ ${SERVER_WG_IPV6} =~ ^[0-9A-Fa-f:]+$ ]] && [[ ${SERVER_WG_IPV6} == *::* ]] ||
		die "the WireGuard IPv6 address must use compressed notation, such as fd42:42:42::1"
	[[ ${SERVER_PORT} =~ ^[0-9]+$ ]] &&
		((SERVER_PORT >= 1 && SERVER_PORT <= 65535)) ||
		die "the WireGuard port must be between 1 and 65535"
}

write_params() {
	{
		printf 'SERVER_PUB_IP=%q\n' "${SERVER_PUB_IP}"
		printf 'SERVER_PUB_NIC=%q\n' "${SERVER_PUB_NIC}"
		printf 'SERVER_WG_NIC=%q\n' "${SERVER_WG_NIC}"
		printf 'SERVER_WG_IPV4=%q\n' "${SERVER_WG_IPV4}"
		printf 'SERVER_WG_IPV6=%q\n' "${SERVER_WG_IPV6}"
		printf 'SERVER_WG_IPV4_NETWORK=%q\n' "${SERVER_WG_IPV4_NETWORK}"
		printf 'SERVER_WG_IPV6_NETWORK=%q\n' "${SERVER_WG_IPV6_NETWORK}"
		printf 'SERVER_PORT=%q\n' "${SERVER_PORT}"
		printf 'SERVER_PUB_KEY=%q\n' "${SERVER_PUB_KEY}"
	} >"${PARAMS_FILE}"
}

write_firewall_helpers() {
	install -d -m 700 "${WG_DIR}/ipt"

	cat >"${WG_DIR}/ipt/start.sh" <<EOF
#!/usr/bin/env bash
set -e

iptables -t nat -I POSTROUTING 1 -s ${SERVER_WG_IPV4_NETWORK} -o ${SERVER_PUB_NIC} -j MASQUERADE
iptables -I INPUT 1 -i ${SERVER_WG_NIC} -j ACCEPT
iptables -I INPUT 1 -i ${SERVER_PUB_NIC} -p udp --dport ${SERVER_PORT} -j ACCEPT
iptables -I FORWARD 1 -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
iptables -I FORWARD 1 -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

ip6tables -t nat -I POSTROUTING 1 -s ${SERVER_WG_IPV6_NETWORK} -o ${SERVER_PUB_NIC} -j MASQUERADE
ip6tables -I INPUT 1 -i ${SERVER_WG_NIC} -j ACCEPT
ip6tables -I INPUT 1 -i ${SERVER_PUB_NIC} -p udp --dport ${SERVER_PORT} -j ACCEPT
ip6tables -I FORWARD 1 -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT
ip6tables -I FORWARD 1 -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
EOF

	cat >"${WG_DIR}/ipt/stop.sh" <<EOF
#!/usr/bin/env bash

iptables -t nat -D POSTROUTING -s ${SERVER_WG_IPV4_NETWORK} -o ${SERVER_PUB_NIC} -j MASQUERADE || true
iptables -D INPUT -i ${SERVER_WG_NIC} -j ACCEPT || true
iptables -D INPUT -i ${SERVER_PUB_NIC} -p udp --dport ${SERVER_PORT} -j ACCEPT || true
iptables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT || true
iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true

ip6tables -t nat -D POSTROUTING -s ${SERVER_WG_IPV6_NETWORK} -o ${SERVER_PUB_NIC} -j MASQUERADE || true
ip6tables -D INPUT -i ${SERVER_WG_NIC} -j ACCEPT || true
ip6tables -D INPUT -i ${SERVER_PUB_NIC} -p udp --dport ${SERVER_PORT} -j ACCEPT || true
ip6tables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_PUB_NIC} -j ACCEPT || true
ip6tables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
EOF

	chmod 700 "${WG_DIR}/ipt/start.sh" "${WG_DIR}/ipt/stop.sh"
}

install_server() {
	local detected_public_ip detected_public_nic server_private_key

	if [[ -d ${WG_DIR} ]] && [[ -n $(find "${WG_DIR}" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
		die "${WG_DIR} is not empty; refusing to overwrite an existing or incomplete setup"
	fi

	detect_os
	install_packages

	detected_public_ip="$(dig TXT +short o-o.myaddr.l.google.com @ns1.google.com |
		awk -F'"' 'NF >= 2 { print $2; exit }' || true)"
	detected_public_nic="$(ip -4 route show default |
		awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"

	printf '\nServer configuration (press Enter to accept each default)\n\n'
	read -r -e -i "${detected_public_ip}" -p "Public IP address or hostname: " SERVER_PUB_IP
	read -r -e -i "${detected_public_nic}" -p "Public interface: " SERVER_PUB_NIC
	read -r -e -i "wg0" -p "WireGuard interface name: " SERVER_WG_NIC
	read -r -e -i "10.66.66.1" -p "WireGuard IPv4 address: " SERVER_WG_IPV4
	read -r -e -i "fd42:42:42::1" -p "WireGuard IPv6 address: " SERVER_WG_IPV6
	read -r -e -i "51515" -p "WireGuard UDP port: " SERVER_PORT

	validate_settings
	SERVER_WG_IPV4_NETWORK="${SERVER_WG_IPV4%.*}.0/24"
	SERVER_WG_IPV6_NETWORK="${SERVER_WG_IPV6%::*}::/64"

	install -d -m 700 "${WG_DIR}"
	server_private_key="$(wg genkey)"
	SERVER_PUB_KEY="$(printf '%s' "${server_private_key}" | wg pubkey)"
	write_firewall_helpers

	cat >"${WG_DIR}/${SERVER_WG_NIC}.conf" <<EOF
[Interface]
Address = ${SERVER_WG_IPV4}/24, ${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${server_private_key}
PostUp = ${WG_DIR}/ipt/start.sh
PostDown = ${WG_DIR}/ipt/stop.sh
EOF

	cat >"/etc/sysctl.d/70-wireguard-routing.conf" <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

	sysctl --system
	systemctl enable --now "wg-quick@${SERVER_WG_NIC}"
	write_params
	add_client
}

main() {
	require_root

	case "${1:-}" in
	"")
		if [[ -f ${PARAMS_FILE} ]]; then
			add_client
		else
			install_server
		fi
		;;
	client)
		add_client
		;;
	*)
		die "usage: $0 [client]"
		;;
	esac
}

main "$@"

# The MIT License (MIT)
#
# Copyright (c) 2020 Rajan Patel
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# Notice for Software Components Licensed Under the MIT License.
# wireguard-install Copyright (c) 2019 angristan (Stanislas Lange)
