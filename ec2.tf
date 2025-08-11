# Make sure there's never S3 Bucket naming conflicts
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Create IAM Role - Specifies for portability and can load this anywhere.
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

# SECURITY: Use custom policy with minimal permissions instead of AmazonS3FullAccess
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
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.tasky_mongo_bucket.arn
      }
    ]
  })
}

# Profile so EC2 and S3 can Communicate
resource "aws_iam_instance_profile" "ec2_s3_profile" {
  name = "EC2S3Profile"
  role = aws_iam_role.ec2_s3_role.name
}

# Start EC2 Instance and Set Up MongoDB
resource "aws_instance" "terraform_instance" {
  ami                    = var.AMIS[var.REGION] 
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_subnet_1.id      
  key_name               = var.PUBLIC_KEY
  vpc_security_group_ids = [aws_security_group.terraform_sg.id]  
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name
  
  #user_data script to install and enable mongodb
  #user_data script to install and enable mongodb
  user_data = <<-EOF
            #!/bin/bash
            set -e 
            
            # Log everything for debugging
            exec > >(tee /var/log/user-data.log) 2>&1
            echo "Starting MongoDB installation script..."
            
            # Update base Packages
            sudo apt-get update -y
            sudo apt-get install -y gnupg curl awscli ca-certificates lsb-release
            
            # Variables
            MONGO_VERSION="7.0"
            UBUNTU_CODENAME="jammy"
            GPG_KEY_PATH="/usr/share/keyrings/mongodb-server-$${MONGO_VERSION}.gpg"
            
            # Remove any existing broken repositories
            sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
            
            # Import MongoDB GPG key with retries and verification
            echo "Importing MongoDB GPG key..."
            for i in {1..3}; do
              if wget -qO- https://pgp.mongodb.com/server-$${MONGO_VERSION}.asc | sudo gpg --dearmor -o "$$GPG_KEY_PATH"; then
                echo "GPG key imported successfully"
                break
              else
                echo "GPG key import attempt $$i failed, retrying..."
                sleep 5
              fi
            done
            
            # Verify GPG key was created and has content
            if [ ! -s "$$GPG_KEY_PATH" ]; then
              echo "ERROR: GPG key file is missing or empty"
              exit 1
            fi
            
            # Set proper permissions on GPG key
            sudo chmod 644 "$$GPG_KEY_PATH"
            
            # Add MongoDB repository
            echo "Adding MongoDB repository..."
            echo "deb [ arch=amd64,arm64 signed-by=$${GPG_KEY_PATH} ] https://repo.mongodb.org/apt/ubuntu $${UBUNTU_CODENAME}/mongodb-org/$${MONGO_VERSION} multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-$${MONGO_VERSION}.list
            
            # Update package lists
            echo "Updating package lists..."
            sudo apt-get update -y
            
            # Install MongoDB with retries
            echo "Installing MongoDB..."
            for i in {1..3}; do
              if sudo apt-get install -y mongodb-org; then
                echo "MongoDB installed successfully"
                break
              else
                echo "MongoDB installation attempt $$i failed, retrying..."
                sudo apt-get update -y
                sleep 10
              fi
            done
            
            # Verify MongoDB was installed
            if ! command -v mongod &> /dev/null; then
              echo "ERROR: MongoDB installation failed"
              exit 1
            fi
            
            # Configure MongoDB for external access
            echo "Configuring MongoDB..."
            sudo cp /etc/mongod.conf /etc/mongod.conf.backup
            sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
            
            # Start and enable MongoDB
            echo "Starting MongoDB service..."
            sudo systemctl daemon-reload
            sudo systemctl enable mongod
            sudo systemctl start mongod
            
            # Wait for MongoDB to start and verify
            echo "Waiting for MongoDB to start..."
            sleep 10
            
            # Check MongoDB status
            if sudo systemctl is-active --quiet mongod; then
              echo "SUCCESS: MongoDB is running!"
              sudo systemctl status mongod --no-pager
            else
              echo "ERROR: MongoDB failed to start"
              sudo systemctl status mongod --no-pager
              sudo journalctl -u mongod --no-pager -n 20
              exit 1
            fi
            
            echo "MongoDB installation and configuration completed successfully!"
            date
            EOF

  tags = {
    Name = "TASKY_MONGODB"
    Environment = "Lab"
    Purpose = "MongoDB Database Server"
  }

}

# Create the Bucket with unique naming
resource "aws_s3_bucket" "tasky_mongo_bucket" {
  bucket = "tasky-mongo-bucket-${random_id.bucket_suffix.hex}" 
  
  tags = {
    Name        = "tasky-mongo-bucket"
    Environment = "Production"
  }
}

# SECURITY: Add server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "tasky_encryption" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# SECURITY: Block public access
resource "aws_s3_bucket_public_access_block" "tasky_pab" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Turn on Versioning
resource "aws_s3_bucket_versioning" "tasky_versioning" {
  bucket = aws_s3_bucket.tasky_mongo_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Confirmation Logging
# Shows Public IP on startup
output "PublicIP" {
  value = aws_instance.terraform_instance.public_ip
}

# Output the Bucket Name on Startup
output "bucket_name" {
  value = aws_s3_bucket.tasky_mongo_bucket.bucket
}

# Output DNS on Startup  
output "instance_dns" {
  value = aws_instance.terraform_instance.public_dns

}






