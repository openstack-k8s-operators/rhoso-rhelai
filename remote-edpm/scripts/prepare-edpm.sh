#!/bin/bash
set -e

# Usable env vars
# SSH_USER ==> User configured in the ansible runner. Defaults to cloud-admin
# SSH_KEY ==> Public key contents used by ansible runner

# Convert arguments to env variables
for envvar in "${@}"; do
  eval "${envvar%%=*}='${envvar#*=}'"
done

# Set defaults
[ -z "${SSH_USER}" ] && SSH_USER=cloud-admin


[ -n "${SSH_KEY}" ] || (echo "Provide the SSH_KEY contents" && exit 1)

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

SSH_HOME=$(eval echo ~${SSH_USER})

sudo mkdir -p "${SSH_HOME}/.ssh"
sudo chmod 0700 "${SSH_HOME}/.ssh"

AUTHORIZED_KEYS="${SSH_HOME}/.ssh/authorized_keys"
# Add the SSH user we are using to the new user's authorized keys
if [ -n "${USER_ADDED}" ]; then
    sudo cat "${HOME}/.ssh/authorized_keys" | sudo tee -a "${AUTHORIZED_KEYS}"
fi

if ! grep -Fq "${SSH_KEY}" "${AUTHORIZED_KEYS}"; then
    echo "${SSH_KEY}" | sudo tee -a "${AUTHORIZED_KEYS}"
fi

sudo chown -R "${SSH_USER}:${SSH_USER}" "${SSH_HOME}/.ssh"
sudo chmod 0600 "${AUTHORIZED_KEYS}"

sudo loginctl enable-linger "${SSH_USER}"
