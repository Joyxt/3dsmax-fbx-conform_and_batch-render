# Outils 3ds Max — Export et rendu FBX par lot

Deux scripts MaxScript pour 3ds Max, conçus pour fonctionner en pipeline :
`Export_FBX_Individuel.ms` prépare des FBX propres à partir d'une scène,
`BatchRenderFBX.ms` les transforme ensuite en rendus.

---

## 1. Export_FBX_Individuel.ms
<img width="702/2" height="1055/2" alt="image" src="https://github.com/user-attachments/assets/bf339076-7119-43cb-8e98-f54ce8e343d2" />

Exporte chaque objet géométrique d'une scène 3ds Max dans son propre fichier
FBX, un dossier par objet :

```
DossierExport\
  NomObjet1\NomObjet1.fbx
  NomObjet2\NomObjet2.fbx
  ...
```

### Ce qu'il fait, par objet
1. Duplique l'objet sur une **copie temporaire** — l'original n'est jamais touché
2. Applique un facteur d'échelle optionnel
3. Recentre la copie sur l'origine en X/Y
4. Pose le point le plus bas de la bounding box à Z = 0
5. Réinitialise les transformations (`Reset XForm`) puis ramène le pivot à (0,0,0)
   sans déplacer la géométrie (équivalent d'« Affect Pivot Only »)
6. Redirige les textures du matériau vers un dossier de textures donné, sur une
   **copie du matériau** (le matériau original n'est jamais modifié)
7. Exporte le résultat en FBX, puis supprime la copie temporaire

### Interface
- Dossier d'export, dossier de textures, facteur d'échelle
- Option pour bloquer l'export si une texture référencée est introuvable
- Journal détaillé et barre de progression pendant le traitement

### À savoir avant utilisation
- La scène doit être configurée en **mètres** ; le script ne fait aucune
  conversion d'unité — un avertissement s'affiche sinon, sans bloquer l'export
- Un FBX déjà présent est **écrasé sans confirmation**
- Un nom d'objet contenant un caractère interdit sous Windows (`\ / : * ? " < > |`)
  fait échouer l'export de cet objet, journalisé, sans arrêter le lot
- Teste d'abord sur 2-3 objets aux configurations différentes (centré, décalé,
  pivot ailleurs, avec rotation) avant un lancement complet

---

## 2. BatchRenderFBX.ms

Parcourt un dossier racine contenant un sous-dossier par modèle (chacun avec
un FBX), et pour chacun : importe, mesure, rend, puis nettoie.

### Ce qu'il fait, par dossier
1. Recherche le FBX du dossier et l'importe dans la scène courante
2. Calcule la **bounding box monde** de l'objet importé (géométrie uniquement)
3. Écrit un fichier `NomFBX.json` avec les dimensions (min/max/taille/centre, en
   mètres, 3 décimales)
4. Décale la **target de la caméra** au centre vertical de la bounding box (la
   direction de vue caméra→cible d'origine est conservée à l'identique) et
   recalcule la distance de la caméra pour un cadrage exact par projection des
   8 coins de la boîte — pas d'approximation par sphère englobante
5. Effectue le rendu (512×512 par défaut) et le sauvegarde sous `NomFBX.png`
   (ou `.jpg`) dans le même dossier
6. Supprime uniquement l'objet importé — caméra, target et environnement de
   scène restent intacts
7. Restaure la position d'origine de la caméra une fois le lot terminé

### Interface
- **Dossier racine**, avec bouton Parcourir et bouton "Lister les dossiers"
  (affiche la correspondance numéro ↔ nom dans le Listener — les dossiers sont
  triés alphabétiquement, donc leur numéro est stable d'un lancement à l'autre)
- **Étendue** : un seul dossier (test), les N premiers, une ou plusieurs plages
  explicites (ex. `1-10, 100-120`), ou la totalité
- **Reprise** : par défaut, un dossier dont l'image existe déjà est sauté —
  utile pour reprendre après une interruption. Option pour tout refaire et
  écraser
- Masquage automatique de toute géométrie déjà présente dans la scène pendant
  le traitement (non destructif, restauré à la fin)
- Marge de cadrage, format d'image (PNG/JPG) réglables

### Pendant le traitement
- Une **purge mémoire** a lieu automatiquement tous les 25 modèles
- **Échap** interrompt proprement le lot (nettoyage et restauration effectués
  avant l'arrêt)
- Un log global (`_batch_log.txt`) est écrit à la racine : succès, échecs et
  leur raison, horodatés

### Hypothèses de la configuration actuelle
- Scène et FBX en mètres, aucune conversion d'unité nécessaire
- Un seul objet géométrique par FBX, déjà centré en X/Y, Z minimum à 0
- Un dossier = exactement un FBX
- Caméra de type *Target Camera*
- Moteur de rendu, éclairage/environnement et matériaux déjà configurés dans
  la scène de rendu

---

## Utilisation

1. Ouvrir la scène 3ds Max concernée
2. **MAXScript → Run Script...**, sélectionner le fichier `.ms` (ou le glisser
   dans le viewport)
3. Une fenêtre de réglages s'ouvre pour les deux scripts
4. Toujours tester sur un petit échantillon avant un lancement complet
