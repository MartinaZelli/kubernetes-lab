# manifests/ — l'applicazione sul cluster

Gli oggetti Kubernetes che descrivono l'applicazione *menu*: due webserver e un
database MySQL, in namespace separati.

**Il punto di questa cartella:** questi file sono **identici** su k3s e su
kubeadm. `../cluster/` descrive come Kubernetes viene *installato*; qui c'è
*cosa gira sopra*. È la separazione che rende il lavoro riutilizzabile — e la
prova che Kubernetes è un'interfaccia standard, non una tecnologia specifica.

**Prerequisiti:** un cluster in piedi (`../cluster/k3s/`) e i Secret generati
(`../scripts/gen-secrets.sh`).

---

# Il modello mentale

## Dichiarativo, in loop

In Kubernetes non si danno comandi: si descrive uno **stato desiderato** in YAML.
Dei componenti chiamati *controller* confrontano continuamente lo stato reale con
quello descritto e agiscono per colmare la differenza.

Se un pod muore non lo si riavvia: il controller nota che ne sono stati chiesti
due e ne vede uno, e ne crea un altro. È lo stesso `plan`/`apply` di OpenTofu, ma
**in loop continuo** invece che una volta sola quando lo lanci tu.

## Label e selector: il meccanismo che tiene insieme tutto

Gli oggetti Kubernetes **non si riferiscono l'uno all'altro per nome**. Si
riferiscono per **etichetta**.

Un `Service` non dice "manda il traffico al pod `web-69cdf59c65-fvqsg`" — dice
"manda il traffico a qualunque pod abbia l'etichetta `app: web`". Un `Deployment`
non elenca i suoi pod: dice "voglio due pod con l'etichetta `app: web`".

È un accoppiamento indiretto, e ha una conseguenza importante:

> **Se le etichette non combaciano, gli oggetti non si trovano e nulla dà
> errore.** Il Service esiste, i pod esistono, ma il traffico non arriva.

È la prima causa di "non funziona e non capisco perché". Il comando che lo
diagnostica è `kubectl get endpointslice`: se non elenca indirizzi, il selector
non corrisponde a nessun pod.

## La struttura a matrioska

In un `Deployment` o `StatefulSet` ci sono **due** blocchi `metadata` e **due**
`spec`:

```yaml
kind: Deployment
metadata:        # ← metadata DEL DEPLOYMENT
spec:            # ← spec DEL DEPLOYMENT
  selector: ...
  template:
    metadata:    # ← metadata DEI POD che verranno creati
    spec:        # ← spec DEI POD
      containers: ...
```

Il `template` è uno **stampo**, non un oggetto. E
`spec.selector.matchLabels` deve combaciare con
`spec.template.metadata.labels`: sembra ridondanza, è invece il meccanismo con
cui il controller riconosce i "suoi" pod. Se non combaciano Kubernetes rifiuta
l'oggetto (qui lo verifica, per fortuna).

---

# Gli oggetti in questo progetto

| File | Oggetto | Namespace | Ruolo |
|---|---|---|---|
| `00-namespaces.yaml` | `Namespace` ×2 | — (cluster) | Crea `web` e `db` |
| `10-db-secret.example.yaml` | `Secret` (template) | `db` | Segnaposto versionato; i valori veri li genera `gen-secrets.sh` |
| `11-db-pvc.yaml` | `PersistentVolumeClaim` | `db` | Richiesta di 5Gi su StorageClass `local-path` |
| `12-db-statefulset.yaml` | `StatefulSet` | `db` | MySQL 8.0, 1 replica, volume montato su `/var/lib/mysql` |
| `13-db-service.yaml` | `Service` (ClusterIP) | `db` | Nome stabile `mysql:3306`, solo interno |
| `20-web-deployment.yaml` | `Deployment` | `web` | 2 repliche + `podAntiAffinity` dura |
| `21-web-service.yaml` | `Service` (NodePort) | `web` | Espone la 80 sulla porta 30080 di **ogni** nodo |
| `22-web-secret.example.yaml` | `Secret` (template) | `web` | Segnaposto per la connessione al DB |

