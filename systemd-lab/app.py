#!/usr/bin/env python3
import os
import sys
import time
import signal
import logging

# Force unbuffered stdout/stderr so logs appear immediately in journald and terminal
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
    # Simulate cleaning up database connections or finishing an in-flight Celery task
    time.sleep(1)
    logging.info("Cleanup complete. Exiting cleanly with status 0.")
    running = False

# Register signal handlers for graceful termination
signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

def main():
    app_name = os.getenv("APP_NAME", "TestpressWorker")
    interval = int(os.getenv("HEARTBEAT_INTERVAL", "5"))
    trigger_file = os.getenv("TRIGGER_FILE", "/tmp/tp_worker_trigger")

    logging.info(f"Starting {app_name} (Heartbeat interval: {interval}s, Trigger file: {trigger_file})")

    # Check if we are configured to crash immediately on startup (for Experiment 8: Restart Rate Limiting)
    if os.getenv("CRASH_ON_STARTUP", "false").lower() == "true":
        logging.error("CRASH_ON_STARTUP is enabled! Simulating fatal boot error...")
        sys.exit(1)

    iteration = 0
    memory_hog = []

    while running:
        iteration += 1
        logging.info(f"[{app_name}] Heartbeat #{iteration} - Service is healthy.")

        # Check external trigger file to simulate runtime conditions without editing code
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
                        # Allocate ~10MB chunks of random bytes so Linux physically commits the RAM pages
                        memory_hog.append(os.urandom(10 * 1024 * 1024))
                        logging.info(f"Allocated {len(memory_hog) * 10} MB of RAM...")
                        time.sleep(0.2)
                except MemoryError:
                    logging.critical("Python MemoryError raised!")
                    sys.exit(1)

        # Sleep in 1-second increments so the process responds quickly to signals
        for _ in range(interval):
            if not running:
                break
            time.sleep(1)

if __name__ == "__main__":
    main()
