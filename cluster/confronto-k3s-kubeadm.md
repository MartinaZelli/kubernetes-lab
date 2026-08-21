# k3s vs kubeadm — confronto pratico

Documento di studio. Ogni differenza è accompagnata dal **comando per
verificarla sulle macchine**, non solo dalla teoria.

Due cluster reali, stessa versione di Kubernetes (**v1.36**), stessa
distribuzione (Ubuntu 24.04), stessa rete. Cambia solo come sono stati
costruiti.

| | k3s | kubeadm |
|---|---|---|
| Nodi | `k8s-cp` .10, `k8s-w1` .11, `k8s-w2` .12 | `k8s2-cp` .20, `k8s2-w1` .21, `k8s2-w2` .22 |
| Alias SSH | `k8s-cp`, `k8s-w1`, `k8s-w2` | `ka-cp`, `ka-w1`, `ka-w2` |
| Contesto kubectl | `k3s` | `kubeadm` |
| Versione | v1.36.3+k3s1 | v1.36.4 |
| CNI | Flannel (VXLAN) | Calico v3.32.1 |
| Container runtime | containerd (incluso) | containerd 2.2.1 |

```bash
kubectl config use-context k3s      # per i comandi sul primo cluster
kubectl config use-context kubeadm  # per i comandi sul secondo
kubectl config current-context      # dove sono adesso?
```

⚠️ Prima di ogni comando `kubectl`, verificare il contesto attivo. È l'errore
più facile da fare con due cluster.

---

## 1. Quanti processi

**k3s: un solo servizio systemd**, con tutto dentro.

```bash
ssh k8s-cp 'sudo systemctl status k3s --no-pager | head -12'
```

Si vede `Main PID: … (k3s-server)` con containerd come figlio. etcd, apiserver,
scheduler e controller manager **non compaiono**: sono funzioni dentro l'unico
processo Go.

**kubeadm: il kubelet come servizio, il resto come container.**

```bash
ssh ka-cp 'sudo systemctl status kubelet --no-pager | head -12'
```

```bash
ssh ka-cp 'sudo crictl ps'
```

Il kubelet è l'unico vero servizio. I quattro componenti del control plane sono
container gestiti da containerd.

---

## 2. Dove vive il control plane

**kubeadm: static pod in una directory standard.**

```bash
ssh ka-cp 'ls /etc/kubernetes/manifests/'
```

Quattro file YAML: `etcd.yaml`, `kube-apiserver.yaml`,
`kube-controller-manager.yaml`, `kube-scheduler.yaml`.

Sono **static pod**: il kubelet li legge direttamente da quella directory e li
avvia, senza chiedere a nessuno. Deve funzionare così per forza — l'API server
non può essere gestito dall'API server. È il problema dell'uovo e della gallina,
risolto dando al kubelet la capacità di avviare cose da solo.

Conseguenza pratica: **si modificano con un editor di testo**. Cambiare un flag
dell'apiserver significa editare quel file; il kubelet se ne accorge e riavvia il
container.

**k3s: la directory non esiste.**

```bash
ssh k8s-cp 'ls /etc/kubernetes/ 2>&1; echo "--- struttura k3s ---"; sudo ls /var/lib/rancher/k3s/server/'
```

Il primo `ls` fallisce, ed è già la risposta. Non ci sono static pod perché non
ci sono componenti separati da avviare. La configurazione si passa come flag al
servizio (`--disable=traefik`, `--write-kubeconfig-mode=644`), non modificando
manifest.

---

## 3. I certificati

Entrambi generano una PKI completa: la crittografia non si può saltare, è così
che Kubernetes autentica ogni comunicazione interna.

**kubeadm: percorso standard e documentato.**

```bash
ssh ka-cp 'ls /etc/kubernetes/pki/'
```

Si trovano `ca.crt`/`ca.key` (la CA del cluster), una CA separata per etcd, i
certificati di apiserver e dei suoi client, `sa.key`/`sa.pub` per firmare i token
dei ServiceAccount.

