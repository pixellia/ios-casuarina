# ios-vince: iOS 16 on the Redmi 5 Plus (vince, Snapdragon 625)

An experimental port of Apple's XNU kernel and an iOS 16.7 userland to the **Xiaomi Redmi 5 Plus ("vince", MSM8953)**.
It is a fork of [ios-topaz](https://github.com/MakrSas/ios-topaz), which is itself built on
[ios-sweet](https://github.com/dipa-studio/ios-sweet) and [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel).
All the vince-specific work lives in `xnu/patches/096x`, `vince/` and the `VINCE` build flag.

> **Status, 2026-11-08: all eight cores run, `launchd` and dozens of iOS daemons run, SpringBoard's interface is drawn, and `backboardd` now renders its frames on the phone's Adreno 506 GPU through Mesa (freedreno). It is slow (a few to ~18 frames a second) and the GPU path is still being tuned.**
> This is a bring-up project, not a ROM. Do not expect a working iPhone.

## Is this for you?

Read this first, it will save you an evening.

- It **wipes Android**. The iOS root filesystem is written into the `userdata` partition. Everything else on the
  phone is left alone (bootloader, `boot`, `recovery`, `system`, modem, `persist`), and the kernel is started with
  `fastboot boot`, so nothing but `userdata` is ever flashed. Do it only on a phone you own and can restore.
- You need an **unlocked bootloader**, a Linux PC with `fastboot`, a **macOS GitHub runner** to build XNU
  (Actions, free for public repos), and **your own iOS IPSW** (none of Apple's files are in this repository).
- There is **no serial console**. Debugging is done by log.txt (use sh tools/sweet-log-pull.sh log.txt in terminal when you in recovery).
!Patience required!
- Only the **4 GB RAM / 64 GB storage** model has been tested.
- Most of this code was written with an AI assistant (see [How this was made](#how-this-was-made)). Read before you trust.

## What works

| | |
|---|---|
| XNU boots (4 KiB pages, GICv2, architected timer, 24 bpp text console) | ✅ |
| eMMC driver inside the kernel (`rd=emmcroot0`, ADMA2, GPT, read and write) | ✅ |
| HFS+ iOS root mounted from `userdata`, `launchd` starts, dozens of daemons run | ✅ (2026-11-02) |
| All eight CPU cores (`cpus=8`, PSCI) | ✅ (2026-11-03) |
| Persistent kernel console log on the eMMC, readable from TWRP (`vincelog`) | ✅ (2026-11-03) |
| Userland process sampler: stacks, workqueue state and unread port messages of chosen processes | ✅ (2026-11-04) |
| Workqueue / dispatch: threads for ordinary dispatch queues (patch 0975) | ✅ (2026-11-05), see below |
| iOS display: `backboardd` opens the panel, iOS frames reach the screen (Apple logo shown) | ✅ (2026-11-05) |
| Touch and button drivers are opened by `backboardd` (`SweetHIDTouch`, `SweetHIDButtons`) | 🟡 opened, input not tested |
| SpringBoard UI | 🟡 drawn, laggy; input not confirmed |
| GPU: Adreno 506 driven by the in-kernel `VinceGPU` service (msm-DRM-style requests) and Mesa 25 freedreno; CoreAnimation draws through it, colours and blur are right | 🟡 works (2026-11-07), slow, see [GPU](#gpu) |
| Battery readout from the PMI8950 (read only, 0979/0980) | 🟡 |
| Wi-Fi, Bluetooth, audio, modem, camera, sensors | ❌ |

It is also slow: eight Cortex-A53 cores, a GPU path that is still read-back bound and an eMMC read speed of about 17 MB/s
(the controller runs at 19.2 MHz SDR for now).

**The bug that blocked userland for days (fixed by 0975).** XNU asks the scheduler for the maximum parallelism of each QoS
class when the first process opens its workqueue. On this port the answer was **0** for every class. With 0, the
admission check of every non-overcommit thread request can never pass, so `dispatch_async` onto a global queue never got a
thread: `usermanagerd`, `runningboardd`, `MobileGestaltHelper` and then SpringBoard and `backboardd` all waited for work
that was queued but never started. Patch 0975 prints the values and never lets a bucket be 0. The root cause of the 0 (what
`machine_info.logical_cpu` holds at that moment) is not yet understood.

Known noise: `driverkitd` is killed by its memory limit and `bluetoothd` / `fairplayd.H2` respawn (no hardware for them).
It does not stop anything.

## The hardware, and why it was hard

| | |
|---|---|
| SoC | Snapdragon 625, MSM8953: 8 × Cortex-A53 r0p4, ARMv8.0 |
| Missing CPU features | **No 16 KiB granule** (`TGran16 = 0`), no LSE atomics, no PAN, no VHE |
| Interrupts | **GICv2** (MMIO), not the GICv3 that iOS-era XNU assumes. Virtual timer is INTID 20 |
| Storage | eMMC 5.1, 58 GiB, Qualcomm `sdhci-msm`. `userdata` is GPT entry 50 |
| Display | 1080 × 2160 panel (TD4310, DSI video mode). LK leaves a packed **24 bpp** framebuffer at `0x90001000` |
| Bootloader | Xiaomi LK (aboot), unlocked. `fastboot boot` works |

Consequences:

- Apple's iOS kernels use 16 KiB pages. This port builds XNU with **4 KiB pages** (`TOPAZ_4K=1`).
- The inherited Qualcomm drivers (battery, display, touch) poke SM6225 (Snapdragon 662) registers that do not exist on
  MSM8953. On this chip such an access **hangs the bus**, and the phone resets about 30 s later with no message.
  (That was the long "silent reboot" during bring-up: the battery driver, patch 0964.)
- LK hands over the eMMC controller in a leftover HS400 state, so SDHCI commands never complete.
  The kernel driver re-initialises the controller and card from scratch the way Linux does
  (vendor-spec `0xa9c`, HC mode, power-control handshake, clocks programmed through GCC `sdcc1_apps_clk_src`,
  CMD0/1/2/3/7, 8-bit bus).
- There is no display (MDP/DSI) driver: iOS draws BGRA 32 bpp frames and the kernel converts them with the CPU into the
  packed 24 bpp buffer LK left scanned out. The GPU only draws the frames; it does not scan them out.

## How it boots

```
Xiaomi LK  ->  fastboot boot (Android boot.img)
                 kernel  = our loader (arm64 Image header) + stock DTB appended, so LK accepts it
                 ramdisk = payload: XNU Mach-O + Apple Device Tree (made by tools) + boot-args
          ->  loader: copies segments, builds boot_args and the ADT, jumps to XNU
          ->  XNU (xnu-8796, 4 KiB pages) -> IOKit -> eMMC root -> /sbin/launchd -> iOS daemons
```

Nothing is flashed except the iOS root in `userdata`. The loader and packer are in `vince/`.

## XNU patches (all in `xnu/patches/`)

The kernel is xnu-8796 (macOS 13.5 source) built on GitHub Actions through
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build); the patch series continues the
ios-topaz numbering.

| Patch | What it does |
|---|---|
| 0960 | `VINCE` build flag and board config |
| 0961 | GICv2 interrupt controller, boot CPU 0, timer INTID 20 |
| 0962 | 24 bpp early console on the LK framebuffer |
| 0963 | On-screen diagnostics (`vince_diag`: uptime pulse, GIC/timer dump, thread stacks); no 30 s `IORTC` wait |
| 0964 | Removes the SweetBattery driver (hangs the MSM8953 bus) |
| 0965 | eMMC driver and root device: `rd=emmcroot0`, GPT, ADMA2, BSD disk glue |
| 0966 | Non-destructive eMMC write test (`emmcwritetest=`) |
| 0967 | eMMC robustness: power-event polling while commands run, CMD3 retries |
| 0968 | iOS display for vince: composes frames in a 32 bpp shadow surface and converts them to the 24 bpp panel buffer |
| 0969 | Rate-limited exec trace, optional exec deny list (`sweetexecdeny=`), display status line (`VINCE FB`) |
| 0970 | Persistent console log on the eMMC (`vincelog`), compatible with the ios-sweet log format and tools |
| 0971 | Scheduling: ordinary daemons run in the background class, `backboardd` and `SpringBoard` get a boost |
| 0972 | Starts the process sampler from the eMMC driver (first sample at 45 s, then every 30 s) |
| 0973 | Mach message trace for watched processes (`vinceipc=`) |
| 0974 | The sampler also prints per-process workqueue state and ports with unread messages |
| 0975 | Workqueue max parallelism is never 0 (see above) |
| 0976 | Keys and touch screen (SPMI PON, TLMM, QUP3 I2C, Synaptics RMI4) |
| 0977 | CPU cluster 1 gets the same clock as cluster 0, MHz per CPU is printed (`vinceclk=0` off) |
| 0978 | Optional 1401/1036 MHz CPU clock (`vincemhz=`) |
| 0979 / 0980 | Battery from the PMI8950 over SPMI (read only); keeps the last good reading across a failed read |
| 0981 | Display off also switches the WLED backlight off (`vinceblank=0` disables) |
| 0982 | Adreno 506 bring-up and the `VinceGPU` service, opt-in (`adreno=N`); the Qualcomm firmware is not in the tree |
| 0983 | Keeps the top 4 MiB of RAM out of the VM for the GPU (ring and secure page table) |
| 0984 | `VinceGPU` self-test (`adreno_test=1`) |
| 0985 | Logs jetsam per-process limit hits; `vincenolimit=1` skips the kill |
| 0986 | GPU buffers are one physically contiguous piece (the GPU has no IOMMU here: its address is the physical address) |
| 0987 | A 192 MiB pool of RAM kept out of the VM for GPU buffers (`0x73c00000`-`0x7fc00000`) |
| 0988 | `vincecache=1`: pool buffers are mapped cached and the kernel does the cache maintenance (readback 150 ms -> ~30 ms a frame) |
| 0989 / 0990 | `vinceplace=1` (needs `vincecache=1`): the window server's screen surfaces live in the pool and the GPU draws into them in place. **Experimental, not yet confirmed on the phone** |
| 0991 | Logs what fills the GPU pool when a buffer does not fit; stops rescanning RAM for big buffers that never come |

`xnu/patches/0020-stage-bearssl.sh` takes BearSSL from `xnu/vendor/sweet_bearssl.tgz` when that file exists, so a build does
not depend on `bearssl.org` (which often answers HTTP 502). `vince/tools/make-bearssl-vendor.sh` makes the archive from the
pinned commit.

## GPU

The GPU is the Adreno 506 (A5xx). The kernel side is `iokit/Kernel/arm/VinceGPU.cpp` plus the bring-up in
`bsd/dev/vince_adreno.c`; it offers Linux's msm DRM requests as IOKit selectors. The userland side is built on
macOS by `userland/gpu/mk-topaz-ci.sh` (Actions workflow `topaz.yml`) over a Mesa 25.0.7 freedreno build:

- `libtopaz-gl.dylib` is the OpenGL ES library CoreAnimation talks to (`EAGLContext` over Mesa's off-screen OSMesa);
- `libtopaz-inject.dylib` and a `backboardd` wrapper put it into the window server; `vince-topaz-install.py` installs
  it into the root image (`--undo` removes it). `gl=0` in the boot-args or a missing GPU service keeps the CPU renderer.

Things learnt the hard way: the GPU has no IOMMU here, so every buffer must be one physically contiguous piece
(hence the pool); the pool is kept out of the VM, so user mappings of it need an explicit cache mode (default is device
memory, where unaligned stores fault); the GPU does not snoop the CPU caches.

**Speed.** The frame is drawn on the GPU in a few ms to ~40 ms, then read back by the CPU. Write-combined readback was
~70 MB/s (5 fps); cached mappings with kernel cache maintenance (0988) give ~18 fps. Drawing in place (0989/0990)
avoids the readback but is unfinished: the 192 MiB pool fills up after several minutes (many long-lived textures), after
which GL reports out-of-memory. Open: why the pool fills, a bigger pool, the GPU clock.

## Build and run

1. **Kernel.** Push to the `vince` branch (or start the `xnu` workflow by hand). It runs on `macos-15` with
   `TOPAZ_4K=1` and `VINCE=1` and fails early if a patch did not apply. Download the `xnu-kernel` artifact; the file
   you need is `kernel.development.sweet`.
2. **Boot image.** Needs only Python 3:

   ```
   python3 vince/tools/vince_pack.py kernel.development.sweet vince-xnu.img \
     --cmdline "debug=0xc serial=3 cpus=8 keepsyms=1 rd=emmcroot0 emmcrw=1 rootrw=1 \
                unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
                launchd_unsecure_cache=1 wdt=-1"
   ```

   `--cmdline` replaces the default command line completely. `--cpus N` rewrites `cpus=` in it. `--native` makes iOS draw at
   the panel size (1080 × 2160) instead of the iPhone X layout (1125 × 2436, scaled down), and adds `sweetfb_native=1`.
   `--quiet` leaves the on-screen kernel text console out of the Device Tree (the log still goes to the eMMC).

   The packer wants the real iPhone X `/product` node: put `research/ipsw-x/d22ap.adt` in place first (it is not in git;
   see `tools/mkadt.py` for the `ipsw` command). Without it the packer warns `no /product node`, and MobileGestalt
   answers are wrong.
3. **iOS root.** On Linux (needs root, `apfs-fuse`, HFS+ tools, `rsync`), from an iPhone X (iPhone10,3) iOS 16.7 IPSW:

   ```
   tools/mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg ios16-root.img        # case-sensitive journaled HFS+, cryptexes merged
   # mount it read-write (fsck.hfsplus -fy, then mount -t hfsplus -o loop,force), then:
   sudo tools/sweet-root-tweaks.py /path/to/mounted/root
   img2simg ios16-root.img ios16-root.simg
   ```

   `sweet-root-tweaks.py` is what turns a plain IPSW root into one that survives bring-up (it stops crashing daemons from
   panicking the system, removes the CommCenter jobs, skips the hour-long data migration and Setup, and so on).
   Read its header, it is the list of everything iOS needed.
4. **Flash and boot.**

   ```
   fastboot flash -S 512M userdata ios16-root.simg     # wipes Android data. Always flash the sparse image
   fastboot boot vince-xnu.img
   ```

   After a big flash the Xiaomi bootloader's fastboot can hang: re-enter fastboot by hand (Power + Volume Down).

**Going back to Android:** `boot`, `recovery`, `system` and the other Android partitions are untouched. Format `userdata`
again (from recovery, or `fastboot erase userdata`) and boot Android as usual. This is the expected path, not something
that has been exercised here; back up first if you care about the data.

Before the first boot with a real root you can run the kernel against the old Android `userdata` with
`emmclist=1 emmchold=120`: the eMMC driver then prints the partition table and the head of the partition on screen.

## Useful boot-args

| Argument | Meaning |
|---|---|
| `rd=emmcroot0` | Root device is the eMMC partition named by `emmcroot=` (default `userdata`) |
| `emmcrw=1` / `rootrw=1` | Allow writes to the eMMC / mount the root read-write (needed: the journaled root writes at first mount) |
| `emmclist=1`, `emmchold=N`, `emmcpio=1`, `emmcselftest=0`, `emmcwritetest=1\|2` | eMMC diagnostics: list partitions, hold N seconds after the report, PIO instead of ADMA, skip self test, write test |
| `cpus=8` | Number of CPU cores to start (1-8; all eight work) |
| `vincelog=0\|1\|2`, `vincelogsecs=N` | Persistent log on the eMMC (mode, flush interval in seconds); read it from TWRP with `tools/sweet-log-pull.sh` |
| `sweetsample=a,b,c` | Process names (first 16 characters) the sampler prints stacks, workqueue and port queues for; `-` switches it off |
| `sweetsample_first=N`, `sweetsample_every=N` | Seconds before the first sample and between samples |
| `sweetiolog=a,b` | Processes whose IOKit lookups and opens are logged (default `backboardd,SpringBoard`, at most 400 lines) |
| `vinceipc=a,b` | Processes whose Mach sends are traced (`VIPC` lines, at most 600; `-` off) |
| `sweetexecdeny=a,b` | Executables the kernel refuses to start |
| `debug=0xc serial=3 keepsyms=1` | Standard XNU debug flags used here |
| `unentitled_ios_sim_launch=1`, `ignition_level=1`, `wdt_test=no_user_checkin`, `launchd_unsecure_cache=1`, `wdt=-1` | Make the macOS-configured kernel accept iOS binaries and skip checks that cannot pass here |
| `sweetfb_noconsole=1` | Mute the kernel text console once iOS presents its first frame |
| `sweetfb_hz=N` | Panel copy rate in Hz (default 10) |
| `sweetfb_native=1` | iOS draws at 1080 × 2160 (use together with `vince_pack.py --native`, the Device Tree canvas must match) |
| `vincediag=0` | Switch off the on-screen diagnostics (patch 0963) |
| `vincemhz=1401` | CPU clock in MHz (0978) |
| `vincenolimit=1` | Do not let jetsam kill processes at their memory limit (0985) |
| `adreno=11`, `adreno_test=1` | Start the Adreno 506 (level), run its self-test at boot (0982/0984) |
| `vincecache=1` | Cached mappings of GPU pool buffers with kernel cache maintenance (0988) |
| `vinceplace=1` | Screen surfaces in the GPU pool, drawn in place (0989/0990, needs `vincecache=1`, experimental) |
| `glframes=1`, `gltrace=A-B` | Userland GL library log: one line per frame; per-call trace of frames A..B (logging only) |
| `gl=0` | Keep CoreAnimation on the CPU renderer |
| `fdnobcache=1` | Userland: turn off freedreno's buffer cache (diagnostic) |

## Hardware facts worth keeping

Measured on the phone, not taken from a datasheet:

- LK loads the image at `0x10080000`, the DTB at `0x13400000`, the ramdisk at `0x13600000`.
  XNU gets RAM `0x20000000-0x7fffffff` (1.5 GiB for now); with the GPU the top 196 MiB of it is kept out of the VM (pool `0x73c00000`-`0x7fc00000`, GPU ring `0x7fc00000`-`0x80000000`).
- Framebuffer `0x90001000`, 1080 × 2160, stride 3240, bytes in the order B, G, R.
- GICv2: distributor `0x0b000000`, CPU interface `0x0b002000`. Both architected timers arrive as IRQ (not FIQ).
- eMMC: SDHCI `0x07824900`, controller core `0x07824000` (interrupts SPI 123 / 138). GCC SDCC1 clock registers start at `0x01842004`.
- PSCI 1.0 over `smc`. All eight cores come up (cluster 0 MPIDR 0-3, cluster 1 0x100-0x103).
- A second SD controller exists at `0x07864900` (the SD card slot); the port does not touch it.

## Roadmap

1. Let `lsd` finish the first-boot LaunchServices database and get SpringBoard to draw its first screen.
2. Finish the GPU: stop the pool from filling up, render in place (0989/0990), then the GPU clock. `IOAcceleratorES` itself is still an empty stub, rendering goes through the OpenGL ES library of `userland/gpu`.
3. Touch and buttons (the drivers are opened; input is untested).
4. Speed: faster eMMC modes (HS200/HS400), a trimmed root, a prebuilt LaunchServices database.
5. Find out why the scheduler reported a maximum parallelism of 0 (0975 only works around it).

## How this was made

The author does not write kernel code by hand. The analysis, the patches and the tools were produced by an AI
assistant (Claude, by Anthropic) working from the author's phone dumps, measurements and photos of the screen.
The author builds the kernel, flashes the phone, runs every test and reports what appears on the display.
Expect rough edges and read the patches before trusting them.

## Credits and licences

- [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel) (OOSEX GANG): the original XNU and iOS 16.5 userland port
  for the POCO X5 Pro. [ios-sweet](https://github.com/dipa-studio/ios-sweet) and
  [ios-topaz](https://github.com/MakrSas/ios-topaz) (MIT) are the bases of this fork: the boot shim, payload format,
  Device Tree generator, the display and surface drivers, the root-image tools and most of the patch series.
- Per-file licences and attributions are in [`CREDITS.md`](CREDITS.md) and [`vince/NOTICE.md`](vince/NOTICE.md).
  XNU patches are under the Apple Public Source License 2.0 like XNU itself.
- No Apple code, IPSW contents or firmware is distributed here. You must supply your own IPSW.
- Not affiliated with Apple, Xiaomi or Qualcomm. All trademarks belong to their owners.

More: [`NOTES.md`](NOTES.md) is the detailed log of the sweet/topaz bring-up this work builds on (their phones, not
vince), [`RECOVERY.md`](RECOVERY.md) is the topaz (Redmi Note 12 4G) recovery runbook, not valid for vince, and
[`vince/README.md`](vince/README.md) (in Ukrainian) describes the original loader test steps.
