<#
Written by Harry Shelton - 2026
Script Name: Backup-CloudflareDNS.ps1
Version: 1.0
Description: Main Script for the Automation Account - make sure in a different region than storage account for networking requirements.
#>

Connect-AzAccount -Identity

# --- Environment Variables - Update These ---
$VaultName          = "UPDATE-ME-WITH-YOUR-KEY-VAULT-NAME"
$GlobalSecretName   = "CLOUDFLARE-API-KEY"
$StorageAccountName = "UPDATE-ME-WITH-YOUR-STORAGE-ACCOUNT-NAME"
$TableName          = "ProtectedCustomers"
$ContainerName      = "dns-backups"
$ResourceGroupName  = "UPDATE-ME-WITH-YOUR-RESOURCE-GROUP"
# ------------------------------

#Get the dynamic IP of the Azure Automation Worker.
Write-Output "Discovering local worker IP..."
$WorkerIP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip").Trim()
Write-Output "Worker IP is $WorkerIP. Whitelisting on firewalls..."

# =========================================================================
# Main Block - for firewall updating
# =========================================================================
try {
    #Update the Firewall - with debugging for logs if needed
    Write-Output "Attempting to add IP to Key Vault firewall..."
    Add-AzKeyVaultNetworkRule -VaultName $VaultName -IpAddressRange "$WorkerIP/32" -ErrorAction Stop
    
    Write-Output "Attempting to add IP to Storage Account firewall..."
    Add-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -IPAddressOrRange $WorkerIP -ErrorAction Stop

    #Establish the Storage Context (For Blob Uploads later)
    $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount

    #Grab an auth token for Storage using the Automation Account's Identity
    $StorageToken = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com/").Token

    #Call the Table Storage endpoint
    $TableApiUrl = "https://$StorageAccountName.table.core.windows.net/$TableName`()"
    $TableHeaders = @{
        "Authorization" = "Bearer $StorageToken"
        "x-ms-version"  = "2019-02-02"
        "Accept"        = "application/json;odata=nometadata"
    }

    #Retry Loop
    $MaxRetries = 6
    $RetryWaitSeconds = 30
    $TableConnected = $false
    $Attempt = 0

    while (-not $TableConnected -and $Attempt -lt $MaxRetries) {
        $Attempt++
        Start-Sleep -Seconds $RetryWaitSeconds
        
        try {
            Write-Output "Attempt $Attempt to access Azure Table Storage..."
            $TableResponse = Invoke-RestMethod -Uri $TableApiUrl -Method Get -Headers $TableHeaders -ErrorAction Stop
            $ClientConfigurations = $TableResponse.value
            $TableConnected = $true
            Write-Output "Firewall is open! Successfully connected to Table Storage."
        }
        catch {
            #If we get a 403 Forbidden, the firewall is still closed. Wait and retry.
            if ($_.Exception.Message -match "403") {
                Write-Output "Firewall still propagating (Got 403 Forbidden). Retrying in $RetryWaitSeconds seconds..."
            } else {
                throw "Failed to query Table Storage due to an unexpected error: $_"
            }
        }
    }

    #If it fails 6 times (3 minutes), abort the whole script
    if (-not $TableConnected) {
        throw "Azure firewall failed to open after 3 minutes. Aborting backup run."
    }

    if (-not $ClientConfigurations) {
        Write-Warning "No customers found in the '$TableName' table. Exiting."
        exit
    }

    #Fetch the Global Cloudflare API Token (Now safe, since firewall is open)
    Write-Output "Fetching the global Cloudflare API token from Key Vault..."
    $TokenSecret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $GlobalSecretName -AsPlainText -ErrorAction Stop

    # Prepare Cloudflare Auth Headers
    $Headers = @{
        "Authorization" = "Bearer $TokenSecret"
        "Content-Type"  = "application/json"
    }

    # =========================================================================
    # CLOUDFLARE BACKUP ENGINE SECTION
    # =========================================================================
    
    #Loop through each customer account
    foreach ($Client in $ClientConfigurations) {
        $CustomerName = $Client.RowKey
        $AccountId    = $Client.AccountId

        Write-Output "================================================="
        Write-Output "Discovering zones for $CustomerName (Account: $AccountId)..."

        try {
            #Fetch all zones under this Account ID (Allows up to 500 domains per client)
            $ZonesUrl = "https://api.cloudflare.com/client/v4/zones?account.id=$AccountId&per_page=500"
            $ZonesResponse = Invoke-RestMethod -Uri $ZonesUrl -Method Get -Headers $Headers -ErrorAction Stop
            
            $ZoneCount = $ZonesResponse.result.Count
            if ($ZoneCount -eq 0) {
                Write-Warning "No domains found in Cloudflare for $CustomerName. Skipping."
                continue
            }

            Write-Output "Found $ZoneCount domains for $CustomerName."

            #Loop through every discovered domain in the account
            foreach ($Zone in $ZonesResponse.result) {
                $ZoneId = $Zone.id
                $DomainName = $Zone.name
                
                Write-Output "  -> Exporting DNS for $DomainName..."
                
                $ExportUrl = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/export"
                $TempFile = "$env:TEMP\$CustomerName-$DomainName-dns.txt"
                
                #Download the BIND file
                Invoke-RestMethod -Uri $ExportUrl -Method Get -Headers $Headers -OutFile $TempFile -ErrorAction Stop

                #Upload to Blob Storage into the Customer's folder
                Set-AzStorageBlobContent -Context $StorageContext `
                    -Container $ContainerName `
                    -File $TempFile `
                    -Blob "$CustomerName/$DomainName-dns.txt" `
                    -Force | Out-Null
                
                #Clean up the local temp file
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
    # Final Catch - Update the Firewall Again
    # =========================================================================
    Write-Output "Securing environment: Removing worker IP from firewalls..."
    
    Remove-AzKeyVaultNetworkRule -VaultName $VaultName -IpAddressRange "$WorkerIP/32" | Out-Null
    Remove-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -IPAddressOrRange $WorkerIP | Out-Null
    
    Write-Output "Environment secured."
}
