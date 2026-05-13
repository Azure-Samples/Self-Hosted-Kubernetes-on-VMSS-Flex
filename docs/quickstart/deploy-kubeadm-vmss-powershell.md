# PowerShell Equivalents: Self-Hosted Kubernetes on Azure VMSS Flex

This document gives **PowerShell equivalents** for every step of the [main quickstart](deploy-kubeadm-vmss.md) (which uses bash). Use this if you're working from a Windows workstation without WSL.

> ⚠️ **bash is still the recommended shell** for this guide. PowerShell + `az.cmd` + `cmd.exe` re-parsing introduces several friction points (JMESPath quoting, input redirection, empty-string passphrases, CRLF line endings). Each is documented inline below.
>
> **All node-side scripts must be saved with LF line endings** (not CRLF). VS Code: bottom-right status bar → click `CRLF` → select `LF`. Or normalize at use time: `(Get-Content -Raw foo.sh) -replace "`r`n","`n" | ssh ...`

---

## Prerequisites in PowerShell

```powershell
# Verify Azure CLI version (must be 2.86.0+)
az version --output json | ConvertFrom-Json | Select-Object -ExpandProperty "azure-cli"
az login
```

Generate an SSH keypair (use `-N ""` for empty passphrase — NOT `-N '""'`):

```powershell
ssh-keygen -t rsa -b 4096 -f "$HOME\.ssh\k8s_vmss" -N "" -q -C "k8s-vmss"
```

---

## Save deployment variables in env.ps1

Save the following block to `env.ps1` and dot-source it (`. .\env.ps1`) at the start of each session — and again whenever a long-running `az` command returns. PowerShell can drop `$env:*` variables on session-timeout returns, which manifests as cryptic `expected one argument` errors.

```powershell
$env:SUBSCRIPTION_ID    = (az account show --query id -o tsv)
$env:RESOURCE_GROUP     = "rg-k8s-vmss-flex"
$env:LOCATION           = "northeurope"
$env:CLUSTER_NAME       = "k8s-vmss-flex"
$env:VNET_NAME          = "vnet-k8s"
$env:SUBNET_CONTROL     = "snet-controlplane"
$env:SUBNET_WORKER      = "snet-workers"
$env:NSG_NAME           = "nsg-k8s"
$env:LB_NAME            = "lb-k8s-apiserver"
$env:LB_IP_NAME         = "pip-k8s-apiserver"
$env:CONTROL_VMSS_NAME  = "vmss-k8s-controlplane"
$env:WORKER_VMSS_NAME   = "vmss-k8s-workers"
$env:CONTROL_VM_SIZE    = "Standard_D4s_v5"
$env:WORKER_VM_SIZE     = "Standard_D8s_v5"
$env:K8S_VERSION        = "1.29.3"
$env:ADMIN_USER         = "azureuser"
$env:SSH_KEY_PATH       = "$HOME\.ssh\k8s_vmss.pub"
```

---

## Step 2: Resource group + VNet

```powershell
az group create --name $env:RESOURCE_GROUP --location $env:LOCATION

az network vnet create `
  --resource-group $env:RESOURCE_GROUP `
  --name $env:VNET_NAME `
  --address-prefix 10.0.0.0/16 `
  --subnet-name $env:SUBNET_CONTROL `
  --subnet-prefix 10.0.1.0/24

az network vnet subnet create `
  --resource-group $env:RESOURCE_GROUP `
  --vnet-name $env:VNET_NAME `
  --name $env:SUBNET_WORKER `
  --address-prefix 10.0.2.0/24
```

---

## Step 3: NSG + rules

```powershell
az network nsg create --resource-group $env:RESOURCE_GROUP --name $env:NSG_NAME

