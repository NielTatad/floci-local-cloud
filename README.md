# floci-local-cloud

[![CI](https://github.com/your-org/floci-local-cloud/actions/workflows/ci.yml/badge.svg)](https://github.com/your-org/floci-local-cloud/actions/workflows/ci.yml)
[![Docker](https://img.shields.io/badge/Docker-required-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/get-docker/)
[![Floci](https://img.shields.io/badge/Floci-2.5.0-6C63FF)](https://github.com/floci-io/floci)
[![AWS CLI](https://img.shields.io/badge/AWS_CLI-v2-FF9900?logo=amazon-aws&logoColor=white)](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A persistent, automated, AWS-compatible local cloud environment powered by [Floci](https://github.com/floci-io/floci) and Docker Compose.

Develop and test AWS infrastructure locally — no cloud account, no auth token, no cost. Point your AWS CLI, Terraform, CDK, or any AWS SDK at `http://localhost:4566` and use your existing workflows unchanged.

> **Scope:** This repository manages the local cloud simulation environment only. Terraform infrastructure definitions live in the separate [`terraform-floci-infrastructure`](https://github.com/your-org/terraform-floci-infrastructure) repository.

---

## Table of Contents

1. [Features](#features)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Getting Started](#getting-started)
5. [Configuration](#configuration)
6. [Available Commands](#available-commands)
7. [AWS CLI Configuration](#aws-cli-configuration)
8. [Persistence and Data Management](#persistence-and-data-management)
9. [Backup and Restore](#backup-and-restore)
10. [CI/CD Workflow](#cicd-workflow)
11. [Scheduled Backups](#scheduled-backups)
12. [Repository Structure](#repository-structure)
13. [Troubleshooting](#troubleshooting)
14. [Security Considerations](#security-considerations)
15. [Integration with terraform-floci-infrastructure](#integration-with-terraform-floci-infrastructure)
16. [References](#references)
17. [License](#license)

---

## Features

| Feature | Detail |
|---|---|
| **Local AWS emulation** | 45+ AWS services at `http://localhost:4566` via Floci |
| **Pinned Docker image** | `floci/floci:2.5.0` — reproducible, no surprise upgrades |
| **Persistent storage** | Named Docker volume survives container restarts |
| **Four storage modes** | `memory` / `hybrid` / `persistent` / `wal` — tunable per workflow |
| **Health monitoring** | Docker health check + `/_floci/health` endpoint polling |
| **Backup and restore** | Timestamped archives with SHA-256 checksums and safety snapshots |
| **Makefile automation** | Ten commands covering the full lifecycle |
| **GitHub Actions CI** | Static validation + live integration tests on every push |
| **Dedicated AWS profile** | Isolated `floci` AWS CLI profile — never touches real AWS |
| **Web console** | Browser UI at `http://localhost:4500/_floci/ui` (optional) |

---

## Architecture

```mermaid
flowchart TD
    Dev["Developer workstation"]

    subgraph Tools["Local tooling"]
        CLI["AWS CLI\n(--profile floci)"]
        TF["Terraform\n(terraform-floci-infrastructure)"]
        SDK["AWS SDK\n(Java / Python / Node / Go)"]
    end

    subgraph Compose["Docker Compose (floci/)"]
        direction TB
        Floci["floci container\nfloci/floci:2.5.0\nlocalhost:4566"]
        Volume[("Docker volume\nfloci-data\n/app/data")]
        Socket["Docker socket\n/var/run/docker.sock"]
        Floci <-->|"hybrid storage\nflush every 5s"| Volume
        Floci <-->|"Lambda / RDS /\nElastiCache / ECS"| Socket
    end

    subgraph AWS["Simulated AWS services (port 4566)"]
        S3["S3"]
        DDB["DynamoDB"]
        SQS["SQS / SNS"]
        IAM["IAM / STS / KMS"]
        Lambda["Lambda (Docker)"]
        RDS["RDS (Docker)"]
        More["45+ more services"]
    end

    subgraph CI["GitHub Actions CI"]
        Validate["validate job\nShellCheck · yamllint\nCompose config · file checks"]
        Integration["integration job\nFloci start · health wait\nSTS · IAM · S3 tests"]
    end

    Dev --> Tools
    CLI -->|"HTTP :4566\nAWS wire protocol"| Floci
    TF  -->|"HTTP :4566\nAWS wire protocol"| Floci
    SDK -->|"HTTP :4566\nAWS wire protocol"| Floci
    Floci --> AWS

    CI -.->|"validates config\nnot deployed locally"| Compose
```

**Key design decisions:**

- Floci runs as a single container. All 45+ AWS services are served from one port (`4566`), keeping the setup simple.
- The `floci-data` Docker named volume holds all state. `docker compose down` (without `-v`) stops the container but preserves the volume, so resources survive restarts.
- The Docker socket is mounted so Floci can launch real Docker containers for Lambda, RDS, ElastiCache, ECS, EC2, and other container-backed services.
- `FLOCI_HOSTNAME=floci` ensures that URLs Floci returns (e.g. SQS `QueueUrl`) use the Docker Compose service name, which resolves correctly from other containers on the same network.
- CI runs Floci in `memory` storage mode — fast and stateless, appropriate for ephemeral runners.

---

## Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| **Docker Engine** or **Docker Desktop** | 23.0 | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| **Docker Compose v2** | 2.0 (plugin syntax) | [docs.docker.com/compose/install](https://docs.docker.com/compose/install/) |
| **AWS CLI v2** | 2.0 | [Installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| **GNU Make** | 3.81 | Ships with most Linux/macOS; [Windows via Chocolatey](https://community.chocolatey.org/packages/make) |
| **curl** | any | Used by health check scripts |

> **WSL users (Windows):** Run all commands inside a WSL terminal. Docker Desktop with WSL 2 integration is the recommended setup.

Verify your environment:

```bash
docker --version          # Docker version 23.x or higher
docker compose version    # Docker Compose version v2.x
aws --version             # aws-cli/2.x
make --version            # GNU Make 3.81 or higher
```

---

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/your-org/floci-local-cloud.git
cd floci-local-cloud
```

### 2. Configure environment variables

```bash
cp floci/.env.example floci/.env
```

The defaults work out of the box for local development. Open `floci/.env` if you need to change the port, storage mode, or image version. The file is excluded from Git — never commit it.

### 3. Start Floci

```bash
make up
```

This starts the container in detached mode and waits up to 120 seconds for Floci to pass its health check at `/_floci/health`.

Expected output:

```
[floci] Starting Floci (image: floci/floci:2.5.0, port: 4566)...
[floci] Floci container started.
[floci] Waiting for Floci to become healthy...
[floci] Floci is healthy and ready at http://localhost:4566
[floci] Web console (if enabled): http://localhost:4500/_floci/ui
```

### 4. Check container status

```bash
make status
```

### 5. View logs

```bash
make logs                        # last 100 lines
make logs ARGS='--follow'        # stream live
make logs ARGS='--tail 50'       # last 50 lines
```

### 6. Verify the endpoint with AWS CLI

```bash
# Configure the floci profile once (see AWS CLI Configuration below)
aws --profile floci sts get-caller-identity
```

Expected response:

```json
{
    "UserId": "AKIAIOSFODNN7EXAMPLE",
    "Account": "000000000000",
    "Arn": "arn:aws:iam::000000000000:root"
}
```

### 7. Stop Floci

```bash
make down          # stop container, preserve all state
```

---

## Configuration

All configuration is managed through `floci/.env` (copied from `floci/.env.example`). Docker Compose reads this file automatically.

| Variable | Default | Description |
|---|---|---|
| `FLOCI_VERSION` | `2.5.0` | Pinned Docker image tag |
| `FLOCI_CONTAINER_NAME` | `floci` | Docker container name |
| `FLOCI_VOLUME_NAME` | `floci-data` | Docker volume name for persistent state |
| `FLOCI_HOST_PORT` | `4566` | Host port for the AWS-compatible endpoint |
| `FLOCI_HOSTNAME` | `floci` | Hostname used in URLs Floci returns (set to service name for Compose) |
| `FLOCI_STORAGE_MODE` | `hybrid` | Storage mode: `memory` / `persistent` / `hybrid` / `wal` |
| `FLOCI_DEFAULT_REGION` | `us-east-1` | Default AWS region |
| `FLOCI_DEFAULT_ACCOUNT_ID` | `000000000000` | Default AWS account ID |
| `FLOCI_SERVICES_S3_ENFORCE_AUTH` | `false` | Reject S3 requests with unknown signed keys |
| `FLOCI_NETWORK_SECURITY_GROUP_ENFORCEMENT_ENABLED` | `false` | Apply nftables SG rules to container-backed services |
| `FLOCI_SERVICES_UI_ENABLED` | `true` | Enable the browser web console sidecar |

### Storage mode guide

| Mode | Behaviour | Best for |
|---|---|---|
| `memory` | Entirely in RAM; lost on container stop | CI, ephemeral tests |
| `persistent` | Write-through to disk on every mutation | Simple local state |
| `hybrid` | In-memory with async flush every 5 s | **Local development (default)** |
| `wal` | Write-ahead log before every response | Maximum durability |

### IAM enforcement

Floci accepts any non-empty string as AWS credentials by default. Two optional enforcement mechanisms are available:

- **S3 auth enforcement** (`FLOCI_SERVICES_S3_ENFORCE_AUTH=true`): Rejects S3 requests signed with access keys that have not been created via the IAM API.
- **Security group enforcement** (`FLOCI_NETWORK_SECURITY_GROUP_ENFORCEMENT_ENABLED=true`): Applies nftables rules to Docker-backed services. Requires rootful Docker on Linux. Not supported with rootless Docker or Windows containers.

Both are disabled by default and are not required for normal local development.

---

## Available Commands

Run `make help` for a quick reference at any time.

### `make up`

Start Floci and wait for it to become healthy.

```bash
make up
```

Checks Docker availability, verifies the port is free, starts the container in detached mode, and polls `/_floci/health` every 5 seconds until ready (120-second timeout).

---

### `make down`

Stop Floci. The persistent volume is **not** deleted.

```bash
make down
```

Resources (S3 buckets, DynamoDB tables, IAM users, etc.) are preserved and available on the next `make up`.

---

### `make restart`

Stop then start Floci in one command.

```bash
make restart
```

---

### `make status`

Show container state, Docker health check status, endpoint reachability, volume status, and a live resource snapshot.

```bash
make status
```

---

### `make logs`

Display container logs. Pass `ARGS` to control output.

```bash
make logs                        # last 100 lines (default)
make logs ARGS='--follow'        # stream continuously (Ctrl+C to stop)
make logs ARGS='--tail 50'       # last 50 lines
```

---

### `make health`

Run the full five-check health suite:

1. Docker daemon reachable
2. Container running
3. Docker health check status
4. HTTP `/_floci/health` returns 200
5. Named volume exists

```bash
make health
```

Exits `0` when all checks pass, `1` with diagnostic hints when any check fails.

---

### `make backup`

Back up Floci's persistent state to a timestamped archive in `backups/`.

```bash
make backup
```

Output:

```
backups/floci-backup-20261118-143022.tar.gz
backups/floci-backup-20261118-143022.tar.gz.sha256
```

Safe to run while Floci is running in `hybrid` or `persistent` mode. With `wal` mode, stopping Floci first (`make down`) gives maximum consistency.

---

### `make restore`

Restore Floci state from a backup archive. **Floci must be stopped first.**

```bash
make down
make restore BACKUP=backups/floci-backup-20261118-143022.tar.gz
make up
```

The script verifies the archive checksum, creates a safety snapshot of the current volume before overwriting, and requires explicit confirmation.

---

### `make clean`

Remove stopped containers and dangling Docker images. The persistent volume is **not** deleted.

```bash
make clean
```

---

### `make clean-volumes`

Remove containers **and** the persistent volume. All Floci state is permanently lost.

```bash
make clean-volumes
```

Requires typing `yes` to confirm. Consider running `make backup` first.

---

### `make help`

Print all available targets with descriptions.

```bash
make help
```

---

## AWS CLI Configuration

Configure a dedicated `floci` profile that targets `http://localhost:4566`. This profile is completely isolated from any real AWS configuration.

### Configure the profile

Add the following to `~/.aws/config`:

```ini
[profile floci]
region = us-east-1
output = json
endpoint_url = http://localhost:4566
```

Add the following to `~/.aws/credentials`:

```ini
[floci]
aws_access_key_id = test
aws_secret_access_key = test
```

> **Never use real AWS credentials with Floci.** The values `test` / `test` are intentional dummy credentials that Floci accepts.

### Usage examples

All examples use `--profile floci`. When `endpoint_url` is set in `~/.aws/config`, the `--endpoint-url` flag is optional but shown for clarity.

**STS — verify connectivity:**

```bash
aws --profile floci sts get-caller-identity
```

**IAM — create a user and access key:**

```bash
# Create a user
aws --profile floci iam create-user --user-name dev-user

# Create an access key for the user
aws --profile floci iam create-access-key --user-name dev-user

# List all users
aws --profile floci iam list-users
```

**S3 — create a bucket and upload a file:**

```bash
# Create a bucket
aws --profile floci s3api create-bucket --bucket my-local-bucket

# Upload a file
aws --profile floci s3 cp myfile.txt s3://my-local-bucket/

# List bucket contents
aws --profile floci s3 ls s3://my-local-bucket/

# List all buckets
aws --profile floci s3 ls
```

**DynamoDB — create a table and put an item:**

```bash
# Create a table
aws --profile floci dynamodb create-table \
  --table-name my-table \
  --attribute-definitions AttributeName=pk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# Put an item
aws --profile floci dynamodb put-item \
  --table-name my-table \
  --item '{"pk": {"S": "item-1"}, "value": {"S": "hello"}}'

# List tables
aws --profile floci dynamodb list-tables
```

**SQS — create a queue and send a message:**

```bash
# Create a queue
aws --profile floci sqs create-queue --queue-name my-queue

# Send a message
aws --profile floci sqs send-message \
  --queue-url http://localhost:4566/000000000000/my-queue \
  --message-body "Hello from Floci"

# Receive messages
aws --profile floci sqs receive-message \
  --queue-url http://localhost:4566/000000000000/my-queue
```

**Without the profile** (using environment variables directly):

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://localhost:4566

aws s3 ls
aws iam list-users
```

---

## Persistence and Data Management

### How it works

Floci stores all state in the `floci-data` Docker named volume, mounted inside the container at `/app/data`. The default storage mode is `hybrid` — Floci keeps state in memory for fast reads and writes, flushing to the volume every 5 seconds.

### What survives a container restart

With `hybrid`, `persistent`, or `wal` storage mode, **all AWS resources survive `docker compose down` and restart**:

- IAM users, roles, groups, policies, and access keys
- S3 buckets and objects
- DynamoDB tables and items
- SQS queues and messages
- SNS topics and subscriptions
- Secrets Manager secrets
- All other stateful resources

### What does NOT survive

- **`docker compose down -v`** — the `-v` flag deletes named volumes. All state is lost. The Makefile's `make down` command never passes `-v`. Only `make clean-volumes` does, and it requires typing `yes` to confirm.
- **`memory` storage mode** — state lives only in RAM. The container is stateless; a restart starts fresh. Use this for CI or when you want a clean slate.

### Storage mode comparison

```
make down       →  container stops, volume preserved   ✓ state kept
make up         →  container starts, volume remounted  ✓ state restored

make down -v    →  NEVER done by make down
make clean-volumes → volume deleted (confirmation required)
```

---

## Backup and Restore

### Creating a backup

```bash
make backup
```

The script:

1. Checks that the `floci-data` volume exists.
2. Warns if `wal` mode is in use (stopping first gives better consistency).
3. Uses an Alpine helper container to stream the volume contents as a gzip archive.
4. Writes `backups/floci-backup-YYYYMMDD-HHMMSS.tar.gz`.
5. Generates a SHA-256 checksum at `backups/floci-backup-YYYYMMDD-HHMMSS.tar.gz.sha256`.

Backup files are excluded from Git by `.gitignore`.

### Restoring a backup

```bash
# 1. Stop Floci (required — do not restore while the container is running)
make down

# 2. Restore from a specific archive
make restore BACKUP=backups/floci-backup-20261118-143022.tar.gz

# 3. Restart with the restored state
make up
```

The restore script:

1. Verifies the archive against its SHA-256 checksum (if present).
2. Confirms the archive is a valid gzip file.
3. Refuses to run if Floci is still running.
4. Creates a safety snapshot of the current volume before overwriting it.
5. Asks for explicit confirmation before proceeding.
6. Extracts the archive into the volume.

### Listing available backups

```bash
ls -lh backups/*.tar.gz
```

### Scheduled backups

See [Scheduled Backups](#scheduled-backups) for cron, WSL cron, and Windows Task Scheduler instructions.

---

## CI/CD Workflow

The workflow in `.github/workflows/ci.yml` runs on every push to `main`, every pull request targeting `main`, and on manual dispatch.

It never deploys to your local machine and never provisions real AWS resources.

### Job 1: `validate` (static checks, no Docker required)

| Step | What it checks |
|---|---|
| Docker Compose config | `docker compose config --quiet` — validates the Compose file |
| YAML syntax | `yamllint` on `docker-compose.yml` and `ci.yml` |
| ShellCheck | All 7 scripts in `scripts/` at `warning` severity |
| Makefile syntax | `make --dry-run help` |
| Required files | Asserts every file in the defined list exists |
| Script permissions | Confirms all `scripts/*.sh` are executable |

### Job 2: `integration` (runs after `validate` passes)

| Step | What it does |
|---|---|
| Pull image | Pulls `floci/floci:2.5.0` explicitly to verify it is pullable |
| Start Floci | Starts with `memory` storage mode (CI is stateless) |
| Wait for health | Polls `/_floci/health` every 5 s, up to 120 s |
| AWS CLI v2 check | Verifies `aws-cli/2.x` is on the runner |
| STS connectivity | `aws sts get-caller-identity` against the local endpoint |
| IAM test | Creates a user, retrieves it, lists users |
| S3 test | Creates a bucket, puts an object, retrieves and diffs it |
| `health-check.sh` | Runs the script directly to validate the script itself |
| Cleanup | `docker compose down --volumes` — always runs, even on failure |

### Security properties

- Permissions: `contents: read` only — no write access to code, packages, or deployments.
- No real credentials anywhere — `AWS_ACCESS_KEY_ID=test`, `AWS_SECRET_ACCESS_KEY=test`.
- `actions/checkout` pinned to an immutable SHA (`11bd71901bbe5b1630ceea73d27597364c9af683`).
- No third-party actions used.

---

## Scheduled Backups

The following options set up automatic daily backups. All assume you are running Floci on your local machine — GitHub Actions runners cannot access your local Docker volumes.

### Linux cron

```bash
crontab -e
```

Add (runs daily at 02:00):

```cron
0 2 * * * cd /path/to/floci-local-cloud && make backup >> /var/log/floci-backup.log 2>&1
```

### WSL cron (Windows Subsystem for Linux)

WSL 2 does not start cron automatically. Enable it once:

```bash
# Start the cron service (run this after each WSL restart, or add to ~/.bashrc)
sudo service cron start
```

Then add the crontab entry as above, using the WSL path to the repository:

```cron
0 2 * * * cd /mnt/d/DevOps/floci-local-cloud && make backup >> /tmp/floci-backup.log 2>&1
```

### Windows Task Scheduler

1. Open **Task Scheduler** → **Create Basic Task**.
2. Set the trigger to **Daily** at your preferred time.
3. Set the action to **Start a program**:
   - **Program:** `wsl.exe`
   - **Arguments:** `-e bash -c "cd /mnt/d/DevOps/floci-local-cloud && make backup"`
4. Under **Settings**, check **Run task as soon as possible after a scheduled start is missed**.

---

## Repository Structure

```text
floci-local-cloud/
├── .github/
│   └── workflows/
│       └── ci.yml              # GitHub Actions CI — validation + integration tests
│
├── floci/
│   ├── docker-compose.yml      # Floci service definition (image, volumes, env, health)
│   └── .env.example            # Environment variable template — copy to .env
│
├── scripts/
│   ├── start.sh                # Start Floci and wait for health
│   ├── stop.sh                 # Stop Floci (--volumes flag for state deletion)
│   ├── status.sh               # Container, endpoint, and volume status
│   ├── health-check.sh         # Five-check health suite with diagnostics
│   ├── logs.sh                 # Stream or display container logs
│   ├── backup.sh               # Back up floci-data volume to timestamped archive
│   └── restore.sh              # Restore volume from backup (with safety snapshot)
│
├── backups/
│   └── .gitkeep                # Preserves the directory; archives are gitignored
│
├── Makefile                    # Developer interface — delegates to scripts/
├── .gitignore                  # Excludes .env, backups/*.tar.gz, .tfstate, etc.
├── .dockerignore               # Keeps any future build context clean and secure
├── README.md                   # This file
└── LICENSE                     # MIT
```

---

## Troubleshooting

### Container fails to start

```bash
make logs          # check for startup errors
make status        # check container state
```

Common causes:

- **Port 4566 already in use** — something else is listening on that port. Find and stop it, or change `FLOCI_HOST_PORT` in `floci/.env`.

  ```bash
  # Linux / WSL
  ss -tlnp | grep 4566
  # macOS
  lsof -iTCP:4566 -sTCP:LISTEN
  ```

- **Docker daemon not running** — start Docker Desktop or the Docker service.

- **Missing floci/.env** — copy the example: `cp floci/.env.example floci/.env`.

---

### Port conflict

```bash
# Find what is using port 4566
ss -tlnp | grep 4566              # Linux / WSL
lsof -iTCP:4566 -sTCP:LISTEN      # macOS

# Change the port in floci/.env
FLOCI_HOST_PORT=4567

# Restart
make restart
```

Remember to update `AWS_ENDPOINT_URL` and `--endpoint-url` to the new port.

---

### Health check never passes

```bash
make health        # detailed diagnostic output
make logs          # look for startup errors or panics
```

Floci starts in roughly 24 ms. If the health check times out (120 s), the most likely causes are:

- Docker socket not accessible (required for the web console sidecar — set `FLOCI_SERVICES_UI_ENABLED=false` to disable it).
- Insufficient memory — Floci idle footprint is ~13 MiB; Docker Desktop's memory limit should not be an issue.
- Image pull failing — verify network connectivity and that `floci/floci:2.5.0` exists on Docker Hub.

---

### AWS CLI authentication errors

```bash
# Verify endpoint is reachable
curl -sf http://localhost:4566/_floci/health && echo "OK"

# Confirm you are using the floci profile, not your real AWS profile
aws configure list --profile floci

# Test connectivity
aws --profile floci sts get-caller-identity
```

If you see `Could not connect to the endpoint URL`, Floci is not running — start it with `make up`.

If you see `InvalidClientTokenId`, the request reached a real AWS endpoint. Check that `endpoint_url` is set in `~/.aws/config` for the `floci` profile, or pass `--endpoint-url http://localhost:4566` explicitly.

---

### Data not persisting after restart

Check the storage mode:

```bash
grep FLOCI_STORAGE_MODE floci/.env
```

If it is `memory`, state is never written to disk. Change it to `hybrid` for local development:

```
FLOCI_STORAGE_MODE=hybrid
```

Verify the volume exists:

```bash
docker volume inspect floci-data
```

If the volume does not exist, it means either `make up` has not been run yet, or `make clean-volumes` / `docker compose down -v` was run previously.

---

### Incorrect endpoint configuration

All AWS CLI commands must target `http://localhost:4566`. The two ways to ensure this:

**Option 1 — AWS profile (recommended):**

```ini
# ~/.aws/config
[profile floci]
endpoint_url = http://localhost:4566
```

**Option 2 — Explicit flag per command:**

```bash
aws --endpoint-url http://localhost:4566 s3 ls
```

**Option 3 — Environment variable:**

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
aws s3 ls
```

---

### Diagnostic quick reference

```bash
make status                              # container + endpoint + volume status
make health                              # full health suite
make logs                                # last 100 log lines
make logs ARGS='--follow'                # stream live logs
docker inspect floci                     # raw container metadata
docker volume inspect floci-data         # volume metadata and mount point
docker stats --no-stream floci           # live resource usage
curl -sf http://localhost:4566/_floci/health && echo "healthy"
```

---

## Security Considerations

### Credentials

- **Always use dummy credentials** (`test` / `test` or any non-empty string). Never use real AWS access keys with Floci.
- The `floci` AWS CLI profile is completely isolated from your default profile. Do not set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in your shell environment unless they are the dummy values.

### Files that must never be committed

| File | Why |
|---|---|
| `floci/.env` | Contains environment overrides; listed in `.gitignore` |
| `~/.aws/credentials` | Real AWS credentials; never inside this repository |
| `backups/*.tar.gz` | May contain sensitive resource state; listed in `.gitignore` |
| `*.tfstate` | Contains Terraform state which may include sensitive outputs |

### Network exposure

- The Floci endpoint (`4566`) is bound to `localhost` only via Docker's port mapping — it is not accessible from other machines on your network by default.
- The web console (`4500`) is bound to `127.0.0.1` via `FLOCI_SERVICES_UI_BIND_ADDRESS=127.0.0.1` in `docker-compose.yml`.
- Do not publish these ports on `0.0.0.0` without understanding the implications.

### Docker socket

The Docker socket (`/var/run/docker.sock`) is mounted for container-backed services (Lambda, RDS, etc.). This grants the Floci container significant access to the Docker daemon. If you are not using container-backed services, remove the socket mount from `floci/docker-compose.yml`.

### IAM enforcement

By default, Floci accepts any non-empty credential. This matches standard local development practice — there are no real resources at risk. Enable `FLOCI_SERVICES_S3_ENFORCE_AUTH=true` if you want to test IAM-enforced S3 access patterns locally.

### CI security

- The workflow uses `permissions: contents: read` — the minimum needed to check out the repository.
- No secrets are stored in the repository or passed to the workflow.
- The `actions/checkout` step is pinned to an immutable SHA, not a mutable tag.

---

## Integration with terraform-floci-infrastructure

This repository provides the running Floci environment. The [`terraform-floci-infrastructure`](https://github.com/your-org/terraform-floci-infrastructure) repository contains Terraform modules that provision AWS resources against it.

### Workflow

```bash
# 1. Start Floci (this repository)
cd floci-local-cloud
make up

# 2. In the Terraform repository, configure provider.tf:
#    endpoint_url = "http://localhost:4566"
#    access_key   = "test"
#    secret_key   = "test"
#    skip_credentials_validation = true
#    skip_metadata_api_check     = true
#    skip_requesting_account_id  = true
#    s3_use_path_style           = true

# 3. Apply infrastructure
cd ../terraform-floci-infrastructure
terraform init
terraform plan
terraform apply

# 4. Verify resources
aws --profile floci s3 ls
aws --profile floci dynamodb list-tables

# 5. When done
terraform destroy
cd ../floci-local-cloud
make down
```

### Terraform S3 backend (optional)

Floci supports the S3 backend and DynamoDB locking used by Terraform's remote state. To use a fully emulated remote state workflow, create the backend resources first:

```bash
aws --profile floci s3api create-bucket --bucket tfstate
aws --profile floci dynamodb create-table \
  --table-name tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then configure `backend "s3"` in the Terraform repository. See the [Floci Terraform guide](https://github.com/floci-io/floci/blob/main/docs/getting-started/terraform.md) for the full backend configuration.

---

## References

| Resource | URL |
|---|---|
| Floci repository | https://github.com/floci-io/floci |
| Floci Docker Hub | https://hub.docker.com/r/floci/floci |
| Floci installation docs | https://github.com/floci-io/floci/blob/main/docs/getting-started/installation.md |
| Floci Terraform guide | https://github.com/floci-io/floci/blob/main/docs/getting-started/terraform.md |
| Docker Compose docs | https://docs.docker.com/compose/ |
| AWS CLI v2 installation | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| AWS CLI configuration | https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html |
| Terraform AWS provider | https://registry.terraform.io/providers/hashicorp/aws/latest/docs |
| GitHub Actions docs | https://docs.github.com/en/actions |
| ShellCheck | https://www.shellcheck.net |

---

## License

[MIT](LICENSE) — use it however you want.
