# Terraform Kubernetes Cluster on AWS EC2

This repository uses Terraform to create a small Kubernetes cluster on Amazon
EC2: one control-plane (master) node and one or more worker nodes. Terraform
creates the VPC, two subnets, routing, security groups, and instances. EC2
user-data scripts install Kubernetes with `kubeadm`, initialize the control
plane, join the workers, and install Calico as the pod network.

The examples are intended as a learning starting point. Review the security
group rules, AWS costs, and Kubernetes/Amazon Linux compatibility before using
this in a production environment.

## Prerequisites

- An AWS account and an AWS CLI named profile with permissions to describe
  Amazon Linux AMIs and create/manage EC2 instances, key pairs, VPCs, subnets,
  route tables, internet gateways, and security groups.
- AWS CLI installed and configured. For example:

  ```sh
  aws configure --profile k8s-admin
  aws sts get-caller-identity --profile k8s-admin
  ```

  An IAM user credential or an assumed IAM role can back this profile. Use
  least-privilege permissions appropriate for the resources in this project;
  do not put AWS access keys in Terraform files.
- Terraform CLI `~> 1.17.1`.
- OpenSSH tools, including `ssh-keygen` and `ssh`, to create a key pair and
  connect to the instances.
- A region with the configured availability zones available. The current
  subnet list is `ap-south-1a` and `ap-south-1b`; update it in `vpc.tf` when
  deploying in a different region.

## 1. Terraform providers: `_providers.tf`

The providers file requires Terraform `~> 1.17.1`, the AWS provider
`~> 6.71.0`, and the Random provider `~> 3.7.0`. AWS resources are created in
the region and with the AWS CLI profile selected by the Terraform variables.
Terraform downloads provider plugins when you initialize the working
directory.

## 2. Variables: `_variables.tf`

All declared input variables have defaults, so you can start without supplying
your own values. The variables are:

| Variable | Default | Purpose |
|---|---|---|
| `aws_region` | `ap-south-1` | AWS region for the cluster |
| `aws_profile` | `account-admin` | AWS CLI profile Terraform uses |
| `project_name` | `tf-ec2-k8s-cluster` | Prefix for resource names and tags |
| `vpc_cidr` | `10.190.32.0/26` | CIDR block allocated to the VPC |
| `instance_type` | `t3a.medium` | EC2 instance type for master and workers |
| `worker_count` | `2` | Number of worker instances |
| `k8s_version` | `1.36` | Kubernetes package repository version |

Change a default in `_variables.tf` if it should apply to every use of this
configuration, or override it locally with `terraform.tfvars`.

## 3. Optional local configuration: `terraform.tfvars`

To customize settings for your AWS account, create a `terraform.tfvars` file in
the repository root. It is ignored by Git because it can contain
account-specific configuration. For example:

```hcl
aws_profile  = "k8s-admin"
aws_region   = "ap-south-1"
project_name = "learning-k8s"
vpc_cidr     = "10.190.32.0/26"
instance_type = "t3a.medium"
worker_count  = 2
k8s_version  = "1.36"
```

The profile name must match a profile configured in your AWS CLI credentials
and config files. Ensure the VPC CIDR does not overlap with networks you need
to connect to. The sample values are examples; choose values appropriate for
your account and region.

## 4. VPC, subnets, and security groups: `vpc.tf`

The VPC file creates:

- A VPC with DNS support and DNS hostnames enabled.
- Two subnets, one in each configured availability zone. The VPC CIDR is split
  into two subnet CIDRs.
- An internet gateway, route table, and default route for outbound internet
  access.
- Separate security groups for the control-plane and workers.

The ingress ports are declared in local lists near the top of `vpc.tf` and
turned into security-group rules:

