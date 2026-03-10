# ProCopy: The Bulletproof Linux Transfer Protocol

![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat-square&logo=gnu-bash)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)
![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux)

**ProCopy** is an enterprise-grade, hardware-aware data transfer and verification script for Linux. Wrapped in a clean `zenity` GUI, it combines the sheer speed of `rsync` with the cryptographic certainty of `md5sum`. 

Standard file copy operations suffer from silent data corruption, hardware bottlenecks, and UI freezes during massive transfers. ProCopy was engineered from the ground up to solve these issues using advanced POSIX pipeline mechanics, ensuring mathematically verified data integrity without sacrificing speed.

## 📸 Screenshots

<img width="454" height="404" alt="image" src="https://github.com/user-attachments/assets/34d38aed-f565-45dd-a3bc-9cfc363a909a" />

<img width="553" height="280" alt="image" src="https://github.com/user-attachments/assets/29cff184-263f-4f90-9c3e-37e91b83a5d1" />



## 🚀 Key Features

* **Deterministic RAM Caching (The "Live Tether"):** ProCopy prevents mechanical hard drive (HDD) thrashing by physically chaining `rsync` and `md5sum` together using a Named Pipe (`mkfifo`). As `rsync` pulls data into the OS RAM cache, the pipe instantly wakes up the hasher to read that exact same data block from memory. This guarantees a near 100% cache hit rate.
* **Hardware-Aware Parallelism:** During Phase 2 verification, the script queries your destination drive's architecture (`lsblk -o ROTATIONAL`). It deploys maximum multi-threading (`xargs -P`) for SSDs/NVMe drives, and strictly locks to a single thread for mechanical HDDs to prevent the read-needle from thrashing.
* **Bulletproof UTF-8 Handling:** Uses `LC_COLLATE=C` and the `rsync -8` flag to enforce strict machine-level sorting while flawlessly preserving complex multi-byte filenames (Chinese, Japanese, Cyrillic, spaces, and `%` signs).
* **Recursive Process Assassin (The "Cyanide Pill"):** ProCopy subshells are armed with custom `trap` commands that recursively hunt down and terminate all child and grandchild processes. If you hit "Cancel" mid-transfer, zero orphaned zombie processes are left in your RAM.
* **Cumulative Progress Tracking:** Calculates the exact byte-delta of the payload prior to transfer, feeding a smooth Zenity progress bar even when resuming partially completed backups.

## 🧠 How It Works Under the Hood

ProCopy executes in two distinct phases:

**Phase 1: The Tethered Transfer**
The script generates a Named Pipe. `rsync` acts as the primary mover, copying the payload and simultaneously writing the filenames down the pipe. `md5sum` acts as the reader, waking up only when the pipe feeds it a name, hashing the file directly from the active RAM cache, and generating an `.md5` manifest on the fly. Linux pipe backpressure natively throttles the processes to handle hardware bottlenecks.

**Phase 2: Cryptographic Verification**
Once the transfer finishes, the script reads the generated `.md5` manifest and verifies the data mathematically against the destination drive. Any corrupted bits, flipped `0`s, or bad cables will be caught and written to a timestamped `.log` file.

## ⚠️ Known Limitations

* **Desktop Environment Required:** ProCopy relies on `zenity` for its staging area and progress bars. It will fail if executed on a headless server without X11/Wayland forwarding.
* **Symbolic Links:** To prevent double-processing loops, the hashing engine explicitly ignores symbolic links (`[ ! -L ]`). `rsync` will copy them, but Phase 2 will not cryptographically verify them.
* **Empty Directories:** The `md5sum` engine calculates the hash of file *contents*. Empty folders are copied by `rsync` but bypassed by the verification phase.
* **Integrity, Not Security:** This script uses `md5sum` to minimize CPU overhead and maximize transfer speeds. It is designed to detect random hardware bit-rot and cable faults, not to defend against malicious cryptographic collision attacks. 
* **Metadata Verification:** Phase 2 guarantees the file contents are identical. It does not verify if Linux file permissions or ownership (UID/GID) were perfectly mapped, though `rsync -a` handles this implicitly.

## 🛠 Dependencies

ProCopy relies on standard, ultra-stable Linux core utilities.
* `bash`
* `rsync`
* `zenity`
* `coreutils` (`md5sum`, `sort`, `awk`, `df`, `lsblk`, `mkfifo`, `xargs`)

## 💻 Installation & Usage

1. Clone the repository:
   git clone [https://github.com/zer02root/procopy.git](https://github.com/zer02root/procopy.git)
   cd procopy

2. Make the script executable:
   chmod +x procopy.sh
   
3. Run it:
   ./procopy.sh

## 🤝 Contributing

Pull requests are welcome! If you find a bug or have a feature request (like adding sha256sum support via a CLI flag), please open an issue first to discuss what you would like to change.

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.
