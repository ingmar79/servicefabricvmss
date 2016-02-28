##############################################################################
# Author : Gonzalo Ruiz - Cloud Architect 
#  For more info : www.gonzowins.com
# Date   : 25/02/2015
#
# This script creates a Service Fabric Cluster in Azure and the related objects
# like  :
#          Certificates
#          KeyVault
#          Azure Objects - By using an ARM Template, the following objects will be created
#                One VNET with two Subnets
#                N - Number of VMS
#                   Two extensions will be installed : Service Fabric and Diagnostics extensions
#                N - Number of NICS
#                One Public IP and one LB
#                One Application Gatway for SSL Termination
#                One Network Security Group per Subnet    
#                One Availability Set
#                One Service Fabric Extension
#          
# Note : You will need privileges to create Service Fabric Clusters in Azure
# 
###############################################################################

function SetupCertificates()
{
 
    If (-not (Test-Path $certificateFilePath)){
        $newCer = New-SelfSignedCertificate -CertStoreLocation Cert:\CurrentUser\My -DnsName $dnsName
        $newCer    | Export-PfxCertificate -FilePath $certificateFilePath -Password  $certificatePassword 

        
        $newCer |Export-Certificate -FilePath $cerCertificateFilePath -Type CERT
        ######## Set up the Certs
        #If this is a self signed cert, then add it to the Trusted People Store.Else skip.
        $importedCer = Import-PfxCertificate -Exportable -CertStoreLocation Cert:\CurrentUser\TrustedPeople -FilePath $certificateFilePath -Password $certificatePassword

        #####import the cert into your local store. this is so that you can use the cert to view the secure cluster 
        $importedCer = Import-PfxCertificate -Exportable -CertStoreLocation Cert:\CurrentUser\My -FilePath $certificateFilePath -Password $certificatePassword

    }    
    $clusterCertificates = new-object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificateFilePath, $certificatePassword
    $clusterCertificates
}

