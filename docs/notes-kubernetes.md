# Notes Kubernetes — premiers Pods

Séance 4 du fil rouge. Le namespace `taskflow` regroupe un Pod PostgreSQL et un Pod API. Il n'y a ni Service, ni volume, ni contrôleur : la configuration est dans les manifestes, avec le mot de passe de test `taskflow-test`.

Cluster du labo : k3s v1.36.5+k3s1, serveur `manager.k3s`, agent `worker.k3s`. Administration depuis le poste avec le contexte `k3s-lab` (`KUBECONFIG=$HOME/.kube/k3s-lab.yaml`). La configuration d'installation est consignée dans [`k8s/k3s-config.yaml`](../k8s/k3s-config.yaml). Ce fichier n'est pas un manifeste Kubernetes.

## Point de contrôle

`kubectl get nodes` :

```text
NAME          STATUS   ROLES           AGE   VERSION
manager.k3s   Ready    control-plane   32h   v1.36.5+k3s1
worker.k3s    Ready    worker          31h   v1.36.5+k3s1
```

`kubectl get pods -n taskflow -o wide` (après remise en état ; `RESTARTS` vaut 1 à cause du `kill 1` de l'étape 5) :

```text
NAME   READY   STATUS    RESTARTS   AGE    IP          NODE         NOMINATED NODE   READINESS GATES
api    1/1     Running   1          91s    10.42.1.6   worker.k3s   <none>           <none>
db     1/1     Running   0          2m10s  10.42.1.5   worker.k3s   <none>           <none>
```

`curl` de `/healthz` à travers `kubectl port-forward -n taskflow pod/api 18080:3000` :

```text
HTTP/1.1 200 OK
X-Served-By: api

{"status":"ok","version":"1.0.0","hostname":"api"}
```

L'en-tête `X-Served-By` vaut `api`, le nom du Pod. Kubernetes donne ce nom comme nom d'hôte du conteneur, et l'API le recopie dans l'en-tête.

## Namespace

Les Pods portent `metadata.namespace: taskflow`. C'est le choix le plus sûr pour un tiers qui applique les fichiers : le résultat ne dépend pas du namespace courant de son contexte kubectl. Compter sur le défaut du contexte appliquerait les Pods dans `default` si personne n'a fait `kubectl config set-context --current --namespace=taskflow`.

## Pod de base de données

Transposition du service `db` de `compose.yaml` : image `postgres:18-alpine`, port 5432, variables `POSTGRES_DB`, `POSTGRES_USER` et `POSTGRES_PASSWORD`.

Il n'y a pas d'équivalent du fichier `.env`. La variable à renseigner directement, à titre provisoire, est `POSTGRES_PASSWORD`. Les deux autres ont les mêmes valeurs par défaut que Compose (`taskflow`).

Le volume nommé `postgres_data` n'est pas repris. Les fichiers de la base sont dans le système de fichiers du conteneur. Suppression du Pod `db` (IP `10.42.1.3`) puis recréation à partir du même manifeste : la nouvelle IP est `10.42.1.5`, et `psql` répond `Did not find any tables.` Les tâches créées avant la suppression n'existent plus.

Labels : `app=taskflow` et `component=db`. Ils identifieront le Pod quand un Service ou un contrôleur les sélectionnera.

PostgreSQL journalise `database system is ready to accept connections` une fois prêt. L'adresse relevée est `10.42.1.5`.

## Pod API

Image publiée en séance 1 : `docker.io/rchrdkvcs/taskflow-api:1.0.0`. Labels `app=taskflow` et `component=api`. Variables d'environnement du README (`HOST`, `PORT`, `APP_ENV`, `DB_*`, plafonds de stress et d'arrêt).

Avec Compose, l'API joignait la base par le nom de service `db`. Ce nom n'est pas résolu ici : depuis le Pod API, `dns.lookup("db")` renvoie `ENOTFOUND`. Il n'existe aucun Service. `DB_HOST` reçoit donc l'adresse IP du Pod `db`. Le choix est volontairement provisoire et il est noté dans [`k8s/pods/api.yaml`](../k8s/pods/api.yaml).

Une API qui ne joint pas sa base au démarrage s'arrête après les tentatives (`DB_CONNECT_RETRIES` à 5, intervalle 2 s, soit une dizaine de secondes) et le Pod entre en redémarrage. Ce n'est pas le cas d'une API déjà démarrée dont la base disparaît : le processus reste là.

## Limites de l'approche par Pods

### L'adresse IP change, les données disparaissent

