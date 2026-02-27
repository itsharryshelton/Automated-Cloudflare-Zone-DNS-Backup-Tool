<#
Written by Harry Shelton - 2026
Script Name: Backup-CloudflareDNS.ps1
Version: 2.0
Description: Refreshed for V2, for use with the Frontend design of Cloudflare Worker for easier engineering onboarding. Includes better security design of requesting split storage for customer list and actual backup data.
#>

Connect-AzAccount -Identity

# --- Environment Variables - Update These ---
$VaultName                = "UPDATE ME WITH VAULT NAME"
$GlobalSecretName         = "CLOUDFLARE-API-KEY"
$BackupStorageAccountName = "UPDATE ME WITH STORAGE ACCOUNT FOR BACKING UP DATA"
$TableStorageAccountName  = "UPDATE ME WITH STORAGE ACCOUNT FOR CUSTOMER LIST"
$TableName                = "ProtectedCustomers"
$ContainerName            = "dns-backups"
$ResourceGroupName        = "UPDATE ME WITH RESOURCE GROUP"
# ------------------------------

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
    Write-Output "Querying Azure Table '$TableName' from Config Storage..."
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

    #Smart Retry Loop (Wait for the locked-down firewalls to open)
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
            
            #Can we read the Key Vault?
            $TokenSecret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $GlobalSecretName -AsPlainText -ErrorAction Stop
            
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
    # CLOUDFLARE BACKUP SECTION
    # =========================================================================
    
    # Loop through each customer account
    foreach ($Client in $ClientConfigurations) {
        $CustomerName = $Client.RowKey
        $AccountId    = $Client.AccountId

        Write-Output "================================================="
        Write-Output "Discovering zones for $CustomerName (Account: $AccountId)..."

        try {
            # Fetch all zones under this Account ID (Allows up to 500 domains per client)
            $ZonesUrl = "https://api.cloudflare.com/client/v4/zones?account.id=$AccountId&per_page=500"
            $ZonesResponse = Invoke-RestMethod -Uri $ZonesUrl -Method Get -Headers $Headers -ErrorAction Stop
            
            $ZoneCount = $ZonesResponse.result.Count
            if ($ZoneCount -eq 0) {
                Write-Warning "No domains found in Cloudflare for $CustomerName. Skipping."
                continue
            }

            Write-Output "Found $ZoneCount domains for $CustomerName."

            # Loop through every discovered domain in the account
            foreach ($Zone in $ZonesResponse.result) {
                $ZoneId = $Zone.id
                $DomainName = $Zone.name
                
                Write-Output "  -> Exporting DNS for $DomainName..."
                
                $ExportUrl = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/export"
                $TempFile = "$env:TEMP\$CustomerName-$DomainName-dns.txt"
                
                # Download the BIND file
                Invoke-RestMethod -Uri $ExportUrl -Method Get -Headers $Headers -OutFile $TempFile -ErrorAction Stop

                # Upload to Blob Storage into the Customer's folder
                Set-AzStorageBlobContent -Context $StorageContext `
                    -Container $ContainerName `
                    -File $TempFile `
                    -Blob "$CustomerName/$DomainName-dns.txt" `
                    -Force | Out-Null
                
                # Clean up the local temp file
                Remove-Item -Path $TempFile -ErrorAction SilentlyContinue
            }
            
            Write-Output "Successfully backed up all domains for $CustomerName."
        }
        catch {
            Write-Error "Failed processing account $CustomerName. Error: $_"
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
    # Final Catch - Update the Firewalls Again
    # =========================================================================
    Write-Output "Securing environment: Removing worker IP from firewalls..."
    
    Remove-AzKeyVaultNetworkRule -VaultName $VaultName -IpAddressRange "$WorkerIP/32" -ErrorAction Continue | Out-Null
    Remove-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $BackupStorageAccountName -IPAddressOrRange $WorkerIP -ErrorAction Continue | Out-Null
    
    Write-Output "Environment secured."
}
