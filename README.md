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

Two runner labels are used.  Each corresponds to a runner group configured in
GitHub Enterprise Cloud.

| Label | Network | Responsibilities |
|-------|---------|-----------------|
| `self-hosted, corporate` | Inside corporate network | Code checkout from internal repos; package IaC source into artifact |
| `self-hosted, cloud` | Can reach Alibaba Cloud APIs (direct or via proxy) | Terraform init / plan / apply; OIDC credential exchange with STS |

### Why two runner types?

Your corporate policy prevents GitHub-hosted runners from accessing internal
code and package registries.  The self-hosted **corporate** runner solves this
for checkout.  The **cloud** runner only ever receives the packaged artifact
(not raw source) and uses short-lived OIDC credentials; it never stores
long-lived cloud credentials.

### Runner installation checklist

Install on each runner type the tools validated by `scripts/validate-prereqs.sh`:

```
terraform   >= 1.9
aliyun CLI  >= 3.0
curl, jq, git, tar
```

Verify a runner is correctly configured:
```bash
./scripts/validate-prereqs.sh
```

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

Follow these steps in order for first-time deployment.

### Step 0 – Prerequisites

```bash
# On the cloud self-hosted runner (or your workstation):
./scripts/validate-prereqs.sh
```

Confirm all checks pass before proceeding.

### Step 1 – Configure Alibaba Cloud CLI

```bash
aliyun configure
# Enter: AccessKey ID, AccessKey Secret, Region (cn-hangzhou)
# These are ONE-TIME bootstrap credentials – revoke after setup.
```

### Step 2 – Create OIDC Provider and Deployment Role

```bash
export ALICLOUD_ACCOUNT_ID="<your-account-id>"
export GITHUB_ORG="<your-github-org>"
export GITHUB_REPO="cloud-lz-deployment-workflow"
export ALICLOUD_REGION="cn-hangzhou"

./scripts/setup-oidc.sh
```

Copy the output values into GitHub repository Variables (see §5).

### Step 3 – Bootstrap Terraform State Backend

```bash
export ALICLOUD_ACCOUNT_ID="<your-account-id>"
export ALICLOUD_REGION="cn-hangzhou"
export STATE_BUCKET_NAME="<your-org>-lz-tfstate"
export TABLESTORE_INSTANCE="<your-org>-lz-tflock"
export TABLESTORE_TABLE="terraform-lock"

./scripts/bootstrap-state-backend.sh
```

Copy the output values into GitHub repository Variables (see §5).

### Step 4 – Drop in Alibaba Cloud LZ IaC

Place the Alibaba Cloud–provided LZ IaC files into:
```
terraform/environments/landing-zone/
```

Refer to `terraform/environments/landing-zone/README.md` for the expected
layout.

### Step 5 – Configure Variable Values

```bash
cp terraform/environments/landing-zone/landing-zone.tfvars.example \
   terraform/environments/landing-zone/landing-zone.tfvars
# Edit landing-zone.tfvars with your environment values
```

Commit `landing-zone.tfvars` (it contains no secrets).

### Step 6 – Trigger the First Deploy

```bash
# Via GitHub CLI:
gh workflow run lz-deploy.yml \
  --field environment=landing-zone \
  --ref main
```

Or use the GitHub UI: **Actions → LZ – Deploy → Run workflow**.

Monitor the run.  The workflow will pause at the **lz-deploy** environment gate
awaiting human approval before applying.

### Step 7 – Revoke Bootstrap Credentials

After the pipeline is running on OIDC, revoke or disable the static
`AccessKey`/`SecretKey` used in Steps 2–3.  All subsequent CI/CD operations
use OIDC-derived short-lived tokens only.

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
