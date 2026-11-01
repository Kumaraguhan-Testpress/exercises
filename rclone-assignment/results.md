# Experimental Observations & Results

## 1. Comparison: `copy` vs `move` vs `sync`
- **`rclone copy`**: Adds new files and overwrites modified files at the destination. Files that exist *only* at the destination are never deleted. Source files remain intact.
- **`rclone move`**: Copies files from source to destination and immediately deletes each source file once its transfer is verified. Extra files at the destination are left untouched.
- **`rclone sync`**: Makes the destination an exact clone of the source. It copies new/updated files and **permanently deletes** any file in the destination that is absent from the source.

## 2. Configuration-Free Execution Analysis
We evaluated three stateless configuration approaches with `--config /dev/null`:
1. **Command-Line Flags (`--s3-access-key-id`, `--s3-secret-access-key`)**: Works for isolated testing, but exposes secret keys in the OS process table (`ps aux` / `/proc/<pid>/cmdline`).
2. **Backend Environment Variables (`RCLONE_S3_*` with `:s3:`)**: Keeps secrets isolated in process memory. Ideal when working with a single S3 endpoint.
3. **Named Remote Environment Variables (`RCLONE_CONFIG_<REMOTENAME>_*`)**: Allows multiple independent S3 endpoints and credentials (`PRIMARY:` and `SECONDARY:`) to be used in a single command without touching disk.

**Production Recommendation:** Inject `RCLONE_CONFIG=/dev/null` and `RCLONE_S3_*` (or `RCLONE_CONFIG_<NAME>_*`) environment variables per worker subprocess (e.g., inside Python Celery tasks). This avoids storing credentials on disk and keeps secrets invisible to other OS users.

## 3. Transfer Reliability & Interrupted 1 GB Upload Observations
During the upload of the 1 GB file (`4k_master_class.mp4`) alongside the 150 MB video and document files:
- We interrupted the transfer at ~40% using `Ctrl+C` (`SIGINT`).
- Upon re-running the exact same `rclone copy` command:
  - Previously completed files (`lecture_recording.mp4`, `syllabus.txt`, `lecture_01.pdf`, `db_backup.sql`) were immediately bypassed (`Unchanged skipping`).
  - The interrupted 1 GB file (`4k_master_class.mp4`) was re-transferred from 0% because S3 multipart uploads are atomic and remain invisible in standard bucket object listings until `CompleteMultipartUpload` is called.
  - Transient network drops (shorter than socket timeouts) are recovered mid-stream by `--low-level-retries`, which re-transmits only the failed 5 MiB multipart chunk rather than the entire 1 GB file.

## 4. Data Safety & Risks of `rclone sync`
`rclone sync` is dangerous if automated carelessly because any deletion or missing mount on the source is replicated as a deletion on the destination. For example, if an NFS mount `/mnt/videos` unmounts and appears empty, running `rclone sync /mnt/videos :s3:prod-bucket` will delete every object in production.
- **Safety Measures Demonstrated:** Always preview destructive jobs with `--dry-run`, verify integrity afterward with `rclone check`, and consider `--max-delete` or `--backup-dir` in production cron/worker jobs.
