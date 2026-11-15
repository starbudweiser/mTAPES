# Premiers chiffres du moteur (15/11/2026)

Méthode : `calcul-lourd .build/release/mtapes bench --seconds 20 --profile P --pixel F`, écran principal 3440 × 1440 (échelle 1),
Mac Apple M5 Max (18 cœurs), macOS 27.2, usage normal du poste pendant la mesure (le contenu de l'écran n'est **pas** contrôlé).
Résultats bruts : `bench/results/*.json`.

| Profil · pixel | Images écrites / perdues | Poids | Débit moyen | Départ | Arrêt | Cœurs (mtapes + encodeur + replayd) | Mémoire pic |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Léger · 8 bits (420v) | 375 / 0 | 6,3 Mo/min | 0,84 Mb/s | 89 ms | 46 ms | 0,044 | 43 Mo |
| **Équilibré · 8 bits (420v)** | 505 / 0 | **10,3 Mo/min** | 1,38 Mb/s | 101 ms | 70 ms | 0,047 | 43 Mo |
| Maximal · 8 bits (420v) | 975 / 0 | 20,6 Mo/min | 2,75 Mb/s | 116 ms | 36 ms | 0,058 | 44 Mo |
| Équilibré · 10 bits (x420) | 505 / 0 | 14,0 Mo/min | 1,87 Mb/s | 106 ms | 67 ms | 0,053 | 43 Mo |

## Lecture
- **Aucune image perdue**, départ ≈ 0,1 s, arrêt ≈ 0,05 s, 43 Mo de mémoire : les objectifs de l'ARCHITECTURE.md §10 sont tenus sur ces prises de 20 s.
- **Processeur** : ≈ 0,05 cœur (5 % d'un cœur) pour mtapes, le service d'encodage et replayd réunis. Marginal par rapport à l'objectif « < 5 % d'un cœur » :
  à surveiller sur un écran très animé.
- **Images adaptatives** : sur 20 s, 396 notifications « rien n'a changé » n'ont rien écrit (Équilibré) ; le poids suit l'activité (Léger 6,3 → Maximal 20,6 Mo/min).
- **10 bits** : fonctionne (encodeur matériel Main10) mais pèse ≈ 36 % de plus à profil égal ; le 8 bits reste le défaut.
- Qualité constante (`kVTCompressionPropertyKey_Quality`) acceptée par l'encodeur matériel HEVC : confirmé par `mtapes doctor`.
- Fichier vérifié à `ffprobe` : HEVC Main, cadence variable (133 images sur 5 s), image clé chaque seconde, durée = durée réelle, fragmenté.

## Limites (à lever avant toute comparaison publique)
- Contenu de l'écran non contrôlé ; scénarios scriptés (écran calme, saisie, défilement, vidéo) à écrire.
- **WindowServer non mesuré** (processus système inaccessible) : le coût réel du système est donc un peu supérieur.
- « Machine » (2,3 à 2,7 cœurs) inclut le bruit des autres programmes : indicatif seulement.
- **Qualité visuelle non mesurée** (SSIM/VMAF contre référence sans perte) ; tenue sur 30 minutes non testée ; capture d'une fenêtre masquée non vérifiée ;
  clics réels non testés à la main (détecteur testé en unitaire).
- Aucune comparaison avec ⌘⇧5, OBS, Cap, Kap, CleanShot X, Screen Studio ou OpenTape pour l'instant : on ne publie que du mesuré.

## Banc d'essai de l'encodeur (séquence synthétique, 15/11/2026)

Séquence source reproductible : 2560 × 1440, 12 s, 481 images à cadence variable (texte qui défile 4 s, écran fixe 4 s, rectangle qui glisse 4 s),
ProRes 422 HQ ; réencodée par `mtapes encode-bench` avec les réglages de chaque profil ; SSIM et PSNR mesurés par ffmpeg contre la source
(après conversion 4:2:0 8 bits des deux côtés). Résultats : `bench/results/encode_*.json`, `bench/results/sweep_q*.json`.

| Profil | Poids (12 s) | Poids par minute | SSIM | PSNR |
| --- | --- | --- | --- | --- |
| Léger (q 0,50) | 2,0 Mo | 10 Mo | 0,9928 | 36,7 dB |
| Équilibré (q 0,65) | 3,7 Mo | 18,5 Mo | 0,9968 | 40,0 dB |
| Maximal (q 0,85, ancien réglage) | 25,4 Mo | 127 Mo | 0,9974 | 42,5 dB |
| Équilibré 10 bits | 10,2 Mo | 51 Mo | 0,9957 | 41,7 dB |

**Balayage de la qualité constante** (8 bits) : le SSIM plafonne vers 0,9975 dès q ≈ 0,70 (5,4 Mo) ; au-delà, le poids explose (q 0,85 : ×4,7)
pour moins de 0,0005 de SSIM et ≈ 1,5 dB de PSNR. **Décision** : Maximal passe de 0,85 à **0,75** (8,6 Mo, PSNR 41,2 dB) ; Léger et Équilibré restent à 0,50 et 0,65.
Le **10 bits** pèse 2,8 fois plus à profil égal pour un SSIM équivalent : il reste réservé à une option, jamais au défaut.

Limites : contenu synthétique (une vraie interface avec ombres, dégradés et vidéo se comportera autrement), la vitesse « ×5,8 temps réel » est bornée par le décodage
ProRes de la source et non par l'encodeur, le SSIM est calculé sur la luminance et les deux chroma après conversion 4:2:0.

## Qualité de la capture réelle (zone 1280 × 720, 12 s, `bench --quality`)

Référence ProRes 4444 des mêmes images (même flux ScreenCaptureKit) ; contenu quasi fixe, donc très peu d'images (7 à 35) : **indicatif seulement**.

| Profil | Images | SSIM | PSNR | Brut |
| --- | --- | --- | --- | --- |
| Léger | 27 | 0,9869 | 39,3 dB | 0,37 Mo |
| Équilibré | 35 | 0,9960 | 47,0 dB | 0,28 Mo |
| Maximal (ancien réglage) | 7 | 0,9983 | 54,3 dB | 0,15 Mo |
