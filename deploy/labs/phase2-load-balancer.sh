#!/usr/bin/env bash
# Phase 2 lab: a Standard public Load Balancer (layer 4) in front of two zonal VMs running nginx.
# Separate resource group, so cleanup is one command. Cost: two B1s VMs + a Standard LB, cents per hour.
#
#   ./deploy/labs/phase2-load-balancer.sh [location]
#   az group delete -n rg-cloudmart-lb-lab --yes --no-wait      # when finished
set -euo pipefail

LOCATION=${1:-eastus2}
RG=rg-cloudmart-lb-lab

az group create -n "$RG" -l "$LOCATION" --tags environment=lab -o none

az network vnet create -g "$RG" -n vnet-lb --address-prefix 10.40.0.0/16 \
  --subnet-name web --subnet-prefix 10.40.1.0/24 -o none

# A Standard Load Balancer is closed by default: traffic needs an NSG allow rule.
az network nsg create -g "$RG" -n nsg-web -o none
az network nsg rule create -g "$RG" --nsg-name nsg-web -n allow-http --priority 100 \
  --access Allow --protocol Tcp --destination-port-ranges 80 -o none
az network vnet subnet update -g "$RG" --vnet-name vnet-lb -n web --network-security-group nsg-web -o none

az network public-ip create -g "$RG" -n pip-lb --sku Standard -o none
az network lb create -g "$RG" -n lb-web --sku Standard --public-ip-address pip-lb \
  --frontend-ip-name frontend --backend-pool-name web -o none
az network lb probe create -g "$RG" --lb-name lb-web -n http --protocol Http --port 80 --path / -o none
az network lb rule create -g "$RG" --lb-name lb-web -n http --protocol Tcp \
  --frontend-port 80 --backend-port 80 --frontend-ip-name frontend --backend-pool-name web \
  --probe-name http --disable-outbound-snat true -o none

# VMs without public IPs need an explicit outbound path (default outbound access is being retired).
# An outbound rule on the LB gives them SNAT for package installs.
az network lb outbound-rule create -g "$RG" --lb-name lb-web -n outbound \
  --frontend-ip-configs frontend --protocol All --address-pool web -o none

CLOUD_INIT=$(mktemp)
cat > "$CLOUD_INIT" <<'EOF'
#cloud-config
package_update: true
packages: [nginx]
runcmd:
  - echo "Hello from $(hostname)" > /var/www/html/index.html
EOF

# One VM per availability zone: the LB frontend is zone-redundant, so losing a zone loses one backend, not the service.
for i in 1 2; do
  az vm create -g "$RG" -n "web$i" --image Ubuntu2404 --size Standard_B1s --zone "$i" \
    --vnet-name vnet-lb --subnet web --nsg "" --public-ip-address "" \
    --admin-username azureuser --generate-ssh-keys --custom-data "$CLOUD_INIT" -o none
  az network nic ip-config address-pool add -g "$RG" --nic-name "web${i}VMNic" --ip-config-name "ipconfigweb$i" \
    --lb-name lb-web --address-pool web -o none
done
rm -f "$CLOUD_INIT"

IP=$(az network public-ip show -g "$RG" -n pip-lb --query ipAddress -o tsv)
cat <<EOF

Load balancer: http://$IP   (give cloud-init a minute or two to install nginx)

  for i in \$(seq 10); do curl -s http://$IP; done        # both VMs answer (5-tuple hash distribution)
  az vm stop -g $RG -n web1                               # wait ~30 s for the probe to mark it down
  for i in \$(seq 10); do curl -s http://$IP; done        # only web2 answers

Then explain why this is the wrong tool for path-based routing or TLS offload (Application Gateway, phase 10).
Clean up: az group delete -n $RG --yes --no-wait
EOF
