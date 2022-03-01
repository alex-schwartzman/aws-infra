locals {
  autoscaling_tags = {
    "k8s.io/cluster-autoscaler/enabled"                      = true,
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.this.name}" = "owned"
  }
}

###########################################
# EKS cluster
###########################################

resource "aws_eks_cluster" "this" {
  name     = var.eks.cluster.name
  role_arn = aws_iam_role.eks.arn
  version  = var.eks.cluster.master_k8s_version

  vpc_config {
    subnet_ids              = module.vpc.public_subnets
    public_access_cidrs     = ["0.0.0.0/0"]
    endpoint_private_access = true
  }

  kubernetes_network_config { service_ipv4_cidr = var.eks.cluster.cidr_block }
  depends_on = [aws_iam_role_policy_attachment.AmazonEKSClusterPolicy, ]
}

resource "aws_eks_node_group" "this" {
  for_each        = var.eks.node_group
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.value.name
  version         = each.value.k8s_version
  node_role_arn   = aws_iam_role.eks.arn
  subnet_ids      = module.vpc.private_subnets
  instance_types  = [each.value.machine_type]
  capacity_type   = each.value.capacity_type
  labels          = each.value.labels
  tags            = merge(each.value.tags, tomap(local.autoscaling_tags))

  launch_template {
    name    = aws_launch_template.eks[each.key].name
    version = aws_launch_template.eks[each.key].latest_version
  }

  scaling_config {
    desired_size = each.value.machine_count
    min_size     = each.value.machine_min
    max_size     = each.value.machine_max
  }

  depends_on = [
    aws_eks_cluster.this,
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
  ]

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }
  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}

data "cloudinit_config" "eks" {
  for_each = var.eks.node_group
  gzip     = false

  part {
    content_type = "text/x-shellscript"
    content = templatefile("files/user_data/eks-nodes-userdata.template.sh", {
      taints = each.value.taints
    })
    filename = "eks-init.sh"
  }
}

resource "aws_launch_template" "eks" {
  depends_on             = [kubernetes_config_map.aws-auth]
  for_each               = var.eks.node_group
  name                   = "eks-${each.key}"
  user_data              = data.cloudinit_config.eks[each.key].rendered
  vpc_security_group_ids = [aws_eks_cluster.this.vpc_config.0.cluster_security_group_id, aws_security_group.ec2.id]
  ebs_optimized          = true
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs { volume_size = 50 }
  }
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "eks-${each.key}"
    }
  }
}

###########################################
# EKS IAM
###########################################

resource "aws_iam_role" "eks" {
  assume_role_policy = file("files/policies/eks-role.json")
  name               = "eks"
}

resource "aws_iam_role_policy_attachment" "AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks.name
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks.name
}

resource "kubernetes_config_map" "aws-auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }
  data = {
    "mapRoles" = yamlencode([
      {
        groups   = ["system:bootstrappers", "system:nodes"],
        rolearn  = aws_iam_role.eks.arn,
        username = "system:node:{{EC2PrivateDNSName}}"
      }
    ])
  }
}

data "tls_certificate" "oidc" { url = aws_eks_cluster.this.identity[0].oidc[0].issuer }

resource "aws_iam_openid_connect_provider" "oidc" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

###########################################
# VPC
###########################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.11.0"

  name = "ukraine-vpc"
  cidr = "10.0.0.0/16"

  azs             = var.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  manage_default_vpc  = false
  enable_dhcp_options = false

  enable_nat_gateway  = true
  reuse_nat_ips       = true
  external_nat_ip_ids = aws_eip.this.*.id
  external_nat_ips    = aws_eip.this.*.address

  create_database_subnet_group = true

  tags = { Terraform = "true" }
  //EKS Node group requirement
  public_subnet_tags  = { "kubernetes.io/cluster/${var.eks.cluster.name}" = "shared" }
  private_subnet_tags = { "kubernetes.io/cluster/${var.eks.cluster.name}" = "shared" }
}

resource "aws_eip" "this" {
  count = 3
}

resource "aws_security_group" "ec2" {
  name        = "ukraine-ec2"
  description = "Allows Load balancers and bastion"
  vpc_id      = module.vpc.vpc_id

  //SSH
  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}
