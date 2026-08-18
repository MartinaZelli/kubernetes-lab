#!/usr/bin/env bash
# Genera i Secret Kubernetes dalla sorgente unica secrets/db.env.
#
# Perché serve: un Secret vive dentro un namespace e non è leggibile da altri,
# quindi servono due oggetti distinti. Questo script li deriva da un solo file,
# così non ci sono valori duplicati da tenere sincronizzati a mano.
#
# I due Secret ricevono sottoinsiemi DIVERSI: l'applicazione non ha bisogno
# della password di root (principio del minimo privilegio).

# source "${SRC}" legge il file e definisce le variabili nella shell corrente. Funziona perché il formato CHIAVE=valore è sintassi bash valida. È lo stesso meccanismo dei file .env che usavi con Docker Compose — ora sai che non è magia, è solo uno script letto da bash.
# --dry-run=client -o yaml | kubectl apply -f - è l'idioma più utile di questa lezione. Leggilo da destra:
# kubectl create secret costruirebbe l'oggetto, ma create fallisce se l'oggetto esiste già — non è idempotente.
# --dry-run=client gli dice di non contattare il cluster: genera solo il manifest.
# -o yaml lo stampa.
# | kubectl apply -f - prende quel manifest dallo standard input (il - finale significa "leggi da stdin") e lo applica in modo dichiarativo.

set -euo pipefail

readonly SRC="secrets/db.env"

if [[ ! -r "${SRC}" ]]; then
  echo "Manca ${SRC}. Vedi scripts/README.md" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${SRC}"

kubectl create secret generic mysql-credentials \
  --namespace db \
  --from-literal="MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}" \
  --from-literal="MYSQL_DATABASE=${DB_NAME}" \
  --from-literal="MYSQL_USER=${DB_USER}" \
  --from-literal="MYSQL_PASSWORD=${DB_PASSWORD}" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - progetto=menu -o yaml \
  | kubectl apply -f -

kubectl create secret generic db-connection \
  --namespace web \
  --from-literal="DB_HOST=${DB_HOST}" \
  --from-literal="DB_PORT=${DB_PORT}" \
  --from-literal="DB_NAME=${DB_NAME}" \
  --from-literal="DB_USER=${DB_USER}" \
  --from-literal="DB_PASSWORD=${DB_PASSWORD}" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - progetto=menu -o yaml \
  | kubectl apply -f -

echo "[ok] Secret aggiornati in db e web"
