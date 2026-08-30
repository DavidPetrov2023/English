import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:http/http.dart' as http;
import 'web_audio_stub.dart' if (dart.library.html) 'web_audio_web.dart' as web_audio;
import 'sw_update_stub.dart' if (dart.library.html) 'sw_update_web.dart' as sw_update;

enum AppLanguage { en, de, cs }

class LanguageConfig {
  final AppLanguage language;
  const LanguageConfig(this.language);

  String get code => switch (language) {
    AppLanguage.en => 'en',
    AppLanguage.de => 'de',
    AppLanguage.cs => 'cs',
  };
  String get ttsLocale => switch (language) {
    AppLanguage.en => 'en-US',
    AppLanguage.de => 'de-DE',
    AppLanguage.cs => 'cs-CZ',
  };
  String get nativeTtsLocale => 'cs-CZ';
  String get label => switch (language) {
    AppLanguage.en => 'Angličtina',
    AppLanguage.de => 'Němčina',
    AppLanguage.cs => 'Čeština',
  };
  String get labelGenitive => switch (language) {
    AppLanguage.en => 'angličtiny',
    AppLanguage.de => 'němčiny',
    AppLanguage.cs => 'češtiny',
  };
  String get shortLabel => switch (language) {
    AppLanguage.en => 'EN',
    AppLanguage.de => 'DE',
    AppLanguage.cs => 'CZ',
  };
  String get flagEmoji => switch (language) {
    AppLanguage.en => '🇺🇸',
    AppLanguage.de => '🇩🇪',
    AppLanguage.cs => '🇨🇿',
  };
  String get cardsAsset => language == AppLanguage.en ? 'assets/cards.json' : 'assets/cards_de.json';
  String get grammarAssetPrefix => language == AppLanguage.en ? 'assets/grammar_' : 'assets/grammar_de_';
  String get addCardLabel => language == AppLanguage.en ? 'Anglicky' : 'Německy';
  String get addCardHint => language == AppLanguage.en ? 'Hello, how are you?' : 'Hallo, wie geht es dir?';
  String get backupFilePrefix => switch (language) {
    AppLanguage.en => 'english',
    AppLanguage.de => 'german',
    AppLanguage.cs => 'czech',
  };

  // SharedPreferences keys - per language
  String get progressKey => '${code}_progress';
  String get myCardsKey => '${code}_myCards';
  String get myCardsNameKey => '${code}_myCardsName';
  String get lastBackupDateKey => '${code}_lastBackupDate';
  String get lastBackupProgressCountKey => '${code}_lastBackupProgressCount';
  String get lastBackupCardsCountKey => '${code}_lastBackupCardsCount';
  String get hasUnsavedProgressKey => '${code}_hasUnsavedProgress';

  String directionLabel(bool isForeignToCz) {
    if (language == AppLanguage.cs) {
      return isForeignToCz ? 'Otázka → Odpověď' : 'Odpověď → Otázka';
    }
    return isForeignToCz ? '$shortLabel → CZ' : 'CZ → $shortLabel';
  }

  static LanguageConfig? fromCode(String code) {
    for (final lang in AppLanguage.values) {
      if (lang.name == code) return LanguageConfig(lang);
    }
    return null;
  }
}

final GlobalKey<ScaffoldMessengerState> _appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

// ===== Backup status (sdílený mezi HomeScreen a LearningScreen) =====

enum BackupStatus { disabled, empty, pending, syncing, synced, error }

class BackupStatusController extends ChangeNotifier {
  BackupStatus _status = BackupStatus.synced;
  DateTime? _lastBackup;
  String? _errorMessage;

  BackupStatus get status => _status;
  DateTime? get lastBackup => _lastBackup;
  String? get errorMessage => _errorMessage;

  void update(BackupStatus s, {DateTime? lastBackup, String? errorMessage}) {
    _status = s;
    if (lastBackup != null) _lastBackup = lastBackup;
    _errorMessage = errorMessage;
    notifyListeners();
  }
}

final backupStatus = BackupStatusController();

class BackupStatusIcon extends StatefulWidget {
  final VoidCallback? onPressed;
  final bool requiresAuth;
  const BackupStatusIcon({super.key, this.onPressed, this.requiresAuth = true});

  @override
  State<BackupStatusIcon> createState() => _BackupStatusIconState();
}

class _BackupStatusIconState extends State<BackupStatusIcon> {
  bool _hasAuth = true;

  @override
  void initState() {
    super.initState();
    backupStatus.addListener(_onStatusChange);
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    if (!widget.requiresAuth) {
      if (mounted) setState(() => _hasAuth = true);
      return;
    }
    final p = await SharedPreferences.getInstance();
    final t = p.getString(AuthService.kTokenKey) ?? '';
    if (!mounted) return;
    setState(() => _hasAuth = t.isNotEmpty);
  }

  void _onStatusChange() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    backupStatus.removeListener(_onStatusChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.requiresAuth && !_hasAuth) return const SizedBox.shrink();

    final s = backupStatus.status;
    final last = backupStatus.lastBackup;
    late IconData icon;
    late Color color;
    late String tooltip;

    switch (s) {
      case BackupStatus.disabled:
        icon = Icons.cloud_off_outlined;
        color = Colors.grey;
        tooltip = 'Záloha vypnuta';
        break;
      case BackupStatus.empty:
        icon = Icons.cloud_outlined;
        color = Colors.grey;
        tooltip = 'Žádná data k záloze';
        break;
      case BackupStatus.pending:
        icon = Icons.cloud_upload_outlined;
        color = Colors.orange;
        tooltip = 'Čeká na zálohu';
        break;
      case BackupStatus.syncing:
        icon = Icons.sync;
        color = const Color(0xFF00D9FF);
        tooltip = 'Synchronizuji…';
        break;
      case BackupStatus.synced:
        icon = Icons.cloud_done_outlined;
        color = const Color(0xFF00FF88);
        tooltip = last != null
            ? 'Zálohováno ${last.day}.${last.month}.${last.year} '
                '${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}'
            : 'Synchronizováno';
        break;
      case BackupStatus.error:
        icon = Icons.cloud_off_outlined;
        color = Colors.redAccent;
        tooltip = backupStatus.errorMessage ?? 'Chyba synchronizace';
        break;
    }

    // Při syncing zobraz spinner overlay přes ikonu — využívá CircularProgressIndicator
    // (na webu spolehlivě animuje, na rozdíl od RotationTransition).
    final Widget iconWidget = s == BackupStatus.syncing
        ? SizedBox(
            width: 22,
            height: 22,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, size: 16, color: color),
                CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ],
            ),
          )
        : Icon(icon, size: 22, color: color);

    return IconButton(
      icon: iconWidget,
      tooltip: tooltip,
      onPressed: widget.onPressed,
    );
  }
}

void main() {
  if (kIsWeb) {
    sw_update.startVersionPolling((newVersion) {
      _appMessengerKey.currentState?.showSnackBar(
        SnackBar(
          duration: const Duration(days: 365),
          backgroundColor: const Color(0xFF00D9FF),
          content: const Text(
            'Je k dispozici nová verze aplikace.',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          ),
          action: SnackBarAction(
            label: 'NAČÍST ZNOVU',
            textColor: Colors.black,
            onPressed: () {
              sw_update.applyUpdate();
            },
          ),
        ),
      );
    });
  }
  runApp(const EnglishLearningApp());
}