function GetOrCreateKeyVault
{
    
        if (-not (Get-AzureRmResourceGroup | ? ResourceGroupName -eq $resourceGroupName))
        {
            $newResourceGroup = New-AzureRmResourceGroup  -Name $ResourceGroupName -Location $Location -Verbose 
        }

        

    
        if( -not (Get-AzureRmKeyVault -ResourceGroupName $ResourceGroupName | ? VaultName -eq $VaultName ))
        {
            Write-Host "Creating vault $VaultName in $location (resource group $ResourceGroupName)"    
            $keyVault = New-AzureRmKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroupName -Location $Location `
                                            -EnabledForDeployment -Verbose  -Sku premium   
            
            
        }
        else 
        {
            $keyVault = Get-AzureRmKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroupName  
        }        
    
    $keyVault

}

function AddCertificateToKeyVault
{
  Param(
      [string] $SecretName,  
      [string] $PfxFilePath,
      [System.Security.SecureString] $Password,
      [string] $ResourceGroupName,  
      [string] $Location,  
      [string] $VaultName
     )
     $ErrorActionPreference = 'Stop'       
    
   
   
    if( -not (Get-AzureKeyVaultSecret   -VaultName $VaultName | ? Name -eq $secretName))
      {
                 

            $bytes = [System.IO.File]::ReadAllBytes($PfxFilePath)
            $base64 = [System.Convert]::ToBase64String($bytes)
            

            $jsonBlob = @{
                data = $base64
                dataType = 'pfx'
                password = $clearPassword
            } | ConvertTo-Json

            $contentbytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBlob)
            $content = [System.Convert]::ToBase64String($contentbytes)

            $secretValue = ConvertTo-SecureString -String $content -AsPlainText -Force
     
            Write-Host "Writing secret $SecretName to vault $VaultName"
            $keyVaultSecret = Set-AzureKeyVaultSecret -VaultName $VaultName -Name $SecretName -SecretValue $secretValue -Verbose         
     }
     else
     {
      $keyVaultSecret = Get-AzureKeyVaultSecret -VaultName $VaultName -Name $SecretName
     }

    $keyVaultSecret

 }

function SetClusterTemplateParameters()
{
    Param(
          [string] $sslCertificate,  
          [string] $sslCertificatePassword,
          [string] $corpNetwork
          
         )
    
    # Read the Json Parameters file and Convert to HashTable
    $parameters = New-Object -TypeName hashtable 
    $jsonContent = Get-Content $parametersFileLocation  -Raw | ConvertFrom-Json 
    $jsonContent.parameters.psobject.Properties.Name `
            |ForEach-Object {$parameters.Add($_ ,$jsonContent.parameters.$_.Value)}
    
    # Complete Parameters Values 
    $parameters["clusterLocation"] = $location
    $parameters["adminPassword"] = $clearPassword
    $parameters["certificateThumbprint"] = $clusterCertificate.Thumbprint   
    $parameters["sourceVaultValue"] = $keyVault.ResourceId
    $parameters["certificateUrlValue"] = $keyVaultSecret.Id
    $parameters["dnsName"] = $dnsName
    $parameters["vmStorageAccountName"] = $dnsName+"inf"
    $parameters["clusterName"] = $dnsName
    $parameters["certData"] = $sslCertificate
    $parameters["certPassword"] = $sslCertificatePassword
    $parameters["allowedSourceIPs"] = $corpNetwork   


    
    $parameters
}



function ValidateClusterConnection()
{

      Start-Sleep -Seconds 120    
      

    $connectionEndpoint = "$dnsName.$location.cloudapp.azure.com:19000"
    Connect-serviceFabricCluster -ConnectionEndpoint $connectionEndpoint -KeepAliveIntervalInSec 10 `
    -X509Credential `
    -ServerCertThumbprint $clusterCertificate.Thumbprint  `
    -FindType FindByThumbprint `
    -FindValue $clusterCertificate.Thumbprint  `
    -StoreLocation CurrentUser `
    -StoreName My

    ##### Get cluster health and other checks    
    Get-ServiceFabricNode | Format-Table -AutoSize
    Get-ServiceFabricService fabric:/System | Format-Table -AutoSize

    ##### Print Connection details
    Write-Output "Connection Endpoint : $connectionEndpoint"
    Write-Output "Certificate Thumbprint : $clusterParameters.certificateThumbprint"
    Write-Output "Common Name : $dnsName"
}

function EnableAuditing()
{
    $storageAccountName = $clusterParameters["vmStorageAccountName"] +"dg"
    $storageAccoungRef = Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
	# KeyVault
	  Set-AzureRmDiagnosticSetting  -ResourceId $keyVault.ResourceId -StorageAccountId $storageAccoungRef.Id -Enabled $true
	# Application Gateway
      $appGW = Get-AzureRmApplicationGateway -ResourceGroupName $resourceGroupName -Name "appwgtosvcfab"
	  Set-AzureRmDiagnosticSetting  -ResourceId $appGW.Id  -StorageAccountId $storageAccoungRef.Id  -Enabled $true
        # Network Security Groups - To Add
        # DocumentDb
        # Azure Batch
	# Azure Media Services

}

##### Optional : Register ServiceFabric Provider
# Register-AzureRmResourceProvider -ProviderNamespace Microsoft.ServiceFabric -Force
# Register-AzureRmResourceProvider -ProviderNamespace Microsoft.KeyVault -Force

clear

##### Parameters - ResourceGroup & KeyVault
$instanceNumber = (Get-Date -format ddMM) + "02"
#$instanceNumber = "010208"
$location = 'North Europe'
$currentLocation = Get-Location

##### Parameters - Names
$appName = "tthd"
$dnsName = "$appName$instanceNumber"
$resourceGroupName = "$appName$instanceNumber"
$deploymentName ="svcfabcluster-Initial"

##### Parameters - Certificates & Security
$certificateFilePath = "$currentLocation\$dnsName.pfx"
$cerCertificateFilePath = "$currentLocation\$dnsName.cer"
$vaultName = "srvfabdev$instanceNumber"
$secretName = 'ServiceFabricCert'


##### Templates Location 
$templateFileLocation = "$currentLocation\azuredeploy_ttgw_ss.json"
$parametersFileLocation = "$currentLocation\azuredeploy-parameters.json"

################ Corp Network #####################
if($corpNetwork -eq $null) {
        #$corpNetwork = (Invoke-WebRequest http://myexternalip.com/raw).Content
        #$corpNetwork = "YOUR_CORPNETWORK"
        $corpNetwork = "*"
}

if($certificatePassword -eq $null) {
    $certificatePassword = Read-Host -Prompt "Enter password" -AsSecureString 
    $clearPassword = (New-Object System.Management.Automation.PSCredential 'N/A', $certificatePassword).GetNetworkCredential().Password    
}


######## STEP 1  : Create And Setup Certificates
$clusterCertificate = SetupCertificates 
$sslCertificate = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($certificateFilePath))

######## STEP 2 : Create ResourceGroup & KeyVault #####################
$keyVault = GetOrCreateKeyVault

######## STEP 3 : Upload the Certificates to Key Vault #####################
$keyVaultSecret = AddCertificateToKeyVault -ResourceGroupName $resourceGroupName -Location $location -VaultName $vaultName -SecretName $secretName -PfxFilePath $certificateFilePath -Password $certificatePassword

####### STEP 4 : Retrieve and Print Cluster Parameters #####################
$clusterParameters = SetClusterTemplateParameters -sslCertificate $sslCertificate -sslCertificatePassword $clearPassword -corpNetwork $corpNetwork
Write-Host $clusterParameters
$DebugPreference ='continue'
####### STEP 5 : Create Service Fabric Cluster #####################
$validation = Test-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName `
                                                  -TemplateFile $templateFileLocation -TemplateParameterObject $clusterParameters 
    
if($validation.Count -eq 0)
{
        
        New-AzureRmResourceGroupDeployment  -Name $deploymentName -ResourceGroupName $resourceGroupName `
                                          -TemplateFile  $templateFileLocation  -TemplateParameterObject $clusterParameters  
        
        ####### STEP 6 : Enable Network logging #####################
        
        ####### STEP 7 : Validate Connection to Cluster #####################
        #ValidateClusterConnection  

}
else
{
    Write-Output "Error Validating Template:" $validation
}



