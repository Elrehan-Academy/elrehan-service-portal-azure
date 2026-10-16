targetScope = 'resourceGroup'

@description('Azure region for the ESP deployment.')
param location string = resourceGroup().location

@description('Resource naming prefix.')
@minLength(3)
@maxLength(40)
param namePrefix string = 'esp'

@description('Networking mode. Use new to create an ESP VNet/subnet, or existing to attach ESP to an existing subnet.')
@allowed([
  'new'
  'existing'
])
param networkMode string = 'new'

@description('Virtual network address space used when networkMode is new.')
param vnetAddressPrefix string = '10.20.0.0/24'

@description('ESP application subnet address prefix used when networkMode is new.')
param subnetAddressPrefix string = '10.20.0.0/28'

@description('Existing subnet resource ID used when networkMode is existing.')
param existingSubnetResourceId string = ''

@description('CIDR allowed to connect to SSH, for example 203.0.113.10/32.')
param sshSourceAddressPrefix string

@description('Azure VM size.')
param vmSize string = 'Standard_B2s'

@description('Linux administrator username.')
param adminUsername string = 'azureuser'

@description('Linux VM authentication method.')
@allowed([
  'sshPublicKey'
  'password'
])
param authenticationType string = 'sshPublicKey'

@description('SSH public key used when authenticationType is sshPublicKey.')
param sshPublicKey string = ''

@secure()
@description('Linux administrator password used when authenticationType is password.')
param adminPassword string = ''

@description('Azure Public IP DNS label. Leave empty to disable the Azure-provided FQDN.')
param dnsLabel string = ''

@description('ESP web administrator username.')
param espAdminUsername string = 'admin'

@secure()
@description('ESP web administrator password.')
param espAdminPassword string

@description('Database credential mode. Generated creates database secrets automatically; custom uses user-supplied credentials.')
@allowed([
  'generated'
  'custom'
])
param databaseCredentialMode string = 'generated'

@description('ESP database username.')
param databaseUsername string = 'itop'

@secure()
@description('ESP database password used when databaseCredentialMode is custom.')
param databasePassword string = ''

@secure()
@description('MariaDB root password used when databaseCredentialMode is custom.')
param databaseRootPassword string = ''

var bootstrapScript = loadTextContent('cloud-init/bootstrap.sh')

var tags = {
  application: 'Elrehan Service Portal'
  managedBy: 'Bicep'
  project: 'ESP'
}

module network 'modules/network.bicep' = if (networkMode == 'new') {
  name: 'esp-network'
  params: {
    location: location
    namePrefix: namePrefix
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddressPrefix: subnetAddressPrefix
    sshSourceAddressPrefix: sshSourceAddressPrefix
    tags: tags
  }
}

var selectedSubnetId = networkMode == 'new'
  ? network!.outputs.subnetId
  : existingSubnetResourceId

module compute 'modules/compute.bicep' = {
  name: 'esp-compute'
  params: {
    location: location
    namePrefix: namePrefix
    subnetId: selectedSubnetId
    vmSize: vmSize
    adminUsername: adminUsername
    authenticationType: authenticationType
    sshPublicKey: sshPublicKey
    adminPassword: adminPassword
    customData: base64(bootstrapScript)
    dnsLabel: dnsLabel
    tags: tags
  }
}

output networkMode string = networkMode
output vnetId string = networkMode == 'new' ? network!.outputs.vnetId : ''
output subnetId string = selectedSubnetId
output nsgId string = networkMode == 'new' ? network!.outputs.nsgId : ''
output vmId string = compute.outputs.vmId
output vmName string = compute.outputs.vmName
output publicIpAddress string = compute.outputs.publicIpAddress
output publicIpFqdn string = compute.outputs.publicIpFqdn