class EnglishLearningApp extends StatelessWidget {
  const EnglishLearningApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LangCards',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _appMessengerKey,
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
      home: _isPrvoukaMode() ? const PrvoukaHomeScreen() : const AuthGate(),
    );
  }

  static bool _isPrvoukaMode() {
    if (!kIsWeb) return false;
    try {
      return (Uri.base.queryParameters['prvouka'] ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}

/// Normalizace pro hledání/porovnávání: lowercase + odstranění diakritiky (cs/de).
String searchFold(String s) {
  const map = {
    'á': 'a', 'č': 'c', 'ď': 'd', 'é': 'e', 'ě': 'e', 'í': 'i', 'ň': 'n',
    'ó': 'o', 'ř': 'r', 'š': 's', 'ť': 't', 'ú': 'u', 'ů': 'u', 'ý': 'y',
    'ž': 'z', 'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 'ss',
  };
  var out = s.toLowerCase();
  map.forEach((k, v) => out = out.replaceAll(k, v));
  return out;
}

// Data models
class FlashCard {
  final String en;
  final String cz;
  final String category;
  final String? note; // gramatická nápověda — v UI pod ikonou ⓘ

  FlashCard({required this.en, required this.cz, required this.category, this.note});

  factory FlashCard.fromJson(Map<String, dynamic> json) {
    final note = json['note'] as String?;
    return FlashCard(
      en: json['en'] ?? '',
      cz: json['cz'] ?? '',
      category: json['category'] ?? '',
      note: (note != null && note.isNotEmpty) ? note : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'en': en,
        'cz': cz,
        'category': category,
        if (note != null) 'note': note,
      };
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
  final String? info; // vysvětlení gramatiky s příkladem — v UI pod ikonou ⓘ
  final List<FlashCard> cards;

  GrammarCategory({
    required this.id,
    required this.name,
    this.info,
    required this.cards,
  });

  factory GrammarCategory.fromJson(Map<String, dynamic> json) {
    final info = json['info'] as String?;
    return GrammarCategory(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      info: (info != null && info.isNotEmpty) ? info : null,
      cards: (json['cards'] as List? ?? [])
          .map((c) => FlashCard.fromJson({...c, 'category': json['name']}))
          .toList(),
    );
  }
}

// Home Screen
class HomeScreen extends StatefulWidget {
  final Map<String, dynamic>? remoteBackup;
  const HomeScreen({super.key, this.remoteBackup});

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
  bool _remoteBackupApplied = false;

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

  Future<void> _applyRemoteBackup(Map<String, dynamic> backup) async {
    // Backup format from server is {data: {...}, size_bytes, updated_at}
    final inner = backup['data'] is Map ? backup['data'] as Map<String, dynamic> : backup;
    if (inner['version'] == '3.0' && inner['languages'] != null) {
      final languages = inner['languages'] as Map<String, dynamic>;
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
      }
    }
  }

  /// Globální „David Petrov" karty: server (živé updaty od admina) → lokální
  /// cache (offline) → bundlovaný asset (první spuštění bez sítě).
  /// Filtruje na kategorii 'Gramatika věty' (stejně jako původní asset load).
  Future<List<FlashCard>> _loadDavidCards() async {
    final cacheKey = 'david_cards_cache_${langConfig.code}';
    Map<String, dynamic>? jsonData;

    final res = await AuthService.getDavidCards(langConfig.code);
    if (res.statusCode == 200 && res.body?['cards'] is List) {
      jsonData = res.body;
      await prefs.setString(cacheKey, json.encode(res.body));
    } else {
      final cached = prefs.getString(cacheKey);
      if (cached != null) {
        try {
          jsonData = json.decode(cached) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    if (jsonData == null) {
      try {
        jsonData = json.decode(await rootBundle.loadString(langConfig.cardsAsset))
            as Map<String, dynamic>;
      } catch (e) {
        debugPrint('Error loading David cards: $e');
        return [];
      }
    }
    final List<dynamic> cardsList = jsonData['cards'] ?? [];
    return cardsList
        .map((c) => FlashCard.fromJson(c))
        .where((c) => c.category == 'Gramatika věty')
        .toList();
  }

  /// Existují v zařízení lokální data (pokrok nebo vlastní kartičky)?
  bool _hasAnyLocalData() {
    for (final lang in AppLanguage.values) {
      if (lang == AppLanguage.cs) continue;
      final lc = LanguageConfig(lang);
      final prog = prefs.getString(lc.progressKey);
      final cards = prefs.getString(lc.myCardsKey);
      if ((prog != null && prog.isNotEmpty && prog != '{}') ||
          (cards != null && cards.isNotEmpty && cards != '[]')) {
        return true;
      }
    }
    return false;
  }

  /// Zapamatovaná odpověď na konflikt záloh (true = vždy stáhnout ze serveru,
  /// false = vždy ponechat data v zařízení, null = pokaždé se zeptat).
  static const String kBackupConflictChoiceKey = 'backupConflictChoice';

  /// Dialog: lokální data vs. serverová záloha. true = stáhnout ze serveru.
  /// Zaškrtnutím „Příště se neptat" se volba uloží a dialog se už neukáže.
  Future<bool?> _askBackupConflict() async {
    bool remember = false;
    final choice = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF16213E),
          title: const Text('Nalezena záloha na serveru'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'V tomto zařízení už jsou uložená data (pokrok nebo kartičky) '
                'a zároveň existuje záloha na serveru.\n\n'
                'Kterou verzi chceš použít?\n\n'
                'Pozn.: pokud ponecháš data v zařízení, serverová záloha se při '
                'příští synchronizaci přepíše těmito daty.',
                style: TextStyle(height: 1.4),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setDialogState(() => remember = !remember),
                child: Row(
                  children: [
                    Checkbox(
                      value: remember,
                      activeColor: const Color(0xFF00D9FF),
                      checkColor: Colors.black,
                      onChanged: (v) =>
                          setDialogState(() => remember = v ?? false),
                    ),
                    const Expanded(
                      child: Text(
                        'Příště se neptat (volbu lze změnit v nastavení)',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Ponechat data v zařízení'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D9FF),
                foregroundColor: Colors.black,
              ),
              child: const Text('Stáhnout zálohu ze serveru'),
            ),
          ],
        ),
      ),
    );
    if (choice != null && remember) {
      await prefs.setBool(kBackupConflictChoiceKey, choice);
    }
    return choice;
  }

  static const Set<String> _adminEmails = {'johndave@seznam.cz'};

  bool _isAdmin() {
    final email = (prefs.getString(AuthService.kEmailKey) ?? '').toLowerCase();
    return _adminEmails.contains(email);
  }

  Future<void> _clearLocalAppState() async {
    for (final lang in AppLanguage.values) {
      if (lang == AppLanguage.cs) continue; // Prvouka data is independent of main app
      final lc = LanguageConfig(lang);
      await prefs.remove(lc.progressKey);
      await prefs.remove(lc.myCardsKey);
      await prefs.remove(lc.myCardsNameKey);
      await prefs.remove(lc.lastBackupDateKey);
      await prefs.remove(lc.lastBackupProgressCountKey);
      await prefs.remove(lc.lastBackupCardsCountKey);
      await prefs.remove(lc.hasUnsavedProgressKey);
    }
  }

  Future<void> _loadAllData() async {
    prefs = await SharedPreferences.getInstance();

    // Migrate old data (one-time)
    await _migrateOldData();

    // Detekce změny účtu - smažeme lokální data jen když se jeden účet
    // přepne na druhý. Při prvním přihlášení (lastEmail == null) lokální
    // data zachováme - migrace existujících mobile uživatelů.
    final currentEmail = prefs.getString(AuthService.kEmailKey);
    final lastEmail = prefs.getString('last_logged_in_email');
    if (lastEmail != null && currentEmail != null && currentEmail != lastEmail) {
      await _clearLocalAppState();
    }
    if (currentEmail != null) {
      await prefs.setString('last_logged_in_email', currentEmail);
    }

    // Apply remote backup if provided (from AuthGate after login).
    // Pouze JEDNOU - další volání _loadAllData (např. při přepnutí jazyka)
    // zachovají aktuální stav prefs (včetně lokálně obnovených dat).
    if (widget.remoteBackup != null && !_remoteBackupApplied) {
      // Konflikt: v zařízení už jsou lokální data (guest / předchozí session).
      // Bez dotazu by je serverová záloha tiše přepsala.
      bool apply = true;
      if (_hasAnyLocalData() && mounted) {
        // Uživatel si mohl volbu zapamatovat („Příště se neptat").
        final remembered = prefs.getBool(kBackupConflictChoiceKey);
        // Vychozi false: kdyz dialog skonci bez odpovedi (na Androidu staci
        // systemove Zpet, barrierDismissible: false ho neblokuje), nesmi se
        // sahnout na lokalni data. Ta ticha volba byla driv ta destruktivni.
        apply = remembered ?? (await _askBackupConflict() ?? false);
      }
      if (apply) {
        await _applyRemoteBackup(widget.remoteBackup!);
      } else {
        // Dialog slibuje, ze se serverova zaloha prepise temito daty.
        // Bez tohohle radku se to nestalo: upload spousti jen editace
        // karticky nebo pokroku, takze slib platil az nekdy priste, nebo
        // nikdy - a server zustal navzdycky stary.
        _scheduleAutoBackup();
      }
      _remoteBackupApplied = true;
    }

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

    // Load David's cards (author's cards): server → cache → bundlovaný asset
    davidCards = await _loadDavidCards();

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
    _refreshBackupStatus();

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
    backupStatus.update(BackupStatus.pending);
    _scheduleAutoBackup();
  }

  bool _backupInFlight = false;

  void _scheduleAutoBackup() {
    final token = prefs.getString(AuthService.kTokenKey);
    if (token == null || token.isEmpty) return;
    _doAutoBackup();
  }

  Future<void> _doAutoBackup() async {
    final token = prefs.getString(AuthService.kTokenKey);
    if (token == null || token.isEmpty) return;
    if (_backupInFlight) return;
    _backupInFlight = true;
    backupStatus.update(BackupStatus.syncing);
    try {
      final Map<String, dynamic> allLangs = {};
      for (final lang in AppLanguage.values) {
        if (lang == AppLanguage.cs) continue; // Prvouka data not synced to cloud
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
      final payload = {
        'version': '3.0',
        'date': DateTime.now().toIso8601String(),
        'languages': allLangs,
      };
      final res = await AuthService.uploadBackup(token, payload);
      if (res.statusCode == 401) {
        await prefs.remove(AuthService.kTokenKey);
        await prefs.remove(AuthService.kEmailKey);
        backupStatus.update(BackupStatus.error, errorMessage: 'Vypršela platnost přihlášení');
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const AuthGate()),
            (_) => false,
          );
        }
      } else if (res.statusCode == 200) {
        lastBackupDate = DateTime.now();
        hasUnsavedProgress = false;
        for (final lang in AppLanguage.values) {
          if (lang == AppLanguage.cs) continue;
          final lc = LanguageConfig(lang);
          await prefs.setString(lc.lastBackupDateKey, lastBackupDate!.toIso8601String());
          await prefs.setBool(lc.hasUnsavedProgressKey, false);
        }
        backupStatus.update(BackupStatus.synced, lastBackup: lastBackupDate);
        if (mounted) setState(() {});
      } else {
        backupStatus.update(BackupStatus.error,
            errorMessage: 'Server vrátil ${res.statusCode}');
      }
    } catch (e) {
      backupStatus.update(BackupStatus.error, errorMessage: 'Síťová chyba');
    } finally {
      _backupInFlight = false;
    }
  }

  /// Nastaví status ikony podle aktuálního stavu po načtení dat.
  void _refreshBackupStatus() {
    final token = prefs.getString(AuthService.kTokenKey) ?? '';
    if (!backupEnabled) {
      backupStatus.update(BackupStatus.disabled, lastBackup: lastBackupDate);
      return;
    }
    if (token.isEmpty) {
      backupStatus.update(BackupStatus.disabled, lastBackup: lastBackupDate);
      return;
    }
    if (progress.isEmpty && myCards.isEmpty) {
      backupStatus.update(BackupStatus.empty, lastBackup: lastBackupDate);
      return;
    }
    if (hasUnsavedProgress) {
      backupStatus.update(BackupStatus.pending, lastBackup: lastBackupDate);
      return;
    }
    backupStatus.update(BackupStatus.synced, lastBackup: lastBackupDate);
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
    // "Naučeno" = modré (interval > 21d), konzistentní s LearningScreen.
    final learned = cards.where((c) => _getCardProgress(c).interval > 21).length;
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
      if (lang == AppLanguage.cs) continue; // Prvouka data is independent of main app
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
        if (lang == AppLanguage.cs) continue;
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

      // Po obnovení ze souboru nahrát data na server (pokud je přihlášený)
      _scheduleAutoBackup();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Chyba při obnovení: $e')),
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
      builder: (context) => SafeArea(
        // top: false — sheet je dole; bottom inset chrání před navigační lištou
        top: false,
        child: SingleChildScrollView(
        child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((prefs.getString(AuthService.kTokenKey) ?? '').isNotEmpty) ...[
              ListTile(
                leading: const Icon(Icons.account_circle, color: Color(0xFF00D9FF)),
                title: Text('Přihlášen: ${prefs.getString(AuthService.kEmailKey) ?? ''}'),
                subtitle: const Text('Záloha se synchronizuje automaticky'),
              ),
              if (_isAdmin())
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings, color: Color(0xFFFFD700)),
                  title: const Text('Admin přehled'),
                  subtitle: const Text('Seznam uživatelů a jejich aktivita'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AdminScreen()),
                    );
                  },
                ),
              if (prefs.getBool(kBackupConflictChoiceKey) != null)
                ListTile(
                  leading: const Icon(Icons.help_outline, color: Color(0xFF00D9FF)),
                  title: const Text('Znovu se ptát na konflikt záloh'),
                  subtitle: Text(
                    prefs.getBool(kBackupConflictChoiceKey)!
                        ? 'Nyní: vždy stáhnout zálohu ze serveru'
                        : 'Nyní: vždy ponechat data v zařízení',
                  ),
                  onTap: () async {
                    await prefs.remove(kBackupConflictChoiceKey);
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Při dalším konfliktu se aplikace zeptá'),
                        ),
                      );
                    }
                  },
                ),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text('Odhlásit'),
                onTap: () async {
                  await prefs.remove(AuthService.kTokenKey);
                  await prefs.remove(AuthService.kEmailKey);
                  // Ponecháme 'last_logged_in_email' pro předvyplnění při příštím loginu.
                  await _clearLocalAppState();
                  if (context.mounted) {
                    Navigator.pop(context);
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const AuthGate()),
                      (_) => false,
                    );
                  }
                },
              ),
              const Divider(color: Colors.grey),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.login, color: Color(0xFF00FF88)),
                title: const Text('Přihlásit se'),
                subtitle: const Text('Automatická záloha kartiček a pokroku na server'),
                onTap: () {
                  // NavigatorState si vezmeme PŘED zavřením sheetu — context sheetu
                  // je v době onLoggedIn callbacku už odpojený (deactivated).
                  final nav = Navigator.of(context);
                  nav.pop();
                  nav.push(
                    MaterialPageRoute(
                      builder: (_) => LoginScreen(
                        prefs: prefs,
                        onLoggedIn: () {
                          // AuthGate stáhne zálohu ze serveru a předá ji HomeScreen.
                          // poPrihlaseni: tohle je jediné místo, kde se má řešit
                          // konflikt s lokálními daty.
                          nav.pushAndRemoveUntil(
                            MaterialPageRoute(
                                builder: (_) => const AuthGate(poPrihlaseni: true)),
                            (_) => false,
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
              const Divider(color: Colors.grey),
            ],
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
              leading: const Icon(Icons.info_outline, color: Colors.grey),
              title: const Text('O aplikaci'),
              onTap: () {
                Navigator.pop(context);
                _showAboutDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.help_outline, color: Color(0xFF00D9FF)),
              title: const Text('Jak to funguje'),
              subtitle: const Text('SM-2 algoritmus a Boost'),
              onTap: () {
                Navigator.pop(context);
                _showHowItWorksDialog();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
        ),
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
        content: const Text(
          'LangCards v1.5.1\n\n'
          'Aplikace pro učení cizích jazyků pomocí kartiček.\n\n'
          'Autor: David Petrov',
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

  void _showHowItWorksDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Jak to funguje'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text(
                '📚 SM-2 algoritmus (normální režim)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              SizedBox(height: 6),
              Text(
                'Klasický algoritmus „spaced repetition" (rozložené opakování). '
                'Každá kartička má svůj plán: po správném zhodnocení se interval '
                'do dalšího opakování zvětšuje, po chybě se vrací na začátek.\n\n'
                'Kartičky které dnes „nejsou na řadě" (nextReview > dnes) se '
                'normálně neukazují. Když projedeš všechny splatné, uvidíš '
                '„Hotovo na dnes".',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              SizedBox(height: 14),
              Text(
                '🎯 Hodnocení kartiček',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              SizedBox(height: 6),
              Text(
                '• Těžké → karta zčervená (Těžká), interval = 1 den, brzy ji uvidíš znovu\n'
                '• Snadné v normálním režimu → postupný SM-2: interval '
                'roste (1 → 6 → 15 → 37 → 92 dní…)\n'
                '• Snadné v Boost režimu → skok rovnou do „Naučená" '
                '(modrá, interval ~90 dní)',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              SizedBox(height: 14),
              Text(
                '🎨 Stavy kartiček (barvy)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              SizedBox(height: 6),
              Text(
                '• Šedá – Nová (ještě nikdy)\n'
                '• Červená – Těžká (potřebuje cvičit)\n'
                '• Oranžová – Učí se\n'
                '• Zelená – Dobrá\n'
                '• Modrá – Naučená 💙',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              SizedBox(height: 14),
              Text(
                '🔥 Boost před lekcí',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              SizedBox(height: 6),
              Text(
                'Tlačítko „Boost před lekcí" se objeví na konci normálního '
                'cvičení (i když jsou všechny kartičky už Naučené).\n\n'
                '1. kolo: Projdou se VŠECHNY kartičky (i Naučené - pro '
                'připomenutí). Ignoruje SM-2 plán.\n\n'
                '• Klikání „Snadné" → karty co znáš zůstanou/přejdou '
                'do Naučená (modré)\n'
                '• Klikání „Těžké" → karty co neumíš se vrátí v dalším kole\n\n'
                'Další kola: Opakují se už jen ty co stále neumíš. Cyklicky, '
                'dokud nejsou všechny modré 💙.\n\n'
                'Použití: před lekcí němčiny si rychle projedeš všechno - '
                'rychle odbavíš to co umíš a soustředíš se na to co ne.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              SizedBox(height: 14),
              Text(
                '⌨️ Klávesnice (desktop)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              SizedBox(height: 6),
              Text(
                '• Mezerník / Enter → 🔊 přečíst + ukázat překlad\n'
                '• ← → Těžké\n'
                '• → → Snadné',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
            ],
          ),
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
    if (lastBackupDate == null) return progress.isNotEmpty || myCards.isNotEmpty;
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
      iconColor = Colors.grey;
      iconData = Icons.cloud_outlined;
      tooltip = 'Žádná data k zálohování';
    } else if (_needsBackup()) {
      iconColor = Colors.orange;
      iconData = Icons.cloud_upload_outlined;
      tooltip = 'Nová data k záloze';
    } else {
      iconColor = const Color(0xFF00FF88);
      iconData = Icons.cloud_done_outlined;
      tooltip = lastBackupDate != null
          ? 'Zálohováno ${lastBackupDate!.day}.${lastBackupDate!.month}.${lastBackupDate!.year}'
          : 'Synchronizováno';
    }

    return IconButton(
      icon: Icon(iconData, size: 22, color: iconColor),
      tooltip: tooltip,
      onPressed: _shareBackup,
    );
  }

  static const String _nemeckyUsmevUnlockedKey = 'nemecky_usmev_unlocked';

  Future<void> _openNemeckySUsmevem() async {
    // Auth is handled at app level; just show disclaimer once.
    final accepted = prefs.getBool(_nemeckyUsmevUnlockedKey) ?? false;
    if (!accepted) {
      final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF16213E),
          title: const Text('Upozornění'),
          content: const Text(
            'Slovní zásobu z této sekce používáme pouze pro osobní studium v rámci '
            'soukromé výukové skupiny. Není povoleno volné šíření, kopírování nebo '
            'distribuce mimo tuto skupinu.\n\n'
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
          final authEmail = prefs.getString(AuthService.kEmailKey) ?? '';
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('LangCards', style: TextStyle(fontSize: 18)),
              if (authEmail.isNotEmpty)
                Text(
                  '☁️ $authEmail',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF00D9FF)),
                ),
            ],
          );
        }),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          BackupStatusIcon(onPressed: _shareBackup),
          // Language picker
          IconButton(
            icon: Text(langConfig.flagEmoji, style: const TextStyle(fontSize: 22)),
            tooltip: langConfig.label,
            onPressed: _showLanguagePicker,
          ),
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
                      onDeleteCard: (card) async {
                        setState(() {
                          myCards.removeWhere((c) => c.en == card.en && c.cz == card.cz);
                        });
                        await _saveMyCards();
                        return true;
                      },
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
                        // Mazání globálních karet: jen admin, server ověřuje ADMIN_EMAILS
                        onDeleteCard: _isAdmin() ? _deleteDavidCard : null,
                      ),
                    ),
                  ).then((_) => setState(() {})),
                  onInfoTap: _showAuthorInfo,
                  onAddCard: _isAdmin() ? () => _addNewCard(presetDavid: true) : null,
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
    _scheduleAutoBackup();
  }

  Future<void> _addNewCard({bool presetDavid = false}) async {
    final isAdminUser = _isAdmin();
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AddCardScreen(
          langConfig: langConfig,
          isAdmin: isAdminUser,
          presetDavid: presetDavid,
          existingCards: [...davidCards, ...myCards],
        ),
      ),
    );
    if (result == null) return;
    final en = result['en'] as String;
    final cz = result['cz'] as String;
    final note = (result['note'] as String?) ?? '';
    if (isAdminUser && result['toDavid'] == true) {
      await _addDavidCard(en, cz, note);
    } else {
      setState(() {
        myCards.add(FlashCard(en: en, cz: cz, category: myCardsName));
      });
      await _saveMyCards();
    }
  }

  /// Admin: smaže globální kartu přes API (všem uživatelům!). Vrací úspěch.
  Future<bool> _deleteDavidCard(FlashCard card) async {
    final token = prefs.getString(AuthService.kTokenKey);
    if (token == null || token.isEmpty) return false;
    try {
      final res = await AuthService.deleteDavidCard(token, {
        'lang': langConfig.code,
        'en': card.en,
      });
      if (res.statusCode != 200) return false;
      setState(() {
        davidCards.removeWhere((c) => c.en == card.en);
      });
      await prefs.setString(
        'david_cards_cache_${langConfig.code}',
        json.encode({'cards': davidCards.map((c) => c.toJson()).toList()}),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Admin: přidá kartu do globálních „David Petrov kartičky" přes API.
  Future<void> _addDavidCard(String en, String cz, String note) async {
    final token = prefs.getString(AuthService.kTokenKey);
    final messenger = ScaffoldMessenger.of(context);
    if (token == null || token.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Pro přidání globální karty se musíš přihlásit.')));
      return;
    }
    try {
      final res = await AuthService.addDavidCard(token, {
        'lang': langConfig.code,
        'en': en,
        'cz': cz,
        'category': 'Gramatika věty',
        if (note.isNotEmpty) 'note': note,
      });
      if (res.statusCode == 200) {
        setState(() {
          davidCards.add(FlashCard(
            en: en,
            cz: cz,
            category: 'Gramatika věty',
            note: note.isNotEmpty ? note : null,
          ));
        });
        // Aktualizace cache, ať nová karta přežije restart i offline
        await prefs.setString(
          'david_cards_cache_${langConfig.code}',
          json.encode({'cards': davidCards.map((c) => c.toJson()).toList()}),
        );
        messenger.showSnackBar(const SnackBar(
            content: Text('Přidáno do David Petrov kartiček (globálně)')));
      } else if (res.statusCode == 409) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Karta se stejným textem už v David Petrov existuje.')));
      } else if (res.statusCode == 403) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Server tě neuznal jako admina (403).')));
      } else {
        messenger.showSnackBar(SnackBar(
            content: Text('Chyba při přidávání (${res.statusCode}).')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Chyba spojení: $e')));
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
    VoidCallback? onAddCard, // jen pro admina — přidání globální karty
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
                if (onAddCard != null) ...[
                  IconButton(
                    icon: const Icon(Icons.add_circle, color: Color(0xFFFFD700), size: 22),
                    tooltip: 'Přidat globální kartičku (admin)',
                    onPressed: onAddCard,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 8),
                ],
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
    final learned = category.cards.where((c) => widget.getCardProgress(c).interval > 21).length;
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

  void _showCategoryInfo(GrammarCategory category) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: Row(
          children: [
            const Icon(Icons.info_outline, color: Color(0xFF00D9FF)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(category.name, style: const TextStyle(fontSize: 17)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            category.info!,
            style: const TextStyle(fontSize: 15, height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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
        // Bottom padding navíc kvůli systémové navigační liště telefonu.
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
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
                    if (category.info != null)
                      IconButton(
                        icon: const Icon(Icons.info_outline,
                            color: Color(0xFF00D9FF), size: 22),
                        tooltip: 'Vysvětlení gramatiky',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _showCategoryInfo(category),
                      ),
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
  final bool initialIsEnToCz;
  /// Mazání karty z přehledu (null = balíček mazání nepodporuje).
  /// Vrací true při úspěchu — pak se karta odebere ze seznamu.
  final Future<bool> Function(FlashCard)? onDeleteCard;

  const LearningScreen({
    super.key,
    required this.title,
    required this.cards,
    required this.progress,
    required this.onSaveProgress,
    required this.langConfig,
    this.initialIsEnToCz = false,
    this.onDeleteCard,
  });

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  FlashCard? currentCard;
  bool showTranslation = false;
  late bool isEnToCz = widget.initialIsEnToCz;
  int todayReviewed = 0;

  final FocusNode _keyboardFocus = FocusNode();
  final Set<String> _sessionReviewed = {};
  bool _boostMode = false;
  bool _boostFirstRoundDone = false;

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
  void dispose() {
    _keyboardFocus.dispose();
    flutterTts.stop();
    super.dispose();
  }

  void _commitRating(int rating) {
    _rate(rating);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.enter) {
      _speakAndReveal();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _commitRating(4); // Snadné
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _commitRating(1); // Znovu
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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

  FlashCard _weightedPick(List<FlashCard> cards) {
    // Higher weight for cards user struggles with (low repetitions, low ease).
    final weights = cards.map((c) {
      final p = _getCardProgress(c);
      // Base weight 1; +5 for new cards (rep 0); decreases as repetitions grow;
      // also boosted when ease is low (struggle).
      final repBonus = (10 - p.repetitions).clamp(1, 10).toDouble();
      final easeBonus = (3.0 - p.ease).clamp(0.0, 2.0);
      return repBonus + easeBonus * 2;
    }).toList();
    final total = weights.fold<double>(0, (s, w) => s + w);
    final random = Random();
    var pick = random.nextDouble() * total;
    for (var i = 0; i < cards.length; i++) {
      pick -= weights[i];
      if (pick <= 0) return cards[i];
    }
    return cards.last;
  }

  void _showNextCard() {
    if (widget.cards.isEmpty) {
      setState(() {
        currentCard = null;
        showTranslation = false;
      });
      return;
    }

    final today = DateTime.now().toIso8601String().split('T')[0];
    List<FlashCard> available;

    if (_boostMode) {
      bool notLearned(FlashCard c) => _getCardProgress(c).interval <= 21;

      if (!_boostFirstRoundDone) {
        // První kolo: VŠECHNY karty (i Naučené pro připomenutí)
        available = widget.cards
            .where((c) => !_sessionReviewed.contains(_getCardKey(c)))
            .toList();

        if (available.isEmpty) {
          // První kolo hotové - dál jen ty co stále neumím
          _boostFirstRoundDone = true;
          _sessionReviewed.clear();
          final remaining = widget.cards.where(notLearned).toList();
          if (remaining.isEmpty) {
            setState(() {
              currentCard = null;
              showTranslation = false;
            });
            return;
          }
          available = remaining;
        }
      } else {
        // Další kola: jen ne-Naučené karty
        available = widget.cards.where((c) {
          if (_sessionReviewed.contains(_getCardKey(c))) return false;
          return notLearned(c);
        }).toList();

        if (available.isEmpty) {
          final remaining = widget.cards.where(notLearned).toList();
          if (remaining.isEmpty) {
            setState(() {
              currentCard = null;
              showTranslation = false;
            });
            return;
          }
          _sessionReviewed.clear();
          available = remaining;
        }
      }
    } else {
      // Normální režim = SM-2: pouze splatné karty které nebyly v relaci viděné.
      available = widget.cards.where((c) {
        if (_sessionReviewed.contains(_getCardKey(c))) return false;
        final prog = _getCardProgress(c);
        return prog.nextReview.compareTo(today) <= 0;
      }).toList();
    }

    if (available.isEmpty) {
      setState(() {
        currentCard = null;
        showTranslation = false;
      });
      return;
    }

    // Vybrat váženě, ale vyhnout se okamžitému zopakování stejné karty
    FlashCard pick = _weightedPick(available);
    if (available.length > 1 && currentCard != null && pick.en == currentCard!.en) {
      for (int i = 0; i < 5; i++) {
        final retry = _weightedPick(available);
        if (retry.en != currentCard!.en) {
          pick = retry;
          break;
        }
      }
    }

    setState(() {
      currentCard = pick;
      showTranslation = false;
    });
  }

  void _startBoost() {
    setState(() {
      _boostMode = true;
      _boostFirstRoundDone = false;
      _sessionReviewed.clear();
    });
    _showNextCard();
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

  Future<bool> _hasNativeVoice(String locale) async {
    try {
      final voices = await flutterTts.getVoices;
      final shortCode = locale.split('-').first.toLowerCase();
      return (voices as List).any((v) =>
        v['locale'].toString().toLowerCase().startsWith(shortCode));
    } catch (_) {
      return true; // can't check → assume yes
    }
  }

  Future<void> _checkTtsVoiceAndWarn(String locale) async {
    final has = await _hasNativeVoice(locale);
    if (!has && mounted) {
      final isGerman = locale.toLowerCase().startsWith('de');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            isGerman
                ? 'Tvoje zařízení nemá německý hlas - výslovnost nebude správná. '
                  'Nainstaluj německý jazykový balíček (Android: Nastavení → '
                  'Jazyk → TTS → Google → stáhnout němčinu).'
                : 'Tvoje zařízení nemá hlas pro tento jazyk - výslovnost nebude správná.',
          ),
          backgroundColor: Colors.orange[700],
        ),
      );
    }
  }

  void _showTtsError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(message),
        backgroundColor: Colors.orange[700],
      ),
    );
  }

  Future<bool> _playCloudTts(String text, String lang) async {
    if (!kIsWeb) return false;
    // Cloud TTS only supports de-DE and en-US
    String cloudLang;
    if (lang.toLowerCase().startsWith('de')) {
      cloudLang = 'de-DE';
    } else if (lang.toLowerCase().startsWith('en')) {
      cloudLang = 'en-US';
    } else {
      return false; // Czech and others fall back silently
    }
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AuthService.kTokenKey);
    if (token == null || token.isEmpty) return false;

    final uri = Uri.base.resolve('api/tts.php').replace(queryParameters: {
      'text': text,
      'lang': cloudLang,
      'token': token,
    });

    final stopwatch = Stopwatch()..start();
    http.Response res;
    try {
      res = await http.get(uri).timeout(const Duration(seconds: 10));
    } catch (e) {
      stopwatch.stop();
      debugPrint('[TTS] FAIL  word="$text"  lang="$cloudLang"  network error: $e  duration=${stopwatch.elapsedMilliseconds}ms');
      debugPrint('[TTS] Falling back to flutter_tts ($cloudLang)');
      _showTtsError('Nelze se spojit se serverem (lokální fallback)');
      return false;
    }
    stopwatch.stop();

    final contentType = res.headers['content-type'] ?? '';
    if (res.statusCode == 200 && contentType.startsWith('audio/')) {
      try {
        await flutterTts.stop();
        await web_audio.playMp3Bytes(res.bodyBytes);
        return true;
      } catch (e) {
        debugPrint('[TTS] FAIL playback: $e');
        _showTtsError('Chyba při přehrávání zvuku (lokální fallback)');
        return false;
      }
    }

    // Error path - parse JSON and show specific message
    String? errorCode;
    try {
      final data = json.decode(res.body) as Map<String, dynamic>;
      errorCode = data['error'] as String?;
    } catch (_) {}

    debugPrint('[TTS] FAIL  word="$text"  lang="$cloudLang"  url="${uri.path}"');
    debugPrint('[TTS] HTTP ${res.statusCode}  body=${res.body}  duration=${stopwatch.elapsedMilliseconds}ms');
    debugPrint('[TTS] Falling back to flutter_tts ($cloudLang)');

    switch (res.statusCode) {
      case 401:
        _showTtsError('Přihlášení vypršelo, přihlas se znovu');
        // Clear token and redirect to login
        await prefs.remove(AuthService.kTokenKey);
        await prefs.remove(AuthService.kEmailKey);
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const AuthGate()),
            (_) => false,
          );
        }
        return true; // don't fallback - user is being redirected
      case 400:
        if (errorCode == 'invalid_lang') {
          _showTtsError('Tento jazyk neumíme přečíst (lokální fallback)');
        } else if (errorCode == 'invalid_text') {
          _showTtsError('Slovo obsahuje nepodporované znaky');
        } else {
          _showTtsError('Cloud TTS chyba: HTTP 400');
        }
        return false;
      case 429:
        _showTtsError('Příliš mnoho přehrání, počkej minutu');
        return false;
      case 500:
        _showTtsError('Cloud hlas momentálně nedostupný (lokální fallback)');
        return false;
      default:
        _showTtsError('Cloud TTS chyba: HTTP ${res.statusCode}');
        return false;
    }
  }

  Future<void> _speak() async {
    if (currentCard == null) return;
    final text = isEnToCz ? currentCard!.cz : currentCard!.en;
    final locale = isEnToCz
        ? widget.langConfig.nativeTtsLocale
        : widget.langConfig.ttsLocale;

    // Try cloud TTS first on web
    if (kIsWeb) {
      final ok = await _playCloudTts(text, locale);
      if (ok) return;
    }

    // Fallback to local flutter_tts
    if (!isEnToCz) {
      await _checkTtsVoiceAndWarn(locale);
    }
    await _setVoiceForLocale(locale);
    await flutterTts.speak(text);
  }

  void _rate(int rating) {
    if (currentCard == null) return;

    final prog = _getCardProgress(currentCard!);
    final today = DateTime.now().toIso8601String().split('T')[0];
    final key = _getCardKey(currentCard!);

    if (rating < 3) {
      // Těžké → červená (Těžká), ne šedá. Repetitions držíme na 1+ aby
      // barva byla červená (interval==1, repetitions>0).
      prog.repetitions = 1;
      prog.interval = 1;
      prog.ease = max(1.3, prog.ease - 0.2);
    } else if (rating == 4 && _boostMode) {
      // Boost: Snadné skočí rovnou do "Naučená"
      prog.repetitions = 10;
      prog.interval = 90;
      prog.ease = 2.8;
    } else {
      // Standardní SM-2 progression (Snadné v normálním režimu)
      if (prog.repetitions == 0) {
        prog.interval = 1;
      } else if (prog.repetitions == 1) {
        prog.interval = 6;
      } else {
        prog.interval = (prog.interval * prog.ease).round();
      }
      prog.repetitions++;
      prog.ease = max(1.3, prog.ease + (0.1 - (5 - rating) * (0.08 + (5 - rating) * 0.02)));
    }

    final nextDate = DateTime.now().add(Duration(days: prog.interval));
    prog.nextReview = nextDate.toIso8601String().split('T')[0];
    prog.lastReview = today;

    // Označit kartičku jako "viděnou v této relaci" - znovu se neukáže
    _sessionReviewed.add(key);
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
          onDelete: widget.onDeleteCard,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().toIso8601String().split('T')[0];
    // "Naučeno" = modré karty (interval > 21d) — souhlasí s barevným kódováním a Boost módem.
    final learned = widget.cards.where((c) => _getCardProgress(c).interval > 21).length;
    final progressPercent = widget.cards.isNotEmpty ? learned / widget.cards.length : 0.0;

    // "Dnes X" = karty hodnocené dnes (přežije zavření přes lastReview).
    final reviewedToday = widget.cards
        .where((c) => _getCardProgress(c).lastReview == today)
        .length;
    // Jmenovatel = kolik bylo splatných na začátku dne = hodnocené dnes + stále splatné neotevřené.
    final stillDueNotTouched = widget.cards.where((c) {
      final p = _getCardProgress(c);
      return p.lastReview != today && p.nextReview.compareTo(today) <= 0;
    }).length;
    final todayDenominator = reviewedToday + stillDueNotTouched;

    // V boost módu po 1. kole počítáme jen ne-Naučené karty (jmenovatel)
    final notLearnedCount = widget.cards.where((c) => _getCardProgress(c).interval <= 21).length;
    final sessionDenominator = (_boostMode && _boostFirstRoundDone)
        ? notLearnedCount
        : widget.cards.length;

    return Focus(
      autofocus: true,
      focusNode: _keyboardFocus,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          const BackupStatusIcon(),
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
                _boostMode
                    ? '🔥 BOOST · Kolo ${_sessionReviewed.length}/$sessionDenominator · Naučeno $learned/${widget.cards.length}'
                    : 'Dnes $reviewedToday/$todayDenominator · Naučeno $learned/${widget.cards.length}',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
                textAlign: TextAlign.center,
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: _buildRatingButton(
                        'Těžké',
                        const Color(0xFFE74C3C),
                        () => _rate(1),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _buildIconButton(Icons.volume_up, _speakAndReveal),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildRatingButton(
                        'Snadné',
                        const Color(0xFF3498DB),
                        () => _rate(4),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
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
      final allLearned = widget.cards.isNotEmpty &&
          widget.cards.every((c) => _getCardProgress(c).interval > 21);
      final allReviewed = _sessionReviewed.length >= widget.cards.length && widget.cards.isNotEmpty;
      // Boost je k dispozici vždy v normálním režimu (i když jsou všechny Naučené,
      // můžeš si jimi projet pro připomenutí).
      final canBoost = !_boostMode && widget.cards.isNotEmpty;
      final nextInfo = allLearned && !_boostMode
          ? '💙 Vše modré - klikni Boost pro připomenutí'
          : (allReviewed && !_boostMode)
              ? '👋 Vrať se příště na další procvičování'
              : _getNextReviewInfo();
      final message = allLearned
          ? '🎉 Všechny kartičky Naučené!'
          : _boostMode
              ? '🔥 Boost dokončen!'
              : (todayReviewed > 0 ? '🎉 Hotovo na dnes!' : '📚 Žádné kartičky na dnes');

      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF16213E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  message,
                  style: const TextStyle(fontSize: 24),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  nextInfo,
                  style: TextStyle(fontSize: 16, color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),
                if (canBoost) ...[
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.local_fire_department),
                    label: const Text('Boost před lekcí'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD700),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _startBoost,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Projde i kartičky které ještě nejsou splatné',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
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
      child: Stack(
        children: [
          Column(
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
          if (currentCard!.note != null)
            Positioned(
              top: -18,
              right: -18,
              child: IconButton(
                icon: const Icon(Icons.info_outline, color: Color(0xFF00D9FF)),
                tooltip: 'Nápověda',
                onPressed: _showNote,
              ),
            ),
        ],
      ),
    );
  }

  void _showNote() {
    final note = currentCard?.note;
    if (note == null) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Color(0xFF00D9FF)),
            SizedBox(width: 8),
            Text('Nápověda', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: Text(note, style: const TextStyle(fontSize: 16, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
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

  Widget _buildRatingButton(String text, Color color, VoidCallback? onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        disabledBackgroundColor: color.withValues(alpha: 0.3),
        disabledForegroundColor: Colors.white70,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      child: Text(text, style: const TextStyle(fontSize: 16)),
    );
  }

  Future<void> _speakAndReveal() async {
    if (!showTranslation) {
      _reveal();
    }
    await _speak();
  }
}

// ===== Add Card Screen (celoobrazovkové přidání kartičky) =====

class AddCardScreen extends StatefulWidget {
  final LanguageConfig langConfig;
  final bool isAdmin;
  final bool presetDavid;
  /// Existující karty (David + moje) pro živé našeptávání duplicit.
  final List<FlashCard> existingCards;

  const AddCardScreen({
    super.key,
    required this.langConfig,
    required this.isAdmin,
    required this.presetDavid,
    required this.existingCards,
  });

  @override
  State<AddCardScreen> createState() => _AddCardScreenState();
}

class _AddCardScreenState extends State<AddCardScreen> {
  final enController = TextEditingController();
  final czController = TextEditingController();
  final noteController = TextEditingController();
  final speech = stt.SpeechToText();
  bool isListeningEn = false;
  bool isListeningCz = false;
  bool isTranslating = false;
  late bool addToDavid = widget.presetDavid && widget.isAdmin;
  Timer? _typeDebounce;
  // Poslední automaticky doplněné překlady — jen ty smíme přepsat novým překladem.
  String? _autoFilledEn;
  String? _autoFilledCz;

  @override
  void dispose() {
    _typeDebounce?.cancel();
    speech.stop();
    enController.dispose();
    czController.dispose();
    noteController.dispose();
    super.dispose();
  }

  Future<String?> _translateText(String text, String from, String to) async {
    try {
      final uri = Uri.parse(
        'https://api.mymemory.translated.net/get?q=${Uri.encodeComponent(text)}&langpair=$from|$to',
      );
      final response = await http.get(uri);
      final data = json.decode(response.body);
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
        result = result.replaceAll(RegExp(r'''["“”„‘’']$'''), '');
        result = result.replaceAll(RegExp(r'''^["“”„‘’']'''), '');
        result = result.trim();
        return result;
      }
    } catch (_) {}
    return null;
  }

  /// Automatický překlad při psaní na klávesnici (s prodlevou po dopsání).
  /// Druhé pole vyplní jen pokud je prázdné, nebo obsahuje předchozí
  /// automatický překlad — ručně napsaný text nikdy nepřepisuje.
  void _onTyped(bool fromEn) {
    _typeDebounce?.cancel();
    _typeDebounce = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      final source = (fromEn ? enController : czController).text.trim();
      final target = fromEn ? czController : enController;
      final canFill = target.text.trim().isEmpty ||
          target.text == (fromEn ? _autoFilledCz : _autoFilledEn);
      if (source.length < 2 || !canFill) return;
      setState(() => isTranslating = true);
      final from = fromEn ? widget.langConfig.code : 'cs';
      final to = fromEn ? 'cs' : widget.langConfig.code;
      _translateText(source, from, to).then((translated) {
        if (!mounted) return;
        setState(() {
          isTranslating = false;
          // Text se mezitím změnil — výsledek už neplatí.
          if ((fromEn ? enController : czController).text.trim() != source) {
            return;
          }
          if (translated != null && translated.isNotEmpty) {
            target.text = translated;
            target.selection = TextSelection.fromPosition(
              TextPosition(offset: target.text.length),
            );
            if (fromEn) {
              _autoFilledCz = translated;
            } else {
              _autoFilledEn = translated;
            }
          }
        });
      });
    });
  }

  Future<void> _toggleListening(
      TextEditingController controller, String localeId, bool isEn) async {
    if (isEn ? isListeningEn : isListeningCz) {
      await speech.stop();
      setState(() {
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
        setState(() {
          isListeningEn = false;
          isListeningCz = false;
        });
      },
    );

    if (available) {
      setState(() {
        if (isEn) {
          isListeningEn = true;
        } else {
          isListeningCz = true;
        }
      });
      await speech.listen(
        onResult: (result) {
          setState(() {
            controller.text = result.recognizedWords;
            controller.selection = TextSelection.fromPosition(
              TextPosition(offset: controller.text.length),
            );
            if (result.finalResult) {
              if (isEn) {
                isListeningEn = false;
                // Auto-translate EN/DE -> CZ
                if (result.recognizedWords.isNotEmpty && czController.text.isEmpty) {
                  isTranslating = true;
                  _translateText(result.recognizedWords, widget.langConfig.code, 'cs')
                      .then((translated) {
                    if (!mounted) return;
                    setState(() {
                      if (translated != null) {
                        czController.text = translated;
                        czController.selection = TextSelection.fromPosition(
                          TextPosition(offset: czController.text.length),
                        );
                        _autoFilledCz = translated;
                      }
                      isTranslating = false;
                    });
                  });
                }
              } else {
                isListeningCz = false;
                // Auto-translate CZ -> EN/DE
                if (result.recognizedWords.isNotEmpty && enController.text.isEmpty) {
                  isTranslating = true;
                  _translateText(result.recognizedWords, 'cs', widget.langConfig.code)
                      .then((translated) {
                    if (!mounted) return;
                    setState(() {
                      if (translated != null) {
                        enController.text = translated;
                        enController.selection = TextSelection.fromPosition(
                          TextPosition(offset: enController.text.length),
                        );
                        _autoFilledEn = translated;
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

  /// Podobné existující karty (živá kontrola duplicit, EN i CZ, bez diakritiky).
  List<FlashCard> get _similar {
    final q = searchFold(enController.text.trim());
    final qc = searchFold(czController.text.trim());
    final out = <FlashCard>[];
    if (q.length >= 2 || qc.length >= 2) {
      for (final c in widget.existingCards) {
        if ((q.length >= 2 && searchFold(c.en).contains(q)) ||
            (qc.length >= 2 && searchFold(c.cz).contains(qc))) {
          out.add(c);
          if (out.length >= 8) break;
        }
      }
    }
    return out;
  }

  void _submit() {
    final en = enController.text.trim();
    final cz = czController.text.trim();
    if (en.isEmpty || cz.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vyplň obě pole.')),
      );
      return;
    }
    speech.stop();
    Navigator.pop(context, {
      'en': en,
      'cz': cz,
      'note': noteController.text.trim(),
      'toDavid': addToDavid,
    });
  }

  @override
  Widget build(BuildContext context) {
    final similar = _similar;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Přidat kartičku'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton(
            onPressed: _submit,
            child: const Text('Přidat',
                style: TextStyle(
                    color: Color(0xFF00FF88),
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: enController,
                decoration: InputDecoration(
                  labelText: widget.langConfig.addCardLabel,
                  hintText: widget.langConfig.addCardHint,
                  border: const OutlineInputBorder(),
                  suffixIcon: isTranslating
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: Icon(
                            isListeningEn ? Icons.mic : Icons.mic_none,
                            color: isListeningEn ? Colors.red : Colors.grey,
                          ),
                          onPressed: () => _toggleListening(
                              enController, widget.langConfig.ttsLocale, true),
                        ),
                ),
                maxLines: 3,
                minLines: 1,
                onChanged: (_) {
                  setState(() {});
                  _onTyped(true);
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: czController,
                decoration: InputDecoration(
                  labelText: 'Česky',
                  hintText: 'Ahoj, jak se máš?',
                  border: const OutlineInputBorder(),
                  suffixIcon: isTranslating
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: Icon(
                            isListeningCz ? Icons.mic : Icons.mic_none,
                            color: isListeningCz ? Colors.red : Colors.grey,
                          ),
                          onPressed: () =>
                              _toggleListening(czController, 'cs-CZ', false),
                        ),
                ),
                maxLines: 3,
                minLines: 1,
                onChanged: (_) {
                  setState(() {});
                  _onTyped(false);
                },
              ),
              if (widget.isAdmin) ...[
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Přidat do „David Petrov kartičky“',
                      style: TextStyle(fontSize: 14)),
                  subtitle: const Text('Globálně — uvidí všichni uživatelé',
                      style: TextStyle(fontSize: 11, color: Color(0xFFFFD700))),
                  activeThumbColor: const Color(0xFFFFD700),
                  value: addToDavid,
                  onChanged: (v) => setState(() => addToDavid = v),
                ),
                if (addToDavid) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteController,
                    decoration: const InputDecoration(
                      labelText: 'Nápověda ⓘ (volitelná)',
                      hintText: 'Gramatická vysvětlivka ke kartě',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                ],
              ],
              const SizedBox(height: 20),
              if (similar.isNotEmpty) ...[
                Text(
                  '⚠ Podobné už existuje (${similar.length}):',
                  style: const TextStyle(color: Color(0xFFF39C12), fontSize: 13),
                ),
                const SizedBox(height: 8),
                ...similar.map((c) => Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16213E),
                        borderRadius: BorderRadius.circular(6),
                        border: const Border(
                          left: BorderSide(color: Color(0xFFF39C12), width: 3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.en,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500)),
                          Text(c.cz,
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFF00D9FF))),
                        ],
                      ),
                    )),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Cards Overview Screen
class CardsOverviewScreen extends StatefulWidget {
  final List<FlashCard> cards;
  final Color Function(FlashCard) getCardColor;
  final CardProgress Function(FlashCard) getCardProgress;
  final FlutterTts flutterTts;
  final LanguageConfig langConfig;
  /// Mazání karty (null = tento balíček mazání nepodporuje).
  final Future<bool> Function(FlashCard)? onDelete;

  const CardsOverviewScreen({
    super.key,
    required this.cards,
    required this.getCardColor,
    required this.getCardProgress,
    required this.flutterTts,
    required this.langConfig,
    this.onDelete,
  });

  @override
  State<CardsOverviewScreen> createState() => _CardsOverviewScreenState();
}

class _CardsOverviewScreenState extends State<CardsOverviewScreen> {
  final _searchController = TextEditingController();
  bool _searchActive = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Karty po aplikaci vyhledávacího filtru (EN i CZ, bez diakritiky).
  List<FlashCard> get _filteredCards {
    final q = searchFold(_searchController.text.trim());
    if (!_searchActive || q.isEmpty) return widget.cards;
    return widget.cards
        .where((c) =>
            searchFold(c.en).contains(q) || searchFold(c.cz).contains(q))
        .toList();
  }

  List<FlashCard> get cards => widget.cards;
  Color Function(FlashCard) get getCardColor => widget.getCardColor;
  CardProgress Function(FlashCard) get getCardProgress => widget.getCardProgress;
  FlutterTts get flutterTts => widget.flutterTts;
  LanguageConfig get langConfig => widget.langConfig;

  Future<void> _confirmAndDelete(NavigatorState detailNav, FlashCard card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Smazat kartičku?'),
        content: Text(
          '„${card.en}“\n\nSmazání je nevratné.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Zrušit'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Smazat'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ok = await widget.onDelete!(card);
    if (!mounted) return;
    if (ok) {
      // Vlastník seznamu (HomeScreen) kartu odebral — stačí překreslit.
      setState(() {});
      detailNav.pop(); // zavřít detail karty
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kartička smazána')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Smazání se nepodařilo (server/připojení)')),
      );
    }
  }

  void _showCardDetail(BuildContext context, FlashCard card) {
    final prog = getCardProgress(card);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: Text(card.en, style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(card.cz, style: const TextStyle(color: Color(0xFF00D9FF))),
            if (card.note != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Color(0xFF00D9FF)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(card.note!,
                        style: TextStyle(color: Colors.grey[300], fontSize: 13, height: 1.3)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text('Opakování: ${prog.repetitions}x', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
            Text('Interval: ${prog.interval} dní', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
            Text('Další: ${prog.nextReview}', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
          ],
        ),
        actions: [
          if (widget.onDelete != null)
            TextButton(
              onPressed: () => _confirmAndDelete(Navigator.of(dialogContext), card),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Smazat'),
            ),
          TextButton(
            onPressed: () async {
              await flutterTts.setLanguage(langConfig.ttsLocale);
              await flutterTts.speak(card.en);
            },
            child: const Text('🔊 Přehrát'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
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
        title: _searchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Hledat slovo (EN i CZ)…',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 16),
                onChanged: (_) => setState(() {}),
              )
            : const Text('Přehled kartiček'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_searchActive ? Icons.close : Icons.search,
                color: const Color(0xFF00D9FF)),
            tooltip: _searchActive ? 'Zrušit hledání' : 'Hledat',
            onPressed: () => setState(() {
              _searchActive = !_searchActive;
              if (!_searchActive) _searchController.clear();
            }),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                _buildLegendItem(Colors.grey[700]!, 'Nová'),
                _buildLegendItem(const Color(0xFFE74C3C), 'Těžká'),
                _buildLegendItem(const Color(0xFFF39C12), 'Učí se'),
                _buildLegendItem(const Color(0xFF27AE60), 'Dobrá'),
                _buildLegendItem(const Color(0xFF3498DB), 'Naučená'),
              ],
            ),
          ),
          if (_searchActive)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Nalezeno: ${_filteredCards.length} z ${cards.length}',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            ),
          Expanded(
            child: ListView.builder(
              // Bottom padding navíc, ať poslední karta není schovaná za
              // systémovou navigační lištou telefonu.
              padding: EdgeInsets.fromLTRB(
                  8, 4, 8, 4 + MediaQuery.of(context).padding.bottom),
              itemCount: _filteredCards.length,
              itemBuilder: (context, index) {
                final card = _filteredCards[index];
                final color = getCardColor(card);
                return GestureDetector(
                  onTap: () => _showCardDetail(context, card),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                      border: Border(
                        left: BorderSide(color: color, width: 4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: Text(
                            card.en,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 5,
                          child: Text(
                            card.cz,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF00D9FF),
                            ),
                          ),
                        ),
                      ],
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
  Map<int, List<FlashCard>> lessonCards = {};
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      final manifestStr = await rootBundle.loadString('assets/nemecky_s_usmevem/manifest.json');
      final manifest = json.decode(manifestStr) as Map<String, dynamic>;
      final list = manifest['lessons'] as List;
      final loaded = list.map((l) => NemeckySUsmevemLesson(
        number: l['number'] as int,
        title: l['title'] as String,
        file: l['file'] as String,
      )).toList();

      final Map<int, List<FlashCard>> cards = {};
      for (final lesson in loaded) {
        try {
          final str = await rootBundle.loadString('assets/nemecky_s_usmevem/${lesson.file}');
          final data = json.decode(str) as Map<String, dynamic>;
          final List<FlashCard> all = [];
          final cardsList = data['cards'] as List? ?? [];
          for (final c in cardsList) {
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
          cards[lesson.number] = all;
        } catch (_) {
          cards[lesson.number] = [];
        }
      }

      setState(() {
        lessons = loaded;
        lessonCards = cards;
        isLoading = false;
      });
    } catch (_) {
      setState(() => isLoading = false);
    }
  }

  String _cardKey(FlashCard card) => card.en.substring(0, min(50, card.en.length));

  double _lessonProgress(int lessonNumber) {
    final cards = lessonCards[lessonNumber] ?? [];
    if (cards.isEmpty) return 0.0;
    int learned = 0;
    for (final c in cards) {
      final p = widget.progress[_cardKey(c)];
      if (p != null && p.interval > 21) learned++;
    }
    return learned / cards.length;
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
                      '⚠️ Obsah z učebnice používáme pouze pro osobní studium v rámci '
                      'soukromé skupiny. Není povoleno volné šíření.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    // Bottom padding kvůli systémové navigační liště telefonu.
                    padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).padding.bottom),
                    itemCount: lessons.length,
                    itemBuilder: (context, index) {
                      final lesson = lessons[index];
                      final cards = lessonCards[lesson.number] ?? [];
                      final cardsCount = cards.length;
                      final progressValue = _lessonProgress(lesson.number);
                      final accentColor = progressValue >= 0.9
                          ? const Color(0xFF00FF88)
                          : progressValue >= 0.5
                              ? Colors.orange
                              : const Color(0xFF00D9FF);
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: accentColor.withValues(alpha: 0.4)),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () async {
                            if (cards.isEmpty) return;
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => LearningScreen(
                                  title: 'Lekce ${lesson.number}',
                                  cards: cards,
                                  progress: widget.progress,
                                  onSaveProgress: widget.onSaveProgress,
                                  langConfig: widget.langConfig,
                                ),
                              ),
                            );
                            if (mounted) setState(() {});
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Lekce ${lesson.number}: ${lesson.title}',
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${(progressValue * 100).toInt()}%',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: progressValue >= 0.9
                                            ? const Color(0xFF00FF88)
                                            : progressValue >= 0.5
                                                ? Colors.orange
                                                : Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '$cardsCount kartiček',
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: progressValue,
                                    backgroundColor: Colors.grey[800],
                                    valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                                    minHeight: 6,
                                  ),
                                ),
                              ],
                            ),
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

// ===== Backend Auth Service =====

class ApiResult {
  final int statusCode;
  final Map<String, dynamic>? body;
  ApiResult(this.statusCode, this.body);
}

class AuthService {
  static const String kTokenKey = 'auth_token';
  static const String kEmailKey = 'auth_email';
  static const String kBackendBase = 'https://petrovelektronika.cz/LangCards/';

  static Uri _api(String endpoint) {
    if (kIsWeb) {
      // Same-origin: relativní URL
      return Uri.base.resolve('api/$endpoint');
    }
    // Mobile: plné URL
    return Uri.parse('${kBackendBase}api/$endpoint');
  }

  /// Adresa stranky s obnovou hesla. Stejny zaklad jako API, aby to sedelo
  /// i na webove verzi a pri vyvoji.
  static Uri resetUrl() => _api('reset.php');

  static Future<ApiResult> _request(String method, String endpoint, {Map<String, dynamic>? body, String? token}) async {
    final uri = _api(endpoint);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final http.Response res;
    if (method == 'POST') {
      res = await http.post(uri, headers: headers, body: body != null ? json.encode(body) : null);
    } else if (method == 'DELETE') {
      res = await http.delete(uri, headers: headers, body: body != null ? json.encode(body) : null);
    } else {
      res = await http.get(uri, headers: headers);
    }
    Map<String, dynamic>? data;
    try {
      data = json.decode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    return ApiResult(res.statusCode, data);
  }

  static Future<ApiResult> register(String email, String password) =>
      _request('POST', 'register.php', body: {'email': email, 'password': password});

  static Future<ApiResult> login(String email, String password) =>
      _request('POST', 'login.php', body: {'email': email, 'password': password});

  static Future<ApiResult> uploadBackup(String token, Map<String, dynamic> data) =>
      _request('POST', 'backup.php', body: data, token: token);

  static Future<ApiResult> downloadBackup(String token) =>
      _request('GET', 'backup.php', token: token);

  static Future<ApiResult> getAdminUsers(String token) =>
      _request('GET', 'admin_users.php', token: token);

  /// Globální „David Petrov" karty ze serveru. Nikdy nevyhazuje — při
  /// chybě sítě vrací ApiResult(0, null), volající spadne na cache/asset.
  static Future<ApiResult> getDavidCards(String lang) async {
    try {
      final uri = _api('david_cards.php').replace(queryParameters: {'lang': lang});
      final res = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 6));
      Map<String, dynamic>? data;
      try {
        data = json.decode(res.body) as Map<String, dynamic>;
      } catch (_) {}
      return ApiResult(res.statusCode, data);
    } catch (_) {
      return ApiResult(0, null);
    }
  }

  /// Admin: přidání globální karty (server ověřuje ADMIN_EMAILS).
  static Future<ApiResult> addDavidCard(String token, Map<String, dynamic> card) =>
      _request('POST', 'david_cards.php', body: card, token: token);

  /// Admin: smazání globální karty podle EN textu (server ověřuje ADMIN_EMAILS).
  static Future<ApiResult> deleteDavidCard(String token, Map<String, dynamic> card) =>
      _request('DELETE', 'david_cards.php', body: card, token: token);
}

// ===== Login Screen =====

class LoginScreen extends StatefulWidget {
  final SharedPreferences prefs;
  final VoidCallback onLoggedIn;

  const LoginScreen({super.key, required this.prefs, required this.onLoggedIn});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  String? error;
  bool isLoading = false;
  bool obscurePassword = true;
  bool registered = false;
  String registeredEmail = '';

  @override
  void initState() {
    super.initState();
    // Předvyplnit email z minulého přihlášení (uložené při loginu)
    final lastEmail = widget.prefs.getString('last_logged_in_email') ?? '';
    if (lastEmail.isNotEmpty) {
      emailController.text = lastEmail;
    }
  }

  /// Obnova hesla bezi na serveru jako stranka, ne v aplikaci.
  ///
  /// Diky tomu funguje i pro telefon se starsi verzi appky a hlavne to
  /// znamena, ze se kvuli zapomenutemu heslu neceka na vydani na Play.
  /// Do 30. 8. 2026 nesla obnova hesla vubec a kdo ho zapomnel, prisel
  /// o ucet natrvalo.
  Future<void> _otevritObnovuHesla() async {
    final uri = AuthService.resetUrl();
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      setState(() => error = 'Nepodařilo se otevřít prohlížeč. Adresa: $uri');
    }
  }

  Future<void> _login() async {
    final email = emailController.text.trim().toLowerCase();
    final password = passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => error = 'Vyplňte email i heslo');
      return;
    }
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      final res = await AuthService.login(email, password);
      if (!mounted) return;
      if (res.statusCode == 200 && res.body != null) {
        final token = res.body!['token'] as String;
        final returnedEmail = (res.body!['email'] as String?) ?? email;
        await widget.prefs.setString(AuthService.kTokenKey, token);
        await widget.prefs.setString(AuthService.kEmailKey, returnedEmail);
        // Signalizuj prohlížeči/OS password manageru, že přihlášení uspělo,
        // aby nabídl uložit heslo.
        TextInput.finishAutofillContext();
        widget.onLoggedIn();
      } else if (res.statusCode == 401) {
        setState(() => error = 'Nesprávný e-mail nebo heslo.');
      } else if (res.statusCode == 403) {
        setState(() => error = 'E-mail ještě nebyl ověřen. Zkontroluj inbox (i spam).');
      } else {
        setState(() => error = 'Chyba při přihlášení (${res.statusCode}).');
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Chyba spojení: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _register() async {
    final email = emailController.text.trim().toLowerCase();
    final password = passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => error = 'Vyplňte email i heslo');
      return;
    }
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      final res = await AuthService.register(email, password);
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          registered = true;
          registeredEmail = email;
        });
      } else if (res.statusCode == 409) {
        setState(() => error = 'Tento e-mail je už registrovaný — přihlas se.');
      } else if (res.statusCode == 400) {
        final err = res.body?['error'] ?? '';
        setState(() => error = err == 'invalid_email'
            ? 'Neplatný e-mail.'
            : 'Heslo musí mít minimálně 8 znaků.');
      } else {
        setState(() => error = 'Chyba při registraci (${res.statusCode}).');
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Chyba spojení: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (registered) {
      return Scaffold(
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 48),
                    const Icon(Icons.email_outlined, size: 80, color: Color(0xFF00FF88)),
                    const SizedBox(height: 24),
                    Text(
                      'Poslali jsme ověřovací e-mail na $registeredEmail.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Klikni na odkaz a poté se přihlas. Mail může být ve spamu.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: () => setState(() {
                        registered = false;
                        error = null;
                      }),
                      child: const Text('Zpět na přihlášení'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 48),
                  const Text('LangCards',
                      style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Aplikace pro učení cizích jazyků',
                      style: TextStyle(fontSize: 14, color: Colors.grey)),
                  const SizedBox(height: 40),
                  AutofillGroup(
                    child: Column(
                      children: [
                        TextField(
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.username, AutofillHints.email],
                          decoration: const InputDecoration(labelText: 'Email'),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: passwordController,
                          obscureText: obscurePassword,
                          autofillHints: const [AutofillHints.password],
                          decoration: InputDecoration(
                            labelText: 'Heslo',
                            suffixIcon: IconButton(
                              icon: Icon(obscurePassword ? Icons.visibility : Icons.visibility_off),
                              tooltip: obscurePassword ? 'Zobrazit heslo' : 'Skrýt heslo',
                              onPressed: () => setState(() => obscurePassword = !obscurePassword),
                            ),
                          ),
                          onSubmitted: (_) => _login(),
                        ),
                      ],
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 16),
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: isLoading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            backgroundColor: const Color(0xFF00FF88),
                            foregroundColor: Colors.black,
                          ),
                          child: const Text('Přihlásit'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: isLoading ? null : _register,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Registrovat'),
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: isLoading ? null : _otevritObnovuHesla,
                    child: const Text(
                      'Zapomenuté heslo?',
                      style: TextStyle(color: Color(0xFF00D9FF)),
                    ),
                  ),
                  if (isLoading) ...[
                    const SizedBox(height: 24),
                    const CircularProgressIndicator(),
                  ],
                  const SizedBox(height: 24),
                  const Text(
                    'Heslo musí mít minimálně 8 znaků. Po registraci ti pošleme '
                    'ověřovací e-mail.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ===== Auth Gate (decides login vs home) =====

class AuthGate extends StatefulWidget {
  /// Vzniklo tohle AuthGate hned po prihlaseni?
  ///
  /// Rozlisuje dva pripady, ktere kod jinak nema jak odlisit: AuthGate je
  /// zaroven `home:` cele aplikace, takze `_check()` bezi i pri kazdem
  /// obycejnem spusteni. Konflikt mezi lokalnimi daty a serverovou zalohou
  /// ma smysl resit jen po skutecnem prihlaseni; pri beznem startu jsou
  /// lokalni data data toho uctu a neni o cem se ptat.
  ///
  /// Bez tohohle priznaku vyskakoval dialog "Nalezena zaloha na serveru"
  /// po kazdem spusteni aplikace.
  final bool poPrihlaseni;

  const AuthGate({super.key, this.poPrihlaseni = false});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  SharedPreferences? prefs;
  bool isLoading = true;
  bool isLoggedIn = false;
  Map<String, dynamic>? remoteBackup;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final p = await SharedPreferences.getInstance();
    final token = p.getString(AuthService.kTokenKey);
    if (token == null || token.isEmpty) {
      setState(() {
        prefs = p;
        isLoading = false;
        isLoggedIn = false;
      });
      return;
    }
    try {
      final res = await AuthService.downloadBackup(token);
      if (res.statusCode == 200) {
        setState(() {
          prefs = p;
          isLoading = false;
          isLoggedIn = true;
          remoteBackup = res.body;
        });
      } else if (res.statusCode == 404) {
        setState(() {
          prefs = p;
          isLoading = false;
          isLoggedIn = true;
        });
      } else if (res.statusCode == 401) {
        await p.remove(AuthService.kTokenKey);
        await p.remove(AuthService.kEmailKey);
        setState(() {
          prefs = p;
          isLoading = false;
          isLoggedIn = false;
        });
      } else {
        setState(() {
          prefs = p;
          isLoading = false;
          isLoggedIn = true;
        });
      }
    } catch (_) {
      setState(() {
        prefs = p;
        isLoading = false;
        isLoggedIn = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!isLoggedIn) {
      // Guest mode: aplikace funguje bez účtu, login je dostupný z nastavení.
      return const HomeScreen();
    }
    // Zaloha se stahuje vzdycky (pozna se tim vyprsela relace), ale do
    // HomeScreen jde jen po prihlaseni - jinak by se resil konflikt,
    // ktery zadny neni.
    return HomeScreen(remoteBackup: widget.poPrihlaseni ? remoteBackup : null);
  }
}

// ===== Admin Screen =====

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  bool isLoading = true;
  String? error;
  List<Map<String, dynamic>> users = [];
  int totalUsers = 0;
  int verifiedUsers = 0;

  int _sortColumnIndex = 2; // last_login_at by default
  bool _sortAscending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AuthService.kTokenKey);
    if (token == null || token.isEmpty) {
      if (mounted) setState(() {
        isLoading = false;
        error = 'Nejste přihlášen.';
      });
      return;
    }
    try {
      final res = await AuthService.getAdminUsers(token);
      if (!mounted) return;
      if (res.statusCode == 200 && res.body != null) {
        final data = res.body!;
        final list = (data['users'] as List? ?? [])
            .map((u) => Map<String, dynamic>.from(u as Map))
            .toList();
        setState(() {
          users = list;
          totalUsers = (data['total_users'] as int?) ?? list.length;
          verifiedUsers = (data['verified_users'] as int?) ?? 0;
          isLoading = false;
        });
        _sortUsers();
      } else if (res.statusCode == 401) {
        await prefs.remove(AuthService.kTokenKey);
        await prefs.remove(AuthService.kEmailKey);
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const AuthGate()),
            (_) => false,
          );
        }
      } else if (res.statusCode == 403) {
        setState(() {
          isLoading = false;
          error = 'Nemáte oprávnění (forbidden).';
        });
      } else {
        setState(() {
          isLoading = false;
          error = 'Chyba: HTTP ${res.statusCode}';
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        isLoading = false;
        error = 'Chyba spojení: $e';
      });
    }
  }

  void _sortUsers() {
    users.sort((a, b) {
      Object? va;
      Object? vb;
      switch (_sortColumnIndex) {
        case 0:
          va = a['email'];
          vb = b['email'];
          break;
        case 1:
          va = a['registered_at'];
          vb = b['registered_at'];
          break;
        case 2:
          va = a['last_login_at'];
          vb = b['last_login_at'];
          break;
        case 3:
          va = a['last_backup_at'];
          vb = b['last_backup_at'];
          break;
        case 4:
          va = a['backup_size_bytes'];
          vb = b['backup_size_bytes'];
          break;
      }
      final av = va ?? '';
      final bv = vb ?? '';
      final cmp = Comparable.compare(
        av is Comparable ? av : av.toString(),
        bv is Comparable ? bv : bv.toString(),
      );
      return _sortAscending ? cmp : -cmp;
    });
  }

  void _onSort(int idx, bool asc) {
    setState(() {
      _sortColumnIndex = idx;
      _sortAscending = asc;
      _sortUsers();
    });
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    return '${local.day}.${local.month}.${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes == 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Color _activityColor(String? lastLogin) {
    if (lastLogin == null) return Colors.grey;
    final dt = DateTime.tryParse(lastLogin);
    if (dt == null) return Colors.grey;
    final days = DateTime.now().difference(dt).inDays;
    if (days <= 1) return const Color(0xFF00FF88);
    if (days <= 7) return Colors.orange;
    if (days <= 30) return const Color(0xFF00D9FF);
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin přehled'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Obnovit',
            onPressed: _load,
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(error!, textAlign: TextAlign.center),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          _summaryCard('Celkem', totalUsers.toString(), const Color(0xFF00D9FF)),
                          const SizedBox(width: 12),
                          _summaryCard('Ověřených', verifiedUsers.toString(), const Color(0xFF00FF88)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SingleChildScrollView(
                          child: DataTable(
                            sortColumnIndex: _sortColumnIndex,
                            sortAscending: _sortAscending,
                            columns: [
                              DataColumn(
                                label: const Text('Email'),
                                onSort: _onSort,
                              ),
                              DataColumn(
                                label: const Text('Registrace'),
                                onSort: _onSort,
                              ),
                              DataColumn(
                                label: const Text('Poslední login'),
                                onSort: _onSort,
                              ),
                              DataColumn(
                                label: const Text('Poslední záloha'),
                                onSort: _onSort,
                              ),
                              DataColumn(
                                label: const Text('Velikost'),
                                numeric: true,
                                onSort: _onSort,
                              ),
                            ],
                            rows: users.map((u) {
                              final verified = u['verified'] == true;
                              return DataRow(cells: [
                                DataCell(Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: _activityColor(u['last_login_at'] as String?),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(u['email']?.toString() ?? ''),
                                    if (!verified) ...[
                                      const SizedBox(width: 6),
                                      const Icon(Icons.warning_amber, size: 14, color: Colors.orange),
                                    ],
                                  ],
                                )),
                                DataCell(Text(_formatDate(u['registered_at'] as String?))),
                                DataCell(Text(_formatDate(u['last_login_at'] as String?))),
                                DataCell(Text(_formatDate(u['last_backup_at'] as String?))),
                                DataCell(Text(_formatBytes(u['backup_size_bytes'] as int?))),
                              ]);
                            }).toList(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _summaryCard(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}

// ===== Prvouka pro Sofinku (hidden URL-gated section, no auth) =====

class PrvoukaLesson {
  final int number;
  final String title;
  final String file;
  PrvoukaLesson({required this.number, required this.title, required this.file});
}

class PrvoukaHomeScreen extends StatefulWidget {
  const PrvoukaHomeScreen({super.key});

  @override
  State<PrvoukaHomeScreen> createState() => _PrvoukaHomeScreenState();
}

class _PrvoukaHomeScreenState extends State<PrvoukaHomeScreen> {
  static const LanguageConfig _langConfig = LanguageConfig(AppLanguage.cs);

  late SharedPreferences prefs;
  List<PrvoukaLesson> lessons = [];
  Map<int, List<FlashCard>> lessonCards = {};
  Map<String, CardProgress> progress = {};
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    prefs = await SharedPreferences.getInstance();

    final progressJson = prefs.getString(_langConfig.progressKey);
    if (progressJson != null) {
      try {
        final Map<String, dynamic> data = json.decode(progressJson);
        data.forEach((key, value) {
          progress[key] = CardProgress.fromJson(value);
        });
      } catch (_) {}
    }

    try {
      final manifestStr = await rootBundle.loadString('assets/prvouka/manifest.json');
      final manifest = json.decode(manifestStr) as Map<String, dynamic>;
      final list = manifest['lessons'] as List;
      final loaded = list.map((l) => PrvoukaLesson(
            number: l['number'] as int,
            title: l['title'] as String,
            file: l['file'] as String,
          )).toList();

      final Map<int, List<FlashCard>> cards = {};
      for (final lesson in loaded) {
        try {
          final str = await rootBundle.loadString('assets/prvouka/${lesson.file}');
          final data = json.decode(str) as Map<String, dynamic>;
          final List<FlashCard> all = [];
          final cardsList = data['cards'] as List? ?? [];
          for (final c in cardsList) {
            all.add(FlashCard(
              en: c['q'] as String,
              cz: c['a'] as String,
              category: 'Lekce ${lesson.number}: ${lesson.title}',
            ));
          }
          cards[lesson.number] = all;
        } catch (_) {
          cards[lesson.number] = [];
        }
      }

      if (!mounted) return;
      setState(() {
        lessons = loaded;
        lessonCards = cards;
        isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  Future<void> _saveProgress() async {
    final Map<String, dynamic> progressJson = {};
    progress.forEach((key, value) {
      progressJson[key] = value.toJson();
    });
    await prefs.setString(_langConfig.progressKey, json.encode(progressJson));
  }

  String _cardKey(FlashCard card) => card.en.substring(0, min(50, card.en.length));

  double _lessonProgress(int lessonNumber) {
    final cards = lessonCards[lessonNumber] ?? [];
    if (cards.isEmpty) return 0.0;
    int learned = 0;
    for (final c in cards) {
      final p = progress[_cardKey(c)];
      if (p != null && p.interval > 21) learned++;
    }
    return learned / cards.length;
  }

  int _lessonDueCount(int lessonNumber) {
    final cards = lessonCards[lessonNumber] ?? [];
    final today = DateTime.now().toIso8601String().split('T')[0];
    int due = 0;
    for (final c in cards) {
      final p = progress[_cardKey(c)];
      if (p == null || p.nextReview.compareTo(today) <= 0) due++;
    }
    return due;
  }

  @override
  Widget build(BuildContext context) {
    final totalCards = lessonCards.values.fold<int>(0, (s, l) => s + l.length);
    final totalDue = lessons.fold<int>(0, (s, l) => s + _lessonDueCount(l.number));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Prvouka pro Sofinku 💜'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: isLoading
            ? const Center(child: CircularProgressIndicator())
            : lessons.isEmpty
                ? const Center(child: Text('Žádné lekce'))
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00D9FF).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF00D9FF).withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            '$totalCards otázek celkem · $totalDue k zopakování dnes',
                            style: const TextStyle(fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: lessons.length,
                          itemBuilder: (context, index) {
                            final lesson = lessons[index];
                            final cards = lessonCards[lesson.number] ?? [];
                            final dueCount = _lessonDueCount(lesson.number);
                            final progressValue = _lessonProgress(lesson.number);
                            final accentColor = progressValue >= 0.9
                                ? const Color(0xFF00FF88)
                                : progressValue >= 0.5
                                    ? Colors.orange
                                    : const Color(0xFF00D9FF);
                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              decoration: BoxDecoration(
                                color: accentColor.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: accentColor.withValues(alpha: 0.4)),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () async {
                                  if (cards.isEmpty) return;
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => LearningScreen(
                                        title: 'Lekce ${lesson.number}: ${lesson.title}',
                                        cards: cards,
                                        progress: progress,
                                        onSaveProgress: _saveProgress,
                                        langConfig: _langConfig,
                                        initialIsEnToCz: true,
                                      ),
                                    ),
                                  );
                                  if (mounted) setState(() {});
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              'Lekce ${lesson.number}: ${lesson.title}',
                                              style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            '${(progressValue * 100).toInt()}%',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: progressValue >= 0.9
                                                  ? const Color(0xFF00FF88)
                                                  : progressValue >= 0.5
                                                      ? Colors.orange
                                                      : Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '${cards.length} otázek · $dueCount k zopakování',
                                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                                      ),
                                      const SizedBox(height: 8),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: LinearProgressIndicator(
                                          value: progressValue,
                                          minHeight: 6,
                                          backgroundColor: Colors.white12,
                                          color: accentColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
