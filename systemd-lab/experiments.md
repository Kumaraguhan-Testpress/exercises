# Linux Process Management & systemd — Experiments Log

This document records the hands-on experiments conducted on `testpress-worker.service`, capturing the exact commands executed, expected outcomes, actual system behavior, and the underlying Linux kernel / `systemd` mechanisms responsible.

---

## Experiment 1: Inspecting a Running Process

- **Evidence:** `evidence/01-running-process.png`
- **Action:**
  Executed `python3 app.py` in Terminal 1, and ran `ps aux | grep app.py`, `pgrep -fa app.py`, and `pstree -p $(pgrep -f app.py)` in Terminal 2.
- **Expectation:**
  The process should appear in the system process table with a unique Process ID (PID), showing `/usr/bin/python3` as the interpreter and the interactive bash shell as its parent process (PPID).
- **Observation:**
  `pgrep -fa app.py` returned the exact PID and full command line. `ps aux` showed the process in state `S+` (interruptible sleep, in the foreground process group) consuming minimal CPU/RAM during its 5-second sleep loop.
- **Explanation:**
  When a command is launched from a shell, the shell executes a `fork()` system call to duplicate itself and `execve()` to replace the child process memory space with the Python interpreter. Because the script spends most of its time in `time.sleep(1)`, the kernel scheduler places the process in Interruptible Sleep (`S`), waking it only when the timer expires or a signal arrives.

---

## Experiment 2: Graceful Shutdown via `SIGTERM`

- **Evidence:** `evidence/02-graceful-shutdown.png`
- **Action:**
  Ran `kill -TERM $(pgrep -f app.py)` while `app.py` was running.
- **Expectation:**
  The Python process should intercept `SIGTERM`, execute the custom `handle_signal` callback, log its cleanup routine, and terminate with exit status `0`.
- **Observation:**
  The terminal logged `Received SIGTERM (signal 15). Starting graceful shutdown...`, paused for 1 second to simulate resource cleanup, logged `Cleanup complete. Exiting cleanly with status 0.`, and returned to the shell prompt.
- **Explanation:**
  `SIGTERM` (Signal 15) is a software termination signal sent to user-space processes. Unlike `SIGKILL`, the Linux kernel allows a process to register a custom signal handler in its process control block (`task_struct`) for `SIGTERM`. Python's `signal.signal()` hooks into the C-level `sigaction()` system call, allowing our application to flip `running = False`, finish its current iteration cleanly, flush file descriptors, and exit safely.

---

## Experiment 3: Forced Termination via `SIGKILL`

- **Evidence:** `evidence/03-forced-termination.png`
- **Action:**
  Ran `kill -KILL $(pgrep -f app.py)` (or `kill -9`) and then checked `echo $?` in the foreground terminal. - **Expectation:** The process should terminate immediately without running the Python signal handler or printing any cleanup logs. - **Observation:** The process vanished immediately. No shutdown log was printed by `app.py`. Instead, the bash shell printed `Killed` and `echo $?` returned `137`.
- **Explanation:**
  `SIGKILL` (Signal 9) cannot be caught, blocked, or ignored by user-space processes. When the kernel receives `SIGKILL` for a target PID, the kernel directly tears down the process's virtual memory pages, closes open file descriptors, and marks the task for reclamation without ever transitioning execution back to user-space code. The exit status `137` follows the POSIX convention of `128 + signal_number` (`128 + 9 = 137`).

---

## Experiment 4: Managing the Application with `systemd`

- **Evidence:** `evidence/04-systemd-service.png`
- **Action:**
  Created `/etc/systemd/system/testpress-worker.service`, reloaded the daemon with `sudo systemctl daemon-reload`, and started the service via `sudo systemctl enable --now testpress-worker.service`. Checked status with `sudo systemctl status testpress-worker.service`.
- **Expectation:**
  `systemd` should spawn `app.py` in the background under the non-root `tpworker` user, capture its standard output into `journald`, and place it inside a dedicated control group (`cgroup`).
- **Observation:**
  `systemctl status` showed `Active: active (running)`, listed the `Main PID`, displayed the cgroup path `/system.slice/testpress-worker.service`, and streamed the heartbeat logs at the bottom of the status output.
- **Explanation:**
  With `Type=simple`, `systemd` (PID 1) forks and executes `/usr/bin/python3 /opt/testpress-worker/app.py`, drops privileges to UID/GID `tpworker`, injects variables from `EnvironmentFile=/etc/testpress-worker.env`, and connects the process's `stdout` and `stderr` file descriptors directly to the `systemd-journald` socket.

---

## Experiment 5: Automatic Restart After an Unexpected Crash

