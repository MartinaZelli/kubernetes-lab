# cluster/kubeadm — installazione manuale del cluster

Percorso 2 di 2. L'alternativa già realizzata è [`../k3s/`](../k3s/README.md).

Stesso risultato di k3s — un cluster Kubernetes a tre nodi su cui girano
identici i manifest in `../../manifests/` — ma con **ogni componente installato
a mano**.

Il valore di questa fase sta nel confronto: ogni pezzo che qui va montato è un
pezzo che k3s nascondeva.

**Nodi:** `k8s2-cp` (192.168.150.20), `k8s2-w1` (.21), `k8s2-w2` (.22)
**Versione:** Kubernetes v1.36 · containerd 2.2.1 · Ubuntu 24.04
**Rete pod:** `10.244.0.0/16` (CNI: Calico)

---

# La catena di dipendenze

Ogni livello regge quello sopra. Saltarne uno non produce un errore chiaro:
produce un cluster che sembra partire e poi si comporta in modo incomprensibile.

| # | Livello | Se manca |
|---|---|---|
| 1 | Prerequisiti del kernel | il kubelet non parte, o i Service funzionano a intermittenza |
| 2 | containerd | nessun container può essere creato |
| 3 | kubelet, kubeadm, kubectl | niente da installare |
| 4 | `kubeadm init` → control plane | nessun cervello del cluster |
| 5 | CNI (Calico) | i nodi restano `NotReady`, i pod non hanno rete |
| 6 | Join dei worker + storage | niente su cui schedulare, nessun volume |
| 7 | I manifest dell'applicazione | — |

---

# Fase 1 — Prerequisiti del kernel

Da fare su **tutti e tre** i nodi. Sono i controlli che `kubeadm init` esegue in
preflight: se mancano, l'installazione si rifiuta di partire.

## 1.1 Swap disattivato

```bash
for n in ka-cp ka-w1 ka-w2; do echo "--- $n"; ssh $n 'swapon --show; free -h | grep -i swap'; done
```

**Perché.** Il kubelet si rifiuta di partire con lo swap attivo, e non è
arbitrario. Kubernetes decide dove piazzare i pod in base alla memoria
**disponibile** su ogni nodo, e applica i `limits: memory` scritti nei manifest.
Lo swap rende quel modello una finzione: un container "dentro il suo limite"
potrebbe in realtà girare su disco, cento volte più lento, mentre lo scheduler
crede che il nodo abbia memoria che non ha.

Sulle immagini cloud di Ubuntu lo swap **non è configurato**: `swapon --show` non
stampa nulla e `free` mostra `0B`. In quel caso non c'è niente da fare.

Se fosse attivo servirebbero due azioni: `sudo swapoff -a` per la sessione
corrente e commentare la riga di swap in `/etc/fstab` per i riavvii futuri.

## 1.2 Moduli del kernel `overlay` e `br_netfilter`

```bash
for n in ka-cp ka-w1 ka-w2; do echo "--- $n"; ssh $n 'lsmod | grep -E "^overlay|^br_netfilter" || echo "NESSUNO DEI DUE"'; done
```

```bash
for n in ka-cp ka-w1 ka-w2; do ssh $n 'printf "overlay\nbr_netfilter\n" | sudo tee /etc/modules-load.d/k8s.conf > /dev/null && sudo modprobe overlay && sudo modprobe br_netfilter && echo "$(hostname): fatto"'; done
```

### Cos'è un modulo del kernel

Il kernel è il programma che gestisce hardware, memoria, filesystem e rete.
Potrebbe essere un unico blocco compilato con dentro tutto, ma sarebbe enorme e
pieno di codice inutile per la macchina specifica.

Linux usa un'architettura **modulare**: un nucleo minimo più tanti pezzi
caricabili a runtime. Un modulo è un file compilato (`.ko`, *kernel object*) che,
una volta caricato, **diventa parte del kernel** — gira in kernel space, con
pieni privilegi. Non è un file di configurazione da leggere: è codice che entra
nel sistema operativo mentre gira. Da qui il `sudo`.

Se ne usano già continuamente senza saperlo: il driver della scheda WiFi,
`kvm_intel` per la virtualizzazione, il supporto per il filesystem di una
chiavetta USB. Il kernel li carica da sé quando rileva l'hardware.