$rules = @(
  @{n='allow-ssh';            p=100; proto='Tcp'; port='22';            src='*'},
  @{n='allow-apiserver';      p=110; proto='Tcp'; port='6443';          src='*'},
  @{n='allow-etcd';           p=120; proto='Tcp'; port='2379-2380';     src='10.0.1.0/24'},
  @{n='allow-kubelet';        p=130; proto='Tcp'; port='10250';         src='10.0.0.0/16'},
  @{n='allow-calico-vxlan';   p=140; proto='Udp'; port='4789';          src='10.0.0.0/16'},
  @{n='allow-nodeports';      p=150; proto='Tcp'; port='30000-32767';   src='*'}
)
foreach ($r in $rules) {
  az network nsg rule create `
    --resource-group $env:RESOURCE_GROUP --nsg-name $env:NSG_NAME `
    --name $r.n --priority $r.p --direction Inbound --access Allow `
    --protocol $r.proto --source-address-prefix $r.src --destination-port-range $r.port
}

foreach ($s in @($env:SUBNET_CONTROL, $env:SUBNET_WORKER)) {
  az network vnet subnet update `
    --resource-group $env:RESOURCE_GROUP --vnet-name $env:VNET_NAME `
    --name $s --network-security-group $env:NSG_NAME
}
```

---

## Step 4: Public IP + LB

```powershell
az network public-ip create `
  --resource-group $env:RESOURCE_GROUP --name $env:LB_IP_NAME `
  --sku Standard --allocation-method Static --zone 1 2 3

$env:LB_PUBLIC_IP = az network public-ip show `
  --resource-group $env:RESOURCE_GROUP --name $env:LB_IP_NAME `
  --query ipAddress -o tsv
"Control-plane endpoint: $($env:LB_PUBLIC_IP):6443"

az network lb create `
  --resource-group $env:RESOURCE_GROUP --name $env:LB_NAME --sku Standard `
  --public-ip-address $env:LB_IP_NAME `
  --frontend-ip-name fe-apiserver --backend-pool-name be-controlplane

az network lb probe create `
  --resource-group $env:RESOURCE_GROUP --lb-name $env:LB_NAME --name probe-apiserver `
  --protocol Tcp --port 6443 --interval 5 --threshold 2

az network lb rule create `
  --resource-group $env:RESOURCE_GROUP --lb-name $env:LB_NAME --name rule-apiserver `
  --protocol Tcp --frontend-port 6443 --backend-port 6443 `
  --frontend-ip-name fe-apiserver --backend-pool-name be-controlplane `
  --probe-name probe-apiserver --load-distribution SourceIP
```

---

## Step 5: Control-plane VMSS Flex

```powershell
$cpSubnetId = az network vnet subnet show -g $env:RESOURCE_GROUP `
  --vnet-name $env:VNET_NAME --name $env:SUBNET_CONTROL --query id -o tsv

az vmss create `
  --resource-group $env:RESOURCE_GROUP --name $env:CONTROL_VMSS_NAME `
  --orchestration-mode Flexible --platform-fault-domain-count 1 `
  --vm-sku $env:CONTROL_VM_SIZE --image Ubuntu2204 `
  --admin-username $env:ADMIN_USER --ssh-key-values $env:SSH_KEY_PATH `
  --subnet $cpSubnetId --instance-count 3 `
  --os-disk-size-gb 128 --storage-sku Premium_LRS `
  --lb $env:LB_NAME --backend-pool-name be-controlplane `
  --public-ip-per-vm `
  --tags "role=controlplane" "cluster=$($env:CLUSTER_NAME)"
```

---

## Step 6: Worker VMSS Flex

```powershell
$workerSubnetId = az network vnet subnet show -g $env:RESOURCE_GROUP `
  --vnet-name $env:VNET_NAME --name $env:SUBNET_WORKER --query id -o tsv

az vmss create `
  --resource-group $env:RESOURCE_GROUP --name $env:WORKER_VMSS_NAME `
  --orchestration-mode Flexible --platform-fault-domain-count 1 `
  --vm-sku $env:WORKER_VM_SIZE --image Ubuntu2204 `
  --admin-username $env:ADMIN_USER --ssh-key-values $env:SSH_KEY_PATH `
  --subnet $workerSubnetId --instance-count 3 `
  --os-disk-size-gb 128 --storage-sku Premium_LRS `
  --public-ip-per-vm `
  --tags "role=worker" "cluster=$($env:CLUSTER_NAME)"

# Inventory
az vm list --resource-group $env:RESOURCE_GROUP -d `
  --query "[].{name:name, privateIp:privateIps, publicIp:publicIps, power:powerState}" -o table
```

---

## Step 7: Bootstrap nodes in parallel

```powershell
$bootstrap = (Resolve-Path "..\..\examples\bootstrap-node.sh").Path
$vms = (az vm list --resource-group $env:RESOURCE_GROUP -o json | ConvertFrom-Json) |
       Select-Object -ExpandProperty name

$jobs = @()
foreach ($vm in $vms) {
  $jobs += Start-Job -Name $vm -ScriptBlock {
    param($rg,$name,$script)
    az vm run-command invoke --resource-group $rg --name $name `
      --command-id RunShellScript --scripts "@$script" `
      --query "value[0].message" -o tsv 2>&1
  } -ArgumentList $env:RESOURCE_GROUP, $vm, $bootstrap
}
$jobs | Wait-Job | Out-Null
foreach ($j in $jobs) {
  $out = Receive-Job -Job $j
  if ($out -match "BOOTSTRAP_OK") { "$($j.Name): OK" } else { Write-Warning "$($j.Name): FAILED" }
  Remove-Job -Job $j
}
```

---

## Step 8: kubeadm init on CP1

The JMESPath `[?contains(name,'controlplane')]|[0].name` from the bash version **does not work** in PowerShell because the `|` and `?` get mangled by `cmd.exe`. Filter in PowerShell instead:

```powershell
$allVms = az vm list -g $env:RESOURCE_GROUP -o json | ConvertFrom-Json
$cp1 = ($allVms | Where-Object { $_.name -like '*controlplane*' } |
        Select-Object -ExpandProperty name -First 1)
"CP1 = $cp1"
```

Build the init script — note the `${LB_PUBLIC_IP}` placeholder is substituted by PowerShell here-string interpolation (not bash):

```powershell
$initBody = @"
bash -s <<'EOSCRIPT'
#!/bin/bash
set -eu
PRIV_IP=`$(hostname -I | awk '{print `$1}')

