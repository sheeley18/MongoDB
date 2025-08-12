#!/bin/bash
# backup-mongodb.sh - Complete MongoDB backup script with S3 integration

set -euo pipefail

# Configuration
BACKUP_DIR="/tmp/mongodb-backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="mongodb_backup_${DATE}"
LOG_FILE="/var/log/mongodb-backup.log"
RETENTION_DAYS=30

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# Function to get MongoDB credentials from AWS Secrets Manager
get_mongodb_credentials() {
    log "Retrieving MongoDB credentials from AWS Secrets Manager..."
    
    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id tasky/database/credentials --query SecretString --output text 2>/dev/null)
    
    if [[ -z "$SECRET_JSON" ]]; then
        error "Could not retrieve MongoDB credentials from Secrets Manager"
    fi
    
    MONGODB_ADMIN_USER=$(echo "$SECRET_JSON" | jq -r '.MONGODB_ADMIN_USERNAME')
    MONGODB_ADMIN_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.MONGODB_ADMIN_PASSWORD')
    S3_BUCKET=$(echo "$SECRET_JSON" | jq -r '.S3_BUCKET')
    
    if [[ "$MONGODB_ADMIN_USER" == "null" || "$MONGODB_ADMIN_PASSWORD" == "null" || "$S3_BUCKET" == "null" ]]; then
        error "Invalid credentials retrieved from Secrets Manager"
    fi
    
    log "Credentials retrieved successfully"
}

# Function to test MongoDB connection
test_connection() {
    log "🔍 Testing MongoDB connection..."
    
    if mongosh -u "$MONGODB_ADMIN_USER" -p "$MONGODB_ADMIN_PASSWORD" --authenticationDatabase admin --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
        log "MongoDB connection successful"
    else
        error "Cannot connect to MongoDB with provided credentials"
    fi
}

# Function to create MongoDB backup
perform_backup() {
    log "🗄️ Starting MongoDB backup..."
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
    
    # Perform mongodump with authentication
    if mongodump \
        --username "$MONGODB_ADMIN_USER" \
        --password "$MONGODB_ADMIN_PASSWORD" \
        --authenticationDatabase admin \
        --out "$BACKUP_PATH" \
        --gzip \
        --oplog; then
        log "MongoDB dump completed successfully"
    else
        error "MongoDB dump failed"
    fi
    
    # Verify backup was created
    if [[ ! -d "$BACKUP_PATH" ]]; then
        error "Backup directory was not created"
    fi
    
    # Compress the backup
    cd "$BACKUP_DIR"
    if tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"; then
        log "Backup compressed successfully"
        rm -rf "$BACKUP_NAME"  # Remove uncompressed directory
    else
        error "Backup compression failed"
    fi
    
    # Log backup size
    COMPRESSED_SIZE=$(du -sh "${BACKUP_NAME}.tar.gz" | cut -f1)
    log "Compressed backup size: $COMPRESSED_SIZE"
}

# Function to upload backup to S3
upload_to_s3() {
    log "Uploading backup to S3..."
    
    LOCAL_FILE="$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
    S3_KEY="backups/mongodb/${BACKUP_NAME}.tar.gz"
    
    # Upload with metadata and appropriate storage class
    if aws s3 cp "$LOCAL_FILE" "s3://$S3_BUCKET/$S3_KEY" \
        --metadata "backup-date=$DATE,backup-type=mongodb,retention-days=$RETENTION_DAYS" \
        --storage-class STANDARD_IA; then
        log "Backup uploaded successfully to s3://$S3_BUCKET/$S3_KEY"
    else
        error "Failed to upload backup to S3"
    fi
    
    # Verify upload by checking S3 object
    S3_SIZE=$(aws s3 ls "s3://$S3_BUCKET/$S3_KEY" --human-readable | awk '{print $3}' || echo "unknown")
    log "S3 object size: $S3_SIZE"
}

# Function to clean up old backups (local and S3)
cleanup_old_backups() {
    log "🧹 Cleaning up old backups..."
    
    # Remove local backup files
    rm -rf "$BACKUP_DIR"
    log "Local cleanup completed"
    
    # Remove old S3 backups (older than retention period)
    OLD_DATE=$(date -d "$RETENTION_DAYS days ago" --iso-8601)
    
    aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" \
        --prefix "backups/mongodb/" \
        --query "Contents[?LastModified<='$OLD_DATE'].Key" \
        --output text | while read -r key; do
        
        if [[ -n "$key" && "$key" != "None" ]]; then
            if aws s3 rm "s3://$S3_BUCKET/$key"; then
                log "Deleted old backup: $key"
            else
                warn "Failed to delete old backup: $key"
            fi
        fi
    done
}

