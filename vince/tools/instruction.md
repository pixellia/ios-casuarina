# GPU firmware for ios-vince (Adreno 506)

The Adreno 506 GPU needs four firmware files from Qualcomm. They are proprietary, so **they are not in this repository
and never will be.** The kernel (patch 0982) carries an empty slot, and `vince-gpu-fw.py` fills it with the files from
**your own phone**, on your own computer.

Without them everything else still works: the GPU stays off (`adreno=0`, the default) and iOS draws with the CPU.

## What you need

| File | What it is |
|---|---|
| `a530_pm4.fw` | command processor microcode (PM4) |
| `a530_pfp.fw` | prefetch parser microcode (PFP) |
| `a506_zap.mdt` | secure "zap" shader, ELF header part |
| `a506_zap.b02` | secure "zap" shader, code part |

(The a5xx family shares the `a530_*` microcode; there is no separate `a506_pm4.fw`.)

## Step 1: get the files from your own phone

Take them from the firmware of **your** phone (or of the stock ROM for the same model you own). The usual place is
`/vendor/firmware` (on some ROMs `/system/vendor/firmware` or `/firmware/image`).

Any of these works:

- **From a running Android or TWRP:** `adb pull /vendor/firmware ./fw` (in TWRP, mount `vendor` or `system` first).
- **From a stock ROM image you downloaded for your phone:** convert a sparse `system.img` with `simg2img system.img
  system.raw`, mount it read-only (`sudo mount -o ro,loop system.raw /mnt`) and copy the four files from
  `/mnt/vendor/firmware` or `/mnt/system/vendor/firmware`.

Put the four files in one folder (subfolders are fine, the script searches them). Check the names match the table.

Keep this folder out of git. Add it to `.gitignore` if it lives inside a clone.

## Step 2: build the kernel as usual

Push to the `vince` branch and let the GitHub Actions workflow build XNU. The artifact has an **empty** slot, because the
firmware is not in the repository. Download `kernel.development.sweet`.

## Step 3: fill the slot (on your computer)

```
python3 vince-gpu-fw.py kernel.development.sweet ./fw
```

- It finds the slot by its marker, checks each file (size limits, and that the `.mdt` is an ELF file) and writes them in.
- By default it **overwrites the kernel file** and first saves a `kernel.development.sweet.bak` copy. Use `-o OUT` to
  write somewhere else instead.
- Run it **before** `vince_pack.py`, so the packed boot image contains the firmware.

Then pack and boot as usual:

```
python3 vince/tools/vince_pack.py kernel.development.sweet vince-xnu.img --cmdline "... adreno=11 adreno_test=1"
fastboot boot vince-xnu.img
```

`adreno=11` starts the GPU; `adreno_test=1` runs the kernel self-test at boot.

## Errors

| Message | Meaning |
|---|---|
| `slot marker not found` | the kernel was built without patch 0982, or the file is compressed or wrapped; use the raw `kernel.development.sweet` |
| `slot marker found twice, refusing` | the file is not a clean build output; start again from the artifact |
| `missing a530_pm4.fw in ...` | a file is not in the folder you gave; check its name |
| `... bytes, allowed 5..N` | wrong file (empty, or far larger than the real one) |
| `a506_zap.mdt is not an ELF file` | wrong file or damaged copy |

## Rules

- **Never commit** the firmware files, the filled kernel, the boot image made from it, or a log or photo that shows
  their contents. The filled kernel and anything packed from it contain Qualcomm's code.
- Use files from a phone you own. Do not download firmware from unofficial mirrors, and do not ask others to send it.
- Actions artifacts are safe to share: they carry the empty slot.
- Same rule for Apple: no IPSW contents, no extracted Apple binaries, no serial numbers or device identifiers.

This is practical guidance, not legal advice. Licences differ by country and vendor; if in doubt, don't publish the
files.
