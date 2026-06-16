/*
Written by Harry Shelton - 2026
Cloudflare Automated Tool Deployment on Azure with Terraform
Version: 1.0

This Terraform configuration deploys a secure and scalable infrastructure on Azure to support an automated Cloudflare backup solution. It includes:
- Resource Groups in UK West and UK South
- Two Storage Accounts (one for DNS backups with Cool tier and one for Customer List with Hot tier)
- An Azure Key Vault for secure credential storage
- An Azure Automation Account with a PowerShell 7.2 runbook for backup operations
- RBAC role assignments to ensure least privilege access for the Automation Account's Managed Identity

*/

# ==========================================
# RESOURCE GROUPS
# ==========================================

resource "azurerm_resource_group" "west" {
  name     = var.rg_west_name
  location = var.location_west
}

resource "azurerm_resource_group" "south" {
  name     = var.rg_south_name
  location = var.location_south
}

# ==========================================
# UK WEST RESOURCES
# ==========================================

# Storage Account - DNS Backup
resource "azurerm_storage_account" "sa_b" {
  name                     = var.storage_account_dnsbackup_name
  resource_group_name      = azurerm_resource_group.west.name
  location                 = azurerm_resource_group.west.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"

  blob_properties {
    versioning_enabled = true
  }

  #Firewall Rules
  network_rules {
    default_action = "Deny"
    ip_rules       = var.allowed_ips
    bypass         = ["AzureServices"]
  }
}

#Blob Container in DNS Backup Storage Account
resource "azurerm_storage_container" "dns_backups" {
  name                  = "dns-backups"
  storage_account_id    = azurerm_storage_account.sa_b.id
  container_access_type = "private"
}

#Lifecycle Management Policy (for cleanup of old verioons)
resource "azurerm_storage_management_policy" "dns_backups_policy" {
  storage_account_id = azurerm_storage_account.sa_b.id

  rule {
    name    = "delete-versions-after-60-days"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["dns-backups/"]
    }

    actions {
      version {
        change_tier_to_cool_after_days_since_creation       = 3
        tier_to_cold_after_days_since_creation_greater_than = 30
        delete_after_days_since_creation                    = 60
      }
    }
  }
}

# Storage Account - Customer List
resource "azurerm_storage_account" "sa_a" {
  name                     = var.storage_account_customerlist_name
  resource_group_name      = azurerm_resource_group.west.name
  location                 = azurerm_resource_group.west.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"
}

# Azure Table in Customer List Storage Account
resource "azurerm_storage_table" "protected_customers" {
  name                 = "ProtectedCustomers"
  storage_account_name = azurerm_storage_account.sa_a.name
}

# Azure Key Vault
resource "azurerm_key_vault" "kv" {
  name                        = var.key_vault_name
  location                    = azurerm_resource_group.west.location
  resource_group_name         = azurerm_resource_group.west.name
  enabled_for_disk_encryption = true
  # Allows ARM template deployments (the Logic App) to resolve secret values via
  # Key Vault references at deploy time, so secrets never pass through Terraform state.
  enabled_for_template_deployment = true
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days      = 7
  purge_protection_enabled        = false
  sku_name                        = "standard"
  rbac_authorization_enabled      = true
}

# ==========================================
# UK SOUTH RESOURCES
# ==========================================

# Azure Automation Account (with Managed Identity)
resource "azurerm_automation_account" "aa" {
  name                = var.automation_account_name
  location            = azurerm_resource_group.south.location
  resource_group_name = azurerm_resource_group.south.name
  sku_name            = "Basic"

  # Enables the System-Assigned Managed Identity
  identity {
    type = "SystemAssigned"
  }
}

# PowerShell Module Import: Az.Accounts
# Provides Connect-AzAccount, Get-AzAccessToken, Get-AzContext (and is the auth
# dependency for Az.KeyVault / Az.Storage, which ship with the runtime's built-in Az set).
#
# IMPORTANT: the version is pinned. An unpinned ".../package/Az.Accounts" URI imports
# whatever is "latest", which is a newer MAJOR (3.x/4.x/5.x) than the Az.KeyVault/Az.Storage
# built into the PowerShell 7.2 runtime. The version mismatch breaks the module's assembly
# load context ("Unable to find type [...AzAssemblyLoadContextInitializer]"), which makes
# Connect-AzAccount fail to register and every downstream Az* cmdlet report
# "context has not been properly initialized". 2.19.0 is the latest 2.x and stays
# major-aligned with the built-in modules.
resource "azurerm_automation_powershell72_module" "az_accounts" {
  name                  = "Az.Accounts"
  automation_account_id = azurerm_automation_account.aa.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Az.Accounts/${var.az_accounts_version}"
  }
}

