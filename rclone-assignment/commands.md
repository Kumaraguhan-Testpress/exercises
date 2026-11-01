# Rclone Commands & Explanations

## 1. Basic Local Storage Operations
- `rclone ls storage_local_a` — Recursively lists all files and their sizes in bytes.
- `rclone lsd storage_local_a` — Lists only directories at the specified path.
- `rclone tree storage_local_a` — Displays the directory hierarchy in a visual tree format.
- `rclone copy storage_local_a storage_local_b -P` — Copies new or updated files from source to destination while preserving extra destination files. `-P` displays real-time progress.
- `rclone move storage_local_a/backups storage_local_b/archived_backups --delete-empty-src-dirs` — Transfers files to destination and deletes the original files from source upon completion.
- `rclone delete storage_local_b/archived_backups` — Deletes all files inside the destination path.
- `rclone sync storage_local_a storage_local_b -P` — Mirrors source to destination, deleting any destination files that do not exist in source.
- `rclone check storage_local_a storage_local_b` — Compares file sizes and cryptographic checksums (MD5/SHA1) between source and destination.

## 2. Configuration-Free S3 Operations (`--config /dev/null`)
- `rclone mkdir :s3:tpstreams-raw` — Creates a bucket named `tpstreams-raw` using on-the-fly `:s3:` syntax.
- `rclone copy storage_local_a :s3:tpstreams-raw -P` — Uploads local directory contents into the S3 bucket.
- `rclone copy :s3:tpstreams-raw :s3:tpstreams-backup -P -v` — Copies objects between two buckets on the same S3 server using Server-Side Copy.
- `rclone copy :s3:tpstreams-raw downloaded_from_s3 -P` — Downloads objects from S3 to a local directory.
- `rclone deletefile :s3:tpstreams-backup/docs/syllabus.txt` — Deletes a single object from the S3 bucket.
- `rclone copy PRIMARY:tpstreams-raw SECONDARY:dr-vault -P -v` — Transfers objects directly between two separate S3 endpoints configured via `RCLONE_CONFIG_PRIMARY_*` and `RCLONE_CONFIG_SECONDARY_*` environment variables.

## 3. Reliability, Throttling & Safety Commands
- `rclone copy storage_local_a :s3:tpstreams-raw --transfers 4 --checkers 8 --bwlimit 50M --retries 5 --low-level-retries 10 --stats 2s -P` — Runs an upload with 4 parallel file streams, 8 metadata checkers, a 50 MiB/s bandwidth cap, 5 high-level retries, and 10 low-level packet retries.
- `rclone sync storage_local_a :s3:tpstreams-raw --dry-run -v` — Previews all additions, updates, and deletions that `sync` would make without modifying any files.
