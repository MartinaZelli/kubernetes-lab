resource "libvirt_cloudinit_disk" "vm_init" {
  for_each = local.vms
  name     = "${each.value.hostname}-cloudinit"

  meta_data = <<-EOF
    instance-id: ${each.value.hostname}
    local-hostname: ${each.value.hostname}
  EOF

  user_data = <<-EOF
    #cloud-config
    hostname: ${each.value.hostname}
    fqdn: ${each.value.hostname}.${each.value.domain}
    users:
      - name: ubuntu
        groups: sudo
        shell: /bin/bash
        sudo: ['ALL=(ALL) NOPASSWD:ALL']
        ssh_authorized_keys:
          - ${trimspace(file(var.ssh_public_key_path))}
    write_files:
      - path: /etc/apt/preferences.d/no-snapd
        content: |
          Package: snapd
          Pin: release a=*
          Pin-Priority: -10
      - path: /etc/apt/apt.conf.d/99force-ipv4
        content: |
          Acquire::ForceIPv4 "true";
      - path: /etc/hosts
        content: |
          127.0.0.1   localhost
          ${join("\n      ", local.hosts_by_cluster[each.value.cluster])}
          ::1 ip6-localhost ip6-loopback
          fe00::0 ip6-localnet
          ff00::0 ip6-mcastprefix
          ff02::1 ip6-allnodes
          ff02::2 ip6-allrouters
          ff02::3 ip6-allhosts
    package_update: true
    package_upgrade: false
    packages:
      - qemu-guest-agent
    runcmd:
      - DEBIAN_FRONTEND=noninteractive apt-get -y purge unattended-upgrades snapd
      - DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
      - rm -rf /root/snap /home/ubuntu/snap
  EOF

  network_config = <<-EOF
    version: 2
    ethernets:
      eth0:
        match:
          macaddress: "${each.value.mac}"
        set-name: eth0
        addresses:
          - "${each.value.ip}/24"
        routes:
          - to: default
            via: ${local.gateway}
        nameservers:
          addresses: ${jsonencode(each.value.nameservers)}
          search: ${jsonencode(each.value.search)}
        dhcp4: false
        dhcp6: false
        accept-ra: false
  EOF

  # una volta generato, il cloud-init di una VM esistente
  # non va più toccato. Le VM nuove ricevono comunque il contenuto corretto
  # al momento della creazione.
  lifecycle {
    ignore_changes = [user_data, network_config, meta_data]
  }
}