`modprobe` li carica a mano, risolvendo anche le dipendenze.

### `overlay` — il filesystem a strati

È ciò che rende possibili i container.

Un'immagine è fatta di **layer** sovrapposti: uno con Alpine, uno con Python, uno
con le dipendenze, uno col codice. `overlay` (OverlayFS) permette al kernel di
presentare più directory sovrapposte come **un unico filesystem coerente**.

Il container vede un `/` normale. Sotto ci sono i layer dell'immagine in **sola
lettura** più uno strato scrivibile suo: quando scrive un file che sta in un
layer inferiore, quel file viene copiato nello strato superiore e modificato lì —
*copy-on-write*.

È lo stesso principio del `backing_store` dei dischi qcow2 in `infra/`: tre VM da
20 GB che non occupano 60 GB perché condividono l'immagine base e registrano solo
le differenze. Stessa idea, un livello più su.

Senza `overlay`, containerd non può creare container.

### `br_netfilter` — far vedere il bridge al firewall

Più sottile, ed è causa di guasti che sembrano casuali.

I pod di un nodo sono attaccati a un **bridge** virtuale — uno switch software,
come `virbr1` per le VM. Un bridge lavora a livello 2 (indirizzi MAC), mentre
iptables filtra a livello 3 (indirizzi IP). Per default il traffico che passa da
un bridge **non attraversa** le regole di iptables: sta a un livello più basso,
non le incontra proprio.

Ma kube-proxy implementa i Service **proprio con regole iptables**: quando un pod
contatta `mysql.db.svc.cluster.local`, è una regola iptables a riscrivere la
destinazione verso l'IP reale del pod.

Senza `br_netfilter`, il traffico tra pod **dello stesso nodo** bypasserebbe
quelle regole. Risultato: i Service funzionano tra nodi diversi e non funzionano
sullo stesso nodo. Un comportamento che fa impazzire, perché sembra casuale.

Il modulo colma quel salto: fa passare il traffico del bridge attraverso
netfilter, il framework di filtraggio del kernel di cui iptables è l'interfaccia.

Caricare il modulo però **non basta**: serve anche dirgli di farlo davvero, ed è
il primo dei parametri sysctl.

## 1.3 Parametri sysctl

```bash
for n in ka-cp ka-w1 ka-w2; do ssh $n 'printf "net.bridge.bridge-nf-call-iptables  = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward                 = 1\n" | sudo tee /etc/sysctl.d/k8s.conf > /dev/null && sudo sysctl --system > /dev/null 2>&1 && echo "$(hostname): applicato"'; done
```

```bash
for n in ka-cp ka-w1 ka-w2; do echo "--- $n"; ssh $n 'sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward'; done
```

`sysctl` è l'interfaccia per leggere e scrivere i parametri del kernel a runtime.
Vivono sotto `/proc/sys/` e ognuno controlla un comportamento del sistema.

| Parametro | Cosa fa |
|---|---|
| `net.bridge.bridge-nf-call-iptables` | il compagno di `br_netfilter`: il modulo rende *possibile* far passare il traffico del bridge per netfilter, questo glielo fa **fare** |
| `net.bridge.bridge-nf-call-ip6tables` | lo stesso per IPv6. Le VM non lo usano, ma `kubeadm` lo controlla in preflight |
| `net.ipv4.ip_forward` | autorizza il kernel a inoltrare pacchetti tra interfacce diverse |

`net.ipv4.ip_forward` è **esattamente** il parametro verificato sull'host Arch
quando le VM non uscivano su Internet. Qui serve per lo stesso motivo, un livello
più in basso: ogni nodo deve instradare i pacchetti tra la rete dei pod e il
resto.

**Perché un file in `/etc/sysctl.d/` e non `sysctl -w`:** quest'ultimo cambia il
valore solo fino al riavvio. I file in quella directory vengono letti a ogni
boot; `sysctl --system` li rilegge tutti adesso. Persistenza **e** effetto
immediato — lo stesso schema di `systemctl enable --now`.

**La verifica legge dal kernel, non dal file.** `sysctl nome` chiede il valore in
vigore. È la differenza tra verificare l'intenzione e verificare il risultato.

---

# Fase 2 — containerd

