# infra/ — le macchine virtuali

Codice OpenTofu che crea le tre VM su cui gira il cluster Kubernetes.

Deriva dal progetto [`terraform_exercise`](https://github.com/MartinaZelli/terraform_exercise)
(lab Active Directory / LDAP), riadattato: rete da bridge a NAT, tre nodi al
posto di quattro, rimossa tutta la logica di appartenenza al dominio AD.

**Prerequisito:** l'host va preparato prima, vedi [`../scripts/README.md`](../scripts/README.md).
Senza quello `tofu apply` fallisce.

## Cosa crea

| Nodo | Ruolo | IP | RAM | vCPU | Disco |
|---|---|---|---|---|---|
| `k8s-cp` | control plane | 192.168.150.10 | 4 GB | 2 | 20 GB |
| `k8s-w1` | worker | 192.168.150.11 | 2 GB | 2 | 20 GB |
| `k8s-w2` | worker | 192.168.150.12 | 2 GB | 2 | 20 GB |

Più la rete NAT `k8s-lab` (`192.168.150.0/24`, gateway `192.168.150.1` = l'host).

Sistema operativo: Ubuntu 24.04 (noble) da immagine cloud, configurata al primo
avvio da cloud-init.

## File

| File | Contenuto |
|---|---|
| `locals.tf` | Definizione delle VM e derivazione dei parametri di rete |
| `network.tf` | La rete NAT di libvirt |
| `volume.tf` | Immagine base Ubuntu, dischi delle VM, ISO di cloud-init |
| `cloud_init.tf` | La configurazione al primo avvio (utente, chiave SSH, `/etc/hosts`, pacchetti) |
| `vm.tf` | Le macchine virtuali |
| `variables.tf` | Parametri configurabili (percorso chiave SSH, DNS, URL immagine) |
| `providers.tf` | Provider `dmacvicar/libvirt` 0.9.7 |

## Uso

Sempre **da dentro `infra/`**: OpenTofu lavora sulla cartella corrente.

```bash
cd infra
tofu init      # prima volta, o dopo aver cambiato provider
tofu fmt       # riallinea l'indentazione dei .tf
tofu validate  # sintassi e riferimenti, NON contatta libvirt
tofu plan      # cosa farebbe: legge libvirt ma non modifica niente
tofu apply     # crea/aggiorna; conferma scrivendo "yes"
tofu destroy   # distrugge tutto
```

Verifica dopo l'apply:

```bash
virsh -c qemu:///system list --all
for n in cp w1 w2; do ssh k8s-$n 'cloud-init status --wait; hostname'; done
```

Serve l'alias SSH in `~/.ssh/config` (vedi sezione in fondo), altrimenti:
`ssh -i ~/.ssh/id_k8slab ubuntu@192.168.150.10`

## Scelte architetturali

### NAT invece di bridge

Il progetto originale usava un bridge sull'interfaccia Ethernet dell'host: le VM
prendevano un IP sulla LAN di casa (`192.168.1.x`) ed erano raggiungibili da
tutti i dispositivi.

Qui si usa una rete NAT interna a libvirt. Motivi:

- **Funziona sempre.** La rete vive dentro l'host, quindi non dipende da cavo,
  WiFi o presenza di rete. I nodi continuano a parlarsi anche offline — e un
  cluster i cui nodi non si vedono va in tilt (il control plane marca i worker
  come `NotReady`).
- Il bridging **non funziona su WiFi**: una scheda in modalità client può
  inviare pacchetti solo col proprio MAC, mentre un bridge deve far uscire i
  MAC delle VM. Su un portatile è un vincolo reale.
- Configurare un bridge sull'host è la parte più fastidiosa e fragile del setup,
  e non ha niente a che vedere con l'argomento di studio.

Costo: le VM **non** sono raggiungibili dal resto della LAN. Irrilevante qui,
perché sia `kubectl` sia il NodePort si usano dall'host.

### Tre VM, non due

kubeadm applica al control plane la taint
`node-role.kubernetes.io/control-plane:NoSchedule`, che impedisce ai pod utente
di girarci. Con 2 VM (1 control plane + 1 worker) resterebbe **un solo nodo
schedulabile**, e il requisito "due pod su due nodi diversi" sarebbe
matematicamente impossibile.

Con k3s il problema non si porrebbe (il nodo server è schedulabile di default),
ma siccome il lab prevede entrambi i percorsi, la stessa infrastruttura serve
per tutti e due.

### DHCP disattivato sulla rete libvirt

Gli IP sono assegnati staticamente da cloud-init. Se anche libvirt li
distribuisse via DHCP ci sarebbero **due autorità** che decidono la stessa cosa.
Una sola fonte di verità — lo stesso principio dell'infrastructure as code.

Conseguenza: nessun DNS conosce i nomi dei nodi, quindi `/etc/hosts` viene
popolato con tutti e tre. Serve perché i nodi Kubernetes devono risolversi per
nome tra loro (kubeadm in particolare li registra con l'hostname).

### Sottorete 192.168.150.0/24

Scelta per non sovrapporsi a:

- `192.168.122.0/24`, la rete `default` di libvirt
- `192.168.1.0/24`, la LAN di casa
- `10.42.0.0/16` e `10.43.0.0/16`, pod e servizi di k3s
- `10.244.0.0/16`, pod di kubeadm con Flannel

Le sovrapposizioni di sottoreti producono bug lunghi da diagnosticare.

### Dimensionamento

Disco a 20 GB e non 10: le immagini dei container occupano spazio, e un nodo che
esaurisce il disco viene marcato `DiskPressure` e Kubernetes gli sfratta i pod.

Control plane a 4 GB perché ci gira etcd, il database dello stato del cluster,
che è la parte più sensibile alla memoria. kubeadm inoltre pretende **almeno
2 vCPU e 2 GB** e si rifiuta di partire se non li trova.

I dischi sono copy-on-write sull'immagine base: tre VM da 20 GB non occupano
60 GB reali, solo le differenze.

---

# Trappole incontrate

Sezione più utile di tutte le altre. Sintomi → causa → rimedio.

## 1. Il provider libvirt 0.9.x ha uno schema completamente diverso

**Sintomo:**
```
Error: Unsupported argument
An argument named "addresses" is not expected here.
```

**Causa.** La 0.9 è una riscrittura basata sul Terraform Plugin Framework che
**ricalca l'XML di libvirt** invece di astrarlo. Quasi tutti gli esempi che si
trovano online (registry incluso) descrivono lo schema legacy 0.8.

Cambiamenti visti:

| Legacy (≤0.8) | 0.9.x |
|---|---|
| `mode = "nat"` | `forward = { mode = "nat" }` |
| `bridge = "virbr1"` | `bridge = { name = "virbr1" }` |
| `addresses = ["192.168.150.0/24"]` | `ips = [{ address = "192.168.150.1", prefix = 24 }]` |
| `dhcp { enabled = false }` | non esiste: si **omette** il blocco `dhcp` |

Nota che `ips[].address` è l'indirizzo **del bridge sull'host** (`.1`), non la
sottorete (`.0`).

**Rimedio: interrogare lo schema invece di cercare esempi.** Il provider porta
con sé la propria definizione, ed è la verità per la versione installata:

```bash
tofu providers schema -json > /tmp/schema.json
jq -r '.provider_schemas[].resource_schemas | keys[]' /tmp/schema.json                      # quali risorse esistono
jq -r '.provider_schemas[].resource_schemas.NOME.block.attributes | keys[]' /tmp/schema.json # quali argomenti accetta
jq '.provider_schemas[].resource_schemas.NOME.block.attributes.ATTRIBUTO' /tmp/schema.json   # struttura interna
```

Due dettagli su `jq`:

- usare `.provider_schemas[]` con le **quadre vuote** (attraversa tutti i valori)
  e non `["registry.terraform.io/..."]`: **OpenTofu usa `registry.opentofu.org`**,
  non il registry di HashiCorp. Con la chiave sbagliata `jq` restituisce `null`
  in silenzio e l'errore che si vede è il fuorviante `null (null) has no keys`.
- `-r` toglie le virgolette: utile per gli elenchi di nomi, da omettere per
  guardare la struttura.

## 2. `Error: Pool Not Found`

Manca lo storage pool `default` di libvirt. Vedi `../scripts/README.md`.

**Lezione generale:** `tofu plan` verifica sintassi e dipendenze interne, **non**
l'esistenza delle risorse esterne. Solo `apply` parla con libvirt. Un plan verde
non garantisce che l'apply funzioni.

## 3. Le VM non escono su Internet (Docker vs libvirt)

`ping` al gateway funziona, `ping 1.1.1.1` no, `apt` dice
`Temporary failure resolving`. Vedi `../scripts/README.md`.

## 4. L'indentazione negli heredoc: la trappola più costosa

**Sintomo.** VM avviata, SSH risponde, ma `Permission denied (publickey)`.
Nel log dentro la VM:

```
util.py[WARNING]: Failed loading yaml blob. Invalid format at line 2 column 1
util.py[DEBUG]: Writing to /home/ubuntu/.ssh/authorized_keys - wb: [600] 0 bytes
```

File creato, **zero byte**. E `cloud-init status` diceva `done` con
`Ran 10 modules with 0 failures`: quando il parser YAML fallisce, cloud-init
**non applica il pezzo buono** e prosegue senza segnalare errori evidenti.

**Causa.** L'heredoc `<<-EOF` di HCL rimuove da ogni riga la quantità di spazi
della riga meno rientrata del blocco (qui `#cloud-config`, 4 spazi). Ma:

> **La rimozione si applica solo al testo letterale del template, NON al
> risultato delle interpolazioni.**

Quindi il separatore di un `join("\n" + spazi, ...)` deve contenere direttamente
l'indentazione **finale** desiderata, non quella del sorgente. Se si scrivono i
10 spazi del sorgente, nel risultato le righe generate hanno 4 spazi in più
delle letterali.

Stesso meccanismo con `file()`, che legge il **newline finale** del file: dentro
un blocco YAML produce una riga di soli spazi che può chiudere la struttura
prematuramente. Rimedio: `trimspace(file(...))`.

**Come diagnosticare, in ordine.** L'errore che abbiamo fatto è ragionare
sull'aritmetica dell'indentazione invece di guardare l'artefatto:

1. il file **come è arrivato nella VM** — questo è il documento decisivo:
   ```bash
   sudo virt-cat -d k8s-cp /var/lib/cloud/instance/user-data.txt
   ```
2. cosa ne ha pensato cloud-init:
   ```bash
   sudo virt-cat -d k8s-cp /var/log/cloud-init.log | grep -iE "authorized_keys|schema|invalid|warn"
   sudo virt-cat -d k8s-cp /var/log/cloud-init-output.log | tail   # richiede sudo: è di root
   ```
3. il template renderizzato, **con contesto largo**:
   ```bash
   tofu plan -no-color | sed -n '/#cloud-config/,/^        EOT/p'
   ```

**Mai usare `grep -A N` per debug di indentazione**: taglia via le righe
*sopra*, e in un caso reale la riga rotta era proprio quella (un `- path:` di
`write_files` finito a colonna 0 mentre guardavamo il blocco `content:` sotto).
`sed -n '/inizio/,/fine/p'` stampa un intervallo e conserva il contesto.

Il criterio di accettazione nel diff del plan: **nessuna riga `+`/`-`
inattesa** dentro il blocco `user_data`.

`virt-cat` sta nel pacchetto **`guestfs-tools`**, non in `libguestfs` (i tool
`virt-*` sono stati separati dalla versione 1.46). Se libguestfs dà errori
strani su Arch: `export LIBGUESTFS_BACKEND=direct`.

## 5. Cloud-init gira solo al primo avvio

**Sintomo.** Modificato `cloud_init.tf`, `tofu plan` mostra solo
`vm_init_iso will be updated in-place` e **non tocca le VM**. Applicando, l'ISO
è corretto ma le macchine continuano a ignorarlo.

**Causa.** Cloud-init legge l'ISO al primo boot, scrive in `/var/lib/cloud/` che
l'istanza è già inizializzata, e ai boot successivi salta tutto. OpenTofu, dal
suo punto di vista, ha ragione: la definizione della VM non è cambiata.

**Lezione generale:** OpenTofu garantisce che le *risorse* corrispondano alla
descrizione, non che il sistema **dentro** le VM sia nello stato che immagini.

**Rimedio.** Ogni modifica a `user_data` richiede di ricreare le macchine:

```bash
tofu destroy
for ip in 10 11 12; do ssh-keygen -R 192.168.150.$ip; done   # le nuove VM avranno chiavi host diverse
tofu apply
```

Senza `ssh-keygen -R` il primo SSH dà l'avviso di possibile intercettazione.

## 6. Il gateway era hardcoded

Nel progetto originale `cloud_init.tf` conteneva `via: 192.168.1.1` scritto a
mano — l'unico valore di rete non derivato. Cambiando sottorete, le VM
sarebbero nate cercando un gateway irraggiungibile: nessun accesso a Internet e
mezza giornata a chiedersi perché.

Ora è `local.gateway`. È il tipico valore che sembra una costante dell'universo
finché non si cambia ambiente.

## 7. apt e IPv6

`getent hosts archive.ubuntu.com` dentro la VM restituisce **solo** indirizzi
IPv6, mentre le VM non hanno IPv6 configurato.

Non era la causa del blocco (quello era il firewall), ma è un rischio latente:
basta un programma che non gestisca bene il ripiego su IPv4 per avere timeout
inspiegabili. Reso deterministico con:

- `/etc/apt/apt.conf.d/99force-ipv4` → `Acquire::ForceIPv4 "true";`
- `accept-ra: false` nel `network_config`, per rendere esplicito che queste VM
  sono IPv4-only

Approccio mirato: si configura il programma, non si disattiva IPv6 nel kernel.
Toccare il kernel per risolvere un problema di un singolo programma è il tipo di
soluzione che si ritorce contro sei mesi dopo.

## 8. `Exec format error` (status 203/EXEC)

Un file eseguibile che systemd non riesce a lanciare: il kernel non trova uno
shebang valido. Cause: shebang non sulla prima riga, spazi o BOM prima di `#!`,
oppure terminatori di riga Windows (`\r\n`).

```bash
file script.sh                       # segnala "with CRLF line terminators"
head -c 40 script.sh | xxd           # primi byte: attesi 23 21 ... 0a (non 0d 0a)
sed -i 's/\r$//' script.sh           # rimuove i \r
```

Si corregge **il sorgente nel repo**, non la copia installata: quella verrebbe
sovrascritta al prossimo deploy.

---

# Debito tecnico / da fare

- [ ] **Nessuna console seriale nelle VM.** `vm.tf` definisce solo l'output VNC,
  quindi `virsh console k8s-cp` risponde
  `cannot find character device <null>`. La console seriale è l'unico modo di
  vedere cosa succede a una VM che non risponde in rete. Ripiego attuale:
  `virt-manager`.
- [ ] `trimspace()` intorno a `file(var.ssh_public_key_path)` (rimuove la riga
  vuota di troppo nel `user_data`; innocua ma sporca).
- [ ] Migrare `../scripts/` a un ruolo Ansible.
- [ ] `SUBNET` in `../scripts/k8s-lab-firewall.sh` deve restare coerente con
  `ips[].address` in `network.tf`: accoppiamento implicito tra due file in
  cartelle diverse, si rompe in silenzio.

---

# Appendice: alias SSH

Da mettere in `~/.ssh/config` (non è nel repo, è configurazione personale):

```
# --- lab Kubernetes ---
Host k8s-cp
    HostName 192.168.150.10
Host k8s-w1
    HostName 192.168.150.11
Host k8s-w2
    HostName 192.168.150.12

Host k8s-cp k8s-w1 k8s-w2
    User ubuntu
    IdentityFile ~/.ssh/id_k8slab
    StrictHostKeyChecking accept-new
```

Poi `chmod 600 ~/.ssh/config`: SSH **ignora in silenzio** i file con permessi
troppo aperti.

SSH legge il file dall'alto e per ogni parametro vince la **prima** definizione
applicabile (l'opposto di `.gitignore`, dove vince l'ultima). Per questo i
blocchi specifici stanno sopra quello condiviso, e un eventuale `Host *`
andrebbe in fondo.
