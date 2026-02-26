# CI/CD Pipeline Setup Guide

This guide walks you through setting up the GitHub Actions CI/CD pipeline for deploying Spring PetClinic to Azure Kubernetes Service (AKS).

## Prerequisites

- Azure CLI installed and logged in
- GitHub CLI installed (`gh`)
- Access to the GitHub repository with admin permissions
- Azure subscription with existing AKS resources

## Overview

The pipeline performs:
1. **CI (Build & Test)**: Builds the application and runs tests on every push and PR
2. **CD (Deploy)**: Deploys to dev → staging → production environments (only on main branch push)

## Step 1: Create Azure Managed Identity for Pipeline

Run the setup script to create a User-assigned Managed Identity with federated credentials:

```powershell
.\.azure\setup-azure-auth-for-pipeline.ps1
```

This script will:
- Create a new resource group for pipeline identity
- Create a User-assigned Managed Identity
- Configure federated credentials for each environment (dev, staging, production)
- Assign necessary RBAC roles (Contributor to resource groups, AcrPush to ACR)

## Step 2: Create GitHub Environments

Create environments with approval protection rules:

### Using GitHub CLI:

```bash
# Create environments
gh api repos/{owner}/{repo}/environments/dev -X PUT
gh api repos/{owner}/{repo}/environments/staging -X PUT
gh api repos/{owner}/{repo}/environments/production -X PUT
```

### Using GitHub UI:

1. Go to your repository → **Settings** → **Environments**
2. Click **New environment** and create:
   - `dev`
   - `staging`
   - `production`
3. For each environment, configure:
   - **Required reviewers**: Add approvers for staging and production
   - **Wait timer**: Optional delay before deployment

## Step 3: Configure GitHub Environment Variables

For **each environment** (dev, staging, production), configure the following variables:

| Variable Name | Description | Example |
|---------------|-------------|---------|
| `AZURE_CLIENT_ID` | Managed Identity Client ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `AZURE_TENANT_ID` | Azure AD Tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `AZURE_SUBSCRIPTION_ID` | Azure Subscription ID | `a0af06b0-4110-4353-804d-4c228ad5a7c2` |
| `RESOURCE_GROUP` | Resource group name | `rg-petclinic-dev` |
| `AKS_CLUSTER_NAME` | AKS cluster name | `aks-petclinic-dev` |
| `ACR_NAME` | Azure Container Registry name | `acrpetclinicdev` |
| `IMAGE_NAME` | Docker image name | `petclinic` |

### Using GitHub CLI:

```bash
# Set variables for dev environment
gh variable set AZURE_CLIENT_ID --env dev --body "<managed-identity-client-id>"
gh variable set AZURE_TENANT_ID --env dev --body "<your-tenant-id>"
gh variable set AZURE_SUBSCRIPTION_ID --env dev --body "a0af06b0-4110-4353-804d-4c228ad5a7c2"
gh variable set RESOURCE_GROUP --env dev --body "rg-petclinic2602260513-dev"
gh variable set AKS_CLUSTER_NAME --env dev --body "<your-aks-cluster-name>"
gh variable set ACR_NAME --env dev --body "<your-acr-name>"
gh variable set IMAGE_NAME --env dev --body "petclinic"

# Repeat for staging and production environments with appropriate values
```

### Using GitHub UI:

1. Go to **Settings** → **Environments** → Select environment
2. Under **Environment variables**, click **Add variable**
3. Add each variable with the appropriate value for that environment

## Step 4: Verify AKS and ACR Configuration

Ensure your AKS cluster is configured to pull images from ACR:

```bash
# Attach ACR to AKS (if not already done)
az aks update \
  --resource-group <resource-group> \
  --name <aks-cluster-name> \
  --attach-acr <acr-name>
```

## Step 5: Create Kubernetes Namespace and Secrets

Before the first deployment, ensure the namespace and secrets exist:

```bash
# Get AKS credentials
az aks get-credentials --resource-group <resource-group> --name <aks-cluster-name>

# Create namespace
kubectl create namespace petclinic

# Create secrets (replace with actual values)
kubectl create secret generic petclinic-db \
  --namespace petclinic \
  --from-literal=postgres-url="jdbc:postgresql://<host>:5432/<db>" \
  --from-literal=postgres-user="<username>" \
  --from-literal=postgres-pass="<password>" \
  --from-literal=appinsights-connection-string="<connection-string>"
```

## Step 6: Test the Pipeline

1. Push a commit to the `main` branch
2. Monitor the workflow in **Actions** tab
3. CI job runs first (build and test)
4. CD jobs run sequentially: dev → staging → production
5. Approve deployments when prompted (for environments with required reviewers)

## Troubleshooting

### Azure Login Fails
- Verify the Managed Identity has federated credentials configured correctly
- Check that the environment name matches the federated credential subject
- Ensure AZURE_CLIENT_ID, AZURE_TENANT_ID are correct

### ACR Push Fails
- Verify the Managed Identity has `AcrPush` role on the ACR
- Check ACR_NAME is correct (without `.azurecr.io`)

### AKS Deployment Fails
- Verify the Managed Identity has `Azure Kubernetes Service Cluster User Role` on the AKS cluster
- Check kubectl can connect to the cluster
- Verify namespace and secrets exist
