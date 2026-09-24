# firelex-patch

Customisations appliquees par-dessus le fork `mozilla-firefox` pour produire un APK Fenix
avec uBlock Origin et l'extension Symfony Bookmarks pre-installees, et la home / nouvel
onglet affichant le dashboard de l'extension.

Tout le code custom vit ici. Ce dossier n'existe pas en amont : les syncs du fork
(`merge mozilla-firefox:main`) ne le touchent jamais. Rien de ce que `apply.sh` injecte dans
l'arbre Firefox n'est committe ; la CI part d'un checkout frais et regenere tout a chaque run.

Voir `DESIGN.md` (architecture) et `PLAN.md` (plan d'implementation).

## Contenu

```
extensions/
  ublock_origin.xpi        # uBlock Origin, telecharge d'AMO, version epinglee
  symfony_bookmarks.xpi    # extension Symfony, buildee depuis le repo symfony-bookmarks
overlay/                   # fichiers ADDITIFS, copies tels quels dans l'arbre
  .../components/SymfonyBuiltInExtensions.kt
patches/                   # patches appliques sur des fichiers upstream
  Core.kt.patch            # appelle l'installer built-in
  home-routing.patch       # route la home vers le dashboard
  fenix-debug-versioning.patch  # versionCode/versionName du build debug derives de version.txt
debug.keystore             # cle de signature stable (alias androiddebugkey / android), voir CI
apply.sh                   # orchestre l'injection (lance en CI avant `mach build`)
```

## apply.sh

Lance depuis la racine du repo (ou par la CI), il :

1. copie `overlay/*` dans l'arbre ;
2. dezippe chaque `extensions/*.xpi` dans
   `mobile/android/fenix/app/src/main/assets/extensions/<nom>/`
   (`ublock_origin.xpi` -> `ublock/`, `symfony_bookmarks.xpi` -> `symfony-bookmarks/`) ;
3. applique chaque `patches/*.patch`.

Toute application de patch en echec fait sortir le script en erreur (exit non nul) : c'est
le signal qu'un patch doit etre rebase apres un sync upstream.

## Maintenance

- **Sync du fork** : `merge mozilla-firefox:main`. Ne touche jamais `firelex-patch/`. Si
  `home-routing.patch` ne s'applique plus, `apply.sh` echoue en CI -> rebaser ce patch.
- **Mettre a jour l'extension Symfony** : re-builder le XPI dans `symfony-bookmarks`
  (`web-ext build`), remplacer `extensions/symfony_bookmarks.xpi`, committer.
- **Mettre a jour uBlock Origin** : re-telecharger le XPI depuis AMO, remplacer, committer.
- **Signature / mise a jour de l'APK** : la CI copie `debug.keystore` dans `$ANDROID_USER_HOME`
  (variable definie au niveau du job) ; sans elle AGP 9 prefere `$XDG_CONFIG_HOME/.android`
  (cree par `sdkmanager` lors du bootstrap) et genere une cle jetable. Le workflow verifie
  l'empreinte SHA-256 du certificat de l'APK apres le build et echoue si elle differe.
  `fenix-debug-versioning.patch` donne au build debug un `versionCode` croissant
  (`157.0.2` -> `157000002`) et `versionName = 157.0.2`, sinon upstream laisse `1`.
