# -----------------------------------------------------------
# Terraform Remote State Backend – Alibaba Cloud OSS
#
# This file is a template. The actual bucket name, region,
# and TableStore endpoint are injected at runtime by the
# GitHub Actions workflow via -backend-config flags.
#
# Do NOT hardcode sensitive values here.  All backend config
# is sourced from GitHub Actions variables (vars.*).
#
# Locking: Alibaba Cloud TableStore (equivalent of DynamoDB
# for AWS or Azure Blob leases for Azure).
# -----------------------------------------------------------
terraform {
  backend "oss" {
    # Values supplied at workflow runtime via -backend-config:
    #   bucket                = <vars.TF_STATE_BUCKET>
    #   prefix                = "landing-zone/terraform.tfstate"
    #   region                = <vars.ALICLOUD_REGION>
    #   tablestore_endpoint   = <vars.TF_LOCK_TABLESTORE_ENDPOINT>
    #   tablestore_table      = <vars.TF_LOCK_TABLE>
  }

  required_version = ">= 1.9"

  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.230"
    }
  }
}

provider "alicloud" {
  # Credentials are injected by the OIDC action as environment
  # variables: ALICLOUD_ACCESS_KEY, ALICLOUD_SECRET_KEY,
  # ALICLOUD_SECURITY_TOKEN, ALICLOUD_REGION.
  # No static credentials should ever appear in this file.
}
