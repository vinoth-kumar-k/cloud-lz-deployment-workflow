# Landing Zone IaC Drop-Zone

This directory is the Terraform working directory used by the GitHub Actions
deployment workflows.  **The actual Alibaba Cloud Landing Zone IaC modules are
provided by Alibaba Cloud** and should be placed here.

## What belongs here

| File | Source | Description |
|------|--------|-------------|
| `backend.tf` | This repo | OSS backend config (template – do not edit) |
| `landing-zone.tfvars` | This repo | Environment-specific variable values |
| `landing-zone.tfvars.example` | This repo | Example/reference for the above |
| `main.tf` | Alibaba Cloud LZ IaC | Root module entry point |
| `variables.tf` | Alibaba Cloud LZ IaC | Variable declarations |
| `outputs.tf` | Alibaba Cloud LZ IaC | Output declarations |
| `modules/` | Alibaba Cloud LZ IaC | LZ sub-modules |

## Setup steps

1. Obtain the Alibaba Cloud Landing Zone IaC package.
2. Drop all IaC files into this directory alongside `backend.tf`.
3. Copy `landing-zone.tfvars.example` → `landing-zone.tfvars` and fill in values.
4. Commit `landing-zone.tfvars` (it should contain no secrets).
5. Run the bootstrap script to create the OSS state bucket first:
   ```bash
   ../../scripts/bootstrap-state-backend.sh
   ```
6. Trigger the deploy workflow from GitHub Actions.
