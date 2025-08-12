# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Make sure there's never S3 Bucket naming conflicts
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Random password generation for MongoDB
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
  description = "Tasky application database credentials"
  
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
    MONGODB_URI          = "mongodb://tasky_app:${random_password.mongodb_app_password.result}@${aws_instance.terraform_instance.private_ip}:27017/tasky?authSource=tasky"
    MONGODB_HOST         = aws_instance.terraform_instance.private_ip
    MONGODB_PORT         = "27017"
    MONGODB_DATABASE     = "tasky"
    MONGODB_USERNAME     = "tasky_app"
    MONGODB_PASSWORD     = random_password.mongodb_app_password.result
    MONGODB_ADMIN_USERNAME = "admin"
    MONGODB_ADMIN_PASSWORD = random_password.mongodb_admin_password.result
    SECRET_KEY           = random_password.app_secret_key.result
    MONGODB_AUTH_SOURCE  = "tasky"
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Create IAM Role for EC2 S3 access
resource "aws_iam_role" "ec2_s3_role" {
  name = "EC2AllowS3"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# S3 access policy
resource "aws_iam_role_policy" "s3_access" {
  name = "EC2S3Access"
  role = aws_iam_role.ec2_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject", 
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.tasky_mongo_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = aws_s3_bucket.tasky_mongo_bucket.arn
      }
    ]
  })
}

# Instance profile
resource "aws_iam_instance_profile" "ec2_s3_profile" {
  name = "EC2S3Profile"
  role = aws_iam_role.ec2_s3_role.name
}

# MongoDB EC2 Instance
resource "aws_instance" "terraform_instance" {
  ami                    = var.AMIS[var.REGION]
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_subnet_1.id  # CHANGED: Use private subnet
  key_name               = var.PUBLIC_KEY
  vpc_security_group_ids = [aws_security_group.mongodb_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name

  user_data = <<-EOF
#!/bin/bash
set -e
exec > >(tee /var/log/user-data.log) 2>&1
echo "Starting MongoDB installation script..."
date

sudo apt-get update -y
sudo apt-get install -y curl gnupg lsb-release ca-certificates awscli jq

# Clean up any existing MongoDB repositories
sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list

echo "Importing MongoDB GPG key..."
if curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo apt-key add - 2>/dev/null; then
  echo "GPG key imported via apt-key"
else
  echo "apt-key failed, trying alternative method..."
  curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg 2>/dev/null || {
    echo "GPG import failed, continuing without verification..."
    echo "deb [trusted=yes] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
  }
fi

if [ ! -f /etc/apt/sources.list.d/mongodb-org-7.0.list ]; then
  echo "Adding MongoDB repository..."
  echo "deb https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
fi

sudo apt-get update -y

echo "Installing MongoDB..."
for i in {1..3}; do
  if sudo apt-get install -y mongodb-org; then
    echo "MongoDB installed successfully on attempt $i"
    break
  else
    echo "MongoDB installation attempt $i failed, retrying..."
    sudo apt-get update -y
    sleep 5
  fi
  
  if [ $i -eq 3 ]; then
    echo "ERROR: MongoDB installation failed after 3 attempts"
    exit 1
  fi
done

if command -v mongod >/dev/null 2>&1; then
  echo "MongoDB binary confirmed installed"
  mongod --version
else
  echo "ERROR: MongoDB not found after installation"
  exit 1
fi

echo "Configuring MongoDB..."
sudo cp /etc/mongod.conf /etc/mongod.conf.backup
sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf

echo "Starting MongoDB..."
sudo systemctl daemon-reload
sudo systemctl enable mongod
sudo systemctl start mongod

sleep 10
if sudo systemctl is-active --quiet mongod; then
  echo "SUCCESS: MongoDB is running!"
  sudo systemctl status mongod --no-pager
  echo "MongoDB installation completed successfully!"
else
  echo "MongoDB service failed to start"
  sudo systemctl status mongod --no-pager
  exit 1
fi

echo "MongoDB installation script completed at: $(date)"
EOF

  tags = {
    Name        = "TASKY_MONGODB"
    Environment = "Production"
    Purpose     = "MongoDB Database Server"
  }
}

# S3 Bucket for backups
resource "aws_s3_bucket" "tasky_mongo_bucket" {
  bucket = "tasky-mongo-bucket-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "tasky-mongo-bucket"
    Environment = "Production"
  }
}

# S3 Security configurations
resource "aws_s3_bucket_server_side_encryption_configuration" "tasky_encryption" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tasky_pab" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "tasky_versioning" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Outputs for other repositories to reference
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.mongo_vpc.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value = [
    aws_subnet.public_subnet_1.id,
    aws_subnet.public_subnet_2.id,
    aws_subnet.public_subnet_3.id
  ]
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value = [
    aws_subnet.private_subnet_1.id,
    aws_subnet.private_subnet_2.id,
    aws_subnet.private_subnet_3.id
  ]
}

output "mongodb_private_ip" {
  description = "Private IP of MongoDB instance"
  value       = aws_instance.terraform_instance.private_ip
}

output "mongodb_security_group_id" {
  description = "Security group ID for MongoDB"
  value       = aws_security_group.mongodb_sg.id
}

output "secrets_manager_arn" {
  description = "ARN of the secrets manager secret"
  value       = aws_secretsmanager_secret.tasky_database_secrets.arn
}

output "bucket_name" {
  value = aws_s3_bucket.tasky_mongo_bucket.bucket
}
