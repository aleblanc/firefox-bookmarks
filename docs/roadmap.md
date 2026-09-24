# Roadmap

## 1. Passer le build en `assembleRelease` (quand le projet sera stable)

### Constat

La source est deja stable : la CI checkout `mozilla-firefox/firefox@release` (Firefox 157
stable, moteur GeckoView inclus). En revanche la coque Android est buildee avec le build type
**debug** (`mach gradle fenix:assembleDebug`), herite du premier workflow de preuve de concept et
fige ensuite comme contrainte dans `PLAN.md` sans avoir ete rediscute.

Consequences du build type debug, toutes independantes du code stable :

- `android:debuggable=true` (lecture des donnees de l'app via `adb run-as`, debogueur attachable).
- LeakCanary embarque et actif par defaut (heap dumps, pics memoire).
- StrictMode avec `penaltyDeath` : le process est tue sur toute I/O disque/reseau sur le main
  thread, y compris du code constructeur (Samsung, Xiaomi...).
- `versionCode 1`, `versionName 1.0.yyww`.
- Code non minifie (pas de R8), APK plus gros et plus lent.

Les correctifs actuels (`-PdisableLeakCanary`, `strictmode-no-penalty-death.patch`,
`fenix-debug-versioning.patch`) sont des rustines sur ce build type. Le build `release`
les rend tous inutiles.

### Cible

`mach gradle fenix:assembleRelease -PbenchmarkTest -PversionName=<version.txt>` sur la meme
source `release`, signe avec le meme keystore (hors automation Mozilla, le build type release
utilise `signingConfigs.debug`, donc `$ANDROID_USER_HOME/debug.keystore`).

### Implications a trancher avant de migrer

1. **Package Android.** `release` donne `applicationIdSuffix ".firefox"` -> `org.mozilla.firefox`,
   le meme que le Firefox du Play Store. Les deux ne peuvent pas cohabiter et la signature
   differe. Deux options :
   - patcher `applicationIdSuffix` en `.firelex` (recommande : package a nous, cohabitation
     possible, pas de collision avec une future installation du Firefox officiel) ;
   - garder `org.mozilla.firefox` et desinstaller le Firefox officiel du telephone.
2. **Reinstallation complete.** Nouveau package ou nouveau build type = nouvelle app pour
   Android. Le profil actuel (`org.mozilla.fenix.debug`) n'est pas migre : onglets, historique,
   logins locaux sont perdus sauf s'ils sont synchronises via Firefox Sync. A faire une fois,
   volontairement.
3. **Telemetrie.** Hors debug, `TELEMETRY` et `CRASH_REPORTING` valent `true` dans
   `defaultConfig`. Glean enverrait des pings a Mozilla depuis un fork : a forcer a `false`
   par patch. Sentry/Adjust/Nimbus sont deja inertes (tokens absents).
4. **Fonctions reservees aux canaux Nightly/Debug** qui disparaissent en release :
   `about:config`, installation d'extensions non signees depuis un fichier, secret settings.
   Les extensions built-in (uBlock, Symfony Bookmarks) ne sont pas concernees :
   `installBuiltInWebExtension` contourne la verification de signature quel que soit le canal.
5. **R8 sur le runner gratuit.** La minification allonge le build et consomme de la memoire
   (`org.gradle.jvmargs=-Xmx7g` upstream). Repli upstream : `-PdisableOptimization`
   (release non minifie, toujours sans outils de dev). Surveiller `timeout-minutes: 120`.
6. **Artifact mode + variante release.** Le projet `:fenix` release consomme la variante release
   de `:geckoview` (`matchingFallbacks = ['release']`). Non verifie en artifact mode dans ce
   workflow : le premier run manuel sert de test.
7. **Extension Symfony Bookmarks.** Verifier que sa banniere de mise a jour ne depend pas du
   `versionName` actuel (`1.0.xxxx`), qui deviendra `157.0`.

### Fichiers a modifier

| Fichier | Action |
|---|---|
| `.github/workflows/build-fenix.yml` | `assembleDebug` -> `assembleRelease`, ajouter `-PversionName=$(cat mobile/android/version.txt)`, retirer `-PdisableLeakCanary`. Renommer l'artefact `fenix-debug-apk`. Adapter le corps de la release ("Debug-signed APK"). Le glob `outputs/apk/**/*.apk` couvre deja `apk/release/`. Garder `ANDROID_USER_HOME`, la copie du keystore et l'etape "Verify APK signature and version" (meme empreinte attendue ; ajuster le package affiche par `aapt2`). Optionnel : `-PdisableOptimization` en repli. |
| `firelex-patch/patches/fenix-debug-versioning.patch` | Supprimer. Le release utilise `Config.generateFennecVersionCode` (croissant, base sur la date) et `-PversionName`. |
| `firelex-patch/patches/strictmode-no-penalty-death.patch` | Supprimer. `StrictModeManager` est construit avec `Config.channel.isDebug`, donc no-op en release. |
| `firelex-patch/patches/<nouveau> release-application-id.patch` | Dans `mobile/android/fenix/app/build.gradle`, bloc `buildTypes.release` : `applicationIdSuffix ".firefox"` -> `".firelex"`. Retirer ou laisser le placeholder `sharedUserId` (inutile sur un package a nous). |
| `firelex-patch/patches/<nouveau> no-telemetry.patch` | Dans `mobile/android/fenix/app/build.gradle`, bloc `android.defaultConfig.with { ... }` : `TELEMETRY` et `CRASH_REPORTING` -> `false`. |
| `firelex-patch/overlay/.../app/src/debug/res/drawable/ic_launcher_foreground.xml` | Deplacer vers `src/release/res/drawable/` (emplacement d'origine avant le commit `9dd2a3c`). |
| `firelex-patch/overlay/.../app/src/debug/res/drawable-nodpi/firelex_launcher.png` | Deplacer vers `src/release/res/drawable-nodpi/`. |
| `firelex-patch/overlay/.../app/src/debug/res/values/firelex_strings.xml` | Supprimer. En release, `app_name` est defini par upstream dans `src/release/res/values/static_strings.xml` : reintroduire le patch `app-name.patch` (supprime dans `9dd2a3c`) qui remplace `Firefox` par `Firefox Bookmarks`. |
| `firelex-patch/README.md` | Mettre a jour la liste des patches, la section "Stabilite du build debug" (a supprimer) et la section signature. |
| `README.md` | Remplacer les mentions `fenix-debug-apk` / APK debug. |
| `DESIGN.md`, `PLAN.md` | Remplacer la contrainte `mach gradle fenix:assembleDebug` par `assembleRelease` et noter la decision. |
| `firelex-patch/patches/Core.kt.patch`, `home-routing.patch`, overlay `SymfonyBuiltInExtensions.kt` | Aucun changement : code dans `src/main`, independant du build type. |

### Ordre de migration propose

1. Ajouter `release-application-id.patch` et `no-telemetry.patch`, reintroduire `app-name.patch`,
   deplacer les ressources vers `src/release/res`. Verifier chaque patch avec `git apply --check`
   sur l'arbre `release` courant.
2. Basculer le workflow (`assembleRelease`, `-PversionName`, artefact, verification).
3. Run manuel (`workflow_dispatch`). Lire dans le log : temps de la tache R8, package et
   `versionCode` affiches par `aapt2`, empreinte du certificat. Si R8 echoue (OOM/timeout),
   ajouter `-PdisableOptimization` et relancer.
4. Installer l'APK, verifier : uBlock actif, dashboard Symfony en home, mise a jour possible
   par-dessus lors du build suivant (meme package, meme cle, `versionCode` superieur).
5. Supprimer les deux patches debug et `-PdisableLeakCanary`, mettre a jour les docs.

### Verification finale

- `aapt2 dump badging` : `package: name='org.mozilla.firelex'` (ou `org.mozilla.firefox`),
  `versionName='157.x'`, pas d'attribut `application-debuggable`.
- `apksigner verify --print-certs` : empreinte `3D:FC:4D:03:...:76:4B`.
- `adb logcat -d -b crash` vide apres une journee d'usage.

## 2. Sortir le keystore du depot (independant du build type)

Le depot est public et `firelex-patch/debug.keystore` est committe. N'importe qui peut donc
produire un APK qui s'installe comme mise a jour de l'application (meme package, meme cle) avec
acces a tout le profil, s'il parvient a le faire installer.

- Encoder le keystore en base64 dans un secret GitHub (`FIRELEX_KEYSTORE_B64`), le decoder dans
  l'etape "Use a stable debug keystore", supprimer le fichier du depot et le purger de
  l'historique si on veut aller au bout (la cle actuelle reste connue publiquement sinon).
- Si la cle est regeneree : une desinstallation manuelle unique sur le telephone, comme lors du
  correctif de signature. Mettre a jour `FIRELEX_KEY_SHA256` dans le workflow.
- Les APK deja publies restent installables ; seule la chaine de mise a jour change de cle.
