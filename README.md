# ios-vince: iOS 16 on the Redmi 5 Plus (vince, Snapdragon 625)

An experimental port of Apple's XNU kernel and an iOS 16.7 userland to the **Xiaomi Redmi 5 Plus ("vince", MSM8953)**.
It is a fork of [ios-topaz](https://github.com/MakrSas/ios-topaz), which is itself built on
[ios-sweet](https://github.com/dipa-studio/ios-sweet) and [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel).
All the vince-specific work lives in `xnu/patches/096x`, `vince/` and the `VINCE` build flag.

> **Status, 2026-11-03: `launchd` and dozens of iOS daemons run on the phone. There is no usable interface yet.**
> This is a bring-up project, not a ROM. Do not expect a working iPhone.

## Is this for you?

Read this first, it will save you an evening.

- It **wipes Android**. The iOS root filesystem is written into the `userdata` partition. Everything else on the
  phone is left alone (bootloader, `boot`, `recovery`, `system`, modem, `persist`), and the kernel is started with
  `fastboot boot`, so nothing but `userdata` is ever flashed. Do it only on a phone you own and can restore.
- You need an **unlocked bootloader**, a Linux PC with `fastboot`, a **macOS GitHub runner** to build XNU
  (Actions, free for public repos), and **your own iOS IPSW** (none of Apple's files are in this repository).
- There is **no serial console**. Debugging is done by photographing the phone's screen. Patience required.
- Only the **4 GB RAM / 64 GB storage** model has been tested.
- Most of this code was written with an AI assistant (see [How this was made](#how-this-was-made)). Read before you trust.

## What works

| | |
|---|---|
| XNU boots (4 KiB pages, GICv2, architected timer, 24 bpp text console) | ✅ |
| eMMC driver inside the kernel (`rd=emmcroot0`, ADMA2, GPT, read and write) | ✅ |
| HFS+ iOS root mounted from `userdata`, `launchd` starts, dozens of daemons run | ✅ (2026-11-02) |
| iOS display (SpringBoard / Setup): converts iOS frames into the panel buffer | 🟡 patch 0968 written, **not yet tested on hardware** |
| More than one CPU core (`cpus=1` today, the other seven are parked) | ❌ not started |
| Touch, buttons, Wi-Fi, Bluetooth, GPU, audio, modem, camera, sensors, battery | ❌ |

It is also slow: one Cortex-A53 core, a CPU-only renderer and an eMMC read speed of about 17 MB/s
(the controller runs at 19.2 MHz SDR for now).

Known noise: `bluetoothd` and `fairplayd.H2` respawn in a loop (there is no hardware for them) and flood the console.

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
- Without a GPU driver the display is a CPU copy: iOS draws BGRA 32 bpp frames and the kernel converts them to the
  packed 24 bpp buffer LK left scanned out. No MDP or DSI hardware is touched.

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

## Build and run

1. **Kernel.** Push to the `vince` branch (or start the `xnu` workflow by hand). It runs on `macos-15` with
   `TOPAZ_4K=1` and `VINCE=1` and fails early if a patch did not apply. Download the `xnu-kernel` artifact; the file
   you need is `kernel.development.sweet`.
2. **Boot image.** Needs only Python 3:

   ```
   python3 vince/tools/vince_pack.py kernel.development.sweet vince-xnu.img \
     --cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 rd=emmcroot0 emmcrw=1 rootrw=1 \
                unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin \
                launchd_unsecure_cache=1 wdt=-1"
   ```

   `--cmdline` replaces the default command line completely. `--native` makes iOS draw at the panel size
   (1080 × 2160) instead of the iPhone X layout (1125 × 2436, scaled down), and adds `sweetfb_native=1`.
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
| `cpus=1` | Number of CPU cores to start (only 1 has been tried on vince) |
| `debug=0xc serial=3 keepsyms=1` | Standard XNU debug flags used here |
| `unentitled_ios_sim_launch=1`, `ignition_level=1`, `wdt_test=no_user_checkin`, `launchd_unsecure_cache=1`, `wdt=-1` | Make the macOS-configured kernel accept iOS binaries and skip checks that cannot pass here |
| `sweetfb_noconsole=1` | Mute the kernel text console once iOS presents its first frame |
| `sweetfb_hz=N` | Panel copy rate in Hz (default 10) |
| `sweetfb_native=1` | iOS draws at 1080 × 2160 (use together with `vince_pack.py --native`, the Device Tree canvas must match) |
| `vincediag=0` | Switch off the on-screen diagnostics (patch 0963) |

## Hardware facts worth keeping

Measured on the phone, not taken from a datasheet:

- LK loads the image at `0x10080000`, the DTB at `0x13400000`, the ramdisk at `0x13600000`.
  XNU gets RAM `0x20000000-0x7fffffff` (1.5 GiB for now).
- Framebuffer `0x90001000`, 1080 × 2160, stride 3240, bytes in the order B, G, R.
- GICv2: distributor `0x0b000000`, CPU interface `0x0b002000`. Both architected timers arrive as IRQ (not FIQ).
- eMMC: SDHCI `0x07824900`, controller core `0x07824000` (interrupts SPI 123 / 138). GCC SDCC1 clock registers start at `0x01842004`.
- PSCI 1.0 over `smc`. `CPU_ON` was shown to start cores 1 and 4 in the bare-metal tests, so SMP is realistic.
- A second SD controller exists at `0x07864900` (the SD card slot); the port does not touch it.

## Roadmap

1. See the iOS interface on the panel (patch 0968, waiting for its first hardware test).
2. Start the other seven cores through PSCI (`cpus=` greater than 1). This is the biggest speed-up available.
3. Quiet the respawn loops and trim the root so boot is faster.
4. A persistent kernel log on the eMMC, so debugging does not depend on photographing the screen.
5. Touch and buttons. Faster eMMC modes (HS200/HS400).

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
