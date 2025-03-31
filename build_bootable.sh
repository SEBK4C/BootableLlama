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
BUILD_DIR="build"
OUTPUT_DIR="output"
LLAMAFILE_REPO="https://github.com/Mozilla-Ocho/llamafile.git"
MODEL_PATH=""
BOOT_MODE="both" # both, bios, uefi
ARCH="both" # x86_64, aarch64, both
VERBOSE=0
TEST_AFTER_BUILD=0
MEMORY="2G"
VGA_CONSOLE=0
LLAMAFILE_ARGS=""
LOG_FILE="bootable_llama.log"

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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOG_FILE"
}

show_help() {
    echo -e "${BOLD}Bootable Llamafile Configuration Script${NORMAL}"
    echo ""
    echo "This script configures and builds a bootable Llamafile using Cosmopolitan Libc's metal mode."
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  -r, --repo URL             Llamafile repository URL (default: $LLAMAFILE_REPO)"
    echo "  -m, --model PATH           Path to model file (required)"
    echo "  -b, --build-dir DIR        Build directory (default: $BUILD_DIR)"
    echo "  -o, --output-dir DIR       Output directory (default: $OUTPUT_DIR)"
    echo "  -t, --boot-mode MODE       Boot mode: bios, uefi, both (default: $BOOT_MODE)"
    echo "  -a, --arch ARCH            Architecture: x86_64, aarch64, both (default: $ARCH)"
    echo "  -v, --verbose              Enable verbose output"
    echo "  -T, --test                 Run QEMU tests after building"
    echo "  -M, --memory SIZE          Memory for QEMU tests (default: $MEMORY)"
    echo "  --vga                      Include VGA console support"
    echo "  --args \"ARGS\"              Additional arguments to pass to llamafile"
    echo ""
    echo "Examples:"
    echo "  $0 --model llama2-7b-q4.gguf --test"
    echo "  $0 --model mistral-7b.gguf --boot-mode uefi --arch both --vga"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -r|--repo)
                LLAMAFILE_REPO="$2"
                shift 2
                ;;
            -m|--model)
                MODEL_PATH="$2"
                shift 2
                ;;
            -b|--build-dir)
                BUILD_DIR="$2"
                shift 2
                ;;
            -o|--output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -t|--boot-mode)
                BOOT_MODE="$2"
                if [[ "$BOOT_MODE" != "bios" && "$BOOT_MODE" != "uefi" && "$BOOT_MODE" != "both" ]]; then
                    log "ERROR" "Invalid boot mode: $BOOT_MODE. Valid options: bios, uefi, both"
                    exit 1
                fi
                shift 2
                ;;
            -a|--arch)
                ARCH="$2"
                if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" && "$ARCH" != "both" ]]; then
                    log "ERROR" "Invalid architecture: $ARCH. Valid options: x86_64, aarch64, both"
                    exit 1
                fi
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -T|--test)
                TEST_AFTER_BUILD=1
                shift
                ;;
            -M|--memory)
                MEMORY="$2"
                shift 2
                ;;
            --vga)
                VGA_CONSOLE=1
                shift
                ;;
            --args)
                LLAMAFILE_ARGS="$2"
                shift 2
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$MODEL_PATH" ]]; then
        log "ERROR" "Model path is required. Use -m or --model to specify."
        show_help
        exit 1
    fi

    if [[ ! -f "$MODEL_PATH" && ! "$MODEL_PATH" =~ ^https?:// ]]; then
        log "ERROR" "Model file not found: $MODEL_PATH"
        exit 1
    fi
}

check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    local missing_deps=()
    
    for cmd in git make gcc wget unzip; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    # Check QEMU if testing is enabled
    if [[ $TEST_AFTER_BUILD -eq 1 ]]; then
        if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "bios" ]]; then
            if ! command -v qemu-system-x86_64 &> /dev/null; then
                missing_deps+=(qemu-system-x86_64)
            fi
        fi
        
        if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "uefi" ]]; then
            if [[ "$ARCH" == "both" || "$ARCH" == "aarch64" ]]; then
                if ! command -v qemu-system-aarch64 &> /dev/null; then
                    missing_deps+=(qemu-system-aarch64)
                fi
            fi
            
            # Check for UEFI firmware
            if [[ ! -f /usr/share/OVMF/OVMF_CODE.fd && ! -f /usr/share/edk2/ovmf/OVMF_CODE.fd ]]; then
                log "WARNING" "UEFI firmware not found in standard locations"
                log "WARNING" "You may need to install OVMF or specify a path for UEFI testing"
            fi
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
    log "INFO" "Preparing environment..."
    
    # Create directories
    mkdir -p "$BUILD_DIR"
    mkdir -p "$OUTPUT_DIR"
    
    # Clone or update llamafile repository
    if [[ -d "$BUILD_DIR/llamafile" ]]; then
        log "INFO" "Updating existing llamafile repository..."
        (cd "$BUILD_DIR/llamafile" && git pull)
    else
        log "INFO" "Cloning llamafile repository..."
        git clone "$LLAMAFILE_REPO" "$BUILD_DIR/llamafile"
    fi
    
    log "SUCCESS" "Environment prepared"
}

