Great, I’ll dive into how to boot a llamafile directly from USB using Cosmopolitan libc in metal mode. I’ll look into:

- Specific build flags and configurations required for metal mode
- How to create bootable APE executables from the llamafile GitHub repo
- Support for both UEFI and BIOS boot targets
- x86_64 and ARM compatibility considerations
- Debugging techniques for bare-metal boot issues

I’ll also include a step-by-step guide based on the findings and reference working examples where available. I’ll let you know when everything is ready!

# Booting a Cosmopolitan “llamafile” on Bare Metal from USB

**Overview:** *Using Cosmopolitan Libc’s “metal” mode, you can compile a **llamafile** (a self-contained LLM binary) into a bootable format that runs directly on hardware without an OS. This guide covers building the binary with Cosmopolitan, adding BIOS and UEFI boot support, preparing a USB stick, and addressing x86_64 vs ARM64 differences. It also provides debugging tips and examples of Cosmopolitan’s bare-metal mode in action.* 

## 1. Building **llamafile** in Cosmopolitan Metal Mode

To get started, clone the **llamafile** repository and set up the latest Cosmopolitan toolchain (often via the `cosmocc` bundle). The Cosmopolitan toolchain can produce **Actually Portable Executables (APE)** that run on multiple OSes and CPU architectures (x86_64 and AArch64) ([cosmopolitan/tool/cosmocc/README.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/tool/cosmocc/README.md#:~:text=Windows%20%2F%20FreeBSD%20%2F%20OpenBSD,reach%20a%20broader%20audience%20from)). We will leverage this to build a **llamafile** as a single fat binary containing everything (code + model weights) with no external dependencies.

**Steps to compile llamafile:**

1. **Prepare the environment:** On a Linux system, install build tools (`build-essential`, `git`, `wget`, `unzip`, etc.). Clone the llamafile repo and enter it:
   ```bash
   git clone https://github.com/Mozilla-Ocho/llamafile.git 
   cd llamafile
   ```
   Download Cosmopolitan’s compiler (cosmocc) or ensure the repo’s Makefile can fetch it. (llamafile’s build uses Cosmopolitan, which may download `cosmocc.zip` automatically ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=match%20at%20L729%20Developing%20on,Windows%20users%20need)).)

2. **Choose build mode:** Set the build flags for **metal mode**. Cosmopolitan normally builds multi-OS binaries by default (including Windows support). For **bare-metal booting**, we need to include BIOS/UEFI support. If the llamafile build system supports a `MODE=metal` or similar, use it (e.g. `make MODE=metal -j$(nproc)`). Otherwise, we can inject the proper flags manually:
   - **No OS libraries:** The build should use `-static -nostdlib -no-pie -fno-pie` and link against Cosmopolitan’s objects (`crt.o`, `ape-no-modify-self.o`) with the APE linker script. For example, a custom build command might resemble:  
     ```bash
     gcc -static -nostdlib -fno-pie -no-pie -mno-red-zone \
         -o llamafile.com.dbg \
         [...].o (your object files) \
         -Wl,-T,ape.lds -Wl,--gc-sections \
         -include cosmopolitan.h crt.o ape-no-modify-self.o cosmopolitan.a
     objcopy -S -O binary llamafile.com.dbg llamafile.com
     ``` 
     This is similar to how a bare-metal Vi was built ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Compile%20,runtime)), producing an APE binary `llamafile.com`. (Using the **Cosmopolitan `make`** or **cosmocc** tool simplifies this: e.g. running `make -j8` in the llamafile repo should generate an output like `o/.../llamafile.com` automatically.)

3. **Embed model weights:** Ensure that the model weights are packaged into the binary (the llamafile build system typically appends the model file into a ZIP section of the binary ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=needing%20to%20be%20copied%20or,then%20opens%20the%20shell%20script))). The output should be a single large `.llamafile` (or `.com`) file that contains both the llamafile runtime (based on llama.cpp) and the model. Verify the output file exists (likely under `o/opt/llamafile/llamafile.com` or similar) and note its size.

