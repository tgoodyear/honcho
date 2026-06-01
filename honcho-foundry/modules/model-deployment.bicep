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