# PowerShell 7.2 Runbook
resource "azurerm_automation_runbook" "ps72_runbook" {
  name                    = "Backup-CloudflareDNS"
  location                = azurerm_resource_group.south.location
  resource_group_name     = azurerm_resource_group.south.name
  automation_account_name = azurerm_automation_account.aa.name
  log_verbose             = true
  log_progress            = true
  description             = "PS 7.2 runbook pulled from a local file"
  runbook_type            = "PowerShell72"

  # Reads the script directly from a local .ps1 file - ensure script exists within the SAME folder as this main.tf and is named "Backup-CloudflareDNS.ps1"
  content = file("${path.module}/Backup-CloudflareDNS.ps1")
}

# ==========================================
# RBAC ROLE ASSIGNMENTS FOR THE AA MANAGED IDENTITY and DEPLOYERS
# ==========================================

# 1. Key Vault Assignments
resource "azurerm_role_assignment" "kv_contributor" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Contributor"
  principal_id         = azurerm_automation_account.aa.identity[0].principal_id
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_automation_account.aa.identity[0].principal_id
}

# 2. DNS Backup Storage Account Assignments (sa_b)
resource "azurerm_role_assignment" "backup_sa_contributor" {
  scope                = azurerm_storage_account.sa_b.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = azurerm_automation_account.aa.identity[0].principal_id
}

resource "azurerm_role_assignment" "backup_blob_contributor" {
  scope                = azurerm_storage_account.sa_b.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_automation_account.aa.identity[0].principal_id
}

# 3. Customer List Storage Account Assignments (sa_a)
resource "azurerm_role_assignment" "customer_table_reader" {
  scope                = azurerm_storage_account.sa_a.id
  role_definition_name = "Storage Table Data Reader"
  principal_id         = azurerm_automation_account.aa.identity[0].principal_id
}

# 4. Deployer Assignments (So you don't lock yourself out)
resource "azurerm_role_assignment" "kv_admin_deployer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ==========================================
# LOGIC APP - DNS DRIFT ALERTING (UK WEST)
# ==========================================
# The runbook POSTs drift alerts to this Logic App's HTTP trigger. The workflow then
# (a) emails a shared mailbox via the Office 365 connector and (b) forwards to the
# Cloudflare drift webhook. The workflow body lives in logic-app.template.json; secrets
# are pulled from Key Vault at deploy time via references (never stored in state).

# Office 365 managed API in the West region
data "azurerm_managed_api" "office365" {
  name     = "office365"
  location = azurerm_resource_group.west.location
}

# API connection used by the email action.
# NOTE: Terraform can create this connection, but it cannot complete the OAuth consent.
# After the first apply you MUST open this connection in the Azure portal and authorize it
# with the shared-mailbox account, or the email action will fail at runtime.
resource "azurerm_api_connection" "office365" {
  name                = "office365"
  resource_group_name = azurerm_resource_group.west.name
  managed_api_id      = data.azurerm_managed_api.office365.id
  display_name        = "office365"

  lifecycle {
    # The authorized connection's parameter_values are populated out-of-band (portal OAuth);
    # don't let Terraform try to revert them on subsequent applies.
    ignore_changes = [parameter_values]
  }
}

# Deploy the Logic App workflow from the ARM template. Secret parameters are supplied as
# Key Vault references, so ARM fetches them directly from the vault at deploy time and the
# values are never written to Terraform state or plan output.
resource "azurerm_resource_group_template_deployment" "logic_app" {
  name                = "${var.logic_app_name}-deploy"
  resource_group_name = azurerm_resource_group.west.name
  deployment_mode     = "Incremental"
  template_content    = file("${path.module}/logic-app.template.json")

  parameters_content = jsonencode({
    workflowName          = { value = var.logic_app_name }
    location              = { value = azurerm_resource_group.west.location }
    office365ConnectionId = { value = azurerm_api_connection.office365.id }
    mailboxAddress        = { value = var.alert_mailbox_address }
    toAddress             = { value = var.alert_to_address }
    driftWebhookUri       = { value = var.drift_webhook_uri }

    # Key Vault references - resolved by ARM at deploy time, not by Terraform.
    driftSecret = {
      reference = {
        keyVault   = { id = azurerm_key_vault.kv.id }
        secretName = var.drift_secret_name
      }
    }
    cfAccessClientId = {
      reference = {
        keyVault   = { id = azurerm_key_vault.kv.id }
        secretName = var.cf_access_client_id_secret_name
      }
    }
    cfAccessClientSecret = {
      reference = {
        keyVault   = { id = azurerm_key_vault.kv.id }
        secretName = var.cf_access_client_secret_secret_name
      }
    }
  })

  depends_on = [
    azurerm_api_connection.office365,
    azurerm_role_assignment.kv_admin_deployer
  ]
}