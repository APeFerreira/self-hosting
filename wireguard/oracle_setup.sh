#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly WG_DIR="/etc/wireguard"
readonly PARAMS_FILE="${WG_DIR}/params"
readonly PEERS_DIR="${WG_DIR}/peers"
readonly PRIVATE_DIR="${WG_DIR}/private"
readonly FIREWALL_DIR="${WG_DIR}/iptables"
readonly BACKUP_DIR="${WG_DIR}/backups"
readonly CLIENTS_DIR="/root/wireguard-clients"
readonly SYSCTL_FILE="/etc/sysctl.d/70-wireguard-routing.conf"
readonly FIREWALL_UNIT="/etc/systemd/system/wireguard-firewall.service"
readonly WG_DROPIN_DIR="/etc/systemd/system/wg-quick@wg0.service.d"
readonly WG_DROPIN_FILE="${WG_DROPIN_DIR}/firewall.conf"
readonly SERVER_WG_NIC="wg0"
readonly SERVER_WG_IPV4="10.66.66.1"
readonly SERVER_WG_NETWORK="10.66.66.0/24"

DRY_RUN=false
POSITIONAL=()
INSTALL_STAGING=""
INSTALL_PREVIOUS_FORWARDING="0"

die() {
	echo "Error: $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage:
  oracle_setup.sh install [--dry-run]
  oracle_setup.sh add-client NAME [split|full] [--dry-run]
  oracle_setup.sh list-clients
  oracle_setup.sh revoke-client NAME [--dry-run]

The installer is IPv4-only by design. It creates wg0 as 10.66.66.1/24 and
allocates client addresses from 10.66.66.2 through 10.66.66.254.
EOF
}

parse_arguments() {
	local argument

	for argument in "$@"; do
		if [[ ${argument} == "--dry-run" ]]; then
			DRY_RUN=true
		else
			POSITIONAL+=("${argument}")
		fi
	done
}

require_root() {
	[[ ${EUID} -eq 0 ]] || die "run this script as root (for example, with sudo -i)"
}

confirm() {
	local expected=$1 prompt=$2 answer

	read -r -p "${prompt} Type ${expected} to continue: " answer
	[[ ${answer} == "${expected}" ]] || die "confirmation did not match; nothing was changed"
}

