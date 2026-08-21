# Roadmap — cluster kubeadm

Documento di lavoro da tenere a fianco. Spuntare man mano.

**Punto di partenza:** tre VM Ubuntu 24.04 già create e raggiungibili —
`k8s2-cp` (.20), `k8s2-w1` (.21), `k8s2-w2` (.22).

**Obiettivo:** un cluster equivalente a quello k3s, ma con ogni componente
installato a mano, e i **manifest di `manifests/` applicati identici**.

---

## Il quadro: cosa k3s faceva al posto tuo

| Componente | Su k3s | Su kubeadm |
|---|---|---|
| Runtime container | incluso (containerd) | **da installare** |
| kubelet | dentro il binario | **servizio systemd a sé** |
| API server, scheduler, controller manager | dentro il binario | **static pod, creati da `kubeadm init`** |
| Database dello stato | SQLite | **etcd** |
| Rete dei pod (CNI) | Flannel preconfigurato | **Calico, da installare** |
| Storage dinamico | local-path incluso | **da installare** |
| Prerequisiti del sistema | gestiti dallo script | **swap, moduli kernel, sysctl a mano** |

Ogni riga della colonna destra è una cosa che prima era invisibile.

---

## Fase 1 — Prerequisiti sui tre nodi

Da fare su **tutti e tre**. Sono i controlli che `kubeadm init` esegue in
preflight e che fanno fallire l'installazione se mancano.

- [ ] **Swap disattivato** — il kubelet si rifiuta di partire con lo swap attivo.
      Kubernetes decide dove mettere i pod in base alla memoria disponibile: lo
      swap renderebbe quel calcolo una bugia.
- [ ] **Moduli kernel `overlay` e `br_netfilter`** — il primo serve al
      filesystem a layer dei container, il secondo per far vedere il traffico
      del bridge a iptables.
- [ ] **sysctl**: `net.bridge.bridge-nf-call-iptables=1`,
      `net.bridge.bridge-nf-call-ip6tables=1`, `net.ipv4.ip_forward=1`
- [ ] Verifica che siano persistenti al riavvio

**Verifica:** `swapon --show` vuoto, `lsmod | grep -E 'overlay|br_netfilter'`,
`sysctl net.ipv4.ip_forward`.

## Fase 2 — Runtime dei container

- [ ] **containerd** installato e attivo
- [ ] Configurazione generata (`containerd config default`)
- [ ] **`SystemdCgroup = true`** ← il punto in cui sbagliano tutti

> Se kubelet e containerd usano driver di cgroup diversi, il cluster parte e poi
> si comporta in modo instabile in modi che non indicano mai la vera causa.

**Verifica:** `systemctl status containerd`, `crictl version`.

## Fase 3 — I binari di Kubernetes

- [ ] Repository `pkgs.k8s.io` aggiunto (con la chiave GPG)
- [ ] `kubelet`, `kubeadm`, `kubectl` installati
- [ ] **Versioni bloccate** con `apt-mark hold`

> Bloccare le versioni non è pignoleria: un aggiornamento automatico di kubelet
> disallineato dal control plane rompe il nodo.

**Verifica:** `kubeadm version`, `kubelet --version`.

## Fase 4 — `kubeadm init` sul control plane

- [ ] `kubeadm init --pod-network-cidr=10.244.0.0/16`
- [ ] Salvare il comando `kubeadm join` che stampa alla fine (contiene un token,
      **è una credenziale**)
- [ ] kubeconfig copiato e unito a `~/.kube/config` sull'host
- [ ] Contesto rinominato in `kubeadm`

> `10.244.0.0/16` e non il `192.168.0.0/16` di default di Calico: quello
> collide con la LAN di casa e con la rete delle VM. Il valore passato qui e
> quello configurato in Calico **devono coincidere**.

**Da guardare, è il pezzo didattico:** `/etc/kubernetes/manifests/` contiene i
**static pod** del control plane — apiserver, etcd, scheduler, controller
manager. Sono file YAML che il kubelet avvia da solo, senza che esista ancora un
API server a cui chiedere. E `/etc/kubernetes/pki/` contiene tutti i certificati
generati.

**Verifica:** `kubectl get nodes` → un nodo, `NotReady` (manca il CNI, è
atteso).

## Fase 5 — Calico

- [ ] Operator installato
- [ ] `Installation` custom resource con il CIDR corretto
- [ ] Attendere che i pod `calico-*` siano `Running`

**Verifica:** il nodo passa a `Ready`. Prima di Calico non poteva esserlo: senza
CNI i pod non hanno rete.

## Fase 6 — Join dei worker

- [ ] `kubeadm join` su `k8s2-w1`
- [ ] `kubeadm join` su `k8s2-w2`
- [ ] Se il token è scaduto (durano 24h): `kubeadm token create --print-join-command`

**Verifica:** `kubectl get nodes -o wide` → tre nodi `Ready`.

## Fase 7 — Storage

- [ ] local-path-provisioner di Rancher installato a mano
- [ ] Impostato come StorageClass di default

> Su k3s c'era già. Qui è un manifest da applicare — ed è il motivo per cui i
> manifest dell'applicazione funzioneranno senza modifiche.

**Verifica:** `kubectl get storageclass` → `local-path (default)`.

## Fase 8 — L'applicazione

- [ ] `kubectl config use-context kubeadm`
- [ ] `./scripts/gen-secrets.sh`
- [ ] `kubectl apply -f manifests/`
- [ ] Job di init eseguito
- [ ] NodePort raggiungibile su `192.168.150.21:30080`

**La differenza attesa rispetto a k3s:** su k3s un pod web girava sul control
plane. Qui non può — è tainted. Con due worker e due repliche l'anti-affinity è
comunque soddisfatta.

## Fase 9 — Il confronto

- [ ] `kubectl get pods -n kube-system` sui due contesti, a confronto
- [ ] Annotare le differenze nel README di `cluster/kubeadm/`

> Su k3s tre pod: CoreDNS, local-path-provisioner, metrics-server.
> Su kubeadm: etcd, apiserver, scheduler, controller-manager, kube-proxy,
> CoreDNS, più i pod di Calico. **È lo stesso software** — solo che qui si vede.

---

## Ordine consigliato di lavoro

1. Fasi 1-3 su **tutti e tre i nodi** insieme (sono identiche, si può ciclare)
2. Fasi 4-5 solo sul control plane
3. Fase 6 sui due worker
4. Fasi 7-9

## Se qualcosa va storto

```bash
# ripartire da zero su un nodo, senza ricreare la VM
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/etcd
sudo iptables -F && sudo iptables -t nat -F
```

Diagnosi, in ordine:

```bash
sudo journalctl -u kubelet -n 50 --no-pager   # il kubelet è la prima cosa che parla
sudo crictl ps -a                              # i container, anche quelli morti
kubectl get events -A --sort-by=.lastTimestamp
```

## Attenzione trasversali

- Il token di join è una credenziale: non finisce nel repo
- Nulla di ciò che si fa qui deve toccare il cluster k3s: attenzione a quale
  contesto è attivo (`kubectl config current-context`)
