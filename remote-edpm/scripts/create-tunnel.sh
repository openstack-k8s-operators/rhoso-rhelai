#!/bin/bash
set -e
SCRIPT_DIR="$(realpath "$( dirname "${BASH_SOURCE[0]}" )")"
SSHUTTLE_PID_FILE="$(realpath "${SCRIPT_DIR}/../out/sshuttle.pid")"

if [ -n "${JUMP_BOX}" ] && ( [ ! -e "${SSHUTTLE_PID_FILE}" ] || ! grep -q sshuttle "/proc/$(cat ${SSHUTTLE_PID_FILE})/cmdline" ); then
    if ! which sshuttle; then
        if ! sudo dnf -y install sshuttle; then
            sudo dnf -y install python3-pip
            sudo pip install sshuttle
        fi
    fi
    if ! ip rule | grep "fwmark ${MARK}"; then
        echo "Adding routes and rules for sshuttle's TPROXY"
        sudo ip route add local default dev lo table 100
        sudo ip rule add fwmark "${TMARK}" lookup 100
        sudo ip -6 route add local default dev lo table 100
        sudo ip -6 rule add fwmark "${TMARK}" lookup 100
    fi

    sudo openvpn --daemon --config /etc/openvpn/ovpn-brq2-udp.conf

    sudo ip route add 10.8.231.19 dev lo
    sudo ip route add 10.8.231.19 dev lo metric 10

    sudo ip route add nat 192.168.140 via 127.0.0.1

    sudo ip route add nat 10.8.231.19 via 127.0.0.1
    sudo ip route add local default dev lo table 100

# sudo iptables -t nat -A LIBVIRT_PRT -s 192.168.130.0/24 -d 10.8.231.19 -p tcp -j MASQUERADE --to
# sudo iptables -t nat -I OUTPUT -p udp --dport 6081 -j NOTRACK

    sudo iptables


    -A LIBVIRT_PRT -s 192.168.130.0/24 ! -d 192.168.130.0/24 -p tcp -j MASQUERADE --to-ports 1024-65535
    -A LIBVIRT_PRT -s 192.168.130.0/24 ! -d 192.168.130.0/24 -p udp -j MASQUERADE --to-ports 1024-65535

    default via 192.168.1.1 dev eth0 proto static metric 100
    10.0.0.0/8 via 10.45.224.1 dev tun0 proto static metric 50
    10.45.224.0/20 dev tun0 proto kernel scope link src 10.45.225.91 metric 50

    echo "Creating an sshuttle connection to ${REMOTE_EDPM_IP} using Jumpbox ${JUMP_BOX} and opening remote port 9000 to ssh connect back"
    # Open remote port 9000 for connecting back
    sudo SSH_AUTH_SOCK="${SSH_AUTH_SOCK}" sshuttle \
        --method=tproxy \
        -D \
        --pidfile="${SSHUTTLE_PID_FILE}" \
        -r "${SSH_USER}@${REMOTE_EDPM_IP}" \
        -e "ssh -R 9000:localhost:22 -J ${JUMP_BOX}" \
        "${REMOTE_EDPM_IP}/32"

    # Authorize key in current user
    SSH_KEY="$(cat ${SSH_KEY_FILE}.pub)"
    if ! grep -Fq "${SSH_KEY}" ~/.ssh/autorized_keys; then
        echo "Adding SSH pub key to this machine's authorized keys"
        echo "${SSH_KEY}" >> ~/.ssh/autorized_keys;
    fi
    # sshuttle -D --pidfile="${SSHUTTLE_PID_FILE}" -r "${SSH_USER}@${REMOTE_EDPM_IP}" -e "ssh -J ${JUMP_BOX}" ${REMOTE_EDPM_IP}/32
fi


# Create tunnel
if ! ip link show "${TUN_NAME}" 2>/dev/null; then
    if ! which brctl >/dev/null 2>&1; then
        if [[ "$(cat /etc/redhat-release)" == CentOS* ]]; then
            sudo dnf -y install epel-release
        fi
        sudo dnf -y install bridge-utils
    fi
    sudo ip link add name "${TUN_NAME}" type geneve id "${GNV_ID}" remote "${REMOTE_EDPM_IP}"
    sudo ip link set "${TUN_NAME}" up

    BRIDGE_NAME=$(sudo virsh net-info "${VIRT_NETWORK}"|grep Bridge|awk '{print $2}')
    sudo brctl addif "${BRIDGE_NAME}" "${TUN_NAME}"
fi

# Allow Geneve tunnel connection
if [[ "$(sudo firewall-cmd --state 2>&1)" == 'running' ]]; then
    # Create firewall rule
    FW_FILE="/etc/firewalld/services/geneve.xml"
    if [[ ! -e "${FW_FILE}" ]]; then
        sudo cp ./templates/geneve.xml "${FW_FILE}"
        sudo chown root:root "${FW_FILE}"
        sudo /sbin/restorecon -v "${FW_FILE}"
    fi
    sudo firewall-cmd --reload
    sudo firewall-cmd --permanent --zone=public \
        --add-rich-rule="rule family=\"ipv4\" source address=\"${REMOTE_EDPM_IP%.*}.0/24\" service name=\"geneve\" accept"
fi

# No conn tracking for geneve tunnel
# sudo iptables -t raw -I PREROUTING -p udp --dport 6081 -j NOTRACK
# sudo iptables -t raw -I OUTPUT -p udp --dport 6081 -j NOTRACK
