# setup-azure-auth-for-pipeline.ps1
# This script creates a User-assigned Managed Identity with federated credentials
# for GitHub Actions OIDC authentication to Azure.

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId = "a0af06b0-4110-4353-804d-4c228ad5a7c2",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",
    
    [Parameter(Mandatory=$false)]
    [string]$IdentityResourceGroup = "rg-github-pipeline-identity",
    
    [Parameter(Mandatory=$false)]
    [string]$IdentityName = "id-github-petclinic-pipeline",
    
    [Parameter(Mandatory=$false)]
    [string]$GitHubOrg = "",  # Your GitHub organization or username
    
    [Parameter(Mandatory=$false)]
    [string]$GitHubRepo = "", # Your GitHub repository name
    
    # Resource groups for each environment (comma-separated if multiple)
    [Parameter(Mandatory=$false)]
    [string]$DevResourceGroup = "rg-petclinic2602260513-dev",
    
    [Parameter(Mandatory=$false)]
    [string]$StagingResourceGroup = "",
    
    [Parameter(Mandatory=$false)]
    [string]$ProductionResourceGroup = "",
    
    # ACR name (same ACR can be used across environments or different ones)
    [Parameter(Mandatory=$false)]
    [string]$AcrName = ""
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "GitHub Actions Azure Auth Setup Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Prompt for required values if not provided
if ([string]::IsNullOrEmpty($GitHubOrg)) {
    $GitHubOrg = Read-Host "Enter your GitHub organization or username"
}

if ([string]::IsNullOrEmpty($GitHubRepo)) {
    $GitHubRepo = Read-Host "Enter your GitHub repository name"
}

if ([string]::IsNullOrEmpty($StagingResourceGroup)) {
    $StagingResourceGroup = Read-Host "Enter staging environment resource group (or press Enter to skip)"
}

if ([string]::IsNullOrEmpty($ProductionResourceGroup)) {
    $ProductionResourceGroup = Read-Host "Enter production environment resource group (or press Enter to skip)"
}

if ([string]::IsNullOrEmpty($AcrName)) {
    $AcrName = Read-Host "Enter Azure Container Registry name"
}

# Set subscription
Write-Host "`nSetting subscription to $SubscriptionId..." -ForegroundColor Yellow
az account set --subscription $SubscriptionId

# Get tenant ID
$tenantId = az account show --query tenantId -o tsv
Write-Host "Tenant ID: $tenantId" -ForegroundColor Green

# Create resource group for identity
Write-Host "`nCreating resource group for Managed Identity..." -ForegroundColor Yellow
az group create --name $IdentityResourceGroup --location $Location --output none
Write-Host "Resource group '$IdentityResourceGroup' created." -ForegroundColor Green

# Create User-assigned Managed Identity
Write-Host "`nCreating User-assigned Managed Identity..." -ForegroundColor Yellow
az identity create `
    --name $IdentityName `
    --resource-group $IdentityResourceGroup `
    --location $Location `
    --output none

# Get identity details
$identityClientId = az identity show --name $IdentityName --resource-group $IdentityResourceGroup --query clientId -o tsv
$identityPrincipalId = az identity show --name $IdentityName --resource-group $IdentityResourceGroup --query principalId -o tsv
$identityId = az identity show --name $IdentityName --resource-group $IdentityResourceGroup --query id -o tsv

Write-Host "Managed Identity created." -ForegroundColor Green
Write-Host "  Client ID: $identityClientId" -ForegroundColor Cyan
Write-Host "  Principal ID: $identityPrincipalId" -ForegroundColor Cyan

# Create federated credentials for each environment
$environments = @("dev", "staging", "production")

Write-Host "`nCreating federated credentials for GitHub environments..." -ForegroundColor Yellow