Gestione esplicita:

```bash
ssh ka-cp 'sudo kubeadm certs check-expiration'
```

**k3s: PKI equivalente, in una directory di prodotto.**

```bash
ssh k8s-cp 'sudo ls /var/lib/rancher/k3s/server/tls/ | head -30'
```

La differenza non è **cosa** viene fatto, ma **quanto è visibile e
modificabile**. Con kubeadm i certificati stanno in un percorso standard, li
rinnovi con `kubeadm certs renew`, li ispezioni con `openssl`. Con k3s la
gestione è automatica, in una directory che il progetto può riorganizzare.

È il compromesso di ogni astrazione: meno cose da sapere, meno controllo quando
serve.

---

## 4. I kubeconfig

**kubeadm** ne genera cinque, uno per ciascun consumatore:

```bash
ssh ka-cp 'ls /etc/kubernetes/*.conf'
```

`admin.conf` (per te), `kubelet.conf`, `controller-manager.conf`,
`scheduler.conf`, `super-admin.conf`. Ogni componente ha la **propria identità**
e i propri permessi: è il principio del minimo privilegio applicato
all'interno del cluster.

Recuperarlo:

```bash
ssh ka-cp 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config-kubeadm
```

Contiene già `server: https://192.168.150.20:6443`, perché glielo abbiamo detto
con `--apiserver-advertise-address`.

**k3s** ne espone uno solo, e va corretto:

```bash
ssh k8s-cp 'sudo cat /etc/rancher/k3s/k3s.yaml' | grep server
```

Contiene `https://127.0.0.1:6443` — corretto dal punto di vista del control
plane, inutile dall'esterno. Serve un `sed` per puntarlo all'IP del nodo.

---

## 5. Il database dello stato

| | k3s | kubeadm |
|---|---|---|
| Motore | **SQLite** (default a nodo singolo) | **etcd** |
| Dove | file in `/var/lib/rancher/k3s/server/db/` | container `etcd`, dati in `/var/lib/etcd` |

```bash
ssh k8s-cp 'sudo ls -la /var/lib/rancher/k3s/server/db/'
```

```bash
ssh ka-cp 'sudo ls /var/lib/etcd/member/'
```

k3s supporta anche etcd (con `--cluster-init`), ma per un control plane singolo
SQLite è sufficiente e molto più leggero.

---

## 6. Cosa gira in `kube-system`

Il confronto più eloquente di tutti. **Osservato il 21/08/2026.**

```bash
kubectl --context k3s get pods -n kube-system
```

```
NAME                                      READY   STATUS    RESTARTS   AGE
coredns-54996dc9b4-4bqgg                  1/1     Running   0          4d1h
local-path-provisioner-58d557dc48-wfxfl   1/1     Running   0          4d1h
metrics-server-6dc596dfb8-8ph75           1/1     Running   0          4d1h
```

**Tre pod.** (Traefik e servicelb sarebbero presenti senza `--disable=traefik`.)

```bash
kubectl --context kubeadm get pods -n kube-system
```

```
NAME                              READY   STATUS    RESTARTS   AGE
coredns-589f44dc88-xsm45          1/1     Running   0          68m
coredns-589f44dc88-zr8p8          1/1     Running   0          68m
etcd-k8s2-cp                      1/1     Running   0          69m
kube-apiserver-k8s2-cp            1/1     Running   0          69m
kube-controller-manager-k8s2-cp   1/1     Running   0          69m
kube-proxy-9cfnl                  1/1     Running   0          8m50s
kube-proxy-cpr8j                  1/1     Running   0          8m2s
kube-proxy-jkz6d                  1/1     Running   0          68m
kube-scheduler-k8s2-cp            1/1     Running   0          69m
```

**Nove pod**, più quelli in `calico-system`.

### Come leggere la differenza

