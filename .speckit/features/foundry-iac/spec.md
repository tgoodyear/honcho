# Azure AI Foundry IaC for Honcho

**Feature:** Codify `ave-foundry` Cognitive Services account, model deployments, RBAC, and auth as Bicep  
**Author:** Woodsman (Infra Dev)  
**Date:** 2025-07-11  
**Status:** Draft  
**Requested by:** Trevor Goodyear

---

## 1. Problem Statement

The `ave-foundry.openai.azure.com` Cognitive Services account and its model deployments are entirely hand-provisioned. There is no IaC, no capacity documentation, and authentication relies on a hardcoded JWT in `.env` that expires every hour — requiring a scheduled task (`Refresh-HonchoToken.ps1`) to rotate it every 45 minutes. This is brittle and unreproducible.

### Current State

| Honcho Role | Deployment Name | Model | Transport |
|---|---|---|---|
| Deriver | `gpt-4.1` | GPT-4.1 | `azure_openai` |
| Embedding | `text-embedding-3-small` | text-embedding-3-small | `azure_openai` |
| Summary | `gpt-4.1` | GPT-4.1 | `azure_openai` |
| Dialectic (minimal–medium) | `gpt-4.1` | GPT-4.1 | `azure_openai` |
| Dialectic (high–max) | `gpt-5.4-1` | GPT-5.4-1 | `azure_openai` |
| Dream (deduction + induction) | `gpt-4.1` | GPT-4.1 | `azure_openai` |

All use `USE_ENTRA_ID=true` with API version `2024-12-01-preview`.

---

## 2. Model Selection Analysis

### 2.1 Embedding: `text-embedding-3-small` vs `text-embedding-3-large`

This was the priority question. Honcho embeds conclusions, observations, and messages for semantic search. The corpus is technical — code concepts, architectural decisions, operational findings.

| Metric | text-embedding-3-small | text-embedding-3-large | text-embedding-ada-002 |
|---|---|---|---|
| Dimensions | 1536 | 3072 | 1536 |
| MTEB (English) | 62.3% | 64.6% | 61.0% |
| Retrieval nDCG@10 | 0.689 | 0.709 | ~0.67 |
| Cost / 1M tokens | $0.02 | $0.13 | $0.10 |
| Latency | ~15ms | ~18ms | ~20ms |
| Dimension flexibility | Yes (can truncate) | Yes (can truncate) | No |

**Recommendation: Stay with `text-embedding-3-small` (1536 dimensions).**

Rationale:

1. **Marginal quality gain.** The 3-large model is ~2% better on retrieval benchmarks. For Honcho's use case — searching a few hundred to low-thousands of conclusions per peer — this delta is negligible. The corpus is small enough that recall is already high.
2. **Cost is 6.5x higher.** Embeddings run on every `search`, `query_conclusions`, and `add_messages_to_session` call. This is the highest-volume API call. The 3-small cost advantage matters.
3. **pgvector storage.** Doubling vector dimensions from 1536 to 3072 doubles index size, slows HNSW queries, and increases memory pressure on the `pgvector/pgvector:pg15` container. For a local Docker deployment, this is real.
4. **ada-002 is deprecated.** No reason to adopt it.

**If precision becomes a problem later**, consider:
- Deploying `text-embedding-3-large` truncated to 1536 dimensions (best-of-both-worlds — better accuracy at same storage cost). This requires a re-embed of existing data.
- The `VECTOR_STORE_DIMENSIONS` env var and `EMBEDDING_VECTOR_DIMENSIONS` both default to 1536, which is correct.

### 2.2 Reasoning: GPT-4.1 for Deriver / Summary / Dream

GPT-4.1 is the right choice here. It's GA on Azure (April 2025), supports tool calling (required by Honcho's deriver), has a 1M token context window, and is cost-effective:

| Model | Input / 1M tokens | Output / 1M tokens | Tool calling | Context |
|---|---|---|---|---|
| GPT-4.1 | $2.20 | $8.80 | ✅ | 1M |
| GPT-4.1-mini | $0.40 | $1.60 | ✅ | 1M |
| GPT-4o | $2.50 | $10.00 | ✅ | 128K |

**Recommendation: Keep GPT-4.1 for deriver, summary, and dream.** It's the best price/performance for tool-calling workloads. GPT-4.1-mini could work for summary (which doesn't need tool calling), but the cost savings are marginal given Honcho's low summary volume — not worth a separate deployment.