create_metal_patch() {
    local patch_file="$BUILD_DIR/metal_mode.patch"
    
    log "INFO" "Creating metal mode patch..."
    
    # Create a patch to add UEFI support and optionally VGA console
    cat > "$patch_file" << EOF
--- a/metal.c
+++ b/metal.c
@@ -0,0 +1,53 @@
+/*
+ * Bootable Llamafile - Metal mode entry point
+ * This file adds support for booting on real hardware via BIOS/UEFI
+ */
+
+#include "cosmopolitan.h"
+
+// Include UEFI support
+STATIC_YOINK("EfiMain");
+
+EOF
+
+    # Add VGA console support if requested
+    if [[ $VGA_CONSOLE -eq 1 ]]; then
+        cat >> "$patch_file" << EOF
+// Include VGA console support for text output
+STATIC_YOINK("vga_console");
+
+// Force VGA console initialization on boot
+static void init_vga_console(void) {
+  vga_console_init();
+}
+
+__attribute__((__section__(".init.start"))) void (*const init_vga)(void) = init_vga_console;
+
+EOF
+    fi
+
+    # Add a main wrapper to handle CLI args for llamafile
+    cat >> "$patch_file" << EOF
+// Metal mode main wrapper
+int main(int argc, char *argv[]) {
+  // Redirect stdout/stderr to serial if not using VGA
+  #if !defined(FORCE_VGA_CONSOLE)
+  // Setup serial at COM1 (0x3F8)
+  pushpop(uint16_t, ax);
+  pushpop(uint16_t, dx);
+  DEBUGF("Initializing serial port...");
+  outb(0x3F8 + 1, 0x00);    // Disable all interrupts
+  outb(0x3F8 + 3, 0x80);    // Enable DLAB
+  outb(0x3F8 + 0, 0x03);    // Set divisor to 3 (38400 baud)
+  outb(0x3F8 + 1, 0x00);    //
+  outb(0x3F8 + 3, 0x03);    // 8 bits, no parity, one stop bit
+  outb(0x3F8 + 2, 0xC7);    // Enable FIFO, clear, 14-byte threshold
+  outb(0x3F8 + 4, 0x0B);    // IRQs enabled, RTS/DSR set
+  #endif
+
+  // Pass control to llamafile main with any specified args
+  char *llamafile_args[] = {"llamafile", $LLAMAFILE_ARGS, NULL};
+  return llamafile_main(sizeof(llamafile_args)/sizeof(char*) - 1, llamafile_args);
+}
EOF
    
    # Replace $LLAMAFILE_ARGS with actual arguments if provided
    if [[ -n "$LLAMAFILE_ARGS" ]]; then
        args_string=""
        for arg in $LLAMAFILE_ARGS; do
            args_string+="\"$arg\", "
        done
        # Remove trailing comma and space
        args_string="${args_string%, }"
        sed -i "s/\$LLAMAFILE_ARGS/$args_string/" "$patch_file"
    else
        sed -i "s/\$LLAMAFILE_ARGS/\"--interactive\", \"--log-disable\"/" "$patch_file"
    fi
    
    log "SUCCESS" "Metal mode patch created at $patch_file"
}