## 2.1 Scegliere il pacchetto

```bash
ssh ka-cp 'apt-cache policy containerd containerd.io 2>&1 | head -20'
```

`apt-cache policy` mostra versione installata, versione candidata e repository di
provenienza: dice cosa otterrai **prima** di installare.

| Pacchetto | Origine | Note |
|---|---|---|
| `containerd` | repository Ubuntu | integrato con la distribuzione, aggiornato da Ubuntu Security |
| `containerd.io` | repository Docker | più recente, richiede di aggiungere una sorgente esterna |

Per un lab su Ubuntu si è scelto il pacchetto della distribuzione: meno pezzi in
movimento, e nessun repository Docker su macchine che con Docker non c'entrano.

Su Ubuntu 24.04 il candidato è risultato **containerd 2.2.1**, non la 1.7 —
Ubuntu ha portato la serie 2.x negli aggiornamenti di noble. Il dettaglio conta
(vedi 2.2).

### containerd non è Docker

Confusione comune. **Docker** è una suite completa: CLI, demone, build delle
immagini, rete, compose. Sotto usa **containerd** per la parte che esegue
davvero i container.

Kubernetes ha bisogno solo di quel pezzo, e ci parla tramite un'interfaccia
standard chiamata **CRI** (Container Runtime Interface). Installare Docker intero
sarebbe come comprare un'auto per usare solo il motore.

```bash
for n in ka-cp ka-w1 ka-w2; do ssh $n 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y containerd > /dev/null 2>&1 && echo "$(hostname): $(containerd --version)"'; done
```

## 2.2 `SystemdCgroup = true` — il punto in cui sbagliano tutti

### Cosa sono i cgroup, e perché il driver deve essere uno solo

I **cgroup** (control groups) sono il meccanismo del kernel che limita e
contabilizza le risorse di un gruppo di processi. È così che Kubernetes fa
rispettare i `limits: memory` scritti nei manifest.

Qualcuno però deve *gestire* quei gruppi, e su Ubuntu quel qualcuno è **systemd**.

Se containerd e kubelet usano gestori diversi — uno systemd, l'altro il gestore
interno di containerd — ci sono **due autorità** che manipolano gli stessi gruppi
senza sapersi. Risultato: un nodo instabile sotto carico, con pod terminati per
motivi che nessun log spiega.

È lo stesso principio del DHCP disattivato in `infra/`: una sola fonte di verità.

### Il formato di configurazione è cambiato

⚠️ **containerd 2.x usa il formato di configurazione versione 3**, e la sezione
in cui vive `SystemdCgroup` ha cambiato nome. Quasi tutte le guide online — e
diversi pezzi di documentazione — mostrano il formato 2.

| | containerd 1.x (formato 2) | containerd 2.x (formato 3) |
|---|---|---|
| sezione | `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]` | `[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]` |
| virgolette | doppie | singole |

Copiando dal formato sbagliato si crea una sezione che **non esiste**, containerd
la ignora in silenzio, e il problema si manifesta molto più tardi.

**Il metodo, invece di fidarsi degli esempi:** chiedere a containerd di generare
la propria configurazione predefinita e cercare lì la chiave vera. È lo stesso
approccio di `tofu providers schema -json` con il provider libvirt.

```bash
ssh ka-cp 'containerd config default | grep -n -i -B5 "cgroup\|^version"'
```

```bash
ssh ka-cp 'containerd config default | sed -n "60,110p"'
```

Il secondo comando serve perché in TOML il significato di una chiave dipende
dalla **sezione** in cui si trova, dichiarata in una riga precedente fra
parentesi quadre. `grep -B5` non era arrivato abbastanza indietro: quando serve
contesto, un intervallo con `sed -n "N,Mp"` batte sempre un `grep`.

## 2.3 Applicare la configurazione

```bash
for n in ka-cp ka-w1 ka-w2; do ssh $n 'sudo mkdir -p /etc/containerd && containerd config default | sudo tee /etc/containerd/config.toml > /dev/null && sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml && sudo systemctl restart containerd && echo "$(hostname): configurato"'; done
```

```bash
for n in ka-cp ka-w1 ka-w2; do echo "--- $n"; ssh $n 'grep SystemdCgroup /etc/containerd/config.toml; systemctl is-active containerd'; done
```