- **Evidence:** `evidence/05-automatic-restart.png`
- **Action:**
  Recorded the initial `Main PID` of `testpress-worker.service`, then triggered an unhandled error via `echo "crash" | sudo tee /tmp/tp_worker_trigger` (which causes `app.py` to call `sys.exit(1)`). Checked `systemctl status` 5 seconds later.
- **Expectation:**
  Because `Restart=on-failure` and `RestartSec=3` are configured, `systemd` should detect the non-zero exit code (`1`), wait 3 seconds, and spawn a brand-new process with a new PID.
- **Observation:**
  The original PID terminated with `status=1/FAILURE`. After a 3-second hold-off (`Active: activating (auto-restart)`), `systemd` launched a new process with a new `Main PID` and returned the unit to `active (running)`. (Note: When tested with `kill -TERM`, the service exited with `status=0/SUCCESS` and was *not* restarted by `Restart=on-failure`, whereas `kill -KILL` exited with `status=9/KILL` and *was* restarted).
- **Explanation:**
  As PID 1, `systemd` receives a `SIGCHLD` signal from the kernel whenever a managed service process exits. It inspects the exit code and termination signal via `waitid()`. Under `Restart=on-failure`, any non-zero exit code, unclean signal (`SIGKILL`, `SIGSEGV`, `SIGABRT`), timeout, or watchdog failure triggers the restart state machine after waiting `RestartSec`.

---

### Troubleshooting Challenge: `/tmp` Sticky Bit & `PermissionError` Crash Loop

- **Issue Encountered:**
  During Experiment 5, triggering the crash via `echo "crash" | sudo tee /tmp/tp_worker_trigger` caused `testpress-worker.service` to enter a rapid crash loop and fail completely after 3 attempts (`Start request repeated too quickly`), rather than restarting cleanly once.
- **Root Cause Diagnosis:**
  Inspecting `journalctl -u testpress-worker.service` revealed:
  `PermissionError: [Errno 1] Operation not permitted: '/tmp/tp_worker_trigger'` at `os.remove(trigger_file)`.
  1. `testpress-worker.service` runs under the unprivileged user `tpworker`.
  2. Running `sudo tee` created `/tmp/tp_worker_trigger` owned by `root:root`.
  3. On Fedora Linux, `/tmp` has permissions `drwxrwxrwt` (`1777`, sticky bit enabled). The sticky bit prevents non-root users from unlinking files in `/tmp` that they do not own.
  4. Because `tpworker` could not delete `/tmp/tp_worker_trigger`, the unhandled `PermissionError` exited with code `1`, and the trigger file remained on disk—causing every subsequent `systemd` restart to hit the same file until `StartLimitBurst=3` was exhausted.
- **Resolution:**
  Removed the root-owned file (`sudo rm -f /tmp/tp_worker_trigger`), reset the systemd failure counter (`sudo systemctl reset-failed testpress-worker.service`), and executed triggers as the service user (`echo "crash" | sudo -u tpworker tee /tmp/tp_worker_trigger`) so `tpworker` owns and can cleanly unlink the trigger file.

---

## Experiment 6: Crash Investigation with `journalctl`

- **Evidence:** `evidence/06-crash-investigation.png`
- **Action:**
  Executed `sudo journalctl -u testpress-worker.service -n 25 --no-pager` immediately following Experiment 5.
- **Expectation:**
  The journal should show both the application-level error log emitted before the crash and `systemd`'s internal lifecycle messages documenting the exit code and restart counter.
- **Observation:**
  `journalctl` displayed the exact sequence:
  1. Application log: `[CRITICAL] Crash trigger detected! Simulating unhandled fatal error (exit code 1)...`
  2. `systemd` log: `testpress-worker.service: Main process exited, code=exited, status=1/FAILURE`
  3. `systemd` log: `testpress-worker.service: Scheduled restart job, restart counter is at 1.`
  4. `systemd` log: `Stopped Testpress Background Worker Service.` -> `Started Testpress Background Worker Service.`
- **Explanation:**
  Because `systemd-journald` indexes log entries with metadata tags (such as `_SYSTEMD_UNIT=testpress-worker.service`, `_PID`, and priority levels), `journalctl -u` correlates stdout/stderr lines from the Python process alongside lifecycle events generated by PID 1 in strict chronological order.

---

## Experiment 7: Investigating an Invalid Executable Path

- **Evidence:** `evidence/07-invalid-configuration.png`
- **Action:**
  Modified `ExecStart` in `testpress-worker.service` to `/usr/bin/python3_nonexistent /opt/testpress-worker/app.py`, ran `sudo systemctl daemon-reload`, and restarted the service.
- **Expectation:**
  The service should fail to start, and `systemd` should report an execution failure (`status=203/EXEC`).