apply_metal_patch() {
    log "INFO" "Applying metal mode patch..."
    
    # Create metal.c in the llamafile source
    cp "$BUILD_DIR/metal_mode.patch" "$BUILD_DIR/llamafile/metal.c"
    
    # Modify Makefile to include metal.c and set appropriate flags
    # This is simplified - you might need to adjust based on the actual Makefile structure
    if grep -q "metal.o" "$BUILD_DIR/llamafile/Makefile"; then
        log "INFO" "Metal mode already configured in Makefile"
    else
        log "INFO" "Adding metal mode to Makefile..."
        sed -i '/^OBJECTS = /s/$/ metal.o/' "$BUILD_DIR/llamafile/Makefile"
        
        # Add metal mode flags
        # Note: This is a simplified approach and might need adjustment based on the actual Makefile
        if ! grep -q "MODE=metal" "$BUILD_DIR/llamafile/Makefile"; then
            cat >> "$BUILD_DIR/llamafile/Makefile" << EOF

# Metal mode configuration
ifeq ($(MODE),metal)
CFLAGS += -static -nostdlib -fno-pie -no-pie -mno-red-zone
LDFLAGS += -static -nostdlib -fno-pie -no-pie -Wl,-T,ape.lds -Wl,--gc-sections
endif
EOF
        fi
    fi
    
    log "SUCCESS" "Metal mode patch applied"
}

build_llamafile() {
    log "INFO" "Building bootable llamafile..."
    
    # Download model if it's a URL
    if [[ "$MODEL_PATH" =~ ^https?:// ]]; then
        local model_filename=$(basename "$MODEL_PATH")
        log "INFO" "Downloading model from $MODEL_PATH..."
        wget -O "$BUILD_DIR/$model_filename" "$MODEL_PATH"
        MODEL_PATH="$BUILD_DIR/$model_filename"
        log "SUCCESS" "Model downloaded to $MODEL_PATH"
    fi
    
    # Build command with appropriate flags
    cd "$BUILD_DIR/llamafile"
    
    # Set architecture flags
    local arch_flag=""
    if [[ "$ARCH" == "x86_64" ]]; then
        arch_flag="--target=x86_64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        arch_flag="--target=aarch64"
    fi
    
    # Set VGA console flag if needed
    local vga_flag=""
    if [[ $VGA_CONSOLE -eq 1 ]]; then
        vga_flag="-DFORCE_VGA_CONSOLE=1"
    fi
    
    # Build command
    local build_cmd="MODE=metal make -j$(nproc) $arch_flag $vga_flag"
    
    log "INFO" "Running build command: $build_cmd"
    if [[ $VERBOSE -eq 1 ]]; then
        eval "$build_cmd"
    else
        eval "$build_cmd" > /dev/null
    fi
    
    # Create the bootable llamafile
    log "INFO" "Building final llamafile with model..."
    local llamafile_binary=$(find . -name "llamafile.com" | head -1)
    
    if [[ -z "$llamafile_binary" ]]; then
        log "ERROR" "Failed to find llamafile.com binary"
        exit 1
    fi
    
    # Create the final llamafile with the model embedded
    # Assuming llamafile has a mechanism to embed the model (simplification)
    cp "$llamafile_binary" "$OUTPUT_DIR/bootable_llamafile.com"
    
    # For demonstration, let's create a simple script to simulate embedding the model
    cat > "$OUTPUT_DIR/embed_model.sh" << EOF
#!/bin/bash
# This script simulates embedding the model into the llamafile binary
cat "$OUTPUT_DIR/bootable_llamafile.com" "$MODEL_PATH" > "$OUTPUT_DIR/bootable_llamafile_with_model.com"
EOF
    chmod +x "$OUTPUT_DIR/embed_model.sh"
    
    log "INFO" "Running model embedding script..."
    "$OUTPUT_DIR/embed_model.sh"
    
    log "SUCCESS" "Bootable llamafile built at $OUTPUT_DIR/bootable_llamafile_with_model.com"
    
    # Return to the original directory
    cd - > /dev/null
}

create_boot_media() {
    log "INFO" "Creating boot media files..."
    
    local binary="$OUTPUT_DIR/bootable_llamafile_with_model.com"
    
    # Create raw disk image for BIOS boot
    if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "bios" ]]; then
        log "INFO" "Creating raw disk image for BIOS boot..."
        
        # Create a raw disk image - this is a direct copy of the binary for BIOS boot
        cp "$binary" "$OUTPUT_DIR/bios_bootable.img"
        
        log "SUCCESS" "BIOS boot image created at $OUTPUT_DIR/bios_bootable.img"
        log "INFO" "To write to USB: sudo dd if=$OUTPUT_DIR/bios_bootable.img of=/dev/sdX bs=4M conv=notrunc"
    fi
    
    # Create EFI files for UEFI boot
    if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "uefi" ]]; then
        log "INFO" "Creating EFI files for UEFI boot..."
        
        # Create EFI directory structure
        mkdir -p "$OUTPUT_DIR/efi_boot/EFI/BOOT"
        
        # Copy binary as EFI application
        if [[ "$ARCH" == "both" || "$ARCH" == "x86_64" ]]; then
            cp "$binary" "$OUTPUT_DIR/efi_boot/EFI/BOOT/bootx64.efi"
            log "SUCCESS" "x86_64 EFI file created at $OUTPUT_DIR/efi_boot/EFI/BOOT/bootx64.efi"
        fi
        
        if [[ "$ARCH" == "both" || "$ARCH" == "aarch64" ]]; then
            cp "$binary" "$OUTPUT_DIR/efi_boot/EFI/BOOT/bootaa64.efi"
            log "SUCCESS" "ARM64 EFI file created at $OUTPUT_DIR/efi_boot/EFI/BOOT/bootaa64.efi"
        fi
        
        # Create a script to create FAT32 image with EFI files
        cat > "$OUTPUT_DIR/create_efi_image.sh" << EOF
