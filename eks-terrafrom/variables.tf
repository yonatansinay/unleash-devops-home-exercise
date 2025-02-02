variable "region" {
  type        = string
  default     = "us-west-2"
  description = "The AWS region to deploy into."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VPC."
}

variable "cluster_name" {
  type        = string
  default     = "yonatan-cluster"
  description = "Name of the EKS cluster."
}

variable "desired_capacity" {
  type        = number
  default     = 2
  description = "Desired number of worker nodes in the managed node group."
}
