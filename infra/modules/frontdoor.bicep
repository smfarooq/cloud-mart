// Phase 10, part 1: Front Door profile, endpoint and WAF. Created early, because the App Service access
// restriction needs this profile's frontDoorId and the Storage CORS rule needs the endpoint host name.
// Origins and routes come later in frontdoor-routes.bicep, once the apps exist.

param profileName string
param endpointName string
param wafPolicyName string
param tags object

@description('Standard: custom WAF rules only. Premium: Microsoft-managed rule sets, bot protection, Private Link origins.')
@allowed(['Standard_AzureFrontDoor', 'Premium_AzureFrontDoor'])
param sku string = 'Standard_AzureFrontDoor'

var isPremium = sku == 'Premium_AzureFrontDoor'

resource profile 'Microsoft.Cdn/profiles@2024-09-01' = {
  name: profileName
  location: 'global'
  tags: tags
  sku: { name: sku }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-09-01' = {
  parent: profile
  name: endpointName
  location: 'global'
  tags: tags
  properties: { enabledState: 'Enabled' }
}

resource waf 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: wafPolicyName
  location: 'global'
  tags: tags
  sku: { name: sku }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: 'Enabled'
    }
    customRules: {
      rules: [
        {
          name: 'RateLimitApiPerIp'
          priority: 100
          enabledState: 'Enabled'
          ruleType: 'RateLimitRule'
          rateLimitDurationInMinutes: 1
          rateLimitThreshold: 300
          action: 'Block'
          matchConditions: [{ matchVariable: 'RequestUri', operator: 'Contains', matchValue: ['/api/'] }]
        }
      ]
    }
    managedRules: {
      managedRuleSets: isPremium
        ? [
            { ruleSetType: 'Microsoft_DefaultRuleSet', ruleSetVersion: '2.1', ruleSetAction: 'Block' }
            { ruleSetType: 'Microsoft_BotManagerRuleSet', ruleSetVersion: '1.1' }
          ]
        : []
    }
  }
}

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-09-01' = {
  parent: profile
  name: 'waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: { id: waf.id }
      associations: [{ domains: [{ id: endpoint.id }], patternsToMatch: ['/*'] }]
    }
  }
}

output profileName string = profile.name
output endpointName string = endpoint.name
output frontDoorId string = profile.properties.frontDoorId
output endpointHostName string = endpoint.properties.hostName
