import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

enum AppLanguage { en, de }

class LanguageConfig {
  final AppLanguage language;
  const LanguageConfig(this.language);

  String get code => language == AppLanguage.en ? 'en' : 'de';
  String get ttsLocale => language == AppLanguage.en ? 'en-US' : 'de-DE';
  String get nativeTtsLocale => 'cs-CZ';
  String get label => language == AppLanguage.en ? 'Angličtina' : 'Němčina';
  String get labelGenitive => language == AppLanguage.en ? 'angličtiny' : 'němčiny';
  String get shortLabel => language == AppLanguage.en ? 'EN' : 'DE';
  String get flagEmoji => language == AppLanguage.en ? '🇺🇸' : '🇩🇪';
  String get cardsAsset => language == AppLanguage.en ? 'assets/cards.json' : 'assets/cards_de.json';
  String get grammarAssetPrefix => language == AppLanguage.en ? 'assets/grammar_' : 'assets/grammar_de_';
  String get addCardLabel => language == AppLanguage.en ? 'Anglicky' : 'Německy';
  String get addCardHint => language == AppLanguage.en ? 'Hello, how are you?' : 'Hallo, wie geht es dir?';
  String get backupFilePrefix => language == AppLanguage.en ? 'english' : 'german';

  // SharedPreferences keys - per language
  String get progressKey => '${code}_progress';
  String get myCardsKey => '${code}_myCards';
  String get myCardsNameKey => '${code}_myCardsName';
  String get lastBackupDateKey => '${code}_lastBackupDate';
  String get lastBackupProgressCountKey => '${code}_lastBackupProgressCount';
  String get lastBackupCardsCountKey => '${code}_lastBackupCardsCount';
  String get hasUnsavedProgressKey => '${code}_hasUnsavedProgress';

  String directionLabel(bool isForeignToCz) {
    return isForeignToCz ? '$shortLabel → CZ' : 'CZ → $shortLabel';
  }

  static LanguageConfig? fromCode(String code) {
    for (final lang in AppLanguage.values) {
      if (lang.name == code) return LanguageConfig(lang);
    }
    return null;
  }
}

void main() {
  runApp(const EnglishLearningApp());
}

class EnglishLearningApp extends StatelessWidget {
  const EnglishLearningApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LangCards',
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
      home: const HomeScreen(),
    );
  }
}

// Data models
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

  Map<String, dynamic> toJson() => {'en': en, 'cz': cz, 'category': category};
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

class GrammarLevel {
  final String level;
  final String name;
  final Color color;
  final List<GrammarCategory> categories;

  GrammarLevel({
    required this.level,
    required this.name,
    required this.color,
    required this.categories,
  });

  factory GrammarLevel.fromJson(Map<String, dynamic> json) {
    return GrammarLevel(
      level: json['level'] ?? '',
      name: json['name'] ?? '',
      color: Color(int.parse((json['color'] ?? '#9E9E9E').replaceFirst('#', '0xFF'))),
      categories: (json['categories'] as List? ?? [])
          .map((c) => GrammarCategory.fromJson(c))
          .toList(),
    );
  }
}

class GrammarCategory {
  final String id;
  final String name;
  final List<FlashCard> cards;

  GrammarCategory({
    required this.id,
    required this.name,
    required this.cards,
  });

  factory GrammarCategory.fromJson(Map<String, dynamic> json) {
    return GrammarCategory(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      cards: (json['cards'] as List? ?? [])
          .map((c) => FlashCard.fromJson({...c, 'category': json['name']}))
          .toList(),
    );
  }
}

