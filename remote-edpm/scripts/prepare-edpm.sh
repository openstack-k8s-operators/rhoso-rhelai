#!/bin/bash
set -e

# Usable env vars
# SSH_USER ==> User configured in the ansible runner. Defaults to cloud-admin
# SSH_PUB_KEY ==> Public key contents used by ansible runner
# SSH_PRIV_KEY ==> Private key contents used by ansible runner

# Convert arguments to env variables
for envvar in "${@}"; do
  eval "${envvar%%=*}='${envvar#*=}'"
done

# Set defaults
[ -z "${SSH_USER}" ] && SSH_USER=cloud-admin


[ -n "${SSH_PUB_KEY}" ] || (echo "Provide the SSH_PUB_KEY contents" && exit 1)
[ -n "${SSH_PRIV_KEY}" ] || (echo "Provide the SSH_PRIV_KEY contents" && exit 1)

# Install minimum packages required by the ansible runner
sudo dnf -y install tar curl


# Ensure user exists
if ! id -u "${SSH_USER}"; then
    sudo useradd "${SSH_USER}"
    USER_ADDED=true
fi


SUDOERS_FILE="/etc/sudoers.d/${SSH_USER}"

if [ ! -f "${SUDOERS_FILE}" ]; then
    echo "${SSH_USER}       ALL = (ALL) NOPASSWD: ALL" | sudo tee "${SUDOERS_FILE}"
    sudo chown root:root "${SUDOERS_FILE}"
    sudo chmod 0660 "${SUDOERS_FILE}"
fi

# SH_HOME=$(eval $(echo ~${SSH_USER}))
SSH_HOME=$(eval echo ~$USER)

sudo mkdir -p "${SSH_HOME}/.ssh"
sudo chmod 0700 "${SSH_HOME}/.ssh"

AUTHORIZED_KEYS="${SSH_HOME}/.ssh/authorized_keys"
PRIV_KEY_FILE="${SSH_HOME}/.ssh/rhoso_geneve"
# Add the SSH user we are using to the new user's authorized keys
if [ -n "${USER_ADDED}" ]; then
    sudo cat "${HOME}/.ssh/authorized_keys" | sudo tee -a "${AUTHORIZED_KEYS}"
fi

if ! grep -Fq "${SSH_PUB_KEY}" "${AUTHORIZED_KEYS}"; then
    echo "${SSH_PUB_KEY}" | sudo tee -a "${AUTHORIZED_KEYS}"
fi
sudo chmod 0600 "${AUTHORIZED_KEYS}"

if [ ! -e "${PRIV_KEY_FILE}" ]; then
    echo "${SSH_PUB_KEY}" | sudo tee -a "${PRIV_KEY_FILE}.pub"
fi

if ! grep -Fq "${SSH_PRIV_KEY}" "${PRIV_KEY_FILE}"; then
    echo "${SSH_PRIV_KEY}" | sudo tee -a "${PRIV_KEY_FILE}"
fi
sudo chmod 0600 "${PRIV_KEY_FILE}"

sudo chown -R "${SSH_USER}:${SSH_USER}" "${SSH_HOME}/.ssh"

sudo loginctl enable-linger "${SSH_USER}"

if [ -n "${JUMP_BOX}" ]; then
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
fi
