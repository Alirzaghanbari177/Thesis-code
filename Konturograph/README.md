# Konturograph – Bolzenhalter v7 (flach) + Seitenschale v1

## Dateien
| Datei | Inhalt |
|---|---|
| `Konturograph_v7_erzeugen.iLogicVb` | iLogic-Regel: erzeugt in Inventor die **nativen .ipt-Dateien** (+ Baugruppe .iam) |
| `Bolzenhalter_Flach_28Loch_v7.step` | Hauptblock als STEP (Inventor öffnen → als .ipt speichern) |
| `Bolzen_Seitenschale_v1.step` | Seitenschale als STEP |
| `Konturograph_Baugruppe.step` | beide Teile zusammen (eingeschoben) |
| `Vorschau_*.png` | Vorschaubilder |

## So entsteht die .ipt (empfohlen: iLogic, parametrisch, mit Features)
1. Inventor öffnen, ein beliebiges Teil öffnen oder neu anlegen.
2. **Verwalten → iLogic → Regel hinzufügen**, Inhalt von `Konturograph_v7_erzeugen.iLogicVb` einfügen.
3. **Ausführen** → speichert nach `D:\AAM\Konturograph\`:
   `Bolzenhalter_Flach_28Loch_v7.ipt`, `Bolzen_Seitenschale_v1.ipt`, `Konturograph_Baugruppe_v7.iam`.
   (Ordner ändern: Konstante `ORDNER` oben in der Regel.)

Alternative ohne iLogic: STEP-Datei in Inventor öffnen → **Speichern unter → .ipt** (dann ohne Feature-Historie).

## Maße
**Hauptblock** 310 × 310 × 100 mm, oben flach (keine Treppe)
- 4 Reihen × 7 = **28 Bohrungen Ø20 mm**, Sackloch 50 mm tief → unten 50 mm massiv (stabil wie v6)
- Rand Lochkante → Außenkante 17,5 mm (15 < x < 20), Teilung 42,5 mm (X) / 85 mm (Y)
- rechte Seite: Schwalbenschwanznut 60°, Breite 16 mm, Tiefe 6 mm, Mitte 75 mm über Boden, durchgehend

**Seitenschale (tragbar)** 150 × 120 × 50 mm, Oberkante bündig mit dem Block
- wird seitlich von vorne/hinten in die Nut eingeschoben (Feder links, 0,2 mm Spiel pro Seite)
- vordere Zone, 2 Reihen, 12 mm tief:
  Reihe 1 (zum Fach): Ø1,5 / Ø1 / Ø2,5 mm – Reihe 2 (vorne): Ø3 / Ø2,5 / Ø1,5 mm
- Rest: leeres Fach 112 × 82 × 35 mm, Wand 4 mm