4. **Verify multi-arch support:** Cosmopolitan’s APE format can include both x86_64 and ARM64 code in one file. By default, `cosmocc` produces a fat binary for both architectures ([cosmopolitan/tool/cosmocc/README.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/tool/cosmocc/README.md#:~:text=Windows%20%2F%20FreeBSD%20%2F%20OpenBSD,reach%20a%20broader%20audience%20from)). (It also emits separate ELF files for each arch for debugging ([cosmopolitan/tool/cosmocc/README.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/tool/cosmocc/README.md#:~:text=%60hello.dbg%60%20%28x86,file%60%20command)).) This means your `llamafile.com` can run on both Intel/AMD64 and ARM64 machines without rebuilding. You can confirm this by running `file llamafile.com` – it should report a “PE32+” or “MZ” executable (Cosmopolitan uses a PE/COFF container) rather than a normal ELF.

**Build configuration summary:** In the table below, we summarize key build flags and options for Cosmopolitan metal mode:

| **Build Flag / Option**            | **Purpose**                                         |
| ---------------------------------- | --------------------------------------------------- |
| `-static -nostdlib -no-pie`        | Produce a static binary with no OS-specific startup (needed for bare metal) ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=gcc%20,self.o%20cosmopolitan.a)). |
| `-fuse-ld=bfd -T ape.lds`          | Use Cosmopolitan’s linker script (ape.lds) to lay out an APE file (with DOS/PE headers). |
| Link with `crt.o`, `ape-no-modify-self.o`, `cosmopolitan.a` | Link Cosmopolitan’s startup code and libc. These provide the runtime that makes the binary Actually Portable ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=gcc%20,self.o%20cosmopolitan.a)). |
| `STATIC_YOINK("EfiMain")` (or `-DSUPPORT_VECTOR=251`) | Include UEFI entry point (discussed below) ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,x86_64)) ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,%40see%20libc%2Fdce.h)). This enables UEFI boot support by removing conflicts with Windows code. |
| **MODE=metal** (Makefile option)   | (If available) A build mode in llamafile’s Makefile to enable bare-metal settings. This would set appropriate CFLAGS/LDFLAGS for you. |

After a successful build, you should have a **`llamafile.com`** (or `.llamafile`) binary. Test it in a normal OS environment first if you want (it should run on Linux/macOS with the appropriate loader or on Windows if renamed `.exe` ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=Unfortunately%2C%20Windows%20users%20cannot%20make,llamafile%20allows%20you%20to%20use))). Once confirmed, we can proceed to make it bootable on bare metal.

## 2. Ensuring BIOS and UEFI Boot Support

To boot directly from a USB on real hardware, the binary must contain bootloader code for either **BIOS (legacy)** or **UEFI** (modern firmware). Cosmopolitan’s APE format cleverly embeds such boot code in the binary:

- **BIOS:** Cosmopolitan **by default includes a 16-bit x86 boot sector** in the APE header. The magic bytes at the file’s start (`MZqFpD='`) double as valid machine code for all x86 modes ([cosmopolitan/ape/specification.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/ape/specification.md#:~:text=The%20letters%20were%20carefully%20chosen,as%20a%20floppy%20disk%20image)). In fact, simple programs built with Cosmopolitan will **boot via BIOS** into 64-bit mode if you treat the binary as a disk image ([cosmopolitan/ape/specification.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/ape/specification.md#:~:text=The%20letters%20were%20carefully%20chosen,as%20a%20floppy%20disk%20image)). The APE’s DOS stub essentially serves as an MBR boot sector (with the 0x55AA signature) that sets up the CPU and jumps into the 64-bit C code.

- **UEFI:** UEFI uses PE64 executables as boot applications. Cosmopolitan can also make the binary act as a UEFI PE by providing an `EfiMain` entry point. However, Windows and UEFI both use the PE format, so by default Cosmopolitan’s PE header is set for Windows. **To enable UEFI**, we must either rebuild Cosmopolitan with an appropriate **support vector** or explicitly link in the UEFI startup code:
  - *Option 1:* **Recompile with UEFI support** – Cosmopolitan’s author notes that building with `CPPFLAGS=-DSUPPORT_VECTOR=251` will “remove all the Windows code and turn EFI on” ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,x86_64)) (251 enables BIOS+UEFI; changing to 249 would drop BIOS too ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=%2A%20make%20,x86_64))). If you are building Cosmopolitan from source for this project, use this flag in the build of Cosmopolitan and your program.
  - *Option 2:* **Link in EfiMain symbol** – If using the prebuilt cosmopolitan libc, you can force inclusion of the UEFI entry by adding in your code: `__static_yoink("EfiMain");` before `main()` (or use the macro `STATIC_YOINK("EfiMain")`). This hints the APE linker to include the `EfiMain` function in the binary ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,%40see%20libc%2Fdce.h)). The llamafile codebase may not include this by default; you might add it in `metal.c` or as a patch when building for metal mode.

