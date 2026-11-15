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
