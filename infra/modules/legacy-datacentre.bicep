// Phase 15: the "on-premises" datacentre that CloudMart replaces, simulated in its own resource group. One small
// Linux server plays the legacy shop's database and file server: PostgreSQL 16 with seven years of orders, a folder
// of product photos, and a cron job that keeps taking orders until the cutover. Deleting the resource group at the
// end of the lab is the "retire" step.
//
// It is deliberately not connected to CloudMart's network: like most first migration waves, it reaches Azure over
// the internet, with Entra ID and TLS. Phase 13's VPN or ExpressRoute is the private path a real datacentre would add.
// Nothing reaches it from the internet either: the lab drives it with Run Command, through the VM agent.

param location string
param tags object
param vnetName string
param serverName string

@description('Azure needs one for a Linux VM even though nobody signs in with it: the lab uses Run Command.')
param sshPublicKey string
param adminUsername string = 'azureuser'
param vmSize string = 'Standard_B2ats_v2'

@description('Daily auto-shutdown, HHmm in UTC. A deallocated VM costs only its disk.')
param shutdownTimeUtc string = '1900'

// A private range that doesn't overlap CloudMart's 10.20.0.0/16 spoke or the 10.0.0.0/16 hub, as a real datacentre's
// must not if you ever connect them.
var addressPrefix = '172.16.0.0/24'

// Custom data is fixed when Azure creates the VM. After editing the files under deploy/migration/legacy-shop, delete
// the legacy resource group and deploy again. cloud-config is YAML, and JSON is valid YAML, so the object below is
// written as JSON; the seed files travel base64-encoded so nothing in them needs escaping.
var cloudConfig = {
  package_update: true
  packages: ['postgresql', 'imagemagick', 'fonts-dejavu-core', 'jq']
  write_files: [
    {
      path: '/opt/legacy-shop/seed-database.sql'
      encoding: 'b64'
      content: base64(loadTextContent('../../deploy/migration/legacy-shop/seed-database.sql'))
      permissions: '0644'
    }
    {
      path: '/opt/legacy-shop/trade.sql'
      encoding: 'b64'
      content: base64(loadTextContent('../../deploy/migration/legacy-shop/trade.sql'))
      permissions: '0644'
    }
    {
      path: '/opt/legacy-shop/seed-images.sh'
      encoding: 'b64'
      content: base64(loadTextContent('../../deploy/migration/legacy-shop/seed-images.sh'))
      permissions: '0755'
    }
  ]
  runcmd: [
    // deploy/migration/.gitattributes keeps these files LF in a Windows checkout. This catches an editor that saved
    // them with CRLF, which bash can't run.
    'sed -i "s/\\r$//" /opt/legacy-shop/*'
    // AzCopy isn't in Ubuntu's archive: Microsoft publishes it as a tarball.
    'curl -sSL https://aka.ms/downloadazcopy-v10-linux | tar -xz --strip-components=1 -C /usr/local/bin --wildcards "*/azcopy"'
    'sudo -u postgres psql -v ON_ERROR_STOP=1 -f /opt/legacy-shop/seed-database.sql'
    '/opt/legacy-shop/seed-images.sh'
    // The shop is still trading: one order a minute until the cutover makes the database read-only.
    'echo "* * * * * postgres psql -qX -d legacyshop -f /opt/legacy-shop/trade.sql 2>&1 | logger -t legacy-shop" > /etc/cron.d/legacy-shop'
  ]
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-servers-nsg'
  location: location
  tags: tags
  // No rules: the defaults already refuse everything from the internet. Run Command needs no inbound port.
  properties: { securityRules: [] }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [
      {
        name: 'snet-servers'
        properties: {
          addressPrefix: addressPrefix
          networkSecurityGroup: { id: nsg.id }
          // The datacentre's internet edge: apt, AzCopy's download and the copy to Azure all go out this way. Azure
          // is retiring implicit outbound access for new subnets, so it's switched on explicitly. A production
          // subnet would use a NAT gateway (about $32/month) instead.
          defaultOutboundAccess: true
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${serverName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: { subnet: { id: vnet.properties.subnets[0].id }, privateIPAllocationMethod: 'Dynamic' }
      }
    ]
  }
}

resource server 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: serverName
  location: location
  tags: tags
  // Stands in for the identity Azure Arc gives a real server outside Azure: AzCopy and the PostgreSQL tools sign in
  // with it, so the migration needs no key, SAS or password.
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: serverName
      adminUsername: adminUsername
      customData: base64('#cloud-config\n${string(cloudConfig)}')
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

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${serverName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: shutdownTimeUtc }
    timeZoneId: 'UTC'
    targetResourceId: server.id
  }
}

output serverName string = server.name
output principalId string = server.identity.principalId
output vnetName string = vnet.name
