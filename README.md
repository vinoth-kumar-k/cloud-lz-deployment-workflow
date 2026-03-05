# Alibaba Cloud Landing Zone – Deployment Workflow

GitHub Actions–based CI/CD pipeline for deploying and managing an Alibaba Cloud
Landing Zone (LZ) from IaC code.  The design assumes a **highly restrictive
corporate environment** with GitHub Enterprise Cloud, mixed self-hosted and
GitHub-hosted runners, and **GitHub OIDC** as the authentication mechanism
(no static cloud credentials stored anywhere).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Runner Architecture](#2-runner-architecture)
3. [Authentication – GitHub OIDC to Alibaba Cloud](#3-authentication--github-oidc-to-alibaba-cloud)
4. [Repository Structure](#4-repository-structure)
5. [GitHub Repository Configuration](#5-github-repository-configuration)
6. [Workflows](#6-workflows)
7. [Day-1 Setup Procedure](#7-day-1-setup-procedure)
8. [State Backend](#8-state-backend)
9. [Security Controls](#9-security-controls)
10. [Operational Runbook](#10-operational-runbook)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  GitHub Enterprise Cloud                                                 │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Repository: cloud-lz-deployment-workflow                        │    │
│  │                                                                   │    │
│  │  Branches: main (protected) ← feature/* ← PRs                   │    │
│  │                                                                   │    │
│  │  Environments:                                                    │    │
│  │    lz-plan    (no gate)                                          │    │
│  │    lz-deploy  (required reviewers + branch protection)           │    │
│  │    lz-destroy (required reviewers + branch protection)           │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  Workflows (GitHub Actions):                                             │
│    lz-pr-validate.yml   ← runs on every PR                             │
│    lz-deploy.yml        ← runs on merge to main / manual dispatch      │
│    lz-drift-detect.yml  ← scheduled daily                              │
│    lz-destroy.yml       ← manual dispatch only, double-gated           │
└──────────────┬───────────────────────────────────────────┬─────────────┘
               │                                           │
               │ Job dispatched to runner                  │ OIDC token exchange
               ▼                                           ▼
┌──────────────────────────┐              ┌──────────────────────────────┐
│  Self-hosted Runner      │              │  Alibaba Cloud STS           │
│  Label: corporate        │              │  sts.aliyuncs.com            │
│                          │              │                              │
│  ● Inside corporate      │              │  ● Validates GitHub OIDC     │
│    network               │              │    token against RAM OIDC    │
│  ● Can access internal   │              │    Provider                  │
│    code / registries     │              │  ● Returns temporary STS     │
│  ● Job: checkout code    │              │    credentials (1 h TTL)     │
│    + package artifact    │              └──────────────────────────────┘
└──────────┬───────────────┘                            ▲
           │ Upload artifact                            │ Role ARN
           ▼                                            │
┌──────────────────────────┐              ┌─────────────┴────────────────┐
│  GitHub Artifact Store   │              │  Self-hosted Runner          │
│  (encrypted at rest)     │              │  Label: cloud                │
└──────────┬───────────────┘              │                              │
           │ Download artifact            │  ● Internet-accessible       │
           ▼                              │    (or proxied to Alibaba    │
┌──────────────────────────┐              │    Cloud APIs)               │
│  Self-hosted Runner      │              │  ● Jobs: tf init/plan/apply  │
│  Label: cloud            ◄─────────────┘  ● Acquires OIDC creds       │
│                          │              │    before each cloud op       │
│  Terraform operations    │              └──────────────────────────────┘
│  with STS temp creds     │                            │
└──────────────────────────┘                            │ Terraform API calls
                                                        ▼
                                         ┌──────────────────────────────┐
                                         │  Alibaba Cloud               │
                                         │                              │
                                         │  ResourceDirectory           │
                                         │  RAM (Identity)              │
                                         │  VPC / CEN                   │
                                         │  Security Baseline           │
                                         │  Logging (SLS / OSS)         │
                                         │  OSS (TF state + lock)       │
                                         └──────────────────────────────┘
```

---

## 2. Runner Architecture

### Labels and responsibilities

| Label | Network zone | Responsibilities |
|-------|-------------|-----------------|
| `self-hosted, corporate` | Inside corporate network | Checkout from internal repos; package IaC source into artifact |
| `self-hosted, cloud` | Corporate network + outbound internet to Alibaba Cloud APIs | Terraform init / plan / apply; OIDC token exchange with STS |

### Why two runner types?

Corporate policy prevents GitHub-hosted runners from reaching internal code
repositories and private package registries.  The **corporate** runner handles
the checkout; it never touches Alibaba Cloud.  The **cloud** runner receives
only the pre-packaged artifact (never raw source) and authenticates to Alibaba
Cloud via short-lived OIDC tokens – it stores no long-lived credentials.

### Pre-LZ vs post-LZ runner topology

This is the key Day-1 consideration.

```
PRE-LZ (Day-1 bootstrap)                 POST-LZ (steady state, optional)
────────────────────────                 ───────────────────────────────
Corporate network                        Corporate network
  ┌────────────────┐                       ┌────────────────┐
  │ corporate      │                       │ corporate      │
  │ runner         │                       │ runner         │ (unchanged)
  │ (existing VM)  │                       │ (existing VM)  │
  └────────────────┘                       └────────────────┘

  ┌────────────────┐                     Alibaba Cloud (LZ deployed)
  │ cloud runner   │   ──── migrate ───▶   ┌──────────────────────┐
  │ (new VM on     │                       │ cloud runner         │
  │  corporate     │                       │ (ECS instance inside │
  │  network with  │                       │  the LZ, egress to   │
  │  internet/     │                       │  GitHub + STS)       │
  │  proxy access) │                       └──────────────────────┘
  └────────────────┘
```

**For Day-1, both runners live on corporate infrastructure.**  The cloud runner
is simply a corporate VM that has outbound internet access (direct or via
proxy) to the Alibaba Cloud API endpoints.  There is no chicken-and-egg
problem – the pipeline does not depend on Alibaba Cloud compute to deploy
Alibaba Cloud.

Once the LZ is live and an ECS instance is available inside it, the cloud
runner can optionally be migrated there.  This is purely operational preference
and does not change any workflow or action code.

### Minimum VM specification

| Runner | CPU | RAM | Disk | OS |
|--------|-----|-----|------|----|
| corporate | 2 vCPU | 4 GB | 20 GB | Ubuntu 22.04 LTS |
| cloud | 2 vCPU | 4 GB | 30 GB | Ubuntu 22.04 LTS |

The cloud runner needs more disk because Terraform downloads provider plugins
(~500 MB per init for the alicloud provider).

### Network requirements for the cloud runner

Outbound HTTPS (443) to:

| Destination | Purpose |
|-------------|---------|
| `token.actions.githubusercontent.com` | GitHub OIDC token endpoint |
| `api.github.com` | GitHub API (artifact upload/download) |
| `objects.githubusercontent.com` | GitHub artifact storage |
| `sts.aliyuncs.com` | STS OIDC token exchange |
| `ram.aliyuncs.com` | RAM API calls |
| `oss-cn-<region>.aliyuncs.com` | OSS state backend |
| `<instance>.cn-<region>.ots.aliyuncs.com` | TableStore state locking |
| `*.aliyuncs.com` | Alibaba Cloud service APIs (Terraform provider) |
| `registry.terraform.io` | Terraform provider downloads (or internal mirror) |

If outbound internet is restricted to a proxy, set `HTTP_PROXY`/`HTTPS_PROXY`
on the runner service and add `NO_PROXY=169.254.169.254` (instance metadata).

### Runner software installation

Run these steps on both VMs (adjust if using a different Linux distro):

```bash
# 1. Install runtime dependencies
sudo apt-get update && sudo apt-get install -y curl jq git tar unzip

# 2. Install Terraform
TERRAFORM_VERSION="1.9.5"
curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
  -o /tmp/terraform.zip
sudo unzip /tmp/terraform.zip -d /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
terraform version

# 3. Install Alibaba Cloud CLI (cloud runner only)
curl -fsSL https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz \
  -o /tmp/aliyun-cli.tgz
sudo tar -xzf /tmp/aliyun-cli.tgz -C /usr/local/bin/
aliyun version

# 4. Create a dedicated service account for the runner process
sudo useradd -m -s /bin/bash github-runner
```

### GitHub Actions runner agent registration

GitHub Enterprise Cloud generates a one-time registration token per runner.
Repeat for each VM.

```bash
# On the runner VM, as the github-runner user:
sudo su - github-runner

# Download the latest runner agent (check https://github.com/actions/runner/releases)
RUNNER_VERSION="2.317.0"
mkdir ~/actions-runner && cd ~/actions-runner
curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  -o runner.tar.gz
tar -xzf runner.tar.gz

# Configure – obtain the token from:
# GHEC org → Settings → Actions → Runners → New self-hosted runner
./config.sh \
  --url https://github.com/<YOUR_ORG> \
  --token <REGISTRATION_TOKEN> \
  --name lz-corporate-runner-01 \     # or lz-cloud-runner-01
  --labels self-hosted,corporate \    # or self-hosted,cloud
  --runnergroup lz-runners \
  --work _work \
  --unattended

# Install and start as a systemd service
sudo ./svc.sh install github-runner
sudo ./svc.sh start
sudo ./svc.sh status
```

### Runner group configuration in GitHub Enterprise Cloud

Runner groups restrict which repositories can use which runners.

1. Go to **Org → Settings → Actions → Runner groups → New runner group**
2. Create group: `lz-runners`
3. Access policy: **Selected repositories** → add `cloud-lz-deployment-workflow`
4. Move both runners into this group
5. Disable **Allow public repositories** (enterprise policy)

This ensures the LZ deployment runners are not available to other repos in the
organisation.

### Tool checklist – verify before first pipeline run

```bash
./scripts/validate-prereqs.sh
```

All checks must pass on the cloud runner before triggering Day-1 deployment.

---

## 3. Authentication – GitHub OIDC to Alibaba Cloud

No static `AccessKey`/`SecretKey` pairs are stored in GitHub Secrets.
Authentication uses the **GitHub OIDC → Alibaba Cloud STS** federation chain.

### How it works

```
GitHub Actions workflow
        │
        │  1. Request OIDC token
        │     audience = "sts.aliyuncs.com"
        ▼
GitHub OIDC endpoint
https://token.actions.githubusercontent.com
        │
        │  2. Return signed JWT
        │     sub = "repo:ORG/REPO:ref:refs/heads/main"
        │     aud = "sts.aliyuncs.com"
        │     iss = "https://token.actions.githubusercontent.com"
        ▼
  GitHub Actions step
  aliyun/alibaba-cloud-setup-credentials@v1
        │
        │  3. POST token to STS AssumeRoleWithOIDC
        ▼
Alibaba Cloud STS
        │
        │  4. Validate token signature against RAM OIDC Provider thumbprint
        │  5. Validate aud + sub claim conditions
        │  6. Return temp creds (AccessKey + SecretKey + SecurityToken, 1h TTL)
        ▼
  Terraform provider picks up creds via environment variables
  ALICLOUD_ACCESS_KEY, ALICLOUD_SECRET_KEY, ALICLOUD_SECURITY_TOKEN
```

### RAM OIDC Provider configuration

| Field | Value |
|-------|-------|
| Provider name | `GitHubActions` |
| Issuer URL | `https://token.actions.githubusercontent.com` |
| Fingerprint | Fetched dynamically by `setup-oidc.sh` |
| Allowed audiences | `sts.aliyuncs.com` |

### RAM Role trust policy

```json
{
  "Statement": [
    {
      "Action": "sts:AssumeRoleWithOIDC",
      "Effect": "Allow",
      "Principal": {
        "Federated": ["acs:ram::ACCOUNT_ID:oidc-provider/GitHubActions"]
      },
      "Condition": {
        "StringEquals": {
          "oidc:aud": "sts.aliyuncs.com"
        },
        "StringLike": {
          "oidc:sub": "repo:YOUR_ORG/cloud-lz-deployment-workflow:*"
        }
      }
    }
  ],
  "Version": "1"
}
```

The `StringLike` condition on `oidc:sub` ensures only workflows from **this
specific repository** can assume the role.  Tighten further by restricting to a
specific branch or environment:

```json
"oidc:sub": "repo:YOUR_ORG/cloud-lz-deployment-workflow:ref:refs/heads/main"
```

### One-time setup

```bash
export ALICLOUD_ACCOUNT_ID="123456789012"
export GITHUB_ORG="your-org"
export GITHUB_REPO="cloud-lz-deployment-workflow"
export ALICLOUD_REGION="cn-hangzhou"

./scripts/setup-oidc.sh
```

The script outputs the three GitHub variable values to configure (see §5).

---

## 4. Repository Structure

```
.
├── .github/
│   ├── actions/
│   │   └── tf-init/
│   │       └── action.yml        # Composite: download source + setup-terraform + OIDC + init
│   └── workflows/
│       ├── lz-pr-validate.yml    # Runs on every PR → validate + plan
│       ├── lz-deploy.yml         # Merge to main / manual → plan + apply
│       ├── lz-drift-detect.yml   # Daily cron → detect config drift
│       └── lz-destroy.yml        # Manual only → guarded destroy
│
├── terraform/
│   └── environments/
│       └── landing-zone/
│           ├── README.md                      # Drop-zone instructions
│           ├── backend.tf                     # OSS backend template
│           ├── landing-zone.tfvars            # Environment values (committed)
│           └── landing-zone.tfvars.example    # Reference template
│           └── <Alibaba LZ IaC files here>    # Provided by Alibaba Cloud
│
├── scripts/
│   ├── setup-oidc.sh                # Creates RAM OIDC Provider + Role
│   ├── bootstrap-state-backend.sh   # Creates OSS bucket + TableStore
│   └── validate-prereqs.sh          # Checks runner readiness
│
└── README.md
```

---

## 5. GitHub Repository Configuration

### Required Permissions

The workflows require `id-token: write` at the workflow level.  This is already
set in each workflow file.  Your GitHub Enterprise Cloud organisation policy
must **not** block OIDC token generation.

### Variables (Settings → Secrets and variables → Actions → Variables)

These are non-sensitive and stored as plain variables, not secrets.

| Variable | Description | Example |
|----------|-------------|---------|
| `ALICLOUD_REGION` | Primary deployment region | `cn-hangzhou` |
| `ALICLOUD_OIDC_PROVIDER_ARN` | Full ARN of the RAM OIDC Provider | `acs:ram::123456789012:oidc-provider/GitHubActions` |
| `ALICLOUD_OIDC_ROLE_ARN` | Full ARN of the deployment RAM Role | `acs:ram::123456789012:role/github-lz-deploy` |
| `TF_STATE_BUCKET` | OSS bucket name for Terraform state | `acme-lz-tfstate` |
| `TF_LOCK_TABLESTORE_ENDPOINT` | TableStore HTTPS endpoint | `https://acme-lz-tflock.cn-hangzhou.ots.aliyuncs.com` |
| `TF_LOCK_TABLE` | TableStore table name for locking | `terraform-lock` |

### Environments (Settings → Environments)

Create three environments with the following protection rules:

#### `lz-plan`
- No required reviewers
- Allowed branches: `main`, `feature/*`
- Purpose: gates the terraform plan job (provides separation of OIDC session)

#### `lz-deploy`
- **Required reviewers**: minimum 1 (e.g., platform-lead or a team)
- **Allowed branches**: `main` only
- **Wait timer**: optional (e.g., 5 minutes for last-chance cancel)
- Purpose: human approval gate before terraform apply

#### `lz-destroy`
- **Required reviewers**: minimum 2 (senior team members)
- **Allowed branches**: `main` only
- **Deployment branch policy**: selected branches (`main`)
- Purpose: approval gate for destructive operations

### Branch Protection (Settings → Branches → `main`)

| Rule | Value |
|------|-------|
| Require PR before merging | ✓ |
| Require status checks | `Static Analysis`, `Terraform Plan` |
| Require branches to be up to date | ✓ |
| Restrict force pushes | ✓ |
| Restrict deletions | ✓ |
| Require linear history | recommended |

---

## 6. Workflows

### `lz-pr-validate.yml` – PR Validation

Runs on every PR targeting `main` that modifies `terraform/**`.

```
PR opened / updated
       │
       ▼
[corporate runner] fetch-source
       │  Upload artifact
       ▼
[cloud runner] static-analysis
       │  terraform fmt -check
       │  terraform validate
       │  checkov security scan (SARIF → Security tab)
       │
       ▼
[cloud runner] plan  (environment: lz-plan)
       │  OIDC → STS credentials
       │  terraform init (OSS backend)
       │  terraform plan -out tfplan
       │  Post plan summary as PR comment
       ▼
      Done
```

**Outcome**: reviewer sees plan output inline on the PR before approving merge.

---

### `lz-deploy.yml` – Deploy

Triggers on:
- Push to `main` (IaC file changes)
- `workflow_dispatch` (manual, for Day-1 or targeted runs)

```
Push to main / manual trigger
       │
       ▼
[corporate runner] fetch-source
       │
       ▼
[cloud runner] plan  (environment: lz-plan)
       │  OIDC → STS
       │  terraform plan -out tfplan
       │  Detect if changes exist
       │
       ▼ (if changes detected)
[cloud runner] await-approval  (environment: lz-deploy)
       │  ← Human approval required here
       │
       ▼
[cloud runner] apply
       │  Fresh OIDC → STS (previous session may have expired)
       │  terraform apply tfplan   (applies the exact saved plan)
       │  Upload apply log (retained 30 days)
       ▼
      Done
```

Key design decisions:
- The **exact plan binary** produced in the plan job is downloaded and applied –
  no re-plan on apply, ensuring what was reviewed is what gets applied.
- `concurrency: cancel-in-progress: false` prevents a deploy from being
  cancelled mid-run by a subsequent push.
- Fresh OIDC token is obtained for the apply job independently (STS tokens
  are valid for 1 hour; the approval wait may exceed this).

---

### `lz-drift-detect.yml` – Drift Detection

Runs daily at 04:00 UTC.  Can also be triggered manually.

- Runs `terraform plan -detailed-exitcode`
- Exit code 2 = changes detected (drift)
- Creates or updates a GitHub Issue labelled `drift-alert` if drift is found
- Uploads the full plan output as an artifact (retained 14 days)

---

### `lz-destroy.yml` – Emergency Destroy

**Manual trigger only.**  Hard-gated by:

1. Confirmation string `DESTROY-LANDING-ZONE` required as input
2. GitHub Environment `lz-destroy` with ≥2 required reviewers
3. Audit trail: reason field is mandatory and captured in the workflow log

Use only for full environment decommission or DR exercises.

---

## 7. Day-1 Setup Procedure

Follow these steps **in order**.  Steps 1–4 run on an operator workstation or
on the cloud runner VM itself (whichever has `aliyun` CLI configured).
Steps 5 onward require the runners to be registered and healthy first.

```
Workstation / cloud runner VM          GitHub                  Alibaba Cloud
──────────────────────────────         ──────                  ─────────────
Step 1: aliyun configure
Step 2: setup-oidc.sh          ──────────────────────────▶  Creates OIDC Provider + Role
Step 3: bootstrap-state.sh     ──────────────────────────▶  Creates OSS bucket + TableStore
Step 4: runner registration    ──────────────────────────▶  Runner appears in GHEC
Step 5: drop in LZ IaC
Step 6: configure tfvars + commit
Step 7: gh workflow run        ──────────────────────────▶  Pipeline runs on runner
                                                              ▼ OIDC auth
                                                              ▼ terraform apply
Step 8: revoke bootstrap creds ──────────────────────────▶  Disable static AK/SK
```

### Step 1 – Provision and register self-hosted runners

Before anything else, both VMs must be running and registered.
Follow §2 (Runner Architecture) for:
- VM provisioning and software installation
- Runner agent download and `./config.sh` registration
- Runner group setup in GHEC

Verify both runners appear as **Idle** in:
**Org → Settings → Actions → Runners**

Then confirm the cloud runner is ready:
```bash
# On the cloud runner VM:
./scripts/validate-prereqs.sh
```

All checks must pass before continuing.

### Step 2 – Configure Alibaba Cloud CLI (bootstrap credentials only)

On your workstation or the cloud runner VM:

```bash
aliyun configure
# Enter: AccessKey ID, AccessKey Secret, Region (e.g. cn-hangzhou)
# These credentials are used ONLY for Steps 3–4 below.
# They are revoked in Step 9.
```

The account used here needs RAM admin permissions to create the OIDC Provider,
Role, OSS bucket, and TableStore instance.

### Step 3 – Create OIDC Provider and Deployment Role

```bash
export ALICLOUD_ACCOUNT_ID="<your-account-id>"
export GITHUB_ORG="<your-github-org>"
export GITHUB_REPO="cloud-lz-deployment-workflow"
export ALICLOUD_REGION="cn-hangzhou"

./scripts/setup-oidc.sh
```

The script prints three values at the end.  Add them to:
**GitHub repo → Settings → Secrets and variables → Actions → Variables**

| Variable | Value from script output |
|----------|--------------------------|
| `ALICLOUD_OIDC_PROVIDER_ARN` | `acs:ram::...:oidc-provider/GitHubActions` |
| `ALICLOUD_OIDC_ROLE_ARN` | `acs:ram::...:role/github-lz-deploy` |
| `ALICLOUD_REGION` | e.g. `cn-hangzhou` |

### Step 4 – Bootstrap Terraform State Backend

```bash
export ALICLOUD_ACCOUNT_ID="<your-account-id>"
export ALICLOUD_REGION="cn-hangzhou"
export STATE_BUCKET_NAME="<your-org>-lz-tfstate"
export TABLESTORE_INSTANCE="<your-org>-lz-tflock"
export TABLESTORE_TABLE="terraform-lock"

./scripts/bootstrap-state-backend.sh
```

Add the three output values to GitHub repository Variables:

| Variable | Value from script output |
|----------|--------------------------|
| `TF_STATE_BUCKET` | OSS bucket name |
| `TF_LOCK_TABLESTORE_ENDPOINT` | TableStore HTTPS endpoint |
| `TF_LOCK_TABLE` | Table name (`terraform-lock`) |

### Step 5 – Drop in Alibaba Cloud LZ IaC

Place the Alibaba Cloud–provided LZ IaC files into:
```
terraform/environments/landing-zone/
```

See `terraform/environments/landing-zone/README.md` for the expected layout.

### Step 6 – Configure and commit variable values

```bash
cp terraform/environments/landing-zone/landing-zone.tfvars.example \
   terraform/environments/landing-zone/landing-zone.tfvars
# Edit landing-zone.tfvars – fill in account IDs, CIDRs, names, etc.
```

Commit to a feature branch and open a PR.  This triggers `lz-pr-validate` and
posts a Terraform plan as a PR comment so you can review what will be created
before Day-1 apply.

```bash
git checkout -b feat/initial-lz-config
git add terraform/environments/landing-zone/landing-zone.tfvars
git commit -m "chore: initial landing zone variable configuration"
git push -u origin feat/initial-lz-config
# Open PR → review the plan comment → merge to main
```

### Step 7 – Trigger the first deploy

Merging to `main` in Step 6 triggers `lz-deploy.yml` automatically.
Alternatively, trigger manually:

```bash
gh workflow run lz-deploy.yml --ref main
```

The workflow pauses at the **lz-deploy** environment gate.  An approver must
go to **Actions → the run → Review deployments** and approve.  After approval
the apply job runs and creates the landing zone.

### Step 8 – Verify

```bash
# Check the apply log artifact in the completed workflow run
gh run view --log <RUN_ID>

# Confirm state was written
aliyun oss ls oss://<STATE_BUCKET_NAME>/landing-zone/
```

Confirm in the Alibaba Cloud console that the expected resources exist
(Resource Directory folders, VPC, CEN, logging, etc.).

### Step 9 – Revoke bootstrap credentials

The static `AccessKey`/`SecretKey` used in Steps 2–4 are no longer needed.

```bash
# Disable (preferred – reversible) or delete the bootstrap AK
aliyun ram UpdateAccessKey \
  --UserName <bootstrap-user> \
  --UserAccessKeyId <AK_ID> \
  --Status Inactive
```

All subsequent pipeline runs authenticate exclusively via OIDC → STS.

---

## 8. State Backend

| Component | Alibaba Cloud Service | Purpose |
|-----------|----------------------|---------|
| State file | OSS (Object Storage) | Stores `terraform.tfstate` |
| State locking | TableStore (OTS) | Prevents concurrent modifications |

**State key**: `landing-zone/terraform.tfstate`

Backend configuration is injected at runtime via `-backend-config` flags in the
workflow – no sensitive values are hardcoded in `backend.tf`.

### State recovery

If the state lock is stuck (e.g., after a runner crash):

```bash
# Force-unlock (use with caution – confirm no other operation is running)
terraform force-unlock <LOCK_ID> \
  -backend-config="bucket=<bucket>" \
  -backend-config="region=<region>" \
  -backend-config="tablestore_endpoint=<endpoint>" \
  -backend-config="tablestore_table=<table>"
```

Because OSS versioning is enabled on the state bucket, previous state versions
can be recovered from the OSS console if needed.

---

## 9. Security Controls

| Control | Implementation |
|---------|---------------|
| No static credentials | GitHub OIDC → STS temp credentials (1 h TTL) |
| Least-privilege deployment role | RAM Role with scoped policy (tighten `AdministratorAccess` post-bootstrap) |
| Deployment approval gate | GitHub Environment `lz-deploy` with required reviewers |
| Branch protection | PRs + status checks required on `main` |
| Plan-then-apply | Exact plan binary applied; no re-plan on apply |
| Destroy double-gate | Confirmation string + GitHub Environment `lz-destroy` (≥2 reviewers) |
| Drift detection | Daily terraform plan in check mode; auto-issue on drift |
| Code scanning | Checkov on every PR (SARIF → GitHub Security tab) |
| Artifact integrity | Source artifact is packaged and uploaded by the corporate runner; the cloud runner downloads the same artifact |
| State encryption | OSS SSE-AES256 at rest |
| State versioning | OSS bucket versioning enabled (state recovery) |
| Audit trail | Workflow logs + apply log artifacts (30-day retention) |
| Concurrent deploy prevention | `concurrency` group on deploy workflow |

### Hardening the RAM Role (post-bootstrap)

Replace the broad `AdministratorAccess` policy with a custom RAM policy scoped
to only the services and actions the LZ IaC requires.  Typical LZ services:

```
ResourceDirectory:*
RAM:*
VPC:*
CEN:*
SLS:*          (Log Service)
OSS:PutObject, GetObject, ...
ActionTrail:*
CloudMonitor:*
OTS:*          (TableStore – state locking)
```

Create a custom policy and attach it to the role:
```bash
aliyun ram CreatePolicy \
  --PolicyName "github-lz-deploy-policy" \
  --PolicyDocument file://docs/iam-policy.json \
  --Description "Scoped policy for GitHub Actions LZ deployment"

aliyun ram DetachPolicyFromRole \
  --PolicyType System \
  --PolicyName AdministratorAccess \
  --RoleName github-lz-deploy

aliyun ram AttachPolicyToRole \
  --PolicyType Custom \
  --PolicyName github-lz-deploy-policy \
  --RoleName github-lz-deploy
```

---

## 10. Operational Runbook

### Deploying a change

1. Create a feature branch from `main`.
2. Modify `terraform/environments/landing-zone/` or `landing-zone.tfvars`.
3. Open a PR → `lz-pr-validate` runs automatically.
4. Review the Terraform plan posted as a PR comment.
5. Address any Checkov findings in the Security tab.
6. Get PR approved and merge to `main`.
7. `lz-deploy` triggers automatically.  Approve the `lz-deploy` environment gate.
8. Monitor the apply job output.

### Emergency targeted deployment

```bash
gh workflow run lz-deploy.yml \
  --field environment=landing-zone \
  --field target="module.network_foundation" \
  --ref main
```

### Checking for drift manually

```bash
gh workflow run lz-drift-detect.yml --ref main
```

### Recovering from a failed apply

1. Check the apply log artifact in the failed workflow run.
2. Fix the root cause in a feature branch.
3. Open a PR and follow the normal deploy flow.
4. If state is locked, run `terraform force-unlock` (see §8).

### Rotating the deployment role

1. Run `./scripts/setup-oidc.sh` again (it updates the trust policy non-destructively).
2. If updating the role ARN, update the `ALICLOUD_OIDC_ROLE_ARN` GitHub variable.

---

## Glossary

| Term | Meaning |
|------|---------|
| LZ | Landing Zone – foundational Alibaba Cloud account/network structure |
| OIDC | OpenID Connect – used here for keyless GitHub → Alibaba Cloud auth |
| STS | Security Token Service – issues temp credentials from OIDC tokens |
| RAM | Resource Access Management – Alibaba Cloud identity and access service |
| OSS | Object Storage Service – Alibaba Cloud blob storage |
| OTS / TableStore | Alibaba Cloud NoSQL service, used here for Terraform state locking |
| CEN | Cloud Enterprise Network – Alibaba Cloud transit routing |
| SLS | Simple Log Service – centralised logging |
| ActionTrail | Alibaba Cloud audit log service (equivalent of CloudTrail / Activity Log) |
