# Testing RHEL AI on a single machine using nested virtualization

This repository is meant to help deploying a toy RHOSO + RHEL AI system on a
single machine.

To deploy on a single machine the OpenStack control plane will run as a single
node OpenStack inside a VM (using CRC) and the edpm node will also run as a VM
using PCI passthrough to pass the NVIDIA GPU/GPUs to the nova compute service.

Finally RHEL AI will be run as an OpenStack instance executing in the edpm
node.

This is going to have considerable performance issues because of the double
nesting virtualization, qcow2 disks, and PCI passthrough, so this is clearly
not meant for any real usage, just to help confirm that everything works as
intended.

# QuickStart

## Prerequisites

You'll need at least one [NVIDIA GPU supported by RHEL AI]() and some tools
need to be installed as well the `install_yamls` and this repository. There is
a helper make target for this, although there are some things that you still
need to do:

```bash
$ sudo dnf -y install git make
$ git clone <this repository>
$ make download_tools validate_host
```

The `validate_host` target may fail if you don't have an NVIDIA GPU, if the GPU
is being held by the graphics driver, is IOMMU is not properly configured, etc.

## Deploying RHOSO

Deploying OpenStack on OpenShift has 2 phases: Deploying the control plane and
deploying the edpm node.

To deploy the control plane you'll need a `pull-secret` from
`https://cloud.redhat.com/openshift/create/local`. This file must exist as
`~/pull-secret`, or its location set in the `PULL_SECRET` env var.

The targets for each of these phases:

```bash
$ make deploy_controlplane
$ make deploy_edpm
```

**Note:** By default all the NVIDIA GPUs will be passed through and used by the
single RHEL AI instance.  All GPUs must be of the same model.

## Deploying RHEL AI

You'll need to create a download link in the [RHEL AI download
page](https://access.redhat.com/downloads/content/932), copy the link to the
qcow2 download, and pass it in the `AI_IMAGE_URL` env var or manually download
the qcow2 file as `out/rhel-ai-disk.qcow2`.

Note: You may need to [join the RHEL AI trial](https://www.redhat.com/en/technologies/linux-platforms/enterprise-linux/ai/trial).

```bash
$ AI_IMAGE_URL=https://access.cdn.redhat.com/.../rhel-ai-nvidia-1.2-1728670729-x86_64-kvm.qcow2 \
  make deploy_rhel_ai
```

# Customization

There should be reasonable defaults, but you can still configuration a number
of things via environmental variables when calling the make targets to customize
the different phases.  This is a non-exhaustive list:

- For the control plane:
  - PULL_SECRET
  - TIMEOUT_OPERATORS
  - TIMEOUT_CTRL
  - CRC_CPUS
  - CRC_MEMORY
  - CRC_DISK
  - DEPLOY_CINDER
  - CRC_VERSION

- For the edpm node:
  - EDPM_CPUS
  - EDPM_RAM
  - EDPM_DISK
  - GPU_VENDOR_ID
  - GPU_PRODUCT_ID
  - TIMEOUT_EDPM

- For RHEL AI
  - AI_NUM_GPUS
  - AI_VM_NAME
  - AI_CPUS
  - AI_RAM
  - AI_DISK

  For example, if we have more resources, and the secret is not located on the
  home directory, you may use something like this:

  ```bash
  CRC_CPU=14 CRC_RAM=30 PULL_SECRET=../../pull-secret make deploy_controlplane
  EDPM_CPUS=30 EDPM_RAM=200 EDPM_DISK=800 make deploy_edpm
  PULL_SECRET=../../pull-secret AI_CPUS=22 AI_RAM=50 AI_DISK=650 make deploy_rhel_ai
  ```
