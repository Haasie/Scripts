#!/bin/bash

# Script Information
# Description: Advanced duplicate file finder and remover
# Version: 1.1
# Author: Community Contributor

# Set strict error handling
set -euo pipefail

# Configuration with enhanced defaults
VERBOSE=0
DRY_RUN=0
AUTO_DELETE=0
KEEP_STRATEGY="first"
MAX_FILE_SIZE=$((100 * 1024 * 1024))  # 100MB default max file size
HASH_ALGORITHM="md5sum"

# Validate keep strategies
VALID_STRATEGIES=("first" "last" "oldest" "newest")

# Detect OS and set stat command
if stat --version >/dev/null 2>&1; then
    STAT_CMD='stat -c %Y'   # GNU/Linux
else
    STAT_CMD='stat -f %m'   # macOS/BSD
fi

# Usage function
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -v, --verbose         Enable verbose output"
    echo "  --dry-run             Simulate file removal without actual deletion"
    echo "  --delete              Automatically delete duplicate files"
    echo "  --keep STRATEGY       File keeping strategy (first/last/oldest/newest)"
    echo "  -d DIRECTORY          Target directory for duplicate search"
    echo "  --max-size SIZE       Maximum file size to process (bytes)"
    echo "  --hash ALGORITHM      Hash algorithm (md5sum/sha256sum)"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --delete) AUTO_DELETE=1 ;;
        --keep)
            if [[ ! " ${VALID_STRATEGIES[@]} " =~ " $2 " ]]; then
                echo "Error: Invalid keep strategy. Choose from: ${VALID_STRATEGIES[*]}" >&2
                exit 1
            fi
            KEEP_STRATEGY="$2"
            shift
            ;;
        -d)
            # Use realpath to resolve and sanitize directory path
            directory=$(realpath "$2")
            shift
            ;;
        --max-size)
            MAX_FILE_SIZE="$2"
            shift
            ;;
        --hash)
            HASH_ALGORITHM="$2"
            shift
            ;;
        -h|--help) usage ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
    shift
done

# Safety checks
if [ $AUTO_DELETE -eq 1 ] && [ $DRY_RUN -eq 1 ]; then
    echo "Error: Cannot use both --delete and --dry-run" >&2
    exit 1
fi

if [ -z "${directory:-}" ]; then
    echo "Error: Directory not specified. Use -d to provide a directory." >&2
    exit 1
fi

# Additional safety checks
if [ ! -d "$directory" ]; then
    echo "Error: Directory '$directory' does not exist." >&2
    exit 1
fi

# Prevent accidental deletion in root or critical system directories
if [[ "$directory" =~ ^(/|/bin|/etc|/usr|/var|/home)$ ]]; then
    echo "Error: Cannot process files in system-critical directories." >&2
    exit 1
fi

# Check directory read permissions
if [ ! -r "$directory" ]; then
    echo "Error: No read permissions for directory '$directory'." >&2
    exit 1
fi

[ "$VERBOSE" -eq 1 ] && echo "🔍 Scanning directory: $directory"

# Temporary files setup
sorted_tempfile=$(mktemp)
log_file=$(mktemp)

# Trap to ensure cleanup
trap 'rm -f "$sorted_tempfile" "$log_file"' EXIT

# File discovery and hashing (handle spaces, limit file size)
find "$directory" -type f -size -"$MAX_FILE_SIZE"c -print0 | \
    xargs -0 "$HASH_ALGORITHM" | sort -z > "$sorted_tempfile"

# Duplicate detection and deletion
awk -v dry_run="$DRY_RUN" -v auto_delete="$AUTO_DELETE" \
    -v keep_strategy="$KEEP_STRATEGY" -v verbose="$VERBOSE" \
    -v stat_cmd="$STAT_CMD" -v log_file="$log_file" \
    -v OFS="\t" -v ORS="\n" '
BEGIN { RS="\0" }  # Read null-separated records

{
    hash = $1
    file = substr($0, index($0, $2))  # Preserve full path with spaces

    if (hash == prev_hash) {
        if (!duplicate_group) {
            files_in_group[0] = prev_file
            duplicate_group = 1
            group_hash = hash
        }
        files_in_group[length(files_in_group)] = file
    } else {
        process_group()
        duplicate_group = 0
        delete files_in_group
        prev_hash = hash
        prev_file = file
    }
}
END { process_group() }

function get_keep_index(    i, times, keep_time, keep_index, cmd) {
    keep_index = 0
    for (i in files_in_group) {
        cmd = stat_cmd " \"" files_in_group[i] "\""
        cmd | getline times
        close(cmd)

        if (keep_strategy == "oldest" && (i == 0 || times < keep_time)) {
            keep_time = times
            keep_index = i
        }
        if (keep_strategy == "newest" && (i == 0 || times > keep_time)) {
            keep_time = times
            keep_index = i
        }
        if (keep_strategy == "last") keep_index = length(files_in_group) - 1
    }
    return keep_index
}

function process_group(    i, keep_index, cmd, exit_status, log_entry) {
    if (length(files_in_group) > 0) {
        keep_index = (keep_strategy == "first") ? 0 : get_keep_index()

        if (verbose) {
            log_entry = sprintf("\n🚨 Duplicate group (Hash: %s):\n", group_hash)
            for (i in files_in_group) {
                log_entry = log_entry sprintf("  %s %s\n",
                    (i == keep_index ? "[KEEP]" : "[DEL]"), files_in_group[i])
            }
            system("echo \"" log_entry "\" >> " log_file)
        }

        for (i in files_in_group) {
            if (i != keep_index) {
                if (dry_run) {
                    print "Would remove: \"" files_in_group[i] "\""
                } else if (auto_delete) {
                    cmd = "rm -f -- \"" files_in_group[i] "\""
                    exit_status = system(cmd)

                    if (exit_status != 0) {
                        system("echo '❗ Error: Failed to remove \"" files_in_group[i] "\"' >> " log_file)
                    }
                }
            }
        }
    }
}' "$sorted_tempfile"

# Final logging and cleanup
if [ "$VERBOSE" -eq 1 ]; then
    echo -e "\n🧹 Cleaning up temporary files"
    echo "📄 Detailed log available at: $log_file"
else
    rm -f "$log_file"
fi