// Home Screen
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<FlashCard> myCards = [];
  List<FlashCard> davidCards = [];
  List<GrammarLevel> grammarLevels = [];
  Map<String, CardProgress> progress = {};
  String? userEmail;
  String myCardsName = 'Moje kartičky';
  late SharedPreferences prefs;
  bool isLoading = true;
  DateTime? lastBackupDate;
  bool backupEnabled = true;
  int lastBackupProgressCount = 0;
  int lastBackupCardsCount = 0;
  bool hasUnsavedProgress = false;
  late LanguageConfig langConfig;
  bool _showFirstLaunchPicker = false;

  @override
  void initState() {
    super.initState();
    langConfig = const LanguageConfig(AppLanguage.en);
    _loadAllData();
  }

  Future<void> _migrateOldData() async {
    if (prefs.getBool('dataMigrated') == true) return;

    final keysToMigrate = {
      'progress': 'en_progress',
      'myCards': 'en_myCards',
      'myCardsName': 'en_myCardsName',
      'lastBackupDate': 'en_lastBackupDate',
      'lastBackupProgressCount': 'en_lastBackupProgressCount',
      'lastBackupCardsCount': 'en_lastBackupCardsCount',
      'hasUnsavedProgress': 'en_hasUnsavedProgress',
    };

    for (final entry in keysToMigrate.entries) {
      final oldKey = entry.key;
      final newKey = entry.value;
      // String keys
      if (oldKey == 'progress' || oldKey == 'myCards' || oldKey == 'myCardsName' || oldKey == 'lastBackupDate') {
        final val = prefs.getString(oldKey);
        if (val != null) {
          await prefs.setString(newKey, val);
          await prefs.remove(oldKey);
        }
      }
      // Int keys
      if (oldKey == 'lastBackupProgressCount' || oldKey == 'lastBackupCardsCount') {
        final val = prefs.getInt(oldKey);
        if (val != null) {
          await prefs.setInt(newKey, val);
          await prefs.remove(oldKey);
        }
      }
      // Bool keys
      if (oldKey == 'hasUnsavedProgress') {
        final val = prefs.getBool(oldKey);
        if (val != null) {
          await prefs.setBool(newKey, val);
          await prefs.remove(oldKey);
        }
      }
    }

    await prefs.setBool('dataMigrated', true);
    if (!prefs.containsKey('selectedLanguage')) {
      await prefs.setString('selectedLanguage', 'en');
    }
  }

  Future<void> _loadAllData() async {
    prefs = await SharedPreferences.getInstance();

    // Migrate old data (one-time)
    await _migrateOldData();

    // Load language
    final savedLang = prefs.getString('selectedLanguage');
    if (savedLang == null) {
      _showFirstLaunchPicker = true;
      langConfig = const LanguageConfig(AppLanguage.en);
    } else {
      langConfig = LanguageConfig.fromCode(savedLang) ?? const LanguageConfig(AppLanguage.en);
    }

    // Load global settings
    userEmail = prefs.getString('userEmail');
    backupEnabled = prefs.getBool('backupEnabled') ?? true;

    // Load per-language settings
    myCardsName = prefs.getString(langConfig.myCardsNameKey) ?? 'Moje kartičky';
    lastBackupProgressCount = prefs.getInt(langConfig.lastBackupProgressCountKey) ?? 0;
    lastBackupCardsCount = prefs.getInt(langConfig.lastBackupCardsCountKey) ?? 0;
    hasUnsavedProgress = prefs.getBool(langConfig.hasUnsavedProgressKey) ?? false;
    final lastBackupStr = prefs.getString(langConfig.lastBackupDateKey);
    if (lastBackupStr != null) {
      lastBackupDate = DateTime.tryParse(lastBackupStr);
    } else {
      lastBackupDate = null;
    }

    // Load progress
    progress = {};
    final String? progressJson = prefs.getString(langConfig.progressKey);
    if (progressJson != null) {
      final Map<String, dynamic> progressData = json.decode(progressJson);
      progressData.forEach((key, value) {
        progress[key] = CardProgress.fromJson(value);
      });
    }

    // Load David's cards (author's cards)
    try {
      final String jsonString = await rootBundle.loadString(langConfig.cardsAsset);
      final Map<String, dynamic> jsonData = json.decode(jsonString);
      final List<dynamic> cardsList = jsonData['cards'] ?? [];
      davidCards = cardsList
          .map((c) => FlashCard.fromJson(c))
          .where((c) => c.category == 'Gramatika věty')
          .toList();
    } catch (e) {
      davidCards = [];
      debugPrint('Error loading David cards: $e');
    }

    // Load user's own cards
    final String? myCardsJson = prefs.getString(langConfig.myCardsKey);
    if (myCardsJson != null) {
      final List<dynamic> cardsList = json.decode(myCardsJson);
      myCards = cardsList.map((c) => FlashCard.fromJson(c)).toList();
    } else {
      myCards = [];
    }

    // Load grammar levels
    grammarLevels = [];
    final levels = ['A1', 'A2', 'B1', 'B2', 'C1'];
    for (final level in levels) {
      try {
        final String jsonString = await rootBundle.loadString('${langConfig.grammarAssetPrefix}$level.json');
        final Map<String, dynamic> jsonData = json.decode(jsonString);
        grammarLevels.add(GrammarLevel.fromJson(jsonData));
      } catch (e) {
        // Level file not found
      }
    }

    setState(() {
      isLoading = false;
    });

    if (_showFirstLaunchPicker) {
      _showFirstLaunchPicker = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLanguagePicker();
      });
    }
  }

  void _showLanguagePicker() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Vyberte jazyk'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Text('🇺🇸', style: TextStyle(fontSize: 28)),
              title: const Text('Angličtina'),
              selected: langConfig.language == AppLanguage.en,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              selectedTileColor: Colors.green.withValues(alpha: 0.2),
              onTap: () { Navigator.pop(context); _switchLanguage(AppLanguage.en); },
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Text('🇩🇪', style: TextStyle(fontSize: 28)),
              title: const Text('Němčina'),
              selected: langConfig.language == AppLanguage.de,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              selectedTileColor: Colors.green.withValues(alpha: 0.2),
              onTap: () { Navigator.pop(context); _switchLanguage(AppLanguage.de); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _switchLanguage(AppLanguage lang) async {
    if (langConfig.language == lang && prefs.containsKey('selectedLanguage')) return;

    await prefs.setString('selectedLanguage', lang == AppLanguage.de ? 'de' : 'en');

    setState(() {
      isLoading = true;
      myCards = [];
      davidCards = [];
      grammarLevels = [];
      progress = {};
    });

    await _loadAllData();
  }

  Future<void> _saveProgress() async {
    final Map<String, dynamic> progressJson = {};
    progress.forEach((key, value) {
      progressJson[key] = value.toJson();
    });
    await prefs.setString(langConfig.progressKey, json.encode(progressJson));
    // Mark that we have unsaved progress since last backup
    if (!hasUnsavedProgress) {
      hasUnsavedProgress = true;
      await prefs.setBool(langConfig.hasUnsavedProgressKey, true);
    }
  }

  String _getCardKey(FlashCard card) {
    return card.en.substring(0, min(50, card.en.length));
  }

  CardProgress _getCardProgress(FlashCard card) {
    final key = _getCardKey(card);
    progress[key] ??= CardProgress();
    return progress[key]!;
  }

  double _calculateProgress(List<FlashCard> cards) {
    if (cards.isEmpty) return 0.0;
    final learned = cards.where((c) => _getCardProgress(c).repetitions > 0).length;
    return learned / cards.length;
  }

  double _calculateLevelProgress(GrammarLevel level) {
    final allCards = level.categories.expand((c) => c.cards).toList();
    return _calculateProgress(allCards);
  }

  bool _levelHasDueCards(GrammarLevel level) {
    final today = DateTime.now().toIso8601String().split('T')[0];
    for (final category in level.categories) {
      for (final card in category.cards) {
        final prog = _getCardProgress(card);
        if (prog.nextReview.compareTo(today) <= 0) {
          return true;
        }
      }
    }
    return false;
  }

  Color _getProgressBarColor(List<FlashCard> cards) {
    if (cards.isEmpty) return Colors.grey[800]!;

    int totalScore = 0;
    for (final card in cards) {
      final prog = _getCardProgress(card);
      if (prog.repetitions == 0) {
        totalScore += 0;
      } else if (prog.interval <= 1) {
        totalScore += 1;
      } else if (prog.interval <= 6) {
        totalScore += 2;
      } else if (prog.interval <= 21) {
        totalScore += 3;
      } else {
        totalScore += 4;
      }
    }

    final avgScore = totalScore / cards.length;

    if (avgScore < 0.5) {
      return Colors.grey[700]!;
    } else if (avgScore < 1.5) {
      return const Color(0xFFE74C3C);
    } else if (avgScore < 2.5) {
      return const Color(0xFFF39C12);
    } else if (avgScore < 3.5) {
      return const Color(0xFF27AE60);
    } else {
      return const Color(0xFF3498DB);
    }
  }

  Future<void> _shareBackup() async {
    // Check if there's any data to backup
    if (progress.isEmpty && myCards.isEmpty) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF16213E),
          title: const Text('Prázdná záloha'),
          content: const Text(
            'Nemáte žádný pokrok k zálohování.\n\n'
            'Pokud jste na novém zařízení, použijte "Obnovit ze zálohy" pro načtení dat.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Zrušit'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Přesto zálohovat'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    // Create backup data with ALL languages
    final Map<String, dynamic> allLangs = {};
    for (final lang in AppLanguage.values) {
      final lc = LanguageConfig(lang);
      final progJson = prefs.getString(lc.progressKey);
      final cardsJson = prefs.getString(lc.myCardsKey);
      if (progJson != null || cardsJson != null) {
        allLangs[lc.code] = {
          'progress': progJson != null ? json.decode(progJson) : {},
          'myCards': cardsJson != null ? json.decode(cardsJson) : [],
        };
      }
    }

    final backupData = {
      'version': '3.0',
      'date': DateTime.now().toIso8601String(),
      'languages': allLangs,
    };

    final backupJson = const JsonEncoder.withIndent('  ').convert(backupData);
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}';
    final fileName = 'langcards_backup_$dateStr.json';

    try {
      // Get temporary directory and create file
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/$fileName');
      await file.writeAsString(backupJson);

      // Share the file
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'LangCards - Záloha $dateStr',
        text: 'Záloha vašeho pokroku v aplikaci LangCards',
      );

      // Mark as backed up for all languages
      lastBackupDate = DateTime.now();
      hasUnsavedProgress = false;
      for (final lang in AppLanguage.values) {
        final lc = LanguageConfig(lang);
        await prefs.setString(lc.lastBackupDateKey, lastBackupDate!.toIso8601String());
        await prefs.setBool(lc.hasUnsavedProgressKey, false);
        // Save per-language backup counts
        final progJson = prefs.getString(lc.progressKey);
        final cardsJson = prefs.getString(lc.myCardsKey);
        final progCount = progJson != null ? (json.decode(progJson) as Map).length : 0;
        final cardsCount = cardsJson != null ? (json.decode(cardsJson) as List).length : 0;
        await prefs.setInt(lc.lastBackupProgressCountKey, progCount);
        await prefs.setInt(lc.lastBackupCardsCountKey, cardsCount);
      }
      lastBackupProgressCount = progress.length;
      lastBackupCardsCount = myCards.length;

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Chyba při vytváření zálohy: $e')),
        );
      }
    }
  }

  Future<void> _restoreFromBackup() async {
    // Warn if existing data will be overwritten
    if (progress.isNotEmpty || myCards.isNotEmpty) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF16213E),
          title: const Text('Přepsat stávající data?'),
          content: Text(
            'Máte ${progress.length} záznamů o pokroku a ${myCards.length} vlastních kartiček.\n\n'
            'Obnovením zálohy se tyto data přepíší.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Zrušit'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Přepsat', style: TextStyle(color: Colors.orange)),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    try {
      // Open file picker
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty) return;

      final file = File(result.files.single.path!);
      final backupText = await file.readAsString();

      final data = json.decode(backupText);

      final backupDate = data['date'] != null
          ? (DateTime.tryParse(data['date']) ?? DateTime.now())
          : DateTime.now();

      if (data['version'] == '3.0' && data['languages'] != null) {
        // v3.0 format: restore ALL languages
        final languages = data['languages'] as Map<String, dynamic>;
        for (final entry in languages.entries) {
          final lc = LanguageConfig.fromCode(entry.key);
          if (lc == null) continue; // skip unknown languages
          final langData = entry.value as Map<String, dynamic>;

          // Save progress for this language
          if (langData['progress'] != null) {
            await prefs.setString(lc.progressKey, json.encode(langData['progress']));
          }

          // Save cards for this language
          if (langData['myCards'] != null) {
            await prefs.setString(lc.myCardsKey, json.encode(langData['myCards']));
          }

          // Mark this language as backed up
          await prefs.setString(lc.lastBackupDateKey, backupDate.toIso8601String());
          await prefs.setBool(lc.hasUnsavedProgressKey, false);
        }

        // Reload current language data into memory
        final progJson = prefs.getString(langConfig.progressKey);
        progress.clear();
        if (progJson != null) {
          (json.decode(progJson) as Map<String, dynamic>).forEach((key, value) {
            progress[key] = CardProgress.fromJson(value);
          });
        }
        final cardsJson = prefs.getString(langConfig.myCardsKey);
        if (cardsJson != null) {
          myCards = (json.decode(cardsJson) as List)
              .map((c) => FlashCard.fromJson(c))
              .toList();
        } else {
          myCards = [];
        }

        final restoredLangs = languages.keys.map((c) => c.toUpperCase()).join(', ');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Záloha obnovena pro jazyky: $restoredLangs')),
          );
        }
      } else {
        // v2.0 or older format: restore to current language only
        if (data['progress'] != null) {
          progress.clear();
          (data['progress'] as Map<String, dynamic>).forEach((key, value) {
            progress[key] = CardProgress.fromJson(value);
          });
        }

        if (data['myCards'] != null) {
          myCards = (data['myCards'] as List)
              .map((c) => FlashCard.fromJson(c))
              .toList();
          await _saveMyCards();
        }

        // Save progress to SharedPreferences
        final Map<String, dynamic> progressJson = {};
        progress.forEach((key, value) {
          progressJson[key] = value.toJson();
        });
        await prefs.setString(langConfig.progressKey, json.encode(progressJson));

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Záloha obnovena pro ${langConfig.shortLabel}')),
          );
        }
      }

      // Update backup tracking for current language
      lastBackupDate = backupDate;
      lastBackupProgressCount = progress.length;
      lastBackupCardsCount = myCards.length;
      hasUnsavedProgress = false;
      await prefs.setString(langConfig.lastBackupDateKey, lastBackupDate!.toIso8601String());
      await prefs.setInt(langConfig.lastBackupProgressCountKey, lastBackupProgressCount);
      await prefs.setInt(langConfig.lastBackupCardsCountKey, lastBackupCardsCount);
      await prefs.setBool(langConfig.hasUnsavedProgressKey, false);

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Chyba při obnovení: $e')),
        );
      }
    }
  }

  // ===== GitHub Sync =====

  Future<void> _showGitHubSyncSettings() async {
    final emailController = TextEditingController(text: prefs.getString('gh_email') ?? '');
    final nicknameController = TextEditingController(text: prefs.getString('gh_username') ?? '');
    String? error;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF16213E),
          title: const Text('Registrace'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    hintText: 'jmeno@email.cz',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nicknameController,
                  decoration: const InputDecoration(
                    labelText: 'Přezdívka (nepovinné)',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Email slouží pro pozdější obnovu účtu. Záloha se ukládá do '
                  'soukromého repa skupiny.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Zrušit'),
            ),
            if ((prefs.getString('gh_email') ?? '').isNotEmpty)
              TextButton(
                onPressed: () async {
                  await prefs.remove('gh_email');
                  await prefs.remove('gh_username');
                  await prefs.remove(_nemeckyUsmevUnlockedKey);
                  if (context.mounted) Navigator.pop(context, true);
                },
                child: const Text('Odhlásit', style: TextStyle(color: Colors.red)),
              ),
            TextButton(
              onPressed: () async {
                final email = emailController.text.trim().toLowerCase();
                if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
                  setDialogState(() => error = 'Zadejte platný email');
                  return;
                }
                final nickname = nicknameController.text.trim();
                await prefs.setString('gh_email', email);
                await prefs.setString('gh_username', nickname.isNotEmpty ? nickname : email);
                if (context.mounted) Navigator.pop(context, true);
              },
              child: const Text('Uložit'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) setState(() {});
  }

  String _ghBackupJson() {
    final Map<String, dynamic> allLangs = {};
    for (final lang in AppLanguage.values) {
      final lc = LanguageConfig(lang);
      final progJson = prefs.getString(lc.progressKey);
      final cardsJson = prefs.getString(lc.myCardsKey);
      if (progJson != null || cardsJson != null) {
        allLangs[lc.code] = {
          'progress': progJson != null ? json.decode(progJson) : {},
          'myCards': cardsJson != null ? json.decode(cardsJson) : [],
        };
      }
    }
    return json.encode({
      'version': '3.0',
      'date': DateTime.now().toIso8601String(),
      'languages': allLangs,
    });
  }

  Future<void> _githubSync() async {
    final email = prefs.getString('gh_email') ?? '';
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nejdřív se zaregistrujte')),
      );
      return;
    }

    final filename = _emailToFilename(email);
    final path = '$filename.json';
    final url = Uri.parse('https://api.github.com/repos/$_kGhRepo/contents/$path');
    final token = _kGhToken;

    try {
      // First, check if file exists to get its SHA (required for update)
      String? sha;
      final getReq = await HttpClient().getUrl(url);
      getReq.headers.set('Authorization', 'Bearer $token');
      getReq.headers.set('Accept', 'application/vnd.github+json');
      final getRes = await getReq.close();
      if (getRes.statusCode == 200) {
        final body = await getRes.transform(const Utf8Decoder()).join();
        final data = json.decode(body);
        sha = data['sha'] as String?;
      }

      // Upload (create or update)
      final content = _ghBackupJson();
      final encoded = base64Encode(utf8.encode(content));

      final putReq = await HttpClient().putUrl(url);
      putReq.headers.set('Authorization', 'Bearer $token');
      putReq.headers.set('Accept', 'application/vnd.github+json');
      putReq.headers.contentType = ContentType.json;
      final payload = {
        'message': 'LangCards backup ${DateTime.now().toIso8601String()}',
        'content': encoded,
        if (sha != null) 'sha': sha,
      };
      putReq.write(json.encode(payload));
      final putRes = await putReq.close();
      final putBody = await putRes.transform(const Utf8Decoder()).join();

      if (putRes.statusCode == 200 || putRes.statusCode == 201) {
        // Update backup tracking
        lastBackupDate = DateTime.now();
        hasUnsavedProgress = false;
        for (final lang in AppLanguage.values) {
          final lc = LanguageConfig(lang);
          await prefs.setString(lc.lastBackupDateKey, lastBackupDate!.toIso8601String());
          await prefs.setBool(lc.hasUnsavedProgressKey, false);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Záloha nahrána jako $path')),
          );
          setState(() {});
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Chyba ${putRes.statusCode}: $putBody')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Chyba: $e')),
        );
      }
    }
  }

  Future<void> _githubRestore() async {
    final email = prefs.getString('gh_email') ?? '';
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nejdřív se zaregistrujte')),
      );
      return;
    }

    // Confirm overwrite
    if (progress.isNotEmpty || myCards.isNotEmpty) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF16213E),
          title: const Text('Přepsat stávající data?'),
          content: Text(
            'Stáhnout zálohu pro $email a přepsat lokální data?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Zrušit'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Přepsat', style: TextStyle(color: Colors.orange)),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    final filename = _emailToFilename(email);
    final path = '$filename.json';
    final url = Uri.parse('https://api.github.com/repos/$_kGhRepo/contents/$path');
    final token = _kGhToken;

    try {
      final req = await HttpClient().getUrl(url);
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close();
      if (res.statusCode != 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Záloha nenalezena (${res.statusCode})')),
          );
        }
        return;
      }
      final body = await res.transform(const Utf8Decoder()).join();
      final data = json.decode(body);
      final base64Content = (data['content'] as String).replaceAll('\n', '');
      final decoded = utf8.decode(base64Decode(base64Content));
      final backup = json.decode(decoded);

      final backupDate = backup['date'] != null
          ? (DateTime.tryParse(backup['date']) ?? DateTime.now())
          : DateTime.now();

      if (backup['version'] == '3.0' && backup['languages'] != null) {
        final languages = backup['languages'] as Map<String, dynamic>;
        for (final entry in languages.entries) {
          final lc = LanguageConfig.fromCode(entry.key);
          if (lc == null) continue;
          final langData = entry.value as Map<String, dynamic>;
          if (langData['progress'] != null) {
            await prefs.setString(lc.progressKey, json.encode(langData['progress']));
          }
          if (langData['myCards'] != null) {
            await prefs.setString(lc.myCardsKey, json.encode(langData['myCards']));
          }
          await prefs.setString(lc.lastBackupDateKey, backupDate.toIso8601String());
          await prefs.setBool(lc.hasUnsavedProgressKey, false);
        }

        // Reload current language
        final progJson = prefs.getString(langConfig.progressKey);
        progress.clear();
        if (progJson != null) {
          (json.decode(progJson) as Map<String, dynamic>).forEach((k, v) {
            progress[k] = CardProgress.fromJson(v);
          });
        }
        final cardsJson = prefs.getString(langConfig.myCardsKey);
        myCards = cardsJson != null
            ? (json.decode(cardsJson) as List).map((c) => FlashCard.fromJson(c)).toList()
            : [];
      }

      lastBackupDate = backupDate;
      hasUnsavedProgress = false;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Záloha pro $email obnovena z GitHubu')),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Chyba: $e')),
        );
      }
    }
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16213E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Backup reminder toggle
            StatefulBuilder(
              builder: (context, setLocalState) => SwitchListTile(
                secondary: Icon(
                  backupEnabled ? Icons.notifications_active : Icons.notifications_off,
                  color: backupEnabled ? const Color(0xFF00FF88) : Colors.grey,
                ),
                title: const Text('Připomínka zálohy'),
                subtitle: Text(backupEnabled ? 'Připomene po týdnu' : 'Vypnuto'),
                value: backupEnabled,
                activeTrackColor: const Color(0xFF00FF88),
                onChanged: (value) async {
                  setLocalState(() {
                    backupEnabled = value;
                  });
                  await prefs.setBool('backupEnabled', value);
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                  setState(() {});
                },
              ),
            ),
            if (lastBackupDate != null)
              Padding(
                padding: const EdgeInsets.only(left: 72, bottom: 8),
                child: Text(
                  'Poslední záloha: ${lastBackupDate!.day}.${lastBackupDate!.month}.${lastBackupDate!.year}',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ),
            const Divider(color: Colors.grey),
            ListTile(
              leading: const Icon(Icons.share, color: Color(0xFF00D9FF)),
              title: const Text('Sdílet zálohu'),
              subtitle: const Text('Odeslat soubor se zálohou'),
              onTap: () {
                Navigator.pop(context);
                _shareBackup();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open, color: Color(0xFF00FF88)),
              title: const Text('Obnovit ze zálohy'),
              subtitle: const Text('Vybrat soubor ze zařízení'),
              onTap: () {
                Navigator.pop(context);
                _restoreFromBackup();
              },
            ),
            const Divider(color: Colors.grey),
            ListTile(
              leading: const Icon(Icons.cloud_sync, color: Color(0xFF00D9FF)),
              title: const Text('Cloud účet'),
              subtitle: Text(prefs.getString('gh_email')?.isNotEmpty == true
                  ? 'Přihlášen jako ${prefs.getString('gh_username') ?? prefs.getString('gh_email')}'
                  : 'Registrace'),
              onTap: () {
                Navigator.pop(context);
                _showGitHubSyncSettings();
              },
            ),
            if (prefs.getString('gh_email')?.isNotEmpty == true) ...[
              ListTile(
                leading: const Icon(Icons.cloud_upload, color: Color(0xFF00FF88)),
                title: const Text('Nahrát zálohu do cloudu'),
                onTap: () {
                  Navigator.pop(context);
                  _githubSync();
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_download, color: Color(0xFFFFD700)),
                title: const Text('Stáhnout zálohu z cloudu'),
                onTap: () {
                  Navigator.pop(context);
                  _githubRestore();
                },
              ),
            ],
            const Divider(color: Colors.grey),
            ListTile(
              leading: const Icon(Icons.info_outline, color: Colors.grey),
              title: const Text('O aplikaci'),
              onTap: () {
                Navigator.pop(context);
                _showAboutDialog();
              },
            ),
            // Extra padding for navigation bar
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('O aplikaci'),
        content: Text(
          'LangCards v1.4.1\n\n'
          'Aplikace pro učení cizích jazyků pomocí kartiček.\n\n'
          'Funkce:\n'
          '• Vlastní kartičky\n'
          '• Gramatika A1-C1\n'
          '• SM-2 algoritmus (spaced repetition)\n'
          '• Text-to-Speech výslovnost\n'
          '• Záloha sdílením souboru\n\n'
          'Autor: David Petrov\n'
          'Email: davidpetrov@email.cz',
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

  bool _needsBackup() {
    if (!backupEnabled) return false;
    // Nikdy nezálohováno - potřeba pokud jsou data
    if (lastBackupDate == null) return progress.isNotEmpty || myCards.isNotEmpty;
    // Nový pokrok od poslední zálohy
    if (hasUnsavedProgress) return true;
    if (progress.length > lastBackupProgressCount) return true;
    if (myCards.length > lastBackupCardsCount) return true;
    return false;
  }

  Widget _buildBackupStatusIndicator() {
    Color iconColor;
    IconData iconData;
    String tooltip;

    if (!backupEnabled) {
      iconColor = Colors.grey;
      iconData = Icons.cloud_off_outlined;
      tooltip = 'Záloha vypnuta';
    } else if (progress.isEmpty && myCards.isEmpty) {
      // Žádná data - šedá ikona
      iconColor = Colors.grey;
      iconData = Icons.cloud_outlined;
      tooltip = 'Žádná data k zálohování';
    } else if (_needsBackup()) {
      iconColor = Colors.orange;
      iconData = Icons.cloud_upload_outlined;
      // Spočítej nové položky
      final newProgress = progress.length - lastBackupProgressCount;
      final newCards = myCards.length - lastBackupCardsCount;
      if (lastBackupDate == null) {
        tooltip = 'Nezálohováno - klikni pro zálohu';
      } else {
        final parts = <String>[];
        if (newProgress > 0) parts.add('+$newProgress pokrok');
        if (newCards > 0) parts.add('+$newCards kartiček');
        tooltip = parts.isNotEmpty ? parts.join(', ') : 'Nová data k záloze';
      }
    } else {
      iconColor = const Color(0xFF00FF88);
      iconData = Icons.cloud_done_outlined;
      tooltip = 'Zálohováno ${lastBackupDate!.day}.${lastBackupDate!.month}.${lastBackupDate!.year}';
    }

    return IconButton(
      icon: Icon(iconData, size: 22, color: iconColor),
      tooltip: tooltip,
      onPressed: _shareBackup,
    );
  }

  static const String _nemeckyUsmevUnlockedKey = 'nemecky_usmev_unlocked';

  // Hardcoded GitHub config for "Němčina s úsměvem" group
  static const String _kGhRepo = 'DavidPetrov2023/langcards-backups';
  static const String _kGhToken = '__TOKEN_PLACEHOLDER__'; // TODO: replace with real token before deploy

  String _emailToFilename(String email) {
    final beforeAt = email.split('@').first.trim().toLowerCase();
    // Sanitize - only allow alphanumeric, dots, underscores, dashes
    return beforeAt.replaceAll(RegExp(r'[^a-z0-9._-]'), '_');
  }

  Future<bool> _verifyGithubAccess() async {
    try {
      final url = Uri.parse('https://api.github.com/repos/$_kGhRepo');
      final req = await HttpClient().getUrl(url);
      req.headers.set('Authorization', 'Bearer $_kGhToken');
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close();
      await res.drain();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openNemeckySUsmevem() async {
    final hasEmail = (prefs.getString('gh_email') ?? '').isNotEmpty;
    // Require email registration
    if (!hasEmail) {
      // Show disclaimer first
      final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF16213E),
          title: const Text('Upozornění'),
          content: const Text(
            'Tato sekce obsahuje slovní zásobu z učebnice "Německy s úsměvem - nově" '
            '(Fraus 2003).\n\n'
            'Obsah je určen výhradně pro osobní studium v rámci naší soukromé '
            'výukové skupiny. Není povoleno volné šíření, kopírování nebo '
            'distribuce mimo tuto skupinu.\n\n'
            'Pro vstup je potřeba registrace přes GitHub - každý uživatel zadá své '
            'jméno a sdílený přístupový token od správce skupiny.\n\n'
            'Autor aplikace nenese odpovědnost za případné porušení autorských '
            'práv třetími osobami.',
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Zrušit'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Souhlasím', style: TextStyle(color: Colors.orange)),
            ),
          ],
        ),
      );
      if (agreed != true) return;

      // Show GitHub registration
      if (!mounted) return;
      await _showGitHubSyncSettings();

      // Verify access works
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ověřuji přístup k repu...')),
      );
      final ok = await _verifyGithubAccess();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Přístup zamítnut. Zkontrolujte token a repo.')),
          );
        }
        return;
      }
      await prefs.setBool(_nemeckyUsmevUnlockedKey, true);
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => NemeckySUsmevemScreen(
          progress: progress,
          onSaveProgress: _saveProgress,
          langConfig: langConfig,
        ),
      ),
    ).then((_) => setState(() {}));
  }

  Widget _buildNemeckySUsmevemCard() {
    final unlocked = prefs.getBool(_nemeckyUsmevUnlockedKey) ?? false;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFFD700).withValues(alpha: 0.15),
            const Color(0xFFFFA500).withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD700).withValues(alpha: 0.4)),
      ),
      child: ListTile(
        leading: Icon(
          unlocked ? Icons.menu_book : Icons.lock_outline,
          color: const Color(0xFFFFD700),
          size: 32,
        ),
        title: const Text(
          '😊 Němčina s úsměvem',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(unlocked ? 'Slovní zásoba podle lekcí' : 'Chráněno heslem'),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openNemeckySUsmevem,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final myCardsProgress = _calculateProgress(myCards);
    final davidCardsProgress = _calculateProgress(davidCards);

    return Scaffold(
      appBar: AppBar(
        title: Builder(builder: (_) {
          final ghUser = prefs.getString('gh_username') ?? '';
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('LangCards', style: TextStyle(fontSize: 18)),
              if (ghUser.isNotEmpty)
                Text(
                  '☁️ $ghUser',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF00D9FF)),
                ),
            ],
          );
        }),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          // Language picker
          IconButton(
            icon: Text(langConfig.flagEmoji, style: const TextStyle(fontSize: 22)),
            tooltip: langConfig.label,
            onPressed: _showLanguagePicker,
          ),
          // Backup status indicator
          _buildBackupStatusIndicator(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // My Cards Section (user's own cards)
              _buildSectionCardWithEdit(
                title: '📚 $myCardsName',
                subtitle: '${myCards.length} kartiček',
                progress: myCardsProgress,
                color: _getProgressBarColor(myCards),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => LearningScreen(
                      title: myCardsName,
                      cards: myCards,
                      progress: progress,
                      onSaveProgress: _saveProgress,
                      langConfig: langConfig,
                    ),
                  ),
                ).then((_) => setState(() {})),
                onEditName: _editMyCardsName,
                onAddCard: _addNewCard,
              ),

              if (langConfig.language == AppLanguage.de) ...[
                const SizedBox(height: 16),
                _buildNemeckySUsmevemCard(),
              ],

              const SizedBox(height: 24),

              // Grammar Section Header
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '📖 Gramatika',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Grammar Levels
              ...grammarLevels.map((level) => _buildLevelCard(level)),

              if (langConfig.language == AppLanguage.en && davidCards.isNotEmpty) ...[
                const SizedBox(height: 24),

                // David Petrov's Cards Section (only for English)
                _buildAuthorCard(
                  title: '✨ David Petrov kartičky',
                  subtitle: '${davidCards.length} kartiček',
                  progress: davidCardsProgress,
                  color: _getProgressBarColor(davidCards),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => LearningScreen(
                        title: 'David Petrov kartičky',
                        cards: davidCards,
                        progress: progress,
                        onSaveProgress: _saveProgress,
                        langConfig: langConfig,
                      ),
                    ),
                  ).then((_) => setState(() {})),
                  onInfoTap: _showAuthorInfo,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveMyCards() async {
    final cardsJson = myCards.map((c) => c.toJson()).toList();
    await prefs.setString(langConfig.myCardsKey, json.encode(cardsJson));
  }

  Future<void> _addNewCard() async {
    final enController = TextEditingController();
    final czController = TextEditingController();
    final speech = stt.SpeechToText();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool isListeningEn = false;
        bool isListeningCz = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            bool isTranslating = false;

            Future<String?> translateText(String text, String from, String to) async {
              try {
                final uri = Uri.parse(
                  'https://api.mymemory.translated.net/get?q=${Uri.encodeComponent(text)}&langpair=$from|$to',
                );
                final httpClient = HttpClient();
                final request = await httpClient.getUrl(uri);
                final response = await request.close();
                final body = await response.transform(const Utf8Decoder()).join();
                final data = json.decode(body);
                if (data['responseStatus'] == 200) {
                  String result = data['responseData']['translatedText'] as String;
                  result = result
                      .replaceAll('&quot;', '')
                      .replaceAll('&amp;', '&')
                      .replaceAll('&lt;', '<')
                      .replaceAll('&gt;', '>')
                      .replaceAll('&#39;', '')
                      .trim();
                  // Remove any stray quotes/apostrophes at the very end or start
                  result = result.replaceAll(RegExp(r'''["""„''\u2018\u2019\u201C\u201D\u201E]$'''), '');
                  result = result.replaceAll(RegExp(r'''^["""„''\u2018\u2019\u201C\u201D\u201E]'''), '');
                  result = result.trim();
                  return result;
                }
              } catch (_) {}
              return null;
            }

            Future<void> toggleListening(TextEditingController controller, String localeId, bool isEn) async {
              if (isEn ? isListeningEn : isListeningCz) {
                await speech.stop();
                setDialogState(() {
                  if (isEn) {
                    isListeningEn = false;
                  } else {
                    isListeningCz = false;
                  }
                });
                return;
              }

              bool available = await speech.initialize(
                onError: (error) {
                  setDialogState(() {
                    isListeningEn = false;
                    isListeningCz = false;
                  });
                },
              );

              if (available) {
                setDialogState(() {
                  if (isEn) {
                    isListeningEn = true;
                  } else {
                    isListeningCz = true;
                  }
                });
                await speech.listen(
                  onResult: (result) {
                    setDialogState(() {
                      controller.text = result.recognizedWords;
                      controller.selection = TextSelection.fromPosition(
                        TextPosition(offset: controller.text.length),
                      );
                      if (result.finalResult) {
                        if (isEn) {
                          isListeningEn = false;
                          // Auto-translate EN/DE → CZ
                          if (result.recognizedWords.isNotEmpty && czController.text.isEmpty) {
                            isTranslating = true;
                            translateText(result.recognizedWords, langConfig.code, 'cs').then((translated) {
                              setDialogState(() {
                                if (translated != null) {
                                  czController.text = translated;
                                  czController.selection = TextSelection.fromPosition(
                                    TextPosition(offset: czController.text.length),
                                  );
                                }
                                isTranslating = false;
                              });
                            });
                          }
                        } else {
                          isListeningCz = false;
                          // Auto-translate CZ → EN/DE
                          if (result.recognizedWords.isNotEmpty && enController.text.isEmpty) {
                            isTranslating = true;
                            translateText(result.recognizedWords, 'cs', langConfig.code).then((translated) {
                              setDialogState(() {
                                if (translated != null) {
                                  enController.text = translated;
                                  enController.selection = TextSelection.fromPosition(
                                    TextPosition(offset: enController.text.length),
                                  );
                                }
                                isTranslating = false;
                              });
                            });
                          }
                        }
                      }
                    });
                  },
                  localeId: localeId,
                );
              }
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF16213E),
              title: const Text('Přidat kartičku'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: enController,
                    decoration: InputDecoration(
                      labelText: langConfig.addCardLabel,
                      hintText: langConfig.addCardHint,
                      border: const OutlineInputBorder(),
                      suffixIcon: isTranslating
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: Icon(
                              isListeningEn ? Icons.mic : Icons.mic_none,
                              color: isListeningEn ? Colors.red : Colors.grey,
                            ),
                            onPressed: () => toggleListening(enController, langConfig.ttsLocale, true),
                          ),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: czController,
                    decoration: InputDecoration(
                      labelText: 'Česky',
                      hintText: 'Ahoj, jak se máš?',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          isListeningCz ? Icons.mic : Icons.mic_none,
                          color: isListeningCz ? Colors.red : Colors.grey,
                        ),
                        onPressed: () => toggleListening(czController, 'cs-CZ', false),
                      ),
                    ),
                    maxLines: 2,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    speech.stop();
                    Navigator.pop(context, false);
                  },
                  child: const Text('Zrušit'),
                ),
                TextButton(
                  onPressed: () {
                    speech.stop();
                    Navigator.pop(context, true);
                  },
                  child: const Text('Přidat'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && enController.text.isNotEmpty && czController.text.isNotEmpty) {
      setState(() {
        myCards.add(FlashCard(
          en: enController.text,
          cz: czController.text,
          category: myCardsName,
        ));
      });
      await _saveMyCards();
    }
  }

  Future<void> _editMyCardsName() async {
    final controller = TextEditingController(text: myCardsName);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Změnit název'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Název vašich kartiček',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zrušit'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      setState(() {
        myCardsName = newName;
      });
      await prefs.setString(langConfig.myCardsNameKey, newName);
    }
  }

  void _showAuthorInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: const Color(0xFFFFD700).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(25),
              ),
              child: const Icon(Icons.person, color: Color(0xFFFFD700), size: 30),
            ),
            const SizedBox(width: 12),
            const Text('David Petrov'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Autor aplikace',
              style: TextStyle(
                color: Color(0xFFFFD700),
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Tato sekce obsahuje kartičky vytvořené autorem aplikace Davidem Petrovem.\n\n'
              'Kartičky jsou zaměřené na praktickou gramatiku a běžné fráze.\n\n'
              'Děkuji za používání mé aplikace! 🙏\n\n'
              'Email: davidpetrov@email.cz',
              style: TextStyle(height: 1.5),
            ),
          ],
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

  Widget _buildSectionCardWithEdit({
    required String title,
    required String subtitle,
    required double progress,
    required Color color,
    required VoidCallback onTap,
    required VoidCallback onEditName,
    required VoidCallback onAddCard,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF16213E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Color(0xFF00FF88), size: 22),
                  onPressed: onAddCard,
                  padding: const EdgeInsets.all(0),
                  constraints: const BoxConstraints(),
                  tooltip: 'Přidat kartičku',
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.edit, color: color, size: 18),
                  onPressed: onEditName,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Změnit název',
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward_ios, color: color, size: 16),
              ],
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: Colors.grey[500])),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[800],
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                      minHeight: 8,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${(progress * 100).toInt()}%',
                  style: TextStyle(color: color, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthorCard({
    required String title,
    required String subtitle,
    required double progress,
    required Color color,
    required VoidCallback onTap,
    required VoidCallback onInfoTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF16213E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.info_outline, color: color, size: 20),
                  onPressed: onInfoTap,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward_ios, color: color, size: 16),
              ],
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: Colors.grey[500])),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[800],
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                      minHeight: 8,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${(progress * 100).toInt()}%',
                  style: TextStyle(color: color, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLevelCard(GrammarLevel level) {
    final levelProgress = _calculateLevelProgress(level);
    final totalCards = level.categories.fold<int>(0, (sum, c) => sum + c.cards.length);
    final allCards = level.categories.expand((c) => c.cards).toList();
    final progressColor = _getProgressBarColor(allCards);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GrammarLevelScreen(
              level: level,
              progress: progress,
              onSaveProgress: _saveProgress,
              getCardProgress: _getCardProgress,
              langConfig: langConfig,
            ),
          ),
        ).then((_) => setState(() {})),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF16213E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: level.color.withValues(alpha: 0.3), width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: level.color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    level.level,
                    style: TextStyle(
                      color: level.color,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      level.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${level.categories.length} kategorií • $totalCards kartiček',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: levelProgress,
                        backgroundColor: Colors.grey[800],
                        valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                        minHeight: 6,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${(levelProgress * 100).toInt()}%',
                style: TextStyle(
                  color: progressColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios,
                color: _levelHasDueCards(level) ? Colors.green : Colors.grey,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Grammar Level Screen
class GrammarLevelScreen extends StatefulWidget {
  final GrammarLevel level;
  final Map<String, CardProgress> progress;
  final Function() onSaveProgress;
  final CardProgress Function(FlashCard) getCardProgress;
  final LanguageConfig langConfig;

  const GrammarLevelScreen({
    super.key,
    required this.level,
    required this.progress,
    required this.onSaveProgress,
    required this.getCardProgress,
    required this.langConfig,
  });

  @override
  State<GrammarLevelScreen> createState() => _GrammarLevelScreenState();
}

class _GrammarLevelScreenState extends State<GrammarLevelScreen> {
  bool _hasDueCards(List<FlashCard> cards) {
    final today = DateTime.now().toIso8601String().split('T')[0];
    return cards.any((card) {
      final prog = widget.getCardProgress(card);
      return prog.nextReview.compareTo(today) <= 0;
    });
  }

  double _calculateCategoryProgress(GrammarCategory category) {
    if (category.cards.isEmpty) return 0.0;
    final learned = category.cards.where((c) => widget.getCardProgress(c).repetitions > 0).length;
    return learned / category.cards.length;
  }

  Color _getProgressBarColor(List<FlashCard> cards) {
    if (cards.isEmpty) return Colors.grey[800]!;

    int totalScore = 0;
    for (final card in cards) {
      final prog = widget.getCardProgress(card);
      if (prog.repetitions == 0) {
        totalScore += 0;
      } else if (prog.interval <= 1) {
        totalScore += 1;
      } else if (prog.interval <= 6) {
        totalScore += 2;
      } else if (prog.interval <= 21) {
        totalScore += 3;
      } else {
        totalScore += 4;
      }
    }

    final avgScore = totalScore / cards.length;

    if (avgScore < 0.5) {
      return Colors.grey[700]!;
    } else if (avgScore < 1.5) {
      return const Color(0xFFE74C3C);
    } else if (avgScore < 2.5) {
      return const Color(0xFFF39C12);
    } else if (avgScore < 3.5) {
      return const Color(0xFF27AE60);
    } else {
      return const Color(0xFF3498DB);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.level.level} - ${widget.level.name}'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: widget.level.categories.length,
        itemBuilder: (context, index) {
          final category = widget.level.categories[index];
          final categoryProgress = _calculateCategoryProgress(category);
          final progressColor = _getProgressBarColor(category.cards);

          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => LearningScreen(
                    title: category.name,
                    cards: category.cards,
                    progress: widget.progress,
                    onSaveProgress: widget.onSaveProgress,
                    langConfig: widget.langConfig,
                  ),
                ),
              ).then((_) => setState(() {})),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF16213E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            category.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${category.cards.length} kartiček',
                            style: TextStyle(color: Colors.grey[500], fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: categoryProgress,
                              backgroundColor: Colors.grey[800],
                              valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                              minHeight: 6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${(categoryProgress * 100).toInt()}%',
                      style: TextStyle(
                        color: progressColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.play_arrow,
                      color: _hasDueCards(category.cards)
                          ? Colors.green
                          : Colors.grey,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// Learning Screen (Flashcards)
class LearningScreen extends StatefulWidget {
  final String title;
  final List<FlashCard> cards;
  final Map<String, CardProgress> progress;
  final Function() onSaveProgress;
  final LanguageConfig langConfig;

  const LearningScreen({
    super.key,
    required this.title,
    required this.cards,
    required this.progress,
    required this.onSaveProgress,
    required this.langConfig,
  });

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  FlashCard? currentCard;
  bool showTranslation = false;
  bool isEnToCz = false;
  int todayReviewed = 0;

  late FlutterTts flutterTts;
  String? _lastCheckDate;

  @override
  void initState() {
    super.initState();
    flutterTts = FlutterTts();
    _initTts();
    _lastCheckDate = DateTime.now().toIso8601String().split('T')[0];
    _showNextCard();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkNewDay();
  }

  void _checkNewDay() {
    final today = DateTime.now().toIso8601String().split('T')[0];
    if (_lastCheckDate != today) {
      _lastCheckDate = today;
      todayReviewed = 0;
      _showNextCard();
    }
  }

  Future<void> _initTts() async {
    await flutterTts.setLanguage(widget.langConfig.ttsLocale);
    await flutterTts.setSpeechRate(0.4);
    await flutterTts.setPitch(1.0);
    await flutterTts.awaitSpeakCompletion(true);

    List<dynamic> voices = await flutterTts.getVoices;
    final langCode = widget.langConfig.code;
    final localeMatches = voices.where((v) =>
      v['locale'].toString().toLowerCase().startsWith(langCode)
    ).toList();

    // Prefer high-quality voices, fall back to any voice with matching locale
    var preferredVoices = localeMatches.where((v) =>
      v['name'].toString().toLowerCase().contains('female') ||
      v['name'].toString().toLowerCase().contains('samantha') ||
      v['name'].toString().toLowerCase().contains('google') ||
      v['name'].toString().contains('en-us-x-sfg')
    ).toList();

    final voiceToUse = preferredVoices.isNotEmpty
        ? preferredVoices.first
        : (localeMatches.isNotEmpty ? localeMatches.first : null);

    if (voiceToUse != null) {
      await flutterTts.setVoice({
        "name": voiceToUse['name'],
        "locale": voiceToUse['locale']
      });
    }
  }

  String _getCardKey(FlashCard card) {
    return card.en.substring(0, min(50, card.en.length));
  }

  CardProgress _getCardProgress(FlashCard card) {
    final key = _getCardKey(card);
    widget.progress[key] ??= CardProgress();
    return widget.progress[key]!;
  }

  List<FlashCard> _getDueCards() {
    final today = DateTime.now().toIso8601String().split('T')[0];
    return widget.cards.where((card) {
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

  Future<void> _setVoiceForLocale(String locale) async {
    final shortCode = locale.split('-').first.toLowerCase();
    try {
      final voices = await flutterTts.getVoices;
      final matches = (voices as List).where((v) =>
        v['locale'].toString().toLowerCase().startsWith(shortCode)
      ).toList();
      if (matches.isNotEmpty) {
        // Prefer Google/female/high-quality voices
        final preferred = matches.where((v) =>
          v['name'].toString().toLowerCase().contains('google') ||
          v['name'].toString().toLowerCase().contains('female')
        ).toList();
        final pick = preferred.isNotEmpty ? preferred.first : matches.first;
        await flutterTts.setVoice({
          "name": pick['name'].toString(),
          "locale": pick['locale'].toString()
        });
      } else {
        // No matching voice - reset by passing non-existent voice (clears stale voice)
        await flutterTts.setVoice({"name": "__none__", "locale": locale});
      }
    } catch (_) {}
    await flutterTts.setLanguage(locale);
  }

  Future<void> _speak() async {
    if (currentCard != null) {
      if (isEnToCz) {
        // Vidím cizí jazyk, chci slyšet CZ (odpověď)
        await _setVoiceForLocale(widget.langConfig.nativeTtsLocale);
        await flutterTts.speak(currentCard!.cz);
      } else {
        // Vidím CZ, chci slyšet cizí jazyk (odpověď)
        await _setVoiceForLocale(widget.langConfig.ttsLocale);
        await flutterTts.speak(currentCard!.en);
      }
    }
  }

  void _rate(int rating) {
    if (currentCard == null) return;

    final prog = _getCardProgress(currentCard!);
    final today = DateTime.now().toIso8601String().split('T')[0];

    // SM-2 algorithm
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

    prog.ease = max(1.3, prog.ease + (0.1 - (5 - rating) * (0.08 + (5 - rating) * 0.02)));

    final nextDate = DateTime.now().add(Duration(days: prog.interval));
    prog.nextReview = nextDate.toIso8601String().split('T')[0];
    prog.lastReview = today;

    todayReviewed++;

    widget.onSaveProgress();
    _showNextCard();
  }

  void _toggleDirection() {
    setState(() {
      isEnToCz = !isEnToCz;
    });
  }

  Color _getCardColor(FlashCard card) {
    final prog = _getCardProgress(card);
    if (prog.repetitions == 0) {
      return Colors.grey[700]!;
    } else if (prog.interval <= 1) {
      return const Color(0xFFE74C3C);
    } else if (prog.interval <= 6) {
      return const Color(0xFFF39C12);
    } else if (prog.interval <= 21) {
      return const Color(0xFF27AE60);
    } else {
      return const Color(0xFF3498DB);
    }
  }

  void _showCardsOverview() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CardsOverviewScreen(
          cards: widget.cards,
          getCardColor: _getCardColor,
          getCardProgress: _getCardProgress,
          flutterTts: flutterTts,
          langConfig: widget.langConfig,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dueCards = _getDueCards();
    final learned = widget.cards.where((c) => _getCardProgress(c).repetitions > 0).length;
    final progressPercent = widget.cards.isNotEmpty ? learned / widget.cards.length : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.grid_view),
            onPressed: _showCardsOverview,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(
                'K opakování: ${dueCards.length} | Naučeno: $learned/${widget.cards.length} | Dnes: $todayReviewed',
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
              ),
              const SizedBox(height: 10),

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

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildDirectionButton(widget.langConfig.directionLabel(true), isEnToCz),
                  const SizedBox(width: 10),
                  _buildDirectionButton(widget.langConfig.directionLabel(false), !isEnToCz),
                ],
              ),
              const SizedBox(height: 20),

              Expanded(child: _buildCard()),
              const SizedBox(height: 20),

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

  String _getNextReviewInfo() {
    final today = DateTime.now();
    final todayStr = today.toIso8601String().split('T')[0];

    String? nearestDate;
    for (final card in widget.cards) {
      final prog = _getCardProgress(card);
      if (prog.nextReview.compareTo(todayStr) > 0) {
        if (nearestDate == null || prog.nextReview.compareTo(nearestDate) < 0) {
          nearestDate = prog.nextReview;
        }
      }
    }

    if (nearestDate == null) return '✨ Vše naučeno!';

    final nextDate = DateTime.parse(nearestDate);
    final diff = nextDate.difference(today).inDays + 1;

    if (diff <= 1) return '📅 Další opakování: zítra';
    return '📅 Další opakování: za $diff dní';
  }

  Widget _buildCard() {
    if (currentCard == null) {
      final nextInfo = _getNextReviewInfo();
      final message = todayReviewed > 0 ? '🎉 Hotovo na dnes!' : '📚 Žádné kartičky na dnes';

      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF16213E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                message,
                style: const TextStyle(fontSize: 24),
              ),
              const SizedBox(height: 16),
              Text(
                nextInfo,
                style: TextStyle(fontSize: 16, color: Colors.grey[400]),
              ),
            ],
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
            color: Colors.black.withValues(alpha: 0.3),
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

// Cards Overview Screen
class CardsOverviewScreen extends StatelessWidget {
  final List<FlashCard> cards;
  final Color Function(FlashCard) getCardColor;
  final CardProgress Function(FlashCard) getCardProgress;
  final FlutterTts flutterTts;
  final LanguageConfig langConfig;

  const CardsOverviewScreen({
    super.key,
    required this.cards,
    required this.getCardColor,
    required this.getCardProgress,
    required this.flutterTts,
    required this.langConfig,
  });

  void _showCardDetail(BuildContext context, FlashCard card) {
    final prog = getCardProgress(card);
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
            onPressed: () async {
              await flutterTts.setLanguage(langConfig.ttsLocale);
              await flutterTts.speak(card.en);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: const Text('Přehled kartiček'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
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
                      color: getCardColor(card),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ===== Němčina s úsměvem =====

class NemeckySUsmevemLesson {
  final int number;
  final String title;
  final String file;
  NemeckySUsmevemLesson({required this.number, required this.title, required this.file});
}

class NemeckySUsmevemScreen extends StatefulWidget {
  final Map<String, CardProgress> progress;
  final Function() onSaveProgress;
  final LanguageConfig langConfig;

  const NemeckySUsmevemScreen({
    super.key,
    required this.progress,
    required this.onSaveProgress,
    required this.langConfig,
  });

  @override
  State<NemeckySUsmevemScreen> createState() => _NemeckySUsmevemScreenState();
}

class _NemeckySUsmevemScreenState extends State<NemeckySUsmevemScreen> {
  List<NemeckySUsmevemLesson> lessons = [];
  Set<int> selectedLessons = {};
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadManifest();
  }

  Future<void> _loadManifest() async {
    try {
      final manifestStr = await rootBundle.loadString('assets/nemecky_s_usmevem/manifest.json');
      final manifest = json.decode(manifestStr) as Map<String, dynamic>;
      final list = manifest['lessons'] as List;
      setState(() {
        lessons = list.map((l) => NemeckySUsmevemLesson(
          number: l['number'] as int,
          title: l['title'] as String,
          file: l['file'] as String,
        )).toList();
        isLoading = false;
      });
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  Future<List<FlashCard>> _loadSelectedCards() async {
    final List<FlashCard> all = [];
    for (final lesson in lessons) {
      if (!selectedLessons.contains(lesson.number)) continue;
      try {
        final str = await rootBundle.loadString('assets/nemecky_s_usmevem/${lesson.file}');
        final data = json.decode(str) as Map<String, dynamic>;
        final cards = data['cards'] as List? ?? [];
        for (final c in cards) {
          all.add(FlashCard(
            en: c['de'] as String,
            cz: c['cz'] as String,
            category: 'Lekce ${lesson.number}',
          ));
        }
        final vazby = data['vazby'] as List? ?? [];
        for (final v in vazby) {
          all.add(FlashCard(
            en: v['de'] as String,
            cz: v['cz'] as String,
            category: 'Lekce ${lesson.number} - vazby',
          ));
        }
      } catch (_) {}
    }
    return all;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Němčina s úsměvem'),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
                    ),
                    child: const Text(
                      '⚠️ Obsah pochází z učebnice "Německy s úsměvem - nově" '
                      '(Fraus 2003). Použito pouze pro osobní studium v rámci '
                      'soukromé skupiny. Není povoleno volné šíření.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: lessons.length,
                    itemBuilder: (context, index) {
                      final lesson = lessons[index];
                      final isSelected = selectedLessons.contains(lesson.number);
                      return CheckboxListTile(
                        value: isSelected,
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              selectedLessons.add(lesson.number);
                            } else {
                              selectedLessons.remove(lesson.number);
                            }
                          });
                        },
                        title: Text('Lekce ${lesson.number}: ${lesson.title}'),
                      );
                    },
                  ),
                ),
                if (selectedLessons.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.school),
                        label: Text('Učit se (${selectedLessons.length} ${selectedLessons.length == 1 ? "lekce" : "lekcí"})'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: const Color(0xFF00FF88),
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () async {
                          final cards = await _loadSelectedCards();
                          if (cards.isEmpty) return;
                          if (!mounted) return;
                          final selectedNumbers = selectedLessons.toList()..sort();
                          final title = selectedNumbers.length == 1
                              ? 'Lekce ${selectedNumbers.first}'
                              : 'Lekce ${selectedNumbers.join(", ")}';
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => LearningScreen(
                                title: title,
                                cards: cards,
                                progress: widget.progress,
                                onSaveProgress: widget.onSaveProgress,
                                langConfig: widget.langConfig,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
