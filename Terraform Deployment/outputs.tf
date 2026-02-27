# RESOURCE GROUP OUTPUTS
output "resource_group_west" {
  description = "The name of the UK West Resource Group"
  value       = azurerm_resource_group.west.name
}

output "resource_group_south" {
  description = "The name of the UK South Resource Group"
  value       = azurerm_resource_group.south.name
}

# STORAGE ACCOUNT OUTPUTS
output "storage_account_customerlist_name" {
  description = "The name of the Customer List (Hot) Storage Account"
  value       = azurerm_storage_account.sa_a.name
}

output "storage_account_dnsbackup_name" {
  description = "The name of the DNS Backup (Cool) Storage Account"
  value       = azurerm_storage_account.sa_b.name
}

# KEY VAULT OUTPUTS
output "key_vault_uri" {
  description = "The URI of the Key Vault"
  value       = azurerm_key_vault.kv.vault_uri
}

# AUTOMATION ACCOUNT OUTPUTS
output "automation_account_name" {
  description = "The name of the Automation Account"
  value       = azurerm_automation_account.aa.name
}

output "automation_account_principal_id" {
  description = "The Principal ID of the Automation Account's Managed Identity"
  value       = azurerm_automation_account.aa.identity[0].principal_id
}