Si usa `sed` invece di scrivere il file a mano **proprio per non dipendere dal
percorso della sezione**: si cerca la riga per contenuto, non per posizione. Così
il comando resta valido anche se una versione futura sposta di nuovo la sezione —
stessa filosofia del `jq` con le quadre vuote al posto della chiave del registry.

---

# Fase 3 — I binari di Kubernetes

I pacchetti **non stanno nei repository Ubuntu**: Kubernetes ha un proprio
repository, `pkgs.k8s.io`, **separato per versione minore**.

```bash
for n in ka-cp ka-w1 ka-w2; do ssh $n 'sudo mkdir -p /etc/apt/keyrings && curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null && echo "$(hostname): repo aggiunto"'; done
```

```bash
for n in ka-cp ka-w1 ka-w2; do ssh $n 'sudo apt-get update > /dev/null 2>&1 && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl > /dev/null 2>&1 && sudo apt-mark hold kubelet kubeadm kubectl > /dev/null && echo "$(hostname): $(kubeadm version -o short)"'; done
```

**La chiave GPG.** apt non si fida di un repository qualunque: ogni pacchetto è
firmato crittograficamente e apt verifica la firma con la chiave pubblica del
progetto. Senza, chi controllasse la rete potrebbe servire pacchetti manomessi.
`gpg --dearmor` converte la chiave dal formato testuale (`-----BEGIN PGP PUBLIC
KEY-----`) a quello binario che apt si aspetta.

**`signed-by=`** lega quella chiave **a quel solo repository**. È l'approccio
moderno: il vecchio `apt-key add` metteva tutto in un portachiavi globale, dove
una chiave qualsiasi poteva firmare pacchetti di qualsiasi origine.

**`v1.36` nell'URL.** Non esiste un repository generico "ultimo Kubernetes":
ognuno serve **una sola versione minore**. È voluto — passare da 1.36 a 1.37
richiede la procedura `kubeadm upgrade` e non deve mai succedere per caso durante
un `apt upgrade`.

**I tre binari.** `kubelet` è l'agente che gira su ogni nodo e avvia i container
assegnati: è l'unico componente di Kubernetes che sia un vero servizio systemd.
`kubeadm` costruisce il cluster. `kubectl` è il client.

**`apt-mark hold`** impedisce ad apt di aggiornarli. Kubernetes tollera uno
scarto limitato tra le versioni dei componenti: un kubelet aggiornato da solo
mentre il control plane resta indietro rompe il nodo.

---

# Fase 4 — `kubeadm init`

```bash
ssh ka-cp 'sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=192.168.150.20' 2>&1 | tail -30
```

| Flag | Perché |
|---|---|
| `--pod-network-cidr=10.244.0.0/16` | da quale intervallo assegnare gli IP dei pod. **Deve coincidere** con il CIDR configurato in Calico |
| `--apiserver-advertise-address=192.168.150.20` | quale indirizzo l'API server pubblica agli altri nodi |

`10.244.0.0/16` è scelto per non collidere con il `10.42.0.0/16` di k3s: i sei
nodi condividono lo stesso segmento di rete.

`--apiserver-advertise-address` non sarebbe strettamente necessario (kubeadm
sceglierebbe l'IP dell'interfaccia con la rotta di default), ma essere espliciti
evita sorprese su macchine con più interfacce. **Effetto collaterale utile:** il
kubeconfig generato contiene già l'indirizzo giusto, mentre quello di k3s va
corretto con un `sed`.

## Cosa fa davvero questo comando

Tutto ciò che k3s nascondeva:

1. esegue i **controlli preflight** (swap, moduli, sysctl, cgroup driver, porte)
2. scarica le immagini dei componenti del control plane
3. genera **l'intera infrastruttura di certificati** in `/etc/kubernetes/pki/`
4. scrive i **static pod** in `/etc/kubernetes/manifests/`
5. avvia il kubelet, che legge quei file e fa partire i container
6. crea i kubeconfig per admin, kubelet, scheduler e controller manager

## I static pod

```bash
ssh ka-cp 'ls /etc/kubernetes/manifests/'
```

