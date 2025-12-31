import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const EnglishLearningApp());
}

class EnglishLearningApp extends StatelessWidget {
  const EnglishLearningApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'English Learning',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF00D9FF),
        scaffoldBackgroundColor: const Color(0xFF1A1A2E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D9FF),
          secondary: Color(0xFF00FF88),
          surface: Color(0xFF16213E),
        ),
      ),
      home: const LearningScreen(),
    );
  }
}

class FlashCard {
  final String en;
  final String cz;
  final String category;

  FlashCard({required this.en, required this.cz, required this.category});

  factory FlashCard.fromJson(Map<String, dynamic> json) {
    return FlashCard(
      en: json['en'] ?? '',
      cz: json['cz'] ?? '',
      category: json['category'] ?? '',
    );
  }
}

class CardProgress {
  double ease;
  int interval;
  int repetitions;
  String nextReview;
  String? lastReview;

  CardProgress({
    this.ease = 2.5,
    this.interval = 0,
    this.repetitions = 0,
    String? nextReview,
    this.lastReview,
  }) : nextReview = nextReview ?? _today();

  static String _today() {
    return DateTime.now().toIso8601String().split('T')[0];
  }

  Map<String, dynamic> toJson() => {
        'ease': ease,
        'interval': interval,
        'repetitions': repetitions,
        'nextReview': nextReview,
        'lastReview': lastReview,
      };

  factory CardProgress.fromJson(Map<String, dynamic> json) {
    return CardProgress(
      ease: (json['ease'] ?? 2.5).toDouble(),
      interval: json['interval'] ?? 0,
      repetitions: json['repetitions'] ?? 0,
      nextReview: json['nextReview'],
      lastReview: json['lastReview'],
    );
  }
}

class LearningScreen extends StatefulWidget {
  const LearningScreen({super.key});

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  List<FlashCard> cards = [];
  Map<String, CardProgress> progress = {};
  FlashCard? currentCard;
  bool showTranslation = false;
  bool isEnToCz = true;
  int todayReviewed = 0;

