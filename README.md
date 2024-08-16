# AWS ESK System Monitor Application

![app](https://github.com/user-attachments/assets/89157c8b-5039-41cd-abb6-dff2b697ee46)

## Steps to deploy Application in EKS

1. Create AWS [IAM User](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html#id_users_create_console)

2. Set necessory permision to IAM user to create and destroy aws resources (Eg: **AdministratorAccess**)<br>
    > use Permissions --> Add permissions --> Attach policies directly

3. Install [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)

4. Configure AWS [IAM User in AWS CLI](https://docs.aws.amazon.com/cli/latest/reference/configure/)<br>
    ```bash
    $ aws configure
    AWS Access Key ID [None]: <accesskey>
    AWS Secret Access Key [None]: <secretkey>
    Default region name [None]: <default-region> eg: us-east-1
    Default output format [None]: json
    ```

> [!TIP]
> Check user is configured correctly<br>`$ aws iam list-users`

5. Install [Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)

7. Install [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)

6. Initialize the project <br>
    ```
    $ terraform init
    ```

8. Create resources `main.tf`<br>

```jsx
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
```

9. Create the resources

    ```bash
    $ terraform validate
    $ terraform plan
    $ terraform apply -auto-approve
    ```

10. Setup current-context

    #### Option 1: Setup it manually
    ```bash
    $ aws eks update-kubeconfig --region us-east-1 --name cloud-native-system-monitor-cluster
    $ kubectl config view
    $ kubectl config use-context <cluster-context> (if corrent-context is different)
    $ kubectl config current-context (verify current context)
    ```

    #### Option 2: Setup it using terraform
    
    **Step 1**: update the `main.tf` and add following code snippet
    ```jsx
    resource "null_resource" "update_kubeconfig" {
        provisioner "local-exec" {
            command = "aws eks --region us-east-1 update-kubeconfig --name ${aws_eks_cluster.system-monitor-cluster.name}"
        }
    }
    ```

    **Step 2**: apply the changes
    ```bash
    $ terraform validate
    $ terraform plan
    $ terraform apply -auto-approve
    ```

11. Create and push the docker image to ECR

    To build the docker image for system monitor application follow this [repository](https://github.com/Roni-Boiz/system-monitor-app/tree/main)

    Or you can pull the image from my docker hub `docker pull don361/system-monitor:latest`

    Push the Docker image to ECR using the push commands on the console:

    ```
    $ docker push <ecr_repo_uri>:<tag>
    ```

> [!TIP]
> All the required code snippets to push the image to ECR is provided by the AWS ECR `push commands` buton in ECR repository. Please modify the image name according to your image name.

12. Deploy the application in EKS kubernetes cluster

    **Step 1**: update the `main.tf` and add following code snippet
    ```jsx
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
    ```

    **Step 2**: apply the changes
    ```bash
    $ terraform validate
    $ terraform plan
    $ terraform apply -auto-approve
    $ kubectl get service
    ```

> [!WARNING]
> Make sure to edit the name of the image on line 23 with your ECR image Uri in `manifests/deployment.yaml`

![service](https://github.com/user-attachments/assets/e9b219e3-4c16-44ce-a922-a2dee1df1cd9)


13. Open the browser and enter the external-IP in address bar (Eg: `<account-id>.us-east-1.elb.amazonaws.com:5000`)

14. Destroy the project resources<br>
    `$ terraform destroy -auto-approve`

> [!CAUTION]
> Make sure you have delete the ECR image first in order to destroy the ECR repository

**Verify everything is cleaned up and destroyed**

## Deploy the application locally

```bash
$ minikube start
$ kubectl apply -f manifests/deployment.yaml -f manifests/service.yaml
$ minikube tunnel
$ kubectl get service
```

This will enable to access the application on <external-ip>:5000. Navigate to http://<external-ip>:5000 on your browser to access the application.

#### If insted of LoadBalance if someone use CLusterIP use following commands to access the service in kubernetes cluster in local machine

```
$ kubectl get service
$ minikube service <service-name>
    - or - 
$ kubectl port-forward svc/<service-name> 5000:5000
```
