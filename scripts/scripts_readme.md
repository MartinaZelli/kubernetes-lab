# scripts/ — configurazione dell'host e generazione dei segreti

Questa cartella contiene due famiglie di script, che intervengono su due livelli
diversi:

- **prerequisiti dell'host** (il PC Arch che fa da hypervisor): storage pool di
  libvirt e regole firewall. Servono *prima* di `tofu apply`.
- **generazione dei segreti nel cluster**: deriva i Secret Kubernetes da una
  sorgente unica fuori da Git. Serve *dopo* che il cluster è in piedi.

## Perché esistono

Il codice OpenTofu in `../infra/` descrive le macchine virtuali. Non descrive
l'hypervisor che le ospita: quello è un presupposto. Ci sono quindi alcune cose
che vanno configurate sull'host e che, se mancano, fanno fallire `tofu apply` con
errori che sembrano non avere niente a che fare con la causa reale.

I segreti sono l'altro caso di cosa che non può stare nei manifest versionati:
il valore vero non va su Git, ma la *procedura* per ricostruirlo sì.

Questi script rendono espliciti e ripetibili entrambi i presupposti, invece di
lasciarli in un messaggio di chat o nella memoria di chi li ha fatti la prima
volta.

## Cosa contiene

| File | Ruolo | Quando |
|---|---|---|
| `host-setup.sh` | Punto di ingresso per l'host. Esegue tutto. Da lanciare come root. | Prima di `tofu apply` |
| `k8s-lab-firewall.sh` | Regole `iptables` per la rete NAT delle VM. Installato in `/usr/local/bin/`. | (installato da `host-setup.sh`) |
| `k8s-lab-firewall.service` | Unit systemd che riapplica le regole a ogni avvio. Installata in `/etc/systemd/system/`. | (installata da `host-setup.sh`) |
| `gen-secrets.sh` | Genera i Secret Kubernetes da `../secrets/db.env`. | Dopo l'installazione del cluster |

---

# Parte 1 — prerequisiti dell'host

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
ssh k8s-cp 'ping -c2 1.1.1.1'
```

## Disinstallare

```bash
sudo systemctl disable --now k8s-lab-firewall.service
sudo rm /etc/systemd/system/k8s-lab-firewall.service /usr/local/bin/k8s-lab-firewall.sh
sudo systemctl daemon-reload
```

Le regole già inserite in `DOCKER-USER` restano in memoria fino al riavvio o
fino al prossimo restart di Docker.

---

# Parte 2 — `gen-secrets.sh`

## Il problema

L'applicazione e il database vogliono le **stesse credenziali con nomi
diversi**:

| Cosa | Nome per `mysql:8.0` | Nome per l'app |
|---|---|---|
| Database | `MYSQL_DATABASE` | `DB_NAME` |
| Utente | `MYSQL_USER` | `DB_USER` |
| Password | `MYSQL_PASSWORD` | `DB_PASSWORD` |
| Password root | `MYSQL_ROOT_PASSWORD` | *(non serve)* |

E stanno in **namespace diversi**: MySQL in `db`, l'app in `web`.

Un Secret è una risorsa *dentro* un namespace e **non è leggibile da altri
namespace**. Non esiste un modo nativo per condividerlo. Quindi servono due
oggetti Secret distinti.

Il rischio è ovvio: due file con le stesse password, che prima o poi divergono.

## La soluzione

Una **sorgente unica** in `../secrets/db.env` (fuori da Git), e i due Secret
derivati da quella:

```
secrets/db.env  ──┬──►  Secret mysql-credentials  (namespace db)
                  └──►  Secret db-connection      (namespace web)
