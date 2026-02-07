# Language Learning - Android App

Mobilní aplikace pro učení angličtiny metodou spaced repetition (opakování s rozestupy).

**Autor:** David Petrov

## Co aplikace umí

### Kartičky
- Zobrazuje anglické fráze a jejich české překlady
- Načítá data ze souboru `cards.json` (795 kartiček z kategorie "Gramatika věty")
- Přehled všech kartiček v barevné mřížce (ikona mřížky vpravo nahoře)

### Směr učení
- **EN → CZ**: Vidíte anglicky, hádáte česky
- **CZ → EN**: Vidíte česky, hádáte anglicky

### Výslovnost (Text-to-Speech)
- Tlačítko 🔊 přehraje anglickou výslovnost
- Používá Google TTS (zdarma, offline)

### Přehled kartiček
Barevná mapa všech kartiček podle úspěšnosti:
- **Šedá** - nová (ještě nezkoušená)
- **Červená** - těžká (interval 1 den)
- **Oranžová** - učí se (interval 2-6 dní)
- **Zelená** - dobrá (interval 7-21 dní)
- **Modrá** - naučená (interval 21+ dní)

## SM-2 Algoritmus (Spaced Repetition)

Aplikace používá algoritmus **SM-2** (SuperMemo 2), stejný jako Anki.

### Jak funguje:
1. **První opakování** → interval 1 den
2. **Druhé opakování** (úspěšné) → interval 6 dní
3. **Další opakování** → interval × ease factor (2.5)

### Hodnocení:
- **Znovu** - nepamatuju si, ukázat znovu zítra
- **Těžké** - vzpomněl jsem si těžko
- **Dobře** - vzpomněl jsem si
- **Snadné** - bylo to jednoduché

### Ease factor:
- Špatné odpovědi → ease klesá, intervaly se zkracují
- Dobré odpovědi → ease roste, intervaly se prodlužují

Výsledek: kartičky které znáte se ukazují méně často (1 den → 6 dní → 15 dní → měsíc → 2 měsíce...).

## Jak spustit

### Vývoj (debug mode)
```bash
cd c:\Cloud\AI\English\mobil_projekt
flutter run
```

### Vytvoření APK pro instalaci
```bash
flutter build apk
```
APK soubor bude v: `build/app/outputs/flutter-apk/app-release.apk`

## Hot reload
Při běžící appce v debug mode:
- `r` = hot reload (rychlá aktualizace)
- `R` = hot restart (restart celé appky)
- `q` = ukončit

## Struktura projektu
```
mobil_projekt/
├── lib/
│   └── main.dart          ← hlavní kód aplikace
├── assets/
│   └── cards.json         ← kartičky (z XLSX)
└── pubspec.yaml           ← závislosti (flutter_tts, shared_preferences)
```

## Aktualizace kartiček
1. Upravte XLSX soubor na Google Drive
2. Spusťte `python convert_xlsx.py` v pc_projekt složce
3. Zkopírujte nový `cards.json` do `mobil_projekt/assets/`
4. Znovu spusťte `flutter run` nebo buildněte APK

## Závislosti
- `flutter_tts` - výslovnost
- `shared_preferences` - ukládání pokroku
