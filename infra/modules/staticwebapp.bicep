// Phase 3: the React SPA on Static Web Apps (global static hosting, free tier).
// The pipeline deploys the built files with the deployment token: az staticwebapp secrets list -n <name>

param name string

@description('Static Web Apps is only offered in a handful of regions (content is served globally regardless).')
@allowed(['westus2', 'centralus', 'eastus2', 'westeurope', 'eastasia'])
param location string
param tags object

resource site 'Microsoft.Web/staticSites@2024-04-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Free', tier: 'Free' }
  properties: {
    allowConfigFileUpdates: true
    stagingEnvironmentPolicy: 'Enabled'
  }
}

output name string = site.name
output hostName string = site.properties.defaultHostname
