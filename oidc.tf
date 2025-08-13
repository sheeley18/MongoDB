# OIDC provider for GitHub Actions - Adds short lived tokens and sets up for cloudwatch
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
  
  client_id_list = ["sts.amazonaws.com"]
  
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  tags = {
    Name = "github-actions-oidc"
  }
}

# IAM role for MongoDB repository
resource "aws_iam_role" "github_actions_mongodb" {
  name = "github-actions-mongodb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:sheeley18/MongoDB:*"
        }
      }
    }]
  })
}

# IAM role for EKS infrastructure repository
resource "aws_iam_role" "github_actions_eks" {
  name = "github-actions-eks-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:sheeley18/tasky-eks-cluster:*"
        }
      }
    }]
  })
}

# IAM role for Tasky application repository
resource "aws_iam_role" "github_actions_tasky" {
  name = "github-actions-tasky-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:sheeley18/tasky:*"
        }
      }
    }]
  })
}

# Attach policies (restrict these in production)
resource "aws_iam_role_policy_attachment" "github_mongodb_admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.github_actions_mongodb.name
}

resource "aws_iam_role_policy_attachment" "github_eks_admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.github_actions_eks.name
}

resource "aws_iam_role_policy_attachment" "github_tasky_admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.github_actions_tasky.name
}

# Outputs for other repositories
output "github_actions_mongodb_role_arn" {
  description = "ARN of GitHub Actions role for MongoDB repo"
  value       = aws_iam_role.github_actions_mongodb.arn
}

output "github_actions_eks_role_arn" {
  description = "ARN of GitHub Actions role for EKS repo" 
  value       = aws_iam_role.github_actions_eks.arn
}

output "github_actions_tasky_role_arn" {
  description = "ARN of GitHub Actions role for Tasky repo"
  value       = aws_iam_role.github_actions_tasky.arn
}
