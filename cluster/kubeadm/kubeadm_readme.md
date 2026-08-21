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
- [ ] Fase 3 — kubelet, kubeadm, kubectl
- [ ] Fase 4 — `kubeadm init`
- [ ] Fase 5 — Calico
- [ ] Fase 6 — join dei worker
- [ ] Fase 7 — storage local-path
- [ ] Fase 8 — l'applicazione
- [ ] Fase 9 — confronto con k3s
