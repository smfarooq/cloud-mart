// Phase 2/3: a small Linux VM with no public IP, reached through Azure Bastion, signing in with Entra ID.
// Once private endpoints are on, this is how you reach the data services (nslookup them from here!).

import { roles } from 'types.bicep'

param name string
param location string
param tags object
param subnetId string
param vnetId string
param bastionSubnetId string

@description('Required even with Entra login. ssh-keygen -t ed25519, then paste the .pub contents.')
param sshPublicKey string
param adminUsername string = 'azureuser'
param vmSize string = 'Standard_B2ats_v2'

@description('Gets "Virtual Machine Administrator Login" so `az ssh vm` / Bastion work with your Entra account.')
param loginPrincipalId string

@description('Developer is free (portal-only, limited regions). Basic is ~$140/month and needs AzureBastionSubnet.')
@allowed(['Developer', 'Basic'])
param bastionSku string = 'Developer'

@description('Daily auto-shutdown, HHmm in UTC.')
param shutdownTimeUtc string = '1900'

// cloud-init: tools for poking at private endpoints from inside the VNet.
var cloudInit = '''
#cloud-config
package_update: true
packages: [dnsutils, postgresql-client, jq]
runcmd:
  - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
'''

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${name}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: { subnet: { id: subnetId }, privateIPAllocationMethod: 'Dynamic' }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
        patchSettings: { patchMode: 'AutomaticByPlatform', assessmentMode: 'AutomaticByPlatform' }
      }
    }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'StandardSSD_LRS' }, deleteOption: 'Delete' }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }] }
    securityProfile: { securityType: 'TrustedLaunch', uefiSettings: { secureBootEnabled: true, vTpmEnabled: true } }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

resource vmLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, loginPrincipalId, roles.vmAdminLogin)
  scope: vm
  properties: {
    principalId: loginPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.vmAdminLogin)
    principalType: 'User'
  }
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${name}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: shutdownTimeUtc }
    timeZoneId: 'UTC'
    targetResourceId: vm.id
  }
}

resource bastionIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (bastionSku == 'Basic') {
  name: 'pip-bas-${name}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: 'bas-${name}'
  location: location
  tags: tags
  sku: { name: bastionSku }
  properties: bastionSku == 'Developer'
    ? { virtualNetwork: { id: vnetId } }
    : {
        ipConfigurations: [
          {
            name: 'ipconfig1'
            properties: { subnet: { id: bastionSubnetId }, publicIPAddress: { id: bastionIp.id } }
          }
        ]
      }
}

output vmName string = vm.name
