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
    # MongoDB connection details
    MONGODB_URI            = "mongodb://tasky_app:${random_password.mongodb_app_password.result}@${aws_instance.terraform_instance.private_ip}:27017/tasky?authSource=tasky"
    MONGODB_HOST           = aws_instance.terraform_instance.private_ip
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

# MongoDB EC2 Instance
resource "aws_instance" "terraform_instance" {
  ami                    = var.AMIS[var.REGION]
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_subnet_1.id
  key_name               = var.PUBLIC_KEY
  vpc_security_group_ids = [aws_security_group.mongodb_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3_profile.name

  # Fixed user data with proper escaping
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # Log everything for debugging
    exec > >(tee /var/log/user-data.log) 2>&1
    echo "Starting MongoDB installation script..."
    date

    # Update base packages
    sudo apt-get update -y
    sudo apt-get install -y curl gnupg lsb-release ca-certificates awscli jq

    # Clean up any existing MongoDB repositories
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list

    # Import MongoDB GPG key
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

    # Install MongoDB with retry logic
    echo "Installing MongoDB..."
    for i in {1..3}; do
      if sudo apt-get install -y mongodb-org mongodb-database-tools; then
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

    # Verify installation
    if command -v mongod >/dev/null 2>&1; then
      echo "MongoDB binary confirmed installed"
      mongod --version
    else
      echo "ERROR: MongoDB not found after installation"
      exit 1
    fi

    # Configure MongoDB
    echo "Configuring MongoDB..."
    sudo cp /etc/mongod.conf /etc/mongod.conf.backup
    sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf

    # Start and enable MongoDB
    echo "Starting MongoDB..."
    sudo systemctl daemon-reload
    sudo systemctl enable mongod
    sudo systemctl start mongod

    sleep 10
    if sudo systemctl is-active --quiet mongod; then
      echo "SUCCESS: MongoDB is running!"
      sudo systemctl status mongod --no-pager
    else
      echo "MongoDB service failed to start"
      sudo systemctl status mongod --no-pager
      exit 1
    fi

    # Create backup scripts
    echo "Setting up backup system..."

    # Create backup script
    cat > /home/ubuntu/backup-mongodb.sh << 'BACKUP_SCRIPT_EOF'
#!/bin/bash
# MongoDB backup script with S3 integration

set -euo pipefail

# Configuration
BACKUP_DIR="/tmp/mongodb-backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="mongodb_backup_$${DATE}"
LOG_FILE="/var/log/mongodb-backup.log"
RETENTION_DAYS=30
S3_BUCKET="${aws_s3_bucket.tasky_mongo_bucket.bucket}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "$${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]$${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "$${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:$${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "$${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:$${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# Get MongoDB credentials from Secrets Manager
get_mongodb_credentials() {
    log "Retrieving MongoDB credentials..."
    SECRET_JSON=$$(aws secretsmanager get-secret-value --secret-id tasky/database/credentials --query SecretString --output text 2>/dev/null)
    
    if [[ -z "$SECRET_JSON" ]]; then
        error "Could not retrieve MongoDB credentials"
    fi
    
    MONGODB_ADMIN_USER=$$(echo "$SECRET_JSON" | jq -r '.MONGODB_ADMIN_USERNAME')
    MONGODB_ADMIN_PASSWORD=$$(echo "$SECRET_JSON" | jq -r '.MONGODB_ADMIN_PASSWORD')
}

# Test MongoDB connection
test_connection() {
    log "🔍 Testing MongoDB connection..."
    if mongosh -u "$MONGODB_ADMIN_USER" -p "$MONGODB_ADMIN_PASSWORD" --authenticationDatabase admin --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
        log "MongoDB connection successful"
    else
        error "Cannot connect to MongoDB"
    fi
}

# Create backup
perform_backup() {
    log "Starting MongoDB backup..."
    
    mkdir -p "$BACKUP_DIR"
    BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
    
    if mongodump \
        --username "$MONGODB_ADMIN_USER" \
        --password "$MONGODB_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --out "$BACKUP_PATH" \
        --gzip \
        --oplog; then
        log "MongoDB dump completed"
    else
        error "MongoDB dump failed"
    fi
    
    # Compress backup
    cd "$BACKUP_DIR"
    tar -czf "$${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
    rm -rf "$BACKUP_NAME"
    
    COMPRESSED_SIZE=$$(du -sh "$${BACKUP_NAME}.tar.gz" | cut -f1)
    log "Compressed backup size: $COMPRESSED_SIZE"
}

# Upload to S3
upload_to_s3() {
    log "☁️ Uploading to S3..."
    
    LOCAL_FILE="$BACKUP_DIR/$${BACKUP_NAME}.tar.gz"
    S3_KEY="backups/mongodb/$${BACKUP_NAME}.tar.gz"
    
    if aws s3 cp "$LOCAL_FILE" "s3://$S3_BUCKET/$S3_KEY" \
        --metadata "backup-date=$DATE,backup-type=mongodb,retention-days=$RETENTION_DAYS" \
        --storage-class STANDARD_IA; then
        log "Backup uploaded to s3://$S3_BUCKET/$S3_KEY"
    else
        error "Failed to upload backup"
    fi
}

# Clean up old backups
cleanup_old_backups() {
    log "Cleaning up old backups..."
    
    # Remove local files
    rm -rf "$BACKUP_DIR"
    
    # Remove old S3 backups (older than retention period)
    OLD_DATE=$$(date -d "$RETENTION_DAYS days ago" --iso-8601)
    aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" \
        --prefix "backups/mongodb/" \
        --query "Contents[?LastModified<='$OLD_DATE'].Key" \
        --output text | while read -r key; do
        if [[ -n "$key" && "$key" != "None" ]]; then
            aws s3 rm "s3://$S3_BUCKET/$key"
            log "Deleted old backup: $key"
        fi
    done
}

# Send notification
send_notification() {
    local status=$$1
    local message=$$2
    
    # Send to CloudWatch Logs
    aws logs create-log-group --log-group-name "/mongodb/backups" 2>/dev/null || true
    aws logs put-log-events \
        --log-group-name "/mongodb/backups" \
        --log-stream-name "$$(hostname)" \
        --log-events "timestamp=$$(date +%s)000,message=$status: $message" 2>/dev/null || true
}

# Main backup process
main() {
    log "Starting MongoDB backup process..."
    START_TIME=$$(date +%s)
    
    get_mongodb_credentials
    test_connection
    perform_backup
    upload_to_s3
    cleanup_old_backups
    
    END_TIME=$$(date +%s)
    DURATION=$$((END_TIME - START_TIME))
    
    SUCCESS_MESSAGE="MongoDB backup completed in $${DURATION}s. File: $${BACKUP_NAME}.tar.gz"
    log "$SUCCESS_MESSAGE"
    send_notification "SUCCESS" "$SUCCESS_MESSAGE"
}

# Handle arguments
case "$${1:-}" in
    --test)
        get_mongodb_credentials
        test_connection
        log "Test completed successfully"
        ;;
    --list)
        log "Available backups:"
        aws s3 ls "s3://$S3_BUCKET/backups/mongodb/" --human-readable
        ;;
    *)
        main
        ;;
esac
BACKUP_SCRIPT_EOF

    # Create setup script for cron
    cat > /home/ubuntu/setup-backup-cron.sh << 'CRON_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

echo "⏰ Setting up automated MongoDB backups..."

# Make backup script executable
chmod +x /home/ubuntu/backup-mongodb.sh

# Create log file
sudo touch /var/log/mongodb-backup.log
sudo chown ubuntu:ubuntu /var/log/mongodb-backup.log

# Add cron job for midnight backup (UTC)
CRON_JOB="0 0 * * * /home/ubuntu/backup-mongodb.sh >> /var/log/mongodb-backup.log 2>&1"

if ! crontab -l 2>/dev/null | grep -q "backup-mongodb.sh"; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Cron job added: Daily backup at midnight UTC"
else
    echo "ℹCron job already exists"
fi

# Ensure cron service is running
if ! systemctl is-active --quiet cron; then
    sudo systemctl enable cron
    sudo systemctl start cron
    echo "Cron service started"
fi

echo "Current cron jobs:"
crontab -l

echo "Automated backup setup complete!"
echo "Backups will run daily at midnight UTC"
echo "Backups stored in S3: s3://${aws_s3_bucket.tasky_mongo_bucket.bucket}/backups/mongodb/"
echo "Retention: 30 days in S3, then moved to Glacier, deleted after 1 year"
echo "Check logs: tail -f /var/log/mongodb-backup.log"
CRON_SCRIPT_EOF

    # Create auth setup script
    cat > /home/ubuntu/setup-mongodb-auth.sh << 'AUTH_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

echo "Securing MongoDB Installation..."

if ! systemctl is-active --quiet mongod; then
    echo "MongoDB is not running. Starting it..."
    sudo systemctl start mongod
    sleep 10
fi

# Get passwords from AWS Secrets Manager
echo "📡 Retrieving credentials from AWS Secrets Manager..."
SECRET_JSON=$$(aws secretsmanager get-secret-value --secret-id tasky/database/credentials --query SecretString --output text)
ADMIN_PASSWORD=$$(echo "$SECRET_JSON" | jq -r '.MONGODB_ADMIN_PASSWORD')
APP_PASSWORD=$$(echo "$SECRET_JSON" | jq -r '.MONGODB_PASSWORD')

echo "Creating MongoDB users..."

# Create admin user
mongosh --eval "
use admin
try {
  db.createUser({
    user: 'admin',
    pwd: '$ADMIN_PASSWORD',
    roles: [ 
      { role: 'userAdminAnyDatabase', db: 'admin' }, 
      'readWriteAnyDatabase',
      'dbAdminAnyDatabase',
      'clusterAdmin'
    ]
  })
  print('Admin user created successfully')
} catch(e) {
  if (e.message.includes('already exists')) {
    print('Admin user already exists')
  } else {
    throw e
  }
}
"

# Create application user
mongosh --eval "
use tasky
try {
  db.createUser({
    user: 'tasky_app',
    pwd: '$APP_PASSWORD',
    roles: [ 
      { role: 'readWrite', db: 'tasky' }
    ]
  })
  print('Application user created successfully')
} catch(e) {
  if (e.message.includes('already exists')) {
    print('Application user already exists')
  } else {
    throw e
  }
}
"

echo "Enabling authentication in MongoDB..."

# Backup config if not already backed up
if [[ ! -f /etc/mongod.conf.backup ]]; then
    sudo cp /etc/mongod.conf /etc/mongod.conf.backup
fi

# Check if authentication is already enabled
if ! grep -q "authorization: enabled" /etc/mongod.conf; then
    sudo tee -a /etc/mongod.conf > /dev/null << 'AUTH_CONFIG_EOF'

# Security Configuration
security:
  authorization: enabled
  
# Logging Configuration  
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
  quiet: false
  logRotate: reopen
AUTH_CONFIG_EOF

    echo "Restarting MongoDB..."
    sudo systemctl restart mongod
    sleep 15
else
    echo "Authentication already enabled"
fi

echo "Testing authentication..."
if mongosh -u admin -p "$ADMIN_PASSWORD" --authenticationDatabase admin --eval "db.adminCommand('ismaster')" > /dev/null 2>&1; then
    echo "Authentication working correctly!"
    echo "Connection URI: mongodb://tasky_app:***@$$(hostname -I | awk '{print $$1}'):27017/tasky?authSource=tasky"
else
    echo "Authentication test failed."
    exit 1
fi

echo "MongoDB security setup complete."
AUTH_SCRIPT_EOF

    # Make all scripts executable and set ownership
    chmod +x /home/ubuntu/*.sh
    chown ubuntu:ubuntu /home/ubuntu/*.sh

    # Create log directory for MongoDB
    sudo mkdir -p /var/log/mongodb
    sudo chown mongodb:mongodb /var/log/mongodb

    # Wait for MongoDB to be fully ready
    sleep 30

    echo "✅ MongoDB installation with backup system completed!"
    echo "🔧 Next steps:"
    echo "  1. Run: sudo -u ubuntu /home/ubuntu/setup-mongodb-auth.sh"
    echo "  2. Run: sudo -u ubuntu /home/ubuntu/setup-backup-cron.sh"
    echo "📋 Available scripts:"
    echo "  - backup-mongodb.sh: Manual backup (also --test, --list)"
    echo "  - setup-backup-cron.sh: Setup automated backups"
    echo "  - setup-mongodb-auth.sh: Setup MongoDB authentication"
  EOF
  )

  tags = {
    Name        = "TASKY_MONGODB"
    Environment = "Production"
    Purpose     = "MongoDB Database Server"
    Version     = "v3"
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

    # Move to cheaper storage after 30 days
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # Archive to Glacier after 90 days
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # Deep archive after 180 days
    transition {
      days          = 180
      storage_class = "DEEP_ARCHIVE"
    }

    # Delete after 1 year
    expiration {
      days = 365
    }

    # Clean up incomplete multipart uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # Delete old versions after 30 days
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "general_cleanup"
    status = "Enabled"

    filter {
      prefix = "temp/"
    }

    expiration {
      days = 7
    }
  }
}

# EC2 and Database related outputs (keep in ec2.tf)
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

output "bucket_name" {
  description = "Name of the S3 backup bucket"
  value       = aws_s3_bucket.tasky_mongo_bucket.bucket
}

output "secrets_manager_arn" {
  description = "ARN of the secrets manager secret"
  value       = aws_secretsmanager_secret.tasky_database_secrets.arn
}
