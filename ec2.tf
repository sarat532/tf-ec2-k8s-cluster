## EC2 key pair
resource "aws_key_pair" "ec2-k8s" {
  key_name   = "${var.project_name}-keypair"
  public_key = file("${path.module}/ec2-k8s.pub")
}

resource "random_integer" "master_subnet_index" {
  min = 0
  max = length(local.availability_zones) - 1
}

## EC2 master node
resource "aws_instance" "ec2-k8s-master" {
  ami                         = data.aws_ami.ec2-k8s.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.ec2-k8s.key_name
  subnet_id                   = aws_subnet.ec2-k8s[random_integer.master_subnet_index.result].id
  vpc_security_group_ids      = [aws_security_group.ec2-k8s-master.id]
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/scripts/k8s-master.sh", {
    k8s_version  = var.k8s_version
    worker_count = var.worker_count
  })

  tags = {
    Name = "${var.project_name}-master"
  }
}

## EC2 worker nodes
resource "aws_instance" "ec2-k8s-worker" {
  count                       = var.worker_count
  ami                         = data.aws_ami.ec2-k8s.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.ec2-k8s.key_name
  subnet_id                   = aws_subnet.ec2-k8s[1 - random_integer.master_subnet_index.result].id
  vpc_security_group_ids      = [aws_security_group.ec2-k8s-worker.id]
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/scripts/k8s-worker.sh", {
    k8s_version       = var.k8s_version
    master_private_ip = aws_instance.ec2-k8s-master.private_ip
    worker_index      = count.index
  })

  tags = {
    Name = "${var.project_name}-worker-${count.index}"
  }
}