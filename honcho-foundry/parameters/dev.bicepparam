using '../main.bicep'

// Dev environment — single developer, local Docker Honcho
param location = 'eastus'
param accountName = 'ave-foundry'

// Trevor Goodyear's Entra ID Object ID (from JWT claims in .env)
param principalId = '45440d21-3137-4c16-bdc8-0917d5253696'
param principalType = 'User'