## Ordine di applicazione

Il prefisso numerico non è decorativo: gli oggetti hanno dipendenze.

```bash
kubectl apply -f manifests/00-namespaces.yaml   # i namespace devono esistere prima di tutto
./scripts/gen-secrets.sh                        # i Secret prima dei pod che li consumano
kubectl apply -f manifests/11-db-pvc.yaml
kubectl apply -f manifests/12-db-statefulset.yaml
kubectl apply -f manifests/13-db-service.yaml
kubectl apply -f manifests/20-web-deployment.yaml
kubectl apply -f manifests/21-web-service.yaml
```

Oppure tutto in un colpo (`kubectl` ordina internamente i tipi di risorsa, ma il
numero rende l'intenzione leggibile):

```bash
kubectl apply -f manifests/
```

---

# Le scelte, e perché

## `Deployment` per il web, `StatefulSet` per il database

| | `Deployment` | `StatefulSet` |
|---|---|---|
| Identità dei pod | intercambiabili, nome casuale | stabile e ordinata (`mysql-0`, `mysql-1`) |
| Volume | condiviso o assente | uno per pod, che lo segue |
| Ordine di creazione | qualsiasi, in parallelo | sequenziale |
| Caso d'uso | app senza stato | database, code, cluster con quorum |

Un webserver è senza stato: i pod sono sostituibili, non hanno dati propri. Un
database no.

## Anti-affinity: il requisito "due pod su nodi diversi"

Per default lo scheduler distribuisce i pod in modo abbastanza equilibrato, ma
**non lo garantisce**. Serve dirglielo.

Tre modi, tutti presenti nel file (uno attivo, due commentati):

| Tecnica | Comportamento se non soddisfabile | Quando usarla |
|---|---|---|
| `podAntiAffinity` `required...` | pod resta `Pending` per sempre | serve la **certezza** |
| `podAntiAffinity` `preferred...` | schedula comunque, ammassando | alta disponibilità "best effort" |
| `topologySpreadConstraints` `maxSkew: 1` + `DoNotSchedule` | resta `Pending` solo oltre lo sbilanciamento | molte repliche su pochi nodi |

**Attenzione all'asimmetria strutturale**, che è la fonte di errore principale:

- `required...` prende **direttamente** una lista di termini
- `preferred...` avvolge ogni termine in `podAffinityTerm` e aggiunge un `weight`
  (1-100). Il peso serve perché con più preferenze lo scheduler somma i punteggi
  — concetto che in un vincolo duro non ha senso
- `topologySpreadConstraints` **non sta sotto `affinity`**: è un campo a sé della
  spec del pod

**`topologyKey`** è il concetto che unisce le tre: l'etichetta del nodo che
definisce cosa significa "posto diverso". `kubernetes.io/hostname` = nodo
diverso; `topology.kubernetes.io/zone` = zona diversa in un cloud. Stesso
meccanismo, granularità diverse.

**`IgnoredDuringExecution`** nei nomi lunghissimi significa che la regola vale
**solo al momento della decisione**. Se il vincolo viene violato dopo, Kubernetes
non sposta i pod già in esecuzione: non fa quasi mai migrazioni spontanee.

**Il `labelSelector` è auto-referenziale**: punta ai pod che hanno la stessa
etichetta di quelli che sta creando. Leggilo come "non schedulare questo pod dove
c'è già un pod `app: web`". La prima volta sembra strano.

## Le tre porte di un Service

```yaml
ports:
  - port: 80          # porta del SERVICE dentro il cluster → altri pod usano "web:80"
    targetPort: 80    # porta del CONTAINER
    nodePort: 30080   # porta aperta su OGNI NODO, verso l'esterno
```

| Tipo | Raggiungibile da | Uso qui |
|---|---|---|
| `ClusterIP` (default) | solo dentro il cluster | il database |
| `NodePort` | ClusterIP **+** una porta su ogni nodo | il web |
| `LoadBalancer` | + un IP esterno dal provider | non usato |

**La porta si apre su tutti i nodi, non solo su quelli che ospitano un pod.**
Contattare `192.168.150.11:30080` funziona anche se su `k8s-w1` non gira nessun
pod web: kube-proxy inoltra la richiesta attraverso la rete dei pod. Ogni nodo è
una porta d'ingresso al cluster intero.

`nodePort` deve stare nell'intervallo **30000-32767** (per non collidere con i
servizi di sistema dei nodi). Se lo si omette, Kubernetes ne assegna una casuale
in quel range.

