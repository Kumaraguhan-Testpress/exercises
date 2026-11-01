# File Transfers and Storage Automation with Rclone

A complete, hands-on engineering guide and experimental walkthrough for transferring, synchronizing, verifying, and automating large file workflows across local storage and S3-compatible object storage using **Rclone**—without relying on static configuration files.

---

## 1. Introduction: Understanding Rclone

### What is Rclone?
**Rclone** ("rsync for cloud storage") is an open-source command-line tool written in Go that manages, transfers, synchronizes, and verifies files across local disks and more than 70 cloud and object storage providers (including AWS S3, MinIO, Cloudflare R2, Backblaze B2, DigitalOcean Spaces, Google Cloud Storage, and SFTP).

### Why Use Rclone Instead of `cp`, `scp`, or Custom Scripts?
When dealing with large application assets—such as multi-gigabyte video recordings, PDFs, and database backups—manual transfers and basic CLI tools fail to scale. Rclone solves these core challenges:

1. **Smart Delta Transfers (Idempotency):** Before transferring a file, Rclone checks its size, modification timestamp, or cryptographic hash (MD5/SHA1). If the file already exists at the destination and hasn't changed, Rclone skips it automatically.
2. **Built-In Integrity Verification:** Every transfer is verified using checksums and file sizes, preventing silent file corruption over unstable networks.
3. **Fault Tolerance & Automatic Retries:** If a network connection drops mid-transfer, Rclone automatically retries individual failed HTTP chunks (`--low-level-retries`) as well as the overall transfer job (`--retries`).
4. **High-Performance Multipart & Concurrent Transfers:** Splits large files (e.g., 1 GB+ videos) into parallel multipart chunks and transfers multiple files simultaneously (`--transfers`).
5. **Bandwidth Control (`--bwlimit`):** Allows operators to cap upload/download speeds so large background transfers never saturate production server bandwidth.
6. **Stateless, Configuration-Free Execution:** Rclone can run with zero configuration files on disk (`--config /dev/null`), accepting credentials dynamically via environment variables—making it ideal for containerized workers and CI/CD pipelines.

### Crucial Places Where Rclone is Used in Production
- **Video Transcoding & Streaming Pipelines (e.g., Testpress / TPStreams):** Pulling raw multi-gigabyte master videos from upload buckets onto transcoding worker nodes, and pushing thousands of generated HLS/DASH video segments (`.ts`, `.m4s`, `.m3u8`) back to S3 origin storage.
- **Automated Database & Server Backups:** Streaming compressed nightly database dumps and application snapshots to off-site S3 buckets with automated integrity checks.
- **Zero-Downtime Storage Migrations:** Migrating terabytes of media assets between different S3 providers (e.g., AWS S3 to Cloudflare R2 or MinIO) using incremental `rclone copy` passes followed by a final `rclone sync`.
- **Multi-Region Disaster Recovery (DR):** Replicating critical buckets across two separate S3 storage clusters to maintain a warm standby backup.

---

## 2. Step-by-Step Hands-On Experiments

Anyone can reproduce all experiments from scratch by following the steps below in order.

### Step 1: Environment Setup

#### 1.1 Install Rclone
Install the Rclone CLI on your Linux machine:
```bash
curl [https://rclone.org/install.sh](https://rclone.org/install.sh) | sudo bash
rclone version

```

#### 1.2 Create Local Directories to Simulate Two Storage Locations

We create `storage_local_a` (Source) and `storage_local_b` (Destination) to simulate two separate local storage volumes:

```bash
mkdir -p storage_local_a/videos storage_local_a/docs storage_local_a/backups
mkdir -p storage_local_b

```

#### 1.3 Start Local S3-Compatible Storage (MinIO)

We use Docker Compose to spin up **two** local MinIO servers:

* `minio-primary` on port `9000` (Console on `9001`)
* `minio-secondary` on port `9002` (Console on `9003`) to test cross-server S3 transfers.

Start the containers using the included `docker-compose.yml`:

```bash
docker compose up -d
docker ps

```

---

### Step 2: Generate Sample Files & Run Basic Local Operations

