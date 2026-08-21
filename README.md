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

**Due cluster indipendenti** sulla stessa rete libvirt, per poter confrontare le
due installazioni fianco a fianco.

| Cluster | Control plane | Worker | Contesto kubectl |
|---|---|---|---|
| k3s | `k8s-cp` (.10) | `k8s-w1` (.11), `k8s-w2` (.12) | `k3s` |
| kubeadm | `k8s2-cp` (.20) | `k8s2-w1` (.21), `k8s2-w2` (.22) | `kubeadm` |

Control plane 4 GB / 2 vCPU, worker 2 GB / 2 vCPU. Rete NAT libvirt
`192.168.150.0/24`, gateway `192.168.150.1` (l'host).

Su k3s il nodo server è schedulabile; su kubeadm è tainted, quindi i pod utente
girano solo sui due worker.

### Le sottoreti

Quattro livelli sovrapposti, ed è la cosa che confonde di più all'inizio:

| Rete | Chi ci sta |
|---|---|
| `192.168.1.0/24` | la LAN di casa, dove sta l'host |
| `192.168.150.0/24` | le sei VM, sul bridge NAT di libvirt |
| pod | `10.42.0.0/16` su k3s, **`10.244.0.0/16`** su kubeadm |
| service | `10.43.0.0/16` su k3s, `10.96.0.0/12` su kubeadm |

Le sottoreti dei pod dei due cluster **devono differire**: i nodi condividono lo
stesso segmento di rete, e sovrapporle produrrebbe rotte in conflitto.

Da evitare in particolare il `192.168.0.0/16` che Calico propone come default:
collide sia con la LAN di casa sia con la rete delle VM.

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

# Decisioni tecniche

## Rete NAT invece di bridge per le VM

Un bridge metterebbe le VM sulla LAN di casa, ma resta appeso all'interfaccia
fisica: su un portatile, staccare il cavo significa nodi che non si vedono più e
control plane che li marca `NotReady`. Il bridging inoltre non funziona su WiFi,
per come è fatto 802.11.

La rete NAT vive dentro l'host: il cluster regge anche offline. In cambio le VM
non sono raggiungibili dal resto della LAN — irrilevante qui, perché sia
`kubectl` sia il NodePort si usano dall'host.

## Tre nodi invece di due

`kubeadm` applica al control plane la taint
`node-role.kubernetes.io/control-plane:NoSchedule`. Con due VM resterebbe **un
solo nodo schedulabile**, e il requisito "due pod su nodi diversi" sarebbe
impossibile da soddisfare.

Su k3s il nodo server è schedulabile e due basterebbero, ma la stessa
infrastruttura deve servire entrambe le fasi.

## Anti-affinity dura invece di `preferred`

Il requisito chiede la *certezza*, non una preferenza. Con
`requiredDuringSchedulingIgnoredDuringExecution` un pod che non trova un nodo
libero resta `Pending` invece di essere ammassato su uno già occupato.

Verificato anche nel fallimento: portando le repliche a 4 su 3 nodi, il quarto
pod resta in attesa e lo scheduler dichiara
`0/3 nodes are available: 3 node(s) didn't match pod anti-affinity rules`.

`topologySpreadConstraints` sarebbe la scelta migliore con molte repliche su
pochi nodi (accetta una distribuzione 4-3-3 dove l'anti-affinity dura
fallirebbe). Entrambe le alternative sono nel manifest, commentate.

## `StatefulSet` per il database, `Deployment` per il web

Un webserver è senza stato: i pod sono intercambiabili e sostituibili in
qualsiasi ordine. Un database no — ha identità e un volume che deve seguirlo.

Conseguenza dello storage `local-path`: il volume è una directory sul disco di un
nodo, quindi il PersistentVolume nasce con una `nodeAffinity` che **inchioda il
pod a quel nodo**. Se il nodo cade, MySQL non riparte altrove e i dati non sono
replicati. È il comportamento atteso dallo storage locale, ed è il motivo per cui
in produzione i database stanno su storage di rete o si replicano a livello
applicativo.

## NodePort invece di Ingress

Richiesto dal lab, e didatticamente sensato: il NodePort apre la porta su
**tutti** i nodi, non solo su quelli che ospitano un pod. Una richiesta a un nodo
"vuoto" viene inoltrata da kube-proxy attraverso la rete dei pod — il che rende
visibile il livello che un Ingress controller poi nasconde.

Il bilanciamento è probabilistico e avviene **per connessione**, non per
richiesta HTTP: un client con connessione persistente resta legato a un pod.

## Segreti: una sorgente, due oggetti derivati

Un `Secret` vive dentro un namespace e non è leggibile da altri, quindi
l'applicazione in `web` e il database in `db` richiedono due oggetti distinti —
con **nomi di chiave diversi** (`DB_PASSWORD` contro `MYSQL_PASSWORD`).

Invece di due file da tenere sincronizzati a mano, `scripts/gen-secrets.sh` li
deriva entrambi da un'unica sorgente fuori da Git, mappando i nomi con
`env` + `secretKeyRef`. I due Secret ricevono **sottoinsiemi diversi**:
l'applicazione non riceve la password di root, che non le serve.

Un `Secret` Kubernetes è codificato in base64, **non cifrato**: chiunque possa
leggere l'oggetto ne legge il valore. Per versionarli servirebbe SOPS o Sealed
Secrets — segnato tra le cose da fare.

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
| VM per il secondo cluster | ✅ |
| Cluster kubeadm + Calico | ✅ |
| Applicazione su kubeadm | ✅ |

## Da fare

- [ ] NetworkPolicy tra i namespace (ora possibile: Calico le applica)
- [ ] Sonde `readiness` e `liveness` (l'app non ha ancora `/health`)
- [ ] Console seriale nelle VM: `virsh console` non funziona, `vm.tf` definisce
  solo l'output VNC
- [ ] **SOPS** per versionare i segreti cifrati (equivalente di Ansible Vault)
- [ ] Migrare `scripts/` e l'installazione del cluster a ruoli **Ansible**
- [ ] `NetworkPolicy` tra i namespace: oggi `web` e `db` sono separati solo
  logicamente, la rete tra loro è completamente aperta