- **Observation:**
  `systemctl status` showed `Active: failed` with `(code=exited, status=203/EXEC)` after exhausting its restart attempts. `journalctl -u testpress-worker.service` explicitly logged: `testpress-worker.service: Failed to locate executable /usr/bin/python3_nonexistent: No such file or directory`.
- **Explanation:**
  Exit code `203` (`EXIT_EXEC`) is a special `systemd`-defined exit status returned by the forked child process after `fork()` succeeds but the subsequent `execve()` system call fails (commonly caused by a missing binary, typo in `ExecStart`, missing `chmod +x` permission, or broken shebang `#!` interpreter).

---

## Experiment 8: Repeated Crashes & Restart Rate Limiting

- **Evidence:** `evidence/08-repeated-crashes.png`
- **Action:**
  Set `CRASH_ON_STARTUP=true` in `/etc/testpress-worker.env` and restarted `testpress-worker.service`. Waited 12 seconds and inspected `systemctl status` and `journalctl`.
- **Expectation:**
  The service should crash immediately upon launch, retry up to `StartLimitBurst=3` times within `StartLimitIntervalSec=60`, and then remain permanently in the `failed` state without further restarts.
- **Observation:**
  The service crashed on start, waited 3 seconds (`RestartSec=3`), and restarted until the restart counter hit 3. On the next attempt, `systemd` logged `testpress-worker.service: Start request repeated too quickly.` and `Failed with result 'exit-code'`, halting all further automatic restarts.
- **Explanation:**
  Without rate limiting, a service with a fatal startup bug (such as a bad configuration file or missing database credential) would loop infinitely, consuming CPU, flooding disk logs, and potentially destabilizing the host. `StartLimitBurst` and `StartLimitIntervalSec` act as a circuit breaker: once the burst threshold is breached within the time window, `systemd` locks the unit in `failed` until an administrator fixes the issue and runs `systemctl reset-failed`.

---

## Experiment 9: Resource Limits (`CPUQuota` and `MemoryMax`)

- **Evidence:** `evidence/09-resource-limits.png`
- **Action:**
  Configured `CPUQuota=50%` and `MemoryMax=50M` in the unit file. Verified limits via `systemctl show -p MemoryMax testpress-worker.service`. Triggered rapid memory allocation via `echo "oom" | sudo tee /tmp/tp_worker_trigger`.
- **Expectation:**
  As `app.py` allocates 10 MB chunks of physical RAM, once its Resident Set Size (RSS) reaches 50 MB, the Linux kernel cgroup OOM killer should terminate the process with `SIGKILL`, and `systemd` should record an `oom-kill` result and restart the service.
- **Observation:**
  The journal logged memory allocations up to `40 MB` / `50 MB`, at which point `systemd` logged: `testpress-worker.service: A process of this unit has been killed by the OOM killer.` and `Main process exited, code=killed, status=9/KILL` (result `oom-kill`). After 3 seconds, `systemd` automatically started a fresh instance of the worker.
- **Explanation:**
  `systemd` translates `MemoryMax=50M` and `CPUQuota=50%` directly into Linux Control Groups (cgroups v2) parameters by writing to `/sys/fs/cgroup/system.slice/testpress-worker.service/memory.max` and `cpu.max`. When all processes inside that cgroup attempt to allocate physical pages beyond 50 MiB, the kernel's cgroup memory controller invokes the Out-Of-Memory (OOM) killer scoped strictly to that cgroup, sending `SIGKILL` to the offending process while protecting the rest of the server.

- "Initially, with only MemoryMax=50M configured, the process allocated over 400 MB because the Linux kernel kept physical RAM pinned at 49.9M and paged the excess 358.4M into swap space (zram). Setting MemorySwapMax=0 alongside MemoryMax=50M disabled swap usage for the unit's cgroup (memory.swap.max = 0), causing the kernel cgroup OOM killer to immediately terminate the process with SIGKILL (result=oom-kill) the moment physical RAM reached 50 MB."

---

## Experiment 10: Reboot Persistence

- **Evidence:** `evidence/10-reboot-persistence.png`
- **Action:**
  Enabled the service with `sudo systemctl enable testpress-worker.service`, rebooted the machine (`sudo reboot`), and ran `uptime -s` and `systemctl status testpress-worker.service`.
- **Expectation:**
  The service should start automatically during boot without any manual login or intervention.
- **Observation:**
  After rebooting, `systemctl status` showed `Active: active (running)` with a startup timestamp matching the system boot time reported by `uptime -s`.
- **Explanation:**
  Running `systemctl enable` creates a symbolic link from `/etc/systemd/system/multi-user.target.wants/testpress-worker.service` pointing to `/etc/systemd/system/testpress-worker.service`. During boot, `systemd` resolves the dependency graph leading up to `default.target` (`multi-user.target`), waits until `After=network.target` is satisfied, and launches all units linked inside `multi-user.target.wants/`.