### 2.3 Dialectic High/Max: GPT-5.4-1

**GPT-5.4 is NOT generally available on Azure as of July 2025.** It's expected around March 2026, with previews potentially arriving late 2025. Your current `.env` references `gpt-5.4-1` as a deployment name — this either:

- Is a preview/early-access deployment, or
- Is a custom deployment name pointing at something else

**Recommendation:**
- **If `gpt-5.4-1` deployment exists and works** — keep it. The Bicep template should declare it as-is. When GA arrives, the deployment will remain valid.
- **If it doesn't exist or is unstable** — fall back to `gpt-4.1` for high/max dialectic. The quality difference for Honcho's dialectic (which is essentially a memory query/reasoning pass) won't be dramatic.
- **Add a fallback** in `.env`: `DIALECTIC_LEVELS__max__MODEL_CONFIG__FALLBACK__MODEL=gpt-4.1` with matching transport/overrides.

### 2.4 Summary of Recommended Deployments

| Deployment Name | Model | SKU | TPM (recommended) | Honcho Roles |
|---|---|---|---|---|
| `gpt-4.1` | gpt-4.1 | Standard | 60K | Deriver, Summary, Dream, Dialectic (min–med) |
| `text-embedding-3-small` | text-embedding-3-small | Standard | 120K | Embedding |
| `gpt-5.4-1` | gpt-5.4-1 | Standard | 30K | Dialectic (high, max) |

---

## 3. Capacity Planning

### 3.1 Usage Patterns

| Feature | Frequency | Token Profile |
|---|---|---|
| **Deriver** | Continuous — runs on every message batch | ~2K input + ~500 output per work unit. 1 worker, polling every 1s. Peak: ~10 units/min during active sessions. |
| **Embedding** | Every message add, every search query | ~200 tokens/call average. High volume — dozens per minute during active use. |
| **Summary** | Periodic — every 20 messages (short) or 60 messages (long) | ~4K input + ~1K output per summary. Low frequency: a few per hour. |
| **Dialectic** | On-demand — user queries via `honcho-chat` | Variable. Minimal/low: ~1K tokens. High/max: ~8K input + ~2K output. Infrequent. |
| **Dream** | Background — idle timeout (60 min), min 8 hours between dreams | ~16K input + ~4K output per dream cycle. Very infrequent. |

### 3.2 TPM Recommendations

| Deployment | Estimated Peak TPM | Recommended Quota | Headroom |
|---|---|---|---|
| `gpt-4.1` | ~25K (deriver bursts) | **60K TPM** | 2.4x — covers concurrent deriver + summary + dream |
| `text-embedding-3-small` | ~10K (search + ingest bursts) | **120K TPM** | 12x — embeddings are cheap and bursty; generous quota avoids 429s |
| `gpt-5.4-1` | ~5K (dialectic queries) | **30K TPM** | 6x — dialectic is interactive, latency matters, but volume is low |

These are conservative for a single-developer local Honcho instance. If additional squad agents start using Honcho concurrently, double the `gpt-4.1` quota to 120K.

---

## 4. Auth Improvement

### 4.1 Current Problem

The `.env` contains `AZURE_OPENAI_AD_TOKEN=eyJ...` — a static JWT that expires every ~1 hour. `Refresh-HonchoToken.ps1` runs as a Windows Scheduled Task every 45 minutes, acquires a fresh token via `az account get-access-token --resource https://cognitiveservices.azure.com`, splices it into `.env`, and force-recreates the `api` and `deriver` containers via `podman compose up -d --force-recreate`. This works but has failure modes:

- If `az login` session expires (token refresh fails after ~90 days), Honcho silently stops working.
- Container restarts disrupt in-flight deriver work.
- The `AZURE_OPENAI_AD_TOKEN` env var is a Honcho-specific override — the upstream SDK should be able to acquire tokens automatically.

### 4.2 How Honcho's Azure OpenAI Auth Actually Works

The `docker-compose.yml` mounts `${USERPROFILE}/.azure:/home/app/.azure:ro` into both `api` and `deriver` containers, and sets `AZURE_CONFIG_DIR=/home/app/.azure`. However, **this is NOT sufficient for automatic token acquisition.**