Perché non è la soluzione di produzione: una porta strana su ogni nodo, e serve
conoscere l'IP di un nodo. Un Ingress controller dà un punto d'ingresso unico
sulla 80/443 con routing per nome host — il lab lo evita di proposito, per
vedere prima il livello sotto.

## Storage: la catena PVC → StorageClass → PV

Nel `docker-compose` originale bastava `volumes: - /path/host:/var/lib/mysql`:
un percorso su *quella* macchina. In Kubernetes il pod non sa su quale nodo
girerà, quindi non può nominare un percorso. La cosa si spezza in tre:

| Oggetto | Cos'è | Chi lo scrive |
|---|---|---|
| `PersistentVolumeClaim` | la **richiesta**: "mi servono 5Gi scrivibili" | tu |
| `StorageClass` | il **come**: chi crea i volumi e con quale tecnologia | già presente in k3s |
| `PersistentVolume` | il **risultato**: lo spazio allocato | creato automaticamente |

### `WaitForFirstConsumer`: il PVC resta `Pending`, ed è normale

La StorageClass `local-path` ha `VOLUMEBINDINGMODE: WaitForFirstConsumer`, che
significa: *non creare il volume finché non sai dove andrà il pod*.

Il motivo: `local-path` crea una **directory sul disco di un nodo specifico**
(sotto `/var/lib/rancher/k3s/storage/`). Non è storage di rete. Se Kubernetes
creasse il volume subito lo piazzerebbe su un nodo a caso, e poi lo scheduler
sarebbe costretto a mettere il pod *lì*. Con `WaitForFirstConsumer` l'ordine si
inverte: prima lo scheduler sceglie, poi il volume nasce su quel nodo.

Quindi un PVC `Pending` senza pod che lo usa **non è un errore**. Verificalo con:

```bash
kubectl describe pvc mysql-data -n db | tail -5
# "waiting for first consumer to be created before binding"
```

### Il pod del database è inchiodato a un nodo

Una volta creato, il PV ha una `nodeAffinity` che lo vincola:

```bash
kubectl get pv -o jsonpath='{.items[0].spec.nodeAffinity}' | python3 -m json.tool
# kubernetes.io/hostname In [k8s-w1]
```

Conseguenze da tenere presenti:

- se quel nodo si spegne, **MySQL non riparte altrove**: resta `Pending`
- i dati **non sono replicati** da nessuna parte
- non è un difetto di local-path: è esattamente ciò che si aspetta dallo storage
  locale. In produzione i database stanno su storage di rete o si replicano a
  livello applicativo

### Due campi che ingannano