#### 2.1 Create Nested Folders, Text Files, PDFs, and a 150 MB Video File

We use `/dev/urandom` to create a 150 MB binary file filled with random bytes so checksum calculations and network transfers behave like real media files:

```bash
echo "Course syllabus v1" > storage_local_a/docs/syllabus.txt
echo "%PDF-1.4 sample lecture notes" > storage_local_a/docs/lecture_01.pdf
echo "Database dump 2026-11-01" > storage_local_a/backups/db_backup.sql

# Generate a 150 MB test video file
dd if=/dev/urandom of=storage_local_a/videos/lecture_recording.mp4 bs=1M count=150 status=progress

```

#### 2.2 Inspect Files and Directories (`ls`, `lsd`, `tree`)

* **Why:** Inspect remote or local directory contents before running transfer operations.

```bash
# List all files recursively with their sizes in bytes
rclone ls storage_local_a

# List only directories at the top level
rclone lsd storage_local_a

# Display the full nested folder hierarchy as a visual tree
rclone tree storage_local_a

```

#### 2.3 Copy Files Between Locations (`rclone copy`)

* **Why:** `copy` transfers new or modified files from Source to Destination. It **never** deletes extra files that already exist at the Destination. `-P` shows live transfer progress.

```bash
rclone copy storage_local_a storage_local_b -P

```

> **Experiment — Run `rclone copy` a second time:**
> Run `rclone copy storage_local_a storage_local_b -P -v` again immediately. Notice that `0 B` are transferred. Rclone checks the file sizes and modification times, sees that all 4 files already match at the destination, and skips them.

#### 2.4 Verify File Integrity (`rclone check`)

* **Why:** Compares file sizes and cryptographic hashes (MD5/SHA1) between two locations to prove every file at the destination is 100% identical to the source.

```bash
rclone check storage_local_a storage_local_b

```

*(Expected Output: `0 differences found` / `4 matching files`)*

#### 2.5 Move and Delete Files (`rclone move` & `rclone delete`)

* **Why:** `move` copies files to the destination and immediately deletes them from the source once verified. `delete` removes files inside the target path.

```bash
# Move backups from A into an archived_backups folder in B
rclone move storage_local_a/backups storage_local_b/archived_backups --delete-empty-src-dirs -P

# Verify the file is gone from source A
rclone ls storage_local_a

# Delete the archived backup files from destination B
rclone delete storage_local_b/archived_backups -v

# Re-create the backup file in A for the upcoming experiments
mkdir -p storage_local_a/backups
echo "Database dump 2026-11-01" > storage_local_a/backups/db_backup.sql

```

#### 2.6 Synchronize Two Directories (`rclone sync`)

* **Why:** `sync` makes the Destination an **exact mirror** of the Source. It copies new/updated files **AND deletes** any file in the Destination that does not exist in the Source.

```bash
# Create an extra file ONLY in Destination B
echo "Temporary scratch file" > storage_local_b/extra_file.txt

# Run sync from A to B
rclone sync storage_local_a storage_local_b -P -v

```

*(Observation: Rclone copies `db_backup.sql` to `storage_local_b` and permanently deletes `extra_file.txt` from `storage_local_b` because it does not exist in `storage_local_a`.)*

#### Summary: Differences Between `copy`, `move`, and `sync`

| Operation | New/Modified Source Files | Unchanged Files at Destination | Extra Files Present ONLY at Destination | Source Files After Operation |
| --- | --- | --- | --- | --- |
| **`rclone copy`** | Copied / Overwritten | Skipped | **Kept untouched** | Kept untouched |
| **`rclone move`** | Copied / Overwritten | Skipped (deleted from source) | **Kept untouched** | **Deleted** after verification |
| **`rclone sync`** | Copied / Overwritten | Skipped | **DELETED permanently** | Kept untouched |

---

### Step 3 & Step 4: S3-Compatible Storage & Configuration-Free Execution

By default, `rclone config` writes credentials to `~/.config/rclone/rclone.conf`. In production servers, background workers, and containers, maintaining static config files on disk is a security risk.

