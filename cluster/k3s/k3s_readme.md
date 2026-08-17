# cluster/k3s — installazione del cluster con k3s

Percorso 1 di 2 per costruire il cluster. L'alternativa è `../kubeadm/`.

Il risultato è lo stesso: un cluster Kubernetes a tre nodi su cui girano identici
i manifest in `../../manifests/`.

**Prerequisito:** le tre VM create da `../../infra/`, raggiungibili via SSH.

## Cos'è k3s, e cosa nasconde

k3s è una distribuzione Kubernetes in **un singolo binario**. Su un Kubernetes
tradizionale installeresti separatamente etcd, API server, scheduler, controller
manager, kubelet e un plugin di rete: sei o sette componenti da configurare. Qui
sono tutti dentro lo stesso processo, gestito da **un solo servizio systemd**.

Scelte che k3s fa al posto tuo:

| Componente | Sostituto in k3s |
|---|---|
| Database dello stato | **SQLite** invece di etcd (sufficiente per un control plane singolo) |
| Rete dei pod (CNI) | **Flannel**, già configurato |
| Ingress controller | **Traefik** — noi lo disattiviamo |
| Storage | **local-path-provisioner** di Rancher, già installato |
| LoadBalancer | **ServiceLB** (klipper) |

Differenza importante rispetto a kubeadm: **il nodo server di k3s è
schedulabile**. Non ha la taint `node-role.kubernetes.io/control-plane:NoSchedule`,
quindi i pod utente possono girarci. Con kubeadm servono nodi worker separati.

Versione installata: **v1.36.3+k3s1**, containerd 2.3.2.

## Installazione

### 1. Il control plane

Da dentro `k8s-cp`:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --write-kubeconfig-mode=644" sh -
```

I parametri:

- **`--disable=traefik`** — il lab non usa Ingress (il traffico entra via
  NodePort), quindi Traefik non serve. Meglio non installarlo che installarlo e
  disattivarlo dopo.
- **`--write-kubeconfig-mode=644`** — il kubeconfig viene scritto in
  `/etc/rancher/k3s/k3s.yaml` con permessi da root. Con `644` lo legge anche
  l'utente `ubuntu`, così `kubectl` funziona senza `sudo`. **Accettabile solo in
  un lab**: chiunque abbia accesso alla macchina diventa amministratore del
  cluster.

Su `curl | sh`: è il metodo ufficiale, ma è codice preso da Internet eseguito con
privilegi elevati. Per ispezionarlo prima: `curl -sfL https://get.k3s.io | less`.
Lo script verifica l'hash del binario che scarica.

Cosa crea:

- `/usr/local/bin/k3s`, con `kubectl`, `crictl` e `ctr` come **symlink allo stesso
  binario** (k3s guarda con che nome è stato invocato)
- `/etc/systemd/system/k3s.service`
- `/usr/local/bin/k3s-uninstall.sh` e `k3s-killall.sh`

### 2. Il token di join

```bash
K3S_TOKEN=$(ssh k8s-cp 'sudo cat /var/lib/rancher/k3s/server/node-token')
echo "${#K3S_TOKEN} caratteri"   # atteso: ~108
```

`$(...)` cattura l'output invece di stamparlo: il token non passa per il
copia-incolla e non resta nella history.

`${#VAR}` restituisce la lunghezza: verifica che il segreto sia arrivato senza
mostrarlo a schermo.

**Il token è una credenziale.** Chi lo possiede può aggiungere un nodo al
cluster, e un nodo ha accesso a parecchio. Non va nel repo.

### 3. I worker

Un nodo alla volta:

```bash
ssh k8s-w1 "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.150.10:6443 K3S_TOKEN='${K3S_TOKEN}' sh -"
ssh k8s-w2 "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.150.10:6443 K3S_TOKEN='${K3S_TOKEN}' sh -"
```

**È lo stesso script del control plane.** Non esiste un installatore separato per
i worker: quello che decide il ruolo è la presenza di `K3S_URL`. Se c'è, lo script
avvia un **agent** che si collega a quel control plane; se manca, avvia un
**server**. Lo si vede nell'output — crea `k3s-agent.service` invece di
`k3s.service`.

La porta **6443** è quella standard dell'API server di Kubernetes.

Sulle virgolette: **doppie fuori, singole attorno a `${K3S_TOKEN}`**. Le doppie
permettono a bash *locale* di sostituire la variabile prima di spedire la stringa;
le singole proteggono il valore da interpretazioni sulla macchina remota. Con
l'annidamento invertito il token arriva vuoto.

Nota che il token finisce nella riga di comando e quindi nella `bash_history`
delle VM. Accettabile in un lab; in produzione si usa un file con permessi
ristretti.

### 4. kubeconfig sull'host

Per amministrare dal proprio PC invece che via SSH:

```bash
ssh k8s-cp 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config-k3s
chmod 600 ~/.kube/config-k3s
sed -i 's|https://127.0.0.1:6443|https://192.168.150.10:6443|' ~/.kube/config-k3s
```

La sostituzione è necessaria: dentro il file l'indirizzo è `127.0.0.1`, corretto
dal punto di vista del control plane, inutile dall'esterno.

In `sed` si usa `|` come delimitatore perché l'URL contiene già delle `/`.

Il file contiene le **credenziali di amministratore del cluster**: permessi `600`,
ed è escluso dal `.gitignore`.

Fusione con un kubeconfig esistente, senza perdere i contesti già presenti:

```bash
cp ~/.kube/config ~/.kube/config.backup-$(date +%F)
KUBECONFIG=~/.kube/config:~/.kube/config-k3s kubectl config view --flatten > ~/.kube/merged
KUBECONFIG=~/.kube/merged kubectl config get-contexts   # verifica PRIMA di sostituire
mv ~/.kube/merged ~/.kube/config
```

