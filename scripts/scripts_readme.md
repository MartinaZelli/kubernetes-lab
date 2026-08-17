# scripts/ — prerequisiti dell'host

Questa cartella contiene la configurazione **dell'host** (il PC Arch che fa da
hypervisor), non del lab Kubernetes.

## Perché esiste

Il codice OpenTofu in `infra/` descrive le macchine virtuali. Non descrive
l'hypervisor che le ospita: quello è un presupposto. Ci sono quindi alcune cose
che vanno configurate a mano sull'host e che, se mancano, fanno fallire
`tofu apply` con errori che sembrano non avere niente a che fare con la causa
reale.

Questi script rendono quei presupposti espliciti e ripetibili, invece di
lasciarli in un messaggio di chat o nella memoria di chi li ha fatti la prima
volta.

## Cosa contiene

| File | Ruolo |
|---|---|
| `host-setup.sh` | Punto di ingresso. Esegue tutto. Da lanciare come root. |
| `k8s-lab-firewall.sh` | Le regole `iptables` per la rete NAT delle VM. Viene installato in `/usr/local/bin/`. |
| `k8s-lab-firewall.service` | Unit systemd che riapplica le regole a ogni avvio. Viene installato in `/etc/systemd/system/`. |

## I due problemi che risolve

### 1. Lo storage pool `default` di libvirt

libvirt ha bisogno di un "pool" dichiarato dove tenere i dischi delle VM. Il
pool `default` (`/var/lib/libvirt/images`) di solito viene creato da
`virt-manager` al primo avvio, oppure arriva con i pacchetti di alcune distro.
Su un Arch dove libvirt è stato attivato da riga di comando **non esiste**.

Sintomo se manca:

```
Error: Pool Not Found
Storage pool 'default' not found
```

Nota che `tofu plan` **non** lo rileva: il plan controlla la sintassi e le
dipendenze interne, non l'esistenza delle risorse esterne. Solo `apply` parla
con libvirt.

libvirt separa quattro fasi, ed è il motivo per cui nello script ci sono quattro
comandi invece di uno:

- `pool-define-as` — registra la configurazione
- `pool-build` — predispone lo spazio fisico (qui: crea la directory)
- `pool-start` — lo rende disponibile in questa sessione
- `pool-autostart` — lo riattiva a ogni riavvio dell'host

### 2. Il conflitto Docker / libvirt sul firewall

Questo è il problema serio, e costa ore se non si sa.

Perché il NAT funzioni, il kernel deve inoltrare pacchetti tra la rete virtuale
delle VM e la rete esterna. Quel traffico attraversa la catena `FORWARD` di
`iptables`.

**Docker imposta la policy di `FORWARD` su `DROP`** e ricostruisce le proprie
catene a ogni avvio, spazzando via le regole che libvirt aveva inserito per le
sue reti. Risultato: le VM si parlano tra loro e con l'host, ma **non escono su
Internet**.

Sintomi:

- `ping` al gateway (`192.168.150.1`) → funziona
- `ping 1.1.1.1` dalla VM → 100% packet loss
- `apt` dentro la VM → `Temporary failure resolving 'archive.ubuntu.com'`
  (fallisce il DNS perché anche la query DNS è un pacchetto che deve uscire)
- `sudo iptables -L FORWARD -n` → `policy DROP` e nessuna regola di libvirt

Diagnosi rapida (il ping deve iniziare a funzionare subito):

```bash
sudo iptables -P FORWARD ACCEPT   # SOLO come test, non lasciarlo così
```

La soluzione mirata sono due regole nella catena `DOCKER-USER`, che è la catena
che **Docker riserva all'amministratore e si impegna a non toccare**. Se le
regole finissero direttamente in `FORWARD`, al prossimo riavvio di Docker
sparirebbero come quelle di libvirt.

Servono due regole perché stiamo filtrando su indirizzi e il traffico è
bidirezionale: `-s` autorizza i pacchetti che *partono* dalle VM, `-d` quelli
diretti *a loro* (le risposte).

`-I DOCKER-USER 1` inserisce in **prima** posizione: nel firewall vince la prima
regola che corrisponde, quindi in fondo alla catena sarebbero inutili.

## Come si applica

Dalla radice del repo:

```bash
chmod +x scripts/host-setup.sh scripts/k8s-lab-firewall.sh
sudo ./scripts/host-setup.sh
```

Verifica:

```bash
systemctl status k8s-lab-firewall.service         # atteso: "active (exited)"
sudo iptables -L DOCKER-USER -n --line-numbers    # le due ACCEPT in cima
virsh -c qemu:///system pool-list --all           # default, active=yes, autostart=yes
```

`active (exited)` è lo stato **normale** per un servizio `oneshot` andato a buon
fine: ha girato, ha finito, systemd ricorda che è stato applicato.

Prova end-to-end, da fare con le VM accese:

```bash
ssh -i ~/.ssh/id_k8slab ubuntu@192.168.150.10 'ping -c2 1.1.1.1'
```

## Scelte di implementazione

**`set -euo pipefail`** in testa a ogni script:

- `-e` interrompe al primo comando fallito, invece di proseguire su basi sbagliate
- `-u` tratta come errore l'uso di una variabile non definita (salva dai refusi nei nomi)
- `-o pipefail` fa fallire una pipeline se fallisce un comando qualsiasi, non solo l'ultimo

**Idempotenza.** Gli script descrivono uno *stato desiderato*, non una sequenza
di azioni: rilanciarli dieci volte deve dare lo stesso risultato di lanciarli
una. Nel firewall si ottiene con `iptables -C`, che verifica se la regola esiste
già; per il pool con `virsh pool-info`. Senza, al secondo lancio si
accumulerebbero regole duplicate. È lo stesso principio di OpenTofu e Ansible.

**`Type=oneshot` con `RemainAfterExit=yes`.** Il servizio non è un processo che
resta in vita, è un'azione che si esegue e finisce. Senza `RemainAfterExit`
systemd lo considererebbe morto subito dopo e alcuni comandi lo mostrerebbero
come fallito.

**`After=docker.service`.** La catena `DOCKER-USER` la crea Docker. Se lo script
partisse prima, `iptables` fallirebbe perché la catena non esiste ancora.

**`install` invece di `cp`.** Imposta contenuto e permessi in un colpo solo:
`755` per lo script (eseguibile), `644` per l'unit (solo dati).

## Alternative scartate, e perché

- **`iptables-save` + ricarica all'avvio** — congelerebbe anche le regole *di
  Docker* come sono oggi. Al prossimo aggiornamento o riconfigurazione di Docker
  si avrebbe un conflitto tra le sue regole nuove e quelle vecchie ricaricate.
- **`"ip-forward-no-drop": true` in `/etc/docker/daemon.json`** — risolve alla
  radice ma allenta la postura di sicurezza per *tutti* i container, non solo per
  questo caso.

## Da rifare quando

- Cambia la sottorete delle VM → aggiornare `SUBNET` in `k8s-lab-firewall.sh`
  (deve restare coerente con `addresses` in `infra/network.tf`)
- Si passa da NAT a bridge → le regole diventano inutili, il traffico non
  attraversa più l'host
- Si migra a Ansible → questi script sono il candidato naturale per il primo
  ruolo `host_prereq`

## Disinstallare

```bash
sudo systemctl disable --now k8s-lab-firewall.service
sudo rm /etc/systemd/system/k8s-lab-firewall.service /usr/local/bin/k8s-lab-firewall.sh
sudo systemctl daemon-reload
```

Le regole già inserite in `DOCKER-USER` restano in memoria fino al riavvio o
fino al prossimo restart di Docker.
