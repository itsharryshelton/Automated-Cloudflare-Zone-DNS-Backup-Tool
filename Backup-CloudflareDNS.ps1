<#
Written by Harry Shelton
Script Name: Backup-CloudflareDNS.ps1
Version: 2.1.0
Integrated DNS Drift Detection with aggregated HTML Email alerting (via a Logic App) for the Service Desk.
Added Cloudflare API pagination handling to support enterprise tenants with 50+ domains.
#>

Connect-AzAccount -Identity

# --- Environment Variables - Update These ---
$VaultName                = "Update Me with Your Key Vault Name"
$GlobalSecretName         = "CLOUDFLARE-API-KEY"
$EmailSecretName          = "EMAIL-WEBHOOK-URL"
$BackupStorageAccountName = "Update Me with Your Backup Storage Account Name"
$TableStorageAccountName  = "Update me with your Customer List Storage Account Name"
$TableName                = "ProtectedCustomers"
$ContainerName            = "dns-backups"
$ResourceGroupName        = "Update Me with Your Resource Group Name"
# ------------------------------
# =========================================================================
# =========================================================================

#No requirement to update anything below me:

#Get the dynamic IP of the Azure Automation Worker.
Write-Output "Discovering local worker IP..."
$WorkerIP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip").Trim()
Write-Output "Worker IP is $WorkerIP. Whitelisting on firewalls..."

