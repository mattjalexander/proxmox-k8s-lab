#!/usr/bin/env bash
set -euoxv pipefail
mkdir -p templates ansible/group_vars \
         ansible/roles/common/tasks ansible/roles/common/handlers \
         ansible/roles/control_plane/tasks ansible/roles/worker/tasks

cat > inventory.tf <<'EOF'
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    vms = var.vms
  })
  filename = "${path.module}/ansible/inventory.ini"
}
EOF

cat > templates/inventory.ini.tftpl <<'EOF'
[control_plane]
%{ for name, vm in vms ~}
%{ if vm.role == "control-plane" ~}
${name} ansible_host=${vm.ip}
%{ endif ~}
%{ endfor ~}

[workers]
%{ for name, vm in vms ~}
%{ if vm.role == "worker" ~}
${name} ansible_host=${vm.ip}
%{ endif ~}
%{ endfor ~}

[k8s_cluster:children]
control_plane
workers
EOF

cat > ansible/ansible.cfg <<'EOF'
[defaults]
inventory          = inventory.ini
remote_user        = debian
host_key_checking  = False
roles_path         = roles
stdout_callback    = yaml

[privilege_escalation]
become = True
EOF

cat > ansible/group_vars/all.yml <<'EOF'
---
k8s_apt_channel:      "v1.33"
pause_image:          "registry.k8s.io/pause:3.10"
cni_bin_dir:          "/opt/cni/bin"
control_plane_ip:     "192.168.3.110"
cilium_chart_version: "1.17.1"   # check github.com/cilium/cilium/releases for current stable
EOF

cat > ansible/site.yml <<'EOF'
---
- name: Common prep on all nodes
  hosts: k8s_cluster
  roles: [common]

- name: Initialize control plane
  hosts: control_plane
  roles: [control_plane]

- name: Join workers
  hosts: workers
  roles: [worker]
EOF

cat > ansible/roles/common/handlers/main.yml <<'EOF'
---
- name: restart containerd
  ansible.builtin.systemd:
    name: containerd
    state: restarted
EOF

cat > ansible/roles/common/tasks/main.yml <<'EOF'
---
- name: Disable swap now
  ansible.builtin.command: swapoff -a
  changed_when: false

- name: Comment swap out of fstab
  ansible.builtin.replace:
    path: /etc/fstab
    regexp: '^([^#].*\s+swap\s+.*)$'
    replace: '# \1'

- name: Load kernel modules at boot
  ansible.builtin.copy:
    dest: /etc/modules-load.d/k8s.conf
    content: "overlay\nbr_netfilter\n"
    mode: "0644"

- name: Load modules now
  community.general.modprobe:
    name: "{{ item }}"
    state: present
  loop: [overlay, br_netfilter]

- name: Sysctl for k8s networking
  ansible.posix.sysctl:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-k8s.conf
    reload: true
  loop:
    - { name: net.bridge.bridge-nf-call-iptables,  value: "1" }
    - { name: net.bridge.bridge-nf-call-ip6tables, value: "1" }
    - { name: net.ipv4.ip_forward,                 value: "1" }

- name: Install containerd
  ansible.builtin.apt:
    name: containerd
    state: present
    update_cache: true

- name: Ensure /etc/containerd exists
  ansible.builtin.file:
    path: /etc/containerd
    state: directory
    mode: "0755"

- name: Default containerd config exists?
  ansible.builtin.stat:
    path: /etc/containerd/config.toml
  register: ctr_cfg

- name: Generate default containerd config
  ansible.builtin.shell: containerd config default > /etc/containerd/config.toml
  when: not ctr_cfg.stat.exists
  notify: restart containerd

- name: containerd uses systemd cgroup driver
  ansible.builtin.replace:
    path: /etc/containerd/config.toml
    regexp: 'SystemdCgroup = false'
    replace: 'SystemdCgroup = true'
  notify: restart containerd

- name: Align sandbox (pause) image
  ansible.builtin.replace:
    path: /etc/containerd/config.toml
    regexp: 'sandbox_image = .*'
    replace: 'sandbox_image = "{{ pause_image }}"'
  notify: restart containerd

