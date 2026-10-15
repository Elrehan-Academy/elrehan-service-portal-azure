targetScope = 'resourceGroup'

@description('Azure region for the ESP deployment.')
param location string = resourceGroup().location

@description('Resource naming prefix.')
@minLength(3)
@maxLength(40)
param namePrefix string = 'esp'

@description('Virtual network address space.')
param vnetAddressPrefix string = '10.20.0.0/16'

@description('ESP application subnet address prefix.')
param subnetAddressPrefix string = '10.20.1.0/24'

@description('CIDR allowed to connect to SSH, for example 203.0.113.10/32.')
param sshSourceAddressPrefix string

@description('Azure VM size.')
param vmSize string = 'Standard_B2s'

@description('Linux administrator username.')
param adminUsername string = 'azureuser'

@description('SSH public key used for administrator authentication.')
param sshPublicKey string

@description('Azure Public IP DNS label. Leave empty to disable the Azure-provided FQDN.')
param dnsLabel string = ''

var bootstrapScript = loadTextContent('cloud-init/bootstrap.sh')

var tags = {
  application: 'Elrehan Service Portal'
  managedBy: 'Bicep'
  project: 'ESP'
}

module network 'modules/network.bicep' = {
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

module compute 'modules/compute.bicep' = {
  name: 'esp-compute'
  params: {
    location: location
    namePrefix: namePrefix
    subnetId: network.outputs.subnetId
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    customData: base64(bootstrapScript)
    dnsLabel: dnsLabel
    tags: tags
  }
}

output vnetId string = network.outputs.vnetId
output subnetId string = network.outputs.subnetId
output nsgId string = network.outputs.nsgId
output vmId string = compute.outputs.vmId
output vmName string = compute.outputs.vmName
output publicIpAddress string = compute.outputs.publicIpAddress
output publicIpFqdn string = compute.outputs.publicIpFqdn