| Node | Inbound ports/protocols | Purpose |
|---|---|---|
| Control-plane | TCP 6443 | Kubernetes API server |
| Control-plane | TCP 2379-2380 | etcd |
| Control-plane | TCP 10250 | Kubelet API |
| Control-plane | TCP 10259 | kube-scheduler |
| Control-plane | TCP 10257 | kube-controller-manager |
| Control-plane | TCP 22 | SSH |
| Control-plane | TCP 80 | HTTP (the current scripts do not install a web server) |
| Worker | TCP 10250 | Kubelet API |
| Worker | TCP and UDP 30000-32767 | Kubernetes NodePort services |
| Worker | TCP 10256 | kube-proxy |
| Worker | TCP 22 | SSH |
| Control-plane | TCP 25000 from the worker security group | Temporary join-command endpoint |

The current general ingress rules use `0.0.0.0/0`, and the instances receive
public IP addresses. This exposes sensitive Kubernetes and SSH ports publicly.
Before applying this configuration, restrict SSH to your trusted IP range and
restrict Kubernetes control-plane and node ports to the required cluster
networks or security groups. Port 25000 is separately restricted to instances
in the worker security group. Both security groups currently allow all
outbound traffic.

## 5. EC2 instances and subnets: `ec2.tf`

The EC2 configuration registers a public key as an AWS key pair, looks up the
latest matching Amazon Linux 2023 x86_64 AMI via `data.tf`, and creates the
instances with their respective security groups and user-data scripts.

This repository does not include the matching SSH key pair. From the
repository root, create one with:

```sh
ssh-keygen -t rsa -b 4096 -f ec2-k8s
```

This creates `ec2-k8s` (the private key) and `ec2-k8s.pub` (the public key).
Terraform reads `ec2-k8s.pub`; use the private key to SSH into the EC2
instances. Keep the private key secret and do not commit it. The repository
ignores the generated key files.

The `random_integer` resource chooses the control-plane subnet index. The
workers are assigned to the other subnet, so the control-plane and workers
are in different subnets without hard-coding which subnet the master uses.
All workers share that other subnet. The random choice is kept in Terraform
state and does not change on every plan.

Terraform passes `k8s_version` and `worker_count` to the master script. It
passes `k8s_version`, the master private IP, and each worker's index to the
worker script. The private IP lets each worker contact the master over the
VPC.

The root `outputs.tf` exposes the master's public IP, the worker public IPs,
and an SSH command for the master. Terraform displays these after applying;
you can also retrieve them later with `terraform output`.

## 6. Master and worker bootstrap scripts

Terraform supplies these scripts as EC2 user-data. User-data runs during
instance initialization, normally as root. The scripts use `set -e`; an
unhandled command failure stops the script. Check the EC2 system log or
`/var/log/cloud-init-output.log` on the instance if setup does not finish.

### Master: `scripts/k8s-master.sh`

1. **Hostname and local name resolution:** Sets the hostname to `k8s-master`,
   obtains the private IP using EC2 Instance Metadata Service v2 (IMDSv2), and
   adds the hostname/IP mapping to `/etc/hosts`.
2. **Disable swap:** Removes swap entries from `/etc/fstab` and disables swap
   for Kubernetes.
3. **System packages and networking:** Updates the operating system, installs
   utility packages and Python, and enables IPv4 forwarding through sysctl.
4. **Container runtime:** Installs and enables `containerd`, which runs
   Kubernetes containers.
5. **SELinux:** Sets SELinux to permissive mode for this setup.
6. **Kubernetes repository and packages:** Configures the Kubernetes package
   repository using `k8s_version`, installs `kubelet`, `kubeadm`, and
   `kubectl`, then enables kubelet.
7. **Initialize the control plane:** Runs `kubeadm init` with the pod CIDR
   `172.16.0.0/16`, then configures `/root/.kube/config` and
   `/home/ec2-user/.kube/config` from `/etc/kubernetes/admin.conf`. The
   bootstrap uses that admin config explicitly, independent of the `HOME`
   environment variable.
