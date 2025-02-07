#!/bin/bash
set -e

# Create tunnel
if ! ip link show "${TUN_NAME}" 2>/dev/null; then
    if ! which brctl >/dev/null 2>&1; then
        if [[ "$(cat /etc/redhat-release)" == CentOS* ]]; then
            sudo dnf -y install epel-release
        elif [[ "$(cat /etc/redhat-release)" == *Enterprise* ]]; then
            major_version=$(rpm -qf --qf '%{version}\n' /etc/redhat-release | grep -o '^[0-9]*')
            sudo dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major_version}.noarch.rpm"
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
