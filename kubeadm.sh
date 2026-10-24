
#!/bin/bash

set -euo pipefail

DEBIAN_FRONTEND=noninteractive

# Ensure required binaries are available

command -v git >/dev/null || { echo "❌ git is not installed."; exit 1; }

#Install helm in background:
install_helm() {
if ! command -v helm >/dev/null 2>&1; then
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3;
chmod 700 get_helm.sh;
./get_helm.sh;
helm version;
fi
}
install_helm &

# Install containerd:

sudo apt-get update -qq;
sudo apt-get install -y -qq containerd;
if [ ! -f /etc/containerd/config.toml ]; then
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
fi

# Kubernetes settings as a drop-in (config.toml imports conf.d/*.toml):
# - systemd cgroup driver, matching kubelet
# - local image pull, so CRI pulls read registry mirrors from certs.d

sudo mkdir -p /etc/containerd/conf.d
cat <<'EOF' | sudo tee /etc/containerd/conf.d/10-k8s.toml >/dev/null
version = 3

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins.'io.containerd.cri.v1.images']
  use_local_image_pull = true
EOF
sudo systemctl restart containerd;
containerd --version;

#Install k8s components:
sudo apt-get update -qq;
sudo apt-get install -y apt-transport-https ca-certificates curl gpg;
sudo mkdir -p /etc/apt/keyrings;
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg;
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list;
sudo apt-get update -qq;
sudo apt-get install -y -qq kubelet kubeadm kubectl cri-tools;
sudo systemctl enable --now kubelet;
kubeadm version;

# Install bash-completion:

sudo apt-get install -qq bash-completion;

# Update bashrc file for auto-completion

if ! grep -q "### K8s autocompletion:" ~/.bashrc; then
cat <<'EOF' >> ~/.bashrc

### K8s autocompletion:

source /etc/bash_completion
source <(kubeadm completion bash)
source <(kubectl completion bash)
source <(helm completion bash)
source <(crictl completion bash)
export EDITOR=nano
EOF
fi

# echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> ~/.bashrc

# Load kernel modules:

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay;
sudo modprobe br_netfilter;

# Configure required sysctl to persist across system reboots:

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# apply the same

sudo sysctl --system;

# Overrride fs limits:

# Update /etc/sysctl.conf

sudo touch /etc/sysctl.conf;
sudo sed -i '/^fs\.inotify\.max_user_watches/d' /etc/sysctl.conf;
sudo sed -i '/^fs\.inotify\.max_user_instances/d' /etc/sysctl.conf;
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.conf;
echo "fs.inotify.max_user_instances=512"  | sudo tee -a /etc/sysctl.conf;

sudo sysctl --system;
sudo systemctl daemon-reload;

# Wait for Helm installation to complete before script exits

wait

# Print a command in italic cyan
cmd() { echo -e "\033[3;36m$*;\033[0m"; }

INSTALLED=$(kubeadm version -o short)
LATEST=$(curl -fsSL https://dl.k8s.io/release/stable.txt || true)
echo ""
echo "# Kubernetes installed: $INSTALLED"
if [[ -n "$LATEST" && "$(printf '%s\n' "$INSTALLED" "$LATEST" | sort -V | tail -1)" != "$INSTALLED" ]]; then
echo -e "\033[1;33m# Newer Kubernetes available: $LATEST\033[0m"
fi

echo ""
echo "# Next, create the cluster with:"
cmd "sudo kubeadm init --pod-network-cidr 192.168.0.0/16"

echo ""
echo "# Set up kubectl access for your user:"
cmd 'mkdir -p $HOME/.kube'
cmd 'sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config'
cmd 'sudo chown $(id -u):$(id -g) $HOME/.kube/config'

echo ""
echo "# Then install Calico networking:"
cmd "kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/operator-crds.yaml"
cmd "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/tigera-operator.yaml"
curl -LOs https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/custom-resources.yaml
cmd "kubectl apply -f custom-resources.yaml"

echo ""
echo "# To install Local Path Provisioner:"
cmd "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
cmd "kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class=true"

echo ""
echo "# Finally, remove the control-plane taint if you want to schedule pods on master:"
cmd 'kubectl taint node $(kubectl get nodes -o name) node-role.kubernetes.io/control-plane:NoSchedule-'

if curl -fsSL --max-time 30 -o containerd-registry.sh https://raw.githubusercontent.com/parthyadav3105/ops/refs/heads/main/containerd-registry.sh; then
chmod +x containerd-registry.sh
echo ""
echo "# Optional: set up a registry mirror or credentials with ./containerd-registry.sh (-h for help):"
echo "#   ./containerd-registry.sh docker.io --mirror harbor.example.com/dockerhub-proxy -u myuser"
echo "#   ./containerd-registry.sh harbor.example.com -u myuser"
fi
echo ""