### 4.3 ❌ TESTED: Removing AZURE_OPENAI_AD_TOKEN Does NOT Work

**Tested 2026-05-15.** Removing `AZURE_OPENAI_AD_TOKEN` from `.env` and relying on `DefaultAzureCredential` fails because:

1. **`AzureCliCredential`: `az` CLI is not installed inside the container** — the mount provides the config/cache directory, but `AzureCliCredential` requires the `az` binary on PATH to refresh tokens. The Honcho container image doesn't include it.
2. **`SharedTokenCacheCredential`: MSAL token cache is DPAPI-encrypted on Windows** — the `.azure/msal_token_cache.json` is encrypted with Windows DPAPI, which cannot be decrypted inside a Linux container.
3. **All other credential types fail** — `EnvironmentCredential` (no env vars), `ManagedIdentityCredential` (no IMDS), `WorkloadIdentityCredential` (no K8s), `VisualStudioCodeCredential` (no broker), `AzurePowerShellCredential` (no PowerShell), `AzureDeveloperCliCredential` (no azd).

**Result: The `AZURE_OPENAI_AD_TOKEN` env var IS required for local Docker.** The refresh script (`Refresh-HonchoToken.ps1`) is the correct solution until Honcho moves to AKS with managed identity.

### 4.4 Recommended Solution (Local Dev) — Improve Existing Refresh

Since `DefaultAzureCredential` cannot work in the container, the refresh script approach is correct. Improve it:

1. **Keep `Refresh-HonchoToken.ps1`** as the primary auth mechanism.
2. **Add health check** after container restart: `curl -sf http://localhost:8000/docs` (verify API responds).
3. **Add alerting on failure** — write to Windows Event Log on token acquisition failure.
4. **Consider a sidecar token-refresh container** — a lightweight container that runs `az CLI` and writes tokens to a shared volume, avoiding the need to restart `api`/`deriver` containers on each refresh. This eliminates the disruption to in-flight deriver work.
5. **Alternative: Install `azure-cli` in the Honcho container** — adds ~500MB to image but enables `AzureCliCredential` natively. Not recommended unless container size is acceptable.

### 4.5 Future: Azure-hosted Honcho (AKS)

When/if Honcho moves to AKS:
- Assign a **User-Assigned Managed Identity** to the pod
- Grant it `Cognitive Services OpenAI User` on the Foundry resource
- Remove all token management — `DefaultAzureCredential` → `ManagedIdentityCredential` automatically

The Bicep template below provisions the RBAC role assignment for both the current user (local dev) and a managed identity (future AKS), selectable via parameter.

---

## 5. Bicep Module Design

### 5.1 Directory Structure

```
honcho-foundry/
├── main.bicep                    # Orchestrator — deploys account + models + RBAC
├── modules/
│   ├── cognitive-account.bicep   # Microsoft.CognitiveServices/accounts
│   ├── model-deployment.bicep    # Microsoft.CognitiveServices/accounts/deployments
│   └── rbac-assignment.bicep     # Microsoft.Authorization/roleAssignments
└── parameters/
    └── dev.bicepparam            # Dev environment values
```

### 5.2 `main.bicep` — Orchestrator

```bicep
// main.bicep — Azure AI Foundry for Honcho
// Deploys the Cognitive Services account, model deployments, and RBAC.

targetScope = 'resourceGroup'

@description('Azure region for deployment')
param location string = resourceGroup().location

@description('Name of the Cognitive Services account')
param accountName string = 'ave-foundry'

@description('Principal ID to grant Cognitive Services OpenAI User role')
param principalId string

@description('Principal type: User (local dev) or ServicePrincipal (managed identity)')
@allowed(['User', 'ServicePrincipal'])
param principalType string = 'User'

@description('Model deployments to create')
param deployments array = [
  {
    name: 'gpt-4.1'
    model: 'gpt-4.1'
    version: '2025-04-14'
    skuName: 'Standard'
    skuCapacity: 60
  }
  {
    name: 'text-embedding-3-small'
    model: 'text-embedding-3-small'
    version: '1'
    skuName: 'Standard'
    skuCapacity: 120
  }
  {
    name: 'gpt-5.4-1'
    model: 'gpt-5.4-1'
    version: '2025-04-14'
    skuName: 'Standard'
    skuCapacity: 30
  }
]

module cognitiveAccount 'modules/cognitive-account.bicep' = {
  name: 'deploy-cognitive-account'
  params: {
    accountName: accountName
    location: location
  }
}

module modelDeployments 'modules/model-deployment.bicep' = [
  for deployment in deployments: {
    name: 'deploy-model-${deployment.name}'
    params: {
      accountName: cognitiveAccount.outputs.accountName
      deploymentName: deployment.name
      modelName: deployment.model
      modelVersion: deployment.version
      skuName: deployment.skuName
      skuCapacity: deployment.skuCapacity
    }
    dependsOn: [cognitiveAccount]
  }
]

module rbac 'modules/rbac-assignment.bicep' = {
  name: 'deploy-rbac'
  params: {
    cognitiveAccountId: cognitiveAccount.outputs.accountId
    principalId: principalId
    principalType: principalType
  }
}

output endpoint string = cognitiveAccount.outputs.endpoint
output accountId string = cognitiveAccount.outputs.accountId
```