#!/bin/bash
# Create a FAT32 image with EFI files
dd if=/dev/zero of="$OUTPUT_DIR/uefi_bootable.img" bs=1M count=512
mkfs.vfat -F 32 "$OUTPUT_DIR/uefi_bootable.img"
mkdir -p /tmp/efi_mount
mount "$OUTPUT_DIR/uefi_bootable.img" /tmp/efi_mount
cp -r "$OUTPUT_DIR/efi_boot/EFI" /tmp/efi_mount/
umount /tmp/efi_mount
rmdir /tmp/efi_mount
EOF
        chmod +x "$OUTPUT_DIR/create_efi_image.sh"
        
        log "INFO" "EFI image creation script prepared at $OUTPUT_DIR/create_efi_image.sh"
        log "INFO" "To create EFI image, run: sudo $OUTPUT_DIR/create_efi_image.sh"
        log "INFO" "To write to USB: sudo dd if=$OUTPUT_DIR/uefi_bootable.img of=/dev/sdX bs=4M conv=notrunc"
    fi
    
    log "SUCCESS" "Boot media files created"
}

test_bios_boot() {
    log "INFO" "Testing BIOS boot with QEMU..."
    
    local binary="$OUTPUT_DIR/bootable_llamafile_with_model.com"
    local log_file="$OUTPUT_DIR/bios_boot_test.log"
    
    # QEMU command for BIOS boot testing
    local qemu_cmd="qemu-system-x86_64 -m $MEMORY -nographic"
    qemu_cmd+=" -serial stdio"
    qemu_cmd+=" -drive file=$binary,format=raw,index=0,media=disk"
    
    log "INFO" "Running QEMU with command: $qemu_cmd"
    log "INFO" "Log will be saved to $log_file"
    log "INFO" "Press Ctrl+A, X to exit QEMU"
    
    # Run QEMU and log output
    echo "Starting BIOS boot test at $(date)" > "$log_file"
    echo "Command: $qemu_cmd" >> "$log_file"
    echo "----------------------------------------" >> "$log_file"
    
    # Execute QEMU
    eval "$qemu_cmd" | tee -a "$log_file"
    
    log "SUCCESS" "BIOS boot test completed"
}