By enabling `EfiMain`, the output binary’s PE header will be recognized as an EFI application. The Cosmopolitan runtime will then handle UEFI boot services, initialize memory, and call your `main` just like on BIOS (but via UEFI). 

**Include VGA output support (optional):** Note that Cosmopolitan’s bare-metal default I/O is **serial**. If you want text output on a PC monitor in BIOS mode, include the VGA console driver. For example, Cosmo’s `vga2.c` example forces in `vga_console` and other low-level pieces with `__static_yoink("vga_console")` ([cosmopolitan/examples/vga2.c at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/examples/vga2.c#:~:text=__static_yoink%28)). In headless scenarios, serial output (accessible via QEMU or a COM port) is often used. Llamafile is primarily a network/CLI app (it starts a local web UI), so interactive text on VGA may not be crucial, but serial logs could help in debugging.

**Summary of Bootloader requirements:**

| **Boot Environment** | **Cosmopolitan Support**             | **What to Ensure**                                   |
|----------------------|--------------------------------------|------------------------------------------------------|
| Legacy BIOS (x86_64) | Built-in MBR boot sector in APE ([cosmopolitan/ape/specification.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/ape/specification.md#:~:text=The%20letters%20were%20carefully%20chosen,as%20a%20floppy%20disk%20image)). | Nothing extra if default build. The APE’s MZ stub acts as bootloader. Make sure to write binary to the disk’s MBR. |
| UEFI (x86_64 & ARM64)| Requires `EfiMain` in binary ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,%40see%20libc%2Fdce.h)) and PE header flagged for EFI. | Include UEFI support (via `STATIC_YOINK("EfiMain")` or `-DSUPPORT_VECTOR=251` at build) so firmware can execute it as `BOOTX64.EFI`/`BOOTAA64.EFI`. |
| **Note:** ARM64 systems typically boot via UEFI (no legacy BIOS). | (Cosmopolitan doesn’t support an ARM “BIOS”; use UEFI.) | For ARM64 targets, ensure UEFI path is enabled. Boot firmware must support running the APE as an EFI application. |

In summary, **for x86_64** the llamafile binary you built likely already boots on BIOS out-of-the-box ([How to boot bare metal on actual hardware? · jart cosmopolitan · Discussion #805 · GitHub](https://github.com/jart/cosmopolitan/discussions/805#:~:text=,examples%2Fvga2.c)), but to also boot on pure UEFI systems (or any ARM64 hardware), you should rebuild or modify it to include UEFI support. Next, we’ll prepare a USB with the binary for each case.

## 3. Preparing a Bootable USB Stick

Now that we have a **llamafile.com** binary with the appropriate boot code, we can write it to a USB drive and test booting. There are two approaches depending on target firmware:

**A. BIOS Boot (Legacy):** You can treat the `.com` binary as a raw disk image containing a boot sector. Simply write it directly to the USB device’s beginning. For example, if the USB is `/dev/sdX`:

```bash
sudo dd if=llamafile.com of=/dev/sdX bs=4M conv=notrunc
```

This will copy the entire binary onto the device starting at LBA0. The BIOS will read the first 512 bytes (the embedded MBR code) and jump into it, which then continues to execute the rest of the binary (already on the disk) as the program in long mode. Remy van Elst confirmed that a Cosmopolitan APE (his `vi.com`) booted on real hardware when written with `dd` to a USB drive ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Update%3A%20I%27ve%20loaned%20an%20x86,dd)). 

**Important:** Be **careful with the dd target** – use the raw device (like `/dev/sdX`, not a partition like `/dev/sdX1`). This method overwrites the device’s MBR. Also, *some BIOSes require the drive to have a valid partition table to appear in the boot menu.* If your BIOS does not list the USB, you may need to create a partition table:
  - One workaround is to create one partition spanning the drive and mark it bootable, then dd the binary *into that partition’s start* (so that the partition’s boot sector gets the Cosmo MBR). This is advanced and usually not necessary, but keep it in mind if a direct dd isn’t recognized by your firmware.

**B. UEFI Boot:** For UEFI, you should not dd the image raw (UEFI won’t treat a raw blob as bootable). Instead, do the following:
  1. **Format the USB with GPT (or MBR) and a FAT32 partition** – Create a small FAT32 partition (an “EFI System Partition”). For example, using `gdisk` or `fdisk`, make a partition and set the type to EFI (if GPT) or set the partition as primary/active (if MBR).
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
  3. Now the USB is a proper UEFI boot disk. On UEFI PCs, you might need to disable Secure Boot (Cosmopolitan binaries are not signed) or enable “UEFI boot from USB”. The firmware should detect the FAT partition and launch `bootx64.efi`. If it doesn’t auto-boot, you can enter the UEFI menu or shell and manually select the file.

**Hybrid approach:** You can actually support **both** BIOS and UEFI on one USB by combining these. For instance, you could partition the USB, put the binary at the MBR (for BIOS) *and* also have a FAT partition with it as an EFI file. Another simpler method is to create a single FAT32 partition, copy the file as `bootx64.efi` *and* also mark the partition bootable and copy the first 440 bytes of the binary to the MBR. However, these steps are intricate – if you need universal compatibility, it might be easier to carry two USBs or use one method at a time.

**Testing on QEMU:** Before rebooting real hardware, it’s wise to test in QEMU for both modes:
- *BIOS test:* Run QEMU in BIOS mode and attach the binary as a drive. For example:  
  ```bash
  qemu-system-x86_64 -m 1G -nographic -drive file=llamafile.com,format=raw,index=0,media=disk
  ```  
  This treats the file as a raw disk. The `-nographic` plus `-serial stdio` will direct output to your terminal. If all goes well, you’ll see your program’s output (likely some startup logs or a prompt). In the bare-metal Vi example, QEMU directly launched into Vi ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Then%20execute%20the%20following%20command,disk)).
