locals {
  availability_zones = ["ap-south-1a", "ap-south-1b"]

  master_ingress_ports = [
    {
      from_port   = 6443
      to_port     = 6443
      protocol    = "tcp"
      description = "Kubernetes API server"
    },
    {
      from_port   = 2379
      to_port     = 2380
      protocol    = "tcp"
      description = "etcd"
    },
    {
      from_port   = 10250
      to_port     = 10250
      protocol    = "tcp"
      description = "Kubelet API"
    },
    {
      from_port   = 10259
      to_port     = 10259
      protocol    = "tcp"
      description = "kube-scheduler"
    },
    {
      from_port   = 10257
      to_port     = 10257
      protocol    = "tcp"
      description = "kube-controller-manager"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH"
    },
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP"
    }
  ]

  worker_ingress_ports = [
    {
      from_port   = 10250
      to_port     = 10250
      protocol    = "tcp"
      description = "kubelet API"
    },
    {
      from_port   = 30000
      to_port     = 32767
      protocol    = "tcp"
      description = "NodePort Services TCP"
    },
    {
      from_port   = 30000
      to_port     = 32767
      protocol    = "udp"
      description = "NodePort Services UDP"
    },
    {
      from_port   = 10256
      to_port     = 10256
      protocol    = "tcp"
      description = "kube-proxy"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH"
    }
  ]
}

## Create a VPC with the specified CIDR block
resource "aws_vpc" "ec2-k8s" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

### Create an Internet Gateway for the VPC
resource "aws_internet_gateway" "ec2-k8s" {
  vpc_id = aws_vpc.ec2-k8s.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

### Create a route table for the VPC
resource "aws_route_table" "ec2-k8s" {
  vpc_id = aws_vpc.ec2-k8s.id

  route {
    cidr_block = var.vpc_cidr
    gateway_id = "local"
  }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ec2-k8s.id
  }

  tags = {
    Name = "${var.project_name}-route-table"
  }
}

## Associate the route table with the subnets
resource "aws_route_table_association" "ec2-k8s" {
  count          = length(local.availability_zones)
  subnet_id      = aws_subnet.ec2-k8s[count.index].id
  route_table_id = aws_route_table.ec2-k8s.id
}

## Create subnets in the specified availability zones
resource "aws_subnet" "ec2-k8s" {
  count             = length(local.availability_zones)
  vpc_id            = aws_vpc.ec2-k8s.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 1, count.index)
  availability_zone = local.availability_zones[count.index]

  tags = {
    Name = "${var.project_name}-subnet-${count.index}"
  }
}

## Master node security group
resource "aws_security_group" "ec2-k8s-master" {
  name        = "${var.project_name}-master-sg"
  description = "Security group for the master node"
  vpc_id      = aws_vpc.ec2-k8s.id

  tags = {
    Name = "${var.project_name}-master-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ec2-k8s-master" {
  for_each = {
    for rule in local.master_ingress_ports : rule.description => rule
  }

  security_group_id = aws_security_group.ec2-k8s-master.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.protocol
  description       = each.value.description
}

resource "aws_vpc_security_group_egress_rule" "ec2-k8s-master" {
  security_group_id = aws_security_group.ec2-k8s-master.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

## Worker node security group
resource "aws_security_group" "ec2-k8s-worker" {
  name        = "${var.project_name}-worker-sg"
  description = "Security group for the worker nodes"
  vpc_id      = aws_vpc.ec2-k8s.id

  tags = {
    Name = "${var.project_name}-worker-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "master_join_command_from_workers" {
  security_group_id            = aws_security_group.ec2-k8s-master.id
  referenced_security_group_id = aws_security_group.ec2-k8s-worker.id
  from_port                    = 25000
  to_port                      = 25000
  ip_protocol                  = "tcp"
  description                  = "Temporary Kubernetes join command endpoint from workers"
}

resource "aws_vpc_security_group_ingress_rule" "ec2-k8s-worker" {
  for_each = {
    for rule in local.worker_ingress_ports : rule.description => rule
  }

  security_group_id = aws_security_group.ec2-k8s-worker.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.protocol
  description       = each.value.description
}

resource "aws_vpc_security_group_egress_rule" "ec2-k8s-worker" {
  security_group_id = aws_security_group.ec2-k8s-worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}