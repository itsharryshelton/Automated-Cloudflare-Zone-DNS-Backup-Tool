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
  access_tier              = "Cool"

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

# Blob Container in DNS Backup Storage Account
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
        delete_after_days_since_creation = 60
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
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  sku_name                    = "standard"
  rbac_authorization_enabled   = true 
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

# PowerShell Module Import: Az.Accounts (Required dependency for AzTable, might not be enabled by default.)
resource "azurerm_automation_powershell72_module" "az_accounts" {
  name                  = "Az.Accounts"
  automation_account_id = azurerm_automation_account.aa.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Az.Accounts"
  }
}

# PowerShell Module Import: AzTable
resource "azurerm_automation_powershell72_module" "az_table" {
  name                  = "AzTable"
  automation_account_id = azurerm_automation_account.aa.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/AzTable"
  }

  # Ensures Az.Accounts finishes installing before AzTable begins
  depends_on = [
    azurerm_automation_powershell72_module.az_accounts
  ]
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