# CRITICAL: Azure SLB hairpin workaround — redirect LB-IP-bound traffic to
# localhost via iptables NAT. /etc/hosts is insufficient (kubeconfig uses
# literal IPs; Linux skips hostname resolution for those).
# See main quickstart Step 8 / concepts/networking.md for rationale.
sudo iptables -t nat -C OUTPUT -p tcp -d $($env:LB_PUBLIC_IP) --dport 6443 \
  -j DNAT --to-destination 127.0.0.1:6443 2>/dev/null || \
  sudo iptables -t nat -A OUTPUT -p tcp -d $($env:LB_PUBLIC_IP) --dport 6443 \
  -j DNAT --to-destination 127.0.0.1:6443

if [ ! -f /etc/kubernetes/admin.conf ]; then
  sudo kubeadm init \
    --control-plane-endpoint "$($env:LB_PUBLIC_IP):6443" \
    --apiserver-cert-extra-sans "$($env:LB_PUBLIC_IP)" \
    --apiserver-advertise-address "`${PRIV_IP}" \
    --upload-certs \
    --pod-network-cidr 192.168.0.0/16 \
    --kubernetes-version $($env:K8S_VERSION)
fi

sudo mkdir -p /home/$($env:ADMIN_USER)/.kube /root/.kube
sudo cp -f /etc/kubernetes/admin.conf /home/$($env:ADMIN_USER)/.kube/config
sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config
sudo chown $($env:ADMIN_USER):$($env:ADMIN_USER) /home/$($env:ADMIN_USER)/.kube/config