### 5.3 `modules/cognitive-account.bicep`

```bicep
// modules/cognitive-account.bicep
// Deploys the Microsoft.CognitiveServices/accounts resource.

@description('Name of the Cognitive Services account')
param accountName string

@description('Azure region')
param location string

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: accountName
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: accountName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true   // Enforce Entra ID only — no API keys
  }
}

output accountName string = account.name
output accountId string = account.id
output endpoint string = account.properties.endpoint
```

Key decisions:
- **`disableLocalAuth: true`** — Forces Entra ID auth. No API keys. This is the correct posture for `USE_ENTRA_ID=true`.
- **`kind: 'OpenAI'`** — Creates an Azure OpenAI resource (not generic Cognitive Services).
- **`sku: S0`** — Standard SKU. The only option for Azure OpenAI.
- **`publicNetworkAccess: 'Enabled'`** — Required for local Docker access. If moved to AKS with Private Endpoint, change to `'Disabled'`.

### 5.4 `modules/model-deployment.bicep`

```bicep
// modules/model-deployment.bicep
// Deploys a model as a child resource of the Cognitive Services account.

@description('Parent account name')
param accountName string

@description('Deployment name (used as the deployment_id in API calls)')
param deploymentName string

@description('Model name from the Azure model catalog')
param modelName string

@description('Model version')
param modelVersion string

@description('SKU name: Standard or ProvisionedManaged')
@allowed(['Standard', 'ProvisionedManaged'])
param skuName string = 'Standard'

@description('Capacity in thousands of tokens per minute (TPM / 1000)')
param skuCapacity int

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: account
  name: deploymentName
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

output deploymentName string = deployment.name
output deploymentId string = deployment.id
```

Notes:
- **`skuCapacity`** is in units of 1K TPM. So `60` = 60K TPM.
- **`versionUpgradeOption: 'OnceCurrentVersionExpired'`** — Auto-upgrades when the current version is deprecated. Safe default; prevents surprise mid-session upgrades.
- **`raiPolicyName`** — Uses Microsoft's default content filtering. Sufficient for internal tooling.

### 5.5 `modules/rbac-assignment.bicep`

```bicep
// modules/rbac-assignment.bicep
// Grants Cognitive Services OpenAI User to the specified principal.

@description('Resource ID of the Cognitive Services account')
param cognitiveAccountId string

@description('Object ID of the principal (user or managed identity)')
param principalId string

@description('Type of principal')
@allowed(['User', 'ServicePrincipal'])
param principalType string

// Cognitive Services OpenAI User — allows calling the OpenAI APIs
// Role definition ID: 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd
var roleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
)

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cognitiveAccountId, principalId, roleDefinitionId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: principalType
  }
}

output roleAssignmentId string = roleAssignment.id
```

Note: The scope is the resource group, which grants access to all Cognitive Services accounts in the RG. To scope to the specific account, the assignment would need to target the account resource directly — but resource-scoped role assignments require `scope` to reference the resource, which is simpler at RG level for a single-account RG.

### 5.6 `parameters/dev.bicepparam`

