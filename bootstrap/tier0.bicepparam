using './tier0.bicep'

param location = 'swedencentral'
param tags = {
  project: 'platform'
  owner: 'tiagomccoutinho@hotmail.com'
  'cost-centre': 'lab'
}
param vendingSubjectPrefix = 'repo:tiago-platform-lab@346922760/platform-vending@1431111786'
param platformSharedSubjectPrefix = 'repo:tiago-platform-lab@346922760/platform-shared@1431111665'
param alertEmail = 'tiagomccoutinho@hotmail.com'
