#!/bin/bash

# ==========================================
# 1. HARDENED ENVIRONMENT & LOGGING
# ==========================================
export GTK_THEME_VARIANT=dark

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="$SCRIPT_DIR/procopy_$(date +%Y%m%d_%H%M%S).log"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

MAX_THREADS=$(nproc 2>/dev/null || echo 4)
log "=== ProCopy Job Started ==="

# ==========================================
# 2. RECURSIVE PROCESS ASSASSIN
# ==========================================
kill_descendants() {
    local target_pid=$1
    local children=$(pgrep -P "$target_pid" 2>/dev/null)
    for child in $children; do
        kill_descendants "$child"
        kill -9 "$child" 2>/dev/null
    done
}

cleanup() {
    log "Initiating shutdown and sweeping process tree..."
    kill_descendants $$
    rm -f "$MANIFEST" "$VERIFY_LOG" /tmp/pc_chunk_* /tmp/pc_pipe_* 2>/dev/null
    log "System sanitized."
}
trap cleanup EXIT INT TERM

for cmd in rsync zenity awk find md5sum numfmt df mktemp split xargs lsblk sort mkfifo; do
    if ! command -v $cmd &> /dev/null; then
        log "FATAL: Missing dependency: $cmd"
        zenity --error --text="Critical dependency missing: $cmd"
        exit 1
    fi
done

MANIFEST=$(mktemp /tmp/pc_manifest_XXXXXX.md5)
VERIFY_LOG=$(mktemp /tmp/pc_verify_XXXXXX.log)

# ==========================================
# 3. GUI STAGING AREA
# ==========================================
SOURCES=()

escape_pango() {
    echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

while true; do
    if [ ${#SOURCES[@]} -eq 0 ]; then
        MSG="Staging Area Empty\n\nChoose what you want to add to your transfer list:"
    else
        DISPLAY_LIST=""
        COUNT=0
        for s in "${SOURCES[@]}"; do
            DISPLAY_LIST+=" * $(basename "$s")\n"
            COUNT=$((COUNT+1))
            if [ $COUNT -ge 5 ]; then
                REMAINING=$((${#SOURCES[@]} - 5))
                [ $REMAINING -gt 0 ] && DISPLAY_LIST+=" ...and $REMAINING more items\n"
                break
            fi
        done
        MSG="Currently Selected (${#SOURCES[@]} items):\n\n$DISPLAY_LIST\nWhat would you like to do next?"
    fi

    ACTION=$(zenity --list --title="ProCopy Staging Area" \
        --text "$MSG" \
        --column="Selection" --column="Action" \
        "Add FILES" "Select individual files (Hold CTRL for multiple)" \
        "Add FOLDER" "Select an entire directory" \
        "Clear List" "Remove all selected items" \
        "PROCEED" "Move to destination selection" \
        --hide-header --width=450 --height=400 </dev/null 2>> "$LOG_FILE")

    EXIT_CODE=$?
    [[ $EXIT_CODE -ne 0 ]] && exit 
    [[ -z "$ACTION" ]] && continue 

    case "$ACTION" in
        "Add FILES")
            NEW_FILES=$(zenity --file-selection --multiple --title="Select Files" --separator="|" </dev/null 2>> "$LOG_FILE")
            if [[ -n "$NEW_FILES" ]]; then
                IFS='|' read -ra ARR <<< "$NEW_FILES"
                SOURCES+=("${ARR[@]}")
            fi
            ;;
        "Add FOLDER")
            NEW_DIR=$(zenity --file-selection --directory --title="Select Folder (Navigate inside and click OK)" </dev/null 2>> "$LOG_FILE")
            if [[ -n "$NEW_DIR" ]]; then
                SOURCES+=("$NEW_DIR")
            fi
            ;;
        "Clear List")
            SOURCES=()
            ;;
        "PROCEED")
            if [ ${#SOURCES[@]} -gt 0 ]; then
                break
            else
                zenity --warning --title="Empty Selection" --text="Please add at least one file or folder before proceeding." </dev/null 2>> "$LOG_FILE"
            fi
            ;;
    esac
done

DEST_BASE=$(zenity --file-selection --directory --title="Select DESTINATION Base Folder" </dev/null 2>> "$LOG_FILE")
[[ $? -ne 0 || -z "$DEST_BASE" ]] && exit

# ==========================================
# 4. SMART ROUTING & SOURCE LOGGING
# ==========================================
ROUTE_ACTION=$(zenity --list --radiolist --title="Transfer Destination" \
    --text "You selected ${#SOURCES[@]} item(s).\nHow do you want to store them?" \
    --column="Select" --column="Option" \
    TRUE "Copy directly into: $(basename "$DEST_BASE")" \
    FALSE "Group into a new subfolder" \
    --width=450 --height=220 </dev/null 2>> "$LOG_FILE")
[[ -z "$ROUTE_ACTION" ]] && exit

if [[ "$ROUTE_ACTION" == *"Group"* ]]; then
    NEW_FOLDER=$(zenity --entry --title="New Folder Name" --text="Enter name for the new folder:" </dev/null 2>> "$LOG_FILE")
    [[ -z "$NEW_FOLDER" ]] && exit
    TARGET_DIR="$DEST_BASE/$NEW_FOLDER"
    
    if [ -d "$TARGET_DIR" ]; then
        CHOICE=$(zenity --list --radiolist --title="Folder Conflict" \
            --text "The folder '$NEW_FOLDER' already exists.\nAction:" \
            --column="Select" --column="Action" \
            TRUE "Merge (Strictly add new files)" \
            FALSE "Auto-rename (Append number)" --width=450 --height=220 </dev/null 2>> "$LOG_FILE")
        [[ -z "$CHOICE" ]] && exit
        if [[ "$CHOICE" == *"Auto-rename"* ]]; then
            COUNTER=1
            while [ -d "${TARGET_DIR}_$COUNTER" ]; do COUNTER=$((COUNTER+1)); done
            TARGET_DIR="${TARGET_DIR}_$COUNTER"
        fi
    fi
else
    TARGET_DIR="$DEST_BASE"
fi

mkdir -p "$TARGET_DIR"
log "Final Target Directory: $TARGET_DIR"

log "--- Selected Source Items ---"
for s in "${SOURCES[@]}"; do
    log "-> $s"
done
log "-----------------------------"

# ==========================================
# 5. HARDWARE DETECTION ENGINE
# ==========================================
zenity --info --title="Scanning" --text "Analyzing destination architecture and calculating payload..." --timeout=2 </dev/null 2>> "$LOG_FILE"

TARGET_FS=$(df -T "$TARGET_DIR" | awk 'NR==2 {print $2}')
TARGET_DEV=$(df -P "$TARGET_DIR" | awk 'NR==2 {print $1}')

if [[ "$TARGET_FS" =~ ^(nfs|cifs|smb3|smbfs|fuse.*)$ ]]; then
    VERIFY_THREADS=1
    HW_PROFILE="Network or FUSE Drive"
else
    ROTATIONAL=$(lsblk -d -n -o ROTATIONAL "$TARGET_DEV" 2>/dev/null)
    if [ "$ROTATIONAL" = "0" ]; then
        VERIFY_THREADS=$MAX_THREADS
        HW_PROFILE="Solid State Drive (SSD)"
    else
        VERIFY_THREADS=1
        HW_PROFILE="Mechanical Drive (HDD) or Unknown Block"
    fi
fi
log "Destination Profile: $HW_PROFILE. Verification locked to $VERIFY_THREADS thread(s)."

# ==========================================
# 6. PRE-FLIGHT RESOURCE CHECK
# ==========================================
STATS=$(LC_COLLATE=C rsync -an8 --ignore-existing --stats "${SOURCES[@]}" "$TARGET_DIR/")
REQ_BYTES=$(echo "$STATS" | awk '/Total transferred file size/ {print $5}' | tr -d ',')
AVAIL_BYTES=$(LC_COLLATE=C df -P -B1 "$TARGET_DIR" | awk 'NR==2 {print $4}')

if [ "$REQ_BYTES" -gt "$AVAIL_BYTES" ]; then
    log "FATAL: Insufficient disk space."
    zenity --error --title="Disk Full" --text "Insufficient space on destination!\n\nRequired: $(numfmt --to=iec --suffix=B $REQ_BYTES)\nAvailable: $(numfmt --to=iec --suffix=B $AVAIL_BYTES)" </dev/null 2>> "$LOG_FILE"
    exit 1
fi
TOTAL_HR=$(numfmt --to=iec --suffix=B "$REQ_BYTES")

SRC_NAMES=""
for s in "${SOURCES[@]}"; do SRC_NAMES+="$(basename "$s"), "; done
SRC_NAMES="${SRC_NAMES%, }"
[ ${#SRC_NAMES} -gt 50 ] && SRC_NAMES="${SRC_NAMES:0:47}..."
DEST_STR=$(escape_pango "$TARGET_DIR")
[ ${#DEST_STR} -gt 55 ] && DEST_STR="...${DEST_STR: -52}"

# ==========================================
# 7. PHASE 1: TETHERED BATCH TRANSFER
# ==========================================
(
# THE CYANIDE PILL: Subshell cleans up its own children before dying
trap 'kill_descendants $BASHPID 2>/dev/null' EXIT INT TERM PIPE

echo "# Initializing Transfer Protocol..." || exit 1
CUMULATIVE_PREV=0

for src in "${SOURCES[@]}"; do
    parent=$(dirname "$src")
    base=$(basename "$src")
    
    ITEM_STATS=$(LC_COLLATE=C rsync -an8 --ignore-existing --stats "$src" "$TARGET_DIR/")
    ITEM_BYTES=$(echo "$ITEM_STATS" | awk '/Total transferred file size/ {print $5}' | tr -d ',')
    [ -z "$ITEM_BYTES" ] && ITEM_BYTES=0
    
    HASH_PIPE=$(mktemp -u /tmp/pc_pipe_XXXXXX)
    mkfifo "$HASH_PIPE"
    
    (
        cd "$parent" || exit
        # The hasher reads directly from the named pipe tether
        while IFS= read -r filepath; do
            # Final fix: Only filters out whitespace to catch all valid filenames (even with % signs)
            if [[ -n "$filepath" && ! "$filepath" =~ ^[[:space:]] ]]; then
                # Safe-guards against symbolic links double-hashing
                if [ -f "$filepath" ] && [ ! -L "$filepath" ]; then
                    md5sum "./$filepath" >> "$MANIFEST"
                fi
            fi
        done < "$HASH_PIPE"
    ) &
    PID_HASHER=$!

    # stdbuf and tee push the rsync output to both the UI and the hasher's pipe simultaneously
    LC_COLLATE=C rsync -a8 --ignore-existing --info=name1,progress2 --no-inc-recursive "$src" "$TARGET_DIR/" | \
    stdbuf -oL tr '\r' '\n' | tee "$HASH_PIPE" | while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)% ]]; then
            CURRENT_BYTES=$(echo "$line" | awk '{print $1}' | tr -d ',')
            TOTAL_TRANSFERRED=$(awk -v cur="$CURRENT_BYTES" -v prev="$CUMULATIVE_PREV" 'BEGIN {print cur + prev}')
            
            PERCENT=$(awk -v tot="$TOTAL_TRANSFERRED" -v req="$REQ_BYTES" 'BEGIN {if(req>0) printf "%d", (tot/req)*100; else print 100}')
            [ "$PERCENT" -gt 100 ] && PERCENT=100
            
            SPEED=$(echo "$line" | awk '{print $3}')
            MOVED_HR=$(numfmt --to=iec --suffix=B "$TOTAL_TRANSFERRED")
            
            echo "$PERCENT" || exit 1
            echo "# To: $DEST_STR\nFrom: $SRC_NAMES\nCopied: $MOVED_HR / $TOTAL_HR\nSpeed: $SPEED\nFile: $CURRENT_FILE" || exit 1
        elif [[ -n "$line" && ! "$line" =~ ^[[:space:]] ]]; then
            safe_file=$(escape_pango "$line")
            CURRENT_FILE=$(echo "$safe_file" | cut -c1-50)"..."
        fi
    done
    
    wait $PID_HASHER 2>/dev/null
    rm -f "$HASH_PIPE"
    
    CUMULATIVE_PREV=$(awk -v cur="$ITEM_BYTES" -v prev="$CUMULATIVE_PREV" 'BEGIN {print cur + prev}')
done
) | zenity --progress --title="Data Transfer (Phase 1)" --percentage=0 --auto-close --auto-kill --width=500 2>> "$LOG_FILE"
[[ $? -ne 0 ]] && exit

TOTAL_FILES=$(wc -l < "$MANIFEST" 2>/dev/null || echo 0)

# ==========================================
# 8. PHASE 2: HARDWARE-AWARE VERIFICATION
# ==========================================
if [ "$TOTAL_FILES" -gt 0 ]; then
    (
    # THE CYANIDE PILL: Subshell cleans up its own children before dying
    trap 'kill_descendants $BASHPID 2>/dev/null' EXIT INT TERM PIPE
    
    echo "0" || exit 1
    echo "# Target Architecture: $HW_PROFILE\n# Deploying $VERIFY_THREADS integrity engine(s)..." || exit 1
    
    split -n l/"$VERIFY_THREADS" "$MANIFEST" /tmp/pc_chunk_
    
    (
    cd "$TARGET_DIR" || exit
    ls /tmp/pc_chunk_* | xargs -n 1 -P "$VERIFY_THREADS" -I {} bash -c "md5sum -c '{}' >> '$VERIFY_LOG' 2>/dev/null"
    ) &
    PID_VERIFY=$!

    while kill -0 $PID_VERIFY 2>/dev/null; do
        if [ -f "$VERIFY_LOG" ]; then
            current=$(wc -l < "$VERIFY_LOG" 2>/dev/null || echo 0)
            percent=$((current * 100 / TOTAL_FILES))
            echo "$percent" || exit 1
            echo "# To: $DEST_STR\nVerifying: $current / $TOTAL_FILES files\nStatus: Architecture limits set to $VERIFY_THREADS core(s)..." || exit 1
        fi
        sleep 0.2
    done
    echo "100" || exit 1
    sleep 0.5
    ) | zenity --progress --title="Integrity Check (Phase 2)" --percentage=0 --auto-close --auto-kill --width=500 2>> "$LOG_FILE"
    [[ $? -ne 0 ]] && exit
fi

# ==========================================
# 9. FINAL LOGGING & REPORTING
# ==========================================
if [ -f "$VERIFY_LOG" ]; then
    ERROR_COUNT=$(grep -c "FAILED" "$VERIFY_LOG")
    if [ "$ERROR_COUNT" -eq 0 ]; then
        log "Hardware-Aware Verification passed perfectly."
        zenity --info --title="Success" --text "Verification Complete!\n\nAll items are 100% identical and safely backed up." </dev/null 2>> "$LOG_FILE"
    else
        log "WARNING: $ERROR_COUNT files failed verification!"
        grep "FAILED" "$VERIFY_LOG" >> "$LOG_FILE"
        zenity --error --title="Integrity Error" --text "Alert! $ERROR_COUNT files failed verification.\nDetails have been written to the log file." </dev/null 2>> "$LOG_FILE"
    fi
fi
