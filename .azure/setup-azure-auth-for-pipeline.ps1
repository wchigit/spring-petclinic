# ============================================================================
# Azure Authentication Setup for GitHub Actions CI/CD Pipeline
# ============================================================================
# This script creates a User-assigned Managed Identity with federated credentials
# for OIDC authentication from GitHub Actions.
# ============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$GitHubOrg,
    
    [Parameter(Mandatory=$true)]
    [string]$GitHubRepo,
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",
    
    [Parameter(Mandatory=$false)]
    [string]$ManagedIdentityRgName = "rg-github-pipeline-identity",
    
    [Parameter(Mandatory=$false)]
    [string]$ManagedIdentityName = "id-github-petclinic-pipeline"
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Azure Authentication Setup for GitHub Actions" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Login and set subscription
Write-Host "`n[1/7] Setting Azure subscription..." -ForegroundColor Yellow
az account set --subscription $SubscriptionId
$tenantId = az account show --query tenantId -o tsv

# Create resource group for managed identity
Write-Host "`n[2/7] Creating resource group for Managed Identity..." -ForegroundColor Yellow
az group create --name $ManagedIdentityRgName --location $Location --output none

# Create User-assigned Managed Identity
Write-Host "`n[3/7] Creating User-assigned Managed Identity..." -ForegroundColor Yellow
az identity create `
    --name $ManagedIdentityName `
    --resource-group $ManagedIdentityRgName `
    --location $Location `
    --output none

$clientId = az identity show --name $ManagedIdentityName --resource-group $ManagedIdentityRgName --query clientId -o tsv
$principalId = az identity show --name $ManagedIdentityName --resource-group $ManagedIdentityRgName --query principalId -o tsv

Write-Host "  Managed Identity Client ID: $clientId" -ForegroundColor Green

# Create federated credential for dev environment
Write-Host "`n[4/7] Creating federated credential for 'dev' environment..." -ForegroundColor Yellow
$fedCredName = "github-actions-dev"
$subject = "repo:${GitHubOrg}/${GitHubRepo}:environment:dev"

az identity federated-credential create `
    --name $fedCredName `
    --identity-name $ManagedIdentityName `
    --resource-group $ManagedIdentityRgName `
    --issuer "https://token.actions.githubusercontent.com" `
    --subject $subject `
    --audiences "api://AzureADTokenExchange" `
    --output none

Write-Host "  Created federated credential for subject: $subject" -ForegroundColor Green

# Assign Contributor role to target resource groups
Write-Host "`n[5/7] Assigning RBAC roles..." -ForegroundColor Yellow

# Prompt for resource groups
$resourceGroups = @()
Write-Host "Enter the resource group names that the pipeline needs access to (comma-separated):" -ForegroundColor Cyan
$rgInput = Read-Host
$resourceGroups = $rgInput -split "," | ForEach-Object { $_.Trim() }

foreach ($rg in $resourceGroups) {
    Write-Host "  Assigning Contributor role to resource group: $rg" -ForegroundColor Gray
    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role "Contributor" `
        --scope "/subscriptions/$SubscriptionId/resourceGroups/$rg" `
        --output none
}

# Assign AcrPush role for container registry
Write-Host "`n[6/7] Assigning ACR roles..." -ForegroundColor Yellow
Write-Host "Enter the Azure Container Registry name:" -ForegroundColor Cyan
$acrName = Read-Host

$acrId = az acr show --name $acrName --query id -o tsv 2>$null
if ($acrId) {
    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role "AcrPush" `
        --scope $acrId `
        --output none
    Write-Host "  Assigned AcrPush role to ACR: $acrName" -ForegroundColor Green
} else {
    Write-Host "  WARNING: ACR '$acrName' not found. Please assign AcrPush role manually." -ForegroundColor Yellow
}

# Output summary
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "`nCopy these values to your GitHub repository secrets/variables:" -ForegroundColor Yellow
Write-Host ""
Write-Host "AZURE_CLIENT_ID:       $clientId"
Write-Host "AZURE_TENANT_ID:       $tenantId"
Write-Host "AZURE_SUBSCRIPTION_ID: $SubscriptionId"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Create GitHub environment 'dev' in your repository settings"
Write-Host "2. Add the above values as environment variables in the 'dev' environment"
Write-Host "3. Add ACR_NAME, AKS_CLUSTER_NAME, and AKS_RESOURCE_GROUP as environment variables"
Write-Host "4. Configure environment protection rules (optional but recommended)"
Write-Host ""
Write-Host "See .azure/pipeline-setup.md for detailed instructions." -ForegroundColor Cyan
