# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Make sure there's never S3 Bucket naming conflicts
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Random password generation for MongoDB security
resource "random_password" "mongodb_admin_password" {
  length  = 32
  special = true
}

resource "random_password" "mongodb_app_password" {
  length  = 32
  special = true
}

resource "random_password" "app_secret_key" {
  length  = 64
  special = true
}

# AWS Secrets Manager secret for MongoDB credentials
resource "aws_secretsmanager_secret" "tasky_database_secrets" {
  name        = "tasky/database/credentials"
  description = "Tasky application database credentials and configuration"
  
  tags = {
    Application = "tasky"
    Environment = "production"
    Type        = "database-credentials"
  }
}

# Store the actual secret values
resource "aws_secretsmanager_secret_version" "tasky_database_secrets" {
  secret_id = aws_secretsmanager_secret.tasky_database_secrets.id
  secret_string = jsonencode({
    # MongoDB connection details - Updated to use PUBLIC IP for external access
    MONGODB_URI            = "mongodb://tasky_app:${random_password.mongodb_app_password.result}@${aws_instance.terraform_instance.public_ip}:27017/tasky?authSource=tasky"
    MONGODB_HOST           = aws_instance.terraform_instance.public_ip
    MONGODB_PORT           = "27017"
    MONGODB_DATABASE       = "tasky"
    MONGODB_USERNAME       = "tasky_app"
    MONGODB_PASSWORD       = random_password.mongodb_app_password.result
    MONGODB_ADMIN_USERNAME = "admin"
    MONGODB_ADMIN_PASSWORD = random_password.mongodb_admin_password.result
    SECRET_KEY             = random_password.app_secret_key.result
    MONGODB_AUTH_SOURCE    = "tasky"
    MONGODB_SSL            = "false"
    MONGODB_REPLICA_SET    = ""
    S3_BUCKET              = "tasky-mongo-bucket-${random_id.bucket_suffix.hex}"
  })
  
  # Prevent Terraform from overwriting manually updated secrets
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Create IAM Role for EC2 (S3 + Secrets Manager + CloudWatch access)
resource "aws_iam_role" "ec2_s3_role" {
  name = "EC2AllowS3SecretsManager"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Enhanced policy for backup system
resource "aws_iam_role_policy" "ec2_access_policy" {
  name = "EC2S3SecretsCloudWatchAccess"
  role = aws_iam_role.ec2_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 access for backups
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.tasky_mongo_bucket.arn,
          "${aws_s3_bucket.tasky_mongo_bucket.arn}/*"
        ]
      },
      # Secrets Manager access for backup script
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.tasky_database_secrets.arn
      },
      # CloudWatch Logs for backup monitoring
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:*:*:log-group:/mongodb/*"
      }
    ]
  })
}

# Instance profile for EC2
resource "aws_iam_instance_profile" "ec2_s3_profile" {
  name = "EC2S3SecretsProfile"
  role = aws_iam_role.ec2_s3_role.name
}

# MongoDB EC2 Instance - MOVED TO PUBLIC SUBNET
resource "aws_instance" "terraform_instance" {
  ami                    = var.AMIS[var.REGION]
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_subnet_1.id  # CHANGED: Now in public subnet
  key_name               = var.PUBLIC_KEY
  vpc_security_group_ids = [aws_security_group.mongodb_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name

  # Enhanced user data for proper MongoDB setup
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    exec > >(tee /var/log/user-data.log) 2>&1
    echo "Starting MongoDB setup..."
    
    # Update packages
    apt-get update -y
    apt-get install -y curl gnupg ca-certificates awscli jq
    
    # Install MongoDB
    curl -fsSL https://pgp.mongodb.com/server-7.0.asc | apt-key add -
    echo "deb [arch=amd64,arm64] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list
    apt-get update -y
    apt-get install -y mongodb-org mongodb-database-tools
    
    # Configure MongoDB for external access
    sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
    
    # Enable authentication
    echo "security:" >> /etc/mongod.conf
    echo "  authorization: enabled" >> /etc/mongod.conf
    
    # Start MongoDB
    systemctl enable mongod
    systemctl start mongod
    
    # Wait for MongoDB to start
    sleep 10
    
    # Create admin user
    mongosh --eval "
    db = db.getSiblingDB('admin');
    db.createUser({
      user: 'admin',
      pwd: '${random_password.mongodb_admin_password.result}',
      roles: [
        { role: 'userAdminAnyDatabase', db: 'admin' },
        { role: 'readWriteAnyDatabase', db: 'admin' },
        { role: 'dbAdminAnyDatabase', db: 'admin' },
        { role: 'clusterAdmin', db: 'admin' }
      ]
    });
    "
    
    # Restart MongoDB with auth enabled
    systemctl restart mongod
    sleep 5
    
    # Create application user
    mongosh -u admin -p '${random_password.mongodb_admin_password.result}' --authenticationDatabase admin --eval "
    db = db.getSiblingDB('tasky');
    db.createUser({
      user: 'tasky_app',
      pwd: '${random_password.mongodb_app_password.result}',
      roles: [
        { role: 'readWrite', db: 'tasky' }
      ]
    });
    "
    
    echo "MongoDB installation and user setup completed."
  EOF
  )

  tags = {
    Name        = "TASKY_MONGODB"
    Environment = "Production"
    Purpose     = "MongoDB Database Server"
  }
}

# S3 Bucket for MongoDB backups
resource "aws_s3_bucket" "tasky_mongo_bucket" {
  bucket = "tasky-mongo-bucket-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "tasky-mongo-bucket"
    Environment = "Production"
    Purpose     = "MongoDB Backups"
  }
}

# S3 Server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "tasky_encryption" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# S3 Public access block (security)
resource "aws_s3_bucket_public_access_block" "tasky_pab" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Versioning
resource "aws_s3_bucket_versioning" "tasky_versioning" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Lifecycle policy for intelligent backup retention
resource "aws_s3_bucket_lifecycle_configuration" "backup_lifecycle" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id

  rule {
    id     = "mongodb_backup_retention"
    status = "Enabled"

    filter {
      prefix = "backups/mongodb/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# EC2 and Database related outputs
output "PublicIP" {
  description = "Public IP of MongoDB instance (for SSH access)"
  value       = aws_instance.terraform_instance.public_ip
}

output "instance_dns" {
  description = "Public DNS of MongoDB instance"
  value       = aws_instance.terraform_instance.public_dns
}

output "mongodb_private_ip" {
  description = "Private IP of MongoDB instance (for internal access)"
  value       = aws_instance.terraform_instance.private_ip
}

output "mongodb_public_ip" {
  description = "Public IP of MongoDB instance (for EKS access)"
  value       = aws_instance.terraform_instance.public_ip
}

output "bucket_name" {
  description = "Name of the S3 backup bucket"
  value       = aws_s3_bucket.tasky_mongo_bucket.bucket
}

output "secrets_manager_arn" {
  description = "ARN of the secrets manager secret"
  value       = aws_secretsmanager_secret.tasky_database_secrets.arn
}

output "vpc_id" {
  description = "VPC ID for EKS deployment"
  value       = aws_vpc.mongo_vpc.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs for EKS"
  value       = [
    aws_subnet.public_subnet_1.id,
    aws_subnet.public_subnet_2.id,
    aws_subnet.public_subnet_3.id
  ]
}

output "private_subnet_ids" {
  description = "Private subnet IDs for EKS"
  value       = [
    aws_subnet.private_subnet_1.id,
    aws_subnet.private_subnet_2.id,
    aws_subnet.private_subnet_3.id
  ]
}
