# kubernetes-lab

Costruzione a mano di un cluster Kubernetes su tre macchine virtuali locali, e
deploy sopra di esso di un'applicazione reale (FastAPI + MySQL).

Progetto di studio: l'obiettivo non è avere un cluster, è **capire cosa c'è
dentro**.

## Obiettivi

- cluster con **un solo control plane** e almeno un worker
- un `Deployment` con **due webserver**, con la **garanzia** che i due pod non
  stiano sullo stesso nodo
- accesso al servizio **senza ingress controller**: NodePort o port-forward
- un **database con volume `local-path`**
- **ogni componente nel suo namespace**

## Il percorso in due fasi

**Fase 1 — k3s.** Una distribuzione Kubernetes in un singolo binario, che
installa e configura da sé rete, storage e ingress. Serve ad avere qualcosa che
funziona, e a costruire i manifest dell'applicazione.

**Fase 2 — kubeadm.** Lo stesso risultato, ricostruito installando a mano ogni
componente che k3s aveva incluso. È qui che si impara: ogni pezzo da montare a
mano è un pezzo che prima era invisibile.

Il motivo dell'ordine: partendo da kubeadm si passano giorni su certificati e
rete per ottenere un cluster vuoto che non dice ancora niente. Partendo da k3s si
ha subito un'immagine mentale concreta di cosa si sta cercando di ricostruire.

**I manifest dell'applicazione sono gli stessi in entrambe le fasi.** Non è un
dettaglio organizzativo: è la dimostrazione che Kubernetes è un'interfaccia
standard, non una tecnologia specifica.

## Struttura

```text
kubernetes-lab/
├── infra/        # OpenTofu: le 3 VM su libvirt/KVM
├── scripts/      # prerequisiti dell'host + generazione dei Secret
├── cluster/
│   ├── k3s/      # fase 1: installazione con k3s
│   └── kubeadm/  # fase 2: installazione manuale (da fare)
├── manifests/    # l'applicazione: identica su entrambi i cluster
└── secrets/      # NON versionato: sorgente unica delle credenziali
```

Il criterio è **un livello di astrazione per cartella**:

- `infra/` = le macchine. Non sa niente di Kubernetes.
- `scripts/` = i presupposti dell'host, che il codice OpenTofu dà per scontati.
- `cluster/` = come le macchine diventano un cluster.
- `manifests/` = cosa gira sopra. Non sa niente di come è nato il cluster.

Ogni cartella ha un proprio `README.md` con le scelte, i comandi e le trappole
incontrate.

## Architettura

| Nodo | Ruolo | IP | RAM | vCPU |
|---|---|---|---|---|
| `k8s-cp` | control plane (schedulabile su k3s) | 192.168.150.10 | 4 GB | 2 |
| `k8s-w1` | worker | 192.168.150.11 | 2 GB | 2 |
| `k8s-w2` | worker | 192.168.150.12 | 2 GB | 2 |