- *UEFI test:* Install an OVMF (UEFI) firmware for QEMU. Run:  
  ```bash
  qemu-system-x86_64 -m 1G -bios OVMF.fd -drive format=raw,file=fat:rw:./efidisk
  ```  
  Here `./efidisk` is a directory containing an EFI/BOOT/bootx64.efi copy of your binary (QEMU will present it as a FAT volume). When QEMU starts, it may drop to an EFI shell – from there, you can do `FS0:` then `BOOTX64.EFI` (or it might auto-run if properly set). This was the approach suggested by Cosmopolitan’s author for testing UEFI apps ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=%2A%20qemu,amalgamated%20release%20binaries%20then%20it)). You should observe the program starting up similarly.

Once QEMU confirms both BIOS and UEFI boots, you can confidently try real hardware.

## 4. BIOS vs UEFI: Bootloader Differences and Considerations

Booting via BIOS or UEFI will ultimately run the same llamafile code, but there are a few differences in environment:

- **CPU State:** The Cosmopolitan bootloader (in BIOS mode) will switch the CPU from real mode to 64-bit long mode before entering the C `main()` function. In UEFI mode, the firmware already provides a 64-bit execution environment. Either way, by the time your program’s `main` runs, it’s in 64-bit mode with paging enabled. The Cosmopolitan runtime abstracts this, so you typically don’t need to handle it.

