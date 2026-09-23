# firelex - Design : build Firefox custom (Fenix) avec extensions pre-installees

Date : 2026-09-21
Depot : fork de `mozilla-firefox` (branche `main`, synchronisee par merge de `mozilla-firefox:main`)
Cible de build : Fenix (Firefox for Android), artifact mode, APK debug via GitHub Actions

## 1. Objectif

Produire un APK Fenix personnalise dans lequel :

1. uBlock Origin est pre-installe et actif par defaut.
2. L'extension Symfony Bookmarks est pre-installee par defaut.
3. La page de nouvel onglet / page d'accueil affiche le dashboard de l'extension
   Symfony Bookmarks a la place de la home native de Fenix.

Le tout doit survivre aux syncs reguliers du fork (merge upstream) avec un minimum
de conflits, et concentrer 100 % du code custom dans un seul dossier `firelex-patch/`.

## 2. Contraintes constatees dans l'arbre

Deux limitations de Fenix motivent le build custom (verifiees dans le code) :

- **`chrome_url_overrides.newtab` n'est pas honore sur Android.** La surface home de
  Fenix est native (Jetpack Compose), pas une page web. Une extension ne peut donc pas
  remplacer la home via son manifest.
- **L'API WebExtension `bookmarks` n'existe pas sur Android.** Son implementation et son
  schema vivent dans `browser/components/extensions/` (Firefox desktop uniquement). Le
  fichier qui declare les APIs disponibles sur Android,
  `mobile/shared/components/extensions/ext-android.json`, n'expose que `browserAction`,
  `pageAction`, `browsingData`, `tabs`, `geckoViewAddons`.

## 3. Decision de scope

Le dashboard gere **son propre magasin** : il tire ses liens du serveur Symfony via HTTP
(`fetch`) et met en cache via `storage`. Ces deux APIs fonctionnent deja dans une page
d'extension sur Fenix.

Consequence : **l'API `bookmarks` n'est pas requise.** On ne rebranche pas l'API bookmarks
desktop, on ne touche pas au store Places (Rust application-services). La **seule** raison
de builder un Firefox custom est la home page.

Hors scope (pourra faire l'objet d'un projet ulterieur) :
- Miroir des liens Symfony dans les marque-pages natifs de Fenix.
- Re-activation de l'API `bookmarks` sur Android.

## 4. Architecture

Repartition des responsabilites :

- **Extension Symfony Bookmarks** : toute la logique applicative (dashboard, popup, save,
  options), en `fetch` + `storage`. Aucun code applicatif natif Firefox.
- **Patch Firefox** : une seule fonction - router le nouvel onglet / la home vers la page
  dashboard de l'extension.
- **Installation built-in** : uBO et l'extension Symfony sont installees comme extensions
  "built-in" depuis les assets de l'APK. Ce mode contourne la verification de signature AMO
  (donc l'extension non signee s'installe), et rend les extensions non desinstallables par
  l'utilisateur (voulu pour un navigateur "cuit").

### Mecanisme d'installation built-in (existant dans l'arbre)

API : `runtime.installBuiltInWebExtension(id, url, onSuccess, onError)` definie dans
`mobile/android/android-components/.../concept/engine/webextension/WebExtensionRuntime.kt`.

`url` pointe sur `resource://android/assets/extensions/<nom>/` (forme dossier = semantique
built-in garantie).

Reference d'implementation : `WebCompatFeature` installe l'extension webcompat de cette
maniere, et est appelee dans Fenix depuis `Core.kt` lors de la construction de `GeckoEngine`
(appel `WebCompatFeature.install(it)`).

### Resolution de l'URL du dashboard

`moz-extension://<uuid>/` a un UUID aleatoire par profil : impossible a coder en dur. On le
resout au runtime : dans le callback `onSuccess` de l'install built-in de l'extension
Symfony, recuperer `webExtension.getMetadata()?.baseUrl`, construire
`<baseUrl>dashboard.html`, et memoriser cette valeur pour que le routing home la lise.

## 5. Structure du dossier `firelex-patch/`

Tout est committe sur `main`. Ce dossier n'existe pas en amont, donc les merges upstream ne
le touchent jamais.

```
firelex-patch/
  extensions/
    ublock_origin.xpi          # telecharge d'AMO une fois, version epinglee, committe
    symfony_bookmarks.xpi      # build depuis le repo symfony-bookmarks, committe
  overlay/                     # fichiers ADDITIFS, copies tels quels dans l'arbre
    .../fenix/.../SymfonyBuiltInExtensions.kt
  patches/
    Core.kt.patch              # ~2 lignes : import + appel de l'installer
    home-routing.patch         # route new-tab/home vers l'URL dashboard
  apply.sh
  README.md
```

