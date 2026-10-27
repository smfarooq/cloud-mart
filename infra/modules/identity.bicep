// Phase 6: one user-assigned managed identity per workload, so each gets only the roles it needs
// (the API sends to Service Bus; the Functions app receives). User-assigned identities outlive the app,
// can be pre-authorised before the app exists, and can be shared by App Service, Container Apps and AKS.

param location string
param tags object
param apiIdentityName string
param functionsIdentityName string

resource api 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: apiIdentityName
  location: location
  tags: tags
}

resource functions 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: functionsIdentityName
  location: location
  tags: tags
}

output apiId string = api.id
output apiName string = api.name
output apiClientId string = api.properties.clientId
output apiPrincipalId string = api.properties.principalId
output functionsId string = functions.id
output functionsName string = functions.name
output functionsClientId string = functions.properties.clientId
output functionsPrincipalId string = functions.properties.principalId
