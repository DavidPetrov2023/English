# English Learning

Aplikace pro učení angličtiny pomocí kartiček s metodou spaced repetition.

**Autor:** David Petrov

## Struktura projektu

```
English/
├── mobil_projekt/     ← Flutter Android aplikace
├── pc_projekt/        ← Webová verze + Python skripty
└── README.md          ← tento soubor
```

## Mobilní aplikace (Android)

Flutter aplikace s funkcemi:
- Kartičky EN ↔ CZ
- Výslovnost (Text-to-Speech)
- SM-2 algoritmus pro spaced repetition
- Barevný přehled pokroku

Více v [mobil_projekt/README.md](mobil_projekt/README.md)

### Spuštění

```bash
cd mobil_projekt
flutter run
```

## PC verze (Web)

HTML + JavaScript aplikace s Python serverem.

Více v [pc_projekt/README.md](pc_projekt/README.md)

### Spuštění

```bash
cd pc_projekt
python convert_xlsx.py
```

## Zdroj dat

Kartičky se načítají z Excel souboru (`English.xlsx`) na Google Drive.
Soubor `cards.json` se generuje pomocí `convert_xlsx.py`.

## Bezpečnost

Soubory které nejsou v repozitáři (viz `.gitignore`):
- `cards.json` - osobní kartičky
- `progress.json` - váš pokrok
- `*.env` - API klíče
- `*.keystore` - podepisovací klíče pro Android
