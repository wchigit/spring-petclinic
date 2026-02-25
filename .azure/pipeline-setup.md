# CI/CD Pipeline Setup Guide

This guide walks you through setting up the GitHub Actions CI/CD pipeline for deploying Spring PetClinic to Azure Kubernetes Service (AKS).

## Prerequisites

- Azure CLI installed and authenticated
- GitHub CLI installed (optional, for automation)
- Access to the GitHub repository with admin permissions
- Existing Azure resources:
  - Resource Group: `rg-petclinic2602251424-dev`
  - AKS Cluster
  - Azure Container Registry (ACR)

## Overview

The pipeline uses **User-assigned Managed Identity with OIDC** for secure, passwordless authentication to Azure. This eliminates the need for storing Azure credentials as secrets.

### Pipeline Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Build &   │────▶│  Push to    │────▶│  Deploy to  │
│    Test     │     │    ACR      │     │    AKS      │
└─────────────┘     └─────────────┘     └─────────────┘
      CI                   CD (dev environment)
```

## Step 1: Azure Authentication Setup

### Option A: Automated Setup (Recommended)

Run the PowerShell setup script:

```powershell
cd .azure
.\setup-azure-auth-for-pipeline.ps1 `
    -SubscriptionId "a4ab3025-1b32-4394-92e0-d07c1ebf3787" `
    -GitHubOrg "YOUR_GITHUB_ORG" `
    -GitHubRepo "spring-petclinic"
```

The script will:
1. Create a resource group for the managed identity
2. Create a User-assigned Managed Identity
3. Configure federated credentials for the `dev` environment
4. Assign necessary RBAC roles (Contributor, AcrPush)

### Option B: Manual Setup

#### 1. Create Managed Identity

```bash
# Create resource group for identity
az group create --name rg-github-pipeline-identity --location eastus

# Create User-assigned Managed Identity
az identity create \
    --name id-github-petclinic-pipeline \
    --resource-group rg-github-pipeline-identity \
    --location eastus

# Get the Client ID and Principal ID
CLIENT_ID=$(az identity show --name id-github-petclinic-pipeline --resource-group rg-github-pipeline-identity --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name id-github-petclinic-pipeline --resource-group rg-github-pipeline-identity --query principalId -o tsv)
```

#### 2. Create Federated Credential

```bash
# For dev environment
az identity federated-credential create \
    --name github-actions-dev \
    --identity-name id-github-petclinic-pipeline \
    --resource-group rg-github-pipeline-identity \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "repo:YOUR_GITHUB_ORG/spring-petclinic:environment:dev" \
    --audiences "api://AzureADTokenExchange"
```

#### 3. Assign RBAC Roles

```bash
# Contributor to resource group
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "/subscriptions/a4ab3025-1b32-4394-92e0-d07c1ebf3787/resourceGroups/rg-petclinic2602251424-dev"

# AcrPush to container registry
ACR_ID=$(az acr show --name YOUR_ACR_NAME --query id -o tsv)
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "AcrPush" \
    --scope $ACR_ID
```

## Step 2: GitHub Environment Setup

### Create GitHub Environment

1. Go to your GitHub repository
2. Navigate to **Settings** → **Environments**
3. Click **New environment**
4. Name it `dev`
5. (Optional) Configure protection rules:
   - Add required reviewers
   - Restrict to specific branches

### Configure Environment Variables

In the `dev` environment, add the following **variables** (not secrets):

| Variable Name | Description | Example Value |
|--------------|-------------|---------------|
| `AZURE_CLIENT_ID` | Managed Identity Client ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `AZURE_TENANT_ID` | Azure AD Tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `AZURE_SUBSCRIPTION_ID` | Azure Subscription ID | `a4ab3025-1b32-4394-92e0-d07c1ebf3787` |
| `ACR_NAME` | Azure Container Registry name | `acrpetclinic` |
| `AKS_CLUSTER_NAME` | AKS cluster name | `aks-petclinic-dev` |
| `AKS_RESOURCE_GROUP` | Resource group containing AKS | `rg-petclinic2602251424-dev` |

### Using GitHub CLI (Optional)

```bash
# Create environment
gh api repos/{owner}/{repo}/environments/dev -X PUT

# Set variables
gh variable set AZURE_CLIENT_ID --env dev --body "YOUR_CLIENT_ID"
gh variable set AZURE_TENANT_ID --env dev --body "YOUR_TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --env dev --body "a4ab3025-1b32-4394-92e0-d07c1ebf3787"
gh variable set ACR_NAME --env dev --body "YOUR_ACR_NAME"
gh variable set AKS_CLUSTER_NAME --env dev --body "YOUR_AKS_NAME"
gh variable set AKS_RESOURCE_GROUP --env dev --body "rg-petclinic2602251424-dev"
```

## Step 3: Kubernetes Namespace Setup

Ensure the `petclinic` namespace exists and has the required secrets:

```bash
# Get AKS credentials
az aks get-credentials --resource-group rg-petclinic2602251424-dev --name YOUR_AKS_NAME

# Create namespace
kubectl create namespace petclinic

# Create database secrets (adjust values as needed)
kubectl create secret generic petclinic-db -n petclinic \
    --from-literal=postgres-url="jdbc:postgresql://YOUR_DB_HOST:5432/petclinic" \
    --from-literal=postgres-user="YOUR_DB_USER" \
    --from-literal=postgres-pass="YOUR_DB_PASSWORD" \
    --from-literal=appinsights-connection-string="YOUR_APPINSIGHTS_CONNECTION_STRING"
```

## Step 4: Attach ACR to AKS

Ensure your AKS cluster can pull images from ACR:

```bash
az aks update \
    --resource-group rg-petclinic2602251424-dev \
    --name YOUR_AKS_NAME \
    --attach-acr YOUR_ACR_NAME
```

## Step 5: Verify Setup

1. Push a commit to the `main` branch
2. Go to **Actions** tab in your GitHub repository
3. Verify the workflow runs successfully:
   - ✅ Build and Test job completes
   - ✅ Deploy to Dev job completes
4. Check the deployment:
   ```bash
   kubectl get pods -n petclinic
   kubectl get svc -n petclinic
   ```

## Troubleshooting

### OIDC Authentication Fails

- Verify the federated credential subject matches exactly:
  ```
  repo:YOUR_ORG/spring-petclinic:environment:dev
  ```
- Ensure the `id-token: write` permission is set in the workflow
- Check that the environment name in GitHub matches the federated credential

### Image Push Fails

- Verify AcrPush role is assigned to the managed identity
- Check ACR name is correct in environment variables

### Deployment Fails

- Verify Contributor role is assigned to the resource group
- Check AKS cluster name and resource group are correct
- Ensure namespace and secrets exist in the cluster

## Adding More Environments

To add staging or production environments:

1. Create additional federated credentials with appropriate subjects:
   ```bash
   az identity federated-credential create \
       --name github-actions-staging \
       --identity-name id-github-petclinic-pipeline \
       --resource-group rg-github-pipeline-identity \
       --issuer "https://token.actions.githubusercontent.com" \
       --subject "repo:YOUR_ORG/spring-petclinic:environment:staging" \
       --audiences "api://AzureADTokenExchange"
   ```

2. Assign RBAC roles to the new environment's resource group

3. Create the environment in GitHub and configure variables

4. Add a new deployment job in the workflow with `needs: deploy-dev`
