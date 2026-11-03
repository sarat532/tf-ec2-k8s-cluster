#!/bin/bash

set -eou pipefail

# This script sets up the Kubernetes master node on an EC2 instance running on Amazon Linux 2023.
echo "Starting Kubernetes master node setup..."

# Set the hostname for the master node
hostnamectl set-hostname k8s-master
IMDS_TOKEN=$(curl --fail --silent --show-error -X PUT \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
MASTER_PRIVATE_IP=$(curl --fail --silent --show-error \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
printf '%s\t%s\n' "$MASTER_PRIVATE_IP" "k8s-master" >> /etc/hosts

# Disable swap persistently across reboots (Kubernetes requires swap to be disabled)
echo "Disabling swap..."
sed -i '/swap/d' /etc/fstab || swapoff -a
echo "swap disabled."

# Update the system and install necessary packages
echo "Updating system and installing necessary packages..."
dnf update -y
dnf install -y git wget vim python3

# Load modules required by Kubernetes
echo "Loading required kernel modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params without reboot
sysctl --system

# Install containerd
echo "Installing containerd..."
dnf install -y containerd

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable --now containerd

# Set SELinux in permissive mode (effectively disabling it)
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# Add Kubernetes repository
# This overwrites any existing configuration in /etc/yum.repos.d/kubernetes.repo
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${k8s_version}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${k8s_version}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# Add the Kubernetes repository to DNF configuration
dnf config-manager --add-repo=/etc/yum.repos.d/kubernetes.repo

# Install Kubernetes components
echo "Installing Kubernetes components..."
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

# Enable and start kubelet service
systemctl enable --now kubelet

# Initialize the Kubernetes master node
echo "Initializing Kubernetes master node..."
kubeadm init --pod-network-cidr=172.16.0.0/16

# Create a short-lived join command and expose it only to workers through the
# security-group-restricted endpoint on port 8080.
JOIN_COMMAND=$(kubeadm token create --ttl 30m --print-join-command)
umask 077
printf '%s\n' "$JOIN_COMMAND" > /tmp/k8s-join-command.sh

cat > /tmp/k8s-join-command-server.py <<'PYTHON'
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import time

COMMAND_PATH = Path("/tmp/k8s-join-command.sh")


class JoinCommandHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/join-command":
            self.send_error(404)
            return

        try:
            command = COMMAND_PATH.read_bytes()
        except OSError:
            self.send_error(503)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(command)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(command)

    def log_message(self, format, *args):
        pass


server = HTTPServer(("0.0.0.0", 8080), JoinCommandHandler)
server.timeout = 1
deadline = time.monotonic() + 1800
try:
    while time.monotonic() < deadline:
        server.handle_request()
finally:
    server.server_close()
    COMMAND_PATH.unlink(missing_ok=True)
PYTHON

nohup python3 /tmp/k8s-join-command-server.py >/var/log/k8s-join-command-server.log 2>&1 </dev/null &
JOIN_SERVER_PID=$!
JOIN_SERVER_READY=0
for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8080/join-command --output /dev/null; then
    JOIN_SERVER_READY=1
    break
  fi
  if ! kill -0 "$JOIN_SERVER_PID" 2>/dev/null; then
    echo "Join-command endpoint failed to start; see /var/log/k8s-join-command-server.log." >&2
    exit 1
  fi
  sleep 1
done
if [ "$JOIN_SERVER_READY" -ne 1 ]; then
  echo "Join-command endpoint did not become ready." >&2
  exit 1
fi

# Set up kubeconfig for the root user
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Set up kubeconfig for the ec2-user
mkdir -p /home/ec2-user/.kube
cp -i /etc/kubernetes/admin.conf /home/ec2-user/.kube/config
chown ec2-user:ec2-user /home/ec2-user/.kube/config

# Install a pod network add-on (Calico)
echo "Installing Calico network add-on..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/v3_projectcalico_org.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/custom-resources.yaml

# Modify the Calico custom resources to set the pod network CIDR
sed -i 's/192.168.0.0/172.16.0.0/' custom-resources.yaml
kubectl apply -f custom-resources.yaml

# Add the standard worker role label once each worker has registered.
if [ "${worker_count}" -gt 0 ]; then
  SECONDS=0
  for worker_index in $(seq 0 $((${worker_count} - 1))); do
    WORKER_NODE="k8s-worker-$${worker_index}"
    until kubectl get node "$WORKER_NODE" >/dev/null 2>&1; do
      if [ "$SECONDS" -ge 1800 ]; then
        echo "Timed out waiting for worker node $WORKER_NODE to register." >&2
        exit 1
      fi
      echo "Waiting for worker node $WORKER_NODE to register..."
      sleep 5
    done
    kubectl label node "$WORKER_NODE" node-role.kubernetes.io/worker="" --overwrite
  done
fi

echo "Kubernetes master node setup complete."