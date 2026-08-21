resource "libvirt_volume" "ubuntu" {
  name = "ubuntu.qcow2"
  pool = var.storage_pool

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.ubuntu_image_url
    }
  }
}

resource "libvirt_volume" "vm_disk" {
  for_each = local.vms
  name     = "${each.value.hostname}.qcow2"
  pool     = var.storage_pool
  capacity = each.value.disk_gb * 1024 * 1024 * 1024


  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.ubuntu.path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "vm_init_iso" {
  for_each = local.vms
  name     = "${each.value.hostname}-init.iso"
  pool     = var.storage_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.vm_init[each.key].path
    }
  }
  # Il volume ISO viene letto da cloud-init SOLO al primo avvio della VM.
  # Cambiarne il contenuto su una macchina già in funzione non ha alcun effetto,
  # e il provider non sa aggiornare un volume (Storage volumes cannot be updated).
  # Per cambiare davvero il cloud-init: tofu apply -replace='libvirt_domain.vm["chiave"]'
  lifecycle {
    ignore_changes = [create]
  }
}