echo "===WORKER_JOIN==="
sudo kubeadm token create --print-join-command
echo "===CP_CERT_KEY==="
sudo kubeadm init phase upload-certs --upload-certs 2>&1 | tail -1
EOSCRIPT
"@
$initBody | Out-File -Encoding utf8 -NoNewline ".\kubeadm-init.sh"

$initOut = az vm run-command invoke `
  --resource-group $env:RESOURCE_GROUP --name $cp1 `
  --command-id RunShellScript --scripts "@.\kubeadm-init.sh" `
  --query "value[0].message" -o tsv
$initOut | Out-File -Encoding utf8 ".\kubeadm-init.log"
```

Parse the marker-anchored join material (do **not** match any line starting with "kubeadm join" — kubeadm prints a multi-line example before the markers):

```powershell
$lines = $initOut -split "`r?`n"
$wjIdx = (0..($lines.Length - 1)) | Where-Object { $lines[$_] -match '^===WORKER_JOIN===' } | Select-Object -First 1
$ckIdx = (0..($lines.Length - 1)) | Where-Object { $lines[$_] -match '^===CP_CERT_KEY===' } | Select-Object -First 1
$env:WORKER_JOIN_CMD = $lines[$wjIdx + 1].Trim()
$env:CERT_KEY        = $lines[$ckIdx + 1].Trim()
"WORKER_JOIN: $($env:WORKER_JOIN_CMD)"
"CERT_KEY:    $($env:CERT_KEY)"
```

---

## Step 9: Calico CNI

```powershell
$calico = @'
bash -s <<'EOSCRIPT'
#!/bin/bash
set -eu
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml || echo "(already)"
cat <<EOF | sudo kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata: { name: default }
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLAN
      natOutgoing: Enabled
      nodeSelector: all()
EOF
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if sudo kubectl get ns calico-system >/dev/null 2>&1; then break; fi
  sleep 5
done
sudo kubectl -n calico-system wait --for=condition=Ready pods --all --timeout=300s
EOSCRIPT
'@
$calico | Out-File -Encoding utf8 -NoNewline ".\calico-install.sh"
az vm run-command invoke -g $env:RESOURCE_GROUP -n $cp1 --command-id RunShellScript `
  --scripts "@.\calico-install.sh" --query "value[0].message" -o tsv
```

---

## Step 10: Join CP2 + CP3 sequentially

```powershell
$otherCps = $allVms | Where-Object { $_.name -like '*controlplane*' -and $_.name -ne $cp1 } |
            Select-Object -ExpandProperty name

# Splice the token+hash portion of the worker-join line into the CP-join command
$workerJoinTail = $env:WORKER_JOIN_CMD -replace '^kubeadm join \S+ ', ''

$joinCp = @"
bash -s <<'EOSCRIPT'
#!/bin/bash
set -eu
if [ -f /etc/kubernetes/admin.conf ]; then echo "Already joined."; exit 0; fi
PRIV_IP=`$(hostname -I | awk '{print `$1}')

# Same hairpin workaround required on every joining CP (iptables NAT)
sudo iptables -t nat -C OUTPUT -p tcp -d $($env:LB_PUBLIC_IP) --dport 6443 \
  -j DNAT --to-destination 127.0.0.1:6443 2>/dev/null || \
  sudo iptables -t nat -A OUTPUT -p tcp -d $($env:LB_PUBLIC_IP) --dport 6443 \
  -j DNAT --to-destination 127.0.0.1:6443

sudo kubeadm join $($env:LB_PUBLIC_IP):6443 $workerJoinTail \
  --control-plane --certificate-key $($env:CERT_KEY) \
  --apiserver-advertise-address "`${PRIV_IP}"
echo "CP_JOIN_OK"
EOSCRIPT
"@
$joinCp | Out-File -Encoding utf8 -NoNewline ".\join-cp.sh"

