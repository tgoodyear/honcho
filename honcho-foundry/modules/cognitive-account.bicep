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
