# Serverless Cloudflare DNS Backup for MSPs (Azure Edition)

A highly scalable, multi-tenant, and virtually serverless solution to automatically back up Cloudflare DNS records to Azure Blob Storage, with a front end website.

Designed specifically for Managed Service Providers (MSPs), this tool handles multiple Cloudflare accounts, dynamically discovers all domains within those accounts, and retains a version-controlled history of DNS records without requiring a single virtual machine.

<img width="3981" height="2619" alt="Cloudflare Automated Backup Tool - Diagram V2" src="https://github.com/user-attachments/assets/c966b795-3b5a-4e3e-b397-ac4bd576bb71" />


## Main Bits after being setup
* **Serverless:** No VMs, no patching, no Hybrid Workers.
* **Networking:** Resources remain completely locked down behind Azure Firewalls.
* **Terraform:** Pre-built Terraform Files to help support deploying this into an existing or new pipeline. Or just save time deploying it.
* **Versioning:** Leverages Azure Blob Versioning to keep a point-in-time history of all DNS changes.
* **Multi-Tenant:** Uses Azure Table Storage as a lightweight database to manage hundreds of clients easily.
* **Custom Front End:** For easier engineering onboarding, a frontend protected in Cloudflare and hosted in Cloudflare Workers.

<img width="664" height="759" alt="image" src="https://github.com/user-attachments/assets/943e4bd9-1972-4356-9366-503780286454" />


---

## "Cross-Region" Architecture (Crucial)
To maintain a strict Zero-Trust firewall posture without needing Virtual Networks (VNets), NAT Gateways etc, this solution uses a dynamic IP whitelisting script based on the Automation Account's Public IP - avoiding Microsoft's Backbone Within-Region routing. 

**CRITICAL REQUIREMENT:** Your **Azure Automation Account** must be deployed in a **different Azure Region** than your Storage Account and Key Vault (e.g., Automation in `UK South`, Storage in `UK West`). 

If they are in the same region, Azure routes the traffic over its internal backbone, stripping the public IP address, which causes the firewall whitelist to fail (`403 Forbidden`). Splitting regions forces the traffic over the public internet, allowing the dynamic firewall rules to work perfectly.

---

## Deployment Guide

Review the Wiki Section of this Repo for complete guides for each section of this design.

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
