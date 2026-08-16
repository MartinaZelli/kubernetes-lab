resource "libvirt_network" "network" {
  name      = "k8s-lab"
  autostart = true

  forward = {
    mode = "nat"
  }

  ips = [
    {
      family  = "ipv4"
      address = "192.168.150.1" # l'host su questa rete = gateway delle VM
      prefix  = 24
      # nessun blocco "dhcp": gli IP li assegna cloud-init
    }
  ]
}
