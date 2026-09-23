# firelex - Plan d'implementation : Firefox custom avec extensions pre-installees

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produire un APK Fenix custom avec uBlock Origin + l'extension Symfony Bookmarks pre-installees, et la home / nouvel onglet affichant le dashboard de l'extension.

**Architecture:** Tout le custom vit dans `firelex-patch/` (additif, hors arbre upstream). Un script `apply.sh` tourne en CI avant `mach build` : il copie un fichier overlay Kotlin, dezippe les XPI dans les assets Fenix, et applique 2 patches. Les extensions sont installees en "built-in" (contourne la signature AMO). La home est routee vers l'URL dashboard de l'extension, resolue au runtime via `Metadata.baseUrl`.

**Tech Stack:** Firefox/Fenix (Gradle, Kotlin, android-components, GeckoView), GitHub Actions, bash, WebExtension (XPI).

**Spec:** `firelex-patch/DESIGN.md`

## Global Constraints

- Aucune modification committee dans l'arbre Firefox : 100 % du custom dans `firelex-patch/`. Les fichiers injectes par `apply.sh` (overlay copie, assets dezippes) ne sont jamais committes.
- Style Firefox : pas d'emoji dans le code ni les commentaires ; commentaires au strict minimum.
- Build cible : `mach gradle fenix:assembleDebug`, artifact mode (pas de compilation C++).
- ID extensions : uBlock Origin = `uBlock0@raymondhill.net` ; Symfony Bookmarks = `sfbookmarks-sync@aleblanc`.
- URLs assets built-in : uBO = `resource://android/assets/extensions/ublock/` ; Symfony = `resource://android/assets/extensions/symfony-bookmarks/`.
- Les patches s'auteurent par edit reel dans l'arbre puis `git diff > patch` puis revert : ne jamais ecrire un diff a la main (numeros de ligne non fiables).
- Repo qui bouge vite : pinner les points d'accroche avec `searchfox-cli` avant d'editer.

---

### Task 1: Acquerir et committer les deux XPI

**Files:**
- Create: `firelex-patch/extensions/ublock_origin.xpi`
- Create: `firelex-patch/extensions/symfony_bookmarks.xpi`

**Interfaces:**
- Produces: deux fichiers XPI dont `apply.sh` (Task 3) attend les noms exacts `ublock_origin.xpi` et `symfony_bookmarks.xpi`.

- [ ] **Step 1: Recuperer l'XPI uBlock Origin depuis AMO (version epinglee)**

```bash
mkdir -p firelex-patch/extensions
# Recupere l'URL de l'XPI courant depuis l'API AMO, puis telecharge.
curl -sL "https://addons.mozilla.org/api/v5/addons/addon/ublock-origin/" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['current_version']['file']['url'])" \
  | xargs curl -sL -o firelex-patch/extensions/ublock_origin.xpi
```

- [ ] **Step 2: Verifier l'XPI uBO (id attendu)**

Run:
```bash
unzip -p firelex-patch/extensions/ublock_origin.xpi manifest.json \
  | python3 -c "import sys,json; m=json.load(sys.stdin); print(m['browser_specific_settings']['gecko']['id'])"
```
Expected: `uBlock0@raymondhill.net`

- [ ] **Step 3: Builder l'XPI de l'extension Symfony et le copier**

Run (depuis le repo `symfony-bookmarks`, cote extension) :
```bash
cd ../symfony-bookmarks/extension
npx web-ext build --overwrite-dest
cp web-ext-artifacts/*.zip /tmp/symfony_bookmarks.xpi 2>/dev/null || cp web-ext-artifacts/*.xpi /tmp/symfony_bookmarks.xpi
```
Puis copier dans firelex :
```bash
cp /tmp/symfony_bookmarks.xpi <firelex>/firelex-patch/extensions/symfony_bookmarks.xpi
```

- [ ] **Step 4: Verifier l'XPI Symfony (id attendu)**

Run:
```bash
unzip -p firelex-patch/extensions/symfony_bookmarks.xpi manifest.json \
  | python3 -c "import sys,json; m=json.load(sys.stdin); print(m['browser_specific_settings']['gecko']['id'])"
```
Expected: `sfbookmarks-sync@aleblanc`

- [ ] **Step 5: Committer**

