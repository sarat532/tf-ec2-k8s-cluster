#!/bin/bash

set -eou pipefail

# This script sets up the Kubernetes worker node on an EC2 instance running on Amazon Linux 2023.
echo "Starting Kubernetes worker node setup..."

# Set the hostname for the worker node
hostnamectl set-hostname k8s-worker-${worker_index}
IMDS_TOKEN=$(curl --fail --silent --show-error -X PUT \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
WORKER_PRIVATE_IP=$(curl --fail --silent --show-error \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
printf '%s\t%s\n' "$WORKER_PRIVATE_IP" "k8s-worker-${worker_index}" >> /etc/hosts

# Disable swap persistently across reboots (Kubernetes requires swap to be disabled)
echo "Disabling swap..."
sed -i '/swap/d' /etc/fstab || swapoff -a
echo "swap disabled."

# Update the system and install necessary packages
echo "Updating system and installing necessary packages..."
dnf update -y
dnf install -y git wget vim

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
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
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
dnf install -y kubelet kubeadm --disableexcludes=kubernetes

# Enable and start kubelet service
systemctl enable --now kubelet

# Poll the master's private, worker-restricted endpoint until its join command is ready.
MASTER_PRIVATE_IP="${master_private_ip}"
JOIN_URL="http://$MASTER_PRIVATE_IP:25000/join-command"
JOIN_COMMAND=""
SECONDS=0
while [ "$SECONDS" -lt 1800 ]; do
  if JOIN_COMMAND=$(curl --connect-timeout 3 --max-time 5 --fail --silent "$JOIN_URL"); then
    break
  fi
  echo "Waiting for the master join-command endpoint..."
  sleep 5
done

if [ -z "$JOIN_COMMAND" ]; then
  echo "Timed out waiting for the master join command." >&2
  exit 1
fi

read -r command join endpoint token_flag token_value ca_hash_flag ca_hash extra <<< "$JOIN_COMMAND"
if [ "$command" != "kubeadm" ] ||
  [ "$join" != "join" ] ||
  [ "$endpoint" != "$MASTER_PRIVATE_IP:6443" ] ||
  [ "$token_flag" != "--token" ] ||
  [ "$ca_hash_flag" != "--discovery-token-ca-cert-hash" ] ||
  [ -n "$extra" ] ||
  ! [[ "$token_value" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] ||
  ! [[ "$ca_hash" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "Received an invalid join command from the master." >&2
  exit 1
fi

echo "Joining the Kubernetes cluster..."
kubeadm join "$endpoint" --token "$token_value" \
  --discovery-token-ca-cert-hash "$ca_hash"