```
etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

Il kubelet legge questa directory **direttamente** e avvia ciò che ci trova,
senza chiedere a nessuno. Deve funzionare così per forza: **l'API server non può
essere gestito dall'API server**. È il problema dell'uovo e della gallina,
risolto dando al kubelet la capacità di avviare cose da solo.

Conseguenza pratica: **si modificano con un editor di testo**. Cambiare un flag
dell'apiserver significa editare quel file; il kubelet se ne accorge e riavvia il
container.

Si riconoscono anche dai nomi: `etcd-k8s2-cp` porta in coda l'hostname del nodo
che li ospita, invece del suffisso casuale dei pod creati da un Deployment.

## La PKI

```bash
ssh ka-cp 'ls /etc/kubernetes/pki/'
```

Una CA per il cluster (`ca.crt`/`ca.key`), una **separata** per etcd,
certificati per apiserver e per i suoi client, `sa.key`/`sa.pub` per firmare i
token dei ServiceAccount. Ogni comunicazione interna a Kubernetes è autenticata
con TLS reciproco.

```bash
ssh ka-cp 'sudo kubeadm certs check-expiration'
```

## I cinque kubeconfig

```bash
ssh ka-cp 'ls /etc/kubernetes/*.conf'
```

`admin.conf`, `kubelet.conf`, `controller-manager.conf`, `scheduler.conf`,
`super-admin.conf`. Ogni componente ha la **propria identità** e i propri
permessi: minimo privilegio applicato dentro il cluster.

```bash
ssh ka-cp 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config-kubeadm && chmod 600 ~/.kube/config-kubeadm
```

Fusione con il kubeconfig esistente (stessa procedura di k3s):

```bash
cp ~/.kube/config ~/.kube/config.backup-$(date +%F) && KUBECONFIG=~/.kube/config:~/.kube/config-kubeadm kubectl config view --flatten > ~/.kube/merged && KUBECONFIG=~/.kube/merged kubectl config get-contexts
```

```bash
mv ~/.kube/merged ~/.kube/config && chmod 600 ~/.kube/config && kubectl config rename-context kubernetes-admin@kubernetes kubeadm
```

## Il nodo è `NotReady`, ed è atteso

```bash
kubectl describe node k8s2-cp | grep -A3 "Ready "
```

```
Ready   False   KubeletNotReady   container runtime network not ready:
NetworkReady=false reason:NetworkPluginNotReady message:Network plugin
returns error: cni plugin not initialized
```

Il kubelet sa che manca la rete dei pod e si rifiuta di dichiarare il nodo
disponibile: se accettasse pod, quelli nascerebbero senza connettività.

---

# Fase 5 — Calico

## Perché serve un CNI

Kubernetes **non implementa** la rete dei pod: definisce un'interfaccia (**CNI**,
Container Network Interface) e lascia che qualcun altro la realizzi. È una scelta
di progetto — ambienti diversi hanno esigenze di rete diverse.

k3s include Flannel già configurato. Su kubeadm il CNI è una scelta, e qui è
**Calico** — più ricco, e soprattutto **applica davvero le NetworkPolicy**, cosa
che Flannel non fa.

## Trovare la versione corrente

```bash
curl -s https://api.github.com/repos/projectcalico/calico/releases/latest | jq -r '.tag_name, .published_at'
```

L'API di GitHub espone `releases/latest` per qualsiasi repository pubblico: è la
fonte autorevole, sempre aggiornata, e non dipende da un blog vecchio di mesi.

È lo **stesso metodo** di `tofu providers schema -json` e `containerd config
default`: chiedere allo strumento invece di fidarsi degli esempi. Terzo caso in
cui evita un errore.

## Installazione

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/tigera-operator.yaml
```

⚠️ Nelle versioni recenti questo manifest **include già le CRD**. Applicare anche
`operator-crds.yaml` produce una lunga lista di `AlreadyExists`: innocui, ma
inutili. `create` (non `apply`) rifiuta di sovrascrivere, ed è la protezione che
evita danni quando si sbaglia ordine.

Si usa `create` anche per un motivo tecnico: `apply` salva l'intero oggetto in
un'annotazione per calcolare i diff futuri, e su manifest oltre i 256 KB dà
errore.

### CRD e operator