```bash
git add firelex-patch/extensions/ublock_origin.xpi firelex-patch/extensions/symfony_bookmarks.xpi
git commit -m "firelex-patch: bundle uBlock Origin and Symfony Bookmarks XPIs"
```

---

### Task 2: Ecrire l'overlay installer built-in

**Files:**
- Create: `firelex-patch/overlay/mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/SymfonyBuiltInExtensions.kt`

**Interfaces:**
- Consumes: `mozilla.components.concept.engine.webextension.WebExtensionRuntime.installBuiltInWebExtension(id, url, onSuccess, onError)` ; `WebExtension.getMetadata()?.baseUrl` (confirme dans `concept/engine/.../WebExtension.kt`, `Metadata.baseUrl: String`).
- Produces: `object SymfonyBuiltInExtensions` avec `fun install(runtime: WebExtensionRuntime)` et `val dashboardUrl: String?` (lu par Task 5) ; appele depuis `Core.kt` par Task 4.

- [ ] **Step 1: Ecrire le fichier overlay**

```kotlin
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

package org.mozilla.fenix.components

import mozilla.components.concept.engine.webextension.WebExtensionRuntime
import mozilla.components.support.base.log.logger.Logger

object SymfonyBuiltInExtensions {
    private val logger = Logger("firelex-builtin")

    private const val UBLOCK_ID = "uBlock0@raymondhill.net"
    private const val UBLOCK_URL = "resource://android/assets/extensions/ublock/"

    private const val SYMFONY_ID = "sfbookmarks-sync@aleblanc"
    private const val SYMFONY_URL = "resource://android/assets/extensions/symfony-bookmarks/"
    private const val DASHBOARD_PAGE = "dashboard.html"

    /** moz-extension:// URL of the Symfony dashboard, resolved once the extension is installed. */
    @Volatile
    var dashboardUrl: String? = null
        private set

    fun install(runtime: WebExtensionRuntime) {
        runtime.installBuiltInWebExtension(
            UBLOCK_ID,
            UBLOCK_URL,
            onSuccess = { logger.debug("Installed uBlock Origin: ${it.id}") },
            onError = { throwable -> logger.error("Failed to install uBlock Origin", throwable) },
        )
        runtime.installBuiltInWebExtension(
            SYMFONY_ID,
            SYMFONY_URL,
            onSuccess = { extension ->
                val base = extension.getMetadata()?.baseUrl
                if (base != null) {
                    dashboardUrl = base + DASHBOARD_PAGE
                    logger.debug("Symfony dashboard resolved at $dashboardUrl")
                } else {
                    logger.error("Symfony extension installed but baseUrl is null")
                }
            },
            onError = { throwable -> logger.error("Failed to install Symfony Bookmarks", throwable) },
        )
    }
}
```

- [ ] **Step 2: Verifier la coherence des imports avec la reference**

Run:
```bash
grep -n "import mozilla.components" \
  mobile/android/android-components/components/feature/webcompat/src/main/java/mozilla/components/feature/webcompat/WebCompatFeature.kt
```
Expected: confirme que `WebExtensionRuntime` et `Logger` s'importent bien depuis ces packages (memes imports que l'overlay). Corriger l'overlay si divergence.

- [ ] **Step 3: Committer**

```bash
git add firelex-patch/overlay/
git commit -m "firelex-patch: add built-in extensions installer overlay"
```

---

### Task 3: Ecrire apply.sh

**Files:**
- Create: `firelex-patch/apply.sh`

**Interfaces:**
- Consumes: `firelex-patch/extensions/*.xpi` (Task 1), `firelex-patch/overlay/` (Task 2), `firelex-patch/patches/*.patch` (Tasks 4-5).
- Produces: script idempotent lance en CI (Task 6). Sortie non nulle si un patch echoue.

- [ ] **Step 1: Ecrire le script**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/firelex-patch"
ASSETS_DIR="$REPO_ROOT/mobile/android/fenix/app/src/main/assets/extensions"

echo "[firelex-patch] Copying overlay files into the tree..."
cp -Rv "$PATCH_DIR/overlay/." "$REPO_ROOT/"

