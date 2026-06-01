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
