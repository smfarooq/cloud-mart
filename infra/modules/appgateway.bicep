// Phase 10 (regional alternative to Front Door): Application Gateway WAF_v2 in front of the API.
// Expensive (fixed hourly cost even when idle). Deploy, experiment, then set deployAppGateway=false and redeploy.

param name string
param location string
param tags object
param workspaceId string
param subnetId string
param backendHostName string

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${name}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: toLower(name) }
  }
}

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = {
  name: '${name}-waf'
  location: location
  tags: tags
  properties: {
    // Start in Detection, read the firewall logs, tune exclusions, then switch to Prevention.
    policySettings: { state: 'Enabled', mode: 'Detection', requestBodyCheck: true, maxRequestBodySizeInKb: 128, fileUploadLimitInMb: 100 }
    managedRules: { managedRuleSets: [{ ruleSetType: 'OWASP', ruleSetVersion: '3.2' }] }
  }
}

var gatewayId = resourceId('Microsoft.Network/applicationGateways', name)

resource gateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: { name: 'WAF_v2', tier: 'WAF_v2' }
    autoscaleConfiguration: { minCapacity: 0, maxCapacity: 2 }
    firewallPolicy: { id: wafPolicy.id }
    gatewayIPConfigurations: [{ name: 'gateway', properties: { subnet: { id: subnetId } } }]
    frontendIPConfigurations: [{ name: 'public', properties: { publicIPAddress: { id: publicIp.id } } }]
    frontendPorts: [{ name: 'http', properties: { port: 80 } }]
    backendAddressPools: [{ name: 'api', properties: { backendAddresses: [{ fqdn: backendHostName }] } }]
    probes: [
      {
        name: 'api-health'
        properties: {
          protocol: 'Https'
          path: '/health/live'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: { statusCodes: ['200-399'] }
        }
      }
    ]
    // App Service routes by Host header, so the gateway must send the app's own host name.
    backendHttpSettingsCollection: [
      {
        name: 'api-https'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
          probe: { id: '${gatewayId}/probes/api-health' }
        }
      }
    ]
    // HTTP only to keep the lab simple. Production: HTTPS listener with a Key Vault certificate.
    httpListeners: [
      {
        name: 'http'
        properties: {
          frontendIPConfiguration: { id: '${gatewayId}/frontendIPConfigurations/public' }
          frontendPort: { id: '${gatewayId}/frontendPorts/http' }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'api'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: { id: '${gatewayId}/httpListeners/http' }
          backendAddressPool: { id: '${gatewayId}/backendAddressPools/api' }
          backendHttpSettings: { id: '${gatewayId}/backendHttpSettingsCollection/api-https' }
        }
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: gateway
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output publicHostName string = publicIp.properties.dnsSettings.fqdn