echo "[firelex-patch] Unpacking bundled extensions into assets..."
declare -A EXT_MAP=(
  ["ublock_origin.xpi"]="ublock"
  ["symfony_bookmarks.xpi"]="symfony-bookmarks"
)
for xpi in "${!EXT_MAP[@]}"; do
  dest="$ASSETS_DIR/${EXT_MAP[$xpi]}"
  rm -rf "$dest"
  mkdir -p "$dest"
  unzip -o -q "$PATCH_DIR/extensions/$xpi" -d "$dest"
  test -f "$dest/manifest.json" || { echo "ERROR: manifest.json missing in $dest"; exit 1; }
done

echo "[firelex-patch] Applying source patches..."
shopt -s nullglob
for patch in "$PATCH_DIR"/patches/*.patch; do
  echo "  -> applying $(basename "$patch")"
  git -C "$REPO_ROOT" apply --verbose "$patch"
done

echo "[firelex-patch] Done."
```

- [ ] **Step 2: Rendre executable**

```bash
chmod +x firelex-patch/apply.sh
```

- [ ] **Step 3: Test partiel (overlay + dezippage, sans patches)**

Les patches n'existent pas encore (Tasks 4-5) : verifier que la partie assets/overlay fonctionne. Le dossier `patches/` vide fait que la boucle (avec `nullglob`) ne tourne pas.
Run:
```bash
mkdir -p firelex-patch/patches
./firelex-patch/apply.sh
ls mobile/android/fenix/app/src/main/assets/extensions/ublock/manifest.json
ls mobile/android/fenix/app/src/main/assets/extensions/symfony-bookmarks/manifest.json
ls mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/SymfonyBuiltInExtensions.kt
```
Expected: les trois `ls` reussissent.

- [ ] **Step 4: Nettoyer les fichiers generes (ne pas les committer)**

```bash
git -C . checkout -- mobile/ 2>/dev/null || true
git clean -fd mobile/android/fenix/app/src/main/assets/extensions/ublock mobile/android/fenix/app/src/main/assets/extensions/symfony-bookmarks
rm -f mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/SymfonyBuiltInExtensions.kt
```
Verifier : `git status` ne montre que `firelex-patch/` en modifications.

- [ ] **Step 5: Ignorer les artefacts generes**

Ajouter a `firelex-patch/.gitignore` (pour usage local) une note ; les chemins generes vivent hors `firelex-patch/` donc deja ignores de fait en CI (checkout frais). Creer `firelex-patch/README.md` minimal documentant `apply.sh` et le workflow de sync (contenu depuis `DESIGN.md` sections 5-7).

- [ ] **Step 6: Committer**

```bash
git add firelex-patch/apply.sh firelex-patch/README.md
git commit -m "firelex-patch: add apply.sh and README"
```

---

### Task 4: Creer Core.kt.patch (appel de l'installer)

**Files:**
- Create: `firelex-patch/patches/Core.kt.patch`
- Reference (non committe): `mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/Core.kt`

**Interfaces:**
- Consumes: `SymfonyBuiltInExtensions.install(it)` (Task 2).
- Produces: patch qui ajoute un import + un appel a cote de `WebCompatFeature.install(it)`.

- [ ] **Step 1: Pinner le point d'accroche**

Run:
```bash
searchfox-cli --path 'mobile/android/fenix/**/Core.kt' -q 'WebCompatFeature.install' || \
  grep -n "WebCompatFeature" mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/Core.kt
```
Expected: confirme la ligne `WebCompatFeature.install(it)` (dans le bloc `GeckoEngine(...)`) et la ligne d'import `import mozilla.components.feature.webcompat.WebCompatFeature`.

- [ ] **Step 2: Editer Core.kt dans l'arbre**

Ajouter l'import a cote de celui de WebCompat :
```kotlin
import org.mozilla.fenix.components.SymfonyBuiltInExtensions
```
Et l'appel juste apres `WebCompatFeature.install(it)` :
```kotlin
                WebCompatFeature.install(it)
                SymfonyBuiltInExtensions.install(it)
```
(Note : `Core.kt` est deja dans le package `org.mozilla.fenix.components`, l'import peut etre inutile ; le verifier et l'omettre si meme package.)

- [ ] **Step 3: Generer le patch depuis le diff reel, puis revert**

Run:
```bash
git diff mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/Core.kt \
  > firelex-patch/patches/Core.kt.patch