Le **CRD** (Custom Resource Definition) insegnano all'API server tipi di oggetto
nuovi. Kubernetes conosce di suo Pod, Service, Deployment — ma è **estensibile**:
una CRD dichiara "esiste un oggetto `Installation`, fatto così". Da quel momento
`kubectl get installation` funziona come `kubectl get pods`, con la stessa
validazione e gli stessi permessi.

È il meccanismo che rende Kubernetes una piattaforma e non solo un orchestratore.

Un **operator** è un controller che gira nel cluster e gestisce un componente
complesso al posto tuo. Si dichiara *cosa si vuole*; lui crea deployment,
daemonset e configurazioni, e sorveglia che lo stato resti quello dichiarato.

È il modello dichiarativo applicato all'**installazione del software**: invece di
uno script che fa venti cose, si dichiara il risultato e un controller lo
realizza — riparandolo se si scosta. La differenza tra `apt install` e un
Deployment.

## La risorsa `Installation`

`cluster/kubeadm/calico-installation.yaml`:

```yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: 10.244.0.0/16
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
```

| Campo | Significato |
|---|---|
| `cidr` | **deve coincidere** con `--pod-network-cidr` di `kubeadm init` |
| `blockSize: 26` | Calico ritaglia blocchi da 64 indirizzi e ne affida uno a ciascun nodo, che poi li distribuisce ai propri pod senza chiedere ogni volta |
| `encapsulation` | vedi sotto |
| `natOutgoing: Enabled` | quando un pod contatta l'esterno, il suo `10.244.x.x` viene tradotto nell'indirizzo del nodo |
| `nodeSelector: all()` | il pool vale per tutti i nodi |

⚠️ **Non usare il `192.168.0.0/16` degli esempi ufficiali di Calico**: collide
sia con la LAN di casa (`192.168.1.0/24`) sia con la rete delle VM
(`192.168.150.0/24`).

### L'incapsulamento

Un pod su un nodo deve raggiungere un pod su un altro nodo, ma la rete
sottostante (`192.168.150.0/24`) non sa nulla degli indirizzi `10.244.x.x`.

La soluzione è **incapsulare**: il pacchetto originale viene messo dentro un
altro pacchetto indirizzato tra i due nodi, e spacchettato all'arrivo. Stesso
principio del NAT di libvirt, un livello più su.

`VXLANCrossSubnet` incapsula **solo** quando i due nodi stanno su sottoreti
diverse. Se sono sullo stesso segmento — come qui — usa il routing diretto, più
veloce perché evita il costo dell'incapsulamento.

## Seguire l'installazione

```bash
kubectl get tigerastatus
```

```
NAME      AVAILABLE   PROGRESSING   DEGRADED   SINCE   MESSAGE
calico    False       True          False      21s
ippools   True        False         False      21s     All objects available
tiers                               True               Waiting for Tigera API server to be ready
```

I log dell'operator durante l'avvio sono **pieni di righe `error` con
stacktrace**. Non è un guasto: la funzione che segnala uno stato temporaneo si
chiama `SetDegraded`, e Go allega sempre lo stacktrace anche quando il messaggio
significa "non ancora pronto, riprovo".

Merita attenzione solo `the object has been modified; please apply your changes
to the latest version`: è **concorrenza ottimistica**. Due controller hanno
provato a scrivere lo stesso oggetto insieme; Kubernetes ne fa fallire uno, che
riprova con la versione aggiornata. È il meccanismo che garantisce la coerenza,
non un errore.

**Il riassunto affidabile è `tigerastatus`, non i log.**

```bash
kubectl get pods -n calico-system -o wide
```

Il namespace `calico-system` lo crea l'operator. Dentro:

- **`calico-node`** — un **DaemonSet**: l'agente che programma la rete su ogni
  nodo
- **`calico-typha`** — un proxy che riduce il carico sull'API server; il numero
  di repliche dipende dalla dimensione del cluster
- **`calico-kube-controllers`** — sincronizza lo stato con l'API server
- **`csi-node-driver`** — supporto per i volumi

### Il DaemonSet

Un **Deployment** dice "voglio N repliche, mettile dove vuoi". Un **DaemonSet**
dice "voglio **esattamente una** copia su ogni nodo". È il modello giusto per gli
agenti di sistema: rete, log, monitoraggio.

