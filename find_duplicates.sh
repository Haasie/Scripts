#!/bin/bash

# Configuration
VERBOSE=0
DRY_RUN=0
AUTO_DELETE=0
KEEP_STRATEGY="first"  # Options: first, last, oldest, newest

# Detect OS and set stat command
if stat --version >/dev/null 2>&1; then
    STAT_CMD='stat -c %Y'   # GNU/Linux
else
    STAT_CMD='stat -f %m'   # macOS/BSD
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --delete) AUTO_DELETE=1 ;;
        --keep)
            KEEP_STRATEGY="$2"
            shift
            ;;
        -d)
            directory="$2"
            shift
            ;;
        *)
            echo "Usage: $0 [-v] [--dry-run] [--delete] [--keep first|last|oldest|newest] [-d directory]"
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

if [ -z "$directory" ]; then
    echo "Error: Directory not specified. Use -d to provide a directory." >&2
    exit 1
fi

[ "$VERBOSE" -eq 1 ] && echo "🔍 Scanning directory: $directory"

# Temporary files setup
sorted_tempfile=$(mktemp)

# File discovery and hashing (handle spaces with -print0 and -z)
find "$directory" -type f -print0 | xargs -0 md5sum | sort -z > "$sorted_tempfile"

# Duplicate detection and deletion
awk -v dry_run="$DRY_RUN" -v auto_delete="$AUTO_DELETE" \
    -v keep_strategy="$KEEP_STRATEGY" -v verbose="$VERBOSE" \
    -v stat_cmd="$STAT_CMD" -v OFS="\t" -v ORS="\n" '
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

function process_group(    i, keep_index, cmd, exit_status) {
    if (length(files_in_group) > 0) {
        keep_index = (keep_strategy == "first") ? 0 : get_keep_index()

        if (verbose) {
            printf "\n🚨 Duplicate group (MD5: %s):\n", group_hash
            for (i in files_in_group) {
                printf "  %s %s\n", (i == keep_index ? "[KEEP]" : "[DEL]"), files_in_group[i]
            }
        }

        for (i in files_in_group) {
            if (i != keep_index) {
                if (dry_run) {
                    print "Would remove: \"" files_in_group[i] "\""
                } else if (auto_delete) {
                    if (verbose) print "Removing: \"" files_in_group[i] "\""

                    cmd = "rm -- \"" files_in_group[i] "\""
                    exit_status = system(cmd)

                    if (exit_status != 0) {
                        print "❗ Error: Failed to remove \"" files_in_group[i] "\"" > "/dev/stderr"
                        if (verbose) print "   Exit status: " exit_status > "/dev/stderr"
                    }
                }
            }
        }
    }
}' "$sorted_tempfile"

# Cleanup
[ "$VERBOSE" -eq 1 ] && echo -e "\n🧹 Cleaned temporary files"
rm -f "$sorted_tempfile"