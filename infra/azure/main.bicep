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

@description('Email address used for Let\'s Encrypt certificate registration and renewal notices.')
param certificateEmail string

@description('Immutable ESP deployment artifact URL. The artifact must match the supplied SHA256 digest.')
param espArtifactUrl string

@description('Expected lowercase SHA256 digest of the ESP deployment artifact.')
@minLength(64)
@maxLength(64)
param espArtifactSha256 string

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

var installerScript = loadTextContent('scripts/install-esp.sh')
var protectedWrapperTemplate = loadTextContent('scripts/run-esp-protected.sh')

var protectedWrapper01 = replace(
  protectedWrapperTemplate,
  '__ESP_ARTIFACT_URL_B64__',
  base64(espArtifactUrl)
)
var protectedWrapper02 = replace(
  protectedWrapper01,
  '__ESP_ARTIFACT_SHA256_B64__',
  base64(espArtifactSha256)
)
var protectedWrapper03 = replace(
  protectedWrapper02,
  '__ESP_FQDN_B64__',
  base64('${dnsLabel}.${location}.cloudapp.azure.com')
)
var protectedWrapper04 = replace(
  protectedWrapper03,
  '__ESP_CERTIFICATE_EMAIL_B64__',
  base64(certificateEmail)
)
var protectedWrapper05 = replace(
  protectedWrapper04,
  '__ESP_ADMIN_USER_B64__',
  base64(espAdminUsername)
)
var protectedWrapper06 = replace(
  protectedWrapper05,
  '__ESP_ADMIN_PASSWORD_B64__',
  base64(espAdminPassword)
)
var protectedWrapper07 = replace(
  protectedWrapper06,
  '__ESP_DATABASE_CREDENTIAL_MODE_B64__',
  base64(databaseCredentialMode)
)
var protectedWrapper08 = replace(
  protectedWrapper07,
  '__ESP_DATABASE_USER_B64__',
  base64(databaseUsername)
)
var protectedWrapper09 = replace(
  protectedWrapper08,
  '__ESP_DATABASE_PASSWORD_B64__',
  base64(databasePassword)
)
var protectedWrapper10 = replace(
  protectedWrapper09,
  '__ESP_DATABASE_ROOT_PASSWORD_B64__',
  base64(databaseRootPassword)
)

var protectedDeploymentScript = base64(protectedWrapper10)

var bootstrapWithInstaller = replace(
  bootstrapScript,
  '# __ESP_INSTALLER_PAYLOAD__',
  concat(
    '# Install the non-secret ESP deployment orchestrator before bootstrap is marked ready.\n',
    'install -d -m 0750 -o root -g root /opt/esp/install\n',
    'echo \'',
    base64(installerScript),
    '\' | base64 --decode > /opt/esp/install/install-esp.sh\n',
    'chown root:root /opt/esp/install/install-esp.sh\n',
    'chmod 0750 /opt/esp/install/install-esp.sh'
  )
)

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
    customData: base64(bootstrapWithInstaller)
    protectedDeploymentScript: protectedDeploymentScript
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