  late FlutterTts flutterTts;
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    flutterTts = FlutterTts();
    _initTts();
    _loadData();
  }

  Future<void> _initTts() async {
    await flutterTts.setLanguage('en-US');
    await flutterTts.setSpeechRate(0.4);
    await flutterTts.setPitch(1.0);
    await flutterTts.awaitSpeakCompletion(true);

    // Zkusit najít lepší hlas
    List<dynamic> voices = await flutterTts.getVoices;
    var englishVoices = voices.where((v) =>
      v['locale'].toString().startsWith('en') &&
      v['name'].toString().toLowerCase().contains('female') ||
      v['name'].toString().toLowerCase().contains('samantha') ||
      v['name'].toString().toLowerCase().contains('google') ||
      v['name'].toString().contains('en-us-x-sfg')
    ).toList();

    if (englishVoices.isNotEmpty) {
      await flutterTts.setVoice({
        "name": englishVoices.first['name'],
        "locale": englishVoices.first['locale']
      });
    }
  }

  Future<void> _loadData() async {
    prefs = await SharedPreferences.getInstance();

    // Načíst kartičky z assets
    final String jsonString = await rootBundle.loadString('assets/cards.json');
    final Map<String, dynamic> jsonData = json.decode(jsonString);
    final List<dynamic> cardsList = jsonData['cards'] ?? [];

    // Filtrovat jen "Gramatika věty"
    cards = cardsList
        .map((c) => FlashCard.fromJson(c))
        .where((c) => c.category == 'Gramatika věty')
        .toList();

    // Načíst pokrok
    final String? progressJson = prefs.getString('progress');
    if (progressJson != null) {
      final Map<String, dynamic> progressData = json.decode(progressJson);
      progressData.forEach((key, value) {
        progress[key] = CardProgress.fromJson(value);
      });
    }

    _showNextCard();
  }

  String _getCardKey(FlashCard card) {
    return card.en.substring(0, min(50, card.en.length));
  }

  CardProgress _getCardProgress(FlashCard card) {
    final key = _getCardKey(card);
    progress[key] ??= CardProgress();
    return progress[key]!;
  }

  List<FlashCard> _getDueCards() {
    final today = DateTime.now().toIso8601String().split('T')[0];
    return cards.where((card) {
      final prog = _getCardProgress(card);
      return prog.nextReview.compareTo(today) <= 0;
    }).toList()
      ..sort((a, b) {
        final progA = _getCardProgress(a);
        final progB = _getCardProgress(b);
        return progA.nextReview.compareTo(progB.nextReview);
      });
  }

  void _showNextCard() {
    final dueCards = _getDueCards();

    if (dueCards.isEmpty) {
      setState(() {
        currentCard = null;
        showTranslation = false;
      });
      return;
    }

    // Vybrat náhodnou kartičku z prvních 10
    final pool = dueCards.take(10).toList();
    final random = Random();

    setState(() {
      currentCard = pool[random.nextInt(pool.length)];
      showTranslation = false;
    });
  }

  void _reveal() {
    setState(() {
      showTranslation = true;
    });
  }

  Future<void> _speak() async {
    if (currentCard != null) {
      await flutterTts.speak(currentCard!.en);
    }
  }

  void _rate(int rating) {
    if (currentCard == null) return;

    final prog = _getCardProgress(currentCard!);
    final today = DateTime.now().toIso8601String().split('T')[0];

    // SM-2 algoritmus
    if (rating < 3) {
      prog.repetitions = 0;
      prog.interval = 1;
    } else {
      if (prog.repetitions == 0) {
        prog.interval = 1;
      } else if (prog.repetitions == 1) {
        prog.interval = 6;
      } else {
        prog.interval = (prog.interval * prog.ease).round();
      }
      prog.repetitions++;
    }

    // Upravit ease factor
    prog.ease = max(1.3, prog.ease + (0.1 - (5 - rating) * (0.08 + (5 - rating) * 0.02)));

    // Nastavit další opakování
    final nextDate = DateTime.now().add(Duration(days: prog.interval));
    prog.nextReview = nextDate.toIso8601String().split('T')[0];
    prog.lastReview = today;

    todayReviewed++;

    _saveProgress();
    _showNextCard();
  }

  Future<void> _saveProgress() async {
    final Map<String, dynamic> progressJson = {};
    progress.forEach((key, value) {
      progressJson[key] = value.toJson();
    });
    await prefs.setString('progress', json.encode(progressJson));
  }

  void _toggleDirection() {
    setState(() {
      isEnToCz = !isEnToCz;
    });
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('O aplikaci'),
        content: const Text(
          'English Learning\n\n'
          'Aplikace pro učení angličtiny pomocí kartiček.\n\n'
          'Používá SM-2 algoritmus (spaced repetition) - kartičky které neznáte se opakují častěji.\n\n'
          'Autor: David Petrov\n'
          'Verze 1.0',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zavřít'),
          ),
        ],
      ),
    );
  }

  Color _getCardColor(FlashCard card) {
    final prog = _getCardProgress(card);
    if (prog.repetitions == 0) {
      return Colors.grey[700]!; // Nová - šedá
    } else if (prog.interval <= 1) {
      return const Color(0xFFE74C3C); // Těžká - červená
    } else if (prog.interval <= 6) {
      return const Color(0xFFF39C12); // Učí se - oranžová
    } else if (prog.interval <= 21) {
      return const Color(0xFF27AE60); // Dobrá - zelená
    } else {
      return const Color(0xFF3498DB); // Naučená - modrá
    }
  }

  void _showCardsOverview(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          appBar: AppBar(
            title: const Text('Přehled kartiček'),
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: Column(
            children: [
              // Legenda
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildLegendItem(Colors.grey[700]!, 'Nová'),
                    _buildLegendItem(const Color(0xFFE74C3C), 'Těžká'),
                    _buildLegendItem(const Color(0xFFF39C12), 'Učí se'),
                    _buildLegendItem(const Color(0xFF27AE60), 'Dobrá'),
                    _buildLegendItem(const Color(0xFF3498DB), 'Naučená'),
                  ],
                ),
              ),
              // Mřížka kartiček
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 8,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: cards.length,
                  itemBuilder: (context, index) {
                    final card = cards[index];
                    return GestureDetector(
                      onTap: () => _showCardDetail(context, card),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _getCardColor(card),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }

  void _showCardDetail(BuildContext context, FlashCard card) {
    final prog = _getCardProgress(card);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: Text(card.en, style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(card.cz, style: const TextStyle(color: Color(0xFF00D9FF))),
            const SizedBox(height: 16),
            Text('Opakování: ${prog.repetitions}x', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
            Text('Interval: ${prog.interval} dní', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
            Text('Další: ${prog.nextReview}', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              flutterTts.speak(card.en);
            },
            child: const Text('🔊 Přehrát'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zavřít'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dueCards = _getDueCards();
    final learned = cards.where((c) => _getCardProgress(c).repetitions > 0).length;
    final progressPercent = cards.isNotEmpty ? learned / cards.length : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('English Learning'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.grid_view),
            onPressed: () => _showCardsOverview(context),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showAboutDialog(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              // Statistiky
              Text(
                'K opakování: ${dueCards.length} | Naučeno: $learned/${cards.length} | Dnes: $todayReviewed',
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
              ),
              const SizedBox(height: 10),

              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progressPercent,
                  backgroundColor: Colors.grey[800],
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00D9FF)),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 20),

              // Směr překladu
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildDirectionButton('EN → CZ', isEnToCz),
                  const SizedBox(width: 10),
                  _buildDirectionButton('CZ → EN', !isEnToCz),
                ],
              ),
              const SizedBox(height: 20),

              // Kartička
              Expanded(
                child: _buildCard(),
              ),
              const SizedBox(height: 20),

              // Tlačítka
              if (currentCard != null) ...[
                if (!showTranslation) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildIconButton(Icons.volume_up, _speak),
                      const SizedBox(width: 20),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _reveal,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00D9FF),
                            foregroundColor: const Color(0xFF1A1A2E),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Text('Ukázat překlad', style: TextStyle(fontSize: 16)),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildIconButton(Icons.volume_up, _speak),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildRatingButton('Znovu', const Color(0xFFE74C3C), () => _rate(1)),
                      _buildRatingButton('Těžké', const Color(0xFFF39C12), () => _rate(2)),
                      _buildRatingButton('Dobře', const Color(0xFF27AE60), () => _rate(3)),
                      _buildRatingButton('Snadné', const Color(0xFF3498DB), () => _rate(4)),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDirectionButton(String text, bool isActive) {
    return GestureDetector(
      onTap: _toggleDirection,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF00D9FF) : Colors.grey[800],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isActive ? const Color(0xFF1A1A2E) : Colors.grey[500],
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCard() {
    if (currentCard == null) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF16213E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: Text(
            '🎉 Hotovo na dnes!',
            style: TextStyle(fontSize: 24),
          ),
        ),
      );
    }

    final questionText = isEnToCz ? currentCard!.en : currentCard!.cz;
    final answerText = isEnToCz ? currentCard!.cz : currentCard!.en;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            questionText,
            style: const TextStyle(fontSize: 22, height: 1.5),
            textAlign: TextAlign.center,
          ),
          if (showTranslation) ...[
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              height: 1,
              color: Colors.grey[700],
            ),
            const SizedBox(height: 20),
            Text(
              answerText,
              style: const TextStyle(
                fontSize: 20,
                color: Color(0xFF00D9FF),
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const Spacer(),
          Text(
            currentCard!.category,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton(IconData icon, VoidCallback onPressed) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF4A4A6A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 28),
        color: Colors.white,
        padding: const EdgeInsets.all(12),
      ),
    );
  }

  Widget _buildRatingButton(String text, Color color, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      child: Text(text),
    );
  }
}