foreach ($env in $environments) {
    $credentialName = "github-$env"
    $subject = "repo:${GitHubOrg}/${GitHubRepo}:environment:$env"
    
    Write-Host "  Creating credential for environment '$env'..." -ForegroundColor Yellow
    
    $federatedCredential = @{
        name = $credentialName
        issuer = "https://token.actions.githubusercontent.com"
        subject = $subject
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress
    
    az identity federated-credential create `
        --name $credentialName `
        --identity-name $IdentityName `
        --resource-group $IdentityResourceGroup `
        --issuer "https://token.actions.githubusercontent.com" `
        --subject $subject `
        --audiences "api://AzureADTokenExchange" `
        --output none
    
    Write-Host "    Federated credential created for '$env'" -ForegroundColor Green
}

# Assign RBAC roles
Write-Host "`nAssigning RBAC roles..." -ForegroundColor Yellow

# Helper function to assign role
function Assign-Role {
    param(
        [string]$RoleName,
        [string]$Scope,
        [string]$Description
    )
    
    if ([string]::IsNullOrEmpty($Scope)) {
        Write-Host "  Skipping $Description (no scope provided)" -ForegroundColor Gray
        return
    }
    
    Write-Host "  Assigning '$RoleName' to $Description..." -ForegroundColor Yellow
    
    try {
        az role assignment create `
            --assignee-object-id $identityPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role $RoleName `
            --scope $Scope `
            --output none 2>$null
        Write-Host "    Role assigned successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "    Role may already exist or assignment failed. Check manually." -ForegroundColor Yellow
    }
}

# Get subscription scope
$subscriptionScope = "/subscriptions/$SubscriptionId"

# Assign Contributor role to each environment's resource group
$resourceGroups = @{
    "dev" = $DevResourceGroup
    "staging" = $StagingResourceGroup
    "production" = $ProductionResourceGroup
}

foreach ($env in $resourceGroups.Keys) {
    $rg = $resourceGroups[$env]
    if (-not [string]::IsNullOrEmpty($rg)) {
        $rgScope = "$subscriptionScope/resourceGroups/$rg"
        Assign-Role -RoleName "Contributor" -Scope $rgScope -Description "$env resource group ($rg)"
        Assign-Role -RoleName "Azure Kubernetes Service Cluster User Role" -Scope $rgScope -Description "$env AKS cluster"
    }
}

# Assign AcrPush role to ACR
if (-not [string]::IsNullOrEmpty($AcrName)) {
    $acrId = az acr show --name $AcrName --query id -o tsv 2>$null
    if ($acrId) {
        Assign-Role -RoleName "AcrPush" -Scope $acrId -Description "ACR ($AcrName)"
    } else {
        Write-Host "  ACR '$AcrName' not found. Please assign AcrPush role manually." -ForegroundColor Yellow
    }
}

# Output summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Managed Identity Details:" -ForegroundColor Yellow
Write-Host "  Client ID:       $identityClientId" -ForegroundColor White
Write-Host "  Tenant ID:       $tenantId" -ForegroundColor White
Write-Host "  Subscription ID: $SubscriptionId" -ForegroundColor White
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "1. Create GitHub environments (dev, staging, production)" -ForegroundColor White
Write-Host "2. Configure environment variables in each GitHub environment:" -ForegroundColor White
Write-Host "   - AZURE_CLIENT_ID:       $identityClientId" -ForegroundColor Cyan
Write-Host "   - AZURE_TENANT_ID:       $tenantId" -ForegroundColor Cyan
Write-Host "   - AZURE_SUBSCRIPTION_ID: $SubscriptionId" -ForegroundColor Cyan
Write-Host "   - RESOURCE_GROUP:        <environment-specific>" -ForegroundColor Cyan
Write-Host "   - AKS_CLUSTER_NAME:      <environment-specific>" -ForegroundColor Cyan
Write-Host "   - ACR_NAME:              $AcrName" -ForegroundColor Cyan
Write-Host "   - IMAGE_NAME:            petclinic" -ForegroundColor Cyan
Write-Host ""
Write-Host "See .azure/pipeline-setup.md for detailed instructions." -ForegroundColor Yellow
