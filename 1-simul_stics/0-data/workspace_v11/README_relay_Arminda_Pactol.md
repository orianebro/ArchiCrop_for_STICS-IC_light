# Relais blé Arminda – maïs Pactol, Auzeville 2006–2007

Scénario exploratoire pluvial préparé le 28 septembre 2026. Les fichiers sont exécutables ; ce n'est pas une calibration de l'association.

## USM

- `Auzeville_Arminda_Pactol_relay_2007` : Arminda (plante 1), Pactol (plante 2), bandes alternées.
- `Auzeville_Arminda_monocrop_2007` : référence blé pur.
- `Auzeville_Pactol_monocrop_2007` : référence maïs pur.

Les trois USM commencent au J268 (25 septembre 2006) et finissent au J730 (31 décembre 2007), avec le même sol, la même initialisation et la même météo. `culturean=0`. Le témoin maïs inclut donc le sol nu avant son semis, sans remise à zéro de l'eau ou de l'azote au printemps.

| Entrée | Association | Blé pur | Maïs pur |
|---|---|---|---|
| Variété | Arminda / Pactol | Arminda | Pactol |
| Indice dans le fichier plante | 1 / 2 | 1 | 2 |
| Semis, jours depuis le 1/1/2006 | 298 / 473 | 298 | 473 |
| Dates | 25/10/2006 / 18/04/2007 | 25/10/2006 | 18/04/2007 |
| Profondeur (cm) | 3 / 5 | 3 | 5 |
| Densité semée, graines/m² de parcelle entière | 115 / 4,25 | 230 | 8,5 |
| Interrang STICS (m) | 6 / 6 | 0,15 | 0,75 |
| `code_strip` | 1 / 1 | 2 | 2 |
| `nrow` | 20 / 4 | 1 (inactif) | 1 (inactif) |
| Azote minéral apporté (kg N/ha de parcelle entière) | 80 + 90 = 170 | 160 | 180 |

Bandes nominales : 3 m de blé et 3 m de maïs, nord–sud (`orientrang=0`). Espacements physiques intrabande : 15 cm pour le blé, 75 cm pour le maïs. Dans STICS strip, `interrang` représente la distance entre centres de bandes de la même espèce (module de 6 m), pas l'espacement entre rangs dans la bande. Le transfert radiatif STICS représente chaque bande comme une enveloppe, pas comme 20 ou 4 rangs distincts.

Le maïs est semé à 8,5 graines/m² de bande pour viser environ 8 plantes/m² après pertes ; la densité levée reste simulée. Les densités de l'association sont divisées par deux à surface de bande 50/50. Les cultures pures conservent les mêmes densités locales.

## Eau, azote et autres interventions

Aucune irrigation, aucun apport organique ni travail du sol explicite. Le sol est supposé prêt à semer ; ces choix évitent de transposer les interventions de l'ancien essai ou de travailler toute la parcelle au milieu du relais.