test_uefi_boot() {
    log "INFO" "Testing UEFI boot with QEMU..."
    
    # Prepare UEFI directory
    mkdir -p "$OUTPUT_DIR/uefi_test"
    mkdir -p "$OUTPUT_DIR/uefi_test/EFI/BOOT"
    
    # Find OVMF firmware
    local ovmf_code=""
    for path in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        if [[ -f "$path" ]]; then
            ovmf_code="$path"
            break
        fi
    done
    
    if [[ -z "$ovmf_code" ]]; then
        log "ERROR" "UEFI firmware not found. Please install OVMF package."
        return 1
    fi
    
    # Test x86_64 UEFI boot
    if [[ "$ARCH" == "both" || "$ARCH" == "x86_64" ]]; then
        local binary="$OUTPUT_DIR/bootable_llamafile_with_model.com"
        local log_file="$OUTPUT_DIR/uefi_x64_boot_test.log"
        
        # Copy binary as EFI application
        cp "$binary" "$OUTPUT_DIR/uefi_test/EFI/BOOT/bootx64.efi"
        
        # QEMU command for UEFI boot testing
        local qemu_cmd="qemu-system-x86_64 -m $MEMORY -nographic"
        qemu_cmd+=" -serial stdio"
        qemu_cmd+=" -bios $ovmf_code"
        qemu_cmd+=" -drive file=fat:rw:$OUTPUT_DIR/uefi_test,format=raw"
        
        log "INFO" "Running QEMU with command: $qemu_cmd"
        log "INFO" "Log will be saved to $log_file"
        log "INFO" "Press Ctrl+A, X to exit QEMU"
        
        # Run QEMU and log output
        echo "Starting UEFI x86_64 boot test at $(date)" > "$log_file"
        echo "Command: $qemu_cmd" >> "$log_file"
        echo "----------------------------------------" >> "$log_file"
        
        # Execute QEMU
        eval "$qemu_cmd" | tee -a "$log_file"
        
        log "SUCCESS" "UEFI x86_64 boot test completed"
    fi
    
    # Test ARM64 UEFI boot
    if [[ "$ARCH" == "both" || "$ARCH" == "aarch64" ]]; then
        local binary="$OUTPUT_DIR/bootable_llamafile_with_model.com"
        local log_file="$OUTPUT_DIR/uefi_arm64_boot_test.log"
        
        # Find AAVMF firmware for ARM64
        local aavmf_code=""
        for path in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI.fd; do
            if [[ -f "$path" ]]; then
                aavmf_code="$path"
                break
            fi
        done
        
        if [[ -z "$aavmf_code" ]]; then
            log "WARNING" "ARM64 UEFI firmware not found. Skipping ARM64 UEFI test."
            return 0
        fi
        
        # Copy binary as EFI application
        cp "$binary" "$OUTPUT_DIR/uefi_test/EFI/BOOT/bootaa64.efi"
        
        # QEMU command for ARM64 UEFI boot testing
        local qemu_cmd="qemu-system-aarch64 -m $MEMORY -nographic"
        qemu_cmd+=" -serial stdio"
        qemu_cmd+=" -machine virt -cpu cortex-a72"
        qemu_cmd+=" -bios $aavmf_code"
        qemu_cmd+=" -drive file=fat:rw:$OUTPUT_DIR/uefi_test,format=raw"
        
        log "INFO" "Running QEMU with command: $qemu_cmd"
        log "INFO" "Log will be saved to $log_file"
        log "INFO" "Press Ctrl+A, X to exit QEMU"
        
        # Run QEMU and log output
        echo "Starting UEFI ARM64 boot test at $(date)" > "$log_file"
        echo "Command: $qemu_cmd" >> "$log_file"
        echo "----------------------------------------" >> "$log_file"
        
        # Execute QEMU
        eval "$qemu_cmd" | tee -a "$log_file"
        
        log "SUCCESS" "UEFI ARM64 boot test completed"
    fi
}

