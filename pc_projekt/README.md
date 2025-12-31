# English Learning App

Jednoduchá aplikace pro učení angličtiny metodou spaced repetition (podobně jako Anki).

## Soubory

```
c:\Cloud\AI\English\
├── index.html          ← aplikace (otevřít přes server)
├── cards.json          ← kartičky (generováno ze XLSX)
├── convert_xlsx.py     ← skript pro konverzi XLSX → JSON
└── README.md           ← tento soubor

G:\Můj disk\Gdisk\
└── English.xlsx        ← zdroj dat (jen čtení)
```

## Jak spustit

1. **Spustit lokální server:**
   ```
   cd c:\Cloud\AI\English
   python -m http.server 8080
   ```

2. **Otevřít v prohlížeči:**
   ```
   http://localhost:8080
   ```

## Ovládání

| Klávesa | Akce |
|---------|------|
| Mezerník | Ukázat překlad / Hodnotit "Dobře" |
| S | Přehrát výslovnost |
| 1 | Znovu (nepamatuji si) |
| 2 | Těžké |
| 3 | Dobře |
| 4 | Snadné |

## Aktualizace kartiček

Když přidáte nové věty do XLSX, spusťte:

```
python convert_xlsx.py
```

Obnoví se `cards.json` s novými kartičkami. Pokrok učení zůstane zachován (ukládá se v prohlížeči).

## Jak funguje spaced repetition

- Kartičky které neznáte se opakují častěji
- Kartičky které znáte se ukazují s delším odstupem
- Algoritmus SM-2 (stejný jako v Anki)
- Pokrok se ukládá do localStorage prohlížeče

## Kategorie

Každá záložka v XLSX = jedna kategorie:
- Gramatika věty
- Časy
- Příběhy na téma
- Homework

Můžete filtrovat podle kategorie v rozbalovacím menu.