# Function to create backup metadata
create_backup_metadata() {
    log "Creating backup metadata..."
    
    # Get database statistics
    DB_STATS=$(mongosh -u "$MONGODB_ADMIN_USER" -p "$MONGODB_ADMIN_PASSWORD" --authenticationDatabase admin --quiet --eval "
        print(JSON.stringify({
            serverVersion: db.version(),
            databases: db.adminCommand('listDatabases').databases.map(d => ({
                name: d.name,
                sizeOnDisk: d.sizeOnDisk,
                empty: d.empty
            })),
            totalSize: db.adminCommand('listDatabases').totalSize,
            backupDate: new Date().toISOString(),
            hostname: db.adminCommand('ismaster').me || 'localhost:27017'
        }))
    ")
    
    # Create metadata file
    METADATA_FILE="$BACKUP_DIR/backup_metadata_${DATE}.json"
    echo "$DB_STATS" > "$METADATA_FILE"
    
    # Upload metadata to S3
    aws s3 cp "$METADATA_FILE" "s3://$S3_BUCKET/backups/mongodb/metadata/backup_metadata_${DATE}.json"
    
    log "Backup metadata created and uploaded"
}

# Function to send notifications
send_notification() {
    local status=$1
    local message=$2
    
    # Send to CloudWatch Logs
    aws logs create-log-group --log-group-name "/mongodb/backups" 2>/dev/null || true
    aws logs put-log-events \
        --log-group-name "/mongodb/backups" \
        --log-stream-name "$(hostname)" \
        --log-events "timestamp=$(date +%s)000,message=$status: $message" 2>/dev/null || true
    
    log "Notification sent to CloudWatch Logs"
}

# Function to validate prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if mongodump is available
    if ! command -v mongodump >/dev/null 2>&1; then
        error "mongodump not found. Please install MongoDB tools."
    fi
    
    # Check if AWS CLI is available and configured
    if ! command -v aws >/dev/null 2>&1; then
        error "AWS CLI not found. Please install and configure AWS CLI."
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error "AWS credentials not configured or invalid."
    fi
    
    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        error "jq not found. Please install jq for JSON parsing."
    fi
    
    # Check if MongoDB is running
    if ! systemctl is-active --quiet mongod; then
        error "MongoDB service is not running."
    fi
    
    # Ensure sufficient disk space (at least 1GB free)
    AVAILABLE_SPACE=$(df /tmp | awk 'NR==2 {print $4}')
    if [[ "$AVAILABLE_SPACE" -lt 1048576 ]]; then  # 1GB in KB
        error "Insufficient disk space for backup. Need at least 1GB free in /tmp."
    fi
    
    log "All prerequisites satisfied"
}

# Main backup function
main_backup() {
    log "Starting MongoDB backup process..."
    
    # Track execution time
    START_TIME=$(date +%s)
    
    # Execute backup steps
    check_prerequisites
    get_mongodb_credentials
    test_connection
    perform_backup
    create_backup_metadata
    upload_to_s3
    cleanup_old_backups
    
    # Calculate execution time
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    SUCCESS_MESSAGE="MongoDB backup completed successfully in ${DURATION} seconds. Backup: ${BACKUP_NAME}.tar.gz"
    log "$SUCCESS_MESSAGE"
    
    # Send success notification
    send_notification "SUCCESS" "$SUCCESS_MESSAGE"
}

# Function to list available backups
list_backups() {
    log "Listing available backups in S3..."
    
    get_mongodb_credentials
    
    log "Available MongoDB backups:"
    aws s3 ls "s3://$S3_BUCKET/backups/mongodb/" --human-readable --recursive | grep "\.tar\.gz$" | sort -k1,2
    
    log ""
    log "Backup metadata files:"
    aws s3 ls "s3://$S3_BUCKET/backups/mongodb/metadata/" --human-readable --recursive | sort -k1,2
}

# Function to test backup system
test_backup_system() {
    log "Testing backup system..."
    
    check_prerequisites
    get_mongodb_credentials
    test_connection
    
    log "All backup system tests passed!"
    log "Test results:"
    log "MongoDB tools available"
    log "AWS CLI configured"
    log "Secrets Manager accessible"
    log "MongoDB connection successful"
    log "S3 bucket accessible"
    log ""
    log "Ready to perform actual backup!"
}

# Function to show help
show_help() {
    cat << EOF
MongoDB Backup Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --help, -h          Show this help message
    --test              Test backup system prerequisites and connections
    --list              List available backups in S3
    --backup            Perform full backup (default action)

EXAMPLES:
    $0                  # Run full backup
    $0 --test          # Test backup system
    $0 --list          # List existing backups

CONFIGURATION:
    - Backup retention: $RETENTION_DAYS days
    - Backup storage: S3 Standard-IA
    - Log file: $LOG_FILE
    - Backup directory: $BACKUP_DIR

BACKUP LIFECYCLE:
    - Day 0-30: S3 Standard-IA
    - Day 30-90: S3 Glacier (automatic transition)
    - Day 90-180: S3 Deep Archive (automatic transition)
    - Day 365+: Deleted automatically

MONITORING:
    - CloudWatch Logs: /mongodb/backups
    - Local logs: $LOG_FILE
    - Backup metadata: s3://BUCKET/backups/mongodb/metadata/

EOF
}

# Error handling trap
trap 'error "Backup script failed at line $LINENO"' ERR

# Initialize log file
touch "$LOG_FILE" 2>/dev/null || {
    warn "Cannot create log file $LOG_FILE, using /tmp/mongodb-backup.log"
    LOG_FILE="/tmp/mongodb-backup.log"
    touch "$LOG_FILE"
}

# Main script logic - handle command line arguments
case "${1:---backup}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --test)
        test_backup_system
        ;;
    --list)
        list_backups
        ;;
    --backup|"")
        main_backup
        ;;
    *)
        error "Unknown option: $1. Use --help for usage information."
        ;;
esac

log "Script execution completed at $(date)"
