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
