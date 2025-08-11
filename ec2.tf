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
  user_data = <<-EOF
              #!/bin/bash
              set -e 
              
              # Log everything for debugging
              exec > >(tee /var/log/user-data.log) 2>&1
              echo "Starting MongoDB installation script..."
              date
              
              # Update base packages
              sudo apt-get update -y
              sudo apt-get install -y curl gnupg lsb-release ca-certificates
              
              # Clean up any existing MongoDB repositories
              sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
              
              # Import MongoDB GPG key using apt-key (more reliable method)
              echo "Importing MongoDB GPG key using apt-key..."
              curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo apt-key add -
              
              # Add MongoDB repository (without keyring specification)
              echo "Adding MongoDB repository..."
              echo "deb https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
              
              # Update package lists
              echo "Updating package lists..."
              sudo apt-get update -y
              
              # Install MongoDB
              echo "Installing MongoDB..."
              sudo apt-get install -y mongodb-org
              
              # Verify installation
              if command -v mongod >/dev/null 2>&1; then
                  echo "MongoDB binary confirmed installed"
                  mongod --version
              else
                  echo "ERROR: MongoDB not found after installation"
                  exit 1
              fi
              
              # Configure MongoDB for external access
              echo "Configuring MongoDB..."
              sudo cp /etc/mongod.conf /etc/mongod.conf.backup
              sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
              
              # Start and enable MongoDB
              echo "Starting MongoDB..."
              sudo systemctl daemon-reload
              sudo systemctl enable mongod
              sudo systemctl start mongod
              
              # Wait and verify
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
              
              echo "Script completed at: $$(date)"
              # Add this to the END of your user_data script in ec2.tf (before the final EOF)

              echo "Setting up MongoDB backup system..."
              
              # Create simple, effective backup script
              cat > /home/ubuntu/backup-mongodb.sh << 'BACKUP_SCRIPT'
              #!/bin/bash
              
              # Simple MongoDB Backup Script
              # Usage: ./backup-mongodb.sh [manual|auto]
              
              set -e
              
              # Configuration
              TIMESTAMP=$(date +%Y%m%d-%H%M%S)
              BACKUP_DIR="/home/ubuntu/mongodb-backups"
              LOG_FILE="/var/log/mongodb-backup.log"
              MODE="${1:-manual}"
              
              # Function to log with timestamp
              log() {
                  echo "$(date '+%Y-%m-%d %H:%M:%S') [$MODE]: $1" | tee -a "$LOG_FILE"
              }
              
              log "Starting MongoDB backup..."
              
              # Create backup directory
              mkdir -p "$BACKUP_DIR"
              
              # Check MongoDB is running
              if ! mongosh --quiet --eval "db.runCommand('ping')" localhost:27017/tasky >/dev/null 2>&1; then
                  log "ERROR: MongoDB is not responding"
                  exit 1
              fi
              
              log "MongoDB health check passed"
              
              # Create MongoDB dump
              DUMP_DIR="$BACKUP_DIR/dump-$TIMESTAMP"
              log "Creating MongoDB dump in $DUMP_DIR"
              
              if mongodump --host localhost:27017 --db tasky --out "$DUMP_DIR" 2>&1 | tee -a "$LOG_FILE"; then
                  log "MongoDB dump created successfully"
              else
                  log "ERROR: MongoDB dump failed"
                  exit 1
              fi
              
              # Verify dump was created
              if [ ! -d "$DUMP_DIR/tasky" ] || [ -z "$(ls -A "$DUMP_DIR/tasky")" ]; then
                  log "ERROR: MongoDB dump is empty or invalid"
                  exit 1
              fi
              
              log "Dump verification passed. Files:"
              ls -la "$DUMP_DIR/tasky/" | tee -a "$LOG_FILE"
              
              # Compress the dump
              log "Compressing backup..."
              cd "$BACKUP_DIR"
              tar -czf "tasky-backup-$TIMESTAMP.tar.gz" "dump-$TIMESTAMP/"
              
              # Get backup size
              BACKUP_SIZE=$(du -h "tasky-backup-$TIMESTAMP.tar.gz" | cut -f1)
              log "Backup compressed to $BACKUP_SIZE"
              
              # Get S3 bucket name
              S3_BUCKET=$(aws s3 ls | grep tasky-mongo-bucket | awk '{print $3}')
              if [ -z "$S3_BUCKET" ]; then
                  log "ERROR: Could not find S3 bucket"
                  exit 1
              fi
              
              log "Uploading to S3 bucket: $S3_BUCKET"
              
              # Upload compressed backup
              if aws s3 cp "tasky-backup-$TIMESTAMP.tar.gz" "s3://$S3_BUCKET/mongodb-backups/" 2>&1 | tee -a "$LOG_FILE"; then
                  log "Compressed backup uploaded successfully"
              else
                  log "ERROR: Failed to upload compressed backup"
                  exit 1
              fi
              
              # Upload raw dump for easy restore
              if aws s3 cp "dump-$TIMESTAMP" "s3://$S3_BUCKET/mongodb-backups/dumps/dump-$TIMESTAMP" --recursive 2>&1 | tee -a "$LOG_FILE"; then
                  log "Raw dump uploaded successfully"
              else
                  log "ERROR: Failed to upload raw dump"
                  exit 1
              fi
              
              # Clean up local files older than 3 days
              log "Cleaning up local files older than 3 days..."
              find "$BACKUP_DIR" -name "dump-*" -type d -mtime +3 -exec rm -rf {} \; 2>/dev/null || true
              find "$BACKUP_DIR" -name "tasky-backup-*.tar.gz" -mtime +3 -delete 2>/dev/null || true
              
              # Show final status
              log "✅ Backup completed successfully!"
              log "📦 Compressed backup: s3://$S3_BUCKET/mongodb-backups/tasky-backup-$TIMESTAMP.tar.gz"
              log "📁 Raw dump: s3://$S3_BUCKET/mongodb-backups/dumps/dump-$TIMESTAMP/"
              log "💾 Backup size: $BACKUP_SIZE"
              
              # List recent backups in S3
              log "Recent backups in S3:"
              aws s3 ls "s3://$S3_BUCKET/mongodb-backups/" --human-readable | tail -10 | tee -a "$LOG_FILE"
              
              echo ""
              echo "✅ MongoDB backup completed successfully!"
              echo "📦 Backup: tasky-backup-$TIMESTAMP.tar.gz ($BACKUP_SIZE)"
              echo "📋 Log: $LOG_FILE"
              BACKUP_SCRIPT
              
              # Make backup script executable
              chmod +x /home/ubuntu/backup-mongodb.sh
              
              # Create cleanup script for old S3 backups
              cat > /home/ubuntu/cleanup-old-backups.sh << 'CLEANUP_SCRIPT'
              #!/bin/bash
              
              # Cleanup old backups (keep last 30 days)
              set -e
              
              LOG_FILE="/var/log/mongodb-backup.log"
              RETENTION_DAYS=30
              
              log() {
                  echo "$(date '+%Y-%m-%d %H:%M:%S') [cleanup]: $1" | tee -a "$LOG_FILE"
              }
              
              log "Starting cleanup of backups older than $RETENTION_DAYS days..."
              
              S3_BUCKET=$(aws s3 ls | grep tasky-mongo-bucket | awk '{print $3}')
              if [ -z "$S3_BUCKET" ]; then
                  log "ERROR: Could not find S3 bucket"
                  exit 1
              fi
              
              # Clean up compressed backups
              DELETED_COUNT=0
              aws s3 ls "s3://$S3_BUCKET/mongodb-backups/" | while read -r line; do
                  if [[ "$line" == *".tar.gz" ]]; then
                      createDate=$(echo "$line" | awk '{print $1" "$2}')
                      fileName=$(echo "$line" | awk '{print $4}')
                      
                      if [[ -n "$createDate" ]] && [[ -n "$fileName" ]]; then
                          createTimestamp=$(date -d "$createDate" +%s 2>/dev/null || echo "0")
                          cutoffTimestamp=$(date -d "$RETENTION_DAYS days ago" +%s)
                          
                          if [[ $createTimestamp -lt $cutoffTimestamp ]] && [[ $createTimestamp -gt 0 ]]; then
                              log "Deleting old backup: $fileName"
                              aws s3 rm "s3://$S3_BUCKET/mongodb-backups/$fileName"
                              ((DELETED_COUNT++))
                          fi
                      fi
                  fi
              done
              
              log "Cleanup completed. Deleted $DELETED_COUNT old backups."
              CLEANUP_SCRIPT
              
              chmod +x /home/ubuntu/cleanup-old-backups.sh
              
              # Create restore script for easy recovery
              cat > /home/ubuntu/restore-mongodb.sh << 'RESTORE_SCRIPT'
              #!/bin/bash
              
              # MongoDB Restore Script
              # Usage: ./restore-mongodb.sh [backup-timestamp] [target-db-name]
              
              set -e
              
              BACKUP_TIMESTAMP="$1"
              TARGET_DB="${2:-tasky_restored}"
              LOG_FILE="/var/log/mongodb-restore.log"
              
              log() {
                  echo "$(date '+%Y-%m-%d %H:%M:%S') [restore]: $1" | tee -a "$LOG_FILE"
              }
              
              if [ -z "$BACKUP_TIMESTAMP" ]; then
                  echo "Usage: $0 <backup-timestamp> [target-db-name]"
                  echo ""
                  echo "Available backups:"
                  
                  S3_BUCKET=$(aws s3 ls | grep tasky-mongo-bucket | awk '{print $3}')
                  aws s3 ls "s3://$S3_BUCKET/mongodb-backups/dumps/" | grep "dump-" | awk '{print $4}' | sed 's/dump-//' | sed 's/\///' | sort -r | head -20
                  
                  echo ""
                  echo "Example: $0 20250811-120000 tasky_restored"
                  exit 1
              fi
              
              log "Starting restore of backup: $BACKUP_TIMESTAMP to database: $TARGET_DB"
              
              # Get S3 bucket
              S3_BUCKET=$(aws s3 ls | grep tasky-mongo-bucket | awk '{print $3}')
              RESTORE_DIR="/tmp/restore-$BACKUP_TIMESTAMP"
              
              # Download backup from S3
              log "Downloading backup from S3..."
              aws s3 cp "s3://$S3_BUCKET/mongodb-backups/dumps/dump-$BACKUP_TIMESTAMP" "$RESTORE_DIR" --recursive
              
              # Verify download
              if [ ! -d "$RESTORE_DIR/tasky" ]; then
                  log "ERROR: Downloaded backup is invalid or missing"
                  exit 1
              fi
              
              # Restore to MongoDB
              log "Restoring to MongoDB database: $TARGET_DB"
              mongorestore --host localhost:27017 --db "$TARGET_DB" "$RESTORE_DIR/tasky/"
              
              log "✅ Restore completed successfully!"
              log "Database '$TARGET_DB' has been restored from backup $BACKUP_TIMESTAMP"
              
              # Clean up
              rm -rf "$RESTORE_DIR"
              
              echo "✅ MongoDB restore completed!"
              echo "📋 Log: $LOG_FILE"
              echo "🗄️  Restored to database: $TARGET_DB"
              RESTORE_SCRIPT
              
              chmod +x /home/ubuntu/restore-mongodb.sh
              
              # Set up cron job for midnight EST
              # EST is UTC-5, EDT is UTC-4. Using 5 AM UTC to cover EST
              cat > /tmp/mongodb-cron << 'CRON_CONFIG'
              # MongoDB backup at midnight EST (5 AM UTC)
              0 5 * * * /home/ubuntu/backup-mongodb.sh auto >> /var/log/mongodb-backup.log 2>&1
              
              # Cleanup old backups weekly on Sunday at 2 AM EST (7 AM UTC)  
              0 7 * * 0 /home/ubuntu/cleanup-old-backups.sh >> /var/log/mongodb-backup.log 2>&1
              CRON_CONFIG
              
              # Install cron job
              su - ubuntu -c "crontab /tmp/mongodb-cron"
              rm /tmp/mongodb-cron
              
              # Create log file with proper permissions
              touch /var/log/mongodb-backup.log
              chown ubuntu:ubuntu /var/log/mongodb-backup.log
              
              # Set up log rotation
              cat > /etc/logrotate.d/mongodb-backup << 'LOGROTATE'
              /var/log/mongodb-backup.log {
                  daily
                  rotate 30
                  compress
                  delaycompress
                  missingok
                  notifempty
                  create 644 ubuntu ubuntu
              }
              LOGROTATE
              
              echo "✅ MongoDB backup system configured successfully!"
              echo ""
              echo "Available commands:"
              echo "  Manual backup:    ./backup-mongodb.sh"
              echo "  Restore backup:   ./restore-mongodb.sh <timestamp>"
              echo "  Cleanup old:      ./cleanup-old-backups.sh" 
              echo ""
              echo "Automatic schedule:"
              echo "  Daily backup:     Midnight EST (5 AM UTC)"
              echo "  Weekly cleanup:   Sunday 2 AM EST (7 AM UTC)"
              echo ""
              echo "Logs: /var/log/mongodb-backup.log"
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








