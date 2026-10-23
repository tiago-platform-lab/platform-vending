using './tier0.bicep'

param location = 'swedencentral'
param tags = {
  project: 'platform'
  owner: 'tiagomccoutinho@hotmail.com'
  'cost-centre': 'lab'
}
param vendingRepo = 'tiago-platform-lab/platform-vending'
param platformSharedRepo = 'tiago-platform-lab/platform-shared'
param alertEmail = 'tiagomccoutinho@hotmail.com'
