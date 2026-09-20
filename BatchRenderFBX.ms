/*
================================================================================
  BatchRenderFBX.ms
  --------------------------------------------------------------------------
  3ds Max 2025 - Traitement par lot de dossiers contenant un FBX chacun.

  POUR CHAQUE SOUS-DOSSIER DU DOSSIER RACINE :
     1. Recherche du fichier FBX
     2. Import silencieux dans la scene courante
     3. Mesure de la bounding box monde de l'objet importe
     4. Ecriture d'un fichier JSON portant le nom du FBX, dans le meme dossier
     5. Repositionnement de la camera (target decalee au centre de la bbox,
        direction de vue conservee, distance recalculee pour un cadrage exact)
     6. Rendu et sauvegarde de l'image, au nom du FBX, dans le meme dossier
     7. Suppression du seul objet importe (camera, target et environnement
        restent intacts)

  HYPOTHESES VALIDEES AVEC L'UTILISATEUR :
     - Scene en metres, FBX coherents : aucune conversion d'unites
     - Un seul objet geometrique par FBX, pivot et objet centres en XY,
       Z min a zero, objet droit
     - Materiau / texture identiques pour tous les modeles
     - Un dossier = exactement un FBX
     - Moteur de rendu, environnement et materiaux deja configures dans la scene
     - Rendu carre 512 x 512
     - Aucune lumiere a ajouter

  UTILISATION :
     1. Ouvrir la scene de rendu dans 3ds Max
     2. MAXScript > Run Script...  (ou glisser ce fichier dans le viewport)
     3. Une fenetre de reglages s'ouvre : choisir l'etendue et les options,
        puis cliquer sur LANCER
     4. Le deroulement s'affiche dans le Listener (touche F11)
     5. Pour interrompre proprement : maintenir la touche ECHAP

  NUMEROTATION DES DOSSIERS :
     Les sous-dossiers sont tries par ordre alphabetique, ce qui rend leur
     numero stable d'une execution a l'autre. Le bouton "Lister les dossiers"
     affiche la correspondance numero / nom dans le Listener.

  REPRISE :
     Par defaut, un dossier dont l'image de sortie existe deja est ignore.
     Choisir "Recommencer du debut" pour tout recalculer et ecraser.

================================================================================
*/


-- ============================================================================
--  1. PARAMETRES PAR DEFAUT
--  Ils remplissent l'interface a l'ouverture et peuvent tous y etre modifies.
-- ============================================================================

global BRF_ROOT              = @"D:\Export"   -- dossier racine
global BRF_MAX_FOLDERS       = 1              -- 0 = tous les dossiers
global BRF_INDICES           = #()            -- plages explicites, prioritaire
global BRF_FORCE_REDO        = false          -- refaire les dossiers traites
global BRF_HIDE_EXISTING_GEO = true           -- masquer la geometrie preexistante
global BRF_CAMERA_NAME       = ""             -- "" = detection automatique
global BRF_RENDER_W          = 512
global BRF_RENDER_H          = 512
global BRF_IMAGE_EXT         = "png"          -- "png" ou "jpg"
global BRF_MARGIN            = 0.08           -- marge autour de l'objet
global BRF_DECIMALS          = 3              -- decimales dans le JSON
global BRF_PURGE_EVERY       = 25             -- purge memoire tous les N modeles

-- Etat interne
global BRF_LOGPATH = ""
global BRF_RUNNING = false


-- ============================================================================
--  2. FONCTIONS UTILITAIRES
-- ============================================================================

-- Horodatage lisible, format ISO simplifie
fn brfTimeStamp =
(
    local t = getLocalTime()
    -- getLocalTime() renvoie : annee, mois, jourSemaine, jour, h, min, sec, ms
    (formattedPrint t[1] format:"04d") + "-" + \
    (formattedPrint t[2] format:"02d") + "-" + \
    (formattedPrint t[4] format:"02d") + "T" + \
    (formattedPrint t[5] format:"02d") + ":" + \
    (formattedPrint t[6] format:"02d") + ":" + \
    (formattedPrint t[7] format:"02d")
)

-- Ecriture d'une ligne dans le log global ET dans le Listener
fn brfLog msg =
(
    format "%\n" msg
    if BRF_LOGPATH != "" do
    (
        try
        (
            local f = openFile BRF_LOGPATH mode:"a"
            if f != undefined do
            (
                format "[%] %\n" (brfTimeStamp()) msg to:f
                close f
            )
        )
        catch()
    )
)

-- Formatage d'un flottant avec le nombre de decimales configure.
-- MAXScript ecrit toujours le point comme separateur decimal.
fn brfNum v =
(
    formattedPrint v format:("." + (BRF_DECIMALS as string) + "f")
)

/*  Analyse d'une expression de plages saisie par l'utilisateur.

    Accepte par exemple :  "1-10, 100-120"
                           "1-10 100-120"
                           "5"
                           "1-10, 42, 100-120"

    Les separateurs reconnus sont la virgule, l'espace et le point-virgule.
    Une plage inversee (20-10) est remise dans le bon ordre.
    Retourne un tableau d'indices, doublons compris (filtres plus tard).
*/
fn brfParseRanges str =
(
    local out = #()
    local parts = filterString str ", ;\t"

    for p in parts do
    (
        local seg = filterString p "-"

        if seg.count == 1 then
        (
            -- Valeur isolee
            local v = try (seg[1] as integer) catch (undefined)
            if v != undefined do append out v
        )
        else if seg.count >= 2 then
        (
            -- Plage a - b
            local a = try (seg[1] as integer) catch (undefined)
            local b = try (seg[2] as integer) catch (undefined)
            if a != undefined and b != undefined do
            (
                if a > b do ( local t = a ; a = b ; b = t )
                for v = a to b do append out v
            )
        )
    )
    out
)

/*  Calcul de la distance de camera garantissant que les 8 coins de la
    bounding box tiennent dans le cadre.

    Principe : on projette chaque coin dans le repere de la camera, puis on
    resout, pour chaque coin et chaque axe de l'ecran, la distance minimale
    satisfaisant la contrainte de champ de vision. On retient le maximum.

    C'est un cadrage exact. Une approximation par sphere englobante
    fonctionnerait aussi mais eloignerait inutilement la camera, donnant des
    objets plus petits dans l'image.
*/
fn brfComputeDistance bbMin bbMax targetPos dir fovDeg aspect margin =
(
    -- Base orthonormee du repere camera.
    -- La camera regarde dans la direction -dir (dir pointe de la cible vers
    -- la camera), donc forward = -dir.
    local forward = -(normalize dir)
    local worldUp = [0, 0, 1]

    -- Cas degenere : vue strictement verticale (plongee ou contre-plongee
    -- parfaite). On bascule sur un autre vecteur de reference.
    if (abs (dot forward worldUp)) > 0.999 do worldUp = [0, 1, 0]

    local rightV = normalize (cross worldUp forward)
    local upV    = normalize (cross forward rightV)

    -- Demi-angles de champ effectifs, reduits par la marge
    local tanH = (tan (fovDeg / 2.0)) * (1.0 - margin)
    local tanV = tanH / aspect
    if tanH < 0.0001 do tanH = 0.0001
    if tanV < 0.0001 do tanV = 0.0001

    -- Les 8 coins de la boite
    local corners = #(
        [bbMin.x, bbMin.y, bbMin.z], [bbMax.x, bbMin.y, bbMin.z],
        [bbMin.x, bbMax.y, bbMin.z], [bbMax.x, bbMax.y, bbMin.z],
        [bbMin.x, bbMin.y, bbMax.z], [bbMax.x, bbMin.y, bbMax.z],
        [bbMin.x, bbMax.y, bbMax.z], [bbMax.x, bbMax.y, bbMax.z]
    )

    local dist = 0.0
    for c in corners do
    (
        local v = c - targetPos
        local cx = dot v rightV      -- ecart horizontal ecran
        local cy = dot v upV         -- ecart vertical ecran
        local cz = dot v forward     -- profondeur relative au plan de la cible

        -- Contrainte horizontale puis verticale
        local dH = (abs cx) / tanH - cz
        local dV = (abs cy) / tanV - cz
        if dH > dist do dist = dH
        if dV > dist do dist = dV
    )

    -- Securite : la camera ne doit jamais se retrouver dans l'objet
    local radius = (length (bbMax - bbMin)) / 2.0
    if dist < (radius * 1.1) do dist = radius * 1.1

    dist
)

-- Bounding box monde, alignee sur les axes du monde, de l'union des noeuds
fn brfWorldBBox nodeList =
(
    local bbMin = [1e30, 1e30, 1e30]
    local bbMax = [-1e30, -1e30, -1e30]
    local found = false

    for n in nodeList where isValidNode n do
    (
        -- matrix3 1 = repere monde
        local bb = nodeGetBoundingBox n (matrix3 1)
        if bb != undefined do
        (
            found = true
            if bb[1].x < bbMin.x do bbMin.x = bb[1].x
            if bb[1].y < bbMin.y do bbMin.y = bb[1].y
            if bb[1].z < bbMin.z do bbMin.z = bb[1].z
            if bb[2].x > bbMax.x do bbMax.x = bb[2].x
            if bb[2].y > bbMax.y do bbMax.y = bb[2].y
            if bb[2].z > bbMax.z do bbMax.z = bb[2].z
        )
    )

    if found then #(bbMin, bbMax) else undefined
)

-- Ecriture du fichier JSON descriptif
fn brfWriteJson jsonPath modelName fbxFile bbMin bbMax imgFile =
(
    local size   = bbMax - bbMin
    local center = (bbMin + bbMax) / 2.0

    local f = openFile jsonPath mode:"w"
    if f == undefined do return false

    format "{\n" to:f
    format "  \"name\": \"%\",\n" modelName to:f
    format "  \"source_fbx\": \"%\",\n" fbxFile to:f
    format "  \"units\": \"meters\",\n" to:f
    format "  \"decimal_separator\": \".\",\n" to:f
    format "  \"bbox\": {\n" to:f
    format "    \"min\": { \"x\": %, \"y\": %, \"z\": % },\n" \
        (brfNum bbMin.x) (brfNum bbMin.y) (brfNum bbMin.z) to:f
    format "    \"max\": { \"x\": %, \"y\": %, \"z\": % },\n" \
        (brfNum bbMax.x) (brfNum bbMax.y) (brfNum bbMax.z) to:f
    format "    \"size\": { \"x\": %, \"y\": %, \"z\": % },\n" \
        (brfNum size.x) (brfNum size.y) (brfNum size.z) to:f
    format "    \"center\": { \"x\": %, \"y\": %, \"z\": % }\n" \
        (brfNum center.x) (brfNum center.y) (brfNum center.z) to:f
    format "  },\n" to:f
    format "  \"render\": { \"file\": \"%\", \"width\": %, \"height\": % },\n" \
        imgFile BRF_RENDER_W BRF_RENDER_H to:f
    format "  \"processed_at\": \"%\"\n" (brfTimeStamp()) to:f
    format "}\n" to:f

    close f
    true
)

-- Configuration de l'importeur FBX : silencieux, geometrie seule
fn brfSetupFbxImporter =
(
    try
    (
        FBXImporterSetParam "Mode" #create
        FBXImporterSetParam "Animation" false
        FBXImporterSetParam "Cameras" false
        FBXImporterSetParam "Lights" false
        FBXImporterSetParam "ImportBoneAsDummy" false
        FBXImporterSetParam "AxisConversionMethod" "Animation"
        FBXImporterSetParam "UpAxis" "Z"
        -- Pas de conversion d'echelle : les FBX sont deja coherents
        FBXImporterSetParam "ScaleConversion" false
        FBXImporterSetParam "ShowWarnings" false
        FBXImporterSetParam "GenerateLog" false
    )
    catch
    (
        brfLog "AVERTISSEMENT : certains parametres FBX n'ont pas pu etre appliques."
    )
)

-- Configuration du peripherique de sortie image, pour eviter tout dialogue
fn brfSetupImageIO =
(
    if BRF_IMAGE_EXT == "png" then
    (
        -- 24 bits RGB, sans alpha (fond opaque, comme convenu)
        try ( pngio.setColorType 3 ) catch()
        try ( pngio.setAlpha false ) catch()
        try ( pngio.setInterlaced false ) catch()
    )
    else
    (
        try ( jpeg.setQuality 95 ) catch()
        try ( jpeg.setSmoothing 0 ) catch()
    )
)

-- Liste triee des sous-dossiers de la racine.
-- Le tri garantit que le numero d'un dossier ne change pas d'un lancement
-- a l'autre, ce qui rend les plages fiables.
fn brfGetFolders rootPath =
(
    local r = rootPath
    if r.count == 0 do return #()
    if (r[r.count] != "\\") do r += "\\"
    if not (doesFileExist r) do return #()
    local d = getDirectories (r + "*")
    sort d
    d
)


-- ============================================================================
--  3. TRAITEMENT PRINCIPAL
--  Lit les variables globales ci-dessus. Appelable directement par script
--  (BRF_Run()) si l'on souhaite se passer de l'interface.
-- ============================================================================

fn BRF_Run =
(
    if BRF_RUNNING do ( format "Un traitement est deja en cours.\n" ; return "occupe" )
    BRF_RUNNING = true

    local theCam, camDir, origTargetPos
    local hiddenNodes = #()
    local hiddenStates = #()
    local nbOK = 0, nbSkip = 0, nbFail = 0
    local aborted = false
    local result = "erreur"

    -- --- Normalisation du chemin racine -------------------------------------
    local root = BRF_ROOT
    if root.count == 0 do ( BRF_RUNNING = false ; return "chemin vide" )
    if (root[root.count] != "\\") do root += "\\"
    BRF_LOGPATH = root + "_batch_log.txt"

    format "\n\n"
    brfLog "==================================================================="
    brfLog ("DEBUT DU TRAITEMENT  -  racine : " + root)
    brfLog "==================================================================="

    if not (doesFileExist root) do
    (
        brfLog ("ERREUR FATALE : le dossier racine est introuvable -> " + root)
        BRF_RUNNING = false
        return "dossier introuvable"
    )

    -- --- Selection de la camera ---------------------------------------------
    if BRF_CAMERA_NAME != "" then
    (
        theCam = getNodeByName BRF_CAMERA_NAME
        if theCam == undefined do
        (
            brfLog ("ERREUR FATALE : camera introuvable -> " + BRF_CAMERA_NAME)
            BRF_RUNNING = false
            return "camera introuvable"
        )
    )
    else
    (
        -- Detection automatique : cameras possedant une target
        local cams = for c in cameras where \
            (superClassOf c == camera) and \
            (isProperty c #target) and (c.target != undefined) collect c

        case cams.count of
        (
            0: ( brfLog "ERREUR FATALE : aucune target camera trouvee dans la scene."
                 BRF_RUNNING = false
                 return "aucune camera" )
            1: ( theCam = cams[1] )
            default: ( brfLog ("ERREUR FATALE : " + cams.count as string + \
                       " target cameras trouvees. Renseigner BRF_CAMERA_NAME.")
                       BRF_RUNNING = false
                       return "plusieurs cameras" )
        )
    )
    brfLog ("Camera utilisee : " + theCam.name)

    if not (isProperty theCam #fov) do
    (
        brfLog "ERREUR FATALE : cette camera n'expose pas de propriete FOV."
        BRF_RUNNING = false
        return "camera sans FOV"
    )

    -- Avertissement si un clipping manuel risque de tronquer les objets
    try
    (
        if theCam.clipManually then
            brfLog ("AVERTISSEMENT : clipping manuel actif (near=" + \
                    theCam.nearclip as string + " far=" + theCam.farclip as string + \
                    "). Verifier que les objets eloignes ne sont pas tronques.")
    )
    catch()

    -- --- Memorisation de la direction de vue --------------------------------
    -- La direction camera -> target est figee ici, une fois pour toutes, puis
    -- reutilisee a l'identique pour chaque modele. L'angle de vue de tous les
    -- rendus sera donc strictement le meme.
    origTargetPos = theCam.target.pos
    camDir = normalize (theCam.pos - origTargetPos)

    if (length camDir) < 0.001 do
    (
        brfLog "ERREUR FATALE : camera et target confondues, direction indeterminee."
        BRF_RUNNING = false
        return "direction indeterminee"
    )
    brfLog ("Direction de vue figee : " + camDir as string)
    brfLog ("FOV horizontal : " + (brfNum theCam.fov) + " degres")
    brfLog ("Marge de cadrage : " + (brfNum (BRF_MARGIN * 100)) + " %")

    -- --- Reglages de rendu --------------------------------------------------
    renderWidth  = BRF_RENDER_W
    renderHeight = BRF_RENDER_H
    local aspect = (BRF_RENDER_W as float) / (BRF_RENDER_H as float)

    brfSetupFbxImporter()
    brfSetupImageIO()

    -- --- Mise a l'ecart de la geometrie preexistante ------------------------
    -- La scene contient souvent un modele laisse en place pour avoir regle le
    -- cadrage de la camera. Il apparaitrait dans tous les rendus. On le masque
    -- temporairement, sans rien supprimer ni modifier le fichier .max.
    local existingGeo = for n in objects where superClassOf n == GeometryClass collect n

    if existingGeo.count > 0 then
    (
        if BRF_HIDE_EXISTING_GEO then
        (
            for n in existingGeo do
            (
                append hiddenNodes n
                append hiddenStates n.isHidden
                n.isHidden = true
            )
            brfLog (existingGeo.count as string + \
                    " objet(s) deja present(s) dans la scene : masque(s) pendant le batch.")
            for n in existingGeo do brfLog ("   - " + n.name)
        )
        else
            brfLog ("AVERTISSEMENT : " + existingGeo.count as string + \
                    " objet(s) deja present(s) dans la scene apparaitront dans tous " + \
                    "les rendus (masquage desactive).")
    )
    else
        brfLog "Scene vide de geometrie : aucun masquage necessaire."

    -- --- Liste des dossiers -------------------------------------------------
    local dirs = brfGetFolders root
    if dirs.count == 0 do
    (
        brfLog "ERREUR FATALE : aucun sous-dossier trouve."
        BRF_RUNNING = false
        return "aucun sous-dossier"
    )

    -- --- Construction de la liste des dossiers a traiter ---------------------
    -- Deux modes possibles : plages explicites (BRF_INDICES), sinon les N
    -- premiers dossiers (BRF_MAX_FOLDERS, 0 = tous).
    local todo = #()

    if BRF_INDICES.count > 0 then
    (
        local outOfRange = 0
        for idx in BRF_INDICES do
        (
            if idx >= 1 and idx <= dirs.count then
                appendIfUnique todo idx
            else
                outOfRange += 1
        )
        sort todo
        if outOfRange > 0 do
            brfLog ("AVERTISSEMENT : " + outOfRange as string + \
                    " numero(s) hors de la plage 1-" + dirs.count as string + \
                    ", ignore(s).")
    )
    else
    (
        local n = dirs.count
        if BRF_MAX_FOLDERS > 0 and BRF_MAX_FOLDERS < n do n = BRF_MAX_FOLDERS
        for k = 1 to n do append todo k
    )

    local total = todo.count
    if total == 0 do
    (
        brfLog "ERREUR FATALE : aucun dossier selectionne."
        BRF_RUNNING = false
        return "selection vide"
    )

    brfLog (dirs.count as string + " dossier(s) detecte(s), " + \
            total as string + " a traiter.")
    if BRF_INDICES.count > 0 do
        brfLog ("Selection : dossiers n " + todo[1] as string + " a " + \
                todo[total] as string + " (" + total as string + " au total)")
    brfLog (if BRF_FORCE_REDO then \
            ">>> TOUT REFAIRE : les fichiers existants seront ecrases." else \
            ">>> REPRISE : les dossiers deja traites seront sautes.")
    brfLog "-------------------------------------------------------------------"

    local startTime = timeStamp()

    -- ========================================================================
    --  BOUCLE PRINCIPALE
    -- ========================================================================
    for k = 1 to total while not aborted do
    (
        -- Interruption manuelle par ECHAP
        windows.processPostedMessages()
        if keyboard.escPressed do
        (
            aborted = true
            brfLog ">>> INTERRUPTION DEMANDEE PAR L'UTILISATEUR (ECHAP)."
            exit
        )

        local i   = todo[k]              -- numero du dossier dans la liste triee
        local dir = dirs[i]
        -- Prefixe de progression : avancement, puis numero reel du dossier
        local pfx = "[" + k as string + "/" + total as string + \
                    " #" + i as string + "]"
        local addedNodes = #()

        try
        (
            -- --- Recherche du FBX --------------------------------------------
            local fbxFiles = getFiles (dir + "*.fbx")

            if fbxFiles.count == 0 then
            (
                nbFail += 1
                brfLog (pfx + " ECHEC  " + dir + "  -> aucun FBX dans ce dossier")
            )
            else
            (
                if fbxFiles.count > 1 do
                    brfLog ("AVERTISSEMENT : " + fbxFiles.count as string + \
                            " FBX dans " + dir + ", seul le premier est traite.")

                local fbxPath  = fbxFiles[1]
                local baseName = getFilenameFile fbxPath
                local imgName  = baseName + "." + BRF_IMAGE_EXT
                local imgPath  = dir + imgName
                local jsonPath = dir + baseName + ".json"

                -- --- Reprise : on saute si l'image existe deja ---------------
                if (not BRF_FORCE_REDO) and (doesFileExist imgPath) then
                (
                    nbSkip += 1
                    format "% SAUTE  % (deja traite)\n" pfx baseName
                )
                else
                (
                    -- --- Import ---------------------------------------------
                    -- On photographie la scene avant import pour identifier
                    -- precisement ce qui aura ete ajoute.
                    local before = objects as array

                    local imported = importFile fbxPath #noPrompt using:FBXIMP

                    if not imported then
                    (
                        nbFail += 1
                        brfLog (pfx + " ECHEC  " + baseName + "  -> import FBX refuse")
                    )
                    else
                    (
                        -- Difference avant / apres
                        for n in objects where (findItem before n) == 0 do
                            append addedNodes n

                        -- On ne mesure que la geometrie
                        local geo = for n in addedNodes \
                            where superClassOf n == GeometryClass collect n

                        if geo.count == 0 then
                        (
                            nbFail += 1
                            brfLog (pfx + " ECHEC  " + baseName + \
                                    "  -> aucune geometrie apres import")
                        )
                        else
                        (
                            -- --- Bounding box -------------------------------
                            local bb = brfWorldBBox geo
                            if bb == undefined then
                            (
                                nbFail += 1
                                brfLog (pfx + " ECHEC  " + baseName + \
                                        "  -> bounding box incalculable")
                            )
                            else
                            (
                                local bbMin = bb[1]
                                local bbMax = bb[2]
                                local bbCenter = (bbMin + bbMax) / 2.0

                                -- --- JSON -----------------------------------
                                if not (brfWriteJson jsonPath baseName \
                                        (filenameFromPath fbxPath) bbMin bbMax imgName) do
                                    brfLog ("AVERTISSEMENT : ecriture JSON impossible -> " + jsonPath)

                                -- --- Placement de la camera -----------------
                                -- La target se decale au centre de la bounding
                                -- box. L'objet n'est jamais deplace.
                                local dist = brfComputeDistance bbMin bbMax \
                                    bbCenter camDir theCam.fov aspect BRF_MARGIN

                                theCam.target.pos = bbCenter
                                theCam.pos = bbCenter + camDir * dist

                                -- --- Rendu ----------------------------------
                                local rbmp = render camera:theCam \
                                    outputSize:[BRF_RENDER_W, BRF_RENDER_H] \
                                    vfb:off quiet:true

                                if rbmp == undefined then
                                (
                                    nbFail += 1
                                    brfLog (pfx + " ECHEC  " + baseName + "  -> rendu vide")
                                )
                                else
                                (
                                    -- Sauvegarde via une copie explicite :
                                    -- evite le dialogue de configuration du
                                    -- format image.
                                    local obmp = bitmap BRF_RENDER_W BRF_RENDER_H \
                                                 filename:imgPath
                                    copy rbmp obmp
                                    save obmp
                                    close obmp
                                    close rbmp

                                    nbOK += 1
                                    format "% OK  %  bbox %x%x% m  dist %\n" \
                                        pfx baseName \
                                        (brfNum (bbMax.x - bbMin.x)) \
                                        (brfNum (bbMax.y - bbMin.y)) \
                                        (brfNum (bbMax.z - bbMin.z)) \
                                        (brfNum dist)
                                )
                            )
                        )
                    )
                )
            )
        )
        catch
        (
            nbFail += 1
            brfLog (pfx + " EXCEPTION  " + dir + "  -> " + (getCurrentException()))
        )

        -- --- Nettoyage : on supprime uniquement ce que l'import a ajoute -----
        -- La camera, sa target, l'environnement et les materiaux de scene sont
        -- preserves, y compris en cas d'erreur en cours de route.
        try
        (
            for n in addedNodes where isValidNode n do delete n
        )
        catch
        (
            brfLog "AVERTISSEMENT : nettoyage partiel des objets importes."
        )

        -- --- Purge memoire periodique ---------------------------------------
        -- Sans cela, Max gonfle progressivement au fil des centaines d'imports.
        if (mod k BRF_PURGE_EVERY) == 0 do
        (
            try ( freeSceneBitmaps() ) catch()
            gc light:true
            format "   ... purge memoire (apres % modeles)\n" k
        )
    )

    -- ========================================================================
    --  RESTAURATION ET RESUME
    -- ========================================================================

    -- La target retrouve sa position d'origine
    try
    (
        local d = length (theCam.pos - theCam.target.pos)
        theCam.target.pos = origTargetPos
        theCam.pos = origTargetPos + camDir * d
    )
    catch()

    -- La geometrie preexistante retrouve son etat de visibilite d'origine
    if hiddenNodes.count > 0 do
    (
        try
        (
            for j = 1 to hiddenNodes.count where isValidNode hiddenNodes[j] do
                hiddenNodes[j].isHidden = hiddenStates[j]
            brfLog ("Visibilite restauree sur " + hiddenNodes.count as string + " objet(s).")
        )
        catch
        (
            brfLog "AVERTISSEMENT : restauration de visibilite incomplete."
        )
    )

    try ( freeSceneBitmaps() ) catch()
    gc light:true

    local elapsed = ((timeStamp()) - startTime) / 1000.0

    brfLog "-------------------------------------------------------------------"
    brfLog ("TERMINE" + (if aborted then " (INTERROMPU)" else "") + \
            "  -  reussis : " + nbOK as string + \
            "  |  sautes : " + nbSkip as string + \
            "  |  echecs : " + nbFail as string)
    brfLog ("Duree : " + (brfNum elapsed) + " s" + \
            (if nbOK > 0 then ("  (moyenne " + (brfNum (elapsed / nbOK)) + " s / modele)") else ""))
    brfLog ("Log complet : " + BRF_LOGPATH)
    brfLog "==================================================================="

    BRF_RUNNING = false

    result = (if aborted then "Interrompu - " else "Termine - ") + \
             nbOK as string + " ok, " + nbSkip as string + " sautes, " + \
             nbFail as string + " echecs (" + (brfNum elapsed) + " s)"
    result
)


-- ============================================================================
--  4. INTERFACE
-- ============================================================================

try ( destroyDialog BRF_UI ) catch()

rollout BRF_UI "Batch Render FBX" width:400
(
    group "Dossier racine"
    (
        -- Le champ occupe sa propre ligne : les boutons dessous, pour eviter
        -- tout chevauchement quel que soit le theme de l'interface.
        edittext edtRoot "" text:BRF_ROOT width:360 align:#center offset:[0,2]
        button   btnBrowse "Parcourir..." width:150 height:24 \
                 across:2 align:#left offset:[8,4]
        button   btnList   "Lister les dossiers" width:170 height:24 \
                 align:#right offset:[-8,4] \
                 tooltip:"Affiche les dossiers numerotes dans le Listener (F11)"
    )

    group "Etendue du traitement"
    (
        -- offsets cumulatifs : aere les quatre options verticalement
        radiobuttons rdoScope labels:#("Test : 1 seul dossier", \
                                       "Les N premiers dossiers", \
                                       "Plage(s) precise(s)", \
                                       "Tous les dossiers") \
                     default:1 columns:1 align:#left \
                     offsets:#([0,2], [0,8], [0,14], [0,20])

        spinner  spnCount "N = " range:[1, 100000, 1] type:#integer \
                 fieldwidth:60 enabled:false align:#left offset:[16,26]

        edittext edtRanges "" text:"1-10, 100-120" width:350 \
                 enabled:false align:#center offset:[0,8]
        label    lblRangeHint "ex. 1-10, 100-120   ou   5, 42, 200-210" \
                 align:#center offset:[0,2]
    )

    group "Reprise"
    (
        radiobuttons rdoRedo labels:#("Continuer : sauter les dossiers deja traites", \
                                      "Recommencer du debut : tout refaire et ecraser") \
                     default:1 columns:1 align:#left \
                     offsets:#([0,2], [0,8])
    )

    group "Options de rendu"
    (
        checkbox chkHide "Masquer la geometrie deja presente dans la scene" \
                 checked:true align:#left offset:[0,2]
        spinner spnMargin "Marge autour de l'objet (%)  " range:[0.0, 50.0, 8.0] \
                type:#float scale:0.5 fieldwidth:55 align:#left offset:[0,8]
        dropdownlist ddlFmt "Format de l'image" items:#("PNG", "JPG") \
                selection:1 width:140 align:#left offset:[0,6]
    )

    label lblHint  "Pendant le traitement : ECHAP = arret propre" \
          align:#left offset:[0,6]
    label lblHint2 "Le detail s'affiche dans le Listener (F11)" align:#left

    button btnRun "LANCER" width:370 height:34 offset:[0,10]
    label  lblStatus "Pret." align:#left offset:[0,8]
    label  lblPad "" height:4

    -- Activation des champs selon le mode choisi
    on rdoScope changed state do
    (
        spnCount.enabled  = (state == 2)
        edtRanges.enabled = (state == 3)
    )

    on btnBrowse pressed do
    (
        local p = getSavePath caption:"Choisir le dossier racine" \
                              initialDir:edtRoot.text
        if p != undefined do edtRoot.text = p
    )

    -- Affiche la correspondance numero / nom de dossier
    on btnList pressed do
    (
        local dirs = brfGetFolders edtRoot.text
        if dirs.count == 0 then
            lblStatus.text = "Aucun sous-dossier trouve."
        else
        (
            format "\n--- DOSSIERS DE % ---\n" edtRoot.text
            for j = 1 to dirs.count do
            (
                -- On n'affiche que le nom du dossier, pas le chemin complet
                local nm = dirs[j]
                if nm[nm.count] == "\\" do nm = substring nm 1 (nm.count - 1)
                format "%\t%\n" j (filenameFromPath nm)
            )
            format "--- % dossier(s) ---\n" dirs.count
            lblStatus.text = (dirs.count as string + " dossiers listes dans le Listener (F11).")
        )
    )

    on btnRun pressed do
    (
        if BRF_RUNNING then
            lblStatus.text = "Un traitement est deja en cours."
        else
        (
            -- Transfert des reglages de l'interface vers les variables globales
            BRF_ROOT = edtRoot.text
            BRF_INDICES = #()

            case rdoScope.state of
            (
                1: BRF_MAX_FOLDERS = 1
                2: BRF_MAX_FOLDERS = spnCount.value
                3: BRF_INDICES     = brfParseRanges edtRanges.text
                4: BRF_MAX_FOLDERS = 0
            )

            BRF_FORCE_REDO        = (rdoRedo.state == 2)
            BRF_HIDE_EXISTING_GEO = chkHide.checked
            BRF_MARGIN            = spnMargin.value / 100.0
            BRF_IMAGE_EXT         = (if ddlFmt.selection == 1 then "png" else "jpg")

            if rdoScope.state == 3 and BRF_INDICES.count == 0 then
                lblStatus.text = "Plage invalide. Exemple attendu : 1-10, 100-120"
            else
            (
                -- Confirmation avant un traitement destructif de grande ampleur
                local go = true
                local nbCible = (if rdoScope.state == 3 then BRF_INDICES.count \
                                 else if rdoScope.state == 1 then 1 else 999)

                if BRF_FORCE_REDO and nbCible > 1 do
                (
                    go = queryBox ("Tout refaire depuis le debut ?\n\n" + \
                        "Les images et fichiers JSON existants des dossiers " + \
                        "selectionnes seront ecrases.") title:"Confirmation"
                )

                if go do
                (
                    btnRun.text = "TRAITEMENT EN COURS..."
                    btnRun.enabled = false
                    lblStatus.text = "En cours - ECHAP pour interrompre"
                    local res = "erreur"
                    try ( res = BRF_Run() ) catch ( res = "Erreur : " + getCurrentException() )
                    btnRun.text = "LANCER"
                    btnRun.enabled = true
                    lblStatus.text = res
                )
            )
        )
    )
)

createDialog BRF_UI escapeEnable:false