- name: Point CNI bin_dir at ecosystem-standard path (the Debian scar)
  ansible.builtin.replace:
    path: /etc/containerd/config.toml
    regexp: 'bin_dir = "/usr/lib/cni"'
    replace: 'bin_dir = "{{ cni_bin_dir }}"'
  notify: restart containerd

- name: Enable + start containerd
  ansible.builtin.systemd:
    name: containerd
    enabled: true
    state: started

- name: k8s apt prerequisites
  ansible.builtin.apt:
    name: [apt-transport-https, ca-certificates, curl, gpg]
    state: present
    update_cache: true

- name: keyrings dir
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"

- name: Fetch kubernetes apt key
  ansible.builtin.get_url:
    url: "https://pkgs.k8s.io/core:/stable:/{{ k8s_apt_channel }}/deb/Release.key"
    dest: /etc/apt/keyrings/kubernetes-apt-keyring.asc
    mode: "0644"

- name: Dearmor key
  ansible.builtin.command:
    cmd: gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /etc/apt/keyrings/kubernetes-apt-keyring.asc
    creates: /etc/apt/keyrings/kubernetes-apt-keyring.gpg

- name: Add kubernetes apt repo
  ansible.builtin.apt_repository:
    repo: "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/{{ k8s_apt_channel }}/deb/ /"
    filename: kubernetes
    state: present

- name: Install kubelet/kubeadm/kubectl
  ansible.builtin.apt:
    name: [kubelet, kubeadm, kubectl]
    state: present
    update_cache: true

- name: Hold kube packages (upgrades are deliberate)
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop: [kubelet, kubeadm, kubectl]

- name: Enable kubelet
  ansible.builtin.systemd:
    name: kubelet
    enabled: true
EOF

cat > ansible/roles/control_plane/tasks/main.yml <<'EOF'
---
- name: Already initialized?
  ansible.builtin.stat:
    path: /etc/kubernetes/admin.conf
  register: admin_conf

- name: kubeadm init
  ansible.builtin.command: >
    kubeadm init
    --apiserver-advertise-address={{ control_plane_ip }}
    --control-plane-endpoint={{ control_plane_ip }}
  args:
    creates: /etc/kubernetes/admin.conf
  when: not admin_conf.stat.exists

- name: .kube dir for debian user
  ansible.builtin.file:
    path: /home/debian/.kube
    state: directory
    owner: debian
    group: debian
    mode: "0700"

- name: kubeconfig for debian user
  ansible.builtin.copy:
    src: /etc/kubernetes/admin.conf
    dest: /home/debian/.kube/config
    remote_src: true
    owner: debian
    group: debian
    mode: "0600"

- name: Fetch kubeconfig back to the opsbox (post-rebuild CA is new)
  ansible.builtin.fetch:
    src: /etc/kubernetes/admin.conf
    dest: "{{ playbook_dir }}/../kubeconfig"
    flat: true

- name: Install Helm
  ansible.builtin.shell: curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  args:
    creates: /usr/local/bin/helm

- name: Cilium helm repo
  kubernetes.core.helm_repository:
    name: cilium
    repo_url: https://helm.cilium.io/
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf

- name: Install Cilium (idempotent via Helm)
  kubernetes.core.helm:
    name: cilium
    chart_ref: cilium/cilium
    release_namespace: kube-system
    chart_version: "{{ cilium_chart_version }}"
    values:
      ipam:
        mode: cluster-pool
    wait: true
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf

- name: Generate a fresh join command (tokens expire ~24h)
  ansible.builtin.command: kubeadm token create --print-join-command
  register: join_command
  changed_when: false
EOF

cat > ansible/roles/worker/tasks/main.yml <<'EOF'
---
- name: Already joined?
  ansible.builtin.stat:
    path: /etc/kubernetes/kubelet.conf
  register: kubelet_conf

- name: Join the cluster
  ansible.builtin.command: "{{ hostvars[groups['control_plane'][0]].join_command.stdout }}"
  args:
    creates: /etc/kubernetes/kubelet.conf
  when: not kubelet_conf.stat.exists
EOF

echo "Scaffold written."
