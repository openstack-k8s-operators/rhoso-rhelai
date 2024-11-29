# Adding a remote EDPM node to RHOSO

The objective of this guide is to help us add a host that is in another network
as an EDPM node of our local RHOSO deployment.

This allows us to test hardware that is only available on a remote host, for
example GPUs on a host behind the VPN or a jump server.

We'll focus on a local CRC deployment with a single remote EDPM node, although
it would be trivial to add more local virtualized EDPM nodes to the system.

This is not going to be automated for now, unlike in the nested-passthrough
case; a list of manual steps and some some scripts and templates will be
provided.

## Overview

In the following steps we are going to assume we have a local host where we'll
install RHOSO control plane and a remote EDPM node in IP 192.168.1.13.

We'll create a bridge called `rhoso` that will connect the OCP cluster and the
EDPM nodes together. To stretch this bridge to the remote EDPM node we'll use
a Geneve tunnel.

The `rhoso` network will have the 192.168.140.0/24 subnet because the
192.168.130.0/24 is the crc one that we want to leave alone to always have
connectivity between the crc VM and the host. We also don't use the
192.168.122.0/24 subnet from the `default` libvirt network to avoid problems,
so we'll have to pass additional parameters to `install_yamls` that is not
expecting our subnet.

This will be a deployment with isolated networks, so we'll have 3 VLANs on the
edpm nodes that connect to the OCP cluster and possible local EDPM nodes:
- internalapi (172.17.0.100)
- storage (172.18.0.100)
- tenant (172.19.0.100)

## Assumptions

- This guide assumes you have already cloned the `install_yamls` repository:

  ```bash
  $ sudo dnf -y install git make ansible-core libvirt-daemon-common
  $ git clone https://github.com/openstack-k8s-operators/install_yamls.git
  $ make -C install_yamls/devsetup download_tools
  ```

- You have downloaded your pull secret from
  `https://cloud.redhat.com/openshift/create/local` and have it locally
  available.

- Your local host where you are going to deploy the OCP cluster has access to
  the remote node.  If a VPN is needed, please connect to the VPN on the host
  before following up with this guide.

## Limitations

At the time of this writing OpenStack networking will not provide external
access (to Internet) even though we can attach br-ex network (`192.168.140.x`
IPs).  Though that network will connect the VM with the OCP network and allow
us to ssh into it from the OCP node.

When opening the local tunnel it assumes we are using `firewalld` or nothing.
Scripts don't handle nftables.

There is no support for using a Jump Box to access the edpm node.

## Configure vars

There are many parameters used for the whole process, so to facilitate the
deployment and reduce the number of mistakes they have all been grouped
together in the `env-vars` file.

So the first thing we need to do is go into that file and change it to match
our needs.

There are 4 groupings in the file:
- Variables you **have** to modify.
- Variables you should check to see if they are acceptable to you.
- Variables that should be fine as they are unless you are somewhat diverging
  from this guide.
- Helper functions and validation code that should be fine as they are.

Once we have configured everything we need to source that file:

```bash
$ source ./env-vars
```

## Deploying RHOSO

### Deploy OCP

1. Deploy the OCP CRC VM:

  ```bash
  $ make -C ${INSTALL_YAMLS_DIR}/devsetup crc \
    CRC_VERSION=${CRC_VERSION} \
    PULL_SECRET=$(realpath ${PULL_SECRET}) \
    CPUS=${CRC_CPUS} \
    MEMORY=$((1024*${CRC_RAM})) \
    DISK=${CRC_DISK}

  $ eval $(crc oc-env)
  ```

2. Now we create the `rhoso` networking in libvirt. We should only do this once,
   as this network will survive host reboots and the steps are not idempotent:

   ```bash
   $ eval "echo '$(cat templates/rhoso-net.xml)'" > out/${VIRT_NETWORK}-net.xml
   $ sudo virsh net-define --file out/${VIRT_NETWORK}-net.xml
   $ sudo virsh net-start ${VIRT_NETWORK}
   $ sudo virsh net-autostart --network ${VIRT_NETWORK}
   ```

3. Attach the `rhoso` network to the CRC VM and set a static DHCP entry for it
   (`192.168.140.10`):

   ```bash
   $ make -C${INSTALL_YAMLS_DIR}/devsetup attach_default_interface \
     NETWORK_ISOLATION_NET_NAME=${VIRT_NETWORK} \
     NETWORK_ISOLATION_IP_ADDRESS="${IP_ADDRESS_PREFIX}.10"
   ```

   This network is not a `nat` bridge, because those prevent SFTP from working,
   and ansible will not be able to provision the node.  This means that the OCP
   CRC VM will access internet via the `crc` network (which is an `nat`
   bridge).  More on the types of libvirt bridges here:
   https://libvirt.org/firewall.html

### Deploy operators

Deploy the RHOSO operators with:

