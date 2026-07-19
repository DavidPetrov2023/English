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

### Deploy webové verze (petrovelektronika.cz/LangCards)

```bash
cd mobil_projekt
flutter build web --base-href /LangCards/
scp -r build/web/* root@89.221.217.120:/var/www/html/LangCards/
```

**Pozor:**
- `--base-href /LangCards/` je POVINNÝ — bez něj apka tahá zdroje z rootu domény a skončí bílou obrazovkou (404 na flutter_bootstrap.js)
- V Git Bash flag nefunguje (přemele cestu na `C:/Program Files/Git/...`) — použít PowerShell nebo cmd
- Před buildem zvednout verzi v `pubspec.yaml` — web klienti detekují novou verzi porovnáním version.json; stejná verze = nikdo nedostane prompt „NAČÍST ZNOVU"
- Na serveru NEMAZAT `/var/www/html/LangCards/api/` — tam žije PHP backend (login, backup, TTS), v build/web není a scp ho nepřepíše

**Nginx (nastaveno 19. 7. 2026):** `/LangCards/` se servíruje s `Cache-Control: no-cache` — prohlížeče si vždy ověří aktuálnost (ETag/304), deploy se projeví okamžitě. Config je v `/etc/nginx/sites-enabled/default` (POZOR: na serveru to NENÍ symlink na sites-available — živý je soubor v sites-enabled). Záloha: `/root/nginx-enabled-default.bak-20260719`.

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