Effetto visibile: al join dei worker, `calico-node` e `csi-node-driver` sono
comparsi **da soli** sulle macchine nuove.

### `hostNetwork`

`calico-node` e `calico-typha` hanno come IP `192.168.150.20`, cioè l'indirizzo
**del nodo**, non uno della rete pod. Sono pod con `hostNetwork: true`:
condividono lo stack di rete della macchina.

Deve essere così — `calico-node` è l'agente che *costruisce* la rete dei pod, non
può dipendere da essa per funzionare. Sarebbe come pretendere di salire su una
scala che si sta ancora montando.

Gli altri pod hanno invece IP come `10.244.80.65`, `10.244.10.129`,
`10.244.207.193`: terzo ottetto diverso per nodo, perché ciascuno ha ricevuto un
blocco `/26` diverso. È il `blockSize: 26` visibile nei fatti.

Al termine:

```bash
kubectl get nodes
```

Il nodo passa da `NotReady` a **`Ready`**.

---

# Fase 6 — Join dei worker

```bash
ssh ka-cp 'sudo kubeadm token create --print-join-command'
```

I token di bootstrap **scadono dopo 24 ore** per progetto: sono credenziali di
ammissione al cluster. Questo comando ne crea uno nuovo e compone il comando
completo.

Per evitare di trascrivere a mano stringhe lunghe:

```bash
JOIN=$(ssh ka-cp 'sudo kubeadm token create --print-join-command') && echo "${#JOIN} caratteri"
```

```bash
ssh ka-w1 "sudo ${JOIN}" && ssh ka-w2 "sudo ${JOIN}"
```

Virgolette **doppie** attorno a `${JOIN}` perché bash sostituisca la variabile
prima di spedire il comando.

⚠️ Il token finisce nella `bash_history` delle VM. Accettabile in un lab.

## I due parametri del join

| Parametro | A cosa serve |
|---|---|
| `--token` | dimostra al control plane che il nodo **ha diritto** di entrare |
| `--discovery-token-ca-cert-hash` | dimostra al nodo che il control plane **è autentico** |

È autenticazione **reciproca**. Senza l'hash della CA, qualcuno potrebbe fingersi
il control plane e impossessarsi del nodo.

## Il TLS bootstrap

L'output del join termina con:

```
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.
```

Il token è servito **solo per il primo contatto**. Con quello il nodo ha chiesto
alla CA del cluster di firmargli un certificato personale, e da lì in poi si
autentica con quello — il token non serve più.

Si usa una credenziale condivisa e di breve durata per ottenerne una individuale
e duratura. È lo stesso motivo per cui i token scadono in 24 ore: devono servire
per un attimo, non per sempre.

## Verifica

```bash
kubectl get nodes -o wide
```

I worker restano `NotReady` per una trentina di secondi: Calico deve avviare il
proprio `calico-node` su ciascuno, e prima che la rete sia programmata il kubelet
non li dichiara pronti.

`ROLES` mostra `<none>` sui worker: in Kubernetes il ruolo è **solo
un'etichetta**, e la convenzione è che i worker non ne abbiano.

---

# Anatomia dei comandi

Sezione di riferimento per i costrutti bash usati sopra.

## Il ciclo su più nodi

```bash
for n in ka-cp ka-w1 ka-w2; do echo "--- $n"; ssh $n 'comando'; done
```

Tre strati annidati:

**1. Il ciclo, sul PC locale.** `for` definisce una variabile `n` che assume a
turno i tre valori, ed esegue il corpo (tra `do` e `done`) una volta per
ciascuno. `echo "--- $n"` stampa un'intestazione: senza, si avrebbero nove righe
di output senza sapere quale nodo le ha prodotte.

**2. L'esecuzione remota.** `ssh nodo 'comando'` esegue il comando **sulla
macchina remota** e ne riporta l'output. Gli **apici singoli** impediscono alla
shell locale di interpretare il contenuto: viene spedito così com'è e
interpretato dalla shell della VM.

**3. Il comando che gira sulla VM.**

## Gli operatori che si somigliano

| Simbolo | Nome | Cosa fa |
|---|---|---|
| `\|` | pipe | passa l'output di sinistra come input a destra |
| `\|\|` | OR logico | esegue a destra **solo se** a sinistra fallisce |
| `&&` | AND logico | esegue a destra **solo se** a sinistra riesce |

