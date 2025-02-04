#!/bin/bash

# Script Information
# Description: Advanced duplicate file finder and remover with efficiency improvements
# Version: 2.0
# Author: Community Contributor

# Set strict error handling
set -euo pipefail

# Configuration with enhanced defaults
VERBOSE=0
DRY_RUN=0
AUTO_DELETE=0
KEEP_STRATEGY="first"
MAX_FILE_SIZE=$((100 * 1024 * 1024))  # 100MB default max file size
VALID_STRATEGIES=("first" "last" "oldest" "newest")

# Detect OS and set commands
if stat --version >/dev/null 2>&1; then
    STAT_CMD='stat -c %Y'   # GNU/Linux
    FIND_TS_CMD="%T@"
else
    STAT_CMD='stat -f %m'   # macOS/BSD
    FIND_TS_CMD="%m"
fi

# Set default hash command
if command -v md5sum >/dev/null; then
    HASH_ALGORITHM="md5sum"
else
    HASH_ALGORITHM="md5 -r"  # macOS fallback
fi

# Enhanced help function
print_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -v, --verbose         Enable verbose output"
    echo "  --dry-run             Simulate file removal without actual deletion"
    echo "  --delete              Automatically delete duplicate files"
    echo "  --keep STRATEGY       File keeping strategy:"
    echo "                          first - keep first file in sorted order"
    echo "                          last - keep last file in sorted order"
    echo "                          oldest - keep file with oldest modification time"
    echo "                          newest - keep file with newest modification time"
    echo "  -d DIRECTORY          Target directory for duplicate search (required)"
    echo "  --max-size SIZE       Maximum file size to process in bytes"
    echo "  --hash ALGORITHM      Hash algorithm (supports md5sum/sha256sum/etc)"
    echo "  -h, --help            Show this help message"
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
            directory=$(realpath "$2" || echo "$2")
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
        -h|--help) print_help; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            print_help
            exit 1
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

if [ ! -d "$directory" ]; then
    echo "Error: Directory '$directory' does not exist." >&2
    exit 1
fi

if [[ "$directory" =~ ^(/|/bin|/etc|/usr|/var|/home)$ ]]; then
    echo "Error: Cannot process files in system-critical directories." >&2
    exit 1
fi

if [ ! -r "$directory" ]; then
    echo "Error: No read permissions for directory '$directory'." >&2
    exit 1
fi

if ! command -v "$HASH_ALGORITHM" >/dev/null 2>&1; then
    echo "Error: Hash command '$HASH_ALGORITHM' not found." >&2
    exit 1
fi

[ "$VERBOSE" -eq 1 ] && echo "[INFO] Scanning directory: $directory"

# Temporary files setup
sorted_tempfile=$(mktemp)
log_file=$(mktemp)
trap 'rm -f "$sorted_tempfile" "$log_file"' EXIT

# File discovery and hashing with timestamps
[ "$VERBOSE" -eq 1 ] && echo "[INFO] Generating file hashes..."
find "$directory" -type f -size -"$MAX_FILE_SIZE"c -print0 | while IFS= read -r -d '' file; do
    timestamp=$($STAT_CMD "$file")
    hash=$("$HASH_ALGORITHM" "$file" | awk '{print $1}')
    printf "%s\t%s\t%s\0" "$timestamp" "$hash" "$file"
done | sort -z -k2 > "$sorted_tempfile"

# Duplicate processing with error tracking
awk -v dry_run="$DRY_RUN" -v auto_delete="$AUTO_DELETE" \
    -v keep_strategy="$KEEP_STRATEGY" -v verbose="$VERBOSE" \
    -v log_file="$log_file" -v OFS="\t" -v ORS="\n" '
BEGIN { RS="\0"; FS="\t"; error_count=0 }

{
    timestamp = $1
    current_hash = $2
    file = $3

    if (current_hash == prev_hash) {
        if (!duplicate_group) {
            files_in_group[0]["ts"] = prev_timestamp
            files_in_group[0]["file"] = prev_file
            duplicate_group = 1
            group_hash = current_hash
        }
        files_in_group[length(files_in_group)]["ts"] = timestamp
        files_in_group[length(files_in_group)]["file"] = file
    } else {
        process_group()
        duplicate_group = 0
        delete files_in_group
        prev_hash = current_hash
        prev_file = file
        prev_timestamp = timestamp
    }
}

END {
    process_group()
    exit error_count
}

function get_keep_index(    i, keep_time, keep_index) {
    keep_index = 0
    for (i in files_in_group) {
        if (keep_strategy == "oldest" && (i == 0 || files_in_group[i]["ts"] < keep_time)) {
            keep_time = files_in_group[i]["ts"]
            keep_index = i
        }
        if (keep_strategy == "newest" && (i == 0 || files_in_group[i]["ts"] > keep_time)) {
            keep_time = files_in_group[i]["ts"]
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
            log_entry = sprintf("\n[DUPLICATES] Group (Hash: %s):\n", group_hash)
            for (i in files_in_group) {
                log_entry = log_entry sprintf("  %s %s\n",
                    (i == keep_index ? "[KEEP]" : "[DEL]"), files_in_group[i]["file"])
            }
            system("printf \"%s\" " escape(log_entry) " >> " log_file)
        }

        for (i in files_in_group) {
            if (i != keep_index) {
                file_path = files_in_group[i]["file"]
                if (dry_run) {
                    print "Would remove: \"" file_path "\""
                } else if (auto_delete) {
                    cmd = "rm -f -- " escape(file_path)
                    exit_status = system(cmd)
                    if (exit_status != 0) {
                        system("printf \"[ERROR] Failed to remove: %s\\n\" " escape(file_path) " >> " log_file)
                        error_count++
                    }
                }
            }
        }
    }
}

function escape(str) {
    gsub(/"/, "\\\"", str)
    return "\"" str "\""
}' "$sorted_tempfile"

# Handle awk exit status
awk_exit=$?
if [ $awk_exit -ne 0 ]; then
    echo "[WARNING] Some files could not be processed. Check log for details." >&2
fi

# Final reporting
if [ "$VERBOSE" -eq 1 ]; then
    echo -e "\n[CLEANUP] Removing temporary files"
    echo "[INFO] Detailed log available at: $log_file"
    cat "$log_file"
else
    rm -f "$log_file"
fi

exit $awk_exit