- **Console I/O:** Under BIOS, **Cosmopolitan’s default** is to use the serial port for standard I/O (since there’s no OS). Unless you enabled VGA text output (via `vga_console`), you might not see anything on screen – instead, connect a serial terminal to view output ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=I%20currently%20only%20have%20a,but%20on%20the%20serial%20port)). On QEMU, `-serial stdio` shows this easily. Under UEFI, printing to `stdout` may use UEFI’s console (which often gets redirected to the firmware output or still the serial, depending on system). If nothing is displayed on UEFI, you might again use a serial or UEFI debug output. For interactive input (keyboard), BIOS provides INT 16h (Cosmopolitan might handle basic input via BIOS), and UEFI has its console input protocol. Be aware that **GPU/Display** use in UEFI is not trivial – many UEFI systems do not support VGA text mode ([VGA on UEFI : r/osdev](https://www.reddit.com/r/osdev/comments/yjm04z/vga_on_uefi/#:~:text=I%20did%20some%20experiments%20about,BIOS%20it%20should%20just%20work)) ([VGA on UEFI : r/osdev](https://www.reddit.com/r/osdev/comments/yjm04z/vga_on_uefi/#:~:text=UEFI%20doesn%27t%20require%20VGA%20compatibility,adapter%20in%20the%20first%20place)). Therefore, relying on serial for text interface is recommended for both.

- **Disk access:** In this scenario, we actually don’t need to read any external files – the model weights are embedded in the binary and loaded in RAM at boot. Cosmopolitan’s BIOS stub likely used INT 13h to load the rest of the file into memory initially. If your program did need file I/O, Cosmopolitan’s metal mode has very limited drivers (no full filesystem drivers). Typically, you’d include everything needed in memory. (Networking or storage beyond what’s in memory is largely unsupported in metal mode as of now, except maybe trivial BIOS disk reads or what UEFI provides.)

- **Memory availability:** On real hardware, your program will only have as much memory as the firmware hands over. Cosmopolitan’s bare-metal malloc will use the memory map (e.g., BIOS E820 or UEFI memory map) to know available RAM. Ensure the machine has enough RAM for the model – e.g., a 4GB model plus overhead likely needs >8GB RAM to run comfortably. If you encounter allocation failures on bare metal, it could be that memory is fragmented or limited by firmware settings. (UEFI might reserve some memory; BIOS might need himem, etc.) Testing on a machine with ample RAM is best.

- **ARM64 specific:** On an ARM64 machine, the only way your binary runs is if the firmware can execute the PE binary (with `EfiMain`). This means practically an UEFI environment (most ARM developer boards or servers use UEFI, as do Apple Silicon Macs via their own boot mechanism). There is no legacy BIOS on ARM, so the USB must be UEFI. Additionally, on ARM there is no VGA text; you will need serial or framebuffer output. Cosmopolitan may not have a specialized ARM console driver, so be prepared to rely on serial exclusively when booting on ARM hardware. 

In short, **for x86_64 PCs** you have the flexibility of BIOS or UEFI. For **ARM64 devices**, use UEFI. Once booted, the llamafile should run the same inference server code as if launched under an OS – it will initialize the model and likely start listening on a port. (Note: Without an OS, networking isn’t available unless you’ve integrated a driver. So a web UI might not function on true bare metal unless you add a network driver. In practice, “bare metal llamafile” might be more of a tech demo running in offline mode or with pre-loaded prompts, since serving a web interface needs TCP/IP. One could attach a serial console UI or use it purely for local computation.)

## 5. Debugging Bare-Metal Cosmopolitan Binaries

Getting a cosmopolitan binary to boot can involve some trial and error. Here are some tips and common issues:

- **Use QEMU and Serial Output:** As mentioned, use QEMU in both BIOS and UEFI modes to test quickly. The `-nographic` and `-serial stdio` options are your best friend – they redirect the emulated serial port to your console. Cosmopolitan’s **–strace** and **–ftrace** flags (if enabled) likely won’t work without an OS, but basic `printf` logging will. If nothing appears, try adding a very early `puts("Reached here")` in your `main` to see if it gets that far.

- **Triple Fault or Hang on Boot:** If the machine reboots or freezes immediately, it suggests the bootloader code didn’t properly transition to your code. This could happen if the binary wasn’t written correctly to the USB (e.g., missing the boot signature or truncated). Ensure `dd` used `conv=notrunc` (do **not** truncate the output if your binary is larger than the device – obviously, the device must be at least as large as the file). Also verify the binary’s first 2 bytes are `0x4D 0x5A` (“MZ”) and bytes 511–512 are `0x55 0xAA`. If not, the file may not be seen as bootable by BIOS.

- **BIOS not detecting USB:** As noted, some BIOS firmware won’t boot a “superfloppy” USB. If you dd’ed the image and it’s not listed, consider creating a partition table. For example, create one partition starting at sector 2048 (1MB in) and dd the file to that offset (`of=/dev/sdX seek=2048`). Then install a generic MBR that jumps to the partition (Syslinux or GRUB’s MBR could do). This is complex; alternatively try another PC or use UEFI mode which is more standardized for USB.

- **UEFI application not launching:** If you see the UEFI shell error like “not recognized as an internal or external command”, the binary might not have the EFI subsystem set. Double-check that `EfiMain` was linked in. You can use the Linux `objdump` or `pesign` tools to inspect the PE header of `bootx64.efi`. It should indicate `Subsystem: EFI Application`. If it says `Windows GUI` or `Console`, then it’s still a Windows PE, not an EFI. In that case, revisit the build flags (you may need the `SUPPORT_VECTOR=251` method to flip it). Another clue: if your binary exceeds ~4GB and you didn’t remove Windows support, it wouldn’t run on Windows anyway (Windows has a 4GB max on PE files) ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=match%20at%20L494%20Unfortunately%2C%20Windows,llamafile%20allows%20you%20to%20use)), so you lose nothing by switching to EFI support.