```bash
$ make -C "${INSTALL_YAMLS_DIR}" openstack_wait \
  NETWORK_ISOLATION_USE_DEFAULT_NETWORK=false \
  METALLB_POOL="${IP_ADDRESS_PREFIX}.80-${IP_ADDRESS_PREFIX}.90" \
  NNCP_CTLPLANE_IP_ADDRESS_PREFIX="${IP_ADDRESS_PREFIX}" \
  NNCP_GATEWAY="${IP_ADDRESS_PREFIX}.1" \
  NNCP_DNS_SERVER="${IP_ADDRESS_PREFIX}.1" \
  NNCP_TIMEOUT=600s \
  TIMEOUT=600s \
  NETWORK_MTU=${MTU}
```

The interesting things about the previous custom command to deploy the RHOSO
operators are:

- We are setting the metallb pool addresses so they are between
  `192.168.140.80` and `192.168.140.90`.
- We are setting MTU to `1450` to account for the tunnel.

**Note:** An alternative to decreasing the MTU to `1450` would be to increase
it at the nic level to accommodate the Geneve tunnel header overhead instead.

### Deploy RHOSO control plane

1. Create the storage necessary for the deployment

   ```bash
   $ make -C "${INSTALL_YAMLS_DIR}" crc_storage
   ```

2. Label the storage in case we deploy Cinder with LVMo

   ```bash
   $ oc label node "${OCP_NODE_NAME}" openstack.org/cinder-lvm=
   ```

3. Create the RHOSO control plane configuration files

   ```bash
   $ sed "s/\${VENDOR_ID}/${PCI_VENDOR_ID}/g;s/\${PRODUCT_ID}/${PCI_PRODUCT_ID}/g" "${CTL_TEMPLATE}" > out/kustomization.yaml
   $ sed "s/\${MTU}/${MTU}/g;s/\${IP_ADDRESS_PREFIX}/${IP_ADDRESS_PREFIX}/g" "${NETCONFIG_TEMPLATE}" > out/netconfig.yaml
   $ oc kustomize ./out > ./out/openstack-deployment.yaml
   ```

4. Deploy the control plane:

   ```bash
   $ make -C "${INSTALL_YAMLS_DIR}" openstack_deploy \
     NETCONFIG_CR=$(realpath ./out/netconfig.yaml) \
     NETWORK_ISOLATION_USE_DEFAULT_NETWORK=false \
     NNCP_CTLPLANE_IP_ADDRESS_PREFIX="${IP_ADDRESS_PREFIX}" \
     OPENSTACK_CR=$(realpath ./out/openstack-deployment.yaml)
   ```

   In the previous command we not only replace the `OpenStackControlPlane` CR
   to include our nova custom configuration and remove a bunch of services we
   are not going to use, but we also replace the `NetConfig` CR being used to
   ensure the right MTUs is used on the OCP side as well as when we deploy the
   EDPM node.

5. Wait for it to complete:

   ```bash
   $ oc wait openstackcontrolplane openstack --for condition=Ready --timeout=30m
   ```

   **Note:** We could avoid this step if we used the `openstack_deploy_wait`
   target in step 4, but that would fail if we were deploying Cinder with LVM.

## Deploying EDPM node

### Preparing the node

There are 5 things that we need to manually do on the EDPM node:
1. Provision the host with the OS
2. Prepare it for pci-passthrough
3. Install necessary packages
4. Ensure SSH user exists
5. Authorize RHOSO to SSH into edpm node

You are responsible for the first step, the second step will be handled by the
provisioning of the edpm node (using env vars `EDPM_CPU`,
`EDPM_ADD_KERNEL_ARGS`, `PCI_VENDOR_ID`, and `PCI_PRODUCT_ID`), and the last 3
will be handled by the `prepare-edpm.sh` script.

