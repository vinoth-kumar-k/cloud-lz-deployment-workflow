# Alibaba Cloud Landing Zone - Design Document

This repository manages an Alibaba Cloud Landing Zone (LZ) deployment workflow using Terraform and GitHub Actions CI/CD with OIDC authentication. This is intended for deploying the day 1 Alibaba Cloud Landing Zone from GitHub Enterprise within a highly restrictive corporate environment.

## 1. Architecture Overview

The system uses a split runner architecture operating inside a corporate network, with OIDC-based authentication out to Alibaba Cloud.

```
┌─────────────────────────┐         ┌─────────────────────────┐
│ GitHub Enterprise Cloud │         │      Alibaba Cloud      │
│                         │         │                         │
│   ┌─────────────────┐   │         │    ┌───────────────┐    │
│   │ GitHub Actions  │   │ OIDC    │    │ RAM OIDC Role │    │
│   │                 │───┼─────────┼───▶│               │    │
│   └─────────────────┘   │ Auth    │    └───────────────┘    │
│           │             │         │            │            │
└───────────┼─────────────┘         └────────────┼────────────┘
            │                                    │ STS Tokens
            ▼                                    ▼
┌─────────────────────────────────────────────────────────────┐
│                     Corporate Network                       │
│                                                             │
│  ┌───────────────────┐               ┌───────────────────┐  │
│  │ Corporate Runner  │               │   Cloud Runner    │  │
│  │ (self-hosted)     │ Artifacts     │ (self-hosted)     │  │
│  │ - Fetches source  │──────────────▶│ - Runs Terraform  │  │
│  │ - Packages code   │               │ - Connects to API │  │
│  └───────────────────┘               └───────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## 2. Runner Architecture

The deployment leverages two types of self-hosted runners due to corporate constraints (unable to use GitHub-hosted runners for internal resources):

*   **Corporate Runner:** Located deep inside the corporate network. Responsibilities: Code checkout from internal GitHub Enterprise, packaging the IaC files, and uploading them as GitHub artifacts. It never connects to Alibaba Cloud.
*   **Cloud Runner:** Located in the corporate network but has outbound internet access (or proxy access) to Alibaba Cloud API endpoints and GitHub APIs. Responsibilities: Downloads the artifact, performs Terraform operations (init, plan, apply), and exchanges OIDC tokens with Alibaba Cloud STS.

## 3. Authentication (GitHub OIDC)

To comply with high-security standards, **no static cloud credentials (AccessKeys) are stored in GitHub**.
Authentication relies on the GitHub OIDC to Alibaba Cloud STS federation chain:

1.  GitHub Actions requests an OIDC token (`token.actions.githubusercontent.com`).
2.  The workflow POSTs the token to Alibaba Cloud STS (`sts.aliyuncs.com`) using `AssumeRoleWithOIDC`.
3.  Alibaba Cloud RAM validates the token against the configured RAM OIDC Provider.
4.  STS returns short-lived (1-hour) temporary credentials (AccessKey, SecretKey, SecurityToken).
5.  Terraform utilizes these temporary credentials for deployment.

## 4. State Management

Terraform state is managed remotely using Alibaba Cloud native services:

*   **State Backend:** OSS (Object Storage Service) is used to store `terraform.tfstate`. The bucket is private, versioned, and encrypted at rest (SSE-AES256).
*   **State Locking:** TableStore (OTS) is used to prevent concurrent modifications. Note: Table names must comply with `^[a-zA-Z_][a-zA-Z0-9_]{0,254}$` (no hyphens). A table named `terraform_lock` is used.

## 5. Deployment Workflow

The CI/CD pipeline consists of several key workflows:

*   **PR Validation (`lz-pr-validate.yml`):**
    *   Runs on PRs targeting `main` modifying Terraform code.
    *   Corporate runner packages source.
    *   Cloud runner runs static analysis (`terraform fmt`, `terraform validate`, `checkov`).
    *   Cloud runner generates a `terraform plan` and posts it as a PR comment.
*   **Deploy (`lz-deploy.yml`):**
    *   Runs on merge to `main` or manual dispatch.
    *   Generates a plan and halts at the `lz-deploy` environment for human approval.
    *   Upon approval, exactly applies the saved plan artifact.
*   **Drift Detection (`lz-drift-detect.yml`):**
    *   Runs daily (cron) to detect configuration drift (`terraform plan -detailed-exitcode`).
*   **Emergency Destroy (`lz-destroy.yml`):**
    *   Manual trigger only, double-gated with confirmation string and approvals.

## 6. Day-1 Setup Procedure

Before the pipeline can run, manual bootstrap steps are required:

1.  **Runner Setup:** Provision and register both corporate and cloud runner VMs in GitHub Enterprise under a specific runner group (`lz-runners`).
2.  **OIDC Bootstrap (`scripts/setup-oidc.sh`):** Using temporary manual CLI credentials, create the RAM OIDC Provider and Deployment RAM Role in Alibaba Cloud.
3.  **State Backend Bootstrap (`scripts/bootstrap-state-backend.sh`):** Create the OSS bucket and TableStore instance/table.
4.  **Configure GitHub Variables:** Add the generated ARN and Backend details to GitHub repository variables.
5.  **Revoke Bootstrap Credentials:** Remove the manual credentials; all subsequent operations are handled via OIDC.
6.  **First Deployment:** Commit LZ configuration to `landing-zone.tfvars` and trigger the deployment pipeline.