git checkout -- mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/Core.kt
```

- [ ] **Step 4: Verifier que le patch s'applique proprement**

Run:
```bash
git apply --check --verbose firelex-patch/patches/Core.kt.patch && echo OK
```
Expected: `OK` (aucun reject).

- [ ] **Step 5: Committer**

```bash
git add firelex-patch/patches/Core.kt.patch
git commit -m "firelex-patch: patch Core.kt to install built-in extensions"
```

---

### Task 5: Creer home-routing.patch (home -> dashboard)

**Files:**
- Create: `firelex-patch/patches/home-routing.patch`
- Reference (non committe): fichier Fenix de routing new-tab/home, a pinner.

**Interfaces:**
- Consumes: `SymfonyBuiltInExtensions.dashboardUrl` (Task 2).
- Produces: patch qui, a l'ouverture d'un nouvel onglet / de la home, charge `dashboardUrl` si non nul (sinon fallback home native).

- [ ] **Step 1: Pinner la strategie d'interception**

Fenix affiche la home native quand une requete vers `about:home` est interceptee. Identifier l'intercepteur et/ou le use case de creation d'onglet :
```bash
searchfox-cli --path 'mobile/android/**' -q 'about:home' --regexp || true
searchfox-cli --path 'mobile/android/fenix/**' -q 'AppRequestInterceptor' || true
grep -rn "ABOUT_HOME\|about:home\|onLoadRequest" \
  mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/AppRequestInterceptor.kt 2>/dev/null || true
```
Expected: identifier le fichier + la methode ou l'on peut rediriger `about:home` vers une autre URL (privilegier `AppRequestInterceptor.onLoadRequest` : point additif a faible surface). Documenter le fichier/methode retenus en tete du patch.

- [ ] **Step 2: Editer le fichier retenu dans l'arbre**

Dans `onLoadRequest` (ou equivalent), avant le traitement habituel de `about:home`, rediriger si le dashboard est pret :
```kotlin
if (uri == ABOUT_HOME) {
    SymfonyBuiltInExtensions.dashboardUrl?.let { dashboard ->
        return RequestInterceptor.InterceptionResponse.Url(dashboard)
    }
}
```
Adapter les noms exacts (`uri`, `ABOUT_HOME`, type de retour) a la signature reelle trouvee au Step 1. Si le retour attendu differe, utiliser le type d'interception que la methode renvoie deja pour les autres cas.

- [ ] **Step 3: Generer le patch depuis le diff reel, puis revert**

Run (remplacer <FILE> par le chemin pinne au Step 1) :
```bash
git diff <FILE> > firelex-patch/patches/home-routing.patch
git checkout -- <FILE>
```

- [ ] **Step 4: Verifier que le patch s'applique proprement**

Run:
```bash
git apply --check --verbose firelex-patch/patches/home-routing.patch && echo OK
```
Expected: `OK`.

- [ ] **Step 5: Committer**

```bash
git add firelex-patch/patches/home-routing.patch
git commit -m "firelex-patch: patch home/new-tab to load Symfony dashboard"
```

---

### Task 6: Cabler la CI et builder l'APK

**Files:**
- Modify: `.github/workflows/build-fenix.yml`

**Interfaces:**
- Consumes: `firelex-patch/apply.sh` (Task 3) et tous les patches (Tasks 4-5).
- Produces: un run `workflow_dispatch` qui produit l'APK debug.

- [ ] **Step 1: Ajouter l'etape apply avant le build**

Inserer dans le job `apk`, apres l'etape "Write mozconfig" et avant "mach build (artifact)" :
```yaml
      - name: Apply firelex-patch
        run: ./firelex-patch/apply.sh
