/*
Written by Harry Shelton - 2026
Cloudflare Automated Tool Deployment on Azure with Terraform
Version: 1.0

This Terraform variable file is used alongside the main.tf to define configurable parameters for the deployment of a secure and scalable infrastructure on Azure to support an automated Cloudflare backup solution. 
It includes variables for resource group names, locations, storage account names, key vault name, automation account name, and allowed IP addresses for storage account access. 
The variables have default values that can be overridden during deployment to customise the infrastructure as needed.

*/


variable "location_west" {
  description = "Location for the UK West resources"
  type        = string
  default     = "ukwest"
}

variable "location_south" {
  description = "Location for the UK South resources"
  type        = string
  default     = "uksouth"
}

variable "rg_west_name" {
  description = "Name of the resource group in UK West"
  type        = string
  default     = "rg-cloudflarebackup-ukwest-01"
}

variable "rg_south_name" {
  description = "Name of the resource group in UK South"
  type        = string
  default     = "rg-cloudflarebackup-uksouth-01"
}

variable "storage_account_customerlist_name" {
  description = "Name of Storage Account A (Cool tier). Must be globally unique, 3-24 characters, lowercase letters and numbers only."
  type        = string
  default     = "samspcustomerlist"
}

variable "storage_account_dnsbackup_name" {
  description = "Name of Storage Account B (Hot tier). Must be globally unique, 3-24 characters, lowercase letters and numbers only."
  type        = string
  default     = "samspdnsbackups"
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault. Must be globally unique."
  type        = string
  default     = "kv-ukw-msp-01"
}

variable "automation_account_name" {
  description = "Name of the Azure Automation Account"
  type        = string
  default     = "aa-uksouth-01"
}

variable "allowed_ips" {
  description = "List of public IP addresses or CIDR blocks allowed to access the DNS Backup storage account."
  type        = list(string)
  default     = [
    "203.0.113.50",       # Example single IP
    "198.51.100.22/30"    # Example CIDR block
  ]
}