run_tests() {
    if [[ $TEST_AFTER_BUILD -eq 1 ]]; then
        log "INFO" "Running boot tests..."
        
        if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "bios" ]]; then
            test_bios_boot
        fi
        
        if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "uefi" ]]; then
            test_uefi_boot
        fi
        
        log "SUCCESS" "All requested tests completed"
    else
        log "INFO" "Skipping tests (use --test to enable)"
    fi
}

print_summary() {
    log "INFO" "Build and test summary:"
    echo "----------------------------------------"
    echo "Bootable Llamafile Configuration Summary"
    echo "----------------------------------------"
    echo "Model: $MODEL_PATH"
    echo "Boot mode: $BOOT_MODE"
    echo "Architecture: $ARCH"
    echo "VGA console: $([ $VGA_CONSOLE -eq 1 ] && echo "Enabled" || echo "Disabled")"
    echo "Output files:"
    
    if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "bios" ]]; then
        echo "- BIOS boot image: $OUTPUT_DIR/bios_bootable.img"
    fi
    
    if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "uefi" ]]; then
        if [[ "$ARCH" == "both" || "$ARCH" == "x86_64" ]]; then
            echo "- UEFI x86_64 file: $OUTPUT_DIR/efi_boot/EFI/BOOT/bootx64.efi"
        fi
        if [[ "$ARCH" == "both" || "$ARCH" == "aarch64" ]]; then
            echo "- UEFI ARM64 file: $OUTPUT_DIR/efi_boot/EFI/BOOT/bootaa64.efi"
        fi
        echo "- UEFI image script: $OUTPUT_DIR/create_efi_image.sh"
    fi
    
    echo "----------------------------------------"
    echo "Installation instructions:"
    
    if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "bios" ]]; then
        echo "For BIOS boot:"
        echo "  sudo dd if=$OUTPUT_DIR/bios_bootable.img of=/dev/sdX bs=4M conv=notrunc"
        echo "  (Replace /dev/sdX with your actual USB device)"
    fi
    
    if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "uefi" ]]; then
        echo "For UEFI boot:"
        echo "  1. Create a FAT32 partition on your USB drive"
        echo "  2. Mount it and copy the EFI directory:"
        echo "     cp -r $OUTPUT_DIR/efi_boot/EFI /path/to/mounted/usb/"
        echo "  Alternatively, use the provided script to create a full UEFI image:"
        echo "  sudo $OUTPUT_DIR/create_efi_image.sh"
        echo "  sudo dd if=$OUTPUT_DIR/uefi_bootable.img of=/dev/sdX bs=4M conv=notrunc"
    fi
    
    echo "----------------------------------------"
    echo "For detailed logs, see: $LOG_FILE"
    if [[ $TEST_AFTER_BUILD -eq 1 ]]; then
        if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "bios" ]]; then
            echo "BIOS boot test log: $OUTPUT_DIR/bios_boot_test.log"
        fi
        if [[ "$BOOT_MODE" == "both" || "$BOOT_MODE" == "uefi" ]]; then
            if [[ "$ARCH" == "both" || "$ARCH" == "x86_64" ]]; then
                echo "UEFI x86_64 boot test log: $OUTPUT_DIR/uefi_x64_boot_test.log"
            fi
            if [[ "$ARCH" == "both" || "$ARCH" == "aarch64" ]]; then
                echo "UEFI ARM64 boot test log: $OUTPUT_DIR/uefi_arm64_boot_test.log"
            fi
        fi
    fi
    echo "----------------------------------------"
}

main() {
    # Initialize log file
    echo "Bootable Llamafile Build Log - $(date)" > "$LOG_FILE"
    echo "----------------------------------------" >> "$LOG_FILE"
    
    log "INFO" "Starting Bootable Llamafile build process"
    
    parse_args "$@"
    check_dependencies
    prepare_environment
    create_metal_patch
    apply_metal_patch
    build_llamafile
    create_boot_media
    run_tests
    print_summary
    
    log "SUCCESS" "Bootable Llamafile build process completed"
}

# Execute main function with all arguments
main "$@" 