# =========================================================================
# Main Block - for firewall updating and backups
# =========================================================================
try {
    #Update the Firewalls (Key Vault and Backup Storage ONLY)
    Write-Output "Attempting to add IP to Key Vault firewall..."
    Add-AzKeyVaultNetworkRule -VaultName $VaultName -IpAddressRange "$WorkerIP/32" -ErrorAction Stop
    
    Write-Output "Attempting to add IP to Backup Storage Account firewall..."
    Add-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $BackupStorageAccountName -IPAddressOrRange $WorkerIP -ErrorAction Stop

    #Query the Config Table
    Write-Output "Querying Azure Table '$TableName' from Customer List Storage..."
    $StorageToken = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com/").Token
    $TableApiUrl = "https://$TableStorageAccountName.table.core.windows.net/$TableName`()"
    $TableHeaders = @{
        "Authorization" = "Bearer $StorageToken"
        "x-ms-version"  = "2019-02-02"
        "Accept"        = "application/json;odata=nometadata"
    }
    
    $TableResponse = Invoke-RestMethod -Uri $TableApiUrl -Method Get -Headers $TableHeaders -ErrorAction Stop
    $ClientConfigurations = $TableResponse.value

    if (-not $ClientConfigurations) {
        Write-Warning "No customers found in the '$TableName' table. Exiting."
        exit
    }

    #Retry Loop
    Write-Output "Waiting for Key Vault and Backup Storage firewalls to propagate..."
    $StorageContext = New-AzStorageContext -StorageAccountName $BackupStorageAccountName -UseConnectedAccount
    
    $MaxRetries = 6
    $RetryWaitSeconds = 30
    $FirewallsOpen = $false
    $Attempt = 0

    while (-not $FirewallsOpen -and $Attempt -lt $MaxRetries) {
        $Attempt++
        Start-Sleep -Seconds $RetryWaitSeconds
        
        try {
            Write-Output "Attempt $Attempt to verify firewalls..."
            
            #Can we read the Key Vault Secrets?
            $TokenSecret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $GlobalSecretName -AsPlainText -ErrorAction Stop
            $EmailWebhookUrl = Get-AzKeyVaultSecret -VaultName $VaultName -Name $EmailSecretName -AsPlainText -ErrorAction Stop
            
            #Can we read the Backup Blob Container?
            Get-AzStorageContainer -Context $StorageContext -Name $ContainerName -ErrorAction Stop | Out-Null
            
            $FirewallsOpen = $true
            Write-Output "Firewalls are open! Proceeding with Cloudflare backups."
        }
        catch {
            #If we get a 403 Forbidden or AuthorizationFailure, keep waiting.
            if ($_.Exception.Message -match "403" -or $_.Exception.Message -match "Forbidden" -or $_.Exception.Message -match "AuthorizationFailure") {
                Write-Output "Firewalls still propagating. Retrying in $RetryWaitSeconds seconds..."
            } else {
                throw "Unexpected error during firewall verification: $_"
            }
        }
    }

    if (-not $FirewallsOpen) {
        throw "Azure firewalls failed to open after 3 minutes. Aborting backup run."
    }

    #Prepare Cloudflare Auth Headers
    $Headers = @{
        "Authorization" = "Bearer $TokenSecret"
        "Content-Type"  = "application/json"
    }

    # =========================================================================
    # CLOUDFLARE BACKUP SECTION WITH DRIFT DETECTION & ALERTING - LOOPS PER CUSTOMER FOR ALERT EMAILS
    # =========================================================================
    
    # Loop through each customer account
    foreach ($Client in $ClientConfigurations) {
        $CustomerName = $Client.RowKey
        $AccountId    = $Client.AccountId
        $ClientAlerts = @() #Reset the alert array

        Write-Output "================================================="
        Write-Output "Discovering zones for $CustomerName (Account: $AccountId)..."

        try {
            # ==================================================
            # CLOUDFLARE PAGINATION LOGIC TO AVOID API LIMIT
            # ==================================================
            $AllZones = @()
            $Page = 1
            $TotalPages = 1

            while ($Page -le $TotalPages) {
                Write-Output "  -> Fetching domain list (Page $Page of $TotalPages)..."
                
                #Fetch up to 50 zones per page (Cloudflare's max limit for this endpoint)
                $ZonesUrl = "https://api.cloudflare.com/client/v4/zones?account.id=$AccountId&per_page=50&page=$Page"
                $ZonesResponse = Invoke-RestMethod -Uri $ZonesUrl -Method Get -Headers $Headers -ErrorAction Stop
                
                if ($ZonesResponse.result) {
                    $AllZones += $ZonesResponse.result
                }

                #Update the total pages based on Cloudflare's result_info
                if ($ZonesResponse.result_info.total_pages) {
                    $TotalPages = $ZonesResponse.result_info.total_pages
                }

                $Page++
            }
            # ==================================================

            $ZoneCount = $AllZones.Count
            if ($ZoneCount -eq 0) {
                Write-Warning "No domains found in Cloudflare for $CustomerName. Skipping."
                continue
            }

            Write-Output "Found $ZoneCount total domains for $CustomerName."

            #Loop through every discovered domain in the account
            foreach ($Zone in $AllZones) {
                $ZoneId = $Zone.id
                $DomainName = $Zone.name
                
                Write-Output "  -> Exporting DNS for $DomainName..."
                
                $ExportUrl = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/export"
                $TempFileNew = "$env:TEMP\$CustomerName-$DomainName-new.txt"
                $TempFileOld = "$env:TEMP\$CustomerName-$DomainName-old.txt"
                
                #Download the NEW backup from Cloudflare
                Invoke-RestMethod -Uri $ExportUrl -Method Get -Headers $Headers -OutFile $TempFileNew -ErrorAction Stop

                #Attempt to download the OLD backup from Azure (if it exists)
                $BlobExists = $true
                try {
                    Get-AzStorageBlobContent -Context $StorageContext -Container $ContainerName -Blob "$CustomerName/$DomainName-dns.txt" -Destination $TempFileOld -Force -ErrorAction Stop | Out-Null
                } catch {
                    $BlobExists = $false
                    Write-Output "  -> No previous backup found. First time backing up this domain."
                }

                #Perform the Drift Analysis (If an old backup exists)
                if ($BlobExists) {
                    #Read files, stripping out comments (;), empty lines, AND dynamically changing SOA records - otherwise it will detect drift every time :D
                    $OldRecords = Get-Content $TempFileOld | Where-Object { $_ -notmatch '^\s*;' -and $_ -notmatch '\s+IN\s+SOA\s+' -and $_.Trim() -ne '' }
                    $NewRecords = Get-Content $TempFileNew | Where-Object { $_ -notmatch '^\s*;' -and $_ -notmatch '\s+IN\s+SOA\s+' -and $_.Trim() -ne '' }

                    #Compare the two updated arrays
                    $Diff = Compare-Object -ReferenceObject $OldRecords -DifferenceObject $NewRecords

                    if ($Diff) {
                        Write-Output "  -> DRIFT DETECTED for $DomainName!"
                        $DriftDetails = "<strong>$DomainName</strong><ul>"
                        
                        #Output the exact differences to the console/log and build HTML payload
                        foreach ($Change in $Diff) {
                            if ($Change.SideIndicator -eq "=>") {
                                Write-Output "     [+] ADDED: $($Change.InputObject)"
                                $DriftDetails += "<li><span style='color:green;'>[+] ADDED:</span> $($Change.InputObject)</li>"
                            } else {
                                Write-Output "     [-] REMOVED: $($Change.InputObject)"
                                $DriftDetails += "<li><span style='color:red;'>[-] REMOVED:</span> $($Change.InputObject)</li>"
                            }
                        }
                        $DriftDetails += "</ul>"
                        $ClientAlerts += $DriftDetails
                    } else {
                        Write-Output "  -> No DNS drift detected. Configuration matches last backup."
                    }
                }

                #Upload the NEW file to Blob Storage - this is the backup bit - even if drift is detected, we want to update the backup to the latest state for next time. Won't delete old version.
                Write-Output "  -> Committing new backup to Azure Blob Storage..."
                Set-AzStorageBlobContent -Context $StorageContext `
                    -Container $ContainerName `
                    -File $TempFileNew `
                    -Blob "$CustomerName/$DomainName-dns.txt" `
                    -Force | Out-Null
                
                #Clean up local temp files
                Remove-Item -Path $TempFileNew, $TempFileOld -ErrorAction SilentlyContinue
            }
            
            Write-Output "Successfully backed up all domains for $CustomerName."
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Error "Failed processing account $CustomerName. Error: $ErrorMessage"
            $ClientAlerts += "<p><strong>Critical Error:</strong> Failed to process Cloudflare account. Details: $ErrorMessage</p>"
        }

        # =========================================================================
        # TRIGGER EMAIL IF ALERTS MADE ABOVE
        # =========================================================================
        if ($ClientAlerts.Count -gt 0) {
            Write-Output "Triggering Service Desk ticket for $CustomerName..."
            
            $EmailPayload = @{
                CustomerName = $CustomerName
                Subject      = "Cloudflare DNS Alert: Action Required for $CustomerName"
                HtmlBody     = "<h3>DNS Changes or Errors Detected</h3>" + ($ClientAlerts -join "<br>")
            } | ConvertTo-Json -Depth 10

            try {
                Invoke-RestMethod -Uri $EmailWebhookUrl -Method Post -ContentType "application/json" -Body $EmailPayload -ErrorAction Stop
                Write-Output "Ticket generated successfully."
            } catch {
                Write-Error "Failed to trigger email webhook for $CustomerName : $($_)"
            }
        } else {
            Write-Output "Zero drift or errors. No ticket required for $CustomerName."
        }
    }

    Write-Output "================================================="
    Write-Output "Global backup run complete."

}
catch {
    Write-Error "A critical error occurred during the backup run: $_"
}
finally {
    # =========================================================================
    # CLEAN UP FIREWALLS AFTER SCRIPT - (Will run even if the above scripts fail for whatever reason) 
    # =========================================================================
    Write-Output "Securing environment: Removing worker IP from firewalls..."
    
    Remove-AzKeyVaultNetworkRule -VaultName $VaultName -IpAddressRange "$WorkerIP/32" -ErrorAction Continue | Out-Null
    Remove-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $BackupStorageAccountName -IPAddressOrRange $WorkerIP -ErrorAction Continue | Out-Null
    
    Write-Output "Environment secured."
}