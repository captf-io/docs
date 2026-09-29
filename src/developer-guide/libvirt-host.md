# libvirt Development Host

This page sets up a Linux host with libvirt/KVM so that a kind management
cluster running on it can drive real VMs with libvirt: the Jobs run inside
kind, reaching libvirtd over `qemu+ssh://` from the kind network. It is
one-time host setup, run by hand by the operator of that host. Everything
lives under a scratch directory of your choosing, nothing on `/`; the
commands below use:

```sh
export CAPTF_LIBVIRT_DIR=~/captf-libvirt
mkdir -p "$CAPTF_LIBVIRT_DIR"
```

**The `modules/libvirt/*` modules have not been applied against a real
hypervisor** (see [What the modules
create](#what-the-modules-create) below for their only exercise today).
There is no automated acceptance check; step 6 below lists the manual
checks that stand in for one.

## Before you begin

- A Linux host, separate from or the same as the one running kind, with a
  user who can run commands with `sudo`.
- `virsh`, `podman` and `curl` on that host.
- The kind management cluster already up, so you can read its network's
  gateway address in step 4.

## 1. Packages, daemon, group

```sh
sudo dnf install -y qemu-kvm libvirt virt-install guestfs-tools
sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket
sudo usermod -aG libvirt "$USER"
```

Log out and in (or `newgrp libvirt`) so the group applies, then check:
`virsh -c qemu:///system list --all`.

## 2. The `captf` network

A NAT bridge `virbr-captf` on `192.168.150.0/24`. DHCP serves `.10–.199`;
`.200–.220` stay free for control-plane VIPs (kube-vip in ARP mode needs the
VIP on the same L2 bridge as the VMs).

```sh
cat > "$CAPTF_LIBVIRT_DIR/captf-net.xml" <<'EOF'
<network>
  <name>captf</name>
  <forward mode='nat'/>
  <bridge name='virbr-captf' stp='on' delay='0'/>
  <ip address='192.168.150.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.150.10' end='192.168.150.199'/>
    </dhcp>
  </ip>
</network>
EOF
virsh -c qemu:///system net-define "$CAPTF_LIBVIRT_DIR/captf-net.xml"
virsh -c qemu:///system net-autostart captf
virsh -c qemu:///system net-start captf
```

## 3. Storage pool and base image

```sh
mkdir -p "$CAPTF_LIBVIRT_DIR/pool"
virsh -c qemu:///system pool-define-as captf dir --target "$CAPTF_LIBVIRT_DIR/pool"
virsh -c qemu:///system pool-autostart captf
virsh -c qemu:///system pool-start captf
curl -fL -o "$CAPTF_LIBVIRT_DIR/pool/ubuntu-24.04-cloudimg-amd64.img" \
  https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
virsh -c qemu:///system pool-refresh captf
```

The qemu user must be able to traverse the path; if VMs fail to open the
image and `$CAPTF_LIBVIRT_DIR` is under your home directory, give it
access:

```sh
setfacl -m u:qemu:x ~ "$(dirname "$CAPTF_LIBVIRT_DIR")" "$CAPTF_LIBVIRT_DIR"
setfacl -R -m u:qemu:rwX "$CAPTF_LIBVIRT_DIR/pool"
```

## 4. The identity credential: an ssh key for `qemu+ssh`

A dedicated key, authorized for the user in the `libvirt` group:

```sh
ssh-keygen -t ed25519 -N '' -C captf-libvirt -f "$CAPTF_LIBVIRT_DIR/id_ed25519"
cat "$CAPTF_LIBVIRT_DIR/id_ed25519.pub" >> ~/.ssh/authorized_keys
```

The identity Secret carries these keys. Each reaches the Job as an
environment variable and as a file under `/var/run/captf/credentials/` (see
[how credentials reach a
Job](../user-guide/identities.md#how-credentials-reach-a-job)):

| Key | Module | Value on this host | Default (unset) |
| --- | --- | --- | --- |
| `LIBVIRT_URI` | both | `qemu+ssh://$USER@<host-ip>/system?keyfile=/var/run/captf/credentials/id_ed25519&no_verify=1` (`keyfile` and `no_verify` are libvirt's own qemu+ssh transport query parameters) | `qemu:///system` |
| `id_ed25519` | both | the private key file | (required) |
| `LIBVIRT_BASE_IMAGE` | machine | `$CAPTF_LIBVIRT_DIR/pool/ubuntu-24.04-cloudimg-amd64.img` (absolute path, `$CAPTF_LIBVIRT_DIR` expanded), since the pool lives outside libvirt's default image directory once you follow step 3 above | `/var/lib/libvirt/images/ubuntu-24.04-cloudimg-amd64.img` |
| `LIBVIRT_FAILURE_DOMAIN` | cluster | `<host>`: any name identifying this hypervisor host | `libvirt` |

Set a key only if you diverge from its default.

`<host-ip>` is the host's address as seen from the kind network: the IPv4
gateway of the podman network kind uses (the network is dual-stack; take
the IPv4 subnet's gateway). With the cluster up:

```sh
podman network inspect kind | jq -r '.[0].subnets[] | select(.gateway | contains(":") | not) | .gateway'
```

## 5. Firewall

Allow all traffic from the kind network's IPv4 subnet to the host:

```sh
sudo firewall-cmd --permanent --zone=trusted --add-source=<kind-subnet>
sudo firewall-cmd --reload
```

`<kind-subnet>` is the IPv4 `subnet` from `podman network inspect kind`. If
you prefer a narrower rule, open only port 22 for that source in the active
zone instead of trusting the whole subnet.

## 6. Checks

```sh
virsh -c qemu:///system net-list --all      # captf active
virsh -c qemu:///system pool-list --all     # captf active
podman run --rm --network kind docker.io/library/alpine:3.22 nc -zv <host-ip> 22
```

There is no automated acceptance check. The manual equivalent is a
throwaway VM that boots the cloud image with cloud-init and gets a DHCP
lease on `virbr-captf`, together with a kind pod running `virsh -c
"$LIBVIRT_URI" list`.

## 7. Module images

`templates/cluster-template-libvirt.yaml` defaults `TERRAFORM_CLUSTER_IMAGE`
and `TERRAFORM_MACHINE_IMAGE` to images built from `modules/libvirt/*` and
pushed with `make libvirt-images libvirt-images-push VERSION=v0.1.0` (see
[Releasing](releasing.md#libvirt-module-images)). Rebuild and push after
any change under `modules/libvirt/`; override either variable at
`clusterctl generate` time to use a different image instead. The images
pin `dmacvicar/libvirt` 0.9.9 in their provider mirror.

## What the modules create

`modules/libvirt/cluster/` leases a control-plane VIP; `modules/libvirt/machine/`
boots one VM (2 vCPU, 4 GiB, a 20 GiB qcow2 overlay on the Ubuntu 24.04
cloud image) from the bootstrap payload, on the `captf` network.

There is no load balancer; `KubeadmControlPlane` runs kube-vip as a static
pod on the control-plane machines, announcing the VIP over ARP on
`virbr-captf`. The cluster module only chooses and leases the VIP:

- **The `libvirt` flavor supplies the VIP** (`TERRAFORM_VIP` becomes
  `TerraformCluster.spec.controlPlaneEndpoint`); the module passes it
  through and rejects one outside `.200-.220`.
- **Without one**, the module derives
  `192.168.150.(200 + sha256("<namespace>/<cluster>")[0:8] mod 21)`: a
  pure function of the Cluster, known at the first plan and never
  changed, with no resource backing it, so no plan can replace it.
- **Either way**, the module leases the VIP as a 1-byte volume
  `captf-vip-<vip>` in the `captf` pool; a second cluster that hashes to
  the same VIP fails its apply rather than sharing the address (21
  addresses, so collisions are expected past a handful of clusters — this
  is a development module, not a VIP allocator). Destroying the cluster
  frees it.

The domain is named `<namespace>-<machine_name>` (domain names are
host-wide, Machine names only namespace-wide), and `provider_id` is
`libvirt:///<namespace>-<machine_name>`: the KubeadmConfig templates set
the same string as the kubelet's `provider-id`, so no cloud controller
manager is needed. `kubernetes_version` also rides in the cloud-init
NoCloud meta-data, so a KCP/MachineDeployment upgrade installs the
version the machine was actually created for rather than one clusterctl
baked in at generate time. Addresses and health come from the `captf`
network's DHCP leases, re-read on every refresh (the domain create waits
for a lease with `wait_for_ip`): no lease reads `running`/unhealthy with
message `no DHCP lease on network captf` (a remediation candidate),
never `pending`. The root disk is an overlay, so destroy removes it, the
seed ISO and the domain, leaving the base image untouched.

`make test-libvirt-modules` runs each module's `tests/*.tftest.hcl` with
`tofu test` against a **mocked** `dmacvicar/libvirt` provider — the only
exercise these modules get; there is no automated end-to-end test against
a real hypervisor. The modules target OpenTofu; Terraform 1.16.4 validates
both and passes the cluster tests, but its mock cannot supply the machine
tests' lease data (a nested list attribute).

## See also

- [Releasing](releasing.md), for the `libvirt` module images this host
  builds and pushes.
- [`modules/libvirt/README.md`](https://github.com/scrothers/cluster-api-provider-terraform/blob/main/modules/libvirt/README.md)
  for the module source itself.