**`accessModes: ReadWriteOnce`** significa "montabile in lettura/scrittura da un
solo **nodo**", non da un solo *pod*. Gli altri sono `ReadOnlyMany` e
`ReadWriteMany` (quest'ultimo richiede storage di rete tipo NFS).

**La quota non è applicata.** `storage: 5Gi` con `local-path` è nominale: la
"dimensione" è solo una directory su un filesystem, e scrivendo 15Gi nessuno ti
ferma. Il limite vero è lo spazio del disco della VM. Il campo è obbligatorio
per lo schema, ma qui è documentazione. Coerentemente,
`ALLOWVOLUMEEXPANSION` è `false`.

**`RECLAIMPOLICY: Delete`**: cancellando il PVC si cancellano il volume **e i
dati**. Comodo in un lab, pericoloso altrove.

## Unità di misura e altre finezze di YAML

| Scrittura | Significato |
|---|---|
| `5Gi` | 2³⁰ byte (gibibyte) — **usa questa** |
| `5G` | 10⁹ byte (gigabyte), 7% in meno |
| `250m` | 250 millicore = ¼ di CPU |
| `"3306"` | stringa (obbligatorio per le variabili d'ambiente) |
| `3306` | intero — Kubernetes rifiuta il manifest se serve una stringa |

**`resources`**: `requests` è quello che lo scheduler **garantisce** (cerca un
nodo con almeno tanto libero); `limits` è il tetto. Superare il limite di
**memoria** uccide il container; superare quello di **CPU** lo rallenta
soltanto. Per questo su MySQL c'è un limite di memoria ma non di CPU: un
database rallentato è meglio di un database morto.

## Segreti: `envFrom` contro `env` + `secretKeyRef`

```yaml
envFrom:                        # TUTTE le chiavi, col loro nome
  - secretRef:
      name: mysql-credentials
```

```yaml
env:                            # una alla volta, RINOMINANDO
  - name: MYSQL_PASSWORD        # il nome che vuole il container
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: DB_PASSWORD        # il nome della chiave nel Secret
```

Il secondo modo **disaccoppia** i nomi: il Secret usa nomi tuoi, ogni container
riceve quelli che si aspetta. Serve quando la stessa credenziale ha nomi diversi
per programmi diversi — vedi `../scripts/README.md`.

**Un Secret non è cifrato**, è codificato in base64. Dimostrazione:

```bash
kubectl get secret mysql-credentials -n db -o jsonpath='{.data.MYSQL_USER}' | base64 -d; echo
```

Nessuna chiave, nessuna password: basta il permesso di leggere l'oggetto. La
differenza rispetto a un `ConfigMap` è nel *trattamento* (non finiscono nei log,
controlli d'accesso separati, cifratura a riposo se il cluster è configurato),
non nel contenuto.

## DNS interno e nomi cross-namespace

Lo schema completo è `<servizio>.<namespace>.svc.cluster.local`.

| Da dove | Come raggiungere il servizio `mysql` in `db` |
|---|---|
| dentro `db` | `mysql` |
| da `web` | `mysql.db` oppure `mysql.db.svc.cluster.local` |

Dentro lo stesso namespace basta il nome corto perché il resolver del pod ha le
`search domains` configurate. Da un altro namespace serve almeno
`servizio.namespace`. **Il nome completo è preferibile**: più esplicito e non
dipende dalla configurazione del resolver.

È il motivo per cui `DB_HOST` vale `mysql.db.svc.cluster.local` e non `db` come
nel `docker-compose` originale.

## La rete dei pod

Gli IP dei pod sono `10.42.x.x`, non `192.168.150.x` come le VM: è una rete
virtuale **sovrapposta** a quella dei nodi. Ogni nodo riceve un blocco:

| Nodo | Blocco | Esempio visto |
|---|---|---|
| `k8s-cp` | `10.42.0.0/24` | `10.42.0.5` |
| `k8s-w1` | `10.42.1.0/24` | `10.42.1.3` (MySQL) |
| `k8s-w2` | `10.42.2.0/24` | `10.42.2.2` |

Flannel costruisce i tunnel tra i nodi perché un pod possa parlare con un pod
altrove come se fossero sulla stessa rete. **Dall'IP di un pod si deduce il
nodo** — utile per verificare l'anti-affinity senza guardare la colonna `NODE`.

I Service invece stanno su `10.43.x.x`: sono IP **virtuali**, non appartengono a
nessuna interfaccia. Esistono solo come regole iptables su ogni nodo.

---

# Tabelle di riferimento

## Serve `-n` o no?

**La regola:** se la risorsa "vive dentro" un namespace, serve `-n`.

| Serve `-n <namespace>` | NON serve (risorse di cluster) |
|---|---|
| `pod`, `deployment`, `statefulset`, `job` | `namespace` |
| `service`, `endpointslice`, `ingress` | `node` |
| `secret`, `configmap` | `persistentvolume` (PV) |
| `persistentvolumeclaim` (PVC) | `storageclass` |
| `replicaset`, `daemonset` | `clusterrole`, `clusterrolebinding` |
| `role`, `rolebinding`, `serviceaccount` | `customresourcedefinition` |

L'intuizione: le risorse di cluster sono quelle **condivise da tutti** o che
*contengono* i namespace. Sarebbe assurdo che un nodo appartenesse a un
namespace.

Per scoprirlo da soli:

```bash
kubectl api-resources --namespaced=false    # lista corta: le risorse di cluster
kubectl api-resources --namespaced=true     # tutto il resto
```

Note pratiche:

- **`-A` (`--all-namespaces`)** funziona solo sulle risorse namespaced. Su un
  `get ns -A` viene ignorato in silenzio.
- **`-n` ripetuto non somma**: `-n db -n web` usa solo l'**ultimo**. Per vedere
  più namespace serve `-A`, eventualmente con `-l`.
- Il `namespace:` scritto **nel manifest** vale per `apply`; la *lettura* con
  `get`/`describe` richiede comunque il flag.
- Scrivere `namespace:` nel manifest è preferibile a passare `-n`: l'oggetto sa
  dove vive e non dipende dal fatto che tu ricordi il flag. Senza, un `apply`
  finirebbe in `default`.

## Abbreviazioni

| Lungo | Corto |
|---|---|
| `namespaces` | `ns` |
| `pods` | `po` |
| `services` | `svc` |
| `deployments` | `deploy` |
| `statefulsets` | `sts` |
| `persistentvolumeclaims` | `pvc` |
| `persistentvolumes` | `pv` |
| `storageclasses` | `sc` |
| `configmaps` | `cm` |
| `replicasets` | `rs` |

`kubectl api-resources` mostra tutte le abbreviazioni nella colonna
`SHORTNAMES`.

## Comandi di ispezione

| Comando | A cosa serve |
|---|---|
| `k get pods -n web -o wide` | stato dei pod **+ nodo e IP** — `-o wide` è quasi sempre quello che vuoi |
| `k describe pod <nome> -n web` | stato completo + **eventi** in fondo: il primo posto dove guardare quando qualcosa non parte |
| `k get events -n web --field-selector reason=FailedScheduling` | perché un pod non viene schedulato, senza cercare il pod giusto |
| `k get events -n web --sort-by=.lastTimestamp` | cronologia di cosa è successo nel namespace |
| `k logs -n web -l app=web --prefix --tail=-1` | log di **tutti** i pod con quell'etichetta; `--prefix` mostra da quale pod viene ogni riga |
| `k logs <pod> -n web -f` | log in tempo reale di un pod |
| `k logs <pod> -n web --previous` | log del container **precedente**: indispensabile con `CrashLoopBackOff` |
| `k get endpointslice -n db` | **quali pod ha trovato un Service**: se vuoto, il selector non combacia |
| `k exec -n db mysql-0 -- <comando>` | esegue un comando dentro un container (il `--` separa gli argomenti) |
| `k exec -it <pod> -n web -- sh` | shell interattiva dentro un pod |
| `k get all -n web` | panoramica dei tipi principali (**non** include Secret, ConfigMap, PVC) |
| `k get all -A -l progetto=menu` | tutto il progetto, in ogni namespace |
| `k get <tipo> <nome> -n <ns> -o yaml` | il manifest come lo vede il cluster, campi derivati inclusi |
| `k get <tipo> -o jsonpath='{...}'` | estrae un singolo campo — utile negli script |
| `k api-resources` | tutti i tipi di risorsa, con abbreviazioni e se sono namespaced |
| `k explain statefulset.spec.template` | documentazione dello schema, campo per campo, **offline** |

`k explain` è sottovalutato: descrive i campi validi di qualsiasi oggetto senza
aprire il browser, e riflette la versione **del tuo** cluster.

## Comandi di modifica

| Comando | Effetto | Nota |
|---|---|---|
| `k apply -f <file>` | applica lo stato descritto | **dichiarativo**: rimuove i campi non dichiarati |
| `k apply -f manifests/` | applica un'intera cartella | |
| `k diff -f <file>` | mostra cosa cambierebbe **senza applicare** | l'equivalente di `tofu plan` |
| `k delete -f <file>` | rimuove gli oggetti descritti nel file | |
| `k rollout restart deploy/web -n web` | ricrea i pod senza cambiare il manifest | serve per rileggere un Secret cambiato |
| `k rollout status deploy/web -n web` | attende il completamento di un rollout | |
| `k rollout undo deploy/web -n web` | torna alla versione precedente | |
| `k scale deploy/web -n web --replicas=4` | cambia le repliche | **imperativo**: divergenza dal repo |

⚠️ **`scale` e simili creano divergenza.** Dopo uno `scale` il cluster e il file
non concordano più: è il modo classico in cui l'infrastruttura come codice
smette di descrivere la realtà. Per riallineare basta rilanciare `apply`.

## Stati dei pod e cosa significano

| Stato | Significato | Prima cosa da guardare |
|---|---|---|
| `Pending` | non ancora assegnato a un nodo, o volume non pronto | `k get events` → `FailedScheduling` |
| `ContainerCreating` | nodo assegnato, sta scaricando l'immagine o montando il volume | normale per 30-60s con immagini grandi |
| `Running` con `0/1` | container avviato ma non **pronto** | la readiness probe, o l'app che non parte |
| `CrashLoopBackOff` | il container parte e muore in continuazione | `k logs --previous` |
| `ImagePullBackOff` | non riesce a scaricare l'immagine | nome sbagliato, tag inesistente, o registry privato senza `imagePullSecrets` |
| `Terminating` | in chiusura, periodo di grazia (default 30s) | normale |
| `Completed` | terminato con successo | atteso per i `Job` |

---

# Verifiche del progetto

## I due pod sono su nodi diversi

```bash
k get pods -n web -o wide
```

Le colonne `NODE` devono differire. Controprova indipendente: i prefissi degli
IP (`10.42.0.x` vs `10.42.2.x`) indicano nodi diversi.

## Il vincolo è davvero duro

Esperimento: chiedere più repliche che nodi.

```bash
k scale deploy/web -n web --replicas=4
k get pods -n web -o wide       # 3 Running su 3 nodi + 1 Pending
k get events -n web --field-selector reason=FailedScheduling
# "0/3 nodes are available: 3 node(s) didn't match pod anti-affinity rules"
k apply -f manifests/20-web-deployment.yaml   # riallinea a 2
```

Nel messaggio compare anche `preemption: No preemption victims found`. La
**prelazione** è il meccanismo per cui un pod ad alta priorità può far sfrattare
pod meno importanti. Lo scheduler l'ha valutata e scartata: qui non è un problema
di risorse ma di regole, quindi uccidere qualcosa non aiuterebbe.

Con `preferred` invece di `required` il quarto pod sarebbe partito su un nodo già
occupato.

## Il NodePort risponde da ogni nodo

```bash
for ip in 10 11 12; do
  curl -s -o /dev/null -w "150.$ip → %{http_code}\n" "http://192.168.150.$ip:30080"
done
```

Tutti `200`, **incluso il nodo senza pod web**.

## Il bilanciamento è reale

```bash
for i in $(seq 1 20); do curl -s http://192.168.150.11:30080 > /dev/null; done
k logs -n web -l app=web --prefix --tail=-1 | grep "GET /" \
  | sed 's/^\[\([^]]*\)\].*/\1/' | sort | uniq -c
```

Attesi conteggi su **due** righe, non necessariamente pari: kube-proxy usa
iptables con selezione probabilistica, non round-robin. Una distribuzione 7/15 è
normale.

Se compare **una sola** riga, `curl` ha riusato la stessa connessione TCP: il
bilanciamento avviene **per connessione**, non per richiesta HTTP. Un client con
connessioni persistenti resta legato a un pod. Rilanciare con
`curl -H 'Connection: close'`.

## Il database funziona

```bash
k exec -n db mysql-0 -- mysql -u menu_user \
  -p"$(k get secret mysql-credentials -n db -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)" \
  -e 'SHOW DATABASES;'
```

Atteso: `information_schema`, `menu`, `performance_schema`.

⚠️ Il warning di MySQL sulla password a riga di comando è **corretto**: il
comando finisce nella `bash_history` in chiaro. Accettabile in un lab.

---

# Trappole incontrate

## 1. `kubectl get endpoints` è deprecato (ma il manifest è valido)

```
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
```

Riguarda il **comando**, non lo YAML. `Endpoints` era un elenco unico con tutti
gli IP dietro un Service: con migliaia di pod diventava un oggetto enorme da
ritrasmettere per intero a ogni cambiamento. `EndpointSlice` lo spezza in blocchi
da cento.

**Regola generale per gli avvisi di deprecazione:** capire se riguardano il tuo
manifest (vanno corretti: un `apiVersion` deprecato smetterà di funzionare) o il
comando che hai battuto (è solo un suggerimento).

## 2. `apply` rimuove ciò che non è dichiarato

Vedi `../scripts/README.md`. In breve: `apply` **allinea**, non aggiunge
soltanto. Un campo presente nell'oggetto ma assente dal manifest viene rimosso.
Non mescolare comandi imperativi e file dichiarativi sullo stesso oggetto.

## 3. `grep -A N` nasconde le righe *sopra*

Debug di un problema di indentazione in un template: guardavamo il blocco
`content:` con `grep -A6` mentre la riga rotta era quella **precedente**. Tre
tentativi sbagliati per questo motivo.

Per ispezionare un intervallo conservando il contesto:

```bash
sed -n '/inizio/,/fine/p' file
```

## 4. Un pod `Running` non è un pod pronto

`Running` significa che il container è avviato, non che l'applicazione risponde.
La colonna `READY` (`0/1` vs `1/1`) è quella che conta, e dipende dalla
**readiness probe**. Senza probe definita, Kubernetes considera pronto il pod
appena il processo parte — anche se l'app sta ancora inizializzando.

## 5. `apiVersion` sbagliato

`Deployment` e `StatefulSet` stanno in `apps/v1`, non in `v1`. `Service`,
`Secret`, `ConfigMap`, `Namespace`, `PVC` stanno in `v1`. Sbagliarlo produce
errori criptici del tipo "no matches for kind".

Per verificare:

```bash
k api-resources | grep -i statefulset    # colonna APIVERSION
```

---

# Da fare

- [ ] **Sostituire nginx con l'applicazione reale** (`ghcr.io/martinazelli/menu:v1`)
- [ ] **`Job` di inizializzazione del database.** `main.py` non chiama mai
  `init_db()`: le tabelle le crea `popola_db.py`, che nel `docker-compose`
  originale era un secondo servizio. In Kubernetes è un `Job` — stessa immagine,
  comando sovrascritto a `python3 popola_db/popola_db.py`, con `PYTHONPATH=/app`
- [ ] **Sonde di salute.** L'app non ha un endpoint `/health` (il suo README lo
  segnala come "da implementare"): usare `/menu/elenco-piatti` o la radice
  statica
- [ ] Valutare `initContainer` che attende MySQL, invece di lasciare l'app in
  crash loop al primo avvio
- [ ] Rimuovere `10-db-secret.yaml` / `.example.yaml`, ora che
  `gen-secrets.sh` gestisce lo stesso oggetto: due sorgenti per la stessa cosa
  sono un rischio
- [ ] `NetworkPolicy` per limitare l'accesso a MySQL solo dai pod di `web`
  (richiede un CNI che le supporti — Flannel di k3s **non** le applica)
- [ ] Provare gli stessi manifest sul cluster kubeadm: dovrebbero funzionare
  identici, tranne il pod che oggi gira sul control plane (lì è tainted)
