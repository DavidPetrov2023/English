#!/usr/bin/env python3
"""
Simulace SM-2 algoritmu z LangCards aplikace.
Implementuje stejnou logiku jako main.dart _rate() a _getDueCards().

Realističtější model uživatele:
  - Křivka učení (čím víc opakování, tím větší šance zapamatovat)
  - Křivka zapomínání (overdue karty mají vyšší šanci selhat)
  - Profil obtížnosti karty (easy/medium/hard má jiný ceiling)
  - Víkendová mezera + nárazové dlouhé pauzy

Pustit: python sm2_simulace.py [seed]
"""

import random
import sys
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import List, Dict, Optional

# Windows konzole — vynutit UTF-8 výstup (kvůli emoji a diakritice)
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')


# ============================================================
# 1) IMPLEMENTACE SM-2 (přesně dle main.dart _rate())
# ============================================================

@dataclass
class CardProgress:
    ease: float = 2.5
    interval: int = 0
    repetitions: int = 0
    next_review: date = field(default_factory=date.today)
    last_review: Optional[date] = None

    def rate(self, rating: int, today: date, boost: bool = False):
        """Zrcadlí main.dart:2529-2569."""
        if rating < 3:
            self.repetitions = 1
            self.interval = 1
            self.ease = max(1.3, self.ease - 0.2)
        elif rating == 4 and boost:
            self.repetitions = 10
            self.interval = 90
            self.ease = 2.8
        else:
            if self.repetitions == 0:
                self.interval = 1
            elif self.repetitions == 1:
                self.interval = 6
            else:
                self.interval = round(self.interval * self.ease)
            self.repetitions += 1
            delta = 0.1 - (5 - rating) * (0.08 + (5 - rating) * 0.02)
            self.ease = max(1.3, self.ease + delta)

        self.next_review = today + timedelta(days=self.interval)
        self.last_review = today

    def is_due(self, today: date) -> bool:
        return self.next_review <= today

    def color(self) -> str:
        if self.repetitions == 0:
            return 'gray'
        elif self.interval <= 1:
            return 'red'
        elif self.interval <= 6:
            return 'orange'
        elif self.interval <= 21:
            return 'green'
        else:
            return 'blue'


@dataclass
class Card:
    name: str
    profile: str  # 'easy', 'medium', 'hard'
    progress: CardProgress = field(default_factory=CardProgress)


# ============================================================
# 2) REALISTICKÝ MODEL UŽIVATELE
# ============================================================

# Maximum pravděpodobnosti, že kartu uživatel v daný den úspěšně vybaví
# (po dostatečném učení; "ceiling" znalosti)
PROFILE_CEILING = {
    'easy': 0.97,
    'medium': 0.85,
    'hard': 0.62,
}

def probability_remember(card: Card, today: date) -> float:
    """
    Pravděpodobnost, že si uživatel kartu dnes vybaví.
    Modeluje:
      - Učební křivku: čím víc reps, tím blíž k ceiling.
      - Zapomínání podle Ebbinghausovy křivky: čím déle od posledního review,
        tím menší šance (přes "overdue factor").
    """
    p = card.progress
    ceiling = PROFILE_CEILING[card.profile]

    # Učební progres: 1 - 0.6^reps → asymptoticky k 1
    # rep=0: 0%, rep=1: 40%, rep=2: 64%, rep=3: 78%, rep=5: 92%
    learning = 1.0 - 0.6 ** p.repetitions
    base = ceiling * learning

    # Zapomínání: pokud je karta výrazně overdue (uživatel den vynechal),
    # pravděpodobnost klesá. Když uděláš review včas, base zůstává.
    if p.last_review is not None and p.interval > 0:
        days_since = (today - p.last_review).days
        overdue_factor = days_since / p.interval
        if overdue_factor > 1.0:
            # 2x overdue → ~80%, 3x overdue → ~64% původní pravděpodobnosti
            base *= 0.8 ** (overdue_factor - 1)

    return max(0.02, min(0.99, base))


def user_rates(card: Card, today: date, rng: random.Random) -> int:
    """
    Vrátí rating 1-4 reálným způsobem.
    Pokud si vybavím → Dobře (3), občas Snadné (4) když mám jistotu.
    Pokud nevybavím → Znovu (1) nebo Těžké (2), záleží na blízkosti.
    """
    p_remember = probability_remember(card, today)

    if rng.random() < p_remember:
        # Vybavil jsem si
        # Snadné dávám jen když jsem si fakt jistý (vysoký p_remember)
        if p_remember > 0.85 and rng.random() < 0.40:
            return 4
        return 3
    else:
        # Nevybavil jsem si
        # "Těžké" když to mám aspoň trochu v hlavě (mírný p), "Znovu" když ne
        if p_remember > 0.40 and rng.random() < 0.55:
            return 2
        return 1


# ============================================================
# 3) MODEL CHOVÁNÍ — kdy uživatel otevře aplikaci
# ============================================================

