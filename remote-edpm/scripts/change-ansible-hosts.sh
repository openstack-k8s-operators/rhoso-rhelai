#!/bin/bash
set -e
sed -i "s/value: ${IP_ADDRESS_PREFIX}.10${EDPM_NODE}/value: ${REMOTE_EDPM_IP}/" kustomization.yaml
