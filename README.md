# Serverless Cloudflare DNS Backup for MSPs (Azure Edition)

A highly scalable, multi-tenant, and virtually serverless solution to automatically back up Cloudflare DNS records to Azure Blob Storage. 

Designed specifically for Managed Service Providers (MSPs), this tool handles multiple Cloudflare accounts, dynamically discovers all domains within those accounts, and retains a version-controlled history of DNS records without requiring a single virtual machine.

<img width="3197" height="1991" alt="Cloudflare Automated Backup Tool - Diagram" src="https://github.com/user-attachments/assets/40924e77-9e32-4ab0-9a8f-597da3a835ec" />


## Main Bits after being setup
* **Serverless:** No VMs, no patching, no Hybrid Workers.
* **Networking:** Resources remain completely locked down behind Azure Firewalls. The script dynamically whitelists its own worker IP, performs the backup, and closes the firewall behind itself.
* **Native Versioning:** Leverages Azure Blob Versioning to keep a point-in-time history of all DNS changes.
* **Multi-Tenant:** Uses Azure Table Storage as a lightweight database to manage hundreds of clients easily.
* **Auto-Discovery:** Just provide the Client's Name and Cloudflare Account ID to Azure Tables, and the script automatically finds and backs up every domain inside it.

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

<img width="1165" height="445" alt="image" src="https://github.com/user-attachments/assets/f1b6b8e9-324f-4a8c-8e5f-d956aeddbf0e" />


### Step 4: Deploy the Automation Account (Different Region!)
1. Create an **Azure Automation Account** in a **DIFFERENT REGION** than your storage resources.
2. Under **Identity**, enable the **System assigned managed identity**.
3. Under **Shared Resources** -> **Modules**, ensure the `Az.Accounts`, `Az.KeyVault`, `AzTables` and `Az.Storage` modules are installed and updated (PowerShell 7.2) - AzTables most likely need to be manually imported from gallery.

### Step 5: Assign Permissions
Grant the Automation Account's Managed Identity the following roles:
* **Key Vault Contributor** (For Updating the Networking)
* **Key Vault Secrets User** (For Reading the Secret)
<img width="1439" height="883" alt="image" src="https://github.com/user-attachments/assets/d3b8cf8a-10a9-41a0-9db4-d0f634bddd4d" />

* **Storage Account Contributor** (For Updating the Networking)
* **Storage Table Data Reader** (For Reading the Client List)
* **Storage Blob Data Contributor** (For Updating the Backup Storage)
<img width="1286" height="704" alt="image" src="https://github.com/user-attachments/assets/2f5ddc98-e771-4001-bd39-df00da2fec16" />


### Step 6: Lock Down the Firewalls
1. Go to your **Key Vault** -> **Networking**. Set it to **Allow access from specific virtual networks and IP addresses**. Add your physical office IP (so you can still manage it) and hit Save.
2. Go to your **Storage Account** -> **Networking**. Set it to **Enabled from selected virtual networks and IP addresses**. Add your physical office IP and hit Save.

### Step 7: Create the Runbook
1. Create a PowerShell Runbook in your Automation Account.
2. Paste the provided `Backup-CloudflareDNS.ps1` script (see the script section or repository files).
3. Update the Environment Variables block at the top of the script to match your resource names.
4. Publish and attach a Schedule (e.g., 2:00 AM) - _Note: Massive amounts of zones will take time... make sure your schedule won't overlap if you've got thousands of domains..._
5. Once the script is run, you should see your Blob Storage update with the customer and zones
<img width="1144" height="526" alt="image" src="https://github.com/user-attachments/assets/af83d2ab-0373-4e38-981c-f64c6a569338" />


---

## API Limits & Scaling Considerations

This solution is designed to scale natively for Managed Service Providers, but like any cloud architecture, it operates within the boundaries of Microsoft and Cloudflare. If you are managing thousands of domains, keep the following in mind:

### 1. Cloudflare Rate Limits (1,200 requests / 5 mins)
Cloudflare enforces a strict global rate limit. Because this script runs synchronously (downloading and uploading one domain at a time), it takes roughly 1.5 to 2.5 seconds per domain. 
* **The Result:** The script acts as its own natural throttle. It will only process about 150–200 domains every 5 minutes, keeping you comfortably below Cloudflare's 1,200 request threshold. No `429 Too Many Requests` handling is typically required.

### 2. Azure Automation "Fair Share" Limit (3 Hours)
Azure serverless cloud workers have a hard execution limit of **180 minutes (3 hours)**. If a script runs longer than this, Azure will force-kill the job.
* **The Math:** At ~2 seconds per domain, a single runbook can safely process up to **~5,000 domains** per night. 
* **The Fix:** If your MSP grows beyond 5,000 managed domains, simply duplicate the Runbook and split the schedule. (e.g., Have Runbook A process Partition 1 at 1:00 AM, and Runbook B process Partition 2 at 3:00 AM).
* Or.... migrate the script to a Hybrid Runbook Worker, Virtual Machine or a Function App.

### 3. Cloudflare Pagination (500 Domains per Account)
To maximize efficiency, the domain discovery API call uses the `per_page=500` parameter (`https://api.cloudflare.com/...&per_page=500`). 
* **The Limit:** This instantly captures the entire portfolio of 99% of clients in a single API call. However, if you onboard a massive enterprise client with **501+ domains in a single Cloudflare account**, the script will only process the first 500. 
* **The Fix:** For massive single-tenant accounts, you will need to add a `while` loop to the domain discovery block to check `result_info.total_pages` and paginate through `&page=2`, `&page=3`, etc.

---

## Pricing Summary

This solution was designed to be as lightweight as possible, and as cost effective as possible. A summary of breakdown is below:

1 File Version of Domain is roughly 2-5KiB

So keeping 120 versions of 500 domains is about 1GB; Azure Pricing Calculator starts at 1GB, which is about £2.58pm with GRS (Cool Tier).

Azure Key vault will only cost a few pence a month, as it's just hosting a single key

Azure Automation is FREE :D well... for 500 Minutes per Month... then it's £0.002/minute afterwards

Not included on the steps above, but you can also add Azure Backups to this if you want another layer of protection, which is about £1.09 of GRS of 30 Days Kept.

_(Prices are estimates based on rough maths from Azure Calculator and Live Data I can see from my version of this - UK Based in GBP)_

---

## How to Restore a Backup
If a client accidentally deletes a DNS record:
1. Navigate to your Storage Account -> Containers -> `dns-backups`.
2. Open the specific client's folder and click on the domain's `.txt` file.
3. Download the version from the day prior to the outage or requested time. You can re-import this BIND file directly into Cloudflare or open it in a text editor to find the missing record.

---

## 🤝 Contributing
Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.
