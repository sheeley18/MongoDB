#!/bin/bash
# MongoDB security setup script

set -euo pipefail

echo "🔒 Securing MongoDB Installation..."

if ! systemctl is-active --quiet mongod; then
    echo "MongoDB is not running. Starting it..."
    sudo systemctl start mongod
    sleep 10
fi

# Get passwords from AWS Secrets Manager
echo "Retrieving credentials from AWS Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id tasky/database/credentials --query SecretString --output text)
ADMIN_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.MONGODB_ADMIN_PASSWORD')
APP_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.MONGODB_PASSWORD')

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
    print('ℹApplication user already exists')
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
    sudo tee -a /etc/mongod.conf > /dev/null <<EOF

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
EOF

    echo "Restarting MongoDB..."
    sudo systemctl restart mongod
    sleep 15
else
    echo "ℹAuthentication already enabled"
fi

echo "Testing authentication..."
if mongosh -u admin -p "$ADMIN_PASSWORD" --authenticationDatabase admin --eval "db.adminCommand('ismaster')" > /dev/null 2>&1; then
    echo "Authentication working correctly!"
    echo "Connection URI: mongodb://tasky_app:***@$(hostname -I | awk '{print $1}'):27017/tasky?authSource=tasky"
else
    echo "Authentication test failed!"
    exit 1
fi

echo "🎉 MongoDB security setup complete!"