def user_opens_app(today: date, day_index: int, rng: random.Random) -> bool:
    """
    - Pondělí–pátek: 85% šance
    - Sobota–neděle: 50% šance
    - Náhodně 3× za půl roku: dlouhá pauza 5–10 dní (nemoc, dovolená)
    """
    weekday = today.weekday()  # 0=Po ... 6=Ne
    if weekday >= 5:
        p_open = 0.50
    else:
        p_open = 0.85
    return rng.random() < p_open


# ============================================================
# 4) SIMULACE
# ============================================================

def run(num_days: int = 180, seed: int = 42, num_cards: int = 30):
    rng = random.Random(seed)
    start = date(2026, 1, 1)

    cards = (
        [Card(f'snadná_{i:02d}', 'easy') for i in range(num_cards // 3)]
        + [Card(f'střední_{i:02d}', 'medium') for i in range((num_cards // 3) + (num_cards % 3))]
        + [Card(f'těžká_{i:02d}', 'hard') for i in range(num_cards // 3)]
    )
    for c in cards:
        c.progress.next_review = start

    # Naplánuj 3 dlouhé pauzy
    long_breaks = set()
    for _ in range(3):
        start_d = rng.randint(20, num_days - 15)
        length = rng.randint(5, 10)
        for k in range(length):
            long_breaks.add(start_d + k)

    daily = []
    daily_limit = 25  # uživatel se unaví po 25 hodnoceních

    for d in range(num_days):
        today = start + timedelta(days=d)
        due_at_start = [c for c in cards if c.progress.is_due(today)]

        if d in long_breaks or not user_opens_app(today, d, rng):
            daily.append(_snapshot(d, today, cards, due_at_start, [], 0, 0, opened=False))
            continue

        # Projedeme splatné (zamícháno, do limitu)
        order = list(due_at_start)
        rng.shuffle(order)
        ratings_count = [0, 0, 0, 0]
        reviewed = 0

        for card in order[:daily_limit]:
            r = user_rates(card, today, rng)
            card.progress.rate(r, today, boost=False)
            ratings_count[r - 1] += 1
            reviewed += 1

        daily.append(_snapshot(
            d, today, cards, due_at_start, ratings_count, reviewed,
            sum(ratings_count), opened=True,
        ))

    return cards, daily


def _snapshot(day, today, cards, due_start, ratings, reviewed, _unused, opened):
    """Spočítá UI countery jak je vidí uživatel + interní stav."""
    learned = sum(1 for c in cards if c.progress.repetitions > 0)   # "Naučeno X" v UI
    truly_blue = sum(1 for c in cards if c.progress.interval > 21)  # skutečně modré (>21d)
    reviewed_today = sum(1 for c in cards if c.progress.last_review == today)
    return {
        'day': day,
        'date': today,
        'opened': opened,
        'due_at_start': len(due_start),
        'reviewed': reviewed,
        'ratings': ratings if ratings else [0, 0, 0, 0],
        # Hodnoty, které ukazuje UI:
        'ui_dnes_x': reviewed_today,         # ← "Dnes X" (z lastReview)
        'ui_naucenocount': learned,          # ← "Naučeno X" (z repetitions > 0)
        # Pravdivější metriky pro porovnání:
        'truly_blue': truly_blue,            # opravdu naučené (>21d)
    }


# ============================================================
# 5) REPORT + KONTROLA UI COUNTERŮ
# ============================================================

def report(cards: List[Card], daily: List[Dict], num_cards: int = 30):
    total = num_cards
    print("=" * 78)
    print(f"  SIMULACE SM-2 — {len(daily)} dní, {total} karet (realistický model)")
    print("=" * 78)

    days_opened = sum(1 for s in daily if s['opened'])
    total_reviewed = sum(s['reviewed'] for s in daily)
    total_ratings = [sum(s['ratings'][i] for s in daily) for i in range(4)]

    print(f"\n📊 CELKEM ZA {len(daily)} DNÍ")
    print(f"  Dní s otevřenou apkou: {days_opened}/{len(daily)} ({days_opened/len(daily)*100:.0f}%)")
    print(f"  Celkem ohodnocení:     {total_reviewed}")
    print(f"  Průměrně za otevřený den: {total_reviewed/days_opened:.1f}")
    print(f"  Rozložení ratingů:")
    labels = ['Znovu  (1)', 'Těžké  (2)', 'Dobře  (3)', 'Snadné (4)']
    for i, lbl in enumerate(labels):
        pct = total_ratings[i] / total_reviewed * 100 if total_reviewed else 0
        bar = '█' * int(pct / 2)
        print(f"    {lbl}: {total_ratings[i]:5d} ({pct:5.1f}%) {bar}")

    # === Po obtížnosti ===
    print(f"\n📈 STAV PO OBTÍŽNOSTI (konec simulace)")
    print(f"  {'Profil':<10} {'avg ease':<10} {'avg int':<10} {'avg rep':<10} {'modrých':<10}")
    for diff in ['easy', 'medium', 'hard']:
        sub = [c for c in cards if c.profile == diff]
        avg_ease = sum(c.progress.ease for c in sub) / len(sub)
        avg_int = sum(c.progress.interval for c in sub) / len(sub)
        avg_rep = sum(c.progress.repetitions for c in sub) / len(sub)
        blue = sum(1 for c in sub if c.progress.interval > 21)
        print(f"  {diff:<10} {avg_ease:<10.2f} {avg_int:<10.1f} {avg_rep:<10.1f} "
              f"{blue:<2}/{len(sub)}")

    # === Distribuce barev ===
    colors = {}
    for c in cards:
        colors[c.progress.color()] = colors.get(c.progress.color(), 0) + 1
    print(f"\n🎨 DISTRIBUCE BAREV V POSLEDNÍ DEN")
    color_names = {'gray': '⚪ nová', 'red': '🔴 červená (≤1)',
                   'orange': '🟠 oranžová (≤6)', 'green': '🟢 zelená (≤21)',
                   'blue': '🔵 modrá (>21)'}
    for col in ['gray', 'red', 'orange', 'green', 'blue']:
        n = colors.get(col, 0)
        print(f"  {color_names[col]:<25} {n:3} {'█' * n}")

    # === UI COUNTERY — kontrola, dávají smysl? ===
    print(f"\n🖥️  UI COUNTERY — vývoj 'Dnes X/Y' a 'Naučeno X/Y' (každý 15. den)")
    print(f"  {'Den':<5} {'Otev':<5} {'Splat':<7} {'Dnes(rev)':<10} "
          f"{'Naučeno UI':<12} {'Modré (>21d)':<14} {'Komentář'}")
    for s in daily:
        if s['day'] % 15 != 0 and s['day'] != len(daily) - 1:
            continue
        # Porovnání: "Naučeno X" v UI vs skutečně modré karty
        diff = s['ui_naucenocount'] - s['truly_blue']
        if diff > 0:
            comment = f"UI 'Naučeno' přepočítané o {diff}"
        elif diff == 0:
            comment = "souhlasí"
        else:
            comment = ""
        ratings_str = '/'.join(str(x) for x in s['ratings'])
        opened = '✓' if s['opened'] else '✗'
        print(f"  {s['day']:<5} {opened:<5} {s['due_at_start']:<7} "
              f"{s['ui_dnes_x']:>2}/{total:<6} "
              f"{s['ui_naucenocount']:>2}/{total:<8} "
              f"{s['truly_blue']:>2}/{total:<10} "
              f"{comment}")

    # === HLAVNÍ ZJIŠTĚNÍ K UI ===
    print(f"\n🔎 ANALÝZA UI COUNTERŮ")
    last_day_with_open = [s for s in daily if s['opened']][-1]
    print(f"\n  'Dnes X/Y':")
    print(f"    X = počet karet hodnocených dnes (z lastReview).")
    print(f"    Y = total karet v lekci ({total}).")
    print(f"    Poslední otevřený den: Dnes {last_day_with_open['ui_dnes_x']}/{total}")
    print(f"    → Y by možná dávalo větší smysl jako 'splatných dnes', "
          f"protože uživatel typicky hodnotí ~{int(total_reviewed/days_opened)} karet/den, ne {total}.")

    final = daily[-1]
    print(f"\n  'Naučeno X/Y':")
    print(f"    UI ukazuje X = {final['ui_naucenocount']}/{total} (cards with reps > 0)")
    print(f"    Skutečně modré (interval > 21d) = {final['truly_blue']}/{total}")
    if final['ui_naucenocount'] > final['truly_blue']:
        diff = final['ui_naucenocount'] - final['truly_blue']
        print(f"    ⚠ Rozdíl: UI tvrdí naučeno o {diff} víc, než je modrých.")
        print(f"      'Naučeno' v UI znamená 'aspoň jednou ohodnoceno', ne 'modré'.")
        print(f"      Pro intuitivnější UX by X mělo počítat 'interval > 21' (= modré).")
    else:
        print(f"    ✓ UI a skutečnost se shodují.")

    # === Klíčové ověření algoritmu ===
    print(f"\n✅ OVĚŘENÍ ALGORITMU")
    easy = [c for c in cards if c.profile == 'easy']
    hard = [c for c in cards if c.profile == 'hard']
    easy_blue = sum(1 for c in easy if c.progress.interval > 21)
    hard_blue = sum(1 for c in hard if c.progress.interval > 21)
    avg_int_easy = sum(c.progress.interval for c in easy) / len(easy)
    avg_int_hard = sum(c.progress.interval for c in hard) / len(hard)

    print(f"  Snadné karty modré: {easy_blue}/{len(easy)} (očekáváme většinu)")
    print(f"  Těžké karty modré:  {hard_blue}/{len(hard)} (očekáváme méně)")
    print(f"  Průměrný interval: snadné {avg_int_easy:.0f}d  vs.  těžké {avg_int_hard:.0f}d")
    print(f"  {'✓' if avg_int_easy > avg_int_hard * 2 else '⚠'} "
          f"Algoritmus drží těžké blíže, snadné dál — to je správné chování.")


if __name__ == '__main__':
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 42
    NUM = 30
    cards, daily = run(num_days=180, seed=seed, num_cards=NUM)
    report(cards, daily, num_cards=NUM)
