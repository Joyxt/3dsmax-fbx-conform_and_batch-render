/*
================================================================================
EXPORT FBX INDIVIDUEL PAR OBJET - 3ds Max 2025 (MaxScript)
================================================================================

Ce script exporte chaque objet geometrique de la scene dans son propre
fichier FBX :

    <DossierExport>\<NomObjet>\<NomObjet>.fbx

Les objets originaux de la scene ne sont JAMAIS modifies : chaque objet est
traite sur une copie temporaire (geometrie + copie independante de son
materiau), qui est supprimee juste apres son export.

--------------------------------------------------------------------------------
HYPOTHESES / POINTS RENDUS EXPLICITES (voir aussi le message d'accompagnement) :
--------------------------------------------------------------------------------
1) La scene doit deja etre configuree en metres (units.SystemType == #Meters).
   Le script NE FAIT AUCUNE conversion d'unite. Le "facteur d'echelle" est un
   parametre purement multiplicatif sur les dimensions (champ exportScale),
   independant des unites systeme/affichage/FBX.
2) Si une texture n'est pas physiquement retrouvee dans le dossier textures
   configure, l'export N'EST PAS bloque par defaut (avertissement journalise
   uniquement). Cochez la case "Bloquer si texture introuvable" pour changer
   ce comportement.
3) Un fichier FBX deja present est ECRASE sans confirmation.
4) Le script NE reinitialise PAS l'ensemble de la configuration d'export FBX.
   Seuls 3 parametres cibles sont forces (UpAxis, SmoothingGroups,
   TangentsAndBinormals), chacun protege par un try/catch car le nom exact
   d'un parametre FBX peut varier legerement selon la version du plug-in FBX
   livre avec 3ds Max. En cas d'echec silencieux d'un de ces reglages,
   verifiez dans le Listener avec, par exemple :
       FBXExporterGetParam "UpAxis"
5) La verification des noms de fichiers Windows couvre les caracteres
   interdits usuels ( \ / : * ? " < > | ) ainsi que le nom vide. Les noms de
   peripheriques reserves (CON, NUL, COM1...) ne sont pas verifies separement.
6) Le pivot final est repositionne a (0,0,0) via une correction explicite de
   l'"object offset" (equivalent du mode "Affect Pivot Only"), calculee a
   partir de la position REELLE du noeud apres Reset XForm plutot que d'une
   hypothese sur son comportement exact. Cette approche reste correcte que
   Reset XForm deplace ou non la position du noeud, du moment que la
   rotation/l'echelle du noeud redeviennent neutres (but documente de cet
   utilitaire) — une verification de securite le confirme et journalise un
   avertissement sinon.

Testez d'abord sur 2-3 objets representatifs (objet centre, objet decale,
objet avec pivot ailleurs, objet avec rotation...) avant un lancement complet.
================================================================================
*/

global ExportFBX_Individuel_Rollout

(
    -- ============================================================
    -- FONCTIONS UTILITAIRES
    -- ============================================================

    fn efi_joinStrings arr sep =
    (
        local s = ""
        for i = 1 to arr.count do
        (
            s += arr[i]
            if i < arr.count do s += sep
        )
        s
    )

    -- NOTE CORRECTIVE : "isDirectory" n'est PAS une fonction MAXScript valide.
    -- On utilise ici "getDirectories", qui fonctionne comme test d'existence
    -- exact lorsque le motif ne contient pas de caractere joker.
    fn efi_folderExists p =
    (
        local test = p
        if test.count > 0 and (substring test test.count 1) == "\\" then
            test = substring test 1 (test.count - 1)
        local ok = false
        try (ok = (getDirectories test).count > 0) catch (ok = false)
        ok
    )

    fn efi_isExportableGeometry obj =
    (
        local ok = false
        try
        (
            if isValidNode obj and superclassof obj == GeometryClass then ok = true
        )
        catch (ok = false)
        ok
    )

    fn efi_hasInvalidWindowsChars name =
    (
        local forbidden = "\\/:*?\"<>|"
        local badChar = ""
        local found = false
        if name.count == 0 then
        (
            found = true
            badChar = "(nom vide)"
        )
        else
        (
            for i = 1 to name.count while not found do
            (
                local c = name[i]
                if findString forbidden c != undefined then
                (
                    found = true
                    badChar = c
                )
            )
        )
        #(found, badChar)
    )

    fn efi_collectBitmaps mtlOrMap &bmpArray =
    (
        if mtlOrMap == undefined then return()

        if iskindof mtlOrMap Bitmaptexture then
        (
            appendIfUnique bmpArray mtlOrMap
        )
        else
        (
            local nSubMtls = 0
            try (nSubMtls = getNumSubMtls mtlOrMap) catch (nSubMtls = 0)
            for i = 1 to nSubMtls do
            (
                local sub = undefined
                try (sub = getSubMtl mtlOrMap i) catch (sub = undefined)
                if sub != undefined do efi_collectBitmaps sub &bmpArray
            )

            local nSubMaps = 0
            try (nSubMaps = getNumSubTexmaps mtlOrMap) catch (nSubMaps = 0)
            for i = 1 to nSubMaps do
            (
                local sub = undefined
                try (sub = getSubTexmap mtlOrMap i) catch (sub = undefined)
                if sub != undefined do efi_collectBitmaps sub &bmpArray
            )
        )
    )

    fn efi_redirectTextures tempObj textureFolder blockOnMissing logFn =
    (
        local allOk = true

        if tempObj.material != undefined then
        (
            -- Copie INDEPENDANTE du materiau : garantit qu'on ne touche
            -- jamais au materiau original partage par d'autres objets.
            local tempMat = copy tempObj.material
            tempObj.material = tempMat

            local bmpArray = #()
            efi_collectBitmaps tempMat &bmpArray

            for bmp in bmpArray do
            (
                try
                (
                    local curFile = bmp.filename
                    if curFile != undefined and curFile != "" then
                    (
                        local justName = filenameFromPath curFile
                        local newPath = textureFolder + justName
                        if doesFileExist newPath then
                        (
                            bmp.filename = newPath
                        )
                        else
                        (
                            logFn ("   [AVERTISSEMENT] Texture introuvable dans " + textureFolder + " : " + justName)
                            if blockOnMissing do allOk = false
                        )
                    )
                )
                catch
                (
                    logFn ("   [AVERTISSEMENT] Erreur lors du traitement d'une texture : " + (getCurrentException()))
                )
            )
        )

        allOk
    )

    fn efi_exportSingleObject srcObj exportRoot textureFolder exportScale blockOnMissing logFn =
    (
        -- Retourne #(true, cheminFBX) en cas de succes, #(false, raison) sinon
        local result = #(false, "erreur inconnue")
        local tempObj = undefined

        try
        (
            local objName = srcObj.name

            local nameCheck = efi_hasInvalidWindowsChars objName
            if nameCheck[1] then
            (
                result = #(false, ("nom invalide (caractere interdit : '" + nameCheck[2] + "')"))
            )
            else
            (
                -- ---- Etape 1 : copie temporaire independante ----
                local clonedArr = #()
                maxOps.cloneNodes srcObj cloneType:#copy newNodes:&clonedArr
                if clonedArr.count == 0 then throw "echec de la copie temporaire (maxOps.cloneNodes)"
                tempObj = clonedArr[1]
                tempObj.isHidden = false
                tempObj.isFrozen = false
                -- Note : 3ds Max autorise des noms de noeuds dupliques (l'identite
                -- reelle d'un objet repose sur son handle interne, pas son nom),
                -- une simple concatenation suffit donc ici sans risque de collision.
                tempObj.name = objName + "_TEMP_EXPORT"

                -- ---- Etape 2 : echelle (facteur multiplicatif configurable) ----
                if exportScale != 1.0 do
                    scale tempObj [exportScale, exportScale, exportScale]

                -- ---- Etape 3 : centrage X/Y (bounding box monde) ----
                local bMin = tempObj.min
                local bMax = tempObj.max
                local cX = (bMin.x + bMax.x) / 2.0
                local cY = (bMin.y + bMax.y) / 2.0
                tempObj.pos += [-cX, -cY, 0]

                -- ---- Etape 4 : point le plus bas -> Z = 0 ----
                bMin = tempObj.min
                tempObj.pos += [0, 0, -bMin.z]

                -- ---- Etape 5 : Reset XForm ----
                ResetXForm tempObj
                -- Aplatit le modificateur XForm ajoute par ResetXForm dans l'objet
                -- de base. Non bloquant : si indisponible sur ce type d'objet,
                -- on continue (le Reset XForm reste effectif sans ce nettoyage).
                try (collapseStack tempObj) catch (logFn "   [INFO] collapseStack non applique sur cet objet (non bloquant).")

                -- Verification de securite : Reset XForm doit avoir neutralise
                -- la rotation et l'echelle du noeud. Si ce n'est pas le cas,
                -- la correction du pivot ci-dessous serait imprecise : on le
                -- signale sans bloquer l'export.
                local rotAngleOk = (abs tempObj.rotation.angle) < 0.01
                local scl = tempObj.scale
                local sclOk = ((abs (scl.x - 1.0)) < 0.001) and ((abs (scl.y - 1.0)) < 0.001) and ((abs (scl.z - 1.0)) < 0.001)
                if not (rotAngleOk and sclOk) do
                    logFn "   [AVERTISSEMENT] Apres Reset XForm, rotation/echelle du noeud non neutres : verifiez le pivot final."

                -- ---- Etape 6 : pivot -> (0,0,0) sans deplacer la geometrie ----
                -- Equivalent de "Affect Pivot Only" : on reporte la position
                -- actuelle du pivot dans l'offset d'objet, puis on ramene la
                -- position du noeud a l'origine. La geometrie ne bouge pas.
                local curPos = tempObj.pos
                if curPos != [0, 0, 0] do
                (
                    tempObj.objectOffsetPos += curPos
                    tempObj.pos = [0, 0, 0]
                )

                -- ---- Verifications finales avant export ----
                local tol = 0.001 -- 1 mm (scene en metres)
                local finalMin = tempObj.min
                local finalMax = tempObj.max
                local finalCX = (finalMin.x + finalMax.x) / 2.0
                local finalCY = (finalMin.y + finalMax.y) / 2.0
                local p = tempObj.pos

                local errors = #()
                if finalMin == finalMax do append errors "geometrie vide ou degeneree"
                if (abs finalCX) > tol do append errors ("centre X hors tolerance (" + (finalCX as string) + ")")
                if (abs finalCY) > tol do append errors ("centre Y hors tolerance (" + (finalCY as string) + ")")
                if (abs finalMin.z) > tol do append errors ("Z minimum hors tolerance (" + (finalMin.z as string) + ")")
                if ((abs p.x) > tol or (abs p.y) > tol or (abs p.z) > tol) do
                    append errors ("pivot hors tolerance (" + (p as string) + ")")

                if errors.count > 0 then
                (
                    result = #(false, ("validation echouee : " + (efi_joinStrings errors "; ")))
                )
                else
                (
                    -- ---- Textures ----
                    local texOk = efi_redirectTextures tempObj textureFolder blockOnMissing logFn

                    if not texOk then
                    (
                        result = #(false, "texture(s) introuvable(s) dans le dossier configure")
                    )
                    else
                    (
                        -- ---- Dossier de sortie dedie a l'objet ----
                        local objFolder = exportRoot + objName + "\\"
                        if not (efi_folderExists objFolder) do
                        (
                            makeDir objFolder all:true
                            if not (efi_folderExists objFolder) do
                                throw ("impossible de creer le dossier : " + objFolder)
                        )

                        local fbxPath = objFolder + objName + ".fbx"

                        -- ---- Parametres FBX cibles (sans reset global) ----
                        try (FBXExporterSetParam "UpAxis" "Z") catch (logFn "   [INFO] Parametre FBX 'UpAxis' non applique (nom non reconnu par cette version du plug-in FBX)")
                        try (FBXExporterSetParam "SmoothingGroups" true) catch (logFn "   [INFO] Parametre FBX 'SmoothingGroups' non applique")
                        try (FBXExporterSetParam "TangentsAndBinormals" true) catch (logFn "   [INFO] Parametre FBX 'TangentsAndBinormals' non applique")

                        -- ---- Export ----
                        clearSelection()
                        select tempObj
                        local expOk = exportFile fbxPath #noPrompt selectedOnly:true

                        if expOk == false then
                            result = #(false, "echec de exportFile (voir la fenetre Listener)")
                        else if not (doesFileExist fbxPath) then
                            result = #(false, "fichier FBX introuvable apres export")
                        else
                            result = #(true, fbxPath)
                    )
                )
            )
        )
        catch
        (
            result = #(false, ("exception : " + (getCurrentException())))
        )

        -- ---- Nettoyage systematique de la copie temporaire ----
        if tempObj != undefined then
        (
            try (if isValidNode tempObj do delete tempObj) catch ()
        )

        result
    )

    -- ============================================================
    -- INTERFACE
    -- ============================================================
    rollout ExportFBX_Individuel_Rollout "Export FBX individuel - 3ds Max 2025" width:380
    (
        edittext edtFolder "Dossier export :" text:@"D:\Export\" fieldWidth:340
        edittext edtTexFolder "Dossier textures :" text:@"D:\Textures\" fieldWidth:340
        edittext edtScale "Facteur d'echelle :" text:"1.0" fieldWidth:80
        checkbox chkBlockMissingTex "Bloquer l'export si texture introuvable" checked:false
        button btnExport "EXPORTER TOUS LES OBJETS" width:360 height:32
        progressbar prgBar width:360 height:12
        listbox lstLog "Journal :" height:14 width:360

        local logLines = #()

        fn addLog txt =
        (
            append logLines txt
            lstLog.items = logLines
            format "%\n" txt
        )

        on btnExport pressed do
        (
            logLines = #()
            lstLog.items = #()

            local exportRoot = edtFolder.text
            if exportRoot.count > 0 and (substring exportRoot exportRoot.count 1) != "\\" do
                exportRoot += "\\"

            local textureFolder = edtTexFolder.text
            if textureFolder.count > 0 and (substring textureFolder textureFolder.count 1) != "\\" do
                textureFolder += "\\"

            local exportScale = 1.0
            try (exportScale = edtScale.text as float) catch (exportScale = 1.0)

            local blockMissing = chkBlockMissingTex.checked

            if units.SystemType != #Meters do
                addLog "[AVERTISSEMENT] Les unites systeme ne sont pas configurees en metres. Aucune conversion n'est appliquee (voir specification)."

            if not (efi_folderExists exportRoot) do
            (
                makeDir exportRoot all:true
                if not (efi_folderExists exportRoot) do
                    addLog ("[ERREUR] Impossible de creer le dossier racine : " + exportRoot)
            )

            -- Capture de la liste des objets AVANT toute operation :
            -- aucune dependance a la selection courante de l'utilisateur.
            local sourceObjects = for o in objects where efi_isExportableGeometry o collect o
            addLog ("Objets geometriques detectes : " + (sourceObjects.count as string))

            local okCount = 0
            local failList = #()
            local total = sourceObjects.count
            if total == 0 do total = 1

            disableSceneRedraw()
            try
            (
                local i = 0
                for srcObj in sourceObjects do
                (
                    i += 1
                    prgBar.value = 100 * i / total
                    local r = with undo off (efi_exportSingleObject srcObj exportRoot textureFolder exportScale blockMissing addLog)
                    if r[1] == true then
                    (
                        okCount += 1
                        addLog ("OK    : " + srcObj.name + " -> " + r[2])
                    )
                    else
                    (
                        append failList #(srcObj.name, r[2])
                        addLog ("ECHEC : " + srcObj.name + " -- " + r[2])
                    )
                )
            )
            catch
            (
                addLog ("[ERREUR CRITIQUE] " + (getCurrentException()))
            )
            enableSceneRedraw()
            completeRedraw()

            addLog "------------------------------------------------"
            addLog "EXPORT TERMINE"
            addLog ("Objets detectes : " + (sourceObjects.count as string))
            addLog ("Exports reussis : " + (okCount as string))
            addLog ("Echecs           : " + (failList.count as string))
            for f in failList do addLog ("  Echec : " + f[1] + " -- " + f[2])
            addLog ("Dossier d'export : " + exportRoot)
        )
    )

    try (destroyDialog ExportFBX_Individuel_Rollout) catch()
    createDialog ExportFBX_Individuel_Rollout
)
