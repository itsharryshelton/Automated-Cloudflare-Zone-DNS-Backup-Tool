# Serverless Cloudflare DNS Backup for MSPs (Azure Edition)

A highly scalable, multi-tenant, and virtually serverless solution to automatically back up Cloudflare DNS records to Azure Blob Storage. 

Designed specifically for Managed Service Providers (MSPs), this tool handles multiple Cloudflare accounts, dynamically discovers all domains within those accounts, and retains a version-controlled history of DNS records without requiring a single virtual machine.

## Main Bits after being setup
* **100% Serverless:** No VMs, no patching, no Hybrid Workers.
* **Zero-Trust Networking:** Resources remain completely locked down behind Azure Firewalls. The script dynamically whitelists its own worker IP, performs the backup, and closes the firewall behind itself.
* **Native Versioning:** Leverages Azure Blob Versioning to keep an immutable, point-in-time history of all DNS changes.
* **Multi-Tenant:** Uses Azure Table Storage as a lightweight database to manage hundreds of clients easily.
* **Auto-Discovery:** Just provide a client's Cloudflare Account ID, and the script automatically finds and backs up every domain inside it.

---

## The "Cross-Region" Architecture (Crucial)
To maintain a strict Zero-Trust firewall posture without paying for expensive Virtual Networks (VNets) or NAT Gateways, this solution uses a dynamic IP whitelisting script. 

**CRITICAL REQUIREMENT:** Your **Azure Automation Account** must be deployed in a **different Azure Region** than your Storage Account and Key Vault (e.g., Automation in `UK South`, Storage in `UK West`). 

If they are in the same region, Azure routes the traffic over its internal backbone, stripping the public IP address, which causes the firewall whitelist to fail (`403 Forbidden`). Splitting regions forces the traffic over the public internet, allowing the dynamic firewall rules to work perfectly.

---

## Deployment Guide

### Step 1: Prepare the Cloudflare API Token
You need a single Cloudflare API Token scoped to the accounts you wish to back up.

**Required Permissions:**
* `Zone` -> `Zone` -> `Read` 
* `Zone` -> `DNS` -> `Read`

### Step 2: Deploy Azure Storage & Key Vault
1. Create a **Storage Account** (Standard V2). 
   * Go to **Data protection** and check **Enable versioning for blobs**.
   * Create a private container named `dns-backups`.
2. Create a **Key Vault** in the *same region* as the Storage Account.
   * Add your Cloudflare API token as a Secret (e.g., `CLOUDFLARE-API-KEY`).

### Step 3: Configure the Client Table
In your Storage Account, go to **Storage Browser** -> **Tables** and create a table named `ProtectedCustomers`. Add a row for each client:
* **PartitionKey:** `Cloudflare` (Static grouping label)
* **RowKey:** `Customer Name` (e.g., `Contoso` - recommend you match to the Cloudflare Account Name)
* **AccountId:** `The Cloudflare Account ID String`

### Step 4: Deploy the Automation Account (Different Region!)
1. Create an **Azure Automation Account** in a **DIFFERENT REGION** than your storage resources.
2. Under **Identity**, enable the **System assigned managed identity**.
3. Under **Shared Resources** -> **Modules**, ensure the `Az.Accounts`, `Az.KeyVault`, `AzTables` and `Az.Storage` modules are installed and updated (PowerShell 7.2 recommended) - AzTables most likely need manually import from gallery.

### Step 5: Assign Permissions
Grant the Automation Account's Managed Identity the following roles:
* **Key Vault Contributor** (For Updating the Networking)
* **Key Vault Secrets User** (For Reading the Secret)
* **Storage Account Contributor** (For Updating the Networking)
* **Storage Table Data Reader** (For Reading the Client List)
* **Storage Blob Data Contributor** (For Updating the Backup Storage)

### Step 6: Lock Down the Firewalls
1. Go to your **Key Vault** -> **Networking**. Set it to **Allow access from specific virtual networks and IP addresses**. Add your physical office IP (so you can still manage it) and hit Save.
2. Go to your **Storage Account** -> **Networking**. Set it to **Enabled from selected virtual networks and IP addresses**. Add your physical office IP and hit Save.

### Step 7: Create the Runbook
1. Create a PowerShell Runbook in your Automation Account.
2. Paste the provided `Backup-CloudflareDNS.ps1` script (see the script section or repository files).
3. Update the Environment Variables block at the top of the script to match your resource names.
4. Publish and attach a Schedule (e.g., 2:00 AM) - _Note: Massive amounts of zones will take time... make sure your schedule won't overlap if you've got thousands of domains..._

---

## 🛠️ How to Restore a Backup
If a client accidentally deletes a DNS record:
1. Navigate to your Storage Account -> Containers -> `dns-backups`.
2. Open the specific client's folder and click on the domain's `.txt` file.
3. Download the version from the day prior to the outage or requested time. You can re-import this BIND file directly into Cloudflare or open it in a text editor to find the missing record.

---

## 🤝 Contributing
Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.
