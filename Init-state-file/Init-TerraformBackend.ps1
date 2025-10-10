param(
    # --- Azure context ---
    [Parameter(Mandatory=$true)]
    [string] $SubscriptionId,
    [string] $Location,
    [string] $ResourceGroupName,
    [Parameter(Mandatory=$true)]
    [string] $StorageAccountName,
    [string] $ContainerName,
    [string] $StateFileName,

    # --- Auth/RBAC options ---
    [switch] $GrantBlobDataContributorToCurrentIdentity,
    [string] $PrincipalObjectId,

    # --- (Optional) Legacy auth with access key ---
    [switch] $UseAccessKeyMode
)
# --- Set defaults if not provided ---

if (-not $Location)           { $Location          = "westeurope" }
if (-not $ResourceGroupName)  { $ResourceGroupName = "XXX-tfstate-rg" }
if (-not $StorageAccountName) { $StorageAccountName= "xxxtfstate0001" }
if (-not $ContainerName)      { $ContainerName     = "tfstate" }
if (-not $StateFileName)      { $StateFileName     = "XXX-project-name.tfstate" }
if (-not $PrincipalObjectId)  { $PrincipalObjectId = "" }


# Helper
function Write-Info($msg) { Write-Output "[Init] $msg" }

Write-Info "Selecting subscription ${SubscriptionId}…"
az account set --subscription $SubscriptionId | Out-Null

Write-Info "Ensuring resource group ${ResourceGroupName} in ${Location}…"
az group create --name $ResourceGroupName --location $Location --output none

Write-Info "Ensuring storage account ${StorageAccountName}…"
az storage account create `
  --name $StorageAccountName `
  --resource-group $ResourceGroupName `
  --location $Location `
  --sku Standard_LRS `
  --kind StorageV2 `
  --min-tls-version TLS1_2 `
  --allow-blob-public-access false `
  --output none

Write-Info "Ensuring blob container ${ContainerName}…"
# Use Azure AD login mode to avoid keys
az storage container create `
  --name $ContainerName `
  --account-name $StorageAccountName `
  --auth-mode login `
  --public-access off `
  --output none

# Optional: grant RBAC for current identity or explicit principal
if ($GrantBlobDataContributorToCurrentIdentity -or $PrincipalObjectId) {
    $who = $PrincipalObjectId
    if (-not $who) {
        $signedIn = az ad signed-in-user show --query id -o tsv
        $who = $signedIn
    }
    Write-Info "Assigning 'Storage Blob Data Contributor' to principal ${who} on the storage account scope…"
    $scope = az storage account show -n $StorageAccountName -g $ResourceGroupName --query id -o tsv
    az role assignment create `
      --assignee-object-id $who `
      --assignee-principal-type User `
      --role "Storage Blob Data Contributor" `
      --scope $scope `
      --output none
}

# Compose backend.hcl
Write-Info "Writing backend.hcl…"
$backend = @()
$backend += "resource_group_name  = `"$ResourceGroupName`""
$backend += "storage_account_name = `"$StorageAccountName`""
$backend += "container_name       = `"$ContainerName`""
$backend += "key                  = `"$StateFileName`""
$backend += "subscription_id      = `"$SubscriptionId`""

if ($UseAccessKeyMode) {
    Write-Info "AccessKey mode requested — retrieving access key…"
    $key = az storage account keys list -g $ResourceGroupName -n $StorageAccountName --query "[0].value" -o tsv
    $backend += "access_key          = `"$key`""
    Write-Info "AccessKey added to backend.hcl (note: for legacy/back-compat only)."
} else {
    Write-Info "AAD/RBAC mode selected (recommended). No access_key will be written."
}

$backend | Out-File -FilePath "./backend.hcl" -Encoding utf8 -Force

Write-Output "Backend written to ${PWD}\backend.hcl"
Write-Host "`e[92mNow run: terraform init -backend-config='backend.hcl'`e[0m"