- **No network / limited functionality:** Remember that without an OS, many syscalls are no-ops or stubs. Cosmopolitan’s metal mode is quite minimal. If your llamafile tries to open a browser (as it does on normal OS to show the chat UI), it obviously can’t do that on bare metal. You may need to run it in a mode where it just prints to console or accepts input from serial. Check if llamafile has a flag for CLI-only operation (perhaps it does). Otherwise, you’re essentially running the model inference loop without interactive UI on real hardware.

- **Logging and breaks:** If you have a problem where the binary starts but behaves unexpectedly, you can debug by attaching GDB to QEMU (for BIOS, use `-s -S` to have QEMU wait and listen for gdb). Because Cosmopolitan outputs a `.dbg` ELF, you can load symbols from `llamafile.com.dbg` into GDB for source-level debugging ([cosmopolitan/tool/cosmocc/README.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/tool/cosmocc/README.md#:~:text=%60hello.dbg%60%20%28x86,file%60%20command)). This is advanced, but possible.

- **Common Cosmopolitan quirks:** If the binary runs on QEMU but not on real hardware, the issue could be hardware differences. For example, some very new PCs have no Legacy BIOS support at all (hence require UEFI). Or certain UEFI implementations might not initialize a VGA console at all (so you see nothing if you expected text output). In such cases, verify that something is happening (disk LED activity, etc.) or rely on serial. Another quirk: some laptops might not enable the serial port by default; if so, you truly might have no output device. Using a PC with serial or a USB-to-serial adapter could be the only way to see output in a pure metal environment.

## 6. Architecture Compatibility: x86_64 vs ARM64

One of Cosmopolitan’s feats is making a single binary work across architectures. For our use case, *x86_64 is the primary target*, but *ARM64 (AArch64)* is also supported by Cosmopolitan and llamafile:

- **Building for ARM64:** The `cosmocc` toolchain automatically includes ARM64 code in the output. If you built on an x86 machine, you already have an ARM64 slice in `llamafile.com` (as noted earlier). If you want to target ARM64 *only* (to reduce size slightly), Cosmopolitan provides separate compilers (`aarch64-unknown-cosmo-cc`) ([cosmopolitan/tool/cosmocc/README.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/tool/cosmocc/README.md#:~:text=%2A%20%60aarch64,is%20compiled%20with%20the%20correct)), but in most cases the fat binary is fine.

- **Running on ARM hardware:** The binary can run on Linux/ARM or macOS (as a userland program) out of the box. Booting it on bare metal ARM hardware requires UEFI firmware:
  - Many ARM development boards (and servers) use UEFI firmware (e.g., Ampere servers, SolidRun HoneyComb, etc.). If you have such a board, you can try to boot the USB prepared with the ARM64 EFI (`BOOTAA64.EFI`). Ensure the file name is correct and the system is in UEFI mode. If the board only boots via u-boot or custom bootloaders, you might need to chain-load an EFI environment.
  - On devices like Raspberry Pi: The Pi does not natively use UEFI (it has its own bootloader sequence), but you can install a UEFI firmware for Pi (there’s a project providing TianoCore EDK2 for RPi). With that, you could in theory boot the llamafile. Without it, Cosmopolitan can’t directly interface with the Pi’s firmware/GPU; this is an unlikely path.
  - On Apple Silicon Macs: They have a form of UEFI compatibility. However, Apple Secure Boot may prevent external unsigned EFI binaries from booting. This is not a trivial test case, so we focus on PCs and standard ARM boards.

- **Differences in execution:** The llamafile code (which is largely C/C++ from llama.cpp) should work the same on ARM64. Cosmopolitan’s libc will abstract system differences. Performance may differ (ARM CPU vs x86 CPU for the same model). Ensure any assembly in llama.cpp is compiled for ARM (llama.cpp does have ARM NEON optimizations, which should be picked up if the build was fat and if the code detects an ARM CPU at runtime). One thing to watch: some Cosmopolitan system interfaces might not be fully implemented on ARM bare metal – e.g., if Cosmopolitan had any BIOS-specific assumptions, those won’t hold on ARM. But since we rely on UEFI there, it likely uses UEFI services for things like memory map.

- **Testing on ARM via QEMU:** You can also test the ARM64 path using QEMU’s AArch64 mode. For example:  
  ```bash
  qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 2G -bios <PATH_TO_EDK2_BIN> \
      -drive file=fat:rw:./efidisk_arm
  ```  
  (where `efidisk_arm` has an `EFI/BOOT/bootaa64.efi` file). This would simulate an ARM UEFI system. If your binary is truly fat, you could even use the same USB image by just renaming the efi file accordingly. This is an advanced test but can prove that the ARM slice of the binary is functional.

In practice, if your goal is “boot a PC from USB into an LLM runtime”, x86_64 will be the typical case. ARM64 support is nice to have for completeness (and for possibly booting something like a Jetson or an ARM server board into a local LLM appliance).

## 7. Examples of Cosmopolitan Metal Mode in Action

Cosmopolitan Libc’s metal mode is still a novel approach, but there are already a few compelling examples and projects:

- **Bare-Metal Vi Editor:** *Remy “Raymii” van Elst* demonstrated booting a tiny Vi text editor on bare metal using Cosmopolitan. He compiled the `viless` editor with Cosmopolitan and booted it from a USB. The screenshot below shows “Hello from Bare Metal Vi!” running directly in QEMU with no OS ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Then%20execute%20the%20following%20command,disk)). This project proved that even interactive programs can run with nothing but Cosmopolitan as the OS layer.

   ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html)) *Vi running on bare metal via Cosmopolitan (QEMU output). The Vi binary was written to a disk image and booted directly, showing a text UI over serial/VGA ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Then%20execute%20the%20following%20command,disk)).*

  To boot Vi on real hardware, Raymii simply dd’ed the `vi.com` to a USB stick and it was recognized by the BIOS ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Update%3A%20I%27ve%20loaned%20an%20x86,dd)). This is a great sanity check example similar to what we’re doing with llamafile.

