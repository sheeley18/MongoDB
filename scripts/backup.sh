#!/bin/bash

set -e

# Get credentials from Secrets Manager
SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "tasky/database/credentials" \
    --region us-east-1 \
    --query SecretString \
    --output text)

ADMIN_PASS=$(echo "$SECRET_JSON" | jq -r '.MONGODB_ADMIN_PASSWORD')
S3_BUCKET=$(echo "$SECRET_JSON" | jq -r '.S3_BUCKET')

# Create backup directory
BACKUP_DIR="/tmp/mongodb-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Dump all databases
mongodump --host localhost:27017 \
    --username admin \
    --password "$ADMIN_PASS" \
    --authenticationDatabase admin \
    --out "$BACKUP_DIR"

# Compress backup
BACKUP_FILE="/tmp/mongodb-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$BACKUP_FILE" -C "$BACKUP_DIR" .

# Upload to S3
aws s3 cp "$BACKUP_FILE" "s3://$S3_BUCKET/backups/mongodb/"

# Cleanup
rm -rf "$BACKUP_DIR" "$BACKUP_FILE"

echo "Backup completed: s3://$S3_BUCKET/backups/mongodb/$(basename $BACKUP_FILE)"