Il `\|\|` serve a stampare un messaggio quando un comando non trova nulla:
`grep` esce con errore se non trova corrispondenze, e il vuoto è ambiguo
(nessun risultato? comando sbagliato?).

Gli `&&` incatenati fanno da controllo implicito: se un passaggio fallisce, i
successivi non partono. Vedere il messaggio finale significa che **tutta** la
catena è riuscita.

## `grep -E` e l'ancoraggio

```bash
lsmod | grep -E "^overlay|^br_netfilter"
```

`-E` abilita le espressioni regolari estese, per due motivi:

- il `|` dentro le virgolette significa **OR** (senza `-E` andrebbe scritto `\|`)
- il `^` significa **inizio riga**

L'ancoraggio non è cosmetico: `lsmod` ha una colonna che elenca i moduli
*dipendenti*. Senza `^`, `grep` troverebbe `overlay` anche in una riga di un
altro modulo che lo usa — risposta giusta per il motivo sbagliato.

## `sudo tee` invece di `sudo echo >`

```bash
printf "testo\n" | sudo tee /etc/percorso/file > /dev/null
```

La redirezione `>` è eseguita **dalla shell**, che non è root: `sudo echo … >
/etc/…` fallisce con permission denied prima ancora che `sudo` entri in gioco.

`tee` riceve invece il testo su stdin e lo scrive lui — ed è `tee` a girare con
privilegi. È l'idioma standard per scrivere file di sistema.

`> /dev/null` scarta l'output di `tee`, che altrimenti ripeterebbe a schermo
quello che ha scritto (tee stampa **e** scrive, da qui il nome: come il raccordo
a T di un tubo).

`printf` invece di `echo` perché interpreta `\n` in modo affidabile su qualsiasi
shell, mentre `echo -e` varia da sistema a sistema.

## `DEBIAN_FRONTEND=noninteractive`

Dice ad apt di non aprire mai finestre di dialogo: se un pacchetto volesse
chiedere qualcosa, sceglie il default invece di bloccarsi in attesa.

Su comandi remoti dentro un ciclo è essenziale — senza, un prompt lascerebbe il
terminale appeso senza far capire perché.

## `> /dev/null 2>&1`

Nasconde l'output, che per tre nodi sarebbe centinaia di righe.

`2>&1` redirige anche gli **errori** nello stesso posto: il `2` è lo standard
error, il `&1` significa "dove va lo standard output".

Combinato con `&&`, il nodo che **non** stampa il messaggio di conferma è quello
con il problema.

## Perché non incollare comandi in blocco

L'input digitato o incollato **non va perso** quando un programma prende il
terminale: resta in coda e viene eseguito appena la shell riprende il controllo.

Vale per qualunque comando che si fermi ad aspettare una risposta: `ssh` al primo
contatto con un host, `sudo` che chiede la password, `tofu apply` che chiede
`yes`.

In questo lab è così che è stato installato per sbaglio un server k3s sull'host.

## Gli alias non esistono nei comandi remoti

`ssh k8s-cp 'k get nodes'` risponde `bash: line 1: k: command not found`, mentre
`k get nodes` in una sessione interattiva funziona.

`ssh host 'comando'` avvia una shell **non interattiva**, e bash in quella
modalità **non legge `~/.bashrc`**. Inoltre gli alias sono disabilitati per
default nelle shell non interattive.

Non è un bug: `.bashrc` contiene configurazioni per l'uso umano, che in uno
script darebbero fastidio — un alias potrebbe cambiare silenziosamente il
significato di un comando.

**Regola:** negli script e nei comandi remoti si usano sempre i nomi completi.

---

# Stato

- [x] Fase 1 — prerequisiti del kernel
- [x] Fase 2 — containerd con `SystemdCgroup = true`
- [x] Fase 3 — kubelet, kubeadm, kubectl (v1.36.4)
- [x] Fase 4 — `kubeadm init`
- [x] Fase 5 — Calico v3.32.1
- [x] Fase 6 — join dei worker
- [ ] Fase 7 — storage local-path
- [ ] Fase 8 — l'applicazione
- [ ] Fase 9 — confronto con k3s
