# DLSS Version Scanner (Fish Script)

Scans local storage for `nvngx_dlss.dll` files, reads their version via `exiftool`, and compares them against a recommended baseline determined by the detected NVIDIA GPU architecture.

## What the script does

Runs in five steps:

1. **Dependency check** – verifies that `nvidia-smi`, `exiftool`, `find`, `sort`, and `tr` are available in `PATH`. Aborts with exit code 1 and a list of missing tools if any are not found.
2. **Hardware detection** – queries GPU name and driver version via `nvidia-smi`. Maps the GPU name to an architecture and a recommended minimum DLSS version:
   - RTX 50-series → Blackwell → 4.5.0
   - RTX 40-series → Ada Lovelace → 3.7.10
   - RTX 30-series → Ampere → 3.5.0
   - RTX 20-series → Turing → 2.5.1
   - Anything else → "Unknown" architecture, default baseline 3.7.0
3. **Path discovery** – builds the search scope from `$HOME` plus every top-level directory under `/mnt` and `/run/media`.
4. **Header output** – prints GPU, driver version, detected architecture, target baseline, the color legend (green/yellow/red), and the resolved search paths.
5. **Scan & evaluation** – recursively searches the discovered paths for `nvngx_dlss.dll`. For each match:
   - Extracts `ProductVersion` via `exiftool -s3 -ProductVersion`.
   - Normalizes commas to dots (`,` → `.`) for version comparison.
   - Compares the version against the baseline using `sort -V`.
   - Prints the version and file path, color-coded:
     - **Green** – version meets or exceeds the baseline.
     - **Yellow** – version is below the baseline (upgrade recommended).
     - **Red** – version string could not be read (`ERROR`).
6. **Summary** – total files found and number of upgrades recommended, or a green "all up to date" message if none are needed.

## Requirements

- Fish shell
- `nvidia-smi` (NVIDIA proprietary driver)
- `exiftool`
- Standard `find`, `sort`, `tr` (coreutils / findutils)

## Usage

```fish
chmod +x scan.fish
./scan.fish
```

No arguments. No root privileges required.

## Notes on scope

- Only searches `$HOME` and top-level directories under `/mnt` and `/run/media` — not the entire filesystem.
- Does not modify, delete, or update any files; read-only scan and report.
- Architecture detection relies on the GPU name string containing "RTX 50", "RTX 40", "RTX 30", or "RTX 20" — other GPUs (e.g. GTX-series, non-NVIDIA) fall back to "Unknown" with the 3.7.0 baseline.
- Scan duration depends on storage type, as noted by the script itself (HDDs may be slower).