```

I due Secret ricevono **sottoinsiemi diversi**: `db-connection` non contiene la
password di root, perché l'applicazione non ha bisogno dei privilegi di root sul
database. È il **principio del minimo privilegio** — se l'app viene compromessa,
l'attaccante ottiene solo il suo utente.

## Come si crea la sorgente

⚠️ **Attenzione all'ordine.** Le variabili `MYSQL_*` dell'immagine ufficiale
valgono **solo al primo avvio**: la password dell'utente è già scritta nei file
del database sul volume. Se MySQL è già inizializzato, non si può generare una
password nuova — va recuperata quella in uso, altrimenti l'app non si connette.

**Primo setup** (database non ancora creato):

```bash
mkdir -p secrets
{
  echo "DB_HOST=mysql.db.svc.cluster.local"
  echo "DB_PORT=3306"
  echo "DB_NAME=menu"
  echo "DB_USER=menu_user"
  echo "DB_PASSWORD=$(openssl rand -hex 24)"
  echo "DB_ROOT_PASSWORD=$(openssl rand -hex 24)"
} > secrets/db.env
chmod 600 secrets/db.env
```

**Ricostruzione** (database già esistente, password da recuperare dal cluster):

```bash
{
  echo "DB_HOST=mysql.db.svc.cluster.local"
  echo "DB_PORT=3306"
  echo "DB_NAME=menu"
  echo "DB_USER=menu_user"
  echo "DB_PASSWORD=$(kubectl get secret mysql-credentials -n db -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)"
  echo "DB_ROOT_PASSWORD=$(kubectl get secret mysql-credentials -n db -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)"
} > secrets/db.env
chmod 600 secrets/db.env
```

Le graffe `{ ...; }` raggruppano i comandi in modo che l'output complessivo
finisca in un unico file: senza, la redirezione varrebbe solo per l'ultimo
`echo`.

`openssl rand -hex` invece di `-base64` di proposito: `hex` produce solo cifre e
lettere, mentre base64 include `+`, `/` e `=`, che in YAML e nelle stringhe di
connessione richiedono virgolette e a volte causano guai.

Verifica senza esporre i valori:

```bash
sed 's/=.*/=***/' secrets/db.env    # mostra le chiavi mascherando i valori
```

## Applicare

```bash
chmod +x scripts/gen-secrets.sh
./scripts/gen-secrets.sh
kubectl get secret -A -l progetto=menu    # attesi: mysql-credentials in db, db-connection in web
```

Idempotente: rilanciarlo aggiorna gli oggetti senza errori.

## Le tre tecniche che usa

### `source "${SRC}"`

Legge il file e definisce le variabili nella shell corrente. Funziona perché il
formato `CHIAVE=valore` è sintassi bash valida. È lo stesso meccanismo dei file
`.env` di Docker Compose: non è magia, è uno script letto da bash.

### `--dry-run=client -o yaml | kubectl apply -f -`

L'idioma più utile del blocco. Da leggere da destra:

- `kubectl create secret` costruisce l'oggetto, ma **`create` fallisce se
  l'oggetto esiste già** — non è idempotente
- `--dry-run=client` non contatta il cluster: genera solo il manifest
- `-o yaml` lo stampa
- `| kubectl apply -f -` lo applica in modo dichiarativo (il `-` finale significa
  "leggi da stdin")

Risultato: la comodità di `create`, che risparmia di scrivere lo YAML a mano, con
l'idempotenza di `apply`. È la tecnica standard per Secret e ConfigMap.

### `kubectl label --local -f - progetto=menu -o yaml`

`kubectl create secret` **non accetta un'opzione per le label**. Questo passo le
aggiunge al manifest mentre passa nella pipeline.

Normalmente `kubectl label` modifica un oggetto *nel cluster*, ma con `--local`
opera solo sul manifest ricevuto da stdin, e `-o yaml` lo restituisce
modificato. Diventa un filtro.

Stesso principio del `--dry-run=client`: usare `kubectl` come **trasformatore di
testo** invece che come azione sul cluster. Una volta capito, permette di
comporre cose che a mano sarebbero noiose.

## Rotazione della password

Cambiare la password nel Secret **non** cambia la password dentro MySQL: quella
è nei dati sul volume. La procedura corretta:

1. cambiarla dentro MySQL con `ALTER USER`
2. aggiornare `secrets/db.env`
3. rilanciare `gen-secrets.sh`
4. riavviare i pod che la usano (`kubectl rollout restart`)

I pod non rileggono un Secret modificato se lo consumano come variabili
d'ambiente: le variabili vengono impostate alla creazione del processo. Con i
Secret montati come **file** l'aggiornamento invece propaga, con un ritardo di
circa un minuto.

---

# Scelte di implementazione (tutti gli script)

**`set -euo pipefail`** in testa a ogni script:

- `-e` interrompe al primo comando fallito, invece di proseguire su basi sbagliate
- `-u` tratta come errore l'uso di una variabile non definita (salva dai refusi nei nomi)
- `-o pipefail` fa fallire una pipeline se fallisce un comando qualsiasi, non solo l'ultimo

**Idempotenza.** Gli script descrivono uno *stato desiderato*, non una sequenza
di azioni: rilanciarli dieci volte deve dare lo stesso risultato di lanciarli
una. Nel firewall si ottiene con `iptables -C`, che verifica se la regola esiste
già; per il pool con `virsh pool-info`; per i Secret con l'idioma
`--dry-run | apply`. È lo stesso principio di OpenTofu e Ansible.

**`Type=oneshot` con `RemainAfterExit=yes`.** Il servizio non è un processo che
resta in vita, è un'azione che si esegue e finisce. Senza `RemainAfterExit`
systemd lo considererebbe morto subito dopo e alcuni comandi lo mostrerebbero
come fallito.

**`After=docker.service`.** La catena `DOCKER-USER` la crea Docker. Se lo script
partisse prima, `iptables` fallirebbe perché la catena non esiste ancora.

**`install` invece di `cp`.** Imposta contenuto e permessi in un colpo solo:
`755` per lo script (eseguibile), `644` per l'unit (solo dati).

**`readonly` sulle costanti.** Rende esplicito che non vanno riassegnate e fa
fallire un tentativo accidentale di sovrascrittura.

# Alternative scartate, e perché

- **`iptables-save` + ricarica all'avvio** — congelerebbe anche le regole *di
  Docker* come sono oggi. Al prossimo aggiornamento o riconfigurazione di Docker
  si avrebbe un conflitto tra le sue regole nuove e quelle vecchie ricaricate.
- **`"ip-forward-no-drop": true` in `/etc/docker/daemon.json`** — risolve alla
  radice ma allenta la postura di sicurezza per *tutti* i container, non solo per
  questo caso.
- **SOPS / Sealed Secrets / External Secrets Operator** per i segreti — è la
  risposta professionale (l'equivalente Kubernetes di Ansible Vault: si cifra il
  file e si committa la versione cifrata). Scartata *per ora* perché è un
  componente in più da installare e capire. Vedi "Da fare".
- **Un solo namespace per tutto** — eliminerebbe il problema della duplicazione
  dei Secret, ma il lab prevede namespace separati di proposito, per imparare il
  DNS cross-namespace.

# Trappole incontrate

## `sed -i` su un file che documenta se stesso

Una sostituzione globale del tipo

```bash
sed -i 's#--dry-run=client -o yaml | kubectl apply -f -#...#g' scripts/gen-secrets.sh
```

ha colpito **anche i commenti** dello script, che contenevano la stessa stringa
per spiegarla. Il codice è rimasto valido ma la documentazione è stata corrotta.

Lezione: `sed -i` su file che contengono testo *che parla* del codice è
rischioso. Meglio la modifica a mano, o un pattern ancorato all'inizio di riga.

## `apply` rimuove ciò che non è dichiarato

I due Secret erano stati creati la prima volta senza label, perché
`kubectl create secret` non le supporta. Ma il vecchio `mysql-credentials`, che
era stato applicato da un manifest YAML **con** l'etichetta, l'ha **perduta**: lo
script lo ha sovrascritto con un manifest che non la menzionava.

`apply` non aggiunge soltanto — **allinea**. Se un oggetto ha un campo che il
manifest non menziona, `apply` lo considera non voluto e lo toglie.

È il comportamento corretto (è ciò che rende l'infrastruttura come codice
affidabile) ma sorprende, e spiega perché **mescolare comandi imperativi e file
dichiarativi sullo stesso oggetto porta guai**.

## Comandi interattivi e copia-incolla in blocco

Incollare più comandi insieme si rompe con qualunque comando che si fermi ad
aspettare una risposta: `ssh` al primo contatto con un host, `sudo` che chiede la
password, `tofu apply` che chiede `yes`, `read -rs` che aspetta un token. La riga
successiva del blocco viene letta come risposta.

L'input incollato **non va perso** quando un programma prende il terminale: resta
in coda e viene eseguito quando la shell riprende il controllo. Vedi
`../cluster/k3s/README.md`, trappola 1, per il caso più costoso.

Con `read`, usare sempre `-p` per avere un prompt visibile:

```bash
read -rsp 'Token: ' TOKEN; echo    # -s nasconde i caratteri, -p mostra il prompt
```

# Da fare

- [ ] Migrare a Ansible: `host-setup.sh` è il candidato naturale per un ruolo
  `host_prereq`
- [ ] Valutare SOPS per poter versionare i segreti cifrati e togliere
  `secrets/` dal `.gitignore`
- [ ] `SUBNET` in `k8s-lab-firewall.sh` deve restare coerente con
  `ips[].address` in `../infra/network.tf`: accoppiamento implicito tra due file
  in cartelle diverse, si rompe in silenzio
- [ ] Verificare se serve ancora `10-db-secret.yaml` nei manifest, ora che
  `gen-secrets.sh` gestisce lo stesso oggetto: due sorgenti per la stessa cosa
  sono un rischio
