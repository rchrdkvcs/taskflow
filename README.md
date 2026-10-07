# TaskFlow

Application web de gestion de tâches, utilisée comme projet fil rouge du module « Clusterisation de conteneurs ».

Ce dépôt contient le **code source** de l'application et sa configuration Docker pour construire et lancer toute la stack.

## Exécution avec Docker Compose

Prérequis : Docker avec Docker Compose.

```sh
cp .env.example .env
# Modifier DB_PASSWORD dans .env avant le premier lancement.
docker compose up --build -d --wait
```

L'application est accessible sur `http://localhost:8080` (port configurable avec `FRONT_PORT`). Nginx sert le front compilé, prend en charge le routage Vue et relaie `/api/...` vers l'API. L'API et PostgreSQL sont accessibles uniquement sur le réseau Compose. Le Dockerfile utilise les cibles `api` et `front` ; l'API démarre après le contrôle de santé PostgreSQL, puis le front après celui de l'API.

Les variables sont documentées dans [`.env.example`](.env.example). Les données PostgreSQL 18 sont conservées dans le volume `postgres_data`, monté sur `/var/lib/postgresql`, après un arrêt ou une reconstruction. Les identifiants de la base sont définis à la première initialisation du volume.

```sh
docker compose logs -f       # Journaux de la stack
docker compose down          # Arrêt, sans supprimer les données
```

Pour supprimer également toutes les données PostgreSQL, utiliser `docker compose down -v`.

---

## Architecture

```
navigateur ──HTTP──► front (fichiers statiques Vue.js)
    │
    └── /api/... ──► api (Node.js, Express) ──SQL──► PostgreSQL
```

| Composant | Répertoire | Technologie | Rôle |
|---|---|---|---|
| front | `front/` | Vue.js 3, Vite | Interface web. Compilée en fichiers statiques, à servir par un serveur web. |
| api | `api/` | Node.js 24, Express 5 | API REST de gestion des tâches. Crée le schéma de la base au démarrage. |
| base de données | — | PostgreSQL 18 | Stockage des tâches. Aucun code spécifique dans ce dépôt. |

## Structure du dépôt

```
.
├── api/
│   ├── package.json, package-lock.json
│   └── src/
│       ├── server.js        point d'entrée : démarrage, arrêt propre
│       ├── app.js           application Express, routes techniques
│       ├── config.js        lecture des variables d'environnement
│       ├── db.js            connexion PostgreSQL, création du schéma
│       ├── logger.js        journalisation
│       └── routes/tasks.js  ressource /api/tasks
├── docs/
│   └── notes-kubernetes.md  constats de la première mise en Pods
├── k8s/
│   ├── k3s-config.yaml      configuration du serveur k3s, pas un manifeste
│   ├── namespace.yaml
│   └── pods/
│       ├── api.yaml
│       └── db.yaml
└── front/
    ├── package.json, package-lock.json
    ├── index.html
    ├── vite.config.js
    ├── public/
    └── src/
```

---

## API

### Démarrage

| Étape | Commande (dans `api/`) |
|---|---|
| Installation des dépendances de production | `npm ci --omit=dev` |
| Démarrage | `npm start` (équivalent à `node src/server.js`) |
| Démarrage en développement, avec rechargement automatique | `npm run dev` |

L'API n'a pas d'étape de compilation.

Au démarrage, l'API :
1. tente de se connecter à PostgreSQL, en plusieurs tentatives espacées (voir `DB_CONNECT_RETRIES`) ;
2. crée la table `tasks` si elle n'existe pas. L'opération est idempotente et peut être exécutée simultanément par plusieurs instances ;
3. commence à écouter les requêtes HTTP.

Si la base reste injoignable après toutes les tentatives, le processus s'arrête avec le code de sortie 1.

### Configuration

Toute la configuration passe par des variables d'environnement.

| Variable | Défaut | Description |
|---|---|---|
| `HOST` | `0.0.0.0` | Interface d'écoute du serveur HTTP |
| `PORT` | `3000` | Port d'écoute du serveur HTTP |
| `APP_ENV` | `development` | Nom de l'environnement, renvoyé par `/api/info` |
| `DB_HOST` | `localhost` | Hôte PostgreSQL |
| `DB_PORT` | `5432` | Port PostgreSQL |
| `DB_NAME` | `taskflow` | Nom de la base |
| `DB_USER` | `taskflow` | Utilisateur PostgreSQL |
| `DB_PASSWORD` | *(vide)* | Mot de passe PostgreSQL |
| `DB_PASSWORD_FILE` | *(non défini)* | Chemin d'un fichier contenant le mot de passe. Prioritaire sur `DB_PASSWORD`. |
| `DB_CONNECT_RETRIES` | `5` | Nombre de nouvelles tentatives de connexion au démarrage |
| `DB_CONNECT_INTERVAL_MS` | `2000` | Délai entre deux tentatives, en millisecondes |
| `STRESS_MAX_MS` | `5000` | Durée maximale de calcul acceptée par `/api/stress` |
| `SHUTDOWN_TIMEOUT_MS` | `8000` | Délai maximal accordé à l'arrêt propre avant arrêt forcé |

### Routes techniques

| Route | Usage | Réponse |
|---|---|---|
| `GET /healthz` | Vivacité : le processus répond. **Ne consulte pas** la base de données. | `200` `{"status":"ok","version":"1.0.0","hostname":"..."}` |
| `GET /readyz` | Disponibilité : la base est joignable et aucun arrêt n'est en cours | `200` `{"status":"ready",...}` ou `503` |
| `GET /api/info` | Informations sur l'instance | `200` `{"name","version","env","hostname","uptimeSeconds"}` |
| `GET /api/stress?ms=500` | Génère une charge CPU pendant `ms` millisecondes (500 par défaut, plafonnée à `STRESS_MAX_MS`). L'instance continue de répondre aux autres requêtes pendant le calcul. | `200` `{"hostname","requestedMs","burnedMs"}` |

### Ressource `/api/tasks`

Une tâche a la forme suivante :

```json
{
  "id": 1,
  "title": "Rédiger le README",
  "done": false,
  "createdAt": "2026-10-05T08:30:00.000Z",
  "updatedAt": "2026-10-05T08:30:00.000Z"
}
```

| Méthode et chemin | Corps de requête | Réponse |
|---|---|---|
| `GET /api/tasks` | — | `200`, liste des tâches, les plus récentes en premier |
| `POST /api/tasks` | `{"title": "..."}` (1 à 200 caractères) | `201`, tâche créée |
| `GET /api/tasks/{id}` | — | `200`, ou `404` |
| `PATCH /api/tasks/{id}` | `{"title"?: "...", "done"?: true}` | `200`, tâche modifiée, ou `404` |
| `DELETE /api/tasks/{id}` | — | `204`, ou `404` |

Les erreurs sont renvoyées au format `{"error": "message"}`, avec le code `400` pour une requête invalide, `404` pour une ressource inexistante et `500` pour une erreur interne.

Exemples :

```sh
curl -s http://localhost:3000/api/tasks
curl -s -X POST http://localhost:3000/api/tasks \
     -H 'Content-Type: application/json' -d '{"title": "Première tâche"}'
curl -s -X PATCH http://localhost:3000/api/tasks/1 \
     -H 'Content-Type: application/json' -d '{"done": true}'
curl -s -X DELETE http://localhost:3000/api/tasks/1
```

### Comportements utiles à l'exploitation

