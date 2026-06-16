# Azure Cloudflare Backup & Automation Infrastructure

This is a terraform deployment for this Cloudflare backup tool to speed up, it uses a different method of structure than the basic guide, using two resource groups instead of one. The breakdown is below:

## Resources

**UK West (Data, Secrets & Alerting)**
* **Resource Group:** Logical container for data resources.
* **Storage Account (Cool Tier):** Stores DNS Backups in a private blob container (`dns-backups`). 
  * Blob Versioning and a Lifecycle Management Policy that automatically deletes versions older than 60 days.
  * Secured via Storage Firewall, restricting access to specified IP addresses.
* **Storage Account (Hot Tier):** Hosts an Azure Table (`ProtectedCustomers`) for client lists.
* **Azure Key Vault:** Secured via RBAC (Role-Based Access Control) to store required secrets.
* **Logic App (Consumption):** Receives drift alerts from the runbook (HTTP trigger) and sends an email via the Office 365 connector. Optionally forwards drift details to an external webhook. Defined in `logic-app.template.json` and deployed via an ARM template deployment; its secrets are read from Key Vault at deploy time.

**UK South (Automation Compute)**
* **Resource Group:** Logical container for compute resources.
* **Azure Automation Account:** Runs serverless scripts using a System-Assigned Managed Identity.
* **PowerShell 7.2 Module:** Imports `Az.Accounts` (version-pinned via the `az_accounts_version` variable - see the comment in `main.tf` for why pinning matters). `Az.KeyVault` and `Az.Storage` come from the runtime's built-in Az module set.
* **PowerShell 7.2 Runbook:** Executes the local `Backup-CloudflareDNS.ps1` script to process the backups, drift detection and alerting.

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
Ensure you have your updated PowerShell script named exactly `Backup-CloudflareDNS.ps1` saved in the same directory as these Terraform files. This script will be injected into the Azure Automation Runbook. Make sure it's updated with the variables.

### 2. Update Variables
Copy the example tfvars file and edit your values (this keeps your real values out of git, since `terraform.tfvars` is gitignored):
```bash
cp terraform.tfvars.example terraform.tfvars
```
Then update the following (all defaults are obvious `yourmsp` / `yourcompany.com` / example-IP placeholders that **must** be changed):
* Customise the **globally unique names** for the Storage Accounts and Key Vault.
* Update the `allowed_ips` variable with your actual public IP addresses or CIDR blocks (e.g., `/30` or larger) so you don't get locked out by the Storage Account firewall. The defaults are RFC 5737 documentation ranges and will **not** work.
* Set the alerting values (`alert_mailbox_address`, `alert_to_address`) and, if used, `drift_webhook_uri`.
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

### Key Vault secrets (create BEFORE applying)
The Logic App deployment reads its secrets from Key Vault by reference, so these must exist in the vault **before** `terraform apply` (the vault itself is created on a first apply - so on a brand-new environment, apply once to create the vault, add the secrets, then apply again to deploy the Logic App):

| Secret name | Purpose |
| :--- | :--- |
| `CLOUDFLARE-API-KEY` | Cloudflare API token used by the runbook. |
| `EMAIL-WEBHOOK-URL` | The Logic App's HTTP **trigger callback URL** (see step 4 below) - the runbook POSTs alerts here. |
| `DRIFT-SECRET` | `x-drift-secret` header value for the optional external drift webhook. |
| `CF-ACCESS-CLIENT-ID` | `CF-Access-Client-Id` header for the optional external drift webhook. |
| `CF-ACCESS-CLIENT-SECRET` | `CF-Access-Client-Secret` header for the optional external drift webhook. |

> If you removed the `Cloudflare_D1_Drift` action from `logic-app.template.json`, the three drift/Access secrets are not required. D1 Drift is only used if you're using the A.R.G.U.S Partner Portal.

### 6. Final Changes
Once all deployed, you will need to:
1. Enter the Cloudflare API Key into the Key Vault (`CLOUDFLARE-API-KEY`).
2. Fill out your ProtectedCustomers table
    * **PartitionKey:** `Cloudflare` (Static grouping label)
    * **RowKey:** `Customer Name` (e.g., `Contoso` - recommend you match to the Cloudflare Account Name)
    * **AccountId:** `The Cloudflare Account ID String`
3. **Authorise the Office 365 connection.** Terraform creates the `office365` API connection but cannot complete the OAuth consent. Open it in the portal (see the `office365_connection_id` output) and sign in as the shared mailbox, or the email action will fail at runtime.
4. **Store the Logic App trigger URL.** Retrieve the workflow's HTTP trigger callback URL and save it as the `EMAIL-WEBHOOK-URL` secret so the runbook can call it:
5. Put your Runbook Schedule in if you wanted automatic backups.

---
## Support

Before raising an issue, be sure you've read the complete guides on both Cloudflare and Azure requirements. If you do get an issue, raise an issue with as much info as possible. Ensure that Terraform and Azure CLI (or service connection if using DevOps etc) is installed correctly on the platform (E.g. if you're just deploying from Windows PC).