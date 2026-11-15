# mTAPES — architecture proposée (non validée, aucun code écrit)

Rédigée le 15/11/2026. Maquettes : `maquettes/index.html` (10 écrans, Socle standard, sombre/clair).

## 1. Technologie

- **Swift natif**, SwiftUI + AppKit, macOS 14 minimum (Mac de Stéphan : 27.2). Même chaîne que mBACKUP : `build_app.sh`,
  `sign_app.sh`, `release.sh`, `Updater.swift`, `About.swift`, `L10n.swift`, `Socle.swift`.
- **Capture : ScreenCaptureKit** (`SCStream`, `SCContentFilter`).
  - Écran : filtre sur un `SCDisplay`. Fenêtre : filtre sur une `SCWindow`, qui filme la fenêtre **même masquée** par d'autres.
  - Application : filtre sur une `SCRunningApplication` (toutes ses fenêtres, ou celles choisies).
  - Zone : `sourceRect` sur l'écran, avec exclusions (`exceptingApplications`) : mTAPES, notifications, apps choisies.
  - `showsCursor = false` : le curseur n'est **jamais** dans l'image brute, il est redessiné à la finition (lissage, taille, effet de clic).
- **Écriture du brut** : encodeur matériel HEVC 10 bits à images adaptatives, fichier fragmenté (détail au §10, « Moteur d'enregistrement »). ProRes 422 reste possible en option.
- **Clics et clavier réels** : `CGEventTap` en écoute seule (permission « Surveillance de l'entrée »), échantillonnage du pointeur à 120 Hz.
- **Rendu** : compositeur Metal (`AVVideoComposition` personnalisé) pour l'aperçu temps réel et l'export MP4 ; GIF par
  ImageIO + quantification (ou `ffmpeg` si présent, repli) ; HEVC/H.264 par `AVAssetWriter`.
- **Pas de Tauri, pas d'Electron** : pas de moteur web, pas de pont, empreinte faible, silence garanti (voir §6).

## 2. Modules (un dossier `Sources/` par module)

| Module | Rôle |
| --- | --- |
| `Capture` (moteur, §10) | `CaptureEngine` (SCStream → VideoToolbox → fichier fragmenté), `TargetCatalog` (écrans, fenêtres, applis), `WindowTracker` (suit déplacement et taille d'une fenêtre filmée), `ZoneOverlay` (tracé de zone, `NSPanel` non activant sur chaque écran) |
| `Input` | `EventRecorder` (CGEventTap + pointeur), `ActionLog` (actions annoncées par une IA), fusion des deux en une seule ligne de temps |
| `Take` | `TakeStore` : dossier `.tape` (paquet), index de la bibliothèque, miniatures, suppression |
| `Finishing` | `Planner` (événements → zooms, temps morts, curseur), `FinishingSpec` (modèle JSON), `Compositor` (Metal), `Preview` |
| `Export` | `ExportQueue` (un rendu à la fois), encodeurs GIF et MP4, préréglages de destination |
| `MCP` | `mtapes-mcp` (processus auxiliaire stdio), `Bridge` (socket Unix vers l'appli), `HTTPServer` local facultatif |
| `UI` | SwiftUI au design Socle : Bibliothèque, Finition, Export, Pilotage IA, Réglages (5 onglets), « À propos » |
| `Presence` | icône de barre de menus (style au choix, états), Dock, menu ouvert par `statusItem.socleShow(menu)` (jamais `statusItem.menu`) |
| `Edit` (montage IA, §16) | `Summarizer`, `EditPlan`, `PlanValidator`, `HeuristicBrain`, `EditBrain` (Apple, local, clé, agent MCP), `Perception` (OCR local) |
| `Setup` | assistant de configuration (§11), détection des permissions et des clients IA, test de bout en bout |
| `CLI` | `mtapes` en ligne de commande : `record`, `finish`, `export`, `list`, `doctor`, `bench` (§13) |
| `Bench` | banc d'essai reproductible contre les autres enregistreurs (§14) |
| `Support` | `Settings` (UserDefaults typés), `L10n` (fr/en/es/it, mêmes clés), `Updater`, `Permissions` |

## 3. Format des données : le paquet `.tape`

Une prise = un dossier `~/Movies/mTAPES/<nom>.tape/`, jamais modifié après l'arrêt, sauf `finition.json`.

```
<nom>.tape/
  meta.json         id, nom, date, origine ("manual" | "mcp"), client IA, source {type, écran, fenêtre, appli, cadre, échelle},
                    fps, durée, langue
  raw.mov           brut sans curseur (HEVC ou ProRes)
  events.jsonl      une ligne par événement : {"t":12.480,"kind":"click","x":412,"y":188,"button":"left",
                    "source":"detected|declared","label":"Choisir un dossier"}
                    kinds : click, doubleclick, rightclick, drag, scroll, key, type, chapter, window (cadre de la fenêtre suivie)
  pointer.bin       trajectoire du pointeur 120 Hz (t, x, y) pour le lissage
  finition.json     calque non destructif : préréglage, ratio, fond, cadre, curseur, effet de clic, zooms[], vitesses[], textes[]
  exports/          fichiers produits + journal
```

- **Finition non destructive** : `finition.json` seul change ; « Refaire la mise en scène » relance le `Planner` sans toucher au brut.
- **Préréglages** : `~/Library/Application Support/mTAPES/Presets/*.json` (README, Release, Short fournis). Un préréglage = valeurs
  de Réglages (Zoom, Clics et curseur, Cadre) + destination(s) d'export.
- **Réglages de l'appli** : UserDefaults, mêmes clés que les onglets Capture, Zoom, Clics et curseur, Icône, Général.

## 4. Pipeline de finition

1. **Arrêt** → `events.jsonl` et `pointer.bin` fermés, brut finalisé.
2. **Planner** : regroupe les actions proches (< 2 s) en un zoom ; cadre = boîte englobante élargie, grossissement borné par le
   maximum ; courbe (douce, ressort, linéaire) ; suivi du curseur ou de l'action ; marge de sécurité aux bords ; reste 0,8 s après la
   dernière action ; ignore les doubles-clics < 0,3 s.
3. **Temps morts** : plage sans événement et à faible différence d'image > 1,5 s → accélérée ×4 (jamais sous un chapitre).
4. **Curseur** : trajectoire lissée (Aucun, Léger, Moyen, Fort), taille, ombre, ralenti avant un clic ; **effet de clic** (Onde, Halo,
   Pulsation, Cible, Aucun ; couleur, taille, durée, épaisseur, opacité).
5. **Cadre** : fond (dégradé, uni, image), marge, arrondi, ombre ; ratio **16:9, 9:16 ou 1:1** (en 9:16 le cadre suit l'action).
6. **Aperçu** temps réel Metal dans la fenêtre Finition ; chaque bloc (zoom, vitesse, texte) se retouche à la main.
7. **Export** : une destination = un préréglage (README → GIF ≤ 10 Mo ; Release → MP4 H.264 1080p ; Short → MP4 HEVC 9:16). Plusieurs
   à la fois. Rendus **un par un** par la file ; sur ce Mac, l'appli passe par `calcul-lourd` s'il est présent (sinon file interne).

## 5. Interface MCP (ouverte à toute IA)

Processus auxiliaire `mtapes-mcp` dans `Contents/MacOS/`, protocole MCP (JSON-RPC 2.0) en **stdio** ; il parle à l'appli par un
**socket Unix** `~/Library/Application Support/mTAPES/mcp.sock` (droits 600). **HTTP local** facultatif (`127.0.0.1`, jeton obligatoire,
désactivé par défaut) pour les clients qui ne lancent pas de commande. Raccordement en un clic (Claude Code, Claude Desktop, Codex,
Cursor, Gemini CLI) ou commande à copier, depuis l'écran Pilotage IA.

| Outil | Paramètres (résumé) | Retour |
| --- | --- | --- |
| `tapes_list_targets` | `kind?` (display, window, app) | écrans, fenêtres (titre, appli, cadre), applis ouvertes |
| `tapes_start` | `target` (écran, fenêtre, appli ou zone), `preset?`, `name?`, `audio?`, `max_seconds?` | `tape_id` |
| `tapes_mark` | `tape_id`, `kind` (click, type, scroll, key, chapter), `x?`, `y?`, `space` (screen, window), `label?`, `at?` | `ok` |
| `tapes_status` | `tape_id` | état, durée, marques, avertissements |
| `tapes_stop` | `tape_id`, `finish` (défaut vrai), `wait?` | chemin du `.tape`, état de la finition |
| `tapes_finish` | `tape_id`, `preset?`, surcharges (zoom, curseur, cadre) | chemin de `finition.json` |
| `tapes_export` | `tape_id`, `destinations[]` (readme, release, short, ou format libre) | chemins des fichiers, tailles |
| `tapes_list` / `tapes_get` | filtres | prises et leurs fichiers |
| `tapes_delete` | `tape_id` | suppression après confirmation dans l'appli |

- **Marques d'actions** : l'IA connaît ses clics ; elle les annonce (`tapes_mark`) avec libellé, les zooms suivent ce journal
  (source « declared »), recoupé avec les clics réels détectés. Les coordonnées « fenêtre » sont converties grâce au `WindowTracker`.
- **Silence** : l'appli est en mode accessoire pendant une prise pilotée, aucune fenêtre, aucune activation, aucun focus volé.
- **Sécurité** : accord de l'utilisateur à la **première prise de chaque client**, cible limitée aux fenêtres d'applis par défaut
  (écran entier à autoriser dans Réglages), durée maximale, journal des commandes consultable, suppression toujours confirmée côté appli.
- **Ressources** : `tapes://<id>` (meta et marques) en lecture seule.
- Un fichier `SKILL.md` livré avec l'appli (et un skill Claude Code) décrit le bon enchaînement : start → pilotage + marks → stop → export.

## 6. Silence, permissions, performance

- Autorisations : Enregistrement de l'écran (obligatoire), Surveillance de l'entrée (clics réels), Accessibilité (encadrer l'élément
  cliqué, facultatif). Signature stable `sKYCRASH Local Signing` : pas de redemande à chaque build.
- Aucun `activate`, aucun `makeKeyAndOrderFront` pendant une prise ; le tracé de zone utilise un `NSPanel` non activant.
- Édition de test = premier lancement d'un acheteur (bundle et dossier de données distincts, remise à zéro).

## 7. Build, livraison, équivalences avec mBACKUP

- Bundle `fr.stephan.mtapes` ; développement `fr.stephan.mtapes.dev` ; `build_app.sh` dans le dépôt ; ajout à la liste APPS de
  `_tools/build_all.sh` ; installation dans `~/Applications/Applications Personnelles`.
- Mise à jour automatique (modèle `mBACKUP/Sources/Updater.swift`, clés `upd.*`), « À propos » (modèle mDESK), README avec
  section « About » en anglais, `release.sh` (notarisation `notarize_app.sh`), dépôt GitHub `starbudweiser/mTAPES`.
- Quatre langues, mêmes clés ; test de traductions vérifiant toutes les clés (dont `about.*`).
- Nom : le « m » minuscule prend la couleur de l'icône (jamais dans un menu déroulant).
- **Collection** : mTAPES fait partie du **DESKTOP MAC TOOLKIT** (toutes les applis de Stéphan hors Skyrim). Le nom de la collection figure dans la fenêtre « À propos » (entre la description et les auteurs, texte non traduit), dans la section « About » du README (« Part of the DESKTOP MAC TOOLKIT ») et dans la communication de l'appli. Installation inchangée : `~/Applications/Applications Personnelles`.

## 8. Étapes proposées (après validation)

1. Capture + paquet `.tape` + bibliothèque (écran, fenêtre, zone, application ; enregistrement à la main).
2. Journal d'événements + Planner + aperçu Finition (zooms, curseur, effet de clic, cadre).
3. Export (GIF, MP4, 16:9 et 9:16) + file de rendu.
4. MCP (`mtapes-mcp`, pont, outils, accord par client) + skill d'usage.
5. Réglages complets, icône (états), 4 langues, « À propos », mise à jour automatique.
6. Finition de la v1 : captures comparées aux maquettes, test d'une démo complète pilotée par Claude, notarisation sur demande.

## 9. Risques

- Surveillance de l'entrée refusée → zooms fondés sur les seules actions annoncées (déjà prévu) ; prise à la main moins précise.
- Fenêtre filmée qui change d'écran ou d'échelle en cours de prise → `WindowTracker` + recadrage ; à tester tôt.
- GIF ≤ 10 Mo à 960 px : palette adaptative et 15 i/s ; l'export propose de réduire jusqu'à tenir sous la limite.
- Aperçu Metal 60 i/s sur un brut 2560 × 1600 : proxys de lecture si besoin.

---

# Ajouts du 15/11/2026 : ergonomie, modes, assistant, moteur, positionnement

## 9. Ergonomie : règles de conception

1. **Enregistrer en trois clics au plus** : quoi filmer, quel style, Enregistrer (⌘⇧5). Tout le reste est automatique.
2. **Deux modes, une seule appli.** Interrupteur « Simple | Avancé » en haut à droite de chaque fenêtre et dans Réglages ; le mode se change à tout moment sans perdre de prise.
3. **Un seul appel principal par écran** (ambre) ; boutons de progression toujours à la même place ; chaque état (repos, en cours, terminé, erreur, vide) est dessiné.
4. **L'interface dit vrai** : autorisations lues en direct, poids estimés avant export puis mesurés après, état du serveur MCP réel.
5. **Rien n'est irréversible** : finition non destructive, suppression confirmée, annulation partout, prise de test supprimée seule.
6. **Aucune coupure** : mise en page fluide, fenêtre minimale 900 × 560, aucun texte tronqué, aucun élément rogné sur les côtés ou en bas. Un **audit automatique** (`tests/layout_audit`, même principe que le script utilisé sur les maquettes) mesure les débordements à 900, 1000 et 1300 px dans les quatre langues (l'italien est le plus long) et fait échouer le build.
7. **Accessibilité** : VoiceOver, navigation au clavier complète, « réduire les animations », contraste 4,5:1, thèmes clair et sombre.
8. **Silence** : aucune fenêtre ne passe devant le travail, aucun focus volé, en prise manuelle comme pilotée.
9. **Mots d'usage en mode Simple et dans l'assistant** : jamais de jargon de développeur. « README GitHub » devient **Page de présentation (GitHub)**, « Release » devient **Publication d'une version** (« Nouvelle version » dans les puces), « Short » devient **Vidéo verticale (réseaux)**. Le mode Avancé garde les termes de GitHub (README, Release, Short), avec une info-bulle qui renvoie au mot d'usage. Même règle pour HEVC, VFR, MCP, LLM : absents du mode Simple. Les quatre langues suivent la même table (`L10n`, clés `dest.*`).

## 10. Moteur d'enregistrement (module `Capture`)

Objectif : une qualité visuelle maximale pour un fichier le plus léger possible, avec un coût processeur quasi nul. Les valeurs ci-dessous sont des **objectifs mesurés par le banc d'essai** (§14), pas des résultats : rien n'est affirmé avant d'être mesuré.

### Chaîne de capture
- **ScreenCaptureKit** : `SCStream` sur filtre écran, fenêtre, application ou zone (`sourceRect`), curseur absent de l'image (`showsCursor = false`), résolution native, format de pixel 4:2:0 (10 bits quand disponible) pour éviter une conversion couleur coûteuse, file de tampons de 5 à 8 images.
- **Images adaptatives (VFR)** : ScreenCaptureKit ne livre une image que si le contenu a changé ; le moteur écrit les horodatages réels et **ne duplique jamais une image**. Un écran calme coûte presque zéro octet ; un écran animé reçoit tout le débit.
- **Zéro copie** : tampon IOSurface de SCK → `VTCompressionSession` matériel (HEVC, moteur média d'Apple Silicon) → échantillons compressés écrits tels quels (`AVAssetWriter` sans ré-encodage). Pas de passage par le processeur ni par la mémoire principale.
- **Files d'attente dédiées**, priorité temps réel, **aucun travail d'interface dans le chemin de capture** ; contre-pression comptée (images perdues, retard d'encodeur) et affichée dans le diagnostic.
- **Fichier fragmenté** (fragment de 2 s) : une panne de courant ou un plantage laisse un brut lisible ; récupération proposée au prochain lancement.
- **Image clé chaque seconde** (et aux changements de scène) : défilement et aperçu fluides dans la finition sans recalcul.
- **Qualité constante** (`kVTCompressionPropertyKey_Quality`, confirmée sur le matériel : 0,50 Léger, 0,65 Équilibré, 0,75 Maximal, réglages tirés d'un balayage mesuré, voir `bench/RESULTS.md`), repli sur un débit moyen contraint ; profil « Léger / Équilibré / Maximal / Sur mesure » réglé en un clic.
- **Son** : micro (`captureMicrophone`, macOS 15+) et son du Mac par SCK, AAC, pistes séparées.
- **Suivi de fenêtre** : `WindowTracker` suit déplacement, redimensionnement et changement d'écran ; recadrage sans coupure dans le brut.
- **Événements à part** : clics, clavier et trajectoire du pointeur (120 Hz) dans `events.jsonl` et `pointer.bin`, hors de l'image.

### Pourquoi le résultat est net et léger
- **Curseur redessiné** à la finition en vectoriel : toujours net, même à 2× de zoom, indépendant des images/s de la vidéo.
- **Zoom net** : le brut est à la résolution native ; un zoom ne grossit pas des pixels tant qu'il reste dans la définition d'origine, au-delà mise à l'échelle Lanczos sur le GPU (Metal Performance Shaders).
- **Une seule génération** : chaque export part du brut, jamais d'un export précédent, donc aucune perte cumulée.
- **Export léger** : encodeurs matériels (H.264, HEVC), suppression des images dupliquées, accélération des temps morts, cible de taille résolue par **sondage sur échantillons** (on ajuste débit, échelle et cadence jusqu'à tenir sous la limite) ; contrôle SSIM sur images témoins pour ne pas dégrader sous un seuil.
- **GIF léger** : encodeur maison (palette adaptative par plan, tramage à bruit bleu, images différentielles avec transparence, compression LZW optimisée), repli WebP animé ; objectif d'un GIF de démonstration de README sous 10 Mo.

### Objectifs à tenir (mesurés sur Apple Silicon, écran 2560 × 1600)
| Mesure | Objectif |
| --- | --- |
| Processeur pendant une prise, interface calme | < 5 % d'un cœur performant |
| Images perdues sur une prise de 30 minutes | 0 |
| Délai entre Enregistrer et la première image | < 0,5 s |
| Délai entre Arrêter et l'aperçu de finition | < 1,5 s |
| Poids du brut, profil Équilibré, interface calme | de l'ordre de 10 à 15 Mo par minute |
| Mémoire résidente pendant une prise | < 400 Mo |
| GIF de 60 s pour un README | < 10 Mo, qualité visuelle contrôlée |

## 11. Modes et assistant de configuration

### Mode Simple (débutant)
- Une fenêtre : « Que voulez-vous filmer ? » (écran, fenêtre, zone) · « Quel style ? » (Sobre, Dynamique, Vertical) · **Enregistrer**.
- Fin de prise : la vidéo est déjà finie ; trois gros boutons (copier le GIF du README, enregistrer en MP4, version verticale) avec le **poids estimé** ; « Retoucher » ouvre la même prise en mode Avancé ; « Recommencer ».
- Aucun vocabulaire technique (pas de « HEVC », « VFR », « MCP ») ; les profils s'appellent Léger, Équilibré, Maximal.

### Mode Avancé (IA / MCP)
- Bibliothèque complète, finition par blocs (zooms, vitesses, textes), exports multiples, réglages Capture, Qualité, Zoom, Clics et curseur, Icône, Général.
- **Pilotage IA** : clients MCP, journal des commandes, prise en cours, invite prête à copier, test de connexion, accord par client.
- Le serveur MCP est **désactivé en mode Simple** sauf choix « Les deux » dans l'assistant.

### Assistant de configuration (5 étapes)
1. **Bienvenue** : Simple, Avancé · IA, ou les deux.
2. **Autorisations** : Enregistrement de l'écran (obligatoire), Surveillance de l'entrée (recommandée), Accessibilité et Micro (facultatives). Lecture en direct (`CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`, contrôle d'accès à l'entrée), sondage chaque seconde, boutons qui ouvrent le bon volet de Réglages Système, relance automatique de l'appli quand macOS l'exige.
3. **Usage** : destinations (README, Release, Short) et style ; crée les préréglages d'export correspondants.
4. **Votre IA** (Avancé) : détection de Claude Code, Claude Desktop, Codex, Cursor, Gemini CLI d'après leurs fichiers de configuration ; **Raccorder** écrit l'entrée MCP après aperçu des changements et sauvegarde du fichier ; sinon commande à copier. **Test de bout en bout** : prise de 3 s pilotée, finition, export, puis suppression.
5. **Prêt** : récapitulatif et prise d'essai de 5 s.
- Lancé au premier démarrage, relançable depuis Réglages > Général et depuis l'écran Pilotage IA.

## 12. Interface en ligne de commande et format ouvert

- **`mtapes`** (dans le paquet, installable dans le PATH) : `record`, `finish`, `export`, `list`, `doctor` (permissions, encodeur matériel, serveur MCP), `bench`. Mêmes réglages que l'appli ; utilisable dans un script ou une intégration continue pour **régénérer toutes les démos à chaque release**.
- **Format `.tape` documenté** (`docs/TAPE_FORMAT.md`, versionné) : d'autres outils et d'autres IA peuvent produire ou lire une prise.
- **Skill et invite fournis** : `SKILL.md` pour Claude Code et invite prête à copier pour les autres IA.

## 13. Positionnement : ce qui doit la rendre incontournable

Personne ne peut promettre d'être « le meilleur » ; la stratégie est de gagner sur ce qui se **mesure** et se **vérifie** :
1. **Seule à piloter l'enregistrement par MCP**, avec des zooms fondés sur le journal d'actions de l'IA.
2. **Fichiers les plus légers** à qualité visuelle égale (images adaptatives, encodage matériel, GIF optimisé), prouvé par le banc d'essai.
3. **Locale, gratuite, libre (MIT), sans compte ni nuage**, signée et notarisée.
4. **Deux publics, une appli** : débutant en trois clics, expert et IA en mode Avancé, avec un assistant qui prend la main.
5. **Prise non destructive** et format ouvert : on refait la finition sans refilmer.
6. **Fiabilité** : fichier fragmenté, récupération après plantage, zéro image perdue visé, mesures affichées.
7. **Preuve par l'usage** : les démos du README de mTAPES et des applis de Stéphan sont produites par mTAPES.

Parité à prévoir pour ne pas être distancée par les logiciels commerciaux (hors v1, par ordre de valeur) : bulle webcam, sous-titres automatiques locaux, floutage de zones sensibles (champs mot de passe, notifications), annotations, fonds et cadres en bibliothèque, mise à l'échelle des appareils (cadre d'iPhone, de Mac).

## 14. Banc d'essai (module `Bench`, `mtapes bench`)

- **Scénarios scriptés et reproductibles** : écran calme, saisie de texte, défilement, vidéo en lecture, interface très animée.
- **Mesures** : processeur et énergie, images perdues, débit, poids du fichier, délai de démarrage et d'arrêt, qualité par rapport à une référence sans perte (SSIM, PSNR, VMAF), poids d'un GIF au même score visuel.
- **Comparaison** avec ⌘⇧5 / QuickTime, OBS, Cap, Kap, CleanShot X, Screen Studio et OpenTape, dans les mêmes conditions ; résultats publiés dans le README avec la méthode, et **seuls les chiffres mesurés** y figurent.
- Le banc sert aussi de test de non-régression : une version qui dégrade poids, qualité ou images perdues ne passe pas.

## 15. Étapes révisées

1. **Moteur** : capture adaptative, encodeur matériel, fichier fragmenté, paquet `.tape`, premiers chiffres du banc d'essai (avant toute interface riche).
2. Bibliothèque, mode Simple, assistant (autorisations d'abord).
3. Événements, Planner, finition et aperçu (mode Avancé).
4. Export léger (GIF, MP4, sondage de taille), file de rendu.
5. **Montage IA** : résumé, plan, validateur, montage par règles, Apple Intelligence, guide du brief (§16).
6. MCP, CLI, test de bout en bout, skill ; moteurs local et clé personnelle.
7. Réglages complets, icône, quatre langues, « À propos », mise à jour automatique, audit de mise en page.
8. Banc d'essai complet (dont qualité des plans), README avec résultats, notarisation et release publique.

## 16. Montage automatique par IA (« must have »)

**Promesse : une prise, un bouton, une vidéo prête.** Philosophie Apple : une seule action visible, de bonnes valeurs par défaut, des détails qui se révèlent seulement si on les cherche, un retour immédiat, tout est annulable, la confidentialité par défaut.

### Principes d'expérience
1. **Résultat instantané, amélioration ensuite** : à l'arrêt de la prise, le montage **par règles** (temps morts, zooms, textes d'après les libellés) s'affiche en moins de 3 s ; le plan de l'IA le remplace en transition dès qu'il est prêt, sans bloquer.
2. **Un brief en un clic** : pas de page blanche ; objectif, durée, ton et priorité se choisissent (puces et segments), le brief s'écrit tout seul en une phrase modifiable.
3. **Trois variantes** (Court, Équilibré, Détaillé), aperçu de chacune, poids estimé ; on garde celle qu'on aime.
4. **« Pourquoi ce montage ? »** : chaque décision est expliquée et s'annule seule ; « Annuler le montage IA » revient à la prise brute en un clic.
5. **Vocabulaire sans jargon** : « montage automatique », jamais « LLM » ni « prompt » dans le mode Simple ; le mode Avancé montre le moteur utilisé.
6. **Dire vrai** : l'écran indique toujours quel moteur a servi, s'il a basculé sur un autre et pourquoi.

### Principe technique : l'IA ne produit qu'un plan, jamais des pixels
```
.tape (événements, libellés, chapitres, durée)
  └─ Summarizer ── résumé compact (≈ 1 500 jetons) ─▶ EditBrain ─▶ EditPlan (JSON typé)
                                                         ▲               │
                           brief (objectif, durée, ton, priorité)        ▼
                                                                 PlanValidator ─▶ Planner ─▶ finition.json ─▶ rendu Metal
```
- **`Summarizer`** : transforme la prise en texte court (actions datées avec libellés, écarts sans action, répétitions suspectes, chapitres, titres de fenêtre). Jamais d'image par défaut.
- **`EditPlan`** (schéma versionné) : `keep[]` (plages gardées), `speed[]`, `zooms[]` (instant, cible, grossissement), `captions[]` (plage + texte), `chapters[]`, `titleCard?`, `targetDuration`, `rationale[]` (une phrase par décision, pour « Pourquoi ? »).
- **`PlanValidator`** (déterministe) : plages dans les bornes et sans chevauchement, durée à ±10 % de la cible, grossissement ≤ maximum, textes bornés en longueur et **tirés des libellés ou du texte lu à l'écran** (aucune légende inventée), langue demandée. Un plan invalide est corrigé ou refusé, puis repli sur le montage par règles.
- **Stockage** : `plan.ai.json` dans le paquet `.tape` (moteur, version du prompt, brief, plan) ; la finition marque chaque bloc `source: "ai:<moteur>"` : reproductible, annulable bloc par bloc, jamais destructif.
- **Variantes** : un appel par cible de durée (ou un appel renvoyant trois plans) ; le montage par règles produit les siennes par seuils.

### Moteurs, du plus gratuit et privé au plus ouvert (`EditBrain`)
| Ordre en mode Automatique | Moteur | Coût | Données |
| --- | --- | --- | --- |
| 1 | **Apple Intelligence sur l'appareil** (framework FoundationModels, génération guidée `@Generable` vers `EditPlan` ; disponibilité testée par `SystemLanguageModel.default.availability`) | gratuit | ne quitte pas le Mac |
| 2 | **Modèle local** compatible OpenAI (Ollama `127.0.0.1:11434`, LM Studio `1234`), détecté par sondage ; sortie contrainte par schéma JSON ; vision facultative (images clés) | gratuit | ne quitte pas le Mac |
| 3 | **Mon IA via MCP** (Claude Code, Codex, Cursor) : `tapes_summary` puis `tapes_apply_plan`, ou `tapes_auto_edit` | abonnement déjà payé | selon l'IA choisie |
| 4 | **Clé personnelle** d'un service à offre gratuite (Gemini, OpenRouter, etc.), clé au Trousseau ; quotas gérés, bascule au suivant si dépassé | gratuit selon le quota (les conditions changent : rien n'est codé en dur) | texte seulement, après accord, aperçu exact de l'envoi |
| repli | **Montage par règles** (`HeuristicBrain`) | gratuit | local, toujours disponible |

- Contraintes à vérifier au développement : taille du contexte et langues du modèle sur l'appareil (le résumé est donc compact ; prises longues découpées par chapitre puis fusionnées), disponibilité selon la version de macOS et le réglage d'Apple Intelligence.
- **Aucun moteur payant imposé** ; tout fonctionne avec les règles seules, l'IA améliore.

### Lecture de l'écran, gratuite et locale (`Perception`)
- **OCR Vision** (`VNRecognizeTextRequest`) sur quelques images clés autour des clics pour **nommer** l'élément cliqué (« Sauvegarder ») quand aucune IA n'a annoncé ses actions : les prises à la main deviennent éligibles au montage sans modèle de vision.
- **Accessibilité** (facultatif, autorisation dédiée) pour un nom d'élément plus précis et son cadre.

### Guide du brief (livré dans l'appli, quatre langues)
- **Quatre ingrédients** : Objectif · Durée · Ton · Priorité (et ce qu'il faut ignorer).
- **Six exemples prêts à l'emploi** (README rapide, Release, Short vertical, Tutoriel, Sans les erreurs, En anglais), bouton « Utiliser ».
- **À éviter** : consignes vagues, demandes d'invention, plusieurs objectifs à la fois.
- **Invite prête à copier pour une IA externe** (MCP) et `SKILL.md` à jour ; **« Ce que l'IA ne fait jamais »** : toucher aux pixels, inventer un texte, supprimer sans retour arrière, envoyer hors du Mac sans accord.
- Le prompt système de l'appli est **fixe, versionné** (`Prompts/edit_plan.v1.*`), sortie structurée seulement, température basse.

### Confidentialité et coût
- Par défaut tout reste sur le Mac ; un envoi hors du Mac exige un moteur ajouté par l'utilisateur, un accord et l'aperçu exact du texte transmis ; texte seulement, jamais d'image, sauf choix contraire.
- Coût par défaut : **0 €**, sans compte.

### Évaluation (dans le banc d'essai, §14)
- Jeu de prises de référence avec résumés figés ; mesures par moteur : **taux de plans valides**, écart de durée par rapport à la cible, part des actions étiquetées couvertes par un zoom ou un texte, temps de génération, taux de repli. Un moteur ou un prompt qui dégrade ces mesures ne passe pas.
- Objectifs : aperçu par règles < 3 s ; plan IA sur l'appareil < 10 s pour une prise de 2 minutes ; plans valides ≥ 99 % après validation (à mesurer).