Rete NAT libvirt `192.168.150.0/24`, gateway `192.168.150.1` (l'host).

**Tre reti sovrapposte**, che è la cosa che confonde di più all'inizio:

| Rete | Chi ci sta |
|---|---|
| `192.168.1.0/24` | la LAN di casa, dove sta l'host |
| `192.168.150.0/24` | le VM, sul bridge NAT di libvirt |
| `10.42.0.0/16` | i pod, con un blocco `/24` per nodo |
| `10.43.0.0/16` | i Service (ClusterIP), indirizzi virtuali gestiti da kube-proxy |

Applicazione distribuita su due namespace:

- **`web`** — `Deployment` a 2 repliche con anti-affinity, `Service` NodePort
  sulla 30080, `Job` di inizializzazione del database
- **`db`** — `StatefulSet` MySQL con volume `local-path`, `Service` ClusterIP

## Ricostruire tutto da zero

```bash
# 1. prerequisiti dell'host (una volta sola)
sudo ./scripts/host-setup.sh

# 2. le macchine virtuali
cd infra && tofu init && tofu apply && cd ..

# 3. il cluster            → vedi cluster/k3s/README.md
# 4. i segreti
./scripts/gen-secrets.sh

# 5. l'applicazione
kubectl apply -f manifests/
```

Verifica finale:

```bash
kubectl get pods -A -o wide
curl -s http://192.168.150.11:30080/menu/elenco-piatti | head -c 200
```

## Componenti esterni

| Cosa | Dove |
|---|---|
| Codice dell'applicazione | [menu_v2.0](https://github.com/MartinaZelli/menu_v2.0) |
| Immagine container | `ghcr.io/martinazelli/menu:v2` (GHCR, pubblica) |
| Progetto da cui deriva `infra/` | [terraform_exercise](https://github.com/MartinaZelli/terraform_exercise) |

## Cosa NON è versionato

| Percorso | Perché |
|---|---|
| `secrets/` | credenziali in chiaro |
| `manifests/*-secret.yaml` | idem — è versionato solo `*.example.yaml` |
| `*.tfstate*`, `.terraform/` | stato di OpenTofu: mappa dell'infrastruttura, a volte con valori sensibili |
| `k3s.yaml`, `kubeconfig` | credenziali di amministratore del cluster |
| `~/.ssh/config` | configurazione personale, documentata in `infra/README.md` |

`.terraform.lock.hcl` **è** versionato (negazione esplicita nel `.gitignore`):
registra la versione esatta del provider e i suoi checksum.

---

# Le lezioni trasferibili

Le trappole specifiche stanno nei README di ciascuna cartella. Qui i principi
che valgono oltre questo progetto.

**Il codice descrive un livello, non tutti.** OpenTofu descrive le VM, non
l'hypervisor che le ospita. Ogni livello ha presupposti impliciti sul livello
sotto: renderli espliciti (`scripts/`) è metà del lavoro.

**Un `plan` verde non garantisce un `apply` riuscito.** Gli strumenti
dichiarativi validano la coerenza *interna*; l'esistenza delle risorse esterne la
scoprono solo al momento di agire.

**Lo stato dichiarato non è lo stato di ciò che gira dentro.** OpenTofu garantisce
che le risorse corrispondano alla descrizione, non che il sistema dentro le VM sia
come lo immagini. Cloud-init legge la sua configurazione **solo al primo avvio**:
cambiarla richiede ricreare la macchina.

**`apply` rimuove ciò che non è dichiarato.** Non aggiunge soltanto: allinea. È
ciò che rende affidabile l'infrastruttura come codice, ed è il motivo per cui
mescolare comandi imperativi e file dichiarativi sullo stesso oggetto porta guai.

**Quando la documentazione non torna, chiedere allo strumento.** Il provider
libvirt 0.9 è una riscrittura completa e quasi tutti gli esempi online descrivono
lo schema vecchio. `tofu providers schema -json | jq` è la verità per la versione
installata.

**Guardare l'artefatto, non il template.** Tre tentativi persi a ragionare
sull'aritmetica dell'indentazione di un heredoc; il problema si è risolto
leggendo il file *come è arrivato dentro la VM*
(`/var/lib/cloud/instance/user-data.txt`).

**`grep -A N` è pericoloso per il debug di indentazione**: taglia via le righe
*sopra*, e in un caso reale la riga rotta era proprio quella. Usare
`sed -n '/inizio/,/fine/p'`.

**I comandi interattivi non si incollano in blocco.** L'input in coda non va
perso quando un programma prende il terminale: viene eseguito appena la shell
riprende il controllo. Così è stato installato per sbaglio un server k3s
sull'host.

**Gli alias non esistono nelle shell non interattive.** `ssh host 'k get nodes'`
fallisce: bash non legge `~/.bashrc`. Negli script si usano sempre i nomi
completi.

**Cancellare un segreto non lo rimuove dalla storia Git.** Se un segreto vero
finisce in un commit, l'unica risposta corretta è **ruotarlo**.

---

# Stato

| Fase | Stato |
|---|---|
| Infrastruttura (3 VM, rete NAT) | ✅ |
| Prerequisiti host resi persistenti | ✅ |
| Cluster k3s a 3 nodi | ✅ |
| Namespace, Secret, database con volume local-path | ✅ |
| Deployment a 2 repliche con anti-affinity verificata | ✅ |
| Service NodePort | ✅ |
| Applicazione reale al posto di nginx | ✅ |
| Cluster kubeadm | ⬜ |

## Da fare

- [ ] **Fase 2: kubeadm** — l'obiettivo principale che resta
- [ ] Sonde `readiness` e `liveness` (l'app non ha ancora `/health`)
- [ ] Console seriale nelle VM: `virsh console` non funziona, `vm.tf` definisce
  solo l'output VNC
- [ ] **SOPS** per versionare i segreti cifrati (equivalente di Ansible Vault)
- [ ] Migrare `scripts/` e l'installazione del cluster a ruoli **Ansible**
- [ ] `NetworkPolicy` tra i namespace: oggi `web` e `db` sono separati solo
  logicamente, la rete tra loro è completamente aperta
