param(
  [Parameter(Mandatory = $true)]
  [string]$SubscriptionId,
  [string]$Location = "eastus2",
  [switch]$DeployApp
)

$ErrorActionPreference = "Stop"

function Assert-LastExitCode {
  param([string]$Step)
  if ($LASTEXITCODE -ne 0) {
    throw "$Step failed with exit code $LASTEXITCODE"
  }
}

function Update-ProgressFile {
  param([string[]]$Lines)
  $progressPath = Join-Path $PSScriptRoot "..\.azure\progress.copilotmd"
  Set-Content -Path $progressPath -Value ($Lines -join "`n") -Encoding UTF8
}

Write-Host "Setting Azure subscription..."
az account set --subscription $SubscriptionId

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$infraPath = Join-Path $repoRoot "infra"

$k8sVersion = az aks get-versions --location $Location --query "values[?isDefault].version" -o tsv
if ([string]::IsNullOrWhiteSpace($k8sVersion)) {
  throw "Unable to determine AKS default version in region $Location"
}

$suffix = (Get-Date).ToString("yyMMddHHmm")
$postgresPassword = "Petclinic!" + [Guid]::NewGuid().ToString("N").Substring(0, 16)

$tfVars = @{
  subscription_id = $SubscriptionId
  location = $Location
  project_name = "petclinic$suffix"
  environment = "dev"
  kubernetes_version = $k8sVersion
  aks_node_vm_size = "Standard_D4ds_v5"
  postgres_admin_username = "petclinicadmin"
  postgres_admin_password = $postgresPassword
} | ConvertTo-Json

Set-Content -Path (Join-Path $infraPath "main.tfvars.json") -Value $tfVars -Encoding UTF8

Update-ProgressFile -Lines @(
  "- [x] Scanned project for languages, frameworks, dependencies, and deployment config",
  "- [x] Generated Azure plan via mcp_c2c_appmod-get-plan",
  "- [x] Prepared Terraform IaC and AKS deployment artifacts",
  "- [ ] Provision Azure resources with Terraform (in progress)",
  "- [ ] Build and push image to ACR (skipped: provision-only)",
  "- [ ] Deploy to AKS and validate app availability (skipped: provision-only)"
)

Push-Location $infraPath
terraform init
Assert-LastExitCode -Step "terraform init"
terraform validate
Assert-LastExitCode -Step "terraform validate"
terraform apply -auto-approve -var-file="main.tfvars.json"
Assert-LastExitCode -Step "terraform apply"

$resourceGroup = terraform output -raw resource_group_name
Assert-LastExitCode -Step "terraform output resource_group_name"
$aksName = terraform output -raw aks_name
Assert-LastExitCode -Step "terraform output aks_name"
$acrName = terraform output -raw acr_name
Assert-LastExitCode -Step "terraform output acr_name"
Pop-Location

if (-not $DeployApp) {
  Update-ProgressFile -Lines @(
    "- [x] Scanned project for languages, frameworks, dependencies, and deployment config",
    "- [x] Generated Azure plan via mcp_c2c_appmod-get-plan",
    "- [x] Prepared Terraform IaC and AKS deployment artifacts",
    "- [x] Provision Azure resources with Terraform",
    "- [ ] Build and push image to ACR (skipped: provision-only)",
    "- [ ] Deploy to AKS and validate app availability (skipped: provision-only)"
  )

  Write-Host "Provisioning completed (provision-only mode)."
  Write-Host "Resource Group: $resourceGroup"
  Write-Host "AKS: $aksName"
  Write-Host "ACR: $acrName"
  return
}

$keyVaultName = terraform -chdir="$infraPath" output -raw key_vault_name

Write-Host "Building app image..."
Push-Location $repoRoot
$tag = (Get-Date).ToString("yyyyMMddHHmmss")
$imageRef = "$acrName.azurecr.io/petclinic:$tag"
az acr build --registry $acrName --image "petclinic:$tag" --file "Dockerfile" .
Pop-Location

Write-Host "Configuring kubectl context..."
az aks get-credentials --resource-group $resourceGroup --name $aksName --overwrite-existing
kubectl create namespace petclinic --dry-run=client -o yaml | kubectl apply -f -

$postgresUrl = az keyvault secret show --vault-name $keyVaultName --name "postgres-url" --query value -o tsv
$postgresUser = az keyvault secret show --vault-name $keyVaultName --name "postgres-user" --query value -o tsv
$postgresPass = az keyvault secret show --vault-name $keyVaultName --name "postgres-pass" --query value -o tsv
$appInsightsConn = az monitor app-insights component show --resource-group $resourceGroup --app (az resource list --resource-group $resourceGroup --resource-type "microsoft.insights/components" --query "[0].name" -o tsv) --query connectionString -o tsv

kubectl create secret generic petclinic-db -n petclinic `
  --from-literal=postgres-url="$postgresUrl" `
  --from-literal=postgres-user="$postgresUser" `
  --from-literal=postgres-pass="$postgresPass" `
  --from-literal=appinsights-connection-string="$appInsightsConn" `
  --dry-run=client -o yaml | kubectl apply -f -

$manifestPath = Join-Path $repoRoot "k8s\aks\petclinic-aks.yaml"
((Get-Content -Path $manifestPath -Raw).Replace("__IMAGE__", $imageRef)) | kubectl apply -f -
kubectl rollout status deploy/petclinic -n petclinic --timeout=300s

Update-ProgressFile -Lines @(
  "- [x] Scanned project for languages, frameworks, dependencies, and deployment config",
  "- [x] Generated Azure plan via mcp_c2c_appmod-get-plan",
  "- [x] Prepared Terraform IaC and AKS deployment artifacts",
  "- [x] Provision Azure resources with Terraform",
  "- [x] Build and push image to ACR",
  "- [x] Deploy to AKS and validate app availability"
)

Write-Host "Deployment completed."
Write-Host "Resource Group: $resourceGroup"
Write-Host "AKS: $aksName"
Write-Host "Image: $imageRef"