```

- [ ] **Step 2: Verifier tous les patches en local avant de pousser**

Run:
```bash
for p in firelex-patch/patches/*.patch; do git apply --check "$p" && echo "OK $p"; done
```
Expected: `OK` pour chaque patch.

- [ ] **Step 3: Committer et pousser**

```bash
git add .github/workflows/build-fenix.yml
git commit -m "ci: run firelex-patch apply.sh before Fenix build"
git push
```

- [ ] **Step 4: Declencher le build et verifier**

Run:
```bash
gh workflow run build-fenix.yml
gh run watch "$(gh run list --workflow build-fenix.yml --limit 1 --json databaseId -q '.[0].databaseId')"
```
Expected: run vert, artefact `fenix-debug-apk` present. Si `apply.sh` echoue (patch reject apres un sync upstream), le run echoue a cette etape avec le nom du patch fautif.

---

### Task 7: Valider l'APK

**Files:** (aucun ; validation manuelle)

- [ ] **Step 1: Installer l'APK sur un emulateur/appareil aarch64**

```bash
gh run download "$(gh run list --workflow build-fenix.yml --limit 1 --json databaseId -q '.[0].databaseId')" -n fenix-debug-apk -D /tmp/firelex-apk
adb install -r /tmp/firelex-apk/**/app-*-debug.apk
```

- [ ] **Step 2: Verifier uBlock Origin actif**

Ouvrir une page connue pour ses pubs ; confirmer le blocage. Verifier dans Extensions que uBO et Symfony Bookmarks sont presentes et actives.
Expected: les deux extensions listees, uBO bloque effectivement.

- [ ] **Step 3: Verifier la home = dashboard Symfony**

Ouvrir un nouvel onglet.
Expected: le dashboard Symfony s'affiche (liens charges depuis le serveur Symfony), pas la home native Fenix.

- [ ] **Step 4: Verifier l'echec bruyant d'apply.sh**

Casser volontairement un patch (modifier une ligne de contexte), relancer `./firelex-patch/apply.sh`.
Expected: exit non nul, nom du patch fautif affiche. Restaurer le patch ensuite.

---

### Task 8 (repo symfony-bookmarks, optionnel/independant): nettoyer l'usage bookmarks

**Files:**
- Modify: `../symfony-bookmarks/extension/manifest.json`
- Modify: fichiers de l'extension appelant `browser.bookmarks`

**Interfaces:** aucune dependance avec le build firelex ; peut se faire a tout moment.

- [ ] **Step 1: Retirer la permission bookmarks**

Retirer `"bookmarks"` du tableau `permissions` dans `manifest.json`.

- [ ] **Step 2: Neutraliser les appels browser.bookmarks**

Run:
```bash
grep -rn "browser.bookmarks\|chrome.bookmarks" ../symfony-bookmarks/extension --include=*.js
```
Pour chaque occurrence, garder derriere un garde `if (browser.bookmarks) { ... }` ou retirer si non utilise (le magasin est desormais le serveur Symfony via fetch).
Expected apres correction : plus d'appel non garde ; l'extension ne plante pas sur Android ou l'API est `undefined`.

- [ ] **Step 3: Re-builder et re-committer l'XPI dans firelex (boucle vers Task 1 Step 3)**

```bash
cd ../symfony-bookmarks/extension && npx web-ext build --overwrite-dest
cp web-ext-artifacts/*.zip <firelex>/firelex-patch/extensions/symfony_bookmarks.xpi
```

- [ ] **Step 4: Committer (dans chaque repo concerne)**

```bash
# repo symfony-bookmarks
git add extension/manifest.json extension/*.js && git commit -m "extension: drop unavailable bookmarks API usage on Android"
# repo firelex
git add firelex-patch/extensions/symfony_bookmarks.xpi && git commit -m "firelex-patch: refresh Symfony XPI without bookmarks API"
```

---

## Self-Review

**Spec coverage :**
- Objectif 1 (uBO pre-installe) -> Tasks 1, 2, 3, 6, 7.
- Objectif 2 (extension Symfony pre-installee) -> Tasks 1, 2, 3, 6, 7.
- Objectif 3 (home = dashboard) -> Tasks 2 (resolution baseUrl), 5 (routing), 7.
- Install built-in / contournement signature -> Task 2.
- Structure firelex-patch/ -> Tasks 1-5.
- apply.sh + echec bruyant -> Tasks 3, 6, 7 Step 4.
- Wiring CI -> Task 6.
- Workflow de sync -> Task 3 Step 5 (README), rebase couvert par Task 6 Step 4.
- Nettoyage extension (Spec section 9) -> Task 8.

**Placeholders :** les seuls points non pinnes (fichier de routing home au Task 5) sont accompagnes de commandes de decouverte concretes + du pattern d'edit exact ; c'est inherent au fait que la recherche shell locale est corrompue et que l'arbre bouge. Aucun "TODO"/"TBD" laisse.

**Type consistency :** `SymfonyBuiltInExtensions.install(runtime)` et `SymfonyBuiltInExtensions.dashboardUrl` utilises de facon coherente entre Tasks 2, 4, 5. `installBuiltInWebExtension` et `getMetadata()?.baseUrl` verifies dans l'arbre.