- **Cosmopolitan Examples (VGA and Hello):** The Cosmopolitan repository itself provides low-level examples. For instance, `examples/vga.com` and `examples/vga2.com` illustrate printing text in BIOS and UEFI modes. The maintainers have indicated that `vga.com` can be dd’ed to a drive and run on real BIOS hardware ([How to boot bare metal on actual hardware? · jart cosmopolitan · Discussion #805 · GitHub](https://github.com/jart/cosmopolitan/discussions/805#:~:text=%60dd%60,g)). They also show how adding `EfiMain` (as in `vga2.c`) enables UEFI booting ([How to boot bare metal on actual hardware? · jart cosmopolitan · Discussion #805 · GitHub](https://github.com/jart/cosmopolitan/discussions/805#:~:text=,examples%2Fvga2.c)). These examples, while not as complex as an LLM, confirm the boot process. Another example was a demo called “deathstar.com” (a graphical demo) that the author got running under UEFI as a proof-of-concept ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=Image%3A%20image)) ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=%2A%20qemu,amalgamated%20release%20binaries%20then%20it)).

- **Llamafile usage (non-boot scenario):** Outside of bare metal, llamafile has been used to distribute models like LLaVA and Mistral in a single file for easy running ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=The%20easiest%20way%20to%20try,data%20ever%20leaves%20your%20computer)) ([Llamafile/tinyBLAS, and Julia small-install/binary challenge](https://discourse.julialang.org/t/llamafile-tinyblas-and-julia-small-install-binary-challenge/118206#:~:text=llamafile%20lets%20you%20turn%20large,in)). Our goal extends this convenience to the extreme: running it on a machine with no OS. While not a common use case, it could be seen as creating a portable “LLM appliance” – imagine plugging in a USB and having the computer boot straight into an AI assistant that you can interact with locally, without even a hard drive or installed OS.

- **Netbooting Cosmopolitan programs:** There are reports of using PXE to network-boot Cosmopolitan binaries. For example, one user used **Pixiecore** to boot a Cosmopolitan-built hello world on netbooting machines ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=paulreimer%20%20%20commented%20,91)). This shows that as long as you can get the binary into memory via some boot mechanism (USB, CD, netboot), it can run. Llamafile could similarly be network-booted in a cluster to quickly spin up an LLM server node without any OS setup – an interesting idea for ephemeral AI instances.

- **Other projects:** *Redbean* (a web server in a single APE file by Cosmo’s author) is not a bare-metal app (it runs on top of OS), but it demonstrates the power of the single-binary concept on multiple OS. We mention it to highlight that many complex programs (Lua, SQLite, etc.) have been compiled under Cosmopolitan; taking the extra step to go “metal” is the unusual part. So far, niche tools and demos like the above have done so. Llamafile might be one of the first to attempt a large-scale bare-metal AI runtime.

