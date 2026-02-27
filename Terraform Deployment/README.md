# Azure Cloudflare Backup & Automation Infrastructure

This is a terraform deployment for this Cloudflare backup tool to speed up, it uses a different method of structure than the basic guide, using two resource groups instead of one. The breakdown is below:

## Resources

**UK West (Data & Secrets)**
* **Resource Group:** Logical container for data resources.
* **Storage Account (Cool Tier):** Stores DNS Backups in a private blob container (`dns-backups`). 
  * Blob Versioning and a Lifecycle Management Policy that automatically deletes versions older than 60 days.
  * Secured via Storage Firewall, restricting access to specified IP addresses.
* **Storage Account (Hot Tier):** Hosts an Azure Table (`ProtectedCustomers`) for client lists.
* **Azure Key Vault:** Secured via RBAC (Role-Based Access Control) to store required secrets.

**UK South (Automation Compute)**
* **Resource Group:** Logical container for compute resources.
* **Azure Automation Account:** Runs serverless scripts using a System-Assigned Managed Identity.
* **PowerShell 7.2 Modules:** Automatically installs `Az.Accounts` and `AzTable`.
* **PowerShell 7.2 Runbook:** Executes a local script (`Get-ProtectedCustomers.ps1`) to process the backups and client lists.

**IAM / RBAC Security**
The Automation Account's Managed Identity is strictly scoped with the following permissions:
* `Key Vault Secrets User` & `Key Vault Contributor` (Key Vault)
* `Storage Blob Data Contributor` & `Storage Account Contributor` (DNS Backup Storage)
* `Storage Table Data Reader` (Customer List Storage)

---

## Prerequisites

Before deploying, ensure you have the following installed and configured:
1. [Terraform](https://developer.hashicorp.com/terraform/downloads) (v1.0.0 or newer)
2. [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
3. You must be logged into the Azure CLI (`az login`) with an account that has `Owner` or `User Access Administrator` permissions on the target subscription (required for assigning IAM roles).

------

## How to Deploy

### 1. Prepare Your Script
Ensure you have your updated PowerShell script named exactly `Backup-CloudflareDNS.ps1` saved in the same directory as these Terraform files. This script will be injected into the Azure Automation Runbook. Make sure it's updated with the variables. View the Wiki for more info.

### 2. Update Variables
Open `variables.tf` (or create a `terraform.tfvars` file) and update the following values:
* Customise the **globally unique names** for the Storage Accounts and Key Vault.
* Update the `allowed_ips` variable with your actual public IP addresses or CIDR blocks (e.g., `/30` or larger) so you don't get locked out by the Storage Account firewall.
* Update the Regions if you want to use different ones; make sure Automation sits in a different region to Storage so the Firewall JIT works as expected.

### 3. Initialise Terraform
Run the following command to download the required AzureRM provider (`v4.x`):
```bash
terraform init
```

### 4. Preview the Changes
Run a plan to verify exactly what Terraform will create:
```bash
terraform plan
```

### 5. Apply the Infrastructure
Deploy the resources to Azure. You will need to type `yes` to confirm:
```bash
terraform apply
```

Once complete, Terraform will output your Key Vault URI, Storage Account names, and the Automation Account details directly in your terminal!

### 6. Final Changes
Once all deployed, you will need to:
1. Enter the Cloudflare API Key into the Key Vault (`CLOUDFLARE-API-KEY`)
2. Fill out your ProtectedCustomers table
    * **PartitionKey:** `Cloudflare` (Static grouping label)
    * **RowKey:** `Customer Name` (e.g., `Contoso` - recommend you match to the Cloudflare Account Name)
    * **AccountId:** `The Cloudflare Account ID String`

---
## Support

Before raising an issue, be sure you've read the complete guides on both Cloudflare and Azure requirements. If you do get an issue, raise an issue with as much info as possible. Ensure that Terraform and Azure CLI (or service connection if using DevOps etc) is installed correctly on the platform (E.g. if you're just deploying from Windows PC).

Wiki goes through the Complete Azure and Cloudflare steps required: 

https://github.com/itsharryshelton/Automated-Cloudflare-Zone-DNS-Backup-Tool/wiki