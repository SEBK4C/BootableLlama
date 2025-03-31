Great, I'll dive into how to boot a llamafile directly from USB using Cosmopolitan libc in metal mode. I'll look into:

- Specific build flags and configurations required for metal mode
- How to create bootable APE executables from the llamafile GitHub repo
- Support for both UEFI and BIOS boot targets
- x86_64 and ARM compatibility considerations
- Debugging techniques for bare-metal boot issues

I'll also include a step-by-step guide based on the findings and reference working examples where available. I'll let you know when everything is ready!

# Booting a Cosmopolitan "llamafile" on Bare Metal from USB

**Overview:** *Using Cosmopolitan Libc's "metal" mode, you can compile a **llamafile** (a self-contained LLM binary) into a bootable format that runs directly on hardware without an OS. This guide covers building the binary with Cosmopolitan, adding BIOS and UEFI boot support, preparing a USB stick, and addressing x86_64 vs ARM64 differences. It also provides debugging tips and examples of Cosmopolitan's bare-metal mode in action.* 

## 1. Building **llamafile** in Cosmopolitan Metal Mode

To get started, clone the **llamafile** repository and set up the latest Cosmopolitan toolchain (often via the `cosmocc` bundle). The Cosmopolitan toolchain can produce **Actually Portable Executables (APE)** that run on multiple OSes and CPU architectures (x86_64 and AArch64) ([cosmopolitan/tool/cosmocc/README.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/tool/cosmocc/README.md#:~:text=Windows%20%2F%20FreeBSD%20%2F%20OpenBSD,reach%20a%20broader%20audience%20from)). We will leverage this to build a **llamafile** as a single fat binary containing everything (code + model weights) with no external dependencies.

## Quick Start: Using the Build Scripts

For convenience, this repository provides two helpful scripts:

1. `build_bootable.sh` - Creates bootable llamafile builds with BIOS and UEFI support
2. `debug_boot.sh` - Debugs and tests bootable images using QEMU

### Building a Bootable Llamafile

The `build_bootable.sh` script automates the process of building a bootable llamafile with the necessary BIOS and UEFI support. Here's how to use it:

```bash
# Make the script executable
chmod +x build_bootable.sh

# Basic usage - build with both BIOS and UEFI support
./build_bootable.sh --model path/to/your/model.gguf

# Build with VGA console support (for text output directly to screen)
./build_bootable.sh --model path/to/your/model.gguf --vga

# Build for a specific architecture
./build_bootable.sh --model path/to/your/model.gguf --arch x86_64

# Test the build with QEMU after building
./build_bootable.sh --model path/to/your/model.gguf --test

# See all available options
./build_bootable.sh --help
```

The script will:
1. Clone the llamafile repository (or update if it exists)
2. Apply patches to support booting directly from hardware
3. Build the llamafile with appropriate flags
4. Create boot images for BIOS and/or UEFI
5. Optionally test the bootable images with QEMU

### Debugging a Bootable Llamafile

The `debug_boot.sh` script provides detailed debugging capabilities for troubleshooting boot issues:

```bash
# Make the script executable
chmod +x debug_boot.sh

# Basic BIOS debug
./debug_boot.sh --image output/bios_bootable.img

# Debug UEFI boot
./debug_boot.sh --image output/efi_boot/EFI/BOOT/bootx64.efi --mode uefi

# Debug with GDB attached
./debug_boot.sh --image output/bootable_llamafile_with_model.com --gdb

# See all available options
./debug_boot.sh --help
```

The script will:
1. Run the image in QEMU with appropriate settings
2. Capture serial output to log files
3. Analyze logs for common boot issues
4. Generate a debug summary with recommendations
5. Optionally support GDB debugging

## 2. Ensuring BIOS and UEFI Boot Support

To boot directly from a USB on real hardware, the binary must contain bootloader code for either **BIOS (legacy)** or **UEFI** (modern firmware). Cosmopolitan's APE format cleverly embeds such boot code in the binary:

- **BIOS:** Cosmopolitan **by default includes a 16-bit x86 boot sector** in the APE header. The magic bytes at the file's start (`MZqFpD='`) double as valid machine code for all x86 modes ([cosmopolitan/ape/specification.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/ape/specification.md#:~:text=The%20letters%20were%20carefully%20chosen,as%20a%20floppy%20disk%20image)). In fact, simple programs built with Cosmopolitan will **boot via BIOS** into 64-bit mode if you treat the binary as a disk image ([cosmopolitan/ape/specification.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/ape/specification.md#:~:text=The%20letters%20were%20carefully%20chosen,as%20a%20floppy%20disk%20image)). The APE's DOS stub essentially serves as an MBR boot sector (with the 0x55AA signature) that sets up the CPU and jumps into the 64-bit C code.

- **UEFI:** UEFI uses PE64 executables as boot applications. Cosmopolitan can also make the binary act as a UEFI PE by providing an `EfiMain` entry point. However, Windows and UEFI both use the PE format, so by default Cosmopolitan's PE header is set for Windows. **To enable UEFI**, we must either rebuild Cosmopolitan with an appropriate **support vector** or explicitly link in the UEFI startup code:
  - *Option 1:* **Recompile with UEFI support** – Cosmopolitan's author notes that building with `CPPFLAGS=-DSUPPORT_VECTOR=251` will "remove all the Windows code and turn EFI on" ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,x86_64)) (251 enables BIOS+UEFI; changing to 249 would drop BIOS too ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=%2A%20make%20,x86_64))). If you are building Cosmopolitan from source for this project, use this flag in the build of Cosmopolitan and your program.
  - *Option 2:* **Link in EfiMain symbol** – If using the prebuilt cosmopolitan libc, you can force inclusion of the UEFI entry by adding in your code: `__static_yoink("EfiMain");` before `main()` (or use the macro `STATIC_YOINK("EfiMain")`). This hints the APE linker to include the `EfiMain` function in the binary ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,%40see%20libc%2Fdce.h)). The llamafile codebase may not include this by default; you might add it in `metal.c` or as a patch when building for metal mode.

By enabling `EfiMain`, the output binary's PE header will be recognized as an EFI application. The Cosmopolitan runtime will then handle UEFI boot services, initialize memory, and call your `main` just like on BIOS (but via UEFI). 

**Include VGA output support (optional):** Note that Cosmopolitan's bare-metal default I/O is **serial**. If you want text output on a PC monitor in BIOS mode, include the VGA console driver. For example, Cosmo's `vga2.c` example forces in `vga_console` and other low-level pieces with `__static_yoink("vga_console")` ([cosmopolitan/examples/vga2.c at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/examples/vga2.c#:~:text=__static_yoink%28)). In headless scenarios, serial output (accessible via QEMU or a COM port) is often used. Llamafile is primarily a network/CLI app (it starts a local web UI), so interactive text on VGA may not be crucial, but serial logs could help in debugging.

**Summary of Bootloader requirements:**

| **Boot Environment** | **Cosmopolitan Support**             | **What to Ensure**                                   |
|----------------------|--------------------------------------|------------------------------------------------------|
| Legacy BIOS (x86_64) | Built-in MBR boot sector in APE ([cosmopolitan/ape/specification.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/ape/specification.md#:~:text=The%20letters%20were%20carefully%20chosen,as%20a%20floppy%20disk%20image)). | Nothing extra if default build. The APE's MZ stub acts as bootloader. Make sure to write binary to the disk's MBR. |
| UEFI (x86_64 & ARM64)| Requires `EfiMain` in binary ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,%40see%20libc%2Fdce.h)) and PE header flagged for EFI. | Include UEFI support (via `STATIC_YOINK("EfiMain")` or `-DSUPPORT_VECTOR=251` at build) so firmware can execute it as `BOOTX64.EFI`/`BOOTAA64.EFI`. |
| **Note:** ARM64 systems typically boot via UEFI (no legacy BIOS). | (Cosmopolitan doesn't support an ARM "BIOS"; use UEFI.) | For ARM64 targets, ensure UEFI path is enabled. Boot firmware must support running the APE as an EFI application. |

In summary, **for x86_64** the llamafile binary you built likely already boots on BIOS out-of-the-box ([How to boot bare metal on actual hardware? · jart cosmopolitan · Discussion #805 · GitHub](https://github.com/jart/cosmopolitan/discussions/805#:~:text=,examples%2Fvga2.c)), but to also boot on pure UEFI systems (or any ARM64 hardware), you should rebuild or modify it to include UEFI support. Next, we'll prepare a USB with the binary for each case.

## 3. Preparing a Bootable USB Stick

Now that we have a **llamafile.com** binary with the appropriate boot code, we can write it to a USB drive and test booting. There are two approaches depending on target firmware:

**A. BIOS Boot (Legacy):** You can treat the `.com` binary as a raw disk image containing a boot sector. Simply write it directly to the USB device's beginning. For example, if the USB is `/dev/sdX`:

```bash
sudo dd if=llamafile.com of=/dev/sdX bs=4M conv=notrunc
```

This will copy the entire binary onto the device starting at LBA0. The BIOS will read the first 512 bytes (the embedded MBR code) and jump into it, which then continues to execute the rest of the binary (already on the disk) as the program in long mode. Remy van Elst confirmed that a Cosmopolitan APE (his `vi.com`) booted on real hardware when written with `dd` to a USB drive ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Update%3A%20I%27ve%20loaned%20an%20x86,dd)). 

**Important:** Be **careful with the dd target** – use the raw device (like `/dev/sdX`, not a partition like `/dev/sdX1`). This method overwrites the device's MBR. Also, *some BIOSes require the drive to have a valid partition table to appear in the boot menu.* If your BIOS does not list the USB, you may need to create a partition table:
  - One workaround is to create one partition spanning the drive and mark it bootable, then dd the binary *into that partition's start* (so that the partition's boot sector gets the Cosmo MBR). This is advanced and usually not necessary, but keep it in mind if a direct dd isn't recognized by your firmware.

**B. UEFI Boot:** For UEFI, you should not dd the image raw (UEFI won't treat a raw blob as bootable). Instead, do the following:
  1. **Format the USB with GPT (or MBR) and a FAT32 partition** – Create a small FAT32 partition (an "EFI System Partition"). For example, using `gdisk` or `fdisk`, make a partition and set the type to EFI (if GPT) or set the partition as primary/active (if MBR).
  2. **Copy the APE binary as an EFI application:** Mount the FAT partition and create an `/EFI/BOOT` directory. Copy `llamafile.com` into that directory, renaming it to the standard boot filename:
     - For x86_64: `bootx64.efi`
     - For ARM64: `bootaa64.efi` (if you intend to boot on an ARM machine).
     
     Example:
     ```bash
     sudo mount /dev/sdX1 /mnt/usb
     sudo mkdir -p /mnt/usb/EFI/BOOT
     sudo cp llamafile.com /mnt/usb/EFI/BOOT/bootx64.efi
     sudo umount /mnt/usb
     ```
  3. Now the USB is a proper UEFI boot disk. On UEFI PCs, you might need to disable Secure Boot (Cosmopolitan binaries are not signed) or enable "UEFI boot from USB". The firmware should detect the FAT partition and launch `bootx64.efi`. If it doesn't auto-boot, you can enter the UEFI menu or shell and manually select the file.

## 4. BIOS vs UEFI: Bootloader Differences and Considerations

Booting via BIOS or UEFI will ultimately run the same llamafile code, but there are a few differences in environment:

- **CPU State:** The Cosmopolitan bootloader (in BIOS mode) will switch the CPU from real mode to 64-bit long mode before entering the C `main()` function. In UEFI mode, the firmware already provides a 64-bit execution environment. Either way, by the time your program's `main` runs, it's in 64-bit mode with paging enabled. The Cosmopolitan runtime abstracts this, so you typically don't need to handle it.

- **Console I/O:** Under BIOS, **Cosmopolitan's default** is to use the serial port for standard I/O (since there's no OS). Unless you enabled VGA text output (via `vga_console`), you might not see anything on screen – instead, connect a serial terminal to view output ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=I%20currently%20only%20have%20a,but%20on%20the%20serial%20port)). On QEMU, `-serial stdio` shows this easily. Under UEFI, printing to `stdout` may use UEFI's console (which often gets redirected to the firmware output or still the serial, depending on system). If nothing is displayed on UEFI, you might again use a serial or UEFI debug output. For interactive input (keyboard), BIOS provides INT 16h (Cosmopolitan might handle basic input via BIOS), and UEFI has its console input protocol. Be aware that **GPU/Display** use in UEFI is not trivial – many UEFI systems do not support VGA text mode ([VGA on UEFI : r/osdev](https://www.reddit.com/r/osdev/comments/yjm04z/vga_on_uefi/#:~:text=I%20did%20some%20experiments%20about,BIOS%20it%20should%20just%20work)) ([VGA on UEFI : r/osdev](https://www.reddit.com/r/osdev/comments/yjm04z/vga_on_uefi/#:~:text=UEFI%20doesn%27t%20require%20VGA%20compatibility,adapter%20in%20the%20first%20place)). Therefore, relying on serial for text interface is recommended for both.

- **ARM64 specific:** On an ARM64 machine, the only way your binary runs is if the firmware can execute the PE binary (with `EfiMain`). This means practically an UEFI environment (most ARM developer boards or servers use UEFI, as do Apple Silicon Macs via their own boot mechanism). There is no legacy BIOS on ARM, so the USB must be UEFI. Additionally, on ARM there is no VGA text; you will need serial or framebuffer output. Cosmopolitan may not have a specialized ARM console driver, so be prepared to rely on serial exclusively when booting on ARM hardware. 

In short, **for x86_64 PCs** you have the flexibility of BIOS or UEFI. For **ARM64 devices**, use UEFI. Once booted, the llamafile should run the same inference server code as if launched under an OS – it will initialize the model and likely start listening on a port. (Note: Without an OS, networking isn't available unless you've integrated a driver. So a web UI might not function on true bare metal unless you add a network driver. In practice, "bare metal llamafile" might be more of a tech demo running in offline mode or with pre-loaded prompts, since serving a web interface needs TCP/IP. One could attach a serial console UI or use it purely for local computation.)

## 5. Debugging Bare-Metal Cosmopolitan Binaries

Getting a cosmopolitan binary to boot can involve some trial and error. Here are some tips and common issues:

- **Use QEMU and Serial Output:** As mentioned, use QEMU in both BIOS and UEFI modes to test quickly. The `-nographic` and `-serial stdio` options are your best friend – they redirect the emulated serial port to your console. Cosmopolitan's **–strace** and **–ftrace** flags (if enabled) likely won't work without an OS, but basic `printf` logging will. If nothing appears, try adding a very early `puts("Reached here")` in your `main` to see if it gets that far.

- **Triple Fault or Hang on Boot:** If the machine reboots or freezes immediately, it suggests the bootloader code didn't properly transition to your code. This could happen if the binary wasn't written correctly to the USB (e.g., missing the boot signature or truncated). Ensure `dd` used `conv=notrunc` (do **not** truncate the output if your binary is larger than the device – obviously, the device must be at least as large as the file). Also verify the binary's first 2 bytes are `0x4D 0x5A` ("MZ") and bytes 511–512 are `0x55 0xAA`. If not, the file may not be seen as bootable by BIOS.

- **BIOS not detecting USB:** As noted, some BIOS firmware won't boot a "superfloppy" USB. If you dd'ed the image and it's not listed, consider creating a partition table. For example, create one partition starting at sector 2048 (1MB in) and dd the file to that offset (`of=/dev/sdX seek=2048`). Then install a generic MBR that jumps to the partition (Syslinux or GRUB's MBR could do). This is complex; alternatively try another PC or use UEFI mode which is more standardized for USB.

- **UEFI application not launching:** If you see the UEFI shell error like "not recognized as an internal or external command", the binary might not have the EFI subsystem set. Double-check that `EfiMain` was linked in. You can use the Linux `objdump` or `pesign` tools to inspect the PE header of `bootx64.efi`. It should indicate `Subsystem: EFI Application`. If it says `Windows GUI` or `Console`, then it's still a Windows PE, not an EFI. In that case, revisit the build flags (you may need the `SUPPORT_VECTOR=251` method to flip it). Another clue: if your binary exceeds ~4GB and you didn't remove Windows support, it wouldn't run on Windows anyway (Windows has a 4GB max on PE files) ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=match%20at%20L494%20Unfortunately%2C%20Windows,llamafile%20allows%20you%20to%20use)), so you lose nothing by switching to EFI support.

- **No network / limited functionality:** Remember that without an OS, many syscalls are no-ops or stubs. Cosmopolitan's metal mode is quite minimal. If your llamafile tries to open a browser (as it does on normal OS to show the chat UI), it obviously can't do that on bare metal. You may need to run it in a mode where it just prints to console or accepts input from serial. Check if llamafile has a flag for CLI-only operation (perhaps it does). Otherwise, you're essentially running the model inference loop without interactive UI on real hardware.

- **Logging and breaks:** If you have a problem where the binary starts but behaves unexpectedly, you can debug by attaching GDB to QEMU (for BIOS, use `-s -S` to have QEMU wait and listen for gdb). Because Cosmopolitan outputs a `.dbg` ELF, you can load symbols from `llamafile.com.dbg` into GDB for source-level debugging ([cosmopolitan/tool/cosmocc/README.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/tool/cosmocc/README.md#:~:text=%60hello.dbg%60%20%28x86,file%60%20command)). This is advanced, but possible.

- **Common Cosmopolitan quirks:** If the binary runs on QEMU but not on real hardware, the issue could be hardware differences. For example, some very new PCs have no Legacy BIOS support at all (hence require UEFI). Or certain UEFI implementations might not initialize a VGA console at all (so you see nothing if you expected text output). In such cases, verify that something is happening (disk LED activity, etc.) or rely on serial. Another quirk: some laptops might not enable the serial port by default; if so, you truly might have no output device. Using a PC with serial or a USB-to-serial adapter could be the only way to see output in a pure metal environment.

## 6. Testing and Verification

To ensure your bootable llamafile works properly, follow these testing steps:

1. **QEMU Testing:** Before trying on real hardware, thoroughly test with QEMU using the provided scripts.

   ```bash
   # Test BIOS boot
   ./debug_boot.sh --image output/bios_bootable.img
   
   # Test UEFI boot
   ./debug_boot.sh --image output/efi_boot/EFI/BOOT/bootx64.efi --mode uefi
   ```

2. **Check logs:** Examine the generated logs for any boot failures or warnings:

   ```bash
   # View the serial output log
   cat output/serial_*.log
   
   # View the debug summary
   cat output/debug_summary_*.txt
   ```

3. **GDB Debugging:** If issues persist, use GDB to debug:

   ```bash
   # Start QEMU in debug wait mode
   ./debug_boot.sh --image output/bios_bootable.img --gdb --wait
   
   # In another terminal, connect with GDB
   gdb -x output/debug_gdb_commands.gdb
   ```

4. **Real Hardware:** Once testing with QEMU succeeds, try on real hardware following the USB preparation steps described earlier.

## 7. Common Issues and Solutions

| Issue | Possible Cause | Solution |
|-------|----------------|----------|
| No boot/not recognized | MBR signature missing or invalid | Verify binary has correct boot signatures |
| Triple fault on BIOS boot | Bootloader cannot transition to long mode | Ensure CPU compatibility, check memory mappings |
| UEFI shell errors | Binary not recognized as EFI application | Verify EFI subsystem is set in PE header |
| No visible output | Default serial output with no serial connection | Enable VGA console with `--vga` option |
| Memory allocation failures | Not enough RAM for the model | Reduce model size or increase available RAM |
| Hangs during initialization | Model too large or hardware limitations | Use debugging to identify hang location |

## 8. Resources and References

- [Cosmopolitan Libc](https://github.com/jart/cosmopolitan) - The foundation for cross-platform APE files
- [llamafile](https://github.com/Mozilla-Ocho/llamafile) - The portable LLM platform we're building on
- [Bare Metal Vi](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html) - Example of a similar Cosmopolitan bare-metal project

## 9. License and Contributions

This project is provided as-is under the MIT License. Contributions are welcome - please feel free to submit issues or pull requests to improve the scripts or documentation.

---

With these tools and instructions, you should be able to create a bootable llamafile that runs directly on hardware without an operating system. Remember that running in metal mode has limitations, but it demonstrates the impressive capabilities of Cosmopolitan libc and the portability of llamafile.
