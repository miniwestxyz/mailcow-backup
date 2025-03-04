#!/bin/bash
# Mailcow Backup Script
# with different retention policies. Sends notifications via Gotify for success/failure.
# Created by: miniwestxyz
# Last updated: 2025-03-04

# Exit if any command fails
set -e

# Load environment variables from config file
CONFIG_FILE="/etc/mailcow-backup.env"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found at $CONFIG_FILE"
    exit 1
fi

# Source the configuration file
source "$CONFIG_FILE"

# Derived variables (not in config file)
DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_NAME="mailcow_backup_${DATE}"
TEMP_BACKUP_DIR="/tmp/${BACKUP_NAME}"
LOG_FILE="/var/log/mailcow-backup.log"

# Function for logging
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

# Function to send Gotify notifications
send_gotify_notification() {
    local title="$1"
    local message="$2"
    local priority="$3"
    
    log "Attempting to send Gotify notification: $title"
    
    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        log "ERROR: curl not found. Cannot send Gotify notification."
        return 1
    fi
    
    # Check if GOTIFY_URL and GOTIFY_TOKEN are set
    if [ -z "$GOTIFY_URL" ] || [ -z "$GOTIFY_TOKEN" ]; then
        log "ERROR: Gotify URL or token is empty. Please check your configuration."
        return 1
    fi
    
    # Send notification
    curl -s -X POST \
         "$GOTIFY_URL/message" \
         -H "Content-Type: application/json" \
         -H "X-Gotify-Key: $GOTIFY_TOKEN" \
         -d "{\"title\":\"$title\",\"message\":\"$message\",\"priority\":$priority}" > /dev/null
    
    local curl_exit_code=$?
    
    if [ $curl_exit_code -ne 0 ]; then
        log "ERROR: Gotify notification failed with exit code: $curl_exit_code"
        return 1
    fi
    
    log "Gotify notification sent successfully"
    return 0
}

# Test Gotify connection
test_gotify_connection() {
    log "Testing Gotify connection..."
    
    if send_gotify_notification "Backup Test" "Mailcow backup script is testing Gotify connection at $(date)" "$GOTIFY_SUCCESS_PRIORITY"; then
        log "Gotify connection test successful"
    else
        log "WARNING: Gotify connection test failed. Notifications may not work."
    fi
}

# Function to handle errors
handle_error() {
    local error_message="$1"
    
    log "ERROR: $error_message"
    
    # Send notification
    send_gotify_notification "Mailcow Backup Failed" "Error: $error_message" "$GOTIFY_PRIORITY"
    
    # Clean up any temporary files
    [ -d "$TEMP_BACKUP_DIR" ] && rm -rf "$TEMP_BACKUP_DIR"
    
    exit 1
}

# Calculate directory size in human-readable format
get_dir_size() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sh "$dir" | awk '{print $1}'
    else
        echo "N/A"
    fi
}

# Count backups in a directory
count_backups() {
    local dir="$1"
    if [ -d "$dir" ]; then
        find "$dir" -maxdepth 1 -type d -name "mailcow_backup_*" | wc -l
    else
        echo "0"
    fi
}

# Check if required directories exist
check_directories() {
    log "Checking required directories..."
    
    # Check if Mailcow directory exists
    if [ ! -d "$MAILCOW_DIR" ]; then
        handle_error "Mailcow directory not found at $MAILCOW_DIR"
    fi
    
    # Check SMB mounts
    for SHARE in "$SMB_SHARE1" "$SMB_SHARE2"; do
        if [ ! -d "$SHARE" ]; then
            handle_error "SMB share not mounted at $SHARE"
        fi
        
        # Test write permissions
        if ! touch "$SHARE/test_write_permission" 2>/dev/null; then
            handle_error "Cannot write to SMB share at $SHARE"
        else
            rm "$SHARE/test_write_permission"
        fi
    done
    
    log "Required directories check passed"
}

