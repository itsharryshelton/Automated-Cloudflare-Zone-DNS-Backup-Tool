/*
Written by Harry Shelton - 2026
Cloudflare Automated Tool Deployment on Azure with Terraform
Version: 1.1

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
  description = "Name of Storage Account A. Must be globally unique, 3-24 characters, lowercase letters and numbers only. CHANGE ME."
  type        = string
  default     = "yourmspcustomerlist"
}

variable "storage_account_dnsbackup_name" {
  description = "Name of Storage Account B (Hot tier). Must be globally unique, 3-24 characters, lowercase letters and numbers only. CHANGE ME."
  type        = string
  default     = "yourmspdnsbackups"
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault. Must be globally unique, 3-24 characters. CHANGE ME."
  type        = string
  default     = "yourmsp-cf-kv-01"
}

variable "automation_account_name" {
  description = "Name of the Azure Automation Account"
  type        = string
  default     = "aa-cloudflare-uks-01"
}

variable "az_accounts_version" {
  description = "Az.Accounts module version to import into the PowerShell 7.2 runtime. Pin to a 2.x build to stay major-version aligned with the Az.KeyVault/Az.Storage modules built into the runtime; newer majors break the assembly load context."
  type        = string
  default     = "2.19.0"
}

# ----------------------------------------------------------------------------
# Logic App (DNS drift alerting) - deployed in UK West
# ----------------------------------------------------------------------------

variable "logic_app_name" {
  description = "Name of the Consumption Logic App that sends drift alert emails."
  type        = string
  default     = "la-cloudflare-drift-alerts-ukw-01"
}

variable "alert_mailbox_address" {
  description = "Shared mailbox the drift alert email is sent FROM (must match the authorized Office 365 connection). CHANGE ME."
  type        = string
  default     = "cloudflare-alerts@yourcompany.com"
}

variable "alert_to_address" {
  description = "Recipient of the drift alert email. CHANGE ME."
  type        = string
  default     = "servicedesk@yourcompany.com"
}

variable "drift_webhook_uri" {
  description = "Optional: external webhook endpoint the Logic App also POSTs drift details to (e.g. a custom dashboard). Not a secret, but environment-specific. CHANGE ME, or remove the Cloudflare_D1_Drift action from logic-app.template.json if you don't use one."
  type        = string
  default     = "https://your-drift-endpoint.example.com/drift/api/webhook"
}

# Names of the Key Vault secrets that hold the Logic App's outbound credentials.
variable "drift_secret_name" {
  description = "Key Vault secret name holding the x-drift-secret header value."
  type        = string
  default     = "DRIFT-SECRET"
}

variable "cf_access_client_id_secret_name" {
  description = "Key Vault secret name holding the CF-Access-Client-Id header value."
  type        = string
  default     = "CF-ACCESS-CLIENT-ID"
}

variable "cf_access_client_secret_secret_name" {
  description = "Key Vault secret name holding the CF-Access-Client-Secret header value."
  type        = string
  default     = "CF-ACCESS-CLIENT-SECRET"
}

#Firewall IPs; set out of range on purpose to fail terraform deployment to ensure you update these before using the Terraform code.
variable "allowed_ips" {
  description = "List of public IP addresses or CIDR blocks allowed to access the DNS Backup storage account. CHANGE ME - replace these ranges with your own egress IPs or you will be locked out by the storage firewall."
  type        = list(string)
  default = [
    "703.0.713.0/29",
    "798.51.700.70"
  ]
}