validate_name() {
	local name=$1
	[[ ${name} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] ||
		die "client names must be 1-32 letters, digits, underscores, or hyphens"
}

validate_endpoint() {
	local endpoint=$1
	[[ ${endpoint} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
		die "the public endpoint must be an IPv4 address or DNS hostname without spaces"
}

validate_interface() {
	local interface_name=$1
	[[ ${interface_name} =~ ^[A-Za-z0-9_.+-]{1,15}$ ]] ||
		die "invalid network interface name: ${interface_name}"
	[[ -d "/sys/class/net/${interface_name}" ]] ||
		die "network interface does not exist: ${interface_name}"
}

validate_port() {
	local port=$1
	[[ ${port} =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) ||
		die "the WireGuard UDP port must be between 1 and 65535"
}

detect_os() {
	[[ -r /etc/os-release ]] || die "cannot identify this operating system"
	# shellcheck disable=SC1091
	source /etc/os-release

	case "${ID}" in
	ubuntu | debian) ;;
	*) die "this installer supports Ubuntu and Debian only (detected ${ID})" ;;
	esac
}

check_firewall_manager() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		die "UFW is active; this installer manages direct iptables rules and refuses to mix firewall managers"
	fi

	if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		die "firewalld is active; this installer manages direct iptables rules and refuses to mix firewall managers"
	fi
}

check_fresh_install() {
	if [[ -d ${WG_DIR} ]] && [[ -n $(find "${WG_DIR}" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
		die "${WG_DIR} is not empty; use the client commands for a managed installation or move the existing configuration aside"
	fi

	[[ ! -e ${SYSCTL_FILE} ]] ||
		die "${SYSCTL_FILE} already exists; review or move it before installation"

	if ip -4 route show | grep -Fq "${SERVER_WG_NETWORK}"; then
		die "${SERVER_WG_NETWORK} already exists in the host routing table"
	fi
}

install_packages() {
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		iproute2 \
		iptables \
		procps \
		qrencode \
		wireguard \
		wireguard-tools
}

load_params() {
	[[ -f ${PARAMS_FILE} ]] || die "missing ${PARAMS_FILE}; run the install command first"
	# The installer creates this root-only file with shell-escaped values.
	# shellcheck disable=SC1090
	source "${PARAMS_FILE}"

	: "${SERVER_ENDPOINT:?missing SERVER_ENDPOINT in ${PARAMS_FILE}}"
	: "${SERVER_PUB_NIC:?missing SERVER_PUB_NIC in ${PARAMS_FILE}}"
	: "${SERVER_PORT:?missing SERVER_PORT in ${PARAMS_FILE}}"
	: "${SERVER_PUB_KEY:?missing SERVER_PUB_KEY in ${PARAMS_FILE}}"

	[[ ${MANAGED_BY:-} == "self-hosting-wireguard-v2" ]] ||
		die "${WG_DIR} is not marked as a managed v2 installation"
	[[ ${CONFIGURED_WG_NIC:-} == "${SERVER_WG_NIC}" ]] ||
		die "managed interface mismatch in ${PARAMS_FILE}"
	[[ ${CONFIGURED_WG_IPV4:-} == "${SERVER_WG_IPV4}" ]] ||
		die "managed server address mismatch in ${PARAMS_FILE}"
}

write_params() {
	local output=$1 endpoint=$2 public_nic=$3 port=$4 public_key=$5

	{
		printf 'MANAGED_BY=%q\n' "self-hosting-wireguard-v2"
		printf 'SERVER_ENDPOINT=%q\n' "${endpoint}"
		printf 'SERVER_PUB_NIC=%q\n' "${public_nic}"
		printf 'SERVER_PORT=%q\n' "${port}"
		printf 'SERVER_PUB_KEY=%q\n' "${public_key}"
		printf 'CONFIGURED_WG_NIC=%q\n' "${SERVER_WG_NIC}"
		printf 'CONFIGURED_WG_IPV4=%q\n' "${SERVER_WG_IPV4}"
		printf 'CONFIGURED_WG_NETWORK=%q\n' "${SERVER_WG_NETWORK}"
	} >"${output}"
}

write_firewall_helpers() {
	local start_file=$1 stop_file=$2 public_nic=$3 port=$4

	cat >"${start_file}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

# Authenticated WireGuard peers are trusted to reach services on this host.
iptables -C INPUT -i ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i ${SERVER_WG_NIC} -j ACCEPT
iptables -C INPUT -i ${public_nic} -p udp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i ${public_nic} -p udp --dport ${port} -j ACCEPT
iptables -C FORWARD -i ${SERVER_WG_NIC} -o ${public_nic} -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${SERVER_WG_NIC} -o ${public_nic} -j ACCEPT
iptables -C FORWARD -i ${public_nic} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i ${public_nic} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s ${SERVER_WG_NETWORK} -o ${public_nic} -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${SERVER_WG_NETWORK} -o ${public_nic} -j MASQUERADE
EOF

	cat >"${stop_file}" <<EOF
#!/usr/bin/env bash

while iptables -C INPUT -i ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null; do
	iptables -D INPUT -i ${SERVER_WG_NIC} -j ACCEPT || break
done
while iptables -C INPUT -i ${public_nic} -p udp --dport ${port} -j ACCEPT 2>/dev/null; do
	iptables -D INPUT -i ${public_nic} -p udp --dport ${port} -j ACCEPT || break
done
while iptables -C FORWARD -i ${SERVER_WG_NIC} -o ${public_nic} -j ACCEPT 2>/dev/null; do
	iptables -D FORWARD -i ${SERVER_WG_NIC} -o ${public_nic} -j ACCEPT || break
done
while iptables -C FORWARD -i ${public_nic} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
	iptables -D FORWARD -i ${public_nic} -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || break
done
while iptables -t nat -C POSTROUTING -s ${SERVER_WG_NETWORK} -o ${public_nic} -j MASQUERADE 2>/dev/null; do
	iptables -t nat -D POSTROUTING -s ${SERVER_WG_NETWORK} -o ${public_nic} -j MASQUERADE || break
done
EOF

	# These files are read by Bash rather than executed directly. This works on
	# hardened hosts where /etc is mounted with the noexec option.
	chmod 600 "${start_file}" "${stop_file}"
}

write_systemd_firewall_units() {
	local firewall_unit=$1 wg_dropin=$2

	cat >"${firewall_unit}" <<EOF
[Unit]
Description=Firewall rules for ${SERVER_WG_NIC}
After=network-online.target
Before=wg-quick@${SERVER_WG_NIC}.service
PartOf=wg-quick@${SERVER_WG_NIC}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${FIREWALL_DIR}/start.sh
ExecStop=/bin/bash ${FIREWALL_DIR}/stop.sh
EOF

	cat >"${wg_dropin}" <<EOF
[Unit]
Requires=wireguard-firewall.service
After=wireguard-firewall.service
EOF

	chmod 644 "${firewall_unit}" "${wg_dropin}"
}

render_server_config() {
	local output=$1 extra_peer=${2:-} excluded_name=${3:-} config_root=${4:-${WG_DIR}}
	local peer peer_name

	cat >"${output}" <<EOF
[Interface]
Address = ${SERVER_WG_IPV4}/24
ListenPort = ${SERVER_PORT}
PrivateKey = $(<"${config_root}/private/server.key")
MTU = 1420
EOF

	for peer in "${config_root}/peers"/*.conf; do
		[[ -e ${peer} ]] || continue
		peer_name="$(basename "${peer}" .conf)"
		[[ ${peer_name} == "${excluded_name}" ]] && continue
		printf '\n' >>"${output}"
		cat "${peer}" >>"${output}"
	done

	if [[ -n ${extra_peer} ]]; then
		printf '\n' >>"${output}"
		cat "${extra_peer}" >>"${output}"
	fi
}

validate_wireguard_config() {
	local config=$1 stripped_output=$2
	wg-quick strip "${config}" >"${stripped_output}"
}

rollback_install() {
	local previous_forwarding=$1

	systemctl disable --now "wg-quick@${SERVER_WG_NIC}" >/dev/null 2>&1 || true
	systemctl stop wireguard-firewall.service >/dev/null 2>&1 || true
	[[ -r ${FIREWALL_DIR}/stop.sh ]] && /bin/bash "${FIREWALL_DIR}/stop.sh" >/dev/null 2>&1 || true
	rm -f \
		"${WG_DIR}/${SERVER_WG_NIC}.conf" \
		"${WG_DIR}/.stripped.conf" \
		"${WG_DIR}/70-wireguard-routing.conf" \
		"${PRIVATE_DIR}/server.key" \
		"${PRIVATE_DIR}/server.pub" \
		"${FIREWALL_DIR}/start.sh" \
		"${FIREWALL_DIR}/stop.sh" \
		"${PARAMS_FILE}" \
		"${SYSCTL_FILE}" \
		"${FIREWALL_UNIT}" \
		"${WG_DROPIN_FILE}"
	rmdir "${WG_DROPIN_DIR}" 2>/dev/null || true
	rm -f \
		"${WG_DIR}/systemd/wireguard-firewall.service" \
		"${WG_DIR}/systemd/firewall.conf"
	rmdir "${WG_DIR}/systemd" 2>/dev/null || true
	rmdir "${CLIENTS_DIR}" 2>/dev/null || true
	rmdir "${BACKUP_DIR}" "${PEERS_DIR}" "${PRIVATE_DIR}" "${FIREWALL_DIR}" "${WG_DIR}" 2>/dev/null || true
	systemctl daemon-reload >/dev/null 2>&1 || true
	sysctl -q -w "net.ipv4.ip_forward=${previous_forwarding}" >/dev/null 2>&1 || true
}

install_exit_cleanup() {
	local status=$?
	trap - EXIT

	if [[ -n ${INSTALL_STAGING} && -d ${INSTALL_STAGING} ]]; then
		rm -rf -- "${INSTALL_STAGING}"
	fi
	rollback_install "${INSTALL_PREVIOUS_FORWARDING}"
	exit "${status}"
}

install_server() {
	local endpoint public_nic port public_key private_key
	local staging previous_forwarding

	require_root
	detect_os
	check_fresh_install
	check_firewall_manager

	public_nic="$(ip -4 route show default | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
	[[ -n ${public_nic} ]] || die "could not detect the default IPv4 interface"

	read -r -p "Public endpoint for clients (OCI public IPv4 or DNS hostname): " endpoint
	read -r -e -i "${public_nic}" -p "VPS default-route interface (Linux name, e.g. enp0s3): " public_nic
	read -r -e -i "51515" -p "WireGuard UDP port: " port

	validate_endpoint "${endpoint}"
	validate_interface "${public_nic}"
	validate_port "${port}"

	cat <<EOF

Installation summary
  Operating system: ${ID}
  Public endpoint:  ${endpoint}:${port}/udp
  Public interface: ${public_nic}
  WireGuard:        ${SERVER_WG_NIC} at ${SERVER_WG_IPV4}/24
  VPN subnet:       ${SERVER_WG_NETWORK}
  Client trust:     authenticated peers may reach host services through ${SERVER_WG_NIC}
  Routing:          IPv4 forwarding and NAT enabled
  Configuration:    ${WG_DIR}
  OCI networking:   UDP ${port} must be opened manually in the NSG/security list
EOF

	if ${DRY_RUN}; then
		echo "Dry run complete; no packages, files, firewall rules, or services were changed."
		return
	fi

	confirm "INSTALL" "This installs packages and changes routing, firewall, and systemd state."
	install_packages

	for command_name in wg wg-quick iptables sysctl systemctl qrencode; do
		command -v "${command_name}" >/dev/null 2>&1 || die "required command is unavailable after installation: ${command_name}"
	done

	staging="$(mktemp -d /etc/.wireguard-install.XXXXXX)"
	previous_forwarding="$(sysctl -n net.ipv4.ip_forward)"
	INSTALL_STAGING="${staging}"
	INSTALL_PREVIOUS_FORWARDING="${previous_forwarding}"
	chmod 700 "${staging}"
	trap install_exit_cleanup EXIT
	install -d -m 700 \
		"${staging}/peers" \
		"${staging}/private" \
		"${staging}/iptables" \
		"${staging}/backups" \
		"${staging}/systemd"

	private_key="$(wg genkey)"
	public_key="$(printf '%s' "${private_key}" | wg pubkey)"
	printf '%s\n' "${private_key}" >"${staging}/private/server.key"
	printf '%s\n' "${public_key}" >"${staging}/private/server.pub"
	write_params "${staging}/params" "${endpoint}" "${public_nic}" "${port}" "${public_key}"
	write_firewall_helpers "${staging}/iptables/start.sh" "${staging}/iptables/stop.sh" "${public_nic}" "${port}"
	write_systemd_firewall_units "${staging}/systemd/wireguard-firewall.service" "${staging}/systemd/firewall.conf"

	SERVER_ENDPOINT="${endpoint}"
	SERVER_PUB_NIC="${public_nic}"
	SERVER_PORT="${port}"
	SERVER_PUB_KEY="${public_key}"
	render_server_config "${staging}/${SERVER_WG_NIC}.conf" "" "" "${staging}"
	chmod 600 \
		"${staging}/${SERVER_WG_NIC}.conf" \
		"${staging}/params" \
		"${staging}/private/server.key" \
		"${staging}/private/server.pub"

	printf 'net.ipv4.ip_forward = 1\n' >"${staging}/70-wireguard-routing.conf"
	chmod 644 "${staging}/70-wireguard-routing.conf"
	rmdir "${WG_DIR}" 2>/dev/null || true
	mv "${staging}" "${WG_DIR}"
	staging=""
	INSTALL_STAGING=""
	validate_wireguard_config "${WG_DIR}/${SERVER_WG_NIC}.conf" "${WG_DIR}/.stripped.conf"
	rm -f "${WG_DIR}/.stripped.conf"
	install -d -m 700 "${CLIENTS_DIR}"
	install -d -m 755 "${WG_DROPIN_DIR}"
	install -m 644 "${WG_DIR}/70-wireguard-routing.conf" "${SYSCTL_FILE}"
	install -m 644 "${WG_DIR}/systemd/wireguard-firewall.service" "${FIREWALL_UNIT}"
	install -m 644 "${WG_DIR}/systemd/firewall.conf" "${WG_DROPIN_FILE}"
	rm -f "${WG_DIR}/70-wireguard-routing.conf"
	rm -rf -- "${WG_DIR}/systemd"
	systemctl daemon-reload

	if ! sysctl -q -w net.ipv4.ip_forward=1; then
		die "could not enable IPv4 forwarding; generated WireGuard state was rolled back"
	fi

	if ! systemctl enable --now "wg-quick@${SERVER_WG_NIC}"; then
		echo >&2
		echo "wg-quick failed. Recent service diagnostics:" >&2
		systemctl status "wg-quick@${SERVER_WG_NIC}" --no-pager --full >&2 || true
		journalctl -u "wg-quick@${SERVER_WG_NIC}" -b --no-pager -n 80 >&2 || true
		die "WireGuard startup failed and generated state was rolled back; installed packages were retained"
	fi

	trap - EXIT
	INSTALL_PREVIOUS_FORWARDING="0"
	echo
	echo "WireGuard is running. Open UDP ${port} in OCI, then add a named client with:"
	echo "  $0 add-client PHONE split"
}

next_client_ipv4() {
	local number candidate peer

	for number in {2..254}; do
		candidate="10.66.66.${number}"
		if grep -RqsF "AllowedIPs = ${candidate}/32" "${PEERS_DIR}" 2>/dev/null; then
			continue
		fi
		if wg show "${SERVER_WG_NIC}" allowed-ips 2>/dev/null | grep -Fq "${candidate}/32"; then
			continue
		fi
		printf '%s\n' "${candidate}"
		return
	done

	die "no unused client addresses remain in ${SERVER_WG_NETWORK}"
}

backup_server_config() {
	local operation=$1 timestamp
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	install -m 600 "${WG_DIR}/${SERVER_WG_NIC}.conf" \
		"${BACKUP_DIR}/${SERVER_WG_NIC}.${timestamp}.${operation}.conf"
}

require_running_server() {
	load_params
	[[ -f "${WG_DIR}/${SERVER_WG_NIC}.conf" ]] || die "missing server configuration"
	[[ -r "${PRIVATE_DIR}/server.key" ]] || die "missing server private key"
	wg show "${SERVER_WG_NIC}" >/dev/null 2>&1 ||
		die "${SERVER_WG_NIC} is not running; repair the server before changing peers"
}

add_client() {
	local name=$1 tunnel_mode=${2:-split} client_ipv4 allowed_ips
	local client_private_key client_public_key preshared_key endpoint
	local client_file peer_file staging candidate stripped old_config old_stripped
	local add_mutated=false

	require_root
	validate_name "${name}"
	[[ ${tunnel_mode} == "split" || ${tunnel_mode} == "full" ]] ||
		die "tunnel mode must be split or full"
	require_running_server

	peer_file="${PEERS_DIR}/${name}.conf"
	client_file="${CLIENTS_DIR}/${SERVER_WG_NIC}-${name}.conf"
	[[ ! -e ${peer_file} && ! -e ${client_file} ]] || die "client already exists: ${name}"

	client_ipv4="$(next_client_ipv4)"
	if [[ ${tunnel_mode} == "full" ]]; then
		allowed_ips="0.0.0.0/0"
	else
		allowed_ips="${SERVER_WG_NETWORK}"
	fi
	endpoint="${SERVER_ENDPOINT}:${SERVER_PORT}"

	cat <<EOF

Client summary
  Name:          ${name}
  Address:       ${client_ipv4}/32
  Tunnel mode:   ${tunnel_mode}
  Client routes: ${allowed_ips}
  DNS:           ${SERVER_WG_IPV4}
  Endpoint:      ${endpoint}/udp
  Profile:       ${client_file}
EOF

	if ${DRY_RUN}; then
		echo "Dry run complete; no keys, profiles, peers, or live settings were changed."
		return
	fi

	confirm "ADD" "Create this client."
	staging="$(mktemp -d "${WG_DIR}/.add-client.XXXXXX")"
	client_private_key="$(wg genkey)"
	client_public_key="$(printf '%s' "${client_private_key}" | wg pubkey)"
	preshared_key="$(wg genpsk)"

	cat >"${staging}/peer.conf" <<EOF
# Client = ${name}
# TunnelMode = ${tunnel_mode}
[Peer]
PublicKey = ${client_public_key}
PresharedKey = ${preshared_key}
AllowedIPs = ${client_ipv4}/32
EOF

	cat >"${staging}/client.conf" <<EOF
[Interface]
PrivateKey = ${client_private_key}
Address = ${client_ipv4}/32
DNS = ${SERVER_WG_IPV4}
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${preshared_key}
Endpoint = ${endpoint}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF

	candidate="${staging}/candidate.conf"
	stripped="${staging}/stripped.conf"
	old_config="${staging}/old.conf"
	old_stripped="${staging}/old-stripped.conf"
	cp "${WG_DIR}/${SERVER_WG_NIC}.conf" "${old_config}"
	validate_wireguard_config "${old_config}" "${old_stripped}"
	add_cleanup() {
		local status=$?
		trap - EXIT
		if ${add_mutated}; then
			install -m 600 "${old_config}" "${WG_DIR}/${SERVER_WG_NIC}.conf" || true
			rm -f "${peer_file}" "${client_file}"
			wg syncconf "${SERVER_WG_NIC}" "${old_stripped}" >/dev/null 2>&1 || true
		fi
		rm -rf -- "${staging}"
		exit "${status}"
	}
	trap add_cleanup EXIT
	render_server_config "${candidate}" "${staging}/peer.conf"
	validate_wireguard_config "${candidate}" "${stripped}"
	backup_server_config "before-add-${name}"

	add_mutated=true
	install -m 600 "${staging}/peer.conf" "${peer_file}"
	install -m 600 "${staging}/client.conf" "${client_file}"
	install -m 600 "${candidate}" "${WG_DIR}/${SERVER_WG_NIC}.conf"

	if ! wg syncconf "${SERVER_WG_NIC}" "${stripped}"; then
		die "failed to apply the peer; configuration and generated client files were rolled back"
	fi

	trap - EXIT
	rm -rf -- "${staging}"
	echo
	echo "Client created: ${client_file}"
	echo "The profile and QR code contain a private key. Treat both as secrets."
	qrencode -t ansiutf8 -l L <"${client_file}" ||
		echo "Warning: the client was created, but QR-code rendering failed." >&2
}

list_clients() {
	local peer name address mode found=false

	require_root
	load_params
	printf '%-34s %-18s %-8s\n' "NAME" "ADDRESS" "MODE"
	for peer in "${PEERS_DIR}"/*.conf; do
		[[ -e ${peer} ]] || continue
		found=true
		name="$(sed -n 's/^# Client = //p' "${peer}")"
		address="$(sed -n 's/^AllowedIPs = \([^,]*\).*/\1/p' "${peer}")"
		mode="$(sed -n 's/^# TunnelMode = //p' "${peer}")"
		printf '%-34s %-18s %-8s\n' "${name}" "${address}" "${mode}"
	done
	${found} || echo "No managed clients."
}

revoke_client() {
	local name=$1 peer_file client_file staging candidate stripped old_config old_stripped
	local revoke_mutated=false

	require_root
	validate_name "${name}"
	require_running_server
	peer_file="${PEERS_DIR}/${name}.conf"
	client_file="${CLIENTS_DIR}/${SERVER_WG_NIC}-${name}.conf"
	[[ -f ${peer_file} ]] || die "managed client does not exist: ${name}"

	echo
	echo "Client to revoke: ${name}"
	sed -n 's/^AllowedIPs = /  Address: /p' "${peer_file}"
	echo "  Profile to remove: ${client_file}"

	if ${DRY_RUN}; then
		echo "Dry run complete; no peer, profile, or live settings were changed."
		return
	fi

	confirm "REVOKE" "This permanently removes the peer and local client profile."
	staging="$(mktemp -d "${WG_DIR}/.revoke-client.XXXXXX")"
	candidate="${staging}/candidate.conf"
	stripped="${staging}/stripped.conf"
	old_config="${staging}/old.conf"
	old_stripped="${staging}/old-stripped.conf"
	cp "${WG_DIR}/${SERVER_WG_NIC}.conf" "${old_config}"
	validate_wireguard_config "${old_config}" "${old_stripped}"
	revoke_cleanup() {
		local status=$?
		trap - EXIT
		if ${revoke_mutated}; then
			install -m 600 "${old_config}" "${WG_DIR}/${SERVER_WG_NIC}.conf" || true
			wg syncconf "${SERVER_WG_NIC}" "${old_stripped}" >/dev/null 2>&1 || true
		fi
		rm -rf -- "${staging}"
		exit "${status}"
	}
	trap revoke_cleanup EXIT
	render_server_config "${candidate}" "" "${name}"
	validate_wireguard_config "${candidate}" "${stripped}"
	backup_server_config "before-revoke-${name}"
	revoke_mutated=true
	install -m 600 "${candidate}" "${WG_DIR}/${SERVER_WG_NIC}.conf"

	if ! wg syncconf "${SERVER_WG_NIC}" "${stripped}"; then
		die "failed to apply revocation; the server configuration was restored"
	fi

	trap - EXIT
	rm -f "${peer_file}" "${client_file}" ||
		echo "Warning: peer access was revoked, but a local peer or profile file could not be removed." >&2
	rm -rf -- "${staging}"
	echo "Client revoked: ${name}"
}

main() {
	local command name mode

	parse_arguments "$@"
	command="${POSITIONAL[0]:-}"

	case "${command}" in
	install)
		[[ ${#POSITIONAL[@]} -eq 1 ]] || die "usage: $0 install [--dry-run]"
		install_server
		;;
	add-client | client)
		name="${POSITIONAL[1]:-}"
		mode="${POSITIONAL[2]:-split}"
		[[ -n ${name} && ${#POSITIONAL[@]} -le 3 ]] ||
			die "usage: $0 add-client NAME [split|full] [--dry-run]"
		add_client "${name}" "${mode}"
		;;
	list-clients)
		[[ ${#POSITIONAL[@]} -eq 1 ]] || die "usage: $0 list-clients"
		list_clients
		;;
	revoke-client)
		name="${POSITIONAL[1]:-}"
		[[ -n ${name} && ${#POSITIONAL[@]} -eq 2 ]] ||
			die "usage: $0 revoke-client NAME [--dry-run]"
		revoke_client "${name}"
		;;
	-h | --help | help | "")
		usage
		;;
	*)
		usage >&2
		die "unknown command: ${command}"
		;;
	esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi

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