| Cosa | k3s | kubeadm | Nota |
|---|---|---|---|
| etcd | — | `etcd-k8s2-cp` | k3s usa SQLite dentro il processo |
| API server | — | `kube-apiserver-k8s2-cp` | funzione interna al binario k3s |
| Scheduler | — | `kube-scheduler-k8s2-cp` | idem |
| Controller manager | — | `kube-controller-manager-k8s2-cp` | idem |
| kube-proxy | — | 3 pod, uno per nodo | in k3s è integrato nell'agent |
| CoreDNS | 1 pod | **2 pod** | kubeadm ne mette due per ridondanza |
| Storage | `local-path-provisioner` | — | su kubeadm va installato a mano |
| Metrics | `metrics-server` | — | idem |

**È lo stesso software.** Su k3s i primi cinque non compaiono perché sono
funzioni dentro l'unico processo `k3s server`, non perché non esistano.

Il suffisso `-k8s2-cp` nei nomi rivela la loro natura: sono **static pod**,
nominati con l'hostname del nodo che li ospita. Non li ha creati un Deployment —
li ha avviati il kubelet leggendo `/etc/kubernetes/manifests/`.

`kube-proxy` è invece un **DaemonSet**: tre pod con nome generato, uno per nodo.
Le età lo raccontano — 68m il primo (creato con `kubeadm init`), 8m gli altri due
(comparsi da soli al join dei worker).

`--context nome` sceglie il cluster per quel singolo comando, senza cambiare
quello attivo: comodo per i confronti affiancati.

## 7. Il nodo control plane è schedulabile?

```bash
kubectl --context k3s get nodes -o custom-columns=NOME:.metadata.name,TAINT:.spec.taints[*].key
```

```bash
kubectl --context kubeadm get nodes -o custom-columns=NOME:.metadata.name,TAINT:.spec.taints[*].key
```

**kubeadm** applica al control plane la taint
`node-role.kubernetes.io/control-plane:NoSchedule`, che impedisce ai pod utente
di girarci. Serve a proteggere il cervello del cluster dai carichi applicativi.

**k3s** non la applica: il nodo server esegue anche workload.

Conseguenza concreta in questo lab: su k3s un pod `web` gira sul control plane,
su kubeadm no. Con due worker e due repliche l'anti-affinity è comunque
soddisfatta — ma con **due sole VM** su kubeadm il requisito "due pod su nodi
diversi" sarebbe stato impossibile.

---

## 8. Cosa va installato a mano

| Componente | k3s | kubeadm |
|---|---|---|
| Runtime container | incluso | **da installare** (containerd) |
| Prerequisiti kernel | gestiti dallo script | **swap, moduli, sysctl a mano** |
| CNI (rete dei pod) | Flannel preconfigurato | **da installare** (qui Calico) |
| Storage dinamico | local-path incluso | **da installare** |
| Ingress controller | Traefik (disattivabile) | assente per default |
| LoadBalancer | ServiceLB | assente per default |
| Metrics server | incluso | **da installare** |

Ogni riga della colonna destra è una cosa che k3s faceva senza dirlo.

---

## 8-bis. Come si installa un CNI

Su **k3s** non si installa: Flannel è già configurato al primo avvio.

