########################################
# 1. Terraform Settings & AWS Provider
########################################
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "current" {}

########################################
# 2. Networking - VPC, Subnets, Gateways
########################################

# Create a yonatan VPC
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "yontan-vpc"
  }
}

# Create two public subnets
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, count.index)
  availability_zone       = data.aws_availability_zones.current.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-${count.index}"
  }
}

# Create two private subnets
# Here we use newbits = 2 and offset by 2 so that the public subnets (netnums 0 and 1)
# do not overlap with the private subnets (netnums 2 and 3)
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, count.index + 2)
  availability_zone       = data.aws_availability_zones.current.names[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name = "private-subnet-${count.index}"
  }
}

# Create an Internet Gateway for the VPC
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "yonatan-igw"
  }
}

# Create a public route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = {
    Name = "public-rt"
  }
}

# Associate public subnets with the public route table
resource "aws_route_table_association" "public_association" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Allocate an Elastic IP for the NAT Gateway
resource "aws_eip" "nat_eip" {
  vpc = true
  tags = {
    Name = "nat-eip"
  }
}

# Create a NAT Gateway in the first public subnet
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public[0].id
  tags = {
    Name = "yonatan-nat-gw"
  }
}

# Create a private route table that routes internet traffic through the NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = {
    Name = "private-rt"
  }
}

# Associate private subnets with the private route table
resource "aws_route_table_association" "private_association" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

########################################
# 3. EKS Cluster with Managed Node Groups
########################################

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.32"
  vpc_id          = aws_vpc.this.id

  # Provide both the subnets (used for control plane and node groups)
  control_plane_subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  # Create managed node groups
  eks_managed_node_groups = {
    default = {
      desired_capacity = var.desired_capacity
      max_capacity     = var.desired_capacity
      min_capacity     = 1
      instance_types   = ["t3.medium"]
      # Optional: explicitly specify the subnets for the node group
      subnet_ids       = [for subnet in aws_subnet.private : subnet.id]
    }
  }

  # Control the accessibility of the cluster endpoint
  cluster_endpoint_private_access = false
  cluster_endpoint_public_access  = true

  tags = {
    Environment = "dev"
    Project     = "unleash-devops"
  }
}

###############################################################################
# DATA SOURCES
###############################################################################

# Retrieve the OIDC provider for your EKS cluster.
# This assumes that your EKS module exports the OIDC provider ARN.
# If your cluster does not have an OIDC provider, this data source will fail.
data "aws_iam_openid_connect_provider" "oidc" {
  # Replace with your OIDC provider ARN if not using the EKS module output.
  arn = module.eks.oidc_provider_arn
}

###############################################################################
# IAM POLICY
###############################################################################

# Create an IAM policy that grants read-only access to a specific S3 bucket.
# This policy allows the actions "s3:GetObject" and "s3:ListBucket".
resource "aws_iam_policy" "s3_policy" {
  name        = "unleash-app-s3-policy"
  description = "Policy granting read-only access to S3 bucket for the Unleash app"
  policy      = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        # Replace "my-s3-bucket" with the name of your bucket.
        Resource = [
          "arn:aws:s3:::my-s3-bucket",
          "arn:aws:s3:::my-s3-bucket/*"
        ]
      }
    ]
  })
}

###############################################################################
# IAM ROLE FOR IRSA
###############################################################################

# Create an IAM role that your Kubernetes ServiceAccount can assume.
# This role will be used with IRSA (IAM Roles for Service Accounts).
resource "aws_iam_role" "unleash_app_irsa_role" {
  name = "unleash-app-irsa-role"

  # The assume_role_policy defines who is allowed to assume this role.
  # Here, we allow a federated principal (your EKS cluster's OIDC provider)
  # to assume this role if the request comes from the specified Kubernetes
  # ServiceAccount.
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = {
          # Allow the OIDC provider (federated identity) to assume the role.
          Federated = data.aws_iam_openid_connect_provider.oidc.arn
        },
        Action    = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            # This condition ensures that only the specified ServiceAccount can assume
            # the role. Replace "default" with your namespace if needed,
            # and "unleash-app-sa" with your ServiceAccount name.
            "${replace(data.aws_iam_openid_connect_provider.oidc.url, "https://", "")}:sub" = "system:serviceaccount:default:unleash-app-sa"
          }
        }
      }
    ]
  })
}

###############################################################################
# IAM ROLE POLICY ATTACHMENT
###############################################################################

# Attach the S3 read-only policy to the IAM role we just created.
resource "aws_iam_role_policy_attachment" "attach_s3_policy" {
  role       = aws_iam_role.unleash_app_irsa_role.name
  policy_arn = aws_iam_policy.s3_policy.arn
}