## 8. Conclusion

By combining **Cosmopolitan libc’s bare-metal capabilities** with **Mozilla’s llamafile**, we can create a bootable USB stick that turns any x86_64 PC (or ARM64 device with UEFI) into a dedicated LLM machine – no OS required. The key steps involved compiling the binary with the right flags (Cosmopolitan “metal” mode), ensuring both BIOS and UEFI bootloader code are present in the output, and then properly imaging that binary onto a USB in the format the firmware expects. We also discussed how to debug issues and the limitations one might face running without a traditional operating system (lack of drivers for display, network, etc., unless explicitly handled).

This approach showcases the power of *Actually Portable Executables*: the same file can be an `.exe` on Windows, an ELF on Linux, or even your computer’s initial boot code. As Cosmopolitan’s documentation notes, a single APE binary runs on “Linux + Mac + Windows + … + BIOS” across architectures ([GitHub - jart/cosmopolitan: build-once run-anywhere c library](https://github.com/jart/cosmopolitan#:~:text=Cosmopolitan%20Libc%20makes%20C%20a,and%20the%20tiniest%20footprint%20imaginable)). In our case, we exploited the BIOS/UEFI aspect to achieve something like a tiny single-purpose “OS” that does nothing but run an LLM.

**References:** The process and nuances described here are drawn from official Cosmopolitan libc docs and community experiments. Cosmopolitan’s own issue tracker has commentary on UEFI support ([How to boot bare metal on actual hardware? · jart cosmopolitan · Discussion #805 · GitHub](https://github.com/jart/cosmopolitan/discussions/805#:~:text=,examples%2Fvga2.c)) and how to toggle it ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,x86_64)), and the APE specification explains how the BIOS boot works internally ([cosmopolitan/ape/specification.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/ape/specification.md#:~:text=The%20letters%20were%20carefully%20chosen,as%20a%20floppy%20disk%20image)). Mozilla’s llamafile repository provided the build framework for combining llama.cpp with Cosmopolitan ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=Our%20goal%20is%20to%20make,most%20computers%2C%20with%20no%20installation)). We also cited Remy van Elst’s bare-metal Vi guide for practical insight on compiling and dd’ing a Cosmopolitan binary to USB ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Then%20execute%20the%20following%20command,disk)) ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Update%3A%20I%27ve%20loaned%20an%20x86,dd)). With these resources and steps, you should be able to build your own bootable “llamafile” USB and run an LLM on bare metal. Enjoy your foray into OS-free computing with LLMs!

**Sources:**

- Cosmopolitan Libc documentation and issues ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,x86_64)) ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=,%40see%20libc%2Fdce.h)) ([cosmopolitan/ape/specification.md at master · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/blob/master/ape/specification.md#:~:text=The%20letters%20were%20carefully%20chosen,as%20a%20floppy%20disk%20image)) ([How to boot bare metal on actual hardware? · jart cosmopolitan · Discussion #805 · GitHub](https://github.com/jart/cosmopolitan/discussions/805#:~:text=,examples%2Fvga2.c))  
- Mozilla-Ocho **llamafile** project docs ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=Our%20goal%20is%20to%20make,most%20computers%2C%20with%20no%20installation)) ([GitHub - Mozilla-Ocho/llamafile: Distribute and run LLMs with a single file.](https://github.com/Mozilla-Ocho/llamafile#:~:text=and%20NetBSD%29,you%20prefer%20most%20for%20development))  
- *Raymii.org* – Bare-metal Vi with Cosmopolitan ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Then%20execute%20the%20following%20command,disk)) ([Bare Metal Vi, boot into Vi without an OS! - Raymii.org](https://raymii.org/s/blog/Bare_Metal_Boot_to_Vi.html#:~:text=Update%3A%20I%27ve%20loaned%20an%20x86,dd))  
- Cosmopolitan example discussions (GitHub Q&A) ([How to boot bare metal on actual hardware? · jart cosmopolitan · Discussion #805 · GitHub](https://github.com/jart/cosmopolitan/discussions/805#:~:text=,examples%2Fvga2.c)) ([Support UEFI · Issue #12 · jart/cosmopolitan · GitHub](https://github.com/jart/cosmopolitan/issues/12#:~:text=Image%3A%20image)) and README