`KUBECONFIG` accetta **più file separati da `:`** e li tratta come un kubeconfig
unico. `--flatten` incorpora certificati e chiavi nel risultato, rendendolo
autonomo.

Il contesto di k3s si chiama `default`; conviene rinominarlo:

```bash
kubectl config rename-context default k3s
kubectl config use-context k3s
```

`use-context` è **persistente**: riscrive `current-context` nel file.

## Verifica

```bash
sudo systemctl status k3s --no-pager     # sul control plane: active (running)
kubectl get nodes -o wide
kubectl get pods -A
```

Atteso: tre nodi `Ready`, e in `kube-system` i pod `coredns`,
`local-path-provisioner`, `metrics-server`. **Nessun Traefik** — è la conferma che
`--disable=traefik` ha funzionato.

Sui worker `ROLES` mostra `<none>`: non è un errore. In Kubernetes il ruolo è solo
un'etichetta, e la convenzione è che i worker non ne abbiano.

Gli IP dei pod sono `10.42.x.x`, non `192.168.150.x`: è la rete dei pod, una rete
virtuale sovrapposta a quella delle VM. Ogni nodo riceve un blocco
(`10.42.0.0/24`, `10.42.1.0/24`, …) e Flannel costruisce i tunnel tra i nodi.

## Comodità

Alias `k` con completamento funzionante (aggiungere a `~/.bashrc`):

```bash
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
```

La terza riga è quella che si dimentica. Bash associa il completamento a un **nome
di comando**: `kubectl completion bash` registra la funzione `__start_kubectl` per
il nome `kubectl`, ma `k` è un nome diverso. `complete -F` gliela associa
esplicitamente.

Il completamento conosce anche i nomi delle risorse reali: `k get pod <TAB>`
elenca i pod esistenti. Su nomi generati come
`local-path-provisioner-58d557dc48-wfxfl` fa la differenza.

## Rimozione

```bash
# sul control plane
sudo /usr/local/bin/k3s-uninstall.sh
# sui worker
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

⚠️ Lo script chiama `k3s-killall.sh`, che **ripulisce regole iptables e interfacce
di rete**. Se lo si esegue su una macchina che ospita anche Docker o libvirt, dopo
va ripristinato l'ambiente:

```bash
sudo systemctl restart docker
sudo systemctl restart k8s-lab-firewall.service
```

---

# Trappole incontrate

## 1. Un server k3s installato per sbaglio sull'host

**Sintomo.** Dopo un `exit` da una sessione SSH, l'host inizia da solo
un'installazione di k3s. Indizi nell'output:
`[sudo] password for topina` (utente dell'host, non della VM) e
`Skipping /usr/local/bin/kubectl symlink, command exists in PATH at /usr/bin/kubectl`
(il kubectl installato da pacman).

**Causa.** `ssh k8s-cp` e il comando `curl` erano stati incollati **in blocco**.
SSH ha preso il controllo del terminale e la riga del `curl` è rimasta nel buffer
di input della **shell locale**. Appena `exit` ha restituito il controllo, la shell
ha letto il suo buffer e ha eseguito il comando in attesa — sull'host.

L'input incollato **non va perso** quando un programma prende il terminale: resta
in coda. Da qui il "sembra partito all'improvviso".

Senza `K3S_URL` lo script installa un **server**, non un agent: quindi l'host si è
ritrovato con un secondo control plane, la porta 6443 occupata, un containerd
proprio e — soprattutto — le mani nelle regole iptables.

**Rimedio.** `k3s-uninstall.sh` più il riavvio di Docker e del servizio firewall
(vedi sopra). Verificare che `which kubectl` dia ancora `/usr/bin/kubectl`.

**Lezione:** i comandi interattivi non si incollano in blocco. Vale per `ssh` al
primo contatto, `sudo` che chiede la password, `tofu apply` che chiede `yes`.

## 2. Gli alias non esistono nei comandi remoti

`ssh k8s-cp 'k get nodes'` risponde `bash: line 1: k: command not found`, mentre
`k get nodes` dentro una sessione interattiva funziona.

**Causa.** `ssh host 'comando'` avvia una shell **non interattiva**, e bash in
quella modalità **non legge `~/.bashrc`**. Inoltre gli alias sono disabilitati per
default nelle shell non interattive.

Non è un bug: `.bashrc` contiene configurazioni per l'uso umano, che in uno script
darebbero fastidio — un alias potrebbe cambiare silenziosamente il significato di
un comando.

**Regola operativa:** negli script e nei comandi remoti si usano sempre i nomi
completi. Gli alias sono per le dita, non per l'automazione.

## 3. Errori di avvio che si risolvono da soli

Nel log del control plane, subito dopo l'installazione:

```
error resolving kube-system/metrics-server: no endpoints available for service "metrics-server"
"failed to discover some groups" groups="map[\"metrics.k8s.io/v1beta1\":...]"
```

È **rumore di avvio**: il control plane cercava metrics-server prima che il suo pod
fosse pronto. Poche righe dopo compare
`Adding GroupVersion metrics.k8s.io v1beta1 to ResourceManager` — risolto da sé.

Distinguere gli errori transitori dell'avvio da quelli reali è metà del lavoro con
Kubernetes. Criterio: se il log **continua** a ripeterli dopo qualche minuto, sono
veri.

---

# Da fare

- [ ] Automatizzare l'installazione con Ansible (i comandi qui sopra sono il
  candidato naturale per due ruoli, `k3s_server` e `k3s_agent`)
- [ ] Confrontare questa procedura con `../kubeadm/` una volta scritta: ogni
  componente che lì va installato a mano, qui era già presente
