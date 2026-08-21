locals {

  # --- parametri di rete del lab (unica fonte di verità) ---
  base_domain = "k8s.lab.home"
  gateway     = "192.168.150.1" # l'host, sul bridge NAT di libvirt
  public_dns  = [var.dns1, var.dns2]

  # --- default hardware ---
  vm_default = {
    memory  = 2048
    vcpu    = 2
    disk_gb = 20
  }

  vms_raw = {
    "cp" = {
      hostname = "k8s-cp"
      ip       = "192.168.150.10"
      mac      = "02:00:00:02:00:01"
      memory   = 4096 # il control plane regge etcd + apiserver
      cluster  = "k3s"
    },
    "w1" = {
      hostname = "k8s-w1"
      ip       = "192.168.150.11"
      mac      = "02:00:00:02:00:02"
      cluster  = "k3s"
    },
    "w2" = {
      hostname = "k8s-w2"
      ip       = "192.168.150.12"
      mac      = "02:00:00:02:00:03"
      cluster  = "k3s"
    }
    "cpka" = {
      hostname = "k8s2-cp"
      ip       = "192.168.150.20"
      mac      = "02:00:00:03:00:01"
      memory   = 4096 # control plane kubeadm: etcd + apiserver
      cluster  = "kubeadm"
    },
    "wka1" = {
      hostname = "k8s2-w1"
      ip       = "192.168.150.21"
      mac      = "02:00:00:03:00:02"
      cluster  = "kubeadm"
    },
    "wka2" = {
      hostname = "k8s2-w2"
      ip       = "192.168.150.22"
      mac      = "02:00:00:03:00:03"
      cluster  = "kubeadm"
    }
  }


  # default hardware + rete: qui basta un passaggio solo
  vms = {
    for vm_key, vm_config in local.vms_raw : vm_key => merge(
      local.vm_default,
      vm_config,
      {
        domain      = local.base_domain
        nameservers = local.public_dns
        search      = [local.base_domain]
      }
    )
  }

  # righe di /etc/hosts: ogni nodo deve conoscere gli altri due.
  # NB: nel join in cloud_init.tf il separatore ha 6 spazi di indentazione.
  # Quel valore NON subisce la rimozione di <<-EOF (che invece toglie 4 spazi
  # alle righe letterali), quindi va scritto già come deve risultare nel file.
  # Se lo cambi, verifica con: tofu plan | grep -A6 "path: /etc/hosts"
  # righe di /etc/hosts, raggruppate per cluster: ogni nodo conosce solo i propri
  hosts_by_cluster = {
    for nome_cluster in distinct([for vm in local.vms : vm.cluster]) :
    nome_cluster => [
      for vm in local.vms : "${vm.ip}   ${vm.hostname}.${vm.domain}   ${vm.hostname}"
      if vm.cluster == nome_cluster
    ]
  }
}