8. **Expose the worker join command:** Creates a kubeadm bootstrap token with
   a 30-minute TTL and writes the generated join command to
   `/tmp/k8s-join-command.sh`. A small Python HTTP server temporarily serves
   it at `/join-command` on port 25000. The security group permits this port
   only from the worker security group. The server stops after 30 minutes and
   removes the temporary command file. The join token is sensitive; do not
   expose this endpoint to untrusted networks.
9. **Install Calico:** Applies Calico manifests and configures the pod network
   CIDR to `172.16.0.0/16`.
10. **Label worker roles:** Waits for each expected worker node to register,
    then applies the `node-role.kubernetes.io/worker` label. The `control-plane`
    role is assigned to the control-plane node by kubeadm.

### Worker: `scripts/k8s-worker.sh`

1. **Hostname and local name resolution:** Sets a unique hostname
   (`k8s-worker-0`, `k8s-worker-1`, etc.) and adds its private IP and hostname
   to `/etc/hosts`.
2. **Disable swap and configure networking:** Disables swap and enables IPv4
   forwarding, as on the control-plane.
3. **Install prerequisites and container runtime:** Updates the system,
   installs utilities, installs `containerd`, and enables the service.
4. **Configure SELinux and Kubernetes packages:** Sets SELinux to permissive,
   configures the repository for `k8s_version`, then installs and enables
   `kubelet` and `kubeadm`.
5. **Join the cluster:** Polls the master's private IP for the join command,
   waiting up to 30 minutes for the endpoint to become available. It validates
   the response before passing its values to `kubeadm join`.

   The `read` command splits the received text into fields such as the command
   name, API-server address, token, and CA certificate hash. The following
   `if` block checks that it is the expected `kubeadm join` command, that the
   endpoint matches this cluster's master private IP, and that the token and
   hash have the expected formats; it also rejects extra fields. This prevents
   the worker from blindly executing arbitrary text received over HTTP. After
   validation, the script passes the fields as arguments to `kubeadm join`
   rather than evaluating the response as shell code.

## 7. Deploy and verify

Run these commands from the repository root:

```sh
terraform init
terraform validate
terraform plan
terraform apply
```

Review the plan before confirming `terraform apply`. Instance initialization
continues after Terraform reports that EC2 instances have been created; allow
time for the user-data scripts to finish. Terraform prints the IP outputs and
SSH command after apply. Retrieve them later with:

```sh
terraform output master_public_ip
terraform output worker_public_ips
terraform output -raw master_ssh_command
```

Copy and run the command printed by `terraform output -raw
master_ssh_command` to connect to the control-plane. Once connected, verify
the cluster with:

```sh
kubectl get nodes -o wide
```

Wait until all nodes are `Ready`; the `ROLES` column should show `control-plane`
for the master and `worker` for worker nodes. If a node does not join, check
the user-data logs on that instance and confirm the join endpoint is reachable
from the worker.

If `kubectl` reports that the API server cannot find a requested resource,
check that it is using the admin kubeconfig rather than its default
`http://localhost:8080` endpoint:

```sh
sudo env KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
ls -l /root/.kube/config /home/ec2-user/.kube/config
sudo tail -n 100 /var/log/cloud-init-output.log
```

To remove the resources created by this configuration when finished:

```sh
terraform destroy
```

Review the destroy plan before confirming. This deletes the cluster
infrastructure and the EC2 instances.

## Kubernetes version

The defaults in this repository target Kubernetes `1.36`, set by the
`k8s_version` Terraform variable. You can override it in `terraform.tfvars`.
Changing this value changes the package repository used by the bootstrap
scripts; it does not guarantee that every Kubernetes version is compatible
with the current Amazon Linux image, container runtime, or Calico manifests.
The Calico manifest version is pinned separately in the master script.
Before using another Kubernetes version, verify that version's installation
steps, supported packages, and network-plugin compatibility.

## References

- [Ports and Protocols | Kubernetes](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
- [Creating a cluster with kubeadm | Kubernetes](https://v1-36.docs.kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Installing kubeadm | Kubernetes](https://v1-36.docs.kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Installing on on-premises deployments | Calico Documentation](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises)
