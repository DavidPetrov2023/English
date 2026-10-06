# LangCards — Zásady ochrany soukromí

**Poslední aktualizace:** 6. října 2026
**Provozovatel:** David Petrov · **Kontakt:** davidpetrov@email.cz
**Kanonická verze (URL pro Play Console):** https://petrovelektronika.cz/LangCards/privacy.html

> Tento soubor je kopie pro repozitář. Při změně aktualizovat OBĚ verze — tento soubor
> i privacy.html na serveru (scp do /var/www/html/LangCards/).

## Používání bez účtu

Aplikaci lze plně používat **bez registrace**. Pokrok v učení, vlastní kartičky
a nastavení pak zůstávají **pouze lokálně v zařízení**. Na server provozovatele se
odesílá jen anonymní souhrn používání, viz další oddíl.

## Anonymní souhrn používání

Od verze 1.5.20 si aplikace při prvním spuštění vytvoří **náhodné číslo instalace**.
Není odvozené od zařízení, e-mailu ani jiného údaje. K němu aplikace odesílá na server
provozovatele (petrovelektronika.cz):

- platformu (web, Android) a verzi aplikace,
- po dnech: počet ohodnocených kartiček, čas strávený učením a názvy procvičovaných lekcí.

Účel: aby provozovatel viděl, jestli a jak se aplikace používá, i u lidí bez účtu.
Údaje se nepředávají třetím stranám a nepoužívají k reklamě. U přihlášeného uživatele
se souhrn přiřadí k jeho účtu. Nové číslo instalace vznikne po přeinstalování
aplikace nebo smazání dat prohlížeče; o smazání souhrnu lze požádat e-mailem.

## Volitelný účet a záloha

Při vytvoření účtu zpracováváme:

- **e-mailovou adresu** — přihlášení a ověření účtu
- **heslo** — pouze bcrypt otisk, nikdy heslo samotné
- **zálohu dat** — pokrok a vlastní kartičky se automaticky zálohují na server
  provozovatele (petrovelektronika.cz)
- **provozní údaje účtu** — datum registrace, poslední přihlášení, velikost zálohy

Data neprodáváme, nepoužíváme k reklamě ani nepředáváme třetím stranám s výjimkou
případů níže.

## Překlad textu (třetí strana)

Tlačítko automatického překladu odešle **zadaný text službě MyMemory** (translated.net).
Bez použití tlačítka se žádný text nikam neodesílá.

## Mikrofon a diktování

Diktování vyžaduje oprávnění k **mikrofonu** (vyžádáno při prvním použití). Rozpoznávání
řeči provádí služba zařízení (na Androidu služba Google). Aplikace zvuk neukládá.

## Výslovnost (TTS)

Výslovnost přehrává syntetizér zařízení. Ve webové verzi může být text odeslán na server
provozovatele (vrací zvuk); eviduje se měsíční objem znaků na účet.

## Smazání účtu a dat

E-mailem na davidpetrov@email.cz z registrované adresy; smazání do 30 dnů. Stejně lze
požádat i o smazání samotné zálohy bez zrušení účtu. Lokální data odstraní odhlášení
nebo odinstalace.

## Co aplikace NEDĚLÁ

- žádné reklamy
- žádná analytika třetích stran ani sledování napříč aplikacemi a weby
  (anonymní souhrn výše zůstává jen u provozovatele)
- žádný sběr polohy, kontaktů, SMS
- žádné AI zpracování dat

## Děti

Vhodné pro všechny věkové kategorie. Bez účtu aplikace odesílá jen anonymní souhrn
používání popsaný výše.

---

© 2026 David Petrov