# Create backup using Mailcow's built-in script
create_backup() {
    log "Starting Mailcow backup..."
    
    # Create a temporary directory for the backup
    mkdir -p "$TEMP_BACKUP_DIR"
    
    # Run the backup script with multithreading
    cd "$MAILCOW_DIR" || handle_error "Failed to change to Mailcow directory"
    
    THREADS="$THREADS" MAILCOW_BACKUP_LOCATION="$TEMP_BACKUP_DIR" \
        "$MAILCOW_DIR/helper-scripts/backup_and_restore.sh" backup "$BACKUP_COMPONENTS" || handle_error "Backup creation failed"
    
    log "Backup created successfully at $TEMP_BACKUP_DIR"
}

# Copy backup to SMB share with custom retention
copy_to_smb_with_retention() {
    local share="$1"
    local retention_count="$2"
    local share_name="$3"
    
    log "Copying backup to $share_name at $share..."
    
    # Create backup directory on the share if it doesn't exist
    mkdir -p "$share/mailcow_backups"
    
    # Copy backup to SMB share
    rsync -avh --delete "$TEMP_BACKUP_DIR/" "$share/mailcow_backups/$BACKUP_NAME/" || handle_error "Failed to copy backup to $share"
    
    log "Backup successfully copied to $share/mailcow_backups/$BACKUP_NAME/"
    
    # Keep only the specified number of most recent backups
    log "Applying retention policy to $share_name (keeping $retention_count most recent backups)..."
    
    # List all backup directories, sort by modification time (newest first)
    local backup_dirs=( $(find "$share/mailcow_backups/" -maxdepth 1 -type d -name "mailcow_backup_*" | xargs ls -dt 2>/dev/null) )
    local count=${#backup_dirs[@]}
    
    if [ $count -gt $retention_count ]; then
        log "Found $count backups, removing $(($count-$retention_count)) old backups..."
        
        # Delete older backups exceeding retention count
        for (( i=$retention_count; i<$count; i++ )); do
            log "Removing old backup: ${backup_dirs[$i]}"
            rm -rf "${backup_dirs[$i]}"
        done
    else
        log "Found $count backups, which is within retention limit ($retention_count). No cleanup needed."
    fi
}

# Clean up temporary files
cleanup() {
    log "Cleaning up temporary files..."
    [ -d "$TEMP_BACKUP_DIR" ] && rm -rf "$TEMP_BACKUP_DIR"
    log "Cleanup completed"
}

# Collect and send report
send_success_report() {
    local smb1_size=$(get_dir_size "$SMB_SHARE1/mailcow_backups")
    local smb2_size=$(get_dir_size "$SMB_SHARE2/mailcow_backups")
    
    # Count backups on each share
    local smb1_count=$(count_backups "$SMB_SHARE1/mailcow_backups")
    local smb2_count=$(count_backups "$SMB_SHARE2/mailcow_backups")
    
    local report="Backup completed successfully at $(date).\n\n"
    report+="Storage Usage Report:\n"
    report+="- SMB Share 1: $smb1_size (${smb1_count} backups, retention: ${SMB1_RETENTION_COUNT})\n"
    report+="- SMB Share 2: $smb2_size (${smb2_count} backups, retention: ${SMB2_RETENTION_COUNT})\n"
    
    report+="\nLatest Backup:\n"
    report+="- $SMB_SHARE1/mailcow_backups/$BACKUP_NAME\n"
    report+="- $SMB_SHARE2/mailcow_backups/$BACKUP_NAME\n"
    
    send_gotify_notification "Mailcow Backup Successful" "$report" "$GOTIFY_SUCCESS_PRIORITY"
}

# Main function with error handling
main() {
    # Use trap to ensure we send notification on any error
    trap 'handle_error "Script failed unexpectedly"' ERR
    
    log "=== Starting Mailcow backup process at $(date) ==="
    
    # Test Gotify connection at the beginning
    test_gotify_connection
    
    check_directories
    create_backup
    copy_to_smb_with_retention "$SMB_SHARE1" "$SMB1_RETENTION_COUNT" "SMB Share 1"
    copy_to_smb_with_retention "$SMB_SHARE2" "$SMB2_RETENTION_COUNT" "SMB Share 2"
    
    cleanup
    send_success_report
    
    log "=== Backup process completed at $(date) ==="
}

# Run the script
main
