#!/bin/bash

# Log all output for debugging
exec > >(tee /var/log/backups-configuration.log) 2>&1

# Create the backup config file
cat > /etc/backup-config.conf << 'EOF'
${backup_config_content}
EOF

# Set proper permissions
chown root:root /etc/backup-config.conf
chmod 644 /etc/backup-config.conf

echo "Backup configuration setup completed"