Instead, we disable the config file completely using `--config /dev/null` (or `export RCLONE_CONFIG=/dev/null`) and use Rclone's **on-the-fly remote syntax** (`:s3:bucket-name`).

#### Approach A: Passing Configuration via Command-Line Flags

* **How it works:** Connection settings are passed directly as CLI flags.
* **Security Note:** Useful for quick ad-hoc testing, but **not recommended for production** because other users on the same Linux host can see CLI flags by running `ps aux`.

```bash
rclone mkdir :s3:tpstreams-flag-test \
  --config /dev/null \
  --s3-provider Minio \
  --s3-endpoint http://localhost:9000 \
  --s3-access-key-id admin \
  --s3-secret-access-key admin123

```

#### Approach B: Passing Configuration via Environment Variables (Recommended for Production)

* **How it works:** Rclone automatically reads `RCLONE_S3_*` environment variables when using `:s3:`. Credentials stay in process memory and never appear in `ps aux` or on disk.

```bash
# 1. Disable config file and export S3 credentials into environment memory
export RCLONE_CONFIG=/dev/null
export RCLONE_S3_PROVIDER=Minio
export RCLONE_S3_ENDPOINT=http://localhost:9000
export RCLONE_S3_ACCESS_KEY_ID=admin
export RCLONE_S3_SECRET_ACCESS_KEY=admin123
export RCLONE_S3_ENV_AUTH=false

# 2. Create two buckets on MinIO
rclone mkdir :s3:tpstreams-raw
rclone mkdir :s3:tpstreams-backup

# 3. Upload local files to the S3 bucket
rclone copy storage_local_a :s3:tpstreams-raw -P

# 4. List all buckets, then list objects inside tpstreams-raw
rclone lsd :s3:
rclone ls :s3:tpstreams-raw

# 5. Copy files between two buckets on the same S3 server (Server-Side Copy!)
rclone copy :s3:tpstreams-raw :s3:tpstreams-backup -P -v

# 6. Download files from the S3 bucket to a new local directory
mkdir -p downloaded_from_s3
rclone copy :s3:tpstreams-raw downloaded_from_s3 -P

# 7. Delete a single object from the backup bucket
rclone deletefile :s3:tpstreams-backup/docs/syllabus.txt -v

```

#### Approach C: Using Different Credentials & Endpoints Simultaneously

When transferring files directly between **two separate S3 servers** (`minio-primary` on port `9000` and `minio-secondary` on port `9002`), define named remotes dynamically via `RCLONE_CONFIG_<NAME>_*` environment variables:

```bash
export RCLONE_CONFIG=/dev/null

# Define PRIMARY S3 server (Port 9000)
export RCLONE_CONFIG_PRIMARY_TYPE=s3
export RCLONE_CONFIG_PRIMARY_PROVIDER=Minio
export RCLONE_CONFIG_PRIMARY_ENDPOINT=http://localhost:9000
export RCLONE_CONFIG_PRIMARY_ACCESS_KEY_ID=admin
export RCLONE_CONFIG_PRIMARY_SECRET_ACCESS_KEY=admin123

# Define SECONDARY S3 server (Port 9002)
export RCLONE_CONFIG_SECONDARY_TYPE=s3
export RCLONE_CONFIG_SECONDARY_PROVIDER=Minio
export RCLONE_CONFIG_SECONDARY_ENDPOINT=http://localhost:9002
export RCLONE_CONFIG_SECONDARY_ACCESS_KEY_ID=admin2
export RCLONE_CONFIG_SECONDARY_SECRET_ACCESS_KEY=admin123456

# Create a bucket on SECONDARY and transfer directly from PRIMARY -> SECONDARY
rclone mkdir SECONDARY:dr-vault
rclone copy PRIMARY:tpstreams-raw SECONDARY:dr-vault -P -v
rclone ls SECONDARY:dr-vault

```

---

### Step 5: Transfer Reliability & Interrupted Upload Experiment

#### 5.1 Generate a 1 GB File

```bash
dd if=/dev/urandom of=storage_local_a/videos/4k_master_class.mp4 bs=1M count=1024 status=progress

```

#### 5.2 Simulate an Interrupted Upload (`Ctrl+C`)

We cap the transfer speed to `25M` (`--bwlimit 25M`) so the 1 GB upload takes ~40 seconds, giving you time to interrupt it midway:

```bash
# Start the upload and press Ctrl+C when progress reaches ~35-45%
rclone copy storage_local_a :s3:tpstreams-raw --bwlimit 25M -P -v

```

*(Press **`Ctrl+C`** halfway through the 1 GB transfer to simulate a process crash or network disconnection.)*

#### 5.3 Restart the Operation with Reliability & Concurrency Flags

Now re-run the transfer with verbose logging (`-vv`) and production reliability flags:

* `--transfers 4`: Transfers up to 4 files concurrently.
* `--checkers 8`: Runs 8 parallel metadata/hash comparison threads.
* `--bwlimit 50M`: Caps transfer bandwidth at 50 MiB/s.
* `--retries 5`: Retries the whole transfer operation up to 5 times if errors occur.
* `--low-level-retries 10`: Retries individual broken HTTP/TCP chunks up to 10 times before failing a file.
* `--stats 2s`: Prints live transfer statistics every 2 seconds.

```bash
rclone copy storage_local_a :s3:tpstreams-raw \
  --transfers 4 \
  --checkers 8 \
  --bwlimit 50M \
  --retries 5 \
  --low-level-retries 10 \
  --stats 2s \
  -P -vv

```

> **What We Observed on Restart:**
> 1. **Completed files are skipped:** `syllabus.txt`, `lecture_01.pdf`, `db_backup.sql`, and `lecture_recording.mp4` (150 MB) log `Unchanged skipping` and are not transferred again.
> 2. **Interrupted 1 GB file restarts cleanly:** Because S3 multipart uploads are atomic (parts remain invisible until the final `CompleteMultipartUpload` API call succeeds), the interrupted 1 GB file (`4k_master_class.mp4`) was not committed to the bucket. Rclone automatically initiates a fresh multipart upload for `4k_master_class.mp4` and completes the transfer.
> 
> 

---

### Step 6: Synchronization & Data Safety Experiment

#### 6.1 Create Diverging Files Between Source and Destination

```bash
# 1. Upload an extra "rogue" file directly to the destination S3 bucket
echo "Accidental file uploaded directly to S3" > rogue_file.txt
rclone copy rogue_file.txt :s3:tpstreams-raw/docs/
rm rogue_file.txt

# 2. Update syllabus.txt locally on the source
echo "Course syllabus v2 - Updated Content" > storage_local_a/docs/syllabus.txt

```

#### 6.2 Preview Destructive Changes with `--dry-run`

* **Why:** Running `rclone sync` blindly can delete critical production data if a source directory is accidentally empty or unmounted. Always run `--dry-run` first to inspect exactly which files will be overwritten or deleted:

```bash
rclone sync storage_local_a :s3:tpstreams-raw --dry-run -v

```

*(Observation: Rclone outputs `Skipped copy as --dry-run is set` for `docs/syllabus.txt` and `Skipped delete as --dry-run is set` for `docs/rogue_file.txt`.)*

#### 6.3 Execute Sync and Verify Integrity with `rclone check`

```bash
# Run the actual synchronization
rclone sync storage_local_a :s3:tpstreams-raw -P -v

# Verify that every file size and MD5 checksum matches between local and S3
rclone check storage_local_a :s3:tpstreams-raw

```

---

### Step 7: Automated Transfers with `transfer.sh`

We built `transfer.sh` to wrap configuration-free execution, progress reporting, error logging, and exit-code handling into a single reusable script.

```bash
chmod +x transfer.sh

# 1. Automated Copy (Local -> S3)
./transfer.sh copy ./storage_local_a :s3:tpstreams-raw

# 2. Automated Sync Dry-Run (Local -> S3)
./transfer.sh sync ./storage_local_a :s3:tpstreams-raw --dry-run

# 3. Automated Copy (Local -> Local)
./transfer.sh copy ./storage_local_a ./storage_local_b

# 4. Inspect the operational log file
cat transfer.log

```

---

## 3. Repository Deliverables Overview

