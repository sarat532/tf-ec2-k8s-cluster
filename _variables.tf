## Global/generic variables

variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "The AWS profile to use for authentication."
  type        = string
  default     = "account-admin"
}

variable "project_name" {
  description = "The name of the project."
  type        = string
  default     = "tf-ec2-k8s-cluster"
}

## VPC specific variables
variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
  default     = "10.190.32.0/26"
}

## EC2 specific variables
variable "instance_type" {
  description = "The type of EC2 instance to launch."
  type        = string
  default     = "t3a.medium"
}

variable "worker_count" {
  description = "The number of worker nodes to launch."
  type        = number
  default     = 2
}

variable "k8s_version" {
  description = "The version of Kubernetes to install."
  type        = string
  default     = "1.36"
}