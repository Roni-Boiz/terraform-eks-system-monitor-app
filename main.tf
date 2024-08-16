data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "system-monitor-cluster-role" {
  name               = "eks-cluster-system-monitor-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "system-monitor-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.system-monitor-cluster-role.name
}

resource "aws_iam_role_policy_attachment" "system-monitor-AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.system-monitor-cluster-role.name
}

# Get default VPC
data "aws_vpc" "default" {
    default = true
}

# Get public subnets
data "aws_subnets" "public" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
}

# Create EKS cluster
resource "aws_eks_cluster" "system-monitor-cluster" {
  name     = "cloud-native-system-monitor-cluster"
  role_arn = aws_iam_role.system-monitor-cluster-role.arn
  version = "1.25"

  vpc_config {
    subnet_ids = data.aws_subnets.public.ids
  }

  depends_on = [
    aws_iam_role_policy_attachment.system-monitor-AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.system-monitor-AmazonEKSVPCResourceController,
  ]
}

resource "aws_iam_role" "system-monitor-node-role" {
  name = "eks-cluster-system-monitor-node-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "system-monitor-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.system-monitor-node-role.name
}

resource "aws_iam_role_policy_attachment" "system-monitor-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.system-monitor-node-role.name
}

resource "aws_iam_role_policy_attachment" "system-monitor-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.system-monitor-node-role.name
}

# Policy for ECR Access
resource "aws_iam_role_policy" "ecr_access_policy" {
  name   = "ECRAccessPolicy"
  role   = aws_iam_role.system-monitor-node-role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ],
        Resource = "arn:aws:ecr:region:account-id:repository/repository-name"
      },
      {
        Effect = "Allow",
        Action = [
          "ecr:GetAuthorizationToken",
        ],
        Resource = "*"
      },
    ],
  })
}

# Create EKS node group
resource "aws_eks_node_group" "system-monitor-node" {
  cluster_name    = aws_eks_cluster.system-monitor-cluster.name
  node_group_name = "cloud-native-system-monitor-node"
  version         = aws_eks_cluster.system-monitor-cluster.version
  node_role_arn   = aws_iam_role.system-monitor-node-role.arn
  subnet_ids      = data.aws_subnets.public.ids

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = [ "t2.micro" ]

  depends_on = [
    aws_iam_role_policy_attachment.system-monitor-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.system-monitor-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.system-monitor-AmazonEC2ContainerRegistryReadOnly,
  ]
}

resource "aws_ecr_repository" "system_monitor_app" {
  name                 = "system_monitor_app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "null_resource" "update_kubeconfig" {
  provisioner "local-exec" {
    command = "aws eks --region us-east-1 update-kubeconfig --name ${aws_eks_cluster.system-monitor-cluster.name}"
  }
}

resource "null_resource" "apply_k8s_yaml" {
  provisioner "local-exec" {
    command = "kubectl apply -f ./manifests/deployment.yaml -f ./manifests/service.yaml"
  }
}

resource "null_resource" "get_elb_dns" {
  provisioner "local-exec" {
    command = "kubectl get svc system-monitor-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
  }
}