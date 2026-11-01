# Automated Server Provisioning with Cloud-Init & Multipass

A hands-on guide and reproducible reference implementation for zero-touch Linux server provisioning using **cloud-init** and **Multipass** on Ubuntu 24.04 LTS.

---

## Table of Contents

1. [What is Cloud-Init & Why Do We Need It?](#1-what-is-cloud-init--why-do-we-need-it)
2. [Where is Cloud-Init Used in the Real World?](#2-where-is-cloud-init-used-in-the-real-world)
3. [Architecture Overview: How This Setup Works](#3-architecture-overview-how-this-setup-works)
4. [Prerequisites](#4-prerequisites)
5. [Step-by-Step Implementation Guide](#5-step-by-step-implementation-guide)
   - [Step 1: Create the `cloud-init.yaml` Configuration](#step-1-create-the-cloud-inityaml-configuration)
   - [Step 2: Deep-Dive Explanation of Every Configuration Block](#step-2-deep-dive-explanation-of-every-configuration-block)
   - [Step 3: Provision the Ubuntu 24.04 VM with Multipass](#step-3-provision-the-ubuntu-2404-vm-with-multipass)
6. [Verification Commands & Outputs (Zero-SSH)](#6-verification-commands--outputs-zero-ssh)
7. [Core Concepts & Bonus Challenges Explained](#7-core-concepts--bonus-challenges-explained)
   - [Cloud-Init Execution Stages (Once vs. Every Boot)](#1-cloud-init-execution-stages-once-vs-every-boot)
   - [How Cloud-Init Detects a First Boot](#2-how-cloud-init-detects-a-first-boot)
   - [How Cloud-Init Receives Configuration (`user-data` & `meta-data`)](#3-how-cloud-init-receives-configuration-user-data--meta-data)
   - [Cloud-Init vs. Dockerfile: What is the Difference?](#4-cloud-init-vs-dockerfile-what-is-the-difference)
8. [Teardown & Cleanup](#8-teardown--cleanup)

---

## 1. What is Cloud-Init & Why Do We Need It?

### The Problem with Manual Server Setup
Traditionally, when an engineer spins up a new Linux virtual machine (VM), they have to:
1. Wait for the server to boot.
2. Manually SSH into the server (`ssh root@server-ip`).
3. Run commands by hand to update packages, install Docker/Git/FFmpeg, create non-root users, set permissions, write `.env` files, and start application services.

**Why manual setup fails at scale:**
- **Error-Prone:** Humans forget steps, mistype permissions, or install slightly different package versions ("configuration drift").
- **Not Scalable:** Provisioning 1 server takes 15 minutes; provisioning 50 servers manually takes days.
- **Not Reproducible:** If a server crashes, rebuilding it from memory is slow and unreliable.

### What is Cloud-Init?
**Cloud-init** is the industry-standard multi-distribution method for cross-platform cloud instance initialization. It is pre-installed inside official Ubuntu, Debian, Fedora, RHEL, and Alpine cloud images.

During the **very first boot** of a virtual machine, `cloud-init` wakes up automatically, reads a declarative configuration file (written in YAML and starting with `#cloud-config`), and configures the entire operating system—users, SSH keys, packages, files, systemd services, and startup commands—before you ever log in.

---

## 2. Where is Cloud-Init Used in the Real World?

Cloud-init is the foundational "bootstrapping" layer across almost every modern infrastructure environment:

- **Public Cloud Providers:** AWS EC2 (*User Data*), Google Cloud Compute Engine (*Startup Scripts / cloud-config*), Microsoft Azure (*Custom Data*), Hetzner Cloud, DigitalOcean (*Droplet User Data*), and Linode.
- **Private Cloud & Virtualization:** OpenStack, Proxmox VE, VMware vSphere, and LXD.
- **Local Development & Testing:** Canonical **Multipass**, QEMU/KVM, and Libvirt.
- **Kubernetes Node Bootstrapping:** Managed Kubernetes services (EKS, GKE, AKS) and Cluster API use `cloud-init` under the hood to install `containerd`/`kubelet` and join worker nodes to a cluster automatically when autoscaling triggers.
- **Bare-Metal Provisioning:** Canonical MAAS (Metal as a Service) uses `cloud-init` to initialize physical servers in data centers.

---

## 3. Architecture Overview: How This Setup Works

```text
+-------------------------------------------------------------------------+
| Host Machine (Fedora / Linux / macOS / Windows)                         |
|                                                                         |
|  1. multipass launch 24.04 --cloud-init cloud-init.yaml                 |
|            |                                                            |
|            v  (Attaches virtual 'cidata' ISO with user-data/meta-data)  |
|  +-------------------------------------------------------------------+  |
|  | Ubuntu 24.04 LTS Virtual Machine (testpress-vm)                   |  |
|  |                                                                   |  |
|  |  2. Cloud-Init Boot Pipeline:                                     |  |
|  |     - Creates group 'docker' & non-root user 'testpress'          |  |
|  |     - Updates apt & installs docker.io, git, curl, ffmpeg         |  |
|  |     - Writes /opt/testpress/app.env (0640)                        |  |
|  |     - Writes /etc/systemd/system/testpress-app.service            |  |
|  |     - Starts Docker & enables testpress-app.service               |  |
|  |                                                                   |  |
|  |  3. Systemd Service (testpress-app.service)                       |  |
|  |     - Runs as user: testpress                                     |  |
|  |     - Auto-restarts on crash (Restart=always)                     |  |
|  |     - Auto-starts on VM boot (WantedBy=multi-user.target)         |  |
|  |     - Manages Docker Container: testpress-web (Port 8080 -> 5678) |  |
|  |       [Healthcheck: wget http://localhost:5678/ every 10s]        |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

---

## 4. Prerequisites

To reproduce this setup on your local machine, you only need:

1. **[Multipass](https://multipass.run/)**: A lightweight VM manager provided by Canonical that launches official Ubuntu cloud images locally.
   - **Linux (Snap):** `sudo snap install multipass`
   - **macOS (Homebrew):** `brew install --cask multipass`
   - **Windows:** Download the installer from [multipass.run](https://multipass.run/)
2. **`curl`**: Installed by default on most systems for testing the HTTP endpoint.

Verify Multipass is installed and running:
```bash
multipass version
```

---

## 5. Step-by-Step Implementation Guide

### Step 1: Create the `cloud-init.yaml` Configuration

Create a new directory for the project and save the following file as `cloud-init.yaml`.

> **Important:** The very first line of the file **must** be `#cloud-config` (it is a magic header, not a regular comment). It tells `cloud-init` to parse the file as declarative YAML configuration rather than a shell script.

```yaml
#cloud-config

# 1. Create the docker group early so the testpress user can be added to it
groups:
  - docker

# 2. Create the non-root user 'testpress' and grant Docker + sudo access
users:
  - default
  - name: testpress
    gecos: Testpress Application User
    shell: /bin/bash
    primary_group: testpress
    groups: [docker, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true

# 3. Update apt package index and install required packages
package_update: true
package_upgrade: false
packages:
  - docker.io
  - git
  - curl
  - ffmpeg

# 4. Write application environment file and systemd unit file
write_files:
  - path: /opt/testpress/app.env
    permissions: '0640'
    owner: root:root
    content: |
      APP_NAME=TestpressApp
      APP_ENV=production
      PORT=8080
      LOG_LEVEL=info

  - path: /etc/systemd/system/testpress-app.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Testpress Dockerized HTTP Application
      After=network-online.target docker.service
      Wants=network-online.target
      Requires=docker.service

      [Service]
      Type=simple
      User=testpress
      Group=docker
      WorkingDirectory=/opt/testpress
      EnvironmentFile=/opt/testpress/app.env
      Restart=always
      RestartSec=5
      # Remove any stale container with the same name before starting
      ExecStartPre=-/usr/bin/docker rm -f testpress-web
      # Run HTTP server returning "Hello from Testpress!" with a Docker healthcheck
      ExecStart=/usr/bin/docker run --rm --name testpress-web \
        --env-file /opt/testpress/app.env \
        -p 8080:5678 \
        --health-cmd="wget -qO- http://localhost:5678/ || exit 1" \
        --health-interval=10s \
        --health-timeout=3s \
        --health-retries=3 \
        hashicorp/http-echo:latest -text="Hello from Testpress!"
      ExecStop=/usr/bin/docker stop testpress-web

      [Install]
      WantedBy=multi-user.target

# 5. Finalize directory ownership and enable/start services
runcmd:
  - chown -R testpress:testpress /opt/testpress
  - systemctl daemon-reload
  - systemctl enable --now docker
  - docker pull hashicorp/http-echo:latest
  - systemctl enable --now testpress-app.service
```

---

### Step 2: Deep-Dive Explanation of Every Configuration Block

Why is `cloud-init.yaml` structured in this exact way?

1. **`groups` (`docker`):**
   - In `cloud-init`, the `users` and `groups` modules run during an earlier stage than package installation (`packages`).
   - Normally, the `docker` group is only created when `docker.io` is installed. By explicitly declaring `groups: [docker]` first, we ensure the `docker` group exists on the OS *before* the `testpress` user is created and added to it.

2. **`users` (`default` and `testpress`):**
   - `default`: Preserves Multipass's default `ubuntu` user so host-side commands (`multipass exec`) continue to work seamlessly.
   - `name: testpress`: Creates a dedicated non-root user (`testpress`), assigns `/bin/bash` as its shell, adds it to the `docker` group (allowing it to execute Docker commands without `sudo`), and disables password-based logins (`lock_passwd: true`) for security.

3. **`package_update` & `packages`:**
   - `package_update: true` runs the equivalent of `apt-get update` before installing packages.
   - `packages` installs `docker.io`, `git`, `curl`, and `ffmpeg`. Using the native `packages` module instead of running raw `apt install` inside `runcmd` is best practice because `cloud-init` wraps package installation with built-in network retry and lock-handling logic.

4. **`write_files` (`/opt/testpress/app.env`):**
   - Automatically creates the `/opt/testpress` directory if it does not exist and writes `/opt/testpress/app.env` with sample environment variables.
   - Sets restrictive `0640` permissions (`-rw-r-----`) so unauthorized users on the server cannot read application environment variables.
   - **Order-of-Operations Note:** Initially written with `owner: root:root` because `write_files` can execute before custom user groups are finalized; ownership is transferred to `testpress:testpress` in `runcmd`.

5. **`write_files` (`/etc/systemd/system/testpress-app.service` — Bonus 1 & Bonus 2):**
   - **Systemd Management (Bonus 1):** Rather than launching a detached background container via a one-off `docker run -d` command, we manage the container lifecycle as a first-class Linux `systemd` service (`testpress-app.service`).
   - **Runs as Non-Root:** `User=testpress` and `Group=docker` ensure the service executes under the `testpress` account.
   - **Auto-Start on Boot:** `WantedBy=multi-user.target` starts the container automatically whenever the VM boots.
   - **Auto-Restart on Crash:** `Restart=always` and `RestartSec=5` instruct `systemd` to automatically restart the container within 5 seconds if it crashes or is killed.
   - **Application & Health Check (Bonus 2):** Runs `hashicorp/http-echo:latest` mapped from host port `8080` to container port `5678`, returning `Hello from Testpress!`. The `--health-cmd="wget -qO- http://localhost:5678/ || exit 1"` flag runs an internal health check every 10 seconds so Docker tracks whether the HTTP server is genuinely responsive (`healthy` vs. `unhealthy`).

6. **`runcmd`:**
   - Executes at the end of the boot process (`Final` stage) after all packages and files are installed.
   - Sets ownership of `/opt/testpress` to `testpress:testpress`, reloads the systemd daemon to register `testpress-app.service`, starts Docker, pulls the container image, and starts `testpress-app.service`.

---

### Step 3: Provision the Ubuntu 24.04 VM with Multipass

From the directory containing `cloud-init.yaml`, run:

```bash
multipass launch 24.04 \
  --name testpress-vm \
  --cpus 2 \
  --memory 2G \
  --disk 10G \
  --cloud-init cloud-init.yaml
```

**What happens when you run this command:**
1. Multipass downloads the official Ubuntu 24.04 LTS (`noble`) cloud image (and caches it locally for future runs).
2. Multipass creates a 2-CPU, 2GB RAM, 10GB disk virtual machine named `testpress-vm`.
3. Multipass generates a virtual seed ISO containing `cloud-init.yaml` and attaches it to the VM.
4. The VM boots, and `cloud-init` provisions the entire system automatically without human intervention.

---

## 6. Verification Commands & Outputs (Zero-SSH)

Every requirement can be verified directly from the host terminal **without manually SSH-ing into the VM** using `multipass exec` and `curl`.

> **Note on User Context:** By default, `multipass exec testpress-vm -- <cmd>` runs commands as the default `ubuntu` user. Because we locked down `/opt/testpress/app.env` (`0640`) and granted Docker permissions specifically to the `testpress` user, we prefix `testpress`-specific checks with `sudo -u testpress`.

### 1. Verify Cloud-Init Completed Successfully
```bash
multipass exec testpress-vm -- cloud-init status --wait
```
**Output:**
```text
status: done
```

---

### 2. Verify Installed Packages (Docker, Git, curl, FFmpeg)
```bash
multipass exec testpress-vm -- bash -c "docker --version && git --version && curl --version | head -n 1 && ffmpeg -version | head -n 1"
```
**Output:**
```text
Docker version 28.2.2, build 28.2.2-0ubuntu1~24.04.1
git version 2.43.0
curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0 OpenSSL/3.0.13 zlib/1.3 brotli/1.1.0 zstd/1.5.5 libidn2/2.3.7 libpsl/0.21.2 (+libidn2/2.3.7) libssh/0.10.6/openssl/zlib nghttp2/1.59.0 librtmp/2.3 OpenLDAP/2.6.7
ffmpeg version 6.1.1-3ubuntu5 Copyright (c) 2000-2023 the FFmpeg developers
```

---

### 3. Verify `testpress` User, Docker Execution Rights, `/opt/testpress/app.env`, and Container Health
```bash
multipass exec testpress-vm -- sudo -u testpress bash -c "id && ls -la /opt/testpress && cat /opt/testpress/app.env && docker ps"
```
**Output:**
```text
uid=1001(testpress) gid=1001(testpress) groups=1001(testpress),27(sudo),1000(docker)
total 12
drwxr-xr-x 2 testpress testpress 4096 ... .
drwxr-xr-x 3 root      root      4096 ... ..
-rw-r----- 1 testpress testpress   66 ... app.env
APP_NAME=TestpressApp
APP_ENV=production
PORT=8080
LOG_LEVEL=info
CONTAINER ID   IMAGE                        COMMAND                  CREATED         STATUS                   PORTS                                       NAMES
9f8e7d6c5b4a   hashicorp/http-echo:latest   "/http-echo -text='H…"   2 minutes ago   Up 2 minutes (healthy)   0.0.0.0:8080->5678/tcp, :::8080->5678/tcp   testpress-web
```
*(Notice: `STATUS` shows `Up 2 minutes (healthy)`, confirming our Docker healthcheck is active and passing, and `sudo -u testpress docker ps` succeeded without root privileges.)*

---

### 4. Verify the HTTP Application Over the Network (Port 8080)
Retrieve the VM's IP address and send an HTTP request from the host machine:
```bash
VM_IP=$(multipass exec testpress-vm -- hostname -I | awk '{print $1}')
curl -i http://$VM_IP:8080
```
**Output:**
```text
HTTP/1.1 200 OK
X-App-Name: http-echo
X-App-Version: 1.0.0
Date: ...
Content-Length: 22
Content-Type: text/plain; charset=utf-8

Hello from Testpress!
```

---

### 5. Verify Automatic Crash Recovery (`Restart=always`)
Force-kill the running Docker container as `testpress`, wait 6 seconds for `systemd` (`RestartSec=5`) to bring it back up, and query the HTTP endpoint again:
```bash
VM_IP=$(multipass exec testpress-vm -- hostname -I | awk '{print $1}')
multipass exec testpress-vm -- sudo -u testpress docker kill testpress-web
sleep 6
curl http://$VM_IP:8080
```
**Output:**
```text
testpress-web
Hello from Testpress!
```

---

### 6. Verify Automatic Startup After VM Reboot
Reboot the virtual machine completely and verify that the application starts automatically on boot:
```bash
multipass restart testpress-vm
VM_IP=$(multipass exec testpress-vm -- hostname -I | awk '{print $1}')
curl http://$VM_IP:8080
```
**Output:**
```text
Hello from Testpress!
```

---

### 7. Verify Idempotency (Re-running Cloud-Init Modules)
Force `cloud-init` to re-execute its `init`, `config`, and `final` modules on the running server and verify that users, configuration files, and services are not duplicated or broken:
```bash
multipass exec testpress-vm -- sudo cloud-init init
multipass exec testpress-vm -- sudo cloud-init modules --mode=config
multipass exec testpress-vm -- sudo cloud-init modules --mode=final
multipass exec testpress-vm -- grep -c "^testpress:" /etc/passwd
multipass exec testpress-vm -- sudo -u testpress wc -l /opt/testpress/app.env
curl http://$VM_IP:8080
```
**Output:**
```text
1
4 /opt/testpress/app.env
Hello from Testpress!
```
- `grep -c "^testpress:" /etc/passwd` returns **`1`** (no duplicate user entries).
- `wc -l /opt/testpress/app.env` returns **`4`** (the 4 environment variables were cleanly overwritten rather than appended/duplicated).
- `curl http://$VM_IP:8080` continues to return **`Hello from Testpress!`**.

---

## 7. Core Concepts & Bonus Challenges Explained

### 1. Cloud-Init Execution Stages (Once vs. Every Boot)

Cloud-init integrates into the Linux boot lifecycle via `systemd` and runs across **5 sequential stages**:

| Stage | Systemd Unit / Binary | What Happens in This Stage | Execution Frequency |
| :--- | :--- | :--- | :--- |
| **1. Generator** | `cloud-init-generator` | Runs at the very start of `systemd` initialization. Checks kernel command-line flags and `/etc/cloud/cloud-init.disabled` to decide whether `cloud-init` should run at all. | **Every boot** |
| **2. Local** | `cloud-init-local.service` | Runs **before** networking is started. Scans local drives for datasources (such as Multipass's attached `cidata` ISO) and writes the OS network configuration to disk. | **Every boot** (applies network config on first boot or when `instance-id` changes) |
| **3. Network** | `cloud-init.service` | Runs **after** network interfaces come online. Queries remote metadata servers (if applicable), parses `user-data`, mounts disks, sets the hostname, and runs `groups` and `users` modules. | Modules run **Once per instance** (`per-instance`) by default |
| **4. Config** | `cloud-config.service` | Runs standalone configuration modules that do not affect core boot—including `write_files`, `package_update`, and `packages`. | Modules run **Once per instance** (`per-instance`) by default |
| **5. Final** | `cloud-final.service` | Runs at the very end of the boot process after regular system services are up. Executes `runcmd` and user scripts. | Modules run **Once per instance** (`per-instance`) by default |

**Summary of Frequency:**
- **Every Boot (`per-always` / `per-boot`):** The systemd stage checks themselves, datasource detection, `bootcmd`, and any scripts placed in `/var/lib/cloud/scripts/per-boot/`.
- **Only Once (`per-instance`):** Almost all `#cloud-config` declarations (`users`, `groups`, `packages`, `write_files`, `runcmd`, and scripts in `/var/lib/cloud/scripts/per-instance/`). They execute only on the **first boot** of a unique VM instance.

---

### 2. How Cloud-Init Detects a First Boot

How does `cloud-init` know whether a VM is booting for the very first time or simply rebooting?

1. **The Instance ID (`instance-id`):** Every datasource provides a `meta-data` payload containing a unique identifier called `instance-id` (for example, `i-0123456789abcdef0` on AWS or the VM identifier generated by Multipass).
2. **State Directory (`/var/lib/cloud/`):** During the first boot, `cloud-init` creates a directory at `/var/lib/cloud/instances/<instance-id>/` and points the symlink `/var/lib/cloud/instance` to it.
3. **Semaphore Lock Files (`/var/lib/cloud/instances/<instance-id>/sem/`):** Whenever a `per-instance` module (like `config_packages` or `config_scripts_user`) finishes running, `cloud-init` writes a timestamped lock file (semaphore) inside `/var/lib/cloud/instances/<instance-id>/sem/`.
4. **Subsequent Reboots:** When the VM reboots, `cloud-init` reads the `instance-id` from the datasource, sees that `/var/lib/cloud/instance` already points to that exact `instance-id`, and sees the semaphore files in `sem/`. It therefore skips all `per-instance` modules.
   - *(Tip: Running `sudo cloud-init clean` deletes `/var/lib/cloud/`, wiping the memory of the `instance-id` so the next reboot is treated as a brand-new first boot.)*

---

### 3. How Cloud-Init Receives Configuration (`user-data` & `meta-data`)

Cloud-init ingests two distinct types of configuration via **Datasources**:

- **`meta-data` (Machine Identity & Platform Context):** Automatically generated by the cloud provider or hypervisor. Contains the `instance-id`, `local-hostname`, network configuration, and SSH public keys injected by the platform.
- **`user-data` (Custom Provisioning Logic):** Provided by the developer/administrator (our `cloud-init.yaml`).

Cloud-init receives `user-data` and `meta-data` through one of two mechanisms depending on where the VM is running:
1. **NoCloud Virtual Drive (Used by Multipass & QEMU):** Multipass generates a small ISO-9660 virtual CD-ROM with the volume label `cidata` containing two files at its root: `user-data` and `meta-data`. When the VM boots, `cloud-init` detects the block device labeled `cidata`, mounts it locally without needing network access, and reads the configuration.
2. **IMDS — Instance Metadata Service (Used by AWS, GCP, Azure, Hetzner):** In public clouds, once the VM's network interface comes up during the `Network` stage, `cloud-init` makes an HTTP GET request to a special link-local IP address (`http://169.254.169.254/latest/user-data` and `http://169.254.169.254/latest/meta-data`) to fetch its configuration over the virtual network.

---

### 4. Cloud-Init vs. Dockerfile: What is the Difference?

While both tools use declarative instructions to automate environment setup, they operate at completely different layers of the stack:

| Dimension | Cloud-Init (`cloud-init.yaml`) | Dockerfile (`Dockerfile`) |
| :--- | :--- | :--- |
| **What It Configures** | A full **Virtual Machine (VM)** or bare-metal Linux server with its own kernel and init system (`systemd`). | An isolated **Application Container Image** that shares the host OS's Linux kernel. |
| **When It Runs** | At **Runtime (First Boot)** when a new server instance is launched. | At **Build Time** (`docker build`) to produce an immutable container image before deployment. |
| **Primary Responsibilities** | OS-level bootstrapping: creating system users, SSH keys, firewall rules, disk mounts, systemd services, and installing the container runtime (`docker.io`). | Application packaging: bundling app source code, language runtimes (Node/Python/Go), libraries, and defining the process `ENTRYPOINT`/`CMD`. |
| **State & Mutability** | Configures a long-lived or stateful host OS where services run. | Produces immutable, layered snapshots pushed to a container registry (Docker Hub / GHCR). |
| **How They Work Together** | **Step 1:** `cloud-init` provisions the Ubuntu VM and installs Docker. | **Step 2:** The provisioned VM pulls and runs the container built from a `Dockerfile`. |

---

## 8. Teardown & Cleanup

To stop, delete, and permanently purge the VM and free all disk space on your host machine:

```bash
multipass delete testpress-vm --purge
```