### Composants

- **`extensions/*.xpi`** : artefacts binaires versionnes. Mettre a jour = remplacer le fichier
  et committer. uBO : re-telecharger depuis AMO. Symfony : re-builder dans `symfony-bookmarks`.
- **`overlay/.../SymfonyBuiltInExtensions.kt`** : objet Kotlin calque sur `WebCompatFeature`.
  Expose `install(runtime)` qui appelle `installBuiltInWebExtension` deux fois :
  - uBlock Origin, id `uBlock0@raymondhill.net`, url `resource://android/assets/extensions/ublock/`
  - Symfony Bookmarks, id `sfbookmarks-sync@aleblanc`, url `resource://android/assets/extensions/symfony-bookmarks/`
  Dans le `onSuccess` de l'extension Symfony, memorise `<baseUrl>dashboard.html`.
  Fichier neuf => additif => pas de conflit de merge.
- **`patches/Core.kt.patch`** : ajoute l'import et l'appel `SymfonyBuiltInExtensions.install(it)`
  a cote de `WebCompatFeature.install(it)`. Zone quasi-stable.
- **`patches/home-routing.patch`** : fait charger l'URL dashboard memorisee quand un nouvel
  onglet / la home est ouvert, au lieu de la home native. **Seul patch touchant une zone
  Fenix qui bouge entre versions** ; c'est le point de maintenance principal.

### `apply.sh`

Execute en CI apres le checkout, avant `mach build`. Etapes :

1. Copier `overlay/*` dans la racine du repo (depose le `.kt`).
2. Pour chaque `extensions/*.xpi` : dezipper dans
   `mobile/android/fenix/app/src/main/assets/extensions/<nom>/`.
   Mapping des noms : `ublock_origin.xpi` -> `ublock/`, `symfony_bookmarks.xpi` -> `symfony-bookmarks/`.
3. Appliquer chaque `patches/*.patch`. Toute application en echec (reject) doit faire
   echouer le script bruyamment (exit non nul) pour signaler un besoin de rebase.

Les fichiers generes (overlay copie, assets dezippes) ne sont **jamais** committes : la CI
part d'un checkout frais et les regenere a chaque run. `main` reste vierge cote arbre Firefox.

## 6. Wiring CI

Ajout d'une etape dans `.github/workflows/build-fenix.yml`, apres le checkout et avant
`mach build` :

```yaml
- name: Apply firelex-patch
  run: ./firelex-patch/apply.sh
```

Le reste du workflow (bootstrap artifact mode, `mach configure`, `mach artifact install`,
`mach build`, `mach gradle fenix:assembleDebug`, upload APK) est inchange.

## 7. Workflow de maintenance

- **Sync fork** : `merge mozilla-firefox:main` -> touche l'arbre Firefox, jamais
  `firelex-patch/`. Si `home-routing.patch` ne s'applique plus, `apply.sh` echoue en CI ->
  rebaser ce patch.
- **Modifier l'extension** : re-builder le XPI dans `symfony-bookmarks`, remplacer
  `firelex-patch/extensions/symfony_bookmarks.xpi`, committer.
- **Mettre a jour uBO** : re-telecharger le XPI, remplacer, committer.

## 8. Validation / tests

A verifier sur l'APK produit :

1. uBO present et actif (blocage effectif sur une page de test).
2. Extension Symfony presente.
3. Nouvel onglet / home = dashboard Symfony, avec liens charges depuis le serveur.
4. `apply.sh` echoue proprement si un patch ne s'applique pas (test en cassant volontairement
   un patch).

Le repo Fenix bouge vite et la sortie de recherche shell locale est peu fiable : pinner les
points d'accroche exacts (`Core.kt`, logique new-tab/home) avec les outils moz
(`searchfox-cli`) au moment de l'implementation.

## 9. Nettoyage cote extension (hors build, repo symfony-bookmarks)

Retirer la permission et les appels `bookmarks` du manifest/scripts : l'API est `undefined`
sur Android et provoquerait des erreurs. Tache mineure, independante du build custom.

## 10. Risques

- **`home-routing.patch` fragile aux versions.** Attenue par : patch isole, echec bruyant en
  CI, logique de resolution d'URL deportee dans un fichier overlay additif (moins de surface
  dans le patch lui-meme).
- **Comportement exact du routing new-tab a confirmer** (interception `about:home` vs use case
  de creation d'onglet) : a pinner a l'implementation.
- **Timing de la resolution baseUrl** : le routing doit gerer le cas ou l'install n'est pas
  encore terminee au premier onglet (fallback vers home native tant que l'URL n'est pas prete).