We generate the SSH key (helper function from `env-vars` and prepare edpm host
(steps 3 to 5 from the list above):

```bash
$ generate_key

$ ssh ${SSH_ARGS} ${REMOTE_EDPM_IP} \
    bash -s \
    SSH_USER=${SSH_USER} \
    SSH_KEY="'$(cat ${SSH_KEY_FILE}.pub)'" \
    < ./scripts/prepare-edpm.sh
```

### Prepare configuration

We need to prepare the nova.conf overrides specific for our PCI devices as well
as render templates from `templates/preprovisioned` into `out/preprovisioned`.

The alias that will be created for our PCI devices on nova is named `gpu`,
unlike in the nested example that was `nvidia`.  This is the alias that should
be referenced when creating the nova flavor.

```bash
$ gen_edpm_config
```

Among the customizations that we have that diverge from a standard
install_yamls deployment we have:

- Setting a custom mtu (`1450`) for CRC on the `enp6s0` nic (that's the one
  linked to the `rhoso` libvirt bridge)
- Run ansible playbook after `ovn` has been deployed to create the tunnel.
- Use custom `edpm_network_config_template` that, unlike the standard one,
  doesn't move the first available nic (`nic1` alias in `os-net-config`) on the
  edpm node under the bridge, sets the bridge IP to `192.168.140.100` and adds
  a custom dns nameserver (`${INET_DNS_SERVER}`).

### Create local tunnel

Create the local end of the Geneve tunnel

```bash
$ scripts/create-tunnel.sh
```

### Provision node

Now we just have to do the deployment:

```ssh
$ make -C "${INSTALL_YAMLS_DIR}" edpm_wait_deploy \
  DATAPLANE_SAMPLES_DIR="$(realpath ./out)" \
  DATAPLANE_EXTRA_NOVA_CONFIG_FILE=$(realpath ./out/nova-compute.conf) \
  DATAPLANE_POST_GEN_SCRIPT="$(realpath ./scripts/change-ansible-hosts.sh)" \
  NETWORK_ISOLATION_USE_DEFAULT_NETWORK=false \
  DATAPLANE_TIMEOUT=40m \
  DATAPLANE_TOTAL_NODES=1 \
  NNCP_CTLPLANE_IP_ADDRESS_PREFIX="${IP_ADDRESS_PREFIX}" \
  DATAPLANE_COMPUTE_IP="${IP_ADDRESS_PREFIX}.10${EDPM_NODE}" \
  DATAPLANE_DEFAULT_GW="${IP_ADDRESS_PREFIX}.1" \
  DATAPLANE_SSHD_ALLOWED_RANGES="['0.0.0.0/0']" \
  EDPM_ANSIBLE_USER=${SSH_USER} \
  OUT="${INSTALL_YAMLS_DIR}/out"
```

When we do that there are some interesting customizations beyond what we
discussed when generating the configuration:

- It passes our nova.conf overrides so they are deployed on the edpm node.
- Allows SSH from ANY IP, instead of limiting it to IP address from
  `192.168.140.0/24` which is the standard.
- Tells the make target that the samples for the dataplane kustomization are
  in `out` directory instead of the usual directory from the
  openstack-operator.
- Runs a script (`scripts/change-ansible-shots.sh`) to change the ansible hosts
  in the resulting manifest so we can use a different IP (`${REMOTE_EDPM_IP}`)
  to provision them than the one they will be using afterwards
 (`${IP_ADDRESS_PREFIX}.10${EDPM_NODE}`).

### Check nova compute service

The edpm node should now be up and running and reporting to the control plane.
We can check it using:

```bash
$ oc rsh openstackclient openstack hypervisor list
$ oc rsh openstackclient openstack compute service list --service=nova-compute
```

# Run a VM

Now the EDPM node is ready we can run a VM to test things.

First go into the `openstackclient` pod to run commands:

```bash
$ oc rsh openstackclient
$ source ~/cloudrc
```

Now get the `cirros` image and create the flavor:

```bash
$ glance --force image-create-via-import \
    --disk-format qcow2 \
    --container-format bare \
    --name cirros \
    --visibility public \
    --import-method web-download \
    --uri http://download.cirros-cloud.net/0.5.2/cirros-0.5.2-x86_64-disk.img

$ openstack flavor create --ram 4096 --vcpus 12 --disk 50 gpu \
  --property "pci_passthrough:alias"="gpu:1" \
  --property "hw:pci_numa_affinity_policy=preferred" \
  --property "hw:hide_hypervisor_id"=true
```

Now we create the networks, security group, etc.

```bash
$ openstack network create private --share
$ openstack subnet create priv_sub --subnet-range 192.168.0.0/24 --network private
$ openstack network create public --external --provider-network-type flat --provider-physical-network datacentre
$ openstack subnet create public_subnet --subnet-range 192.168.140.0/24 --allocation-pool start=192.168.140.171,end=192.168.140.250 --gateway 192.168.140.1 --dhcp --network public

$ openstack router create priv_router
$ openstack router add subnet priv_router priv_sub
$ openstack router set priv_router --external-gateway public

$ openstack security group create basic
$ openstack security group rule create basic --protocol icmp --ingress --icmp-type -1
$ openstack security group rule create basic --protocol tcp --ingress --dst-port 22

$ openstack security group rule create basic --protocol tcp --remote-ip 0.0.0.0/0
```

Create the SSH key for the VM:

```bash
$ openstack keypair create cirros > cirros.pem
$ chmod 600 cirros.pem
```

Finally create the VM

```
$ openstack server create --flavor nvidia --image cirros --key-name cirros --nic net-id=private cirros --security-group basic --wait
```

The machine should quickly become ready, although it will depend on the
connection speed between your OCP cluster and the remote EDPM node, because
the glance image has to go from your local machine to the remote one.

Now we will assign a static floating IP (so we don't have to check what IP was
assigned) and use that address to SSH into the VM:

```bash
$ FIP_ADDR=192.168.140.222
$ openstack floating ip create --floating-ip-address $FIP_ADDR public
$ openstack server add floating ip cirros $FIP_ADDR
$ ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./cirros.pem cirros@${FIP_ADDR}
```

**Note:** Remember the VM username is `cirros` and the password is `gocubsgo`.
