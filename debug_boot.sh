#!/bin/bash
set -e

# Text styling
BOLD="\033[1m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NORMAL="\033[0m"

# Default values
OUTPUT_DIR="output"
IMAGE_PATH=""
BOOT_MODE="bios" # bios, uefi
ARCH="x86_64" # x86_64, aarch64
MEMORY="2G"
DEBUG_FILE="debug_llamafile_boot.log"
GDB_MODE=0
SERIAL_LOG="serial_output.log"
MONITOR_LOG="monitor_output.log"
WAIT_FOR_GDB=0
VERBOSE=0

# QEMU paths
QEMU_X86="qemu-system-x86_64"
QEMU_ARM="qemu-system-aarch64"

log() {
    local level="$1"
    local msg="$2"
    local color=""
    
    case "$level" in
        "INFO") color="$BLUE" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARNING") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        *) color="$NORMAL" ;;
    esac
    
    echo -e "${color}[$level]${NORMAL} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$DEBUG_FILE"
}

show_help() {
    echo -e "${BOLD}Bootable Llamafile Debug Tool${NORMAL}"
    echo ""
    echo "This script helps debug bootable llamafile images with detailed logging."
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  -i, --image PATH           Path to bootable image file (required)"
    echo "  -m, --mode MODE            Boot mode: bios, uefi (default: $BOOT_MODE)"
    echo "  -a, --arch ARCH            Architecture: x86_64, aarch64 (default: $ARCH)"
    echo "  -M, --memory SIZE          Memory for QEMU (default: $MEMORY)"
    echo "  -o, --output-dir DIR       Output directory for logs (default: $OUTPUT_DIR)"
    echo "  -g, --gdb                  Enable GDB debugging"
    echo "  -w, --wait                 Wait for GDB connection before starting"
    echo "  -v, --verbose              Enable verbose output"
    echo ""
    echo "Examples:"
    echo "  $0 --image output/bios_bootable.img"
    echo "  $0 --image output/uefi_bootable.img --mode uefi"
    echo "  $0 --image output/bootable_llamafile_with_model.com --gdb --wait"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -i|--image)
                IMAGE_PATH="$2"
                shift 2
                ;;
            -m|--mode)
                BOOT_MODE="$2"
                if [[ "$BOOT_MODE" != "bios" && "$BOOT_MODE" != "uefi" ]]; then
                    log "ERROR" "Invalid boot mode: $BOOT_MODE. Valid options: bios, uefi"
                    exit 1
                fi
                shift 2
                ;;
            -a|--arch)
                ARCH="$2"
                if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
                    log "ERROR" "Invalid architecture: $ARCH. Valid options: x86_64, aarch64"
                    exit 1
                fi
                shift 2
                ;;
            -M|--memory)
                MEMORY="$2"
                shift 2
                ;;
            -o|--output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -g|--gdb)
                GDB_MODE=1
                shift
                ;;
            -w|--wait)
                WAIT_FOR_GDB=1
                GDB_MODE=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$IMAGE_PATH" ]]; then
        log "ERROR" "Image path is required. Use -i or --image to specify."
        show_help
        exit 1
    fi

    if [[ ! -f "$IMAGE_PATH" ]]; then
        log "ERROR" "Image file not found: $IMAGE_PATH"
        exit 1
    fi
    
    # If UEFI boot is selected for ARM, check if firmware is available
    if [[ "$BOOT_MODE" == "uefi" && "$ARCH" == "aarch64" ]]; then
        local found=0
        for path in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI.fd; do
            if [[ -f "$path" ]]; then
                found=1
                break
            fi
        done
        
        if [[ $found -eq 0 ]]; then
            log "ERROR" "ARM64 UEFI firmware not found. Please install AAVMF package."
            exit 1
        fi
    fi

    # If UEFI boot is selected for x86_64, check if firmware is available
    if [[ "$BOOT_MODE" == "uefi" && "$ARCH" == "x86_64" ]]; then
        local found=0
        for path in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
            if [[ -f "$path" ]]; then
                found=1
                break
            fi
        done
        
        if [[ $found -eq 0 ]]; then
            log "ERROR" "x86_64 UEFI firmware not found. Please install OVMF package."
            exit 1
        fi
    fi
}