```bicep
using '../main.bicep'

// Dev environment — single developer, local Docker Honcho
param location = 'eastus'
param accountName = 'ave-foundry'

// Trevor Goodyear's Entra ID Object ID (from JWT claims in .env)
param principalId = '45440d21-3137-4c16-bdc8-0917d5253696'
param principalType = 'User'

// Model deployments with recommended TPM quotas
param deployments = [
  {
    name: 'gpt-4.1'
    model: 'gpt-4.1'
    version: '2025-04-14'
    skuName: 'Standard'
    skuCapacity: 60          // 60K TPM — deriver, summary, dream, dialectic low
  }
  {
    name: 'text-embedding-3-small'
    model: 'text-embedding-3-small'
    version: '1'
    skuName: 'Standard'
    skuCapacity: 120         // 120K TPM — high volume, bursty
  }
  {
    name: 'gpt-5.4-1'
    model: 'gpt-5.4-1'
    version: '2025-04-14'
    skuName: 'Standard'
    skuCapacity: 30          // 30K TPM — dialectic high/max only
  }
]
```

---

## 6. Deployment

### 6.1 Prerequisites

```powershell
# Login and set subscription
az login
az account set --subscription "<AVE subscription>"

# Ensure the resource group exists
az group create --name rg-ave-foundry --location eastus
```

### 6.2 Deploy

```powershell
az deployment group create `
  --resource-group rg-ave-foundry `
  --template-file honcho-foundry/main.bicep `
  --parameters honcho-foundry/parameters/dev.bicepparam
```

### 6.3 Validate (idempotent — safe to re-run)

```powershell
az deployment group what-if `
  --resource-group rg-ave-foundry `
  --template-file honcho-foundry/main.bicep `
  --parameters honcho-foundry/parameters/dev.bicepparam
```

---

## 7. Migration Checklist

After deploying the Bicep template:

- [ ] Verify `ave-foundry.openai.azure.com` endpoint is accessible
- [ ] Verify all three model deployments exist: `gpt-4.1`, `text-embedding-3-small`, `gpt-5.4-1`
- [ ] Verify RBAC: `az role assignment list --scope /subscriptions/.../resourceGroups/rg-ave-foundry --assignee tgoodyear@microsoft.com`
- [ ] Test auth without static token:
  1. Remove `AZURE_OPENAI_AD_TOKEN=eyJ...` line from `~/honcho/.env`
  2. Run `podman compose up -d --force-recreate api deriver`
  3. Check logs: `podman compose logs api --tail 50`
  4. Test: `curl -s http://localhost:8000/health`
  5. Test: `curl -s -X POST http://localhost:8000/v3/workspaces/ave-team/search -H "Content-Type: application/json" -d '{"query":"test"}'`
- [ ] If auth works without token → delete `Refresh-HonchoToken.ps1` and Windows Scheduled Task (`schtasks /delete /tn HonchoTokenRefresh /f`)
- [ ] If auth fails without token → keep refresh script, file issue on Honcho upstream to support `AzureCliCredential` without explicit token

---

## 8. Open Questions

1. **What resource group does `ave-foundry` live in today?** Need to confirm before deploying Bicep to avoid recreating in a different RG.
2. **GPT-5.4-1 availability** — Is this a preview deployment? If it was manually created under a different model name (e.g., `o4-mini` or `gpt-4o`), the Bicep model name needs to match what's actually in the Azure model catalog.
3. **Model version strings** — The `version` params (`2025-04-14`, `1`) need to be validated against the actual deployed versions: `az cognitiveservices account deployment list --name ave-foundry --resource-group <rg>`.
4. **Subscription quota** — Before setting 60K + 120K + 30K TPM, confirm the subscription has enough regional quota. Check: `az cognitiveservices usage list --location eastus`.

---

## 9. Decision Log

| Decision | Rationale |
|---|---|
| Keep `text-embedding-3-small` | 2% quality delta vs 3-large not worth 6.5x cost + doubled pgvector storage for a small local corpus |
| Keep `gpt-4.1` for reasoning roles | Best price/performance for tool-calling. No reason to change. |
| Keep `gpt-5.4-1` for high/max dialectic | If it's deployed and working, don't fix what isn't broken. Add fallback to gpt-4.1. |
| `disableLocalAuth: true` | Enforce Entra ID. No API keys. Consistent with `USE_ENTRA_ID=true` in .env. |
| Standard SKU, not Provisioned | Single-dev workload. Standard pay-per-token is cheaper than provisioned throughput units. |
| Investigate removing `AZURE_OPENAI_AD_TOKEN` | The `.azure/` volume mount should enable automatic credential acquisition. Test before deleting the refresh script. |