foreach ($cp in $otherCps) {
  "Joining $cp..."
  az vm run-command invoke -g $env:RESOURCE_GROUP -n $cp --command-id RunShellScript `
    --scripts "@.\join-cp.sh" --query "value[0].message" -o tsv
}
```

---

## Step 11: Join workers in parallel

```powershell
$joinWorker = @"
bash -s <<'EOSCRIPT'
#!/bin/bash
set -eu
if sudo test -f /etc/kubernetes/kubelet.conf; then echo "Already joined."; exit 0; fi
sudo $($env:WORKER_JOIN_CMD)
echo "WORKER_JOIN_OK"
EOSCRIPT
"@
$joinWorker | Out-File -Encoding utf8 -NoNewline ".\join-worker.sh"

$workers = $allVms | Where-Object { $_.name -like '*workers*' } | Select-Object -ExpandProperty name
$jobs = @()
foreach ($w in $workers) {
  $jobs += Start-Job -Name $w -ScriptBlock {
    param($rg,$name,$script)
    az vm run-command invoke --resource-group $rg --name $name --command-id RunShellScript `
      --scripts "@$script" --query "value[0].message" -o tsv 2>&1
  } -ArgumentList $env:RESOURCE_GROUP, $w, (Resolve-Path ".\join-worker.sh").Path
}
$jobs | Wait-Job | Out-Null
foreach ($j in $jobs) {
  $out = Receive-Job -Job $j
  if ($out -match "WORKER_JOIN_OK") { "$($j.Name): OK" } else { Write-Warning "$($j.Name): FAILED" }
  Remove-Job -Job $j
}
```

---

## Step 12: Validation via SSH

PowerShell does **not** support `<` for input redirection. Use `Get-Content -Raw | ssh ...` instead.

```powershell
$cp1Vm = az vm show -d -g $env:RESOURCE_GROUP -n $cp1 -o json | ConvertFrom-Json
$cp1Pub = $cp1Vm.publicIps
$sshKey = $env:SSH_KEY_PATH -replace '\.pub$', ''

# Normalize CRLF -> LF before piping (Windows editors save scripts as CRLF;
# bash chokes on \r with "$'\r': command not found")
$script = [System.IO.File]::ReadAllText((Resolve-Path "..\..\examples\validate-cluster.sh"))
$script = $script -replace "`r`n", "`n"

$script | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
              -o BatchMode=yes -i $sshKey "azureuser@$cp1Pub" 'bash -s' 2>&1 |
  Tee-Object -FilePath ".\validate.log" | Out-Null

Get-Content ".\validate.log" | Select-String -Pattern "PASS:|FAIL:|RESULT:" |
  ForEach-Object { $_.Line.Trim() }
```

A healthy cluster reports `RESULT: 13 passed, 0 failed`.

> If your corporate egress firewall blocks outbound port 22, run validation via `az vm run-command` instead — but be aware the run-command API truncates output at ~4 KB and will cut off the report around Test 8.

---

## Tear down

```powershell
az group delete --name $env:RESOURCE_GROUP --yes --no-wait
```

---

## Common PowerShell-specific pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `argument --resource-group/-g: expected one argument` | `$env:*` variable dropped after long `az` call | Re-dot-source `env.ps1` |
| `[0].name was unexpected at this time` / `unrecognized arguments` | `cmd.exe` re-parses JMESPath `\|`, `?`, `[` in `--query` | Use `-o json \| ConvertFrom-Json \| Where-Object {...}` |
| `Enter passphrase for key` despite `-N '""'` | PowerShell passes literal `""` as the passphrase | Use `ssh-keygen -N "" -q` (empty PS string) |
| `The '<' operator is reserved for future use` | PowerShell doesn't support `<` input redirection | Use `Get-Content -Raw foo.sh \| ssh ... 'bash -s'` |
| `bash: line N: $'\r': command not found` over ssh | Script saved with CRLF line endings | `(Get-Content -Raw foo.sh) -replace "\`r\`n","\`n" \| ssh ...` |
| `Terminate batch job (Y/N)?` after Ctrl+C in `az` | Pwsh + az.cmd interactive batch prompt | Press `Y` to confirm |
