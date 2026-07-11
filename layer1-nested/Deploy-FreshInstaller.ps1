# Focused deploy: fresh VCF Installer (vcf-m02-inst01) on Trunk-Nobinding
$ErrorActionPreference='Stop'
$VIServer='10.0.0.101'; $VIUser='administrator@vsphere.local'; $VIPass='VMware1!'
$OVA='E:\9.1\VCF-SDDC-Manager-Appliance-9.1.0.0.25371088.ova'
$Net='Trunk-Nobinding'; $DS='vsanDatastore'; $Cluster='Cluster'; $DC='Datacenter'
$name='vcf-m02-inst01'; $fqdn='vcf-m02-inst01.home.lab'; $ip='10.0.1.4'
$mask='255.255.254.0'; $gw='10.0.0.1'; $dns='10.0.0.200'; $domain='home.lab'; $ntp='10.0.1.254'
$pw='VMware1!VMware1!'
function Log($m){ "[{0}] {1}" -f (Get-Date -Format HH:mm:ss),$m | Tee-Object -Append E:\9.1\fresh-installer-deploy.log }
Log "Connecting outer vCenter $VIServer"
$c=Connect-VIServer $VIServer -User $VIUser -Password $VIPass -Force -WarningAction SilentlyContinue
$ds=Get-Datastore -Server $c -Name $DS | Select-Object -First 1
$cl=Get-Cluster -Server $c -Name $Cluster
$vmhost=$cl | Get-VMHost | Where-Object{$_.ConnectionState -eq 'Connected'} | Select-Object -First 1
Log "target host $($vmhost.Name)"
$ovf=Get-OvfConfiguration $OVA
$nml=($ovf.ToHashTable().keys | Where-Object {$_ -Match "NetworkMapping"}).replace("NetworkMapping.","").replace("-","_").replace(" ","_")
$ovf.NetworkMapping.$nml.value=$Net
$ovf.Common.vami.hostname.value=$fqdn
$ovf.vami.SDDC_Manager.ip0.value=$ip
$ovf.vami.SDDC_Manager.netmask0.value=$mask
$ovf.vami.SDDC_Manager.gateway.value=$gw
$ovf.vami.SDDC_Manager.DNS.value=$dns
$ovf.vami.SDDC_Manager.domain.value=$domain
$ovf.vami.SDDC_Manager.searchpath.value=$domain
$ovf.common.guestinfo.ntp.value=$ntp
$ovf.Common.LOCAL_USER_PASSWORD.value=$pw
$ovf.Common.ROOT_PASSWORD.value=$pw
Log "Deploying $name from OVA ..."
$vm=Import-VApp -Source $OVA -OvfConfiguration $ovf -Name $name -Location $cl -VMHost $vmhost -Datastore $ds -DiskStorageFormat thin
Log "Powering on $name ..."
$vm | Start-VM -RunAsync | Out-Null
Log "Fresh installer deploy submitted. Boot ~10-15 min."
Disconnect-VIServer $c -Confirm:$false | Out-Null