Constat. Après suppression et recréation du Pod `db`, l'adresse passe de `10.42.1.3` à `10.42.1.5`. La table `tasks` n'existe plus sur la nouvelle base. L'API, elle, reste `Running` avec `RESTARTS` à 0 : son environnement a été figé au démarrage avec l'ancienne adresse. `/healthz` répond toujours 200, parce qu'il ne consulte pas la base. `GET /api/tasks` aboutit à une erreur 500, `Connection terminated due to connection timeout`, au bout d'environ 5 s.

Pour qu'elle retrouve la base, il faut éditer `DB_HOST` dans le manifeste puis supprimer et recréer le Pod API. `kubectl apply` ne met pas à jour l'environnement d'un Pod déjà créé.

Ce qu'un orchestrateur devrait apporter. Un nom stable (un Service dont le DNS ne change pas quand le Pod est recréé) et un volume persistant, pour que les fichiers de PostgreSQL survivent au Pod.

### Supprimer le Pod API ne le recrée pas

Constat. `kubectl delete pod -n taskflow api` laisse uniquement le Pod `db`. Huit secondes plus tard, aucun Pod `api` n'est réapparu. Le nom du Pod ne change pas tout seul : l'objet a disparu.

La boucle de réconciliation présentée en séance 1 compare en continu l'état désiré et l'état observé, puis corrige l'écart. Ici, rien n'enregistre l'état désiré « un Pod API doit exister ». Le manifeste n'est qu'un ordre appliqué une fois.

Ce qu'un orchestrateur devrait apporter. Un contrôleur, typiquement un Deployment, qui maintient le nombre de répliques demandé et recrée un Pod lorsque celui-ci est supprimé.

### `kill 1` redémarre le conteneur, pas le Pod

Constat. `kubectl exec -n taskflow api -- kill 1` fait passer `RESTARTS` de 0 à 1. Le nom du Pod reste `api`, son adresse IP aussi (`10.42.1.6` après la recréation manuelle). Le processus Node est relancé dans le même Pod, et les journaux montrent un nouveau démarrage qui rejoint `10.42.1.5`.

Compose, en séance 1, utilise `restart: unless-stopped`. Cette politique relance aussi le processus d'un conteneur qui s'arrête, tant que le conteneur n'a pas été supprimé. `restartPolicy: Always` sur le Pod est l'équivalent pour la mort du processus. Ni l'une ni l'autre ne recrée l'objet si on le supprime : c'est le rôle du contrôleur, ou de `docker compose up` lancé à nouveau.

Ce qu'un orchestrateur devrait apporter. La politique de redémarrage couvre déjà la mort du processus. Le contrôleur reste nécessaire pour la disparition du Pod.

## Remise en état

Base recréée (`10.42.1.5`), manifeste API mis à jour, Pod API recréé. Les deux Pods sont `Running`. La tâche créée avant la suppression de la base a disparu : `GET /api/tasks` renvoyait `[]`. Un nouvel appel `POST /api/tasks` renvoie 201, et `GET /readyz` renvoie `{"status":"ready","hostname":"api"}`.

## Appliquer les manifestes

`kubectl apply -f k8s/` échoue : `k8s/k3s-config.yaml` est la configuration du binaire k3s, pas un objet de l'API Kubernetes. L'ordre alphabétique peut en plus envoyer les Pods avant que le namespace existe.

Ordre qui fonctionne :

```sh
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/pods/db.yaml
# Attendre « ready to accept connections », relever l'IP, la reporter dans k8s/pods/api.yaml.
kubectl apply -f k8s/pods/api.yaml
```

Le répertoire `k8s/pods/` ne contient que des Pods. La configuration du cluster reste à la racine de `k8s/`, hors de la commande qui applique l'application.

## Pour aller plus loin

Le relais `/api` de Nginx, dans `docker/nginx.conf.template`, appelle `http://api:${API_PORT}`. Le serveur web cherche donc le nom d'hôte `api`. Sans Service de ce nom, le même `ENOTFOUND` que pour `db` empêche le relais de fonctionner sans modification de l'image, ou sans objet Service.

`kubectl get pod -n taskflow api -o yaml` ajoute à l'objet stocké, par rapport au manifeste écrit, notamment : `metadata.uid`, `resourceVersion`, `generation`, `creationTimestamp`, des annotations de `kubectl` ; dans `spec`, `nodeName`, `serviceAccountName: default`, `schedulerName`, `dnsPolicy`, `tolerations`, `terminationGracePeriodSeconds`, `securityContext`, et le volume projeté du compte de service ; tout le bloc `status` (`phase`, `podIP`, `hostIP`, `conditions`, `containerStatuses`, `qosClass: BestEffort`).