| File | Purpose |
| --- | --- |
| **`README.md`** | Complete architectural guide, concept explanations, and step-by-step experimental tutorial. |
| **`docker-compose.yml`** | Spins up `minio-primary` (`:9000`) and `minio-secondary` (`:9002`) for local S3 testing. |
| **`transfer.sh`** | Reusable, stateless Bash automation script supporting `copy` and `sync` with logging and exit codes. |
| **`commands.md`** | Quick-reference cheatsheet of all Rclone CLI commands and flags used. |
| **`results.md`** | Formal summary of experimental findings (`copy` vs `move` vs `sync`, interrupted uploads, security analysis). |


## Answers to Demonstration Questions (Study Guide)

1. **What happens when `rclone copy` is executed twice with the same source and destination?**
   * During the second run, rclone inspects the metadata (file size, modification time, or MD5/ETag checksum) of the source and destination files. Because they match, **zero bytes of file payload are transferred**—all unmodified files are skipped.

2. **What happens if a file exists at the destination but not at the source when `rclone sync` runs?**
   * `rclone sync` **permanently deletes** that file from the destination so that the destination becomes an exact mirror of the source. (By default, deletions happen after transfers complete (`--delete-after`) so that if transfers fail midway, destination files aren't deleted prematurely).

3. **How does rclone determine whether a file needs to be transferred?**
   * By default, rclone compares **file size** and **modification time (`mtime`)** (stored as custom metadata on S3 objects when uploaded by rclone).
   * If `--checksum` (`-c`) is passed, rclone compares the **cryptographic hash (MD5 on S3)** and **file size**, ignoring modification times.
   * For multipart S3 objects (where the S3 `ETag` is `MD5-of-MD5s-partcount` rather than a raw MD5), rclone reads the `X-Amz-Meta-Md5chksum` header it attaches during upload or falls back to size + `mtime`.

4. **Can rclone transfer data directly between two S3 providers without downloading it to the local machine?**
   * **Between two buckets on the SAME S3 endpoint/provider:** Yes! Rclone uses the S3 `CopyObject` / `UploadPartCopy` API (`Server-Side Copy`), meaning zero file bytes pass through your local machine.
   * **Between two DIFFERENT S3 providers (e.g., MinIO to AWS S3, or Backblaze B2 to Cloudflare R2):** No—because the two separate clouds cannot talk directly to each other's internal storage backends. However, rclone **streams** the chunks in memory (pipelining the download stream from Provider A directly into the upload stream of Provider B) without writing temporary files to your local disk.

5. **What happens when a network connection is interrupted halfway through a 1 GB upload?**
   * Brief drops (a few seconds): Rclone's `--low-level-retries` will automatically re-send the single failed 5 MiB multipart chunk without restarting the whole 1 GB file, and the upload succeeds seamlessly.
   * Total process termination (`Ctrl+C` or machine crash): Because S3 multipart uploads are atomic and only appear in the bucket once `CompleteMultipartUpload` is called, the half-uploaded object is not listed in the bucket. When you restart `rclone copy`, rclone starts a new multipart upload for that 1 GB file while skipping all other files that already finished.

6. **How would you securely execute rclone from a Celery worker without maintaining an `rclone.conf` file?**
   * Inside the Python Celery task, pass credentials via a scoped dictionary to `subprocess.run(..., env=custom_env)` with `RCLONE_CONFIG="/dev/null"`:
   ```python
   import os
   import subprocess

   def transfer_video_task(local_path: str, bucket_path: str, s3_creds: dict):
       env = {
           "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
           "RCLONE_CONFIG": "/dev/null",
           "RCLONE_S3_PROVIDER": s3_creds["provider"],
           "RCLONE_S3_ENDPOINT": s3_creds["endpoint"],
           "RCLONE_S3_ACCESS_KEY_ID": s3_creds["access_key"],
           "RCLONE_S3_SECRET_ACCESS_KEY": s3_creds["secret_key"],
       }
       result = subprocess.run(
           ["rclone", "copy", local_path, f":s3:{bucket_path}", "--stats-one-line"],
           env=env,
           capture_output=True,
           text=True,
           check=True,
       )
       return result.stdout

```