Su **kubeadm** servono tre passi, ed è un buon esempio del pattern *operator*:

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/tigera-operator.yaml
kubectl apply -f cluster/kubeadm/calico-installation.yaml
kubectl get tigerastatus
```

⚠️ Nelle versioni recenti `tigera-operator.yaml` **include già le CRD**.
Applicare anche `operator-crds.yaml` produce una lista di `AlreadyExists` —
innocui, ma inutili. `create` (non `apply`) rifiuta di sovrascrivere ed è la
protezione che evita danni.

### Il pattern operator

Un **operator** è un controller che gira dentro il cluster e gestisce un
componente complesso al posto tuo. Si dichiara *cosa si vuole* con una risorsa
personalizzata (qui `kind: Installation`); lui crea e mantiene deployment,
daemonset e configurazioni, e continua a sorvegliare che lo stato resti quello
dichiarato.

È il modello dichiarativo di Kubernetes applicato all'**installazione del
software**: invece di eseguire uno script che fa venti cose, si dichiara il
risultato e un controller lo realizza — riparandolo se qualcosa si scosta. È la
differenza tra `apt install` e un Deployment.

Le **CRD** (Custom Resource Definition) sono ciò che rende possibile tutto
questo: insegnano all'API server tipi di oggetto nuovi. Da quel momento
`kubectl get installation` funziona come `kubectl get pods`, con la stessa
validazione e gli stessi permessi.

### Leggere lo stato dell'operator

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
significa solo "non ancora pronto, riprovo".

Merita attenzione solo `the object has been modified; please apply your changes
to the latest version`: è **concorrenza ottimistica**. Due controller hanno
provato a scrivere lo stesso oggetto insieme, Kubernetes ne fa fallire uno che
riprova con la versione aggiornata. È il meccanismo che garantisce la coerenza.

Il riassunto affidabile è `tigerastatus`, non i log.

---

## 9. Le NetworkPolicy

```bash
kubectl --context k3s get pods -n kube-system -o wide | grep -i flannel
```

k3s usa **Flannel**, che **non applica** le NetworkPolicy: si possono scrivere,
vengono accettate dall'API server, e non hanno alcun effetto. Un falso senso di
sicurezza.

Calico invece le applica. È uno dei motivi per cui è stato scelto qui.

*(Da verificare con un test pratico quando le scriveremo.)*

---

## 10. Reti a confronto

| | k3s | kubeadm |
|---|---|---|
| Pod CIDR | `10.42.0.0/16` | `10.244.0.0/16` |
| Service CIDR | `10.43.0.0/16` | `10.96.0.0/12` |
| CNI | Flannel (VXLAN) | Calico |

```bash
kubectl --context k3s get pods -A -o wide | awk '{print $7}' | sort -u | head
```

```bash
kubectl --context kubeadm get pods -A -o wide | awk '{print $7}' | sort -u | head
```

Le due sottoreti dei pod **devono differire**: i sei nodi condividono lo stesso
segmento di rete `192.168.150.0/24`, e sovrapporle produrrebbe rotte in
conflitto.

⚠️ Da evitare il `192.168.0.0/16` che Calico propone come default: collide sia
con la LAN di casa sia con la rete delle VM.

---

## 11. Installazione e rimozione

| | k3s | kubeadm |
|---|---|---|
| Installare | `curl -sfL https://get.k3s.io \| sh -` | 3 fasi di prerequisiti + `kubeadm init` |
| Aggiungere un nodo | stesso script con `K3S_URL` + `K3S_TOKEN` | `kubeadm join` con token e hash della CA |
| Rimuovere | `k3s-uninstall.sh` | `kubeadm reset -f` + pulizia manuale |
| Tempo | ~1 minuto | ~30-45 minuti |

Su k3s **è lo stesso script** per server e agent: il ruolo è deciso dalla
presenza di `K3S_URL`. Su kubeadm sono due comandi diversi.

---

# Quando usare quale

**k3s** — edge, IoT, sviluppo locale, cluster piccoli, chi vuole Kubernetes senza
gestirne le viscere. Meno superficie da mantenere, aggiornamenti più semplici.

**kubeadm** — quando serve controllo sui singoli componenti, quando la
configurazione va versionata e ripetuta con precisione, quando si deve rispettare
una policy sui certificati o sulla rete. È anche la base su cui sono costruiti
strumenti come kubespray e Cluster API — e ciò che va saputo per la
certificazione CKA.

**In entrambi i casi i manifest dell'applicazione sono identici.** È la
dimostrazione che Kubernetes è un'interfaccia standard, non una tecnologia
specifica.

---

# Da completare

- [ ] Sezione 6 — output reale di `kube-system` sui due cluster
- [ ] Sezione 7 — output reale delle taint
- [ ] Sezione 9 — test pratico di una NetworkPolicy su Calico
- [ ] Confronto del consumo di risorse (`kubectl top nodes`) a parità di carico
- [ ] Tempi di avvio a freddo dei due cluster
