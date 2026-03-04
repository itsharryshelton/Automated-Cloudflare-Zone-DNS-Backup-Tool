# Serverless Cloudflare DNS Backup for MSPs (Azure Edition)

_Latest Version: 2.1.0_

A highly scalable, multi-tenant, and virtually serverless solution to automatically back up Cloudflare DNS records to Azure Blob Storage and check for drift, then send an alert if there was a change.

This tool handles multiple Cloudflare accounts and zones, dynamically discovers all domains within those accounts, and retains a version-controlled history of DNS records without requiring a single virtual machine. Then sends you an alert if drift is detected.

<img width="3954" height="2648" alt="Cloudflare Automated Backup Tool - Diagram with engineer access website" src="https://github.com/user-attachments/assets/446b328b-1c59-4973-84df-1b0f335e86a0" />

## Main Bits after being setup
* **Serverless:** No VMs, no patching, no Hybrid Workers.
* **Networking:** Resources remain completely locked down behind Azure Firewalls. The script dynamically whitelists its own worker IP, performs the backup, and closes the firewall behind itself.
* **Native Versioning:** Leverages Azure Blob Versioning to keep a point-in-time history of all DNS changes.
* **Multi-Tenant:** Uses Azure Table Storage as a lightweight database to manage hundreds of clients easily.
* **Auto-Discovery:** Just provide the Client's Name and Cloudflare Account ID to Azure Tables, and the script automatically finds and backs up every domain inside it.
* **Custom Front End:** For easier engineering onboarding, a frontend protected in Cloudflare and hosted in Cloudflare Workers.
<img width="664" height="759" alt="image" src="https://github.com/user-attachments/assets/943e4bd9-1972-4356-9366-503780286454" />


---

## The "Cross-Region" Architecture (Crucial)
To maintain a strict Zero-Trust firewall posture without paying for expensive Virtual Networks (VNets) or NAT Gateways, this solution uses a dynamic IP whitelisting script. 

**CRITICAL REQUIREMENT:** Your **Azure Automation Account** must be deployed in a **different Azure Region** than your Storage Account and Key Vault (e.g., Automation in `UK South`, Storage in `UK West`). 

If they are in the same region, Azure routes the traffic over its internal backbone, stripping the public IP address, which causes the firewall whitelist to fail (`403 Forbidden`). Splitting regions forces the traffic over the public internet, allowing the dynamic firewall rules to work perfectly.

---

## Deployment Guide

Review the Wiki Section of this Repo for complete guides for each section of this design.

---

## API Limits & Scaling Considerations

This solution is designed to scale natively for MSPs. However, like any cloud architecture, it operates within the boundaries of the underlying platforms (Microsoft Azure and Cloudflare). 

If you are managing hundreds or thousands of domains, you must factor in the following constraints and scaling strategies:

### Platform Constraints & Mitigation Strategies

| Platform & Constraint | Hard Limit | The Operational Impact | Architectural Fix / Mitigation |
| :--- | :--- | :--- | :--- |
| **Cloudflare** <br> Global Rate Limit | **1,200 req** <br> per 5 mins | Because this script runs synchronously (processing one domain at a time), it takes roughly 1.5 to 2.5 seconds per domain. It acts as its own natural throttle, processing only ~150–200 domains every 5 minutes. | **None Required:** The synchronous nature of PowerShell keeps you comfortably below the 1,200 request threshold. No `429 Too Many Requests` handling is typically needed. |
| **Azure Automation** <br> "Fair Share" Limit | **3 Hours** <br> (180 mins) | Azure serverless cloud workers have a hard execution limit of 3 hours. If a script runs longer than this, Azure will force-kill the job and flag it as "Suspended." | **Horizontal Scaling:** At ~5 seconds per domain (including drift detection), a single runbook can safely process **~2,100 domains**. If you grow beyond this, duplicate the runbook to split the schedule (e.g., Runbook A at 1:00 AM, Runbook B at 3:00 AM), or migrate the compute engine to an Azure Hybrid Worker. |


---

## FinOps

This solution was purpose-built with a serverless, consumption-based architecture. The monthly compute and storage overhead is virtually zero or less than a price of coffee in London a month for most MSPs.

### Estimated Monthly Breakdown

| Azure Service | Estimated Cost (GBP) | Billing Mechanics & Free Tiers |
| :--- | :--- | :--- |
| **Azure Storage (Blob)** | ~£2.58 / mo | **Data Payload:** 1 version of a domain BIND file is ~2-5KiB. Retaining 120 days of history for 500 domains equates to ~300MB. Pricing is based on Azure's 1GB minimum using Geo-Redundant Storage (GRS). |
| **Azure Storage (Table)** | < £0.05 / mo | **Config Database:** Table storage is billed at fractions of a penny per 10,000 transactions. |
| **Azure Key Vault** | < £0.05 / mo | **Secrets:** Billed at ~£0.022 per 10,000 transactions. |
| **Azure Automation** | **FREE** | **Compute:** The first 500 job minutes per month are completely free. Once exceeded, billing is just £0.002/minute. |
| **Azure Logic App** | **FREE** | **Alerting Webhook/Email:** Consumption plan includes the first 4,000 built-in actions per month for free. Subsequent standard connector calls are ~£0.000093 each. |
| **Azure Backup** *(Optional)* | ~£1.09 / mo | **Secondary Protection:** Adding an Azure Recovery Services vault for an isolated 30-day retention layer of the Storage Account. |

### Recommended Data Lifecycle Configuration



To minimise transaction and storage costs while supporting the "Drift Alerting" feature, I highly recommend applying the following Lifecycle Management Rule to your `dns-backups` blob container for verisons:

1. **Hot Tier (Days 1 - 3):** Keep recent backups in the Hot tier. This prevents early-deletion/retrieval penalties when the script downloads yesterday's file to perform the Drift Detection comparison.
2. **Cool Tier (Days 4 - 30):** Automatically transition files to the Cool tier for cheaper at-rest storage.
3. **Cold/Archive Tier (Days 31 - 60):** Move aging historical versions to Cold storage for deep archiving.
4. **Delete (Day 60+):** Automatically permanently delete blob versions older than 60 days to prevent infinite data sprawl.

> *Disclaimer: Prices are estimates based on the Azure Pricing Calculator (UK South/West region) and billing data from test deployments. Actual costs may vary slightly based on your specific domain count, file sizes, and regional pricing updates.*

---

## How to Restore a Backup
If a client accidentally deletes or changes a DNS record:
1. Navigate to your Storage Account -> Containers -> `dns-backups`.
2. Open the specific client's folder and click on the domain's `.txt` file.
3. Download the version from the day prior to the outage or requested time. You can re-import this BIND file directly into Cloudflare or open it in a text editor to find the missing record.

---

## 🤝 Contributing
Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.