check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    local missing_deps=()
    
    # Check for QEMU
    if [[ "$ARCH" == "x86_64" ]]; then
        if ! command -v $QEMU_X86 &> /dev/null; then
            missing_deps+=($QEMU_X86)
        fi
    else
        if ! command -v $QEMU_ARM &> /dev/null; then
            missing_deps+=($QEMU_ARM)
        fi
    fi
    
    # Check for GDB if GDB mode is enabled
    if [[ $GDB_MODE -eq 1 ]]; then
        if ! command -v gdb &> /dev/null; then
            missing_deps+=(gdb)
        fi
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR" "Missing dependencies: ${missing_deps[*]}"
        log "INFO" "Please install the required dependencies and try again"
        exit 1
    fi
    
    log "SUCCESS" "All dependencies satisfied"
}

prepare_environment() {
    log "INFO" "Preparing debug environment..."
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Generate a debug session ID
    DEBUG_SESSION_ID=$(date +%Y%m%d_%H%M%S)
    SERIAL_LOG="$OUTPUT_DIR/serial_${DEBUG_SESSION_ID}.log"
    MONITOR_LOG="$OUTPUT_DIR/monitor_${DEBUG_SESSION_ID}.log"
    
    # Create log files
    touch "$SERIAL_LOG"
    touch "$MONITOR_LOG"
    
    log "INFO" "Serial output will be logged to: $SERIAL_LOG"
    log "INFO" "Monitor output will be logged to: $MONITOR_LOG"
    
    # Create a tmp directory for UEFI boot if needed
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        mkdir -p "$OUTPUT_DIR/debug_uefi"
        if [[ "$IMAGE_PATH" == *.efi ]]; then
            # If it's an EFI file, set up EFI directory structure
            mkdir -p "$OUTPUT_DIR/debug_uefi/EFI/BOOT"
            if [[ "$ARCH" == "x86_64" ]]; then
                cp "$IMAGE_PATH" "$OUTPUT_DIR/debug_uefi/EFI/BOOT/bootx64.efi"
            else
                cp "$IMAGE_PATH" "$OUTPUT_DIR/debug_uefi/EFI/BOOT/bootaa64.efi"
            fi
        fi
    fi
    
    log "SUCCESS" "Debug environment prepared"
}

create_gdb_script() {
    local gdb_script="$OUTPUT_DIR/debug_gdb_commands.gdb"
    local dbg_file="${IMAGE_PATH}.dbg"
    
    # Check if .dbg file exists
    if [[ ! -f "$dbg_file" && "$IMAGE_PATH" != *.dbg ]]; then
        # Try to find a .dbg file with similar name
        for f in "${IMAGE_PATH}.dbg" "${IMAGE_PATH%.*}.dbg"; do
            if [[ -f "$f" ]]; then
                dbg_file="$f"
                break
            fi
        done
    fi
    
    log "INFO" "Creating GDB script..."
    
    cat > "$gdb_script" << EOF
# GDB script for debugging bootable llamafile
set confirm off
set pagination off
set disassembly-flavor intel

# Connect to remote QEMU GDB server
target remote localhost:1234

# If a debug symbol file is available, load it
EOF

    if [[ -f "$dbg_file" ]]; then
        cat >> "$gdb_script" << EOF
echo Loading debug symbols from $dbg_file\n
file $dbg_file
EOF
        log "INFO" "Found debug symbols file: $dbg_file"
    else
        cat >> "$gdb_script" << EOF
echo No debug symbols file found\n
EOF
        log "WARNING" "No debug symbols file found for $IMAGE_PATH"
    fi

    cat >> "$gdb_script" << EOF
# Break at _start or main, if available
tbreak _start
tbreak main

# Some useful commands to run during debugging:
echo \n
echo Useful GDB commands:\n
echo "  c or continue - Continue execution"\n
echo "  si - Step instruction"\n
echo "  s - Step source line"\n
echo "  bt - Print backtrace"\n
echo "  info registers - Show registers"\n
echo "  x/10i \$rip - Examine next 10 instructions"\n
echo "  set logging on - Enable logging"\n
echo \n

# Continue execution up to the first breakpoint
continue
EOF

    chmod +x "$gdb_script"
    log "SUCCESS" "GDB script created at $gdb_script"
    echo "To debug, run in another terminal: gdb -x $gdb_script"
}

run_bios_debug() {
    log "INFO" "Starting BIOS debug mode with QEMU..."
    
    # Base QEMU command
    local qemu_cmd=""
    if [[ "$ARCH" == "x86_64" ]]; then
        qemu_cmd="$QEMU_X86"
    else
        log "ERROR" "BIOS boot is only supported on x86_64 architecture"
        exit 1
    fi
    
    # Add basic options
    qemu_cmd+=" -m $MEMORY"
    qemu_cmd+=" -drive file=$IMAGE_PATH,format=raw,index=0,media=disk"
    
    # Add serial output redirection
    qemu_cmd+=" -serial file:$SERIAL_LOG"
    
    # Add monitor redirection (for QEMU commands)
    qemu_cmd+=" -monitor file:$MONITOR_LOG"
    
    # Add debugging options if needed
    if [[ $GDB_MODE -eq 1 ]]; then
        if [[ $WAIT_FOR_GDB -eq 1 ]]; then
            qemu_cmd+=" -s -S"
            log "INFO" "QEMU will wait for GDB connection on port 1234"
            create_gdb_script
        else
            qemu_cmd+=" -s"
            log "INFO" "GDB server will be available on port 1234"
            create_gdb_script
        fi
    fi
    
    # Add UI options
    if [[ $VERBOSE -eq 1 ]]; then
        # Show QEMU console
        qemu_cmd+=" -display gtk"
    else
        # Headless mode with serial redirected to console
        qemu_cmd+=" -nographic"
    fi
    
    # Log the command
    log "INFO" "Running QEMU with command:"
    log "INFO" "$qemu_cmd"
    
    # Run QEMU in the background to enable log tailing
    eval "$qemu_cmd" &
    QEMU_PID=$!
    
    # Set up log tailing
    log "INFO" "QEMU is running with PID: $QEMU_PID"
    log "INFO" "Tailing serial output log..."
    tail -f "$SERIAL_LOG" &
    TAIL_PID=$!
    
    # Wait for QEMU to exit
    wait $QEMU_PID
    kill $TAIL_PID 2>/dev/null || true
    
    log "INFO" "QEMU has exited. Check logs for details."
}

run_uefi_debug() {
    log "INFO" "Starting UEFI debug mode with QEMU..."
    
    # Find firmware
    local fw_path=""
    if [[ "$ARCH" == "x86_64" ]]; then
        for path in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
            if [[ -f "$path" ]]; then
                fw_path="$path"
                break
            fi
        done
    else
        for path in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI.fd; do
            if [[ -f "$path" ]]; then
                fw_path="$path"
                break
            fi
        done
    fi
    
    # Base QEMU command
    local qemu_cmd=""
    if [[ "$ARCH" == "x86_64" ]]; then
        qemu_cmd="$QEMU_X86"
    else
        qemu_cmd="$QEMU_ARM -machine virt -cpu cortex-a72"
    fi
    
    # Add basic options
    qemu_cmd+=" -m $MEMORY"
    qemu_cmd+=" -bios $fw_path"
    
    # Add drive/image options
    if [[ "$IMAGE_PATH" == *.img || "$IMAGE_PATH" == *.iso ]]; then
        # For disk images
        qemu_cmd+=" -drive file=$IMAGE_PATH,format=raw,media=disk"
    elif [[ "$IMAGE_PATH" == *.efi ]]; then
        # For EFI applications, create a FAT filesystem with EFI structure
        qemu_cmd+=" -drive file=fat:rw:$OUTPUT_DIR/debug_uefi,format=raw"
    else
        # For raw binaries, try both methods
        qemu_cmd+=" -drive file=fat:rw:$OUTPUT_DIR/debug_uefi,format=raw"
        cp "$IMAGE_PATH" "$OUTPUT_DIR/debug_uefi/bootable.bin"
        if [[ "$ARCH" == "x86_64" ]]; then
            cp "$IMAGE_PATH" "$OUTPUT_DIR/debug_uefi/EFI/BOOT/bootx64.efi"
        else
            cp "$IMAGE_PATH" "$OUTPUT_DIR/debug_uefi/EFI/BOOT/bootaa64.efi"
        fi
    fi
    
    # Add serial output redirection
    qemu_cmd+=" -serial file:$SERIAL_LOG"
    
    # Add monitor redirection (for QEMU commands)
    qemu_cmd+=" -monitor file:$MONITOR_LOG"
    
    # Add debugging options if needed
    if [[ $GDB_MODE -eq 1 ]]; then
        if [[ $WAIT_FOR_GDB -eq 1 ]]; then
            qemu_cmd+=" -s -S"
            log "INFO" "QEMU will wait for GDB connection on port 1234"
            create_gdb_script
        else
            qemu_cmd+=" -s"
            log "INFO" "GDB server will be available on port 1234"
            create_gdb_script
        fi
    fi
    
    # Add UI options
    if [[ $VERBOSE -eq 1 ]]; then
        # Show QEMU console
        qemu_cmd+=" -display gtk"
    else
        # Headless mode with serial redirected to console
        qemu_cmd+=" -nographic"
    fi
    
    # Log the command
    log "INFO" "Running QEMU with command:"
    log "INFO" "$qemu_cmd"
    
    # Run QEMU in the background to enable log tailing
    eval "$qemu_cmd" &
    QEMU_PID=$!
    
    # Set up log tailing
    log "INFO" "QEMU is running with PID: $QEMU_PID"
    log "INFO" "Tailing serial output log..."
    tail -f "$SERIAL_LOG" &
    TAIL_PID=$!
    
    # Wait for QEMU to exit
    wait $QEMU_PID
    kill $TAIL_PID 2>/dev/null || true
    
    log "INFO" "QEMU has exited. Check logs for details."
}

analyze_debug_logs() {
    log "INFO" "Analyzing debug logs..."
    
    # Check if serial log has content
    if [[ -s "$SERIAL_LOG" ]]; then
        log "INFO" "Serial log contains output, checking for common boot issues..."
        
        # Look for common error patterns
        if grep -q "Kernel panic" "$SERIAL_LOG"; then
            log "ERROR" "Kernel panic detected in boot output"
        fi
        
        if grep -q "EFI Boot Services not available" "$SERIAL_LOG"; then
            log "WARNING" "EFI Boot Services not available - this is normal for metal mode"
        fi
        
        if grep -q "Triple fault" "$SERIAL_LOG"; then
            log "ERROR" "Triple fault detected - CPU reset during boot"
        fi
        
        if grep -q "ACPI Error" "$SERIAL_LOG"; then
            log "WARNING" "ACPI errors detected - may be normal in metal mode"
        fi
        
        # Check for successful boot markers
        if grep -q "Llamafile initialized" "$SERIAL_LOG"; then
            log "SUCCESS" "Llamafile appears to have booted successfully"
        fi
        
        if grep -q "Error allocating memory" "$SERIAL_LOG"; then
            log "ERROR" "Memory allocation failed - check if enough RAM is available"
        fi
    else
        log "WARNING" "Serial log is empty - check if the image boots correctly"
    fi
    
    # Create a summary file
    local summary_file="$OUTPUT_DIR/debug_summary_${DEBUG_SESSION_ID}.txt"
    
    {
        echo "=== Bootable Llamafile Debug Summary ==="
        echo "Date: $(date)"
        echo "Image: $IMAGE_PATH"
        echo "Boot mode: $BOOT_MODE"
        echo "Architecture: $ARCH"
        echo "Memory: $MEMORY"
        echo ""
        echo "=== Last 20 lines of serial output ==="
        tail -n 20 "$SERIAL_LOG"
        echo ""
        echo "=== Recommendations ==="
        
        if ! grep -q "." "$SERIAL_LOG"; then
            echo "- No serial output detected. Check if the serial port is configured correctly."
            echo "- Verify that the image contains the correct boot code for $BOOT_MODE mode."
            echo "- Try with VGA console support if available."
        else
            echo "- Serial output detected. Check the full log for details."
            
            if grep -q "Triple fault\|General Protection Fault\|Page Fault" "$SERIAL_LOG"; then
                echo "- CPU exception detected. This may indicate an issue with the bootloader."
                echo "- Try debugging with GDB to identify the cause."
            fi
            
            if grep -q "Llamafile initialized" "$SERIAL_LOG"; then
                echo "- Llamafile appears to have booted successfully."
                echo "- If interactive features don't work, consider adding VGA console support."
            fi
        fi
        
    } > "$summary_file"
    
    log "SUCCESS" "Debug analysis complete. Summary saved to $summary_file"
}

main() {
    # Initialize log file
    echo "Bootable Llamafile Debug Log - $(date)" > "$DEBUG_FILE"
    echo "----------------------------------------" >> "$DEBUG_FILE"
    
    log "INFO" "Starting bootable llamafile debug process"
    
    parse_args "$@"
    check_dependencies
    prepare_environment
    
    if [[ "$BOOT_MODE" == "bios" ]]; then
        run_bios_debug
    else
        run_uefi_debug
    fi
    
    analyze_debug_logs
    
    log "SUCCESS" "Debug process completed"
    log "INFO" "Check the following files for debug information:"
    log "INFO" "- Serial output: $SERIAL_LOG"
    log "INFO" "- Monitor output: $MONITOR_LOG"
    log "INFO" "- Debug summary: $OUTPUT_DIR/debug_summary_${DEBUG_SESSION_ID}.txt"
}

# Execute main function with all arguments
main "$@" 