Fertilisation proposée pour ce scénario (non issue d'un bilan agronomique local validé) :

- Blé pur : J410 = 50, J440 = 70, J465 = 40 kg N/ha.
- Maïs pur : J473 = 40, J510 = 100, J535 = 40 kg N/ha.
- Association : moitié de chacun de ces apports, stockés dans les fichiers techniques des espèces correspondantes. Total 170 kg N/ha.

Les apports sont en surface, engrais de code 3 du `param_gen.xml` existant. Les deux espèces partagent les ressources du sol : l'association d'un apport à un fichier technique ne représente pas une allocation exclusive à cette espèce. Les doses à l'hectare ne sont pas doublées sous prétexte qu'il y a deux cultures.

Pas de dates phénologiques forcées (`codestade=2`, stades à 999), ni de semis automatique. Récolte à maturité physiologique (`codrecolte=1`), option associée 2, butoir J730.

**Correction de l'interprétation de l'option de récolte :** avec le moteur testé, `coderecolteassoc=2` permet deux dates de récolte propres aux espèces ; il n'impose pas une récolte simultanée à la maturité du maïs. Le code ne synchronise `nrec` que pour l'option 1. Les sorties ci-dessous confirment cette distinction.

## Provenance et adaptations explicites

Dossier source : `/Users/rvezy/Documents/cirad/Articles_Rapports_Communications/Articles/5-STICS-new_formalisms/STICS-IC_paper_2022/0-data/usms_v11`.

- `auzevilj.2006`, `auzevilj.2007` : copies identiques, années complètes. Une seule campagne illustrative, pas une évaluation climatique pluriannuelle.
- Sol `Auzeville_relay_2006_2007` : copie de la première occurrence `Auzeville_Fababean_Wheat_2007` du fichier source (qui contient plusieurs occurrences de ce nom). Profil de quatre horizons de 30 cm.
- Initialisation : `Auzeville_SC_2006_ini.xml`, identique pour les trois USM, avec nombre de plantes adapté ; valeurs du cinquième horizon mises à zéro car son épaisseur est nulle. Eau et N des quatre horizons conservés.
- Fichiers techniques : structure de `Auzeville_SC_Wheat_2006_tec.xml`, interventions remplacées par le scénario décrit ci-dessus.
- Station `Auzeville_relay_sta.xml` : copie de `auzevilj_sta.xml`, avec `zr=4 m` au lieu de 2,5 m pour satisfaire la contrainte Shuttleworth–Wallace `zr > hautmax` du maïs. **C'est une hypothèse de station pour ce scénario, pas une hauteur de mesure vérifiée. Les vents du fichier météo n'ont pas été réétalonnés.** Cette hypothèse doit être revue pour une analyse quantitative de l'évapotranspiration.
- `plant/wheat_relay_plt.xml` : copie du `wheat_plt.xml` déjà présent ; phénologie et variétés conservées. Activation du transfert radiatif (`codetransrad=2`). Géométrie manquante reprise du fichier `LOCAL_Wheat_Auzeville_2006_plt.xml` : `forme=1`, `rapforme=3`, `adfol=1.5`, `dfolbas=1`, `dfolhaut=5`. Les `ktrou` manquants sont fixés à 0,5 (valeur de `extin`), hypothèse non calibrée pour Arminda.
- `plant/maize_relay_plt.xml` : copie du `corn_plt.xml` local, y compris ses modifications préexistantes. Les `ktrou` manquants sont fixés à 0,7 (valeur de `extin` et du DK250 local), hypothèse non calibrée pour Pactol.
- Les deux copies plantes utilisent l'approche résistive (`codebeso=2`) requise par la station : `rsmin=137 s/m` pour le blé (fichier local Auzeville 2006 de modulostics), `rsmin=215 s/m` pour le maïs (`Mais_Canada_plt.xml` de modulostics). Ces transferts de paramètres ne constituent pas une validation variétale.

Les copies plantes sont utilisées aussi par les témoins afin de conserver les mêmes paramètres physiologiques. Les fichiers plantes originaux, les USM antérieures, `param_gen.xml`, `param_newform.xml`, `var.mod` et les scripts existants n'ont pas été modifiés par cette préparation.

## Lancement

Depuis la racine du dépôt :

```sh
Rscript 1-simul_stics/0-data/workspace_v11/run_relay.R
```

Le script convertit et lance uniquement ces trois USM dans `1-simul_stics/2-outputs/relay_Arminda_Pactol`. Un argument permet de choisir un autre dossier de sortie. `JAVASTICS_HOME` et `STICS_EXE` permettent de remplacer les chemins locaux par défaut. Nécessite `SticsRFiles` et STICS.

Le script désactive les sorties de profils de sol dans les seuls dossiers générés, car le `prof.mod` partagé demande une date de 2000 hors de cette campagne. Les observations sont absentes par construction : les messages de conversion correspondants sont attendus.

Le générateur existant `2-create_stics_simulations.R` est indépendant : il contient actuellement `maize_temp=4` (Furio) et des géométries propres à son plan d'expérience. Il n'a pas été modifié. Utiliser le lanceur dédié ci-dessus pour reproduire ce scénario Pactol.

## Vérification effectuée

Conversion puis exécution des trois USM avec `stics_modulo_mac`, version annoncée `d47aab032_2026-07-20`, le 28/09/2026. Codes retour 0 ; journaux STICS sans erreur ni avertissement après désactivation des profils hors période. Validation effectuée dans `/tmp/stics_relay_final`.

| Cas | Floraison, jour continu | Maturité | Récolte |
|---|---:|---:|---:|
| Blé associé | 510 | 547 (01/07/2007) | 547 |
| Maïs associé | 554 | 612 (04/09/2007) | 612 |
| Blé pur | 510 | 547 (01/07/2007) | 547 |
| Maïs pur | 552 | 608 (31/08/2007) | 608 |

Ces résultats établissent l'exécutabilité et la cohérence du calendrier, pas la validité des rendements ou du partage du rayonnement. Les paramètres de géométrie, d'extinction et de résistance stomatique restent à vérifier, ainsi que l'hypothèse de hauteur de mesure météorologique.
