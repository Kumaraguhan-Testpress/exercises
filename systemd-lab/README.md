# Linux Process Management & systemd: Engineering Guide

In production environments—such as running Django application servers (Gunicorn/Uvicorn), Celery workers, and background queue processors—processes must run reliably without human intervention. They need to start automatically when a server boots, recover gracefully when an unhandled exception or memory leak causes a crash, respect strict CPU and RAM boundaries so a single runaway worker cannot take down the entire machine, and emit structured logs for post-mortem debugging.

This guide explains how Linux manages processes under the hood, how signals control process lifecycles, and how to build, configure, and troubleshoot production-grade background services using `systemd`.

---

## 1. Core Concepts: How Linux Manages Processes

### What is a Process?
A **process** is an active instance of a running program. Every process in Linux is tracked by the kernel using an internal data structure (`task_struct`) and assigned a unique **Process ID (PID)**.

- **PID 1 (`init` / `systemd`):** When the Linux kernel finishes booting, it launches the very first user-space process with **PID 1** (on modern distributions, `systemd`). PID 1 is the ancestor of every other process on the machine.
- **Parent and Child Processes (`PPID`):** New processes are created when an existing parent process calls the `fork()` system call (duplicating itself) followed by `execve()` (replacing its memory image with a new program). Every process records the PID of its creator as its **Parent PID (`PPID`)**.
- **Orphan Processes & Reaping:** If a parent process terminates while its child processes are still running, those children become **orphan processes** and are immediately re-parented to **PID 1 (`systemd`)**, which monitors and cleans them up when they exit.

### Process States
When inspecting processes with tools like `ps`, `top`, or `htop`, you will see single-letter state codes:

| State Code | Name | Meaning |
| :--- | :--- | :--- |
| **`R`** | Running / Runnable | Currently executing on a CPU core, or sitting in the run queue waiting for CPU time. |
| **`S`** | Interruptible Sleep | Waiting for an event to complete (e.g., `time.sleep()`, network I/O, or user input). Can be woken by signals. |
| **`D`** | Uninterruptible Sleep | Waiting directly on hardware/disk I/O inside kernel space. **Cannot** be interrupted by signals (even `SIGKILL`) until the I/O call returns. |
| **`T`** | Stopped | Execution is suspended (e.g., stopped via `SIGSTOP` or pressing `Ctrl+Z` in a terminal). |
| **`Z`** | Zombie (Defunct) | The process has finished executing and released its memory, but its entry remains in the process table because its parent has not yet called `wait()` to read its exit status. |

### Essential Process Management Commands

#### Inspecting Processes (`ps`, `pgrep`, `pidof`, `pstree`, `top`, `htop`)
```bash
# View detailed snapshot of all running processes
ps aux

# View specific columns (PID, Parent PID, State, Niceness, Command)
ps -eo pid,ppid,stat,ni,comm,args

# Find a process ID by matching against its full command line
pgrep -fa app.py

# Find the PID of a named binary
pidof python3

# Visualize the parent-child process hierarchy tree with PIDs
pstree -p

# Interactive real-time process and resource monitors
top
htop
```

#### Foreground, Background, and Shell Job Control (`jobs`, `bg`, `fg`, `nohup`)
When you launch a program in an interactive shell, it runs in the **foreground** and is attached to your terminal session (`pts/0`):
- **`Ctrl+Z`**: Sends `SIGTSTP`, suspending the foreground process.
- **`jobs -l`**: Lists processes managed by the current shell session.
- **`bg %1`**: Resumes suspended job `#1` in the background.
- **`fg %1`**: Brings job `#1` back to the foreground.
- **`nohup python3 app.py &`**: Runs a command immune to `SIGHUP` (hangup signal) when your SSH session disconnects, redirecting output to `nohup.out`.
  - *Why `nohup` is insufficient for production:* `nohup` is a one-shot wrapper. If the process crashes due to an unhandled exception, gets killed by the Out-Of-Memory (OOM) killer, or if the server reboots, a `nohup` process stays dead forever.

#### Process Priority and Scheduling (`nice` and `renice`)
The Linux Completely Fair Scheduler (CFS) uses a **niceness** value ranging from **`-20`** (highest priority, least "nice" to others) to **`+19`** (lowest priority, most "nice" to others). The default is `0`.
```bash
# Start a process with lower CPU scheduling priority (niceness +10)
nice -n 10 python3 app.py

# Change the niceness of an already-running process
renice -n 15 -p <PID>
```
*(Note: Any user can increase niceness to lower their own process's priority, but only `root` can set negative niceness values).*

---

## 2. Linux Signals: `SIGTERM` vs. `SIGKILL`

**Signals** are asynchronous software interrupts delivered to a process by the kernel (either triggered by another process via `kill`/`pkill`, a keyboard shortcut, or the kernel itself).

| Signal | Number | Trigger | Can be Caught/Handled? | Behavior & Production Impact |
| :--- | :--- | :--- | :--- | :--- |
| **`SIGINT`** | `2` | `Ctrl+C` in terminal | **Yes** | Requests interactive interrupt. Python raises `KeyboardInterrupt` by default unless a custom handler is registered. |
| **`SIGTERM`** | `15` | `kill <PID>` (default) or `systemctl stop` | **Yes** | **Polite termination request.** Allows the application to stop accepting new work, finish in-flight database transactions or Celery tasks, close file descriptors, and exit cleanly. |
| **`SIGKILL`** | `9` | `kill -9 <PID>` or Kernel OOM Killer | **No** | **Immediate kernel execution termination.** Bypass user-space code completely. The kernel forcibly reclaims memory and closes descriptors. Can leave corrupted files, half-written transactions, or orphaned lock files. |
| **`SIGHUP`** | `1` | Terminal disconnect / `kill -HUP` | **Yes** | Traditionally notifies a process its controlling terminal closed; daemons (like Nginx or Gunicorn) often use `SIGHUP` to reload configuration without dropping connections. |

---

## 3. Building & Deploying the Background Service

### Architecture Overview
We will deploy a Python background service (`app.py`) managed by a systemd service unit (`testpress-worker.service`).

- **Application Path:** `/opt/testpress-worker/app.py`
- **Configuration File:** `/etc/testpress-worker.env`
- **Service Unit File:** `/etc/systemd/system/testpress-worker.service`
- **Dedicated User:** `tpworker` (non-root system account)

### Step 1: Write the Python Service (`app.py`)
Our application logs a periodic heartbeat, reads configuration from environment variables, registers signal handlers for `SIGTERM` and `SIGINT` to shut down gracefully, and listens for external test triggers (`crash` and `oom`) so we can deterministically test failure recovery and resource limits.

```python
#!/usr/bin/env python3
import os
import sys
import time
import signal
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [PID %(process)d] [%(levelname)s] %(message)s",
    stream=sys.stdout,
)

running = True

def handle_signal(signum, frame):
    global running
    sig_name = signal.Signals(signum).name
    logging.info(f"Received {sig_name} (signal {signum}). Starting graceful shutdown...")
    time.sleep(1)
    logging.info("Cleanup complete. Exiting cleanly with status 0.")
    running = False

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

def main():
    app_name = os.getenv("APP_NAME", "TestpressWorker")
    interval = int(os.getenv("HEARTBEAT_INTERVAL", "5"))
    trigger_file = os.getenv("TRIGGER_FILE", "/tmp/tp_worker_trigger")

    logging.info(f"Starting {app_name} (Heartbeat interval: {interval}s, Trigger file: {trigger_file})")

    if os.getenv("CRASH_ON_STARTUP", "false").lower() == "true":
        logging.error("CRASH_ON_STARTUP is enabled! Simulating fatal boot error...")
        sys.exit(1)

    iteration = 0
    memory_hog = []

    while running:
        iteration += 1
        logging.info(f"[{app_name}] Heartbeat #{iteration} - Service is healthy.")

        if os.path.exists(trigger_file):
            try:
                with open(trigger_file, "r") as f:
                    cmd = f.read().strip()
            except Exception as e:
                logging.error(f"Failed to read trigger file: {e}")
                cmd = ""

            if cmd == "crash":
                os.remove(trigger_file)
                logging.critical("Crash trigger detected! Simulating unhandled fatal error (exit code 1)...")
                sys.exit(1)

            elif cmd == "oom":
                os.remove(trigger_file)
                logging.warning("Memory spike trigger detected! Allocating memory rapidly...")
                try:
                    while True:
                        memory_hog.append(os.urandom(10 * 1024 * 1024))
                        logging.info(f"Allocated {len(memory_hog) * 10} MB of RAM...")
                        time.sleep(0.2)
                except MemoryError:
                    logging.critical("Python MemoryError raised!")
                    sys.exit(1)

        for _ in range(interval):
            if not running:
                break
            time.sleep(1)

if __name__ == "__main__":
    main()
```

### Step 2: Provision the User, Directory, and Environment File

Never run application workers as `root`. If a vulnerability exists in the application or its dependencies, running under an unprivileged system user restricts the blast radius.

```bash
# 1. Create a dedicated system user without a home directory or interactive login shell
sudo useradd --system --no-create-home --shell /usr/sbin/nologin tpworker

# 2. Deploy the script to /opt/testpress-worker
sudo mkdir -p /opt/testpress-worker
sudo cp app.py /opt/testpress-worker/app.py
sudo chown -R tpworker:tpworker /opt/testpress-worker
sudo chmod 755 /opt/testpress-worker/app.py

# 3. Create the external environment configuration file
sudo tee /etc/testpress-worker.env > /dev/null << 'EOF'
APP_NAME=TestpressCeleryWorker
HEARTBEAT_INTERVAL=5
TRIGGER_FILE=/tmp/tp_worker_trigger
CRASH_ON_STARTUP=false
EOF
```

### Step 3: Create the `systemd` Service Unit (`testpress-worker.service`)

Create `/etc/systemd/system/testpress-worker.service`:

```ini
[Unit]
Description=Testpress Background Worker Service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=tpworker
Group=tpworker
WorkingDirectory=/opt/testpress-worker
EnvironmentFile=/etc/testpress-worker.env
ExecStart=/usr/bin/python3 /opt/testpress-worker/app.py
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=testpress-worker

# Resource Management via cgroups
CPUQuota=50%
MemoryMax=50M

[Install]
WantedBy=multi-user.target
```

#### Line-by-Line Unit File Breakdown
- **`After=network.target`**: Ensures the network stack is initialized before `systemd` starts this service on boot.
- **`StartLimitIntervalSec=60` & `StartLimitBurst=3`**: Configures crash-loop rate limiting. If the service fails and restarts more than 3 times within a 60-second window, `systemd` stops attempting further restarts and marks the unit `failed`.
- **`Type=simple`**: Tells `systemd` that the process launched by `ExecStart` is the main service process and runs in the foreground.
- **`User=tpworker` / `Group=tpworker`**: Drops root privileges before executing the binary.
- **`EnvironmentFile=/etc/testpress-worker.env`**: Loads key-value environment variables into the process environment at startup without hardcoding secrets or settings into the unit file.
- **`Restart=on-failure`**: Instructs `systemd` to automatically restart the service if the process exits with a non-zero exit code, is terminated by an unhandled signal (like `SIGKILL` or `SIGSEGV`), or hits an OOM/watchdog timeout. Clean exits (`exit 0`, such as when `SIGTERM` is handled gracefully) will not trigger an unwanted restart.
- **`RestartSec=3`**: Waits 3 seconds before launching a replacement process after a failure.
- **`CPUQuota=50%` & `MemoryMax=50M`**: Enforces kernel-level resource limits using Linux Control Groups (`cgroups`). The service cannot consume more than 50% of a single CPU core's time or allocate more than 50 MiB of physical RAM.
- **`WantedBy=multi-user.target`**: When enabled via `systemctl enable`, links this service into the standard non-graphical multi-user boot target so it starts automatically on reboot.

### Step 4: Activate and Verify the Service

```bash
# Reload systemd so it parses the new unit file
sudo systemctl daemon-reload

# Enable the service for boot persistence and start it immediately
sudo systemctl enable --now testpress-worker.service

# Inspect service health and cgroup hierarchy
sudo systemctl status testpress-worker.service
```

---

## 4. Reproducing Failure Scenarios & Diagnostics

### Scenario A: Graceful Stop vs. Forced Kill (`SIGTERM` vs. `SIGKILL`)
1. **Send `SIGTERM`:**
   ```bash
   sudo kill -TERM $(systemctl show -p MainPID --value testpress-worker.service)
   ```
   *Behavior:* `app.py` catches `SIGTERM`, runs its cleanup block, and exits with status `0`. Because `Restart=on-failure` is configured and status `0` indicates intentional success, `systemd` transitions the service to `inactive (dead)`. Start it back up with `sudo systemctl start testpress-worker.service`.

2. **Send `SIGKILL`:**
   ```bash
   sudo kill -KILL $(systemctl show -p MainPID --value testpress-worker.service)
   ```
   *Behavior:* The process is immediately destroyed by the kernel (`code=killed, status=9/KILL`) without logging cleanup. `systemd` detects an unclean termination signal, waits `RestartSec=3`, and automatically spawns a new process with a fresh PID.

### Scenario B: Unhandled Application Exception (Non-Zero Exit Code)
Simulate a fatal application error (e.g., an unhandled Python exception causing `sys.exit(1)`):echo "crash" | sudo -u tpworker tee /tmp/tp_worker_trigger
```bash
echo "crash" | sudo -u tpworker tee /tmp/tp_worker_trigger
```
*Behavior:* The process exits with `status=1/FAILURE`. `systemd` logs the failure, increments the restart counter, waits 3 seconds, and restarts the worker.

### Scenario C: Exceeding Memory Limits (cgroups OOM Killer)
Trigger a rapid memory spike inside the worker:
```bash
echo "oom" | sudo -u tpworker tee /tmp/tp_worker_trigger
```
*Behavior:* As the Python process allocates 10 MB chunks, its memory usage hits the `MemoryMax=50M` ceiling enforced by `/sys/fs/cgroup/system.slice/testpress-worker.service/memory.max`. The Linux kernel invokes the cgroup Out-Of-Memory (OOM) killer, sends `SIGKILL` to the process, and `systemd` logs `A process of this unit has been killed by the OOM killer` before automatically restarting a clean instance.

### Scenario D: Crash Loop & Restart Rate Limiting
If a service fails immediately on startup (e.g., due to a corrupted config or unreachable upstream dependency):
```bash
sudo sed -i 's/CRASH_ON_STARTUP=false/CRASH_ON_STARTUP=true/' /etc/testpress-worker.env
sudo systemctl reset-failed testpress-worker.service
sudo systemctl restart testpress-worker.service
```
*Behavior:* After 3 crashes within 60 seconds (`StartLimitBurst=3`), `systemd` halts further restarts and logs `Start request repeated too quickly`. Once fixed, reset the state with:
```bash
sudo sed -i 's/CRASH_ON_STARTUP=true/CRASH_ON_STARTUP=false/' /etc/testpress-worker.env
sudo systemctl reset-failed testpress-worker.service
sudo systemctl start testpress-worker.service
```

---

## 5. Diagnostic Playbook: Investigating Failing Services

When a production service is failing or crash-looping, follow this systematic diagnostic workflow:

```bash
# 1. Check current unit state, recent exit codes (e.g., 1/FAILURE, 203/EXEC, 9/KILL), and Main PID
sudo systemctl status testpress-worker.service

# 2. Stream live logs or view recent logs for the unit in journald
sudo journalctl -u testpress-worker.service -n 50 --no-pager
sudo journalctl -u testpress-worker.service -f

# 3. Filter logs since the current boot or within a specific time window
sudo journalctl -u testpress-worker.service -b
sudo journalctl -u testpress-worker.service --since "10 minutes ago"

# 4. Inspect all effective low-level properties (limits, restart counters, exit codes)
systemctl show testpress-worker.service
systemctl show -p MainPID,NRestarts,ExecMainStatus,MemoryCurrent,MemoryMax testpress-worker.service

# 5. Validate unit file syntax and analyze system boot performance
systemd-analyze verify /etc/systemd/system/testpress-worker.service
systemd-analyze blame
```

---

## 6. Deep-Dive Q&A & Bonus Concepts

### Questions for Review
1. **What is the difference between `SIGTERM` and `SIGKILL`?**
   `SIGTERM` (15) is a catchable termination signal that gives the process an opportunity to run cleanup handlers (closing database connections, finishing current tasks, flushing buffers) before exiting. `SIGKILL` (9) cannot be caught or ignored; the kernel immediately destroys the process in kernel space without letting user-space cleanup code run.
2. **Why doesn't `nohup` provide the same reliability as `systemd`?**
   `nohup` only ignores `SIGHUP` and redirects output when a terminal closes. It does not monitor the process, cannot restart it if it crashes or gets OOM-killed, does not start it on server reboot, cannot enforce cgroup CPU/RAM limits, and lacks centralized structured logging and dependency ordering.
3. **What happens when a service crashes repeatedly?**
   `systemd` restarts the service after waiting `RestartSec` on each failure until the number of restarts exceeds `StartLimitBurst` within `StartLimitIntervalSec`. Once that rate limit is hit, `systemd` stops trying to restart the service and places the unit into the `failed` state (`Start request repeated too quickly`).
4. **What is the difference between restarting a process and restarting a service?**
   Restarting a process manually (e.g., killing a PID and launching a binary in a shell) inherits your interactive shell's environment variables, user permissions, working directory, and open file descriptors. Restarting a service via `systemctl restart` instructs PID 1 (`systemd`) to cleanly stop the entire unit cgroup (including any child processes) and spawn a fresh instance in a sanitized, deterministic environment defined strictly by the unit file (`User=`, `EnvironmentFile=`, `WorkingDirectory=`, and `cgroup` limits).
5. **What happens to child processes when a `systemd` service is stopped?**
   By default (`KillMode=control-group`), `systemd` tracks the main process and every child/grandchild process it forks inside a dedicated kernel cgroup (`/sys/fs/cgroup/system.slice/<service>`). When the service is stopped, `systemd` sends `SIGTERM` to **all** processes inside that cgroup simultaneously, waits up to `TimeoutStopSec` (default 90s), and sends `SIGKILL` to any remaining processes in the cgroup so no rogue orphan processes are left behind.
6. **How would you ensure a Celery worker finishes its current task before shutting down?**
   Celery workers listen for `SIGTERM` to initiate a "warm shutdown"—stopping consumption of new tasks from the queue while finishing currently executing tasks. In `systemd`, ensure the unit sends `SIGTERM` (the default `KillSignal=SIGTERM`) and set `TimeoutStopSec=300` (or higher than your longest task execution time) in `[Service]` so `systemd` waits long enough for the Celery worker to finish its active task before falling back to `SIGKILL`.

### Bonus Concepts: Service Types, cgroups, Watchdogs, and Timers
- **`Type=simple` vs. `Type=exec` vs. `Type=notify`:**
  - `Type=simple` considers the service `active (running)` the instant `systemd` calls `fork()`, even before the binary `execve()` call completes.
  - `Type=exec` waits until the `execve()` system call succeeds before marking the unit active (catching missing binaries immediately during `systemctl start`).
  - `Type=notify` waits until the application explicitly sends a readiness message (`READY=1`) over the `$NOTIFY_SOCKET` Unix socket (used by Gunicorn and PostgreSQL so dependent services only start after initialization is truly complete).
- **Watchdogs (`WatchdogSec=`):**
  If a process deadlocks (e.g., stuck on an infinite network call without crashing), its PID stays alive so `Restart=on-failure` won't trigger. Setting `WatchdogSec=30` with `Type=notify` requires the application to ping `sd_notify("WATCHDOG=1")` periodically; if it stops pinging for 30 seconds, `systemd` kills it with `SIGABRT` and restarts it.
- **`systemd` Timers vs. Cron:**
  A `.timer` unit pairs with a `.service` unit (`OnCalendar=` or `OnUnitActiveSec=`) to run scheduled jobs. Unlike `cron`, systemd timers capture all output in `journald`, apply cgroup resource limits, prevent overlapping runs automatically, and can run missed jobs after a power-off via `Persistent=true`.