- **Identification de l'instance** : chaque réponse porte un en-tête `X-Served-By` qui contient le nom d'hôte de l'instance qui l'a traitée.
- **Journaux** : une ligne par événement sur la sortie standard (les erreurs sur la sortie d'erreur), préfixée par la date, le niveau et le nom d'hôte. Chaque requête est journalisée, sauf `/healthz` et `/readyz`.
- **Arrêt propre** : à la réception de `SIGTERM` ou de `SIGINT`, l'API cesse d'accepter de nouvelles connexions et termine les requêtes en cours. `/readyz` renvoie alors `503`. L'API ferme ensuite ses connexions à la base, puis s'arrête avec le code 0. Si l'arrêt dépasse `SHUTDOWN_TIMEOUT_MS`, le processus s'arrête avec le code 1.
- **Version** : la version renvoyée par `/healthz` et `/api/info` est celle du champ `version` de `api/package.json`.

---

## Front

### Construction

| Étape | Commande (dans `front/`) |
|---|---|
| Installation des dépendances (y compris de développement) | `npm ci` |
| Compilation | `npm run build` |
| Serveur de développement | `npm run dev` |

La compilation produit des fichiers statiques dans `front/dist/` : `index.html`, des fichiers JavaScript et CSS, et les ressources de `public/`. Ces fichiers suffisent à l'exécution. Ni Node.js ni les dépendances npm ne sont nécessaires pour les servir.

### Contraintes pour le serveur web

- **Appels à l'API** : le front appelle l'API par des chemins relatifs (`/api/...`). Ces requêtes sont envoyées au serveur qui a servi la page. Ce serveur doit donc les relayer vers l'API, en conservant le préfixe `/api`.
- **Routage côté client** : le front utilise le mode *history* de Vue Router (URL sans `#`, par exemple `/a-propos`). Le serveur web doit renvoyer `index.html` pour tout chemin qui ne correspond pas à un fichier existant. Sinon, le rechargement d'une page autre que l'accueil aboutit à une erreur 404.
- **Configuration** : le front ne lit aucune variable d'environnement, ni à la compilation ni à l'exécution. Les fichiers compilés sont identiques quel que soit l'environnement de déploiement.
- Le pied de page affiche le nom de l'instance d'API qui a traité la dernière requête (en-tête `X-Served-By`).

### Serveur de développement

`npm run dev` démarre le serveur de développement de Vite (port 5173 par défaut). Il relaie les appels `/api` vers l'adresse définie par la variable `API_PROXY_TARGET` (par défaut `http://localhost:3000`). Cette variable ne concerne que le serveur de développement : elle n'a aucun effet sur le résultat de `npm run build`.

---

## Exécution locale sans conteneur

Prérequis : Node.js 24 et une instance PostgreSQL accessible, avec une base et un utilisateur dédiés.

```sh
# Terminal 1 : API
cd api
npm ci
DB_HOST=localhost DB_PASSWORD=<mot de passe> npm run dev

# Terminal 2 : front
cd front
npm ci
npm run dev
```

L'application est alors accessible sur `http://localhost:5173`.

---

## Kubernetes — premiers Pods

Les manifestes de la séance 4 décrivent un namespace `taskflow`, un Pod PostgreSQL et un Pod API. Il n'y a pas encore de Service, de volume ni de contrôleur. L'API joint la base par l'adresse IP du Pod `db`, écrite dans [`k8s/pods/api.yaml`](k8s/pods/api.yaml). Cette adresse change à chaque recréation du Pod. Le mot de passe dans les manifestes est un mot de passe de test.

```sh
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/pods/db.yaml
# Relever l'IP du Pod db, la reporter dans k8s/pods/api.yaml, puis :
kubectl apply -f k8s/pods/api.yaml
kubectl port-forward -n taskflow pod/api 3000:3000
```

`kubectl apply -f k8s/` ne convient pas : [`k8s/k3s-config.yaml`](k8s/k3s-config.yaml) est la configuration du binaire k3s. Les limites observées (IP, données, absence de recréation) sont dans [`docs/notes-kubernetes.md`](docs/notes-kubernetes.md). Le front n'est pas déployé à ce stade.
