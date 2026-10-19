# proxmox-k8s-lab

A reproducible, from-code Kubernetes platform on a bare-metal Proxmox homelab.
Terraform provisions the VMs, Ansible bootstraps a kubeadm cluster with Cilium,
and a single `terraform destroy && apply` + playbook run rebuilds the whole thing
from git — unattended, with a stable cluster CA preserved across rebuilds.

**The artifact:** declarative provision → bootstrap → reproducible teardown/rebuild.
Tear the cluster down and bring it back from code, identity intact.

## Architecture

- **Hypervisor:** 2× Minisforum MS-A2 on Proxmox VE 9.1 (`alpharius`, `omegon`),
  clustered as `alphaomega`.
- **Network:** the lab runs on its own VLAN 3 (`192.168.3.0/24`), bridge `vmbr2`.
- **Control node (`opsbox`, .3.10):** a Debian LXC *outside* Terraform's management —
  holds state, runs terraform/ansible/kubectl, and custodies the cluster CA. The box
  that runs `destroy` must not be something `destroy` can remove.
- **Cluster (Terraform-provisioned Debian 13 VMs):**

  | VM       | role          | host      | IP            |
  |----------|---------------|-----------|---------------|
  | k8s-cp-1 | control-plane | alpharius | 192.168.3.110 |
  | k8s-w-1  | worker        | alpharius | 192.168.3.111 |
  | k8s-w-2  | worker        | omegon    | 192.168.3.112 |

- **Kubernetes:** kubeadm v1.33, containerd, Cilium (eBPF) CNI.

## Layout

.
├── *.tf                      # Proxmox provider + VM definitions (local.nodes map)
├── inventory.tf              # renders ansible/inventory.ini from local.nodes
├── templates/inventory.ini.tftpl
└── ansible/
    ├── ansible.cfg
    ├── requirements.yml      # kubernetes.core, community.general, ansible.posix
    ├── site.yml              # plays: common → control_plane → worker
    ├── group_vars/all.yml
    └── roles/{common,control_plane,worker}/

## Prerequisites (on the opsbox)

```bash
export TF_VAR_proxmox_api_token='terraform@pve!provider=...'   # never written to a file
ansible-galaxy collection install -r ansible/requirements.yml
# ~/.ssh/config: UserKnownHostsFile /dev/null scoped to the lab IPs (VMs are ephemeral)

Usage

# provision VMs + render the Ansible inventory
terraform init && terraform apply

# bootstrap Kubernetes
cd ansible && ansible-playbook site.yml

# the proof — rebuild the entire cluster from code, unattended
terraform destroy -auto-approve && terraform apply -auto-approve
cd ansible && ansible-playbook site.yml
kubectl get nodes      # all Ready; CA unchanged, existing kubeconfig still valid

Design notes

- opsbox is outside Terraform — a stable bastion that survives every rebuild;
holds state, the CA, and the kubeconfig.
- CA preserved across rebuilds — the cluster CA lives on the opsbox
(~/.k8s-pki, not in git) and is restored before kubeadm init, so a rebuilt
cluster keeps the same identity and existing kubeconfigs stay valid.
- Idempotent Ansible — kubeadm init/join guarded by creates:; Cilium via
Helm (declarative); a fail-loud assert on the containerd cgroup driver.
- One source of truth for topology — Terraform renders the Ansible inventory from
the same local.nodes map that declares the VMs.
- Secrets stay out of git — API token via env var; *.tfstate,
ansible/inventory.ini, and kubeconfig are gitignored.

Hard-won lessons (baked into the code)

- Bridge is vmbr2, not vmbr0 — the MS-A2 is multi-NIC; only vmbr2 is on the LAN.
- Lab on its own VLAN 3 — original static IPs collided with the UniFi DHCP pool
(an AP held .112), which masqueraded as an SSH-key bug for a long debug.
- containerd CNI bin_dir — Debian looks in /usr/lib/cni; Cilium installs to
/opt/cni/bin. Mismatch → pods stuck ContainerCreating.
- containerd cgroup driver — Debian ships a minimal config.toml, so "generate
only if absent" left SystemdCgroup unset (cgroupfs) while kubelet runs systemd →
the whole control plane CrashLoopBackOff. The common role regenerates and asserts
SystemdCgroup = true.
- SSH host-key churn — rebuilt VMs present new host keys; handled with a
lab-scoped UserKnownHostsFile /dev/null.

Notes

- This repo on the opsbox is authoritative; the build rationale and step-by-step log
are documented separately. If the docs and the repo disagree, the repo wins.
- Internal RFC1918 addresses are hard-coded for a 3-node lab. Scaling path:
pin contracts (a control-plane VIP, ingress/service VIPs via kube-vip/MetalLB, DNS),
discover members (leased/self-registering workers) — genericize before publishing.
