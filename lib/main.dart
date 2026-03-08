import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_fonts/google_fonts.dart';

// ─── Config ───────────────────────────────────────────────────────────────────
const _serverIp = '192.168.xx.xx';
const _baseUrl  = 'http://$_serverIp:8081';

// ─── Palette ──────────────────────────────────────────────────────────────────
const _bg          = Color(0xFF1A1918);
const _surface     = Color(0xFF242322);
const _card        = Color(0xFF2A2928);
const _border      = Color(0x28F4F3EE);
const _accent      = Color(0xFFC15F3C);
const _accentDim   = Color(0x1AC15F3C);
const _textPri     = Color(0xFFF4F3EE);
const _textSec     = Color(0xFFB1ADA1);
const _userBubble  = Color(0xFFC15F3C);

const _newsGradients = [
  [Color(0xFF1A2030), Color(0xFF0D2818)],
  [Color(0xFF201818), Color(0xFF301A10)],
  [Color(0xFF18181A), Color(0xFF28202A)],
  [Color(0xFF101828), Color(0xFF182838)],
  [Color(0xFF1A1A10), Color(0xFF28280A)],
];

// ── Topic colours ─────────────────────────────────────────────────────────────
const _topicColors = {
  'Monetary Policy': Color(0xFF2EC4A8),
  'Geopolitics':     Color(0xFFE05C5C),
  'Commodities':     Color(0xFFE09840),
  'Equities':        Color(0xFF60A8D8),
  'Fixed Income':    Color(0xFF9E8FE8),
  'FX & Currency':   Color(0xFF40D4A0),
  'Macro Data':      Color(0xFFE07898),
  'Credit Markets':  Color(0xFFD87858),
  'Energy':          Color(0xFFD8C040),
  'Technology':      Color(0xFF9080E8),
  'General':         Color(0xFF9A9080),
};

Color _topicColor(String topic) =>
    _topicColors[topic] ?? const Color(0xFF9A9080);

/// Maps a 1–10 risk score to a traffic-light colour.
/// Score 0 means "not yet scored" — returns a neutral dim colour.
Color _riskColor(int score) {
  if (score == 0) return const Color(0xFFB1ADA1);   // unscored — Cloudy
  if (score <= 3)  return const Color(0xFF38C88A);   // low      — green
  if (score <= 6)  return const Color(0xFFD4A840);   // medium   — amber
  if (score <= 8)  return const Color(0xFFE07848);   // high     — orange
  return const Color(0xFFD04040);                    // critical — red
}

/// Wraps bracketed citations like [1] or [Source 2] in backticks so
/// MarkdownStyleSheet.code can style them as subdued inline text.
String _dimCitations(String text) {
  // Matches [1], [2], [Source 1], [Source 2], etc.
  return text.replaceAllMapped(
    RegExp(r'\[((Source\s+)?\d+)\]'),
    (m) => '`[${m[1]}]`',
  );
}

void main() => runApp(const MacroTrackerApp());

// ─── ID counter ───────────────────────────────────────────────────────────────
int _idCounter = 0;
String _nextId() => 'msg_${++_idCounter}';

// ═══════════════════════════════════════════════════════════════════════════════
//  MODELS
// ═══════════════════════════════════════════════════════════════════════════════

class AnalysisSource {
  final int index;
  final String text;
  final String topic;
  const AnalysisSource({required this.index, required this.text, this.topic = ''});
  factory AnalysisSource.fromJson(Map<String, dynamic> j) => AnalysisSource(
    index: j['index'] as int,
    text:  j['text']  as String,
    topic: j['topic'] as String? ?? '',
  );
}

enum BubbleKind { normal, irrelevant, error, cancelled, image, ocrResult, redTeam, contagion }

// ── Portfolio row data ────────────────────────────────────────────────────────
class _PortfolioRow {
  final String ticker;
  final String name;
  final String weight;
  final double pct;
  final Color  barColor;
  final String assetClass;
  const _PortfolioRow(this.ticker, this.name, this.weight, this.pct,
      this.barColor, this.assetClass);
}

class ChatMessage {
  final String id;
  final String text;
  final bool isUser;
  final bool isLoading;
  final List<AnalysisSource> sources;
  final BubbleKind kind;
  final String? originText;
  final String? imagePath;
  final String? extractedText;
  final bool ocrSaved;
  // Lazily-fetched sub-analyses (cached inside the bubble)
  final String? redTeamText;
  final String? contagionText;
  final String? chartDataJson;   // raw JSON string from /analyze/impact_chart
  final bool isRedTeamLoading;
  final bool isContagionLoading;
  final bool isChartLoading;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.isUser,
    this.isLoading = false,
    this.sources = const [],
    this.kind = BubbleKind.normal,
    this.originText,
    this.imagePath,
    this.extractedText,
    this.ocrSaved = false,
    this.redTeamText,
    this.contagionText,
    this.chartDataJson,
    this.isRedTeamLoading = false,
    this.isContagionLoading = false,
    this.isChartLoading = false,
  });

  ChatMessage copyWith({
    String? text,
    bool? isLoading,
    List<AnalysisSource>? sources,
    BubbleKind? kind,
    String? extractedText,
    bool? ocrSaved,
    String? redTeamText,
    bool clearRedTeamText = false,
    String? contagionText,
    bool clearContagionText = false,
    String? chartDataJson,
    bool clearChartData = false,
    bool? isRedTeamLoading,
    bool? isContagionLoading,
    bool? isChartLoading,
  }) =>
      ChatMessage(
        id: id,
        text: text ?? this.text,
        isUser: isUser,
        isLoading: isLoading ?? this.isLoading,
        sources: sources ?? this.sources,
        kind: kind ?? this.kind,
        originText: originText,
        imagePath: imagePath,
        extractedText: extractedText ?? this.extractedText,
        ocrSaved: ocrSaved ?? this.ocrSaved,
        redTeamText: clearRedTeamText ? null : (redTeamText ?? this.redTeamText),
        contagionText: clearContagionText ? null : (contagionText ?? this.contagionText),
        chartDataJson: clearChartData ? null : (chartDataJson ?? this.chartDataJson),
        isRedTeamLoading: isRedTeamLoading ?? this.isRedTeamLoading,
        isContagionLoading: isContagionLoading ?? this.isContagionLoading,
        isChartLoading: isChartLoading ?? this.isChartLoading,
      );
}

class NewsArticle {
  final String title, summary, url, timeAgo;
  final String? imageUrl;
  final int riskScore;        // 0 = not yet scored, 1–10 = risk level
  final String riskReason;
  const NewsArticle({required this.title, required this.summary,
    required this.url, this.imageUrl, required this.timeAgo,
    this.riskScore = 0, this.riskReason = ''});
  factory NewsArticle.fromJson(Map<String, dynamic> j) => NewsArticle(
    title:      j['title']       ?? '',
    summary:    j['summary']     ?? '',
    url:        j['url']         ?? '',
    imageUrl:   j['image_url'],
    timeAgo:    j['time_ago']    ?? '',
    riskScore:  (j['risk_score'] as num?)?.toInt() ?? 0,
    riskReason: j['risk_reason'] as String? ?? '',
  );
}

// ─── Memory item ──────────────────────────────────────────────────────────────
class MemoryItem {
  final String id;
  final String text;
  final String title;
  final String topic;
  final List<String> tags;
  final List<String> regions;
  final List<String> assetClasses;
  final String summary;
  final String createdAt;
  final int order;
  final String source;

  const MemoryItem({
    required this.id, required this.text, required this.title,
    required this.topic, required this.tags, required this.regions,
    required this.assetClasses, required this.summary,
    required this.createdAt, required this.order, required this.source,
  });

  factory MemoryItem.fromJson(Map<String, dynamic> j) => MemoryItem(
    id:           j['id'] ?? '',
    text:         j['text'] ?? '',
    title:        j['title'] ?? 'Untitled',
    topic:        j['topic'] ?? 'General',
    tags:         List<String>.from(j['tags'] ?? []),
    regions:      List<String>.from(j['regions'] ?? []),
    assetClasses: List<String>.from(j['asset_classes'] ?? []),
    summary:      j['summary'] ?? '',
    createdAt:    j['created_at'] ?? '',
    order:        (j['order'] as num?)?.toInt() ?? 0,
    source:       j['source'] ?? 'manual',
  );
}

// ─── Trend item ──────────────────────────────────────────────────────────────
class TrendItem {
  final String topic;
  final double velocityScore;
  final String status;       // "hot" | "cool" | "stable"
  final int recentCount;
  final int baselineCount;

  const TrendItem({
    required this.topic, required this.velocityScore,
    required this.status, required this.recentCount,
    required this.baselineCount,
  });

  factory TrendItem.fromJson(Map<String, dynamic> j) => TrendItem(
    topic:          j['topic']          as String? ?? '',
    velocityScore:  (j['velocity_score'] as num?)?.toDouble() ?? 0,
    status:         j['status']         as String? ?? 'stable',
    recentCount:    (j['recent_count']  as num?)?.toInt() ?? 0,
    baselineCount:  (j['baseline_count'] as num?)?.toInt() ?? 0,
  );
}

// ─── Divergence item ─────────────────────────────────────────────────────────
class DivergenceItem {
  final String headline;
  final String description;
  const DivergenceItem({required this.headline, required this.description});
  factory DivergenceItem.fromJson(Map<String, dynamic> j) => DivergenceItem(
    headline:    j['headline']    as String? ?? 'None',
    description: j['description'] as String? ?? '',
  );
  bool get hasAlert => headline.isNotEmpty && headline != 'None';
}

// ─── Auto-organise suggestion ─────────────────────────────────────────────────
class OrganizeSuggestion {
  final String id;
  final String title;
  final String topic;
  final List<String> tags;
  final String summary;
  bool accepted;

  OrganizeSuggestion({
    required this.id, required this.title, required this.topic,
    required this.tags, required this.summary, this.accepted = true,
  });

  factory OrganizeSuggestion.fromJson(Map<String, dynamic> j) =>
      OrganizeSuggestion(
        id:      j['id'] ?? '',
        title:   j['title'] ?? '',
        topic:   j['topic'] ?? 'General',
        tags:    List<String>.from(j['tags'] ?? []),
        summary: j['summary'] ?? '',
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  APP
// ═══════════════════════════════════════════════════════════════════════════════

class MacroTrackerApp extends StatelessWidget {
  const MacroTrackerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Macro Tracker',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _bg,
      colorScheme: const ColorScheme.dark(primary: _accent, surface: _surface),
      useMaterial3: true,
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme).apply(
        bodyColor: _textPri, displayColor: _textPri),
    ),
    home: const ChatScreen(),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CHAT SCREEN
// ═══════════════════════════════════════════════════════════════════════════════

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  http.Client? _activeClient;
  bool _sending = false;

  List<NewsArticle> _news = [];
  bool _newsLoading = false;
  bool _newsExpanded = true;
  String? _newsError;

  final ImagePicker _picker = ImagePicker();
  bool _savingMem = false;

  @override
  void initState() {
    super.initState();
    _inputCtrl.addListener(_rebuild);
    _loadNews();
    _messages.add(ChatMessage(
      id: _nextId(),
      text: 'Hello. Describe a macro economic event and I\'ll map its risk chain using institutional memory.',
      isUser: false,
    ));
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _inputCtrl.removeListener(_rebuild);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _activeClient?.close();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  // ── Send ──────────────────────────────────────────────────────────────────
  Future<void> _send({String? override}) async {
    final text = (override ?? _inputCtrl.text).trim();
    if (text.isEmpty || _sending) return;
    if (override == null) _inputCtrl.clear();
    FocusScope.of(context).unfocus();

    final loadingId = _nextId();
    setState(() {
      _sending = true;
      _messages.add(ChatMessage(id: _nextId(), text: text, isUser: true));
      _messages.add(ChatMessage(id: loadingId, text: '', isUser: false,
          isLoading: true, originText: text));
    });
    _scrollToBottom();

    final client = http.Client();
    _activeClient = client;

    try {
      final res = await client.post(
        Uri.parse('$_baseUrl/analyze'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'event': text}),
      ).timeout(const Duration(seconds: 45));
      if (!mounted) return;

      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        switch ((j['status'] as String?) ?? 'success') {
          case 'irrelevant':
            _resolve(loadingId,
              text: (j['message'] as String?) ?? 'Please describe a macro economic event.',
              kind: BubbleKind.irrelevant);
            break;
          case 'error':
            _resolve(loadingId,
              text: (j['message'] as String?) ?? 'Server error.',
              kind: BubbleKind.error);
            break;
          default:
            final content = j['content'] as String?;
            if (content == null || content.trim().isEmpty) {
              _resolve(loadingId,
                text: 'The model didn\'t return a response. Try again in a moment.',
                kind: BubbleKind.error);
            } else {
              final sources = (j['sources'] as List? ?? [])
                  .map((s) => AnalysisSource.fromJson(s as Map<String, dynamic>)).toList();
              _resolve(loadingId, text: content, sources: sources);
            }
        }
      } else {
        _resolve(loadingId, text: 'Server error (${res.statusCode}).', kind: BubbleKind.error);
      }
    } on TimeoutException {
      if (!mounted) return;
      _resolve(loadingId,
        text: 'Analysis timed out — the model is taking too long. Tap ↻ to retry.',
        kind: BubbleKind.error);
    } on SocketException {
      if (!mounted) return;
      _resolve(loadingId,
        text: 'Network disconnected. Check Wi-Fi and that the backend is running.',
        kind: BubbleKind.error);
    } catch (e) {
      if (!mounted) return;
      final cancelled = e is http.ClientException ||
                        e.toString().contains('Connection closed');
      _resolve(loadingId,
        text: cancelled ? 'Request cancelled.' : 'Could not reach $_serverIp:8081.',
        kind: cancelled ? BubbleKind.cancelled : BubbleKind.error);
    } finally {
      client.close();
      if (_activeClient == client) _activeClient = null;
      if (mounted) setState(() => _sending = false);
    }
  }

  void _cancelRequest() { _activeClient?.close(); _activeClient = null; }

  Future<void> _regenerate(ChatMessage msg) async {
    if (_sending || msg.originText == null) return;
    final client = http.Client();
    _activeClient = client;
    setState(() {
      _sending = true;
      final idx = _messages.indexWhere((m) => m.id == msg.id);
      if (idx != -1) _messages[idx] = _messages[idx].copyWith(text: '', isLoading: true, kind: BubbleKind.normal);
    });
    _scrollToBottom();
    try {
      final res = await client.post(Uri.parse('$_baseUrl/analyze'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'event': msg.originText}))
          .timeout(const Duration(seconds: 45));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final status = (j['status'] as String?) ?? 'success';
        if (status == 'irrelevant') {
          _resolve(msg.id, text: j['message'] ?? 'Not a macro event.', kind: BubbleKind.irrelevant);
        } else if (status == 'error') {
          _resolve(msg.id, text: j['message'] ?? 'Server error.', kind: BubbleKind.error);
        } else {
          final content = j['content'] as String?;
          if (content == null || content.trim().isEmpty) {
            _resolve(msg.id, text: 'No response. Try again.', kind: BubbleKind.error);
          } else {
            final sources = (j['sources'] as List? ?? [])
                .map((s) => AnalysisSource.fromJson(s as Map<String, dynamic>)).toList();
            _resolve(msg.id, text: content, sources: sources);
          }
        }
      } else {
        _resolve(msg.id, text: 'Server error (${res.statusCode}).', kind: BubbleKind.error);
      }
    } on TimeoutException {
      if (!mounted) return;
      _resolve(msg.id,
        text: 'Analysis timed out. Tap ↻ to retry.',
        kind: BubbleKind.error);
    } on SocketException {
      if (!mounted) return;
      _resolve(msg.id,
        text: 'Network disconnected. Check Wi-Fi and that the backend is running.',
        kind: BubbleKind.error);
    } catch (e) {
      if (!mounted) return;
      _resolve(msg.id, text: 'Request failed — tap ↻ to retry.', kind: BubbleKind.error);
    } finally {
      client.close();
      if (_activeClient == client) _activeClient = null;
      if (mounted) setState(() => _sending = false);
    }
  }

  // ── Inline sub-analysis fetchers (update parent ChatMessage, no new bubble) ─
  Future<void> _fetchRedTeam(String msgId, String event) async {
    _patchMsg(msgId, (m) => m.copyWith(isRedTeamLoading: true));
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/analyze/red_team'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'event': event}),
      ).timeout(const Duration(seconds: 45));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final text = (j['content'] as String? ?? '').trim();
        _patchMsg(msgId, (m) => m.copyWith(
          redTeamText: text.isEmpty ? 'No contrarian view returned.' : text,
          isRedTeamLoading: false));
      } else {
        _patchMsg(msgId, (m) => m.copyWith(
          redTeamText: 'Server error (${res.statusCode}) — tap to retry.',
          isRedTeamLoading: false));
      }
    } on TimeoutException {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        redTeamText: 'Analysis timed out. Tap to retry.',
        isRedTeamLoading: false));
    } on SocketException {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        redTeamText: 'Network disconnected. Check Wi-Fi and tap to retry.',
        isRedTeamLoading: false));
    } catch (_) {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        redTeamText: 'Request failed — tap to retry.',
        isRedTeamLoading: false));
    }
  }

  Future<void> _fetchContagion(String msgId, String event) async {
    _patchMsg(msgId, (m) => m.copyWith(isContagionLoading: true));
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/analyze/contagion'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'event': event}),
      ).timeout(const Duration(seconds: 45));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final text = (j['content'] as String? ?? '').trim();
        _patchMsg(msgId, (m) => m.copyWith(
          contagionText: text.isEmpty ? 'No contagion map returned.' : text,
          isContagionLoading: false));
      } else {
        _patchMsg(msgId, (m) => m.copyWith(
          contagionText: 'Server error (${res.statusCode}) — tap to retry.',
          isContagionLoading: false));
      }
    } on TimeoutException {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        contagionText: 'Analysis timed out. Tap to retry.',
        isContagionLoading: false));
    } on SocketException {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        contagionText: 'Network disconnected. Check Wi-Fi and tap to retry.',
        isContagionLoading: false));
    } catch (_) {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        contagionText: 'Request failed — tap to retry.',
        isContagionLoading: false));
    }
  }


  Future<void> _fetchChart(String msgId, String event) async {
    _patchMsg(msgId, (m) => m.copyWith(isChartLoading: true));
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/analyze/impact_chart'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'event': event}),
      ).timeout(const Duration(seconds: 45));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        if ((j['status'] as String? ?? '') == 'success') {
          _patchMsg(msgId, (m) => m.copyWith(
            chartDataJson: jsonEncode(j),
            isChartLoading: false));
        } else {
          _patchMsg(msgId, (m) => m.copyWith(
            chartDataJson: jsonEncode({'error': j['message'] ?? 'Unknown error'}),
            isChartLoading: false));
        }
      } else {
        _patchMsg(msgId, (m) => m.copyWith(
          chartDataJson: jsonEncode({'error': 'Server error (${res.statusCode})'}),
          isChartLoading: false));
      }
    } on TimeoutException {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        chartDataJson: jsonEncode({'error': 'Chart timed out. Tap to retry.'}),
        isChartLoading: false));
    } on SocketException {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        chartDataJson: jsonEncode({'error': 'Network disconnected.'}),
        isChartLoading: false));
    } catch (_) {
      if (!mounted) return;
      _patchMsg(msgId, (m) => m.copyWith(
        chartDataJson: jsonEncode({'error': 'Request failed — tap to retry.'}),
        isChartLoading: false));
    }
  }
  void _patchMsg(String id, ChatMessage Function(ChatMessage) fn) {
    setState(() {
      final i = _messages.indexWhere((m) => m.id == id);
      if (i != -1) _messages[i] = fn(_messages[i]);
    });
  }

  void _resolve(String id, {
    required String text, List<AnalysisSource> sources = const [],
    BubbleKind kind = BubbleKind.normal, String? extractedText,
  }) {
    setState(() {
      final idx = _messages.indexWhere((m) => m.id == id);
      if (idx != -1) _messages[idx] = _messages[idx].copyWith(
        text: text, isLoading: false, sources: sources,
        kind: kind, extractedText: extractedText);
    });
  }

  // ── News ──────────────────────────────────────────────────────────────────
  Future<void> _loadNews() async {
    setState(() { _newsLoading = true; _newsError = null; });
    try {
      final res = await http.get(Uri.parse('$_baseUrl/news_feed'))
          .timeout(const Duration(seconds: 45));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final articles = (j['articles'] as List? ?? [])
            .map((a) => NewsArticle.fromJson(a as Map<String, dynamic>)).toList();
        setState(() {
          _news = articles;
          _newsError = articles.isEmpty ? 'Feed returned no articles.' : null;
        });
      } else {
        setState(() => _newsError = 'Feed unavailable (HTTP ${res.statusCode}).');
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _newsError = 'timeout');
    } on SocketException {
      if (!mounted) return;
      setState(() => _newsError = 'disconnected');
    } catch (_) {
      if (!mounted) return;
      setState(() => _newsError = 'unreachable');
    } finally {
      if (mounted) setState(() => _newsLoading = false);
    }
  }

  Future<void> _analyseArticle(NewsArticle article) async {
    http.post(Uri.parse('$_baseUrl/remember'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'text': '[News] ${article.title}. ${article.summary}', 'source': 'news'}));
    await _send(override: article.title);
  }

  // ── OCR ───────────────────────────────────────────────────────────────────
  Future<void> _pickAndOcr(ImageSource source) async {
    if (mounted) Navigator.pop(context);
    XFile? file;
    try {
      file = await _picker.pickImage(source: source, maxWidth: 1920, imageQuality: 85);
    } catch (e) {
      _snack('Could not access ${source == ImageSource.camera ? "camera" : "gallery"}: $e');
      return;
    }
    if (file == null) return;

    final imageMsgId = _nextId();
    final ocrResultId = _nextId();
    setState(() {
      _messages.add(ChatMessage(id: imageMsgId, text: '', isUser: true,
          kind: BubbleKind.image, imagePath: file!.path));
      _messages.add(ChatMessage(id: ocrResultId, text: '', isUser: false,
          isLoading: true, kind: BubbleKind.ocrResult));
    });
    _scrollToBottom();

    try {
      final bytes = await file.readAsBytes();
      final res = await http.post(Uri.parse('$_baseUrl/ingest_image'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'image_base64': base64Encode(bytes), 'source_label': 'ocr'}))
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['status'] == 'success') {
        final extracted = (j['extracted_text'] as String? ?? '').trim();
        if (extracted.isEmpty) {
          _resolve(ocrResultId, text: 'No text extracted. Try a clearer photo.', kind: BubbleKind.error);
        } else {
          _resolve(ocrResultId, text: extracted, kind: BubbleKind.ocrResult, extractedText: extracted);
        }
      } else {
        _resolve(ocrResultId, text: j['message'] ?? 'OCR failed.', kind: BubbleKind.error);
      }
    } on TimeoutException {
      if (!mounted) return;
      _resolve(ocrResultId,
        text: 'OCR timed out. Try a clearer photo or check the backend.',
        kind: BubbleKind.error);
    } on SocketException {
      if (!mounted) return;
      _resolve(ocrResultId,
        text: 'Network disconnected. Check Wi-Fi and try again.',
        kind: BubbleKind.error);
    } catch (e) {
      if (!mounted) return;
      _resolve(ocrResultId,
        text: 'OCR failed — check backend is running.',
        kind: BubbleKind.error);
    }
    _scrollToBottom();
  }

  Future<void> _saveOcrResult(String msgId, String text) async {
    if (text.trim().isEmpty) return;
    try {
      final res = await http.post(Uri.parse('$_baseUrl/remember'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': '[News Capture] ${text.trim()}', 'source': 'ocr'}))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == msgId);
          if (idx != -1) _messages[idx] = _messages[idx].copyWith(ocrSaved: true);
        });
        _snack('Saved to Institutional Memory', good: true);
      } else {
        _snack('Save failed (${res.statusCode})');
      }
    } on TimeoutException {
      _snack('Save timed out — check backend connection');
    } on SocketException {
      _snack('Network disconnected — save failed');
    } catch (_) {
      _snack('Save failed — check connection');
    }
  }

  void _snack(String msg, {bool good = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: TextStyle(
        color: Colors.white, fontWeight: FontWeight.w600)),
      backgroundColor: good ? _accent : const Color(0xFFC04828),
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _openImageOptions() {
    showModalBottomSheet(
      context: context, backgroundColor: _surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _handle(),
          const SizedBox(height: 16),
          const Text('Capture News Article', style: TextStyle(color: _textPri, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Photo text is extracted automatically via OCR.', style: TextStyle(color: _textSec, fontSize: 13)),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: _iconTile(Icons.camera_alt_rounded, 'Camera',
                () => _pickAndOcr(ImageSource.camera))),
            const SizedBox(width: 14),
            Expanded(child: _iconTile(Icons.photo_library_rounded, 'Gallery',
                () => _pickAndOcr(ImageSource.gallery))),
          ]),
          const SizedBox(height: 8),
        ]),
      )),
    );
  }

  // ── Shared helpers ────────────────────────────────────────────────────────
  Widget _handle() => Center(child: Container(width: 36, height: 4,
      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))));

  InputDecoration _inputDeco({String? hint}) => InputDecoration(
    hintText: hint, hintStyle: const TextStyle(color: _textSec, fontSize: 13),
    filled: true, fillColor: _card,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _border)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _border)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _accent.withOpacity(0.5), width: 1.2)),
    contentPadding: const EdgeInsets.all(14),
  );

  Widget _fillBtn(String label, VoidCallback? onTap) => ElevatedButton(
    onPressed: onTap,
    style: ElevatedButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white,
      disabledBackgroundColor: _accent.withOpacity(0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      padding: const EdgeInsets.symmetric(vertical: 14)),
    child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)));

  Widget _iconTile(IconData icon, String label, VoidCallback onTap) =>
    GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: _border)),
      child: Column(children: [
        Icon(icon, color: _accent, size: 28),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: _textPri, fontSize: 13, fontWeight: FontWeight.w500)),
      ])));

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _bg,
    body: SafeArea(child: Column(children: [
      _buildHeader(),
      Expanded(child: _buildChatList()),
      _buildNewsSection(),
      _buildInputBar(),
    ])),
  );

  Widget _buildHeader() => Container(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
    decoration: const BoxDecoration(
      color: _bg,
      border: Border(bottom: BorderSide(color: _border, width: 0.5))),
    child: Row(children: [
      RichText(text: TextSpan(children: [
        TextSpan(text: 'Macro', style: GoogleFonts.newsreader(
          color: _textPri, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 1.0)),
        TextSpan(text: 'Pollo', style: GoogleFonts.newsreader(
          color: _accent, fontSize: 20, fontWeight: FontWeight.w800,
          letterSpacing: 1.0, fontStyle: FontStyle.italic)),
      ])),
      const Spacer(),
      GestureDetector(
        onTap: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => const MemoryDashboardScreen())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(20)),
          child: Row(children: [
            const Icon(Icons.memory_rounded, color: _textSec, size: 13),
            const SizedBox(width: 5),
            Text('Memory', style: GoogleFonts.inter(
              color: _textSec, fontSize: 12, fontWeight: FontWeight.w500)),
          ])),
      ),
    ]),
  );

  Widget _buildChatList() => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    itemCount: _messages.length,
    itemBuilder: (_, i) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _messages[i].isUser ? _userBubble(_messages[i]) : _aiBubble(_messages[i])));

  Widget _userBubble(ChatMessage msg) {
    if (msg.kind == BubbleKind.image && msg.imagePath != null) {
      return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18), bottomRight: Radius.circular(4)),
            border: Border.all(color: _accent.withOpacity(0.4), width: 1.5)),
          clipBehavior: Clip.hardEdge,
          child: Stack(children: [
            Image.file(File(msg.imagePath!), fit: BoxFit.cover,
              width: MediaQuery.of(context).size.width * 0.65, height: 180,
              errorBuilder: (_, __, ___) => Container(width: MediaQuery.of(context).size.width * 0.65,
                height: 100, color: _card, child: const Center(child: Icon(Icons.broken_image_rounded, color: _textSec)))),
            Positioned(bottom: 8, left: 8, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.65), borderRadius: BorderRadius.circular(6)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.document_scanner_rounded, color: _accent, size: 12),
                SizedBox(width: 4),
                Text('News capture', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500)),
              ]))),
          ]),
        ),
      ]);
    }
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      Flexible(child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        decoration: const BoxDecoration(color: Color(0xFFC15F3C),
          borderRadius: BorderRadius.all(Radius.circular(20))),
        child: Text(msg.text, style: GoogleFonts.inter(
          color: Colors.white, fontSize: 15, height: 1.45, fontWeight: FontWeight.w400)),
      )),
    ]);
  }

  // ── Layout wrapper — accent-bar + max-width; content in _AIBubble widget ──
  Widget _aiBubble(ChatMessage msg) {
    final isErr     = msg.kind == BubbleKind.error;
    final isIrrelev = msg.kind == BubbleKind.irrelevant;
    final isOcr     = msg.kind == BubbleKind.ocrResult;
    final showBar   = isErr || isIrrelev || isOcr;
    final barColor  = isErr
        ? const Color(0xFFD04040)
        : isIrrelev
            ? const Color(0xFFD4A840)
            : _accent;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBar)
            Container(
              width: 2,
              margin: const EdgeInsets.only(top: 3, right: 12, bottom: 3),
              decoration: BoxDecoration(
                color: barColor.withOpacity(0.7),
                borderRadius: BorderRadius.circular(1)))
          else
            const SizedBox(width: 14),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.88),
              child: msg.isLoading
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: _loadingDots())
                  : _AIBubble(
                      key: ValueKey(msg.id),
                      msg: msg,
                      onFetchRedTeam: (id, ev) => _fetchRedTeam(id, ev),
                      onFetchContagion: (id, ev) => _fetchContagion(id, ev),
                      onFetchChart: (id, ev) => _fetchChart(id, ev),
                      onRegenerate: () => _regenerate(msg),
                      onSaveOcr: (edited) => _saveOcrResult(msg.id, edited)))),
        ]));
  }

  Widget _loadingDots() => Row(mainAxisSize: MainAxisSize.min,
    children: List.generate(3, (i) => _PulsingDot(delay: Duration(milliseconds: i * 160), color: _accent)));

  Widget _sourcesBlock(List<AnalysisSource> sources) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(color: _border, height: 1),
      const SizedBox(height: 10),
      Text('Sources', style: TextStyle(color: _textSec.withOpacity(0.8), fontSize: 11,
          fontWeight: FontWeight.w600, letterSpacing: 0.8)),
      const SizedBox(height: 8),
      ...sources.map(_sourceTile),
    ]);

  Widget _sourceTile(AnalysisSource src) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: ClipRRect(borderRadius: BorderRadius.circular(8),
      child: Theme(data: ThemeData.dark().copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          dense: true, backgroundColor: _card, collapsedBackgroundColor: _card,
          iconColor: _accent, collapsedIconColor: _textSec,
          leading: Container(width: 22, height: 22,
            decoration: BoxDecoration(color: _accentDim, borderRadius: BorderRadius.circular(5)),
            child: Center(child: Text('[${src.index}]', style: const TextStyle(color: _accent, fontSize: 10, fontWeight: FontWeight.bold)))),
          title: Row(children: [
            if (src.topic.isNotEmpty) ...[
              Container(width: 6, height: 6,
                decoration: BoxDecoration(color: _topicColor(src.topic), shape: BoxShape.circle)),
              const SizedBox(width: 6),
            ],
            Expanded(child: Text(src.text.length > 50 ? '${src.text.substring(0, 50)}…' : src.text,
              style: const TextStyle(color: _textSec, fontSize: 12))),
          ]),
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(src.text, style: GoogleFonts.newsreader(color: _textPri, fontSize: 13, height: 1.55, fontStyle: FontStyle.italic))),
          ],
        ))));

  // ── News section ──────────────────────────────────────────────────────────
  Widget _buildNewsSection() => Container(
    decoration: const BoxDecoration(border: Border(top: BorderSide(color: _border))),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: () => setState(() => _newsExpanded = !_newsExpanded),
        child: Container(color: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            const Icon(Icons.rss_feed_rounded, color: _accent, size: 14),
            const SizedBox(width: 7),
            Text('Live News', style: GoogleFonts.inter(color: _textSec, fontSize: 12, fontWeight: FontWeight.w500)),
            const SizedBox(width: 6),
            if (_news.isNotEmpty) Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: _accentDim, borderRadius: BorderRadius.circular(4)),
              child: Text('${_news.length}', style: const TextStyle(color: _accent, fontSize: 10, fontWeight: FontWeight.bold))),
            const Spacer(),
            GestureDetector(onTap: _newsLoading ? null : _loadNews,
              child: _newsLoading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _accent))
                : const Icon(Icons.refresh_rounded, color: _textSec, size: 16)),
            const SizedBox(width: 10),
            Icon(_newsExpanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
              color: _textSec, size: 18),
          ])),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
        child: _newsExpanded ? SizedBox(height: 210, child: _newsCards()) : const SizedBox.shrink()),
    ]));

  Widget _newsCards() {
    if (_newsLoading) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: _accent));
    if (_newsError != null) {
      // Decode sentinel values set by typed catches
      final bool isTimeout      = _newsError == 'timeout';
      final bool isDisconnected = _newsError == 'disconnected' || _newsError == 'unreachable';
      final IconData icon  = isTimeout ? Icons.hourglass_empty_rounded
                           : isDisconnected ? Icons.wifi_off_rounded
                           : Icons.rss_feed_rounded;
      final String title   = isTimeout      ? 'Feed timed out'
                           : isDisconnected ? 'No connection'
                           : 'Feed unavailable';
      final String sub     = isTimeout      ? 'The backend is running slowly — tap ↻ to retry.'
                           : isDisconnected ? 'Check Wi-Fi and that main.py is running.'
                           : _newsError!;
      return Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _surface,
              shape: BoxShape.circle,
              border: Border.all(color: _border)),
            child: Icon(icon, color: _textSec, size: 20)),
          const SizedBox(height: 10),
          Text(title, style: GoogleFonts.inter(
            color: _textPri, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(sub, textAlign: TextAlign.center,
            style: GoogleFonts.inter(color: _textSec, fontSize: 11, height: 1.4)),
          const SizedBox(height: 14),
          GestureDetector(onTap: _loadNews, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              color: _accentDim,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _accent.withOpacity(0.3))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.refresh_rounded, color: _accent, size: 13),
              const SizedBox(width: 6),
              Text('Retry', style: GoogleFonts.inter(
                color: _accent, fontSize: 12, fontWeight: FontWeight.w600)),
            ]))),
        ])));
    }
    if (_news.isEmpty) return Center(child: Text('No articles available',
      style: GoogleFonts.inter(color: _textSec, fontSize: 13)));
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(left: 14, right: 14, bottom: 12),
      itemCount: _news.length,
      itemBuilder: (_, i) => _newsCard(_news[i], i));
  }

  Widget _newsCard(NewsArticle article, int index) {
    final grad      = _newsGradients[index % _newsGradients.length];
    final riskCol   = _riskColor(article.riskScore);
    final isScored   = article.riskScore > 0;
    final isCritical = article.riskScore >= 8;

    return Container(
      width: 240, margin: const EdgeInsets.only(right: 10),
      decoration: BoxDecoration(
        color: isCritical ? const Color(0xFF2A1818) : _card,
        borderRadius: BorderRadius.circular(12),
        border: isCritical
            ? Border.all(color: const Color(0xFFD04040).withOpacity(0.4), width: 1)
            : null,
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Image / gradient header ──────────────────────────────────────────
        Expanded(flex: 5, child: Stack(fit: StackFit.expand, children: [
          Container(decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight, colors: grad))),
          if (article.imageUrl != null)
            Image.network(article.imageUrl!, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          Container(decoration: const BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0x88000000)]))),

          // ── Risk badge — top left ──────────────────────────────────────────
          Positioned(top: 8, left: 8, child: _RiskBadge(score: article.riskScore)),

          // ── Time badge — top right ─────────────────────────────────────────
          if (article.timeAgo.isNotEmpty)
            Positioned(top: 8, right: 8, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.black54, borderRadius: BorderRadius.circular(5)),
              child: Text(article.timeAgo,
                  style: const TextStyle(color: Colors.white70, fontSize: 10,
                      fontWeight: FontWeight.w500)))),
        ])),

        // ── Critical Alert banner — full-width strip below image ────────────
        if (isCritical)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 5),
            color: const Color(0xFFD04040).withOpacity(0.12),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Color(0xFFD04040), size: 11),
              const SizedBox(width: 4),
              const Text('CRITICAL ALERT',
                  style: TextStyle(color: Color(0xFFD04040), fontSize: 9.5,
                      fontWeight: FontWeight.w800, letterSpacing: 1.1)),
            ])),

        // ── Card body ────────────────────────────────────────────────────────
        Expanded(flex: 6, child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Title
            Text(article.title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: isCritical ? const Color(0xFFD04040) : _textPri,
                  fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.35)),
            const SizedBox(height: 4),

            // Risk reason (when scored) or plain summary (unscored)
            Expanded(child: isScored && article.riskReason.isNotEmpty
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(width: 2.5, margin: const EdgeInsets.only(top: 1, right: 5),
                    decoration: BoxDecoration(
                        color: riskCol, borderRadius: BorderRadius.circular(2))),
                  Expanded(child: Text(article.riskReason,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: riskCol.withOpacity(0.9),
                        fontSize: 11, height: 1.4, fontStyle: FontStyle.italic))),
                ])
              : Text(article.summary, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _textSec, fontSize: 11, height: 1.4))),

            const SizedBox(height: 6),

            // Analyse button
            SizedBox(width: double.infinity, height: 30, child: ElevatedButton(
              onPressed: _sending ? null : () => _analyseArticle(article),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                foregroundColor: _textSec,
                disabledForegroundColor: _textSec.withOpacity(0.3),
                elevation: 0, padding: EdgeInsets.zero,
                side: BorderSide(color: _border),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6))),
              child: Text('Analyse', style: GoogleFonts.inter(
                  fontSize: 11, fontWeight: FontWeight.w600,
                  letterSpacing: 0.2)))),
          ]))),
      ]));
  }

  Widget _buildInputBar() {
    final canSend = !_sending && _inputCtrl.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      decoration: BoxDecoration(
        color: _bg,
        border: Border(top: BorderSide(color: _border, width: 0.5))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        // Camera — ghost button
        GestureDetector(
          onTap: _sending ? null : _openImageOptions,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 11, right: 8),
            child: Icon(Icons.camera_alt_outlined,
                color: _sending ? _textSec.withOpacity(0.4) : _textSec, size: 22))),
        // Text field — flat, fully rounded
        Expanded(child: Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(24)),
          child: TextField(controller: _inputCtrl,
            style: GoogleFonts.inter(color: _textPri, fontSize: 15, height: 1.4),
            maxLines: 5, minLines: 1,
            decoration: InputDecoration(
              hintText: 'Describe a macro event…',
              hintStyle: GoogleFonts.inter(color: _textSec, fontSize: 15),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11)),
            onSubmitted: (_) { if (canSend) _send(); }))),
        // Send / stop
        const SizedBox(width: 8),
        _sending
          ? GestureDetector(
              onTap: _cancelRequest,
              child: Container(width: 44, height: 44,
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: _accent.withOpacity(0.6))),
                child: const Icon(Icons.stop_rounded, color: _accent, size: 20)))
          : AnimatedOpacity(
              opacity: canSend ? 1.0 : 0.35,
              duration: const Duration(milliseconds: 150),
              child: GestureDetector(
                onTap: canSend ? _send : null,
                child: Container(width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: _accent, borderRadius: BorderRadius.circular(22)),
                  child: const Icon(Icons.arrow_upward_rounded,
                      color: Colors.white, size: 20)))),
      ]));
  }

  Widget _circleBtn({required IconData icon, VoidCallback? onTap, Color? color, Color? iconColor}) =>
    GestureDetector(onTap: onTap, child: Container(width: 44, height: 44,
      decoration: BoxDecoration(color: color ?? _surface, borderRadius: BorderRadius.circular(22)),
      child: Icon(icon, color: iconColor ?? _textSec, size: 20)));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  AI BUBBLE — STATEFUL (manages sub-tab state and lazy analysis fetching)
// ═══════════════════════════════════════════════════════════════════════════════

enum _BubbleTab { main, redTeam, contagion, chart }

class _AIBubble extends StatefulWidget {
  final ChatMessage msg;
  final Future<void> Function(String id, String event) onFetchRedTeam;
  final Future<void> Function(String id, String event) onFetchContagion;
  final Future<void> Function(String id, String event) onFetchChart;
  final VoidCallback onRegenerate;
  final Future<void> Function(String) onSaveOcr;

  const _AIBubble({
    super.key,
    required this.msg,
    required this.onFetchRedTeam,
    required this.onFetchContagion,
    required this.onFetchChart,
    required this.onRegenerate,
    required this.onSaveOcr,
  });

  @override
  State<_AIBubble> createState() => _AIBubbleState();
}

class _AIBubbleState extends State<_AIBubble>
    with SingleTickerProviderStateMixin {
  _BubbleTab _tab = _BubbleTab.main;
  final _shareKey = GlobalKey();
  late final AnimationController _shareAnim;
  late final Animation<double> _shareScale;

  // ── Colour helpers ────────────────────────────────────────────────────────
  static const _contagionBlue = Color(0xFF4A8EC2);

  Color get _textColor {
    final k = widget.msg.kind;
    if (k == BubbleKind.error)      return const Color(0xFFD04040);
    if (k == BubbleKind.irrelevant) return const Color(0xFFD4A840);
    return _textPri;
  }

  // Whether this bubble supports the analysis sub-tabs
  bool get _showTabs =>
      widget.msg.kind == BubbleKind.normal &&
      widget.msg.sources.isNotEmpty &&
      widget.msg.originText != null;

  // ── Markdown stylesheet (shared) ──────────────────────────────────────────
  MarkdownStyleSheet _mdStyle([Color? override]) {
    final col = override ?? _textColor;
    return MarkdownStyleSheet(
      // ── Body text ───────────────────────────────────────────────────────
      p: GoogleFonts.newsreader(color: col, fontSize: 15.5, height: 1.7),
      strong: GoogleFonts.newsreader(
          color: _tab == _BubbleTab.main ? _accent : col,
          fontWeight: FontWeight.w700,
          fontSize: 15.5),
      em: GoogleFonts.newsreader(
          color: col, fontStyle: FontStyle.italic,
          fontSize: 15.5, height: 1.7),
      // ── Headings ────────────────────────────────────────────────────────
      h1: GoogleFonts.newsreader(
          color: _textPri, fontSize: 20,
          fontWeight: FontWeight.w700, height: 1.3),
      h2: GoogleFonts.newsreader(
          color: _textPri, fontSize: 17,
          fontWeight: FontWeight.w600, height: 1.35),
      h3: GoogleFonts.newsreader(
          color: _textPri, fontSize: 15.5, fontWeight: FontWeight.w600),
      // ── Code ────────────────────────────────────────────────────────────
      code: GoogleFonts.inter(
          color: _textSec, fontSize: 12,
          backgroundColor: Colors.transparent),
      codeblockDecoration: BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(6)),
      // ── Lists ───────────────────────────────────────────────────────────
      listBullet: GoogleFonts.newsreader(color: _accent, fontSize: 15.5),
      listIndent: 20,
      blockSpacing: 12,
      // ── Blockquote ──────────────────────────────────────────────────────
      blockquoteDecoration: BoxDecoration(
          color: _surface,
          border: Border(
              left: BorderSide(color: _accent, width: 3))),
      blockquotePadding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      blockquote: GoogleFonts.newsreader(
          color: _textPri, fontStyle: FontStyle.italic, fontSize: 15,
          height: 1.6),
      // ── Tables ──────────────────────────────────────────────────────────
      tableBorder: TableBorder.all(color: _border, width: 0.5),
      tableCellsPadding: const EdgeInsets.all(12),
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableHead: GoogleFonts.inter(
          color: _textSec,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8),
      tableBody: GoogleFonts.inter(
          color: _textPri,
          fontSize: 13,
          height: 1.45),
      tableHeadAlign: TextAlign.left,
    );
  }

  // ── Tab-switching + lazy fetch ────────────────────────────────────────────
  void _switchTab(_BubbleTab tab) {
    setState(() => _tab = tab);
    final msg = widget.msg;
    if (tab == _BubbleTab.redTeam &&
        msg.redTeamText == null &&
        !msg.isRedTeamLoading) {
      widget.onFetchRedTeam(msg.id, msg.originText!);
    } else if (tab == _BubbleTab.contagion &&
        msg.contagionText == null &&
        !msg.isContagionLoading) {
      widget.onFetchContagion(msg.id, msg.originText!);
    } else if (tab == _BubbleTab.chart &&
        msg.chartDataJson == null &&
        !msg.isChartLoading) {
      widget.onFetchChart(msg.id, msg.originText!);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _shareAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _shareScale = Tween<double>(begin: 1.0, end: 0.82).animate(
      CurvedAnimation(parent: _shareAnim, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _shareAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;

    // OCR result — no tabs
    if (msg.kind == BubbleKind.ocrResult && msg.extractedText != null) {
      return _OcrResultContent(
          msgId: msg.id,
          extractedText: msg.extractedText!,
          saved: msg.ocrSaved,
          onSave: widget.onSaveOcr);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── Tab bar + share button ────────────────────────────────────────────
      if (_showTabs) ...[
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: _buildTabBar()),
            GestureDetector(
              key: _shareKey,
              onTap: () async {
                await _shareAnim.forward();
                await _shareAnim.reverse();
                _exportMemo();
              },
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ScaleTransition(
                  scale: _shareScale,
                  child: Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _textSec.withOpacity(0.25),
                        width: 1,
                      ),
                    ),
                    child: Icon(Icons.ios_share_rounded,
                        color: _textSec.withOpacity(0.6), size: 14))))),
          ]),
        const SizedBox(height: 16),
      ],

      // ── Content pane ─────────────────────────────────────────────────────
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: KeyedSubtree(
          key: ValueKey(_tab),
          child: _buildPane(),
        )),

      // ── Sources — always visible ──────────────────────────────────────────
      if (msg.sources.isNotEmpty) ...[
        const SizedBox(height: 14),
        _sourcesBlock(msg.sources),
      ],

      // ── Retry button (error / cancelled) ─────────────────────────────────
      if ((msg.kind == BubbleKind.error ||
              msg.kind == BubbleKind.cancelled) &&
          msg.originText != null) ...[
        const SizedBox(height: 12),
        GestureDetector(
          onTap: widget.onRegenerate,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
                color: _accentDim,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _accent.withOpacity(0.3))),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.refresh_rounded, color: _accent, size: 14),
              SizedBox(width: 6),
              Text('Try again',
                  style: TextStyle(
                      color: _accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ]))),
      ],
    ]);
  }

  // ── Minimal flat tab bar ──────────────────────────────────────────────────
  void _exportMemo() {
    final msg = widget.msg;
    if (msg.originText == null) return;

    final buf = StringBuffer();

    // ── Header ─────────────────────────────────────────────────────────────
    buf.writeln('# MacroPollo IC Memo');
    buf.writeln();
    buf.writeln('**Event:** ${msg.originText}');
    buf.writeln();
    buf.writeln('---');
    buf.writeln();

    // ── Main analysis ──────────────────────────────────────────────────────
    buf.writeln('## Main Analysis');
    buf.writeln();
    buf.writeln(msg.text.trim());
    buf.writeln();

    // ── Devil's Advocate (only if loaded) ──────────────────────────────────
    if (msg.redTeamText != null && msg.redTeamText!.isNotEmpty) {
      buf.writeln('---');
      buf.writeln();
      buf.writeln("## Devil's Advocate");
      buf.writeln();
      buf.writeln(msg.redTeamText!.trim());
      buf.writeln();
    }

    // ── Ripple Effect (only if loaded) ─────────────────────────────────────
    if (msg.contagionText != null && msg.contagionText!.isNotEmpty) {
      buf.writeln('---');
      buf.writeln();
      buf.writeln('## Ripple Effect');
      buf.writeln();
      buf.writeln(msg.contagionText!.trim());
      buf.writeln();
    }

    // ── Sources ────────────────────────────────────────────────────────────
    if (msg.sources.isNotEmpty) {
      buf.writeln('---');
      buf.writeln();
      buf.writeln('## Sources');
      buf.writeln();
      for (final s in msg.sources) {
        final topicTag = s.topic.isNotEmpty ? ' [${s.topic}]' : '';
        buf.writeln('[${s.index}]$topicTag ${s.text.trim()}');
        buf.writeln();
      }
    }

    // ── Footer ─────────────────────────────────────────────────────────────
    buf.writeln('---');
    buf.writeln('*Generated by MacroPollo*');

    // Determine anchor rect for iPad popover
    Rect? origin;
    final box = _shareKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final pos = box.localToGlobal(Offset.zero);
      origin = pos & box.size;
    }

    Share.share(
      buf.toString(),
      subject: 'Macro Risk Briefing: ${msg.originText}',
      sharePositionOrigin: origin,
    );
  }

  Widget _buildTabBar() {
    const tabs = [
      (_BubbleTab.main,      'Main Analysis'),
      (_BubbleTab.redTeam,   "Devil's Advocate"),
      (_BubbleTab.contagion, 'Ripple Effect'),
      (_BubbleTab.chart,     'Impact Chart'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: tabs.map((t) => _tabLabel(t.$1, t.$2)).toList(),
      ),
    );
  }

  Widget _tabLabel(_BubbleTab tab, String label) {
    final active  = _tab == tab;
    final loading =
        (tab == _BubbleTab.redTeam   && widget.msg.isRedTeamLoading) ||
        (tab == _BubbleTab.contagion && widget.msg.isContagionLoading) ||
        (tab == _BubbleTab.chart     && widget.msg.isChartLoading);

    return GestureDetector(
      onTap: () => _switchTab(tab),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? _accent.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (loading)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: SizedBox(
                width: 9, height: 9,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: tab == _BubbleTab.contagion
                      ? _contagionBlue : _accent))),
          Text(label,
            style: GoogleFonts.inter(
              color:      active ? _accent : _textPri.withOpacity(0.7),
              fontSize:   14,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 0.1,
            )),
        ]),
      ),
    );
  }

  // ── Content pane switch ───────────────────────────────────────────────────
  Widget _buildPane() {
    switch (_tab) {
      case _BubbleTab.main:
        return _buildMainPane();
      case _BubbleTab.redTeam:
        return _buildSubPane(
          text: widget.msg.redTeamText,
          isLoading: widget.msg.isRedTeamLoading,
          emptyHint: 'Tap Devil\'s Advocate to load contrarian analysis.',
          textColor: _textColor,
        );
      case _BubbleTab.contagion:
        return _buildSubPane(
          text: widget.msg.contagionText,
          isLoading: widget.msg.isContagionLoading,
          emptyHint: 'Tap Ripple Effect to load contagion map.',
          textColor: _textColor,
        );
      case _BubbleTab.chart:
        return _buildChartPane();
    }
  }

  Widget _buildMainPane() {
    return MarkdownBody(
        data: _dimCitations(widget.msg.text), styleSheet: _mdStyle());
  }

  // ── Impact Projection Chart ───────────────────────────────────────────────
  Widget _buildChartPane() {
    final msg = widget.msg;

    // Loading state
    if (msg.isChartLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          SizedBox(
            width: 13, height: 13,
            child: CircularProgressIndicator(strokeWidth: 2, color: _accent)),
          const SizedBox(width: 10),
          Text('Projecting asset impacts…',
              style: GoogleFonts.inter(color: _textSec, fontSize: 13)),
        ]));
    }

    // Not yet requested
    if (msg.chartDataJson == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('Tap Impact Chart to generate projections.',
            style: GoogleFonts.inter(color: _textSec, fontSize: 13)));
    }

    // Parse the cached JSON
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(msg.chartDataJson!) as Map<String, dynamic>;
    } catch (_) {
      return Text('Failed to parse chart data.',
          style: GoogleFonts.inter(color: _textSec, fontSize: 13));
    }

    // Error from server
    if (parsed.containsKey('error')) {
      return Text(parsed['error'] as String,
          style: GoogleFonts.inter(color: const Color(0xFFD04040), fontSize: 13));
    }

    final title = parsed['title'] as String? ?? 'Projected 6-Month Asset Impact';
    final rawData = parsed['data'] as List<dynamic>? ?? [];
    if (rawData.isEmpty) {
      return Text('No chart data returned.',
          style: GoogleFonts.inter(color: _textSec, fontSize: 13));
    }

    // Build typed list and find the max absolute value for axis scaling
    final items = rawData.map((d) {
      final map = d as Map<String, dynamic>;
      return (
        asset:  (map['asset']  as String?)  ?? '?',
        impact: (map['impact'] as num?)?.toDouble() ?? 0.0,
      );
    }).toList();

    final maxAbs = items.fold<double>(
        0.0, (prev, e) => e.impact.abs() > prev ? e.impact.abs() : prev);
    final axisMax = (maxAbs * 1.35).clamp(5.0, 55.0); // headroom + clamp

    // Colours: positive = sky blue, negative = Crail accent
    const positiveColor = Color(0xFF38BDF8);

    // Build BarChartGroupData list
    final groups = items.asMap().entries.map((entry) {
      final i = entry.key;
      final v = entry.value.impact;
      final isPos = v >= 0;
      return BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: v,
            fromY: 0,
            color: isPos ? positiveColor : _accent,
            width: 22,
            borderRadius: BorderRadius.circular(5),
          ),
        ],
        showingTooltipIndicators: [],
      );
    }).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Chart title
      Text(title,
          style: GoogleFonts.inter(
              color: _textSec,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8)),
      const SizedBox(height: 14),

      // Legend row
      Row(children: [
        _legendDot(positiveColor, 'Positive'),
        const SizedBox(width: 14),
        _legendDot(_accent, 'Negative'),
      ]),
      const SizedBox(height: 14),

      // Bar chart
      SizedBox(
        height: 200,
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY:  axisMax,
            minY: -axisMax,
            barGroups: groups,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: axisMax / 2,
              getDrawingHorizontalLine: (_) => FlLine(
                color: _border,
                strokeWidth: 0.5,
              ),
            ),
            borderData: FlBorderData(
              show: true,
              border: Border(
                bottom: BorderSide(color: _border, width: 0.5),
              ),
            ),
            titlesData: FlTitlesData(
              // Asset labels — bottom axis, rotated 45° to prevent overlap
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 72,
                  getTitlesWidget: (value, meta) {
                    final idx = value.toInt();
                    if (idx < 0 || idx >= items.length) return const SizedBox.shrink();
                    final raw   = items[idx].asset;
                    final label = raw.length > 18 ? '${raw.substring(0, 16)}…' : raw;
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Transform.rotate(
                        angle: -0.785,
                        alignment: Alignment.topCenter,
                        child: Text(
                          label,
                          textAlign: TextAlign.right,
                          style: GoogleFonts.inter(
                              color: _textSec,
                              fontSize: 9.5,
                              height: 1.3),
                        )));
                  },
                )),
              // Percentage labels — left axis
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 36,
                  interval: axisMax / 2,
                  getTitlesWidget: (value, meta) => Text(
                    '${value >= 0 ? '+' : ''}${value.toStringAsFixed(0)}%',
                    style: GoogleFonts.inter(
                        color: _textSec, fontSize: 9.5)),
                )),
              // Hide top and right axes
              topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            barTouchData: BarTouchData(
              enabled: true,
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => _card,
                tooltipRoundedRadius: 6,
                tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                getTooltipItem: (group, groupIndex, rod, rodIndex) {
                  final v = rod.toY;
                  return BarTooltipItem(
                    '${items[groupIndex].asset}\n',
                    GoogleFonts.inter(
                        color: _textSec, fontSize: 11, fontWeight: FontWeight.w500),
                    children: [
                      TextSpan(
                        text: '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%',
                        style: GoogleFonts.inter(
                          color: v >= 0 ? positiveColor : _accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        )),
                    ],
                  );
                },
              ),
            ),
          ),
        )),
    ]);
  }

  Widget _legendDot(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8, height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(label,
          style: GoogleFonts.inter(color: _textSec, fontSize: 10.5)),
    ]);


  Widget _buildSubPane({
    required String? text,
    required bool isLoading,
    required String emptyHint,
    required Color textColor,
  }) {
    if (isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          SizedBox(
            width: 13, height: 13,
            child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _tab == _BubbleTab.contagion
                    ? _contagionBlue
                    : _accent)),
          const SizedBox(width: 10),
          Text(
            _tab == _BubbleTab.redTeam
                ? 'Running Devil\'s Advocate…'
                : 'Mapping contagion cascade…',
            style: GoogleFonts.inter(color: _textSec, fontSize: 13)),
        ]));
    }
    if (text == null || text.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(emptyHint,
            style: GoogleFonts.inter(color: _textSec, fontSize: 13)));
    }
    // Fetched — render with matching serif style
    final col = _tab == _BubbleTab.contagion ? _contagionBlue : _accent;
    return MarkdownBody(
        data: _dimCitations(text),
        styleSheet: _mdStyle().copyWith(
          strong: GoogleFonts.newsreader(
              color: col, fontWeight: FontWeight.w700, fontSize: 15.5),
          listBullet:
              GoogleFonts.newsreader(color: col, fontSize: 15.5)));
  }

  // ── Sources block (shared with ChatScreen._sourcesBlock logic) ───────────
  Widget _sourcesBlock(List<AnalysisSource> sources) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(color: _border, height: 1),
      const SizedBox(height: 10),
      Text('Sources',
          style: TextStyle(
              color: _textSec.withOpacity(0.8),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8)),
      const SizedBox(height: 8),
      ...sources.map(_sourceTile),
    ]);
  }

  Widget _sourceTile(AnalysisSource src) {
    final topicCol = _topicColor(src.topic);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Theme(
          data: ThemeData.dark()
              .copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 10),
            dense: true,
            backgroundColor: _card,
            collapsedBackgroundColor: _card,
            iconColor: _accent,
            collapsedIconColor: _textSec,
            leading: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                  color: _accentDim,
                  borderRadius: BorderRadius.circular(5)),
              child: Center(
                  child: Text('[${src.index}]',
                      style: const TextStyle(
                          color: _accent,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)))),
            title: Row(children: [
              if (src.topic.isNotEmpty) ...[
                Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                        color: topicCol,
                        shape: BoxShape.circle)),
                const SizedBox(width: 6),
              ],
              Expanded(
                  child: Text(
                      src.text.length > 50
                          ? '${src.text.substring(0, 50)}…'
                          : src.text,
                      style: const TextStyle(
                          color: _textSec, fontSize: 12))),
            ]),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(src.text,
                    style: GoogleFonts.newsreader(
                        color: _textPri,
                        fontSize: 12.5,
                        height: 1.5,
                        fontStyle: FontStyle.italic))),
            ]))));
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  OCR RESULT WIDGET
// ═══════════════════════════════════════════════════════════════════════════════

class _OcrResultContent extends StatefulWidget {
  final String msgId, extractedText;
  final bool saved;
  final Future<void> Function(String) onSave;
  const _OcrResultContent({required this.msgId, required this.extractedText,
      required this.saved, required this.onSave});
  @override
  State<_OcrResultContent> createState() => _OcrResultContentState();
}

class _OcrResultContentState extends State<_OcrResultContent> {
  late TextEditingController _ctrl;
  bool _expanded = false, _saving = false;
  @override
  void initState() { super.initState(); _ctrl = TextEditingController(text: widget.extractedText); }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (widget.saved) return const Row(children: [
      Icon(Icons.check_circle_rounded, color: _accent, size: 16), SizedBox(width: 8),
      Expanded(child: Text('Saved to Institutional Memory.',
        style: TextStyle(color: _accent, fontSize: 14, fontWeight: FontWeight.w500)))]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.document_scanner_rounded, color: _accent, size: 15),
        const SizedBox(width: 6),
        const Text('Text extracted', style: TextStyle(color: _accent, fontSize: 13, fontWeight: FontWeight.w600)),
        const Spacer(),
        GestureDetector(onTap: () => setState(() => _expanded = !_expanded),
          child: Row(children: [
            Text(_expanded ? 'Hide' : 'Edit', style: const TextStyle(color: _textSec, fontSize: 12)),
            Icon(_expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, color: _textSec, size: 16),
          ])),
      ]),
      const SizedBox(height: 10),
      AnimatedCrossFade(
        duration: const Duration(milliseconds: 220),
        crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        firstChild: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _card, borderRadius: BorderRadius.circular(8)),
          child: Text(widget.extractedText.length > 120 ? '${widget.extractedText.substring(0, 120)}…' : widget.extractedText,
            style: GoogleFonts.newsreader(color: _textSec, fontSize: 13, height: 1.55, fontStyle: FontStyle.italic))),
        secondChild: TextField(controller: _ctrl, maxLines: 6,
          style: const TextStyle(color: _textPri, fontSize: 13),
          decoration: InputDecoration(filled: true, fillColor: _surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: _accent.withOpacity(0.2))),
            contentPadding: const EdgeInsets.all(16)))),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, child: ElevatedButton.icon(
        onPressed: _saving ? null : () async {
          setState(() => _saving = true);
          await widget.onSave(_ctrl.text);
          if (mounted) setState(() => _saving = false);
        },
        style: ElevatedButton.styleFrom(backgroundColor: _accentDim, foregroundColor: _accent,
          disabledBackgroundColor: _accentDim.withOpacity(0.5), elevation: 0,
          side: BorderSide(color: _accent.withOpacity(0.35)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(vertical: 12)),
        icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _accent))
            : const Icon(Icons.save_rounded, size: 16),
        label: Text(_saving ? 'Saving…' : 'Save to Memory',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)))),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MEMORY DASHBOARD SCREEN
// ═══════════════════════════════════════════════════════════════════════════════

class MemoryDashboardScreen extends StatefulWidget {
  const MemoryDashboardScreen({super.key});
  @override
  State<MemoryDashboardScreen> createState() => _MemoryDashboardState();
}

class _MemoryDashboardState extends State<MemoryDashboardScreen>
    with TickerProviderStateMixin {

  // ── Tab ───────────────────────────────────────────────────────────────────
  int _activeTab = 0; // 0=Archive  1=Divergence  2=Stress Test

  // ── Archive state ─────────────────────────────────────────────────────────
  List<MemoryItem> _memories   = [];
  List<String>     _topics     = [];
  bool             _loading    = true;
  String?          _error;
  String           _search     = '';
  String?          _filterTopic;
  bool             _organizing = false;
  final Map<String, bool> _topicExpanded = {};
  final TextEditingController _searchCtrl = TextEditingController();

  List<TrendItem> _trends       = [];
  bool            _trendsLoading = false;

  // ── Divergence state ──────────────────────────────────────────────────────
  DivergenceItem? _divergence;
  bool            _divergenceLoading = false;

  // ── Stress Test state ─────────────────────────────────────────────────────
  final TextEditingController _stressCtrl = TextEditingController();

  // ── Portfolio state ───────────────────────────────────────────────────────
  final TextEditingController _portfolioCtrl = TextEditingController();
  bool   _portfolioLoading = false;
  String? _portfolioResult;
  List<AnalysisSource> _portfolioSources = [];
  static const _mockPortfolio = <String, String>{
    'NVDA': '20%',
    'AAPL': '15%',
    'TLT':  '25%',
    'GLD':  '10%',
    'Cash': '30%',
  };

  // Rich row data for the holdings UI — ticker, full name, weight, bar colour, badge
  static const List<_PortfolioRow> _portfolioRows = [
    _PortfolioRow('NVDA', 'NVIDIA Corp',              '20%', 20, Color(0xFF76B900), 'EQUITIES'),
    _PortfolioRow('AAPL', 'Apple Inc',                '15%', 15, Color(0xFF38BDF8), 'EQUITIES'),
    _PortfolioRow('TLT',  '20+ Yr US Treasuries',     '25%', 25, Color(0xFFA29BFE), 'FIXED INCOME'),
    _PortfolioRow('GLD',  'Gold Trust ETF',           '10%', 10, Color(0xFFFFB347), 'COMMODITIES'),
    _PortfolioRow('Cash', 'T-Bills / MMF',            '30%', 30, Color(0xFF4E6575), 'CASH'),
  ];
  bool   _stressSending    = false;
  String _stressActiveMode = ''; // 'redTeam' | 'contagion' — only while sending
  // Session history: [{mode, event, result, sources, ts}]
  final List<Map<String, dynamic>> _stressTestHistory = [];

  // ── Animation controllers ─────────────────────────────────────────────────
  late final AnimationController _divergenceSpinCtrl;
  late final AnimationController _archiveSpinCtrl;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _divergenceSpinCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800));
    _archiveSpinCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800));
    _loadMemories();
    _loadTopics();
    _loadTrends();
    _loadDivergence();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _stressCtrl.dispose();
    _portfolioCtrl.dispose();
    _divergenceSpinCtrl.dispose();
    _archiveSpinCtrl.dispose();
    super.dispose();
  }

  // ── Archive loaders ───────────────────────────────────────────────────────
  Future<void> _loadMemories() async {
    setState(() { _loading = true; _error = null; });
    _archiveSpinCtrl.repeat();
    try {
      final params = <String, String>{
        'sort': 'topic',
        if (_search.isNotEmpty)   'search': _search,
        if (_filterTopic != null) 'topic':  _filterTopic!,
      };
      final uri = Uri.parse('$_baseUrl/memories').replace(queryParameters: params);
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _memories = (j['memories'] as List? ?? [])
            .map((m) => MemoryItem.fromJson(m as Map<String, dynamic>)).toList());
      } else {
        setState(() => _error = 'Failed to load memories (${res.statusCode})');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Cannot reach backend.');
    } finally {
      _archiveSpinCtrl.stop();
      _archiveSpinCtrl.reset();
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadTopics() async {
    try {
      final res = await http.get(Uri.parse('$_baseUrl/topics'))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _topics = List<String>.from(j['topics'] ?? []));
      }
    } on TimeoutException {
      // Topics are non-critical — silently skip, filters will just be empty
    } on SocketException {
      // Same — non-critical background call
    } catch (_) {}
  }

  Future<void> _loadTrends() async {
    setState(() => _trendsLoading = true);
    try {
      final res = await http.get(Uri.parse('$_baseUrl/trends'))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _trends = (j['trends'] as List? ?? [])
            .map((t) => TrendItem.fromJson(t as Map<String, dynamic>)).toList());
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _trendsLoading = false);
    }
  }

  // ── Divergence loader ─────────────────────────────────────────────────────
  Future<void> _loadDivergence() async {
    setState(() => _divergenceLoading = true);
    _divergenceSpinCtrl.repeat();
    try {
      final res = await http.get(Uri.parse('$_baseUrl/divergences'))
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _divergence = DivergenceItem.fromJson(j));
      }
    } catch (_) {} finally {
      _divergenceSpinCtrl.stop();
      _divergenceSpinCtrl.reset();
      if (mounted) setState(() => _divergenceLoading = false);
    }
  }

  // ── Stress Test runners ───────────────────────────────────────────────────
  Future<void> _runStressTest(String mode) async {
    final event = _stressCtrl.text.trim();
    if (event.isEmpty || _stressSending) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _stressSending    = true;
      _stressActiveMode = mode;
    });
    // Add a pending entry immediately so the loading card appears in the feed
    final entryIndex = _stressTestHistory.length;
    setState(() => _stressTestHistory.add({
      'mode':    mode,
      'event':   event,
      'result':  '',
      'sources': <AnalysisSource>[],
      'ts':      DateTime.now(),
      'loading': true,
    }));

    final endpoint = mode == 'redTeam' ? '/analyze/red_team' : '/analyze/contagion';
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl$endpoint'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'event': event}),
      ).timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final content = (j['content'] as String? ?? '').trim();
        final sources = (j['sources'] as List? ?? [])
            .map((s) => AnalysisSource.fromJson(s as Map<String, dynamic>)).toList();
        setState(() {
          _stressTestHistory[entryIndex]['result']  = content;
          _stressTestHistory[entryIndex]['sources'] = sources;
          _stressTestHistory[entryIndex]['loading'] = false;
        });
      } else {
        setState(() {
          _stressTestHistory[entryIndex]['result']  =
              'Server error (${res.statusCode}). Please retry.';
          _stressTestHistory[entryIndex]['loading'] = false;
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _stressTestHistory[entryIndex]['result'] =
            'Analysis timed out — the LLM is taking too long. Tap to retry.';
        _stressTestHistory[entryIndex]['loading'] = false;
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _stressTestHistory[entryIndex]['result'] =
            'Network disconnected. Check Wi-Fi and that main.py is running.';
        _stressTestHistory[entryIndex]['loading'] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stressTestHistory[entryIndex]['result'] = 'Request failed — check backend is running.';
        _stressTestHistory[entryIndex]['loading'] = false;
      });
    } finally {
      if (mounted) setState(() => _stressSending = false);
    }
  }

  // ── Archive actions ───────────────────────────────────────────────────────
  Future<void> _showTimeline(String topic) async {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TimelineSheet(topic: topic));
  }

  Future<void> _deleteMemory(MemoryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete memory?',
            style: TextStyle(color: _textPri, fontWeight: FontWeight.w600)),
        content: Text('This will permanently remove "${item.title}".',
            style: const TextStyle(color: _textSec, fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: _textSec))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent))),
        ]));
    if (confirmed != true) return;
    try {
      final res = await http.delete(Uri.parse('$_baseUrl/memories/${item.id}'));
      if (!mounted) return;
      if (res.statusCode == 200) {
        _snack('Memory deleted');
        _loadMemories(); _loadTopics();
      } else { _snack('Delete failed'); }
    } catch (_) { _snack('Network error'); }
  }

  Future<void> _saveEdit(MemoryItem item, {
    required String text, required String title,
    required String topic, required String tags, required String summary,
  }) async {
    try {
      final res = await http.put(
        Uri.parse('$_baseUrl/memories/${item.id}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text, 'title': title, 'topic': topic,
            'tags': tags, 'summary': summary}));
      if (!mounted) return;
      if (res.statusCode == 200) {
        _snack('Memory updated', good: true);
        _loadMemories(); _loadTopics();
      } else { _snack('Update failed'); }
    } catch (_) { _snack('Network error'); }
  }

  Future<void> _autoOrganize() async {
    setState(() => _organizing = true);
    try {
      final res = await http.post(Uri.parse('$_baseUrl/memories/auto_organize'))
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final suggestions = (j['suggestions'] as List? ?? [])
            .map((s) => OrganizeSuggestion.fromJson(s as Map<String, dynamic>)).toList();
        if (mounted) _showOrganizationConfirmation(suggestions);
      } else { _snack('Auto-organize failed'); }
    } on TimeoutException {
      if (!mounted) return;
      _snack('Auto-organize timed out — try with fewer memories.');
    } on SocketException {
      if (!mounted) return;
      _snack('Network disconnected — check Wi-Fi.');
    } catch (e) {
      if (!mounted) return;
      _snack('Auto-organize failed — check backend is running.');
    } finally {
      if (mounted) setState(() => _organizing = false);
    }
  }

  Future<void> _applyOrganization(List<OrganizeSuggestion> accepted) async {
    try {
      final res = await http.post(Uri.parse('$_baseUrl/memories/auto_organize/apply'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'assignments': accepted.map((s) => {
          'id': s.id, 'title': s.title, 'topic': s.topic,
          'tags': s.tags, 'summary': s.summary,
        }).toList()}));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        _snack('Applied ${j['applied']} changes', good: true);
        _loadMemories(); _loadTopics();
      } else { _snack('Apply failed'); }
    } catch (_) { _snack('Network error'); }
  }

  void _showOrganizationConfirmation(List<OrganizeSuggestion> suggestions) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _OrganizeConfirmScreen(
        suggestions: suggestions,
        onApply: (accepted) async {
          Navigator.pop(context);
          await _applyOrganization(accepted);
        })));
  }

  // ── Shared helpers ────────────────────────────────────────────────────────
  void _snack(String msg, {bool good = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: TextStyle(
          color: good ? Colors.black : Colors.white, fontWeight: FontWeight.w600)),
      backgroundColor: good ? _accent : Colors.redAccent,
      behavior: SnackBarBehavior.floating));
  }

  // ── Edit sheet ────────────────────────────────────────────────────────────
  void _showEditSheet(MemoryItem item) {
    final titleCtrl   = TextEditingController(text: item.title);
    final textCtrl    = TextEditingController(text: item.text);
    final topicCtrl   = TextEditingController(text: item.topic);
    final tagsCtrl    = TextEditingController(text: item.tags.join(', '));
    final summaryCtrl = TextEditingController(text: item.summary);
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.85, minChildSize: 0.5, maxChildSize: 0.95,
        expand: false,
        builder: (_, sc) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: ListView(controller: sc, children: [
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Row(children: [
              Container(width: 4, height: 20,
                  decoration: BoxDecoration(color: _topicColor(item.topic),
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 10),
              const Text('Edit Memory',
                  style: TextStyle(color: _textPri, fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 20),
            _editField('Title', titleCtrl, hint: 'Short descriptive title'),
            const SizedBox(height: 14),
            _editFieldWithSuggestions('Topic', topicCtrl, _topics),
            const SizedBox(height: 14),
            _editField('Tags', tagsCtrl, hint: 'Comma-separated: fed, rates, inflation'),
            const SizedBox(height: 14),
            _editField('Summary', summaryCtrl, hint: 'One-sentence summary'),
            const SizedBox(height: 14),
            _editField('Content', textCtrl, maxLines: 6, hint: 'Full memory text'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _saveEdit(item,
                    text: textCtrl.text, title: titleCtrl.text,
                    topic: topicCtrl.text, tags: tagsCtrl.text,
                    summary: summaryCtrl.text);
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: _accent, foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: const Text('Save Changes',
                  style: TextStyle(fontWeight: FontWeight.w700))),
          ]))));
  }

  Widget _editField(String label, TextEditingController ctrl,
      {int maxLines = 1, String? hint}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: _textSec, fontSize: 12,
            fontWeight: FontWeight.w600, letterSpacing: 0.5)),
        const SizedBox(height: 6),
        TextField(controller: ctrl, maxLines: maxLines,
            style: const TextStyle(color: _textPri, fontSize: 14),
            decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: _textSec, fontSize: 13),
                filled: true, fillColor: _card,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.all(12))),
      ]);

  Widget _editFieldWithSuggestions(String label,
      TextEditingController ctrl, List<String> suggestions) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: _textSec, fontSize: 12,
            fontWeight: FontWeight.w600, letterSpacing: 0.5)),
        const SizedBox(height: 6),
        TextField(controller: ctrl,
            style: const TextStyle(color: _textPri, fontSize: 14),
            decoration: InputDecoration(
                hintText: 'e.g. Monetary Policy',
                hintStyle: const TextStyle(color: _textSec, fontSize: 13),
                filled: true, fillColor: _card,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.all(12))),
        const SizedBox(height: 8),
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: suggestions.map((t) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: () => ctrl.text = t,
                child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        color: _topicColor(t).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(t, style: TextStyle(
                        color: _topicColor(t), fontSize: 11,
                        fontWeight: FontWeight.w600)))))).toList())),
      ]);

  // ══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: _textPri),
            onPressed: () => Navigator.pop(context)),
        title: RichText(text: TextSpan(children: [
          TextSpan(text: 'Macro', style: GoogleFonts.newsreader(
              color: _textPri, fontSize: 20, fontWeight: FontWeight.w800,
              letterSpacing: 1.0)),
          TextSpan(text: 'Pollo', style: GoogleFonts.newsreader(
              color: _accent, fontSize: 20, fontWeight: FontWeight.w800,
              letterSpacing: 1.0, fontStyle: FontStyle.italic)),
        ])),
        actions: [
          if (_activeTab == 0)
            IconButton(
                onPressed: _organizing ? null : _autoOrganize,
                tooltip: 'Auto-organise with AI',
                icon: _organizing
                    ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _accent))
                    : const Icon(Icons.auto_awesome_rounded,
                    color: _accent, size: 20)),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _border)),
      ),
      body: Column(children: [
        _buildTabBar(),
        Expanded(child: _buildTabBody()),
      ]),
    );
  }

  // ── Tab bar ───────────────────────────────────────────────────────────────
  Widget _buildTabBar() {
    const labels = ['Archive', 'Divergence', 'Stress Test', 'Portfolio'];
    return Container(
      color: _bg,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(labels.length * 2 - 1, (i) {
        // Odd indices are spacers between tabs
        if (i.isOdd) return const SizedBox(width: 24);
        final tabIdx = i ~/ 2;
        final active = _activeTab == tabIdx;
        return GestureDetector(
            onTap: () {
              if (_activeTab == tabIdx) return;
              setState(() => _activeTab = tabIdx);
              if (tabIdx == 1 && _divergence == null && !_divergenceLoading) {
                _loadDivergence();
              }
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(labels[tabIdx],
                style: GoogleFonts.inter(
                  color: active ? _accent : _textSec,
                  fontSize: 14,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  letterSpacing: 0.1,
                )),
              const SizedBox(height: 5),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                height: 2,
                width: active ? _tabLabelWidth(labels[tabIdx]) : 0,
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(1))),
            ]));  // Column.children, Column, GestureDetector
      })));  // callback, List.generate, Row, Container
  }

  double _tabLabelWidth(String label) {
    // Approximate pixel width of the Inter-14 label for the underline
    return label.length * 7.8;
  }

  Widget _buildTabBody() {
    switch (_activeTab) {
      case 0: return _buildArchiveTab();
      case 1: return _buildDivergenceTab();
      case 2: return _buildStressTestTab();
      case 3: return _buildPortfolioTab();
      default: return _buildArchiveTab();
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 0 — ARCHIVE
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildArchiveTab() {
    return Column(children: [
      _buildArchiveControls(),
      Expanded(child: _buildArchiveBody()),
    ]);
  }

  Widget _buildArchiveControls() => Container(
    color: _surface,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(children: [
      Row(children: [
        Expanded(child: Container(
          decoration: BoxDecoration(color: _card,
              borderRadius: BorderRadius.circular(12)),
          child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: _textPri, fontSize: 14),
              onChanged: (v) { _search = v; _loadMemories(); },
              decoration: const InputDecoration(
                  hintText: 'Search memories…',
                  hintStyle: TextStyle(color: _textSec),
                  prefixIcon: Icon(Icons.search_rounded,
                      color: _textSec, size: 18),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12))))),
        const SizedBox(width: 10),
        // Rotating refresh icon
        GestureDetector(
          onTap: _loading ? null : _loadMemories,
          child: RotationTransition(
            turns: _archiveSpinCtrl,
            child: Icon(Icons.refresh_rounded,
                color: _loading ? _accent : _textSec, size: 18))),
      ]),
      const SizedBox(height: 10),
      SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _filterChip('All', _filterTopic == null, () {
              setState(() => _filterTopic = null);
              _loadMemories();
            }),
            ..._topics.map((t) => _filterChip(t, _filterTopic == t, () {
              setState(() =>
              _filterTopic = _filterTopic == t ? null : t);
              _loadMemories();
            })),
          ])),
    ]));

  Widget _filterChip(String label, bool active, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
                color: active ? _accentDim : _card,
                borderRadius: BorderRadius.circular(20)),
            child: Text(label, style: TextStyle(
                color: active ? _accent : _textSec,
                fontSize: 12, fontWeight: FontWeight.w600))));

  Widget _buildArchiveBody() {
    if (_loading) return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: _accent));
    if (_error != null) return Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.error_outline_rounded, color: _textSec, size: 32),
      const SizedBox(height: 12),
      Text(_error!, style: const TextStyle(color: _textSec, fontSize: 14)),
      const SizedBox(height: 16),
      ElevatedButton(onPressed: _loadMemories,
          style: ElevatedButton.styleFrom(
              backgroundColor: _accentDim, foregroundColor: _accent),
          child: const Text('Retry')),
    ]));
    if (_memories.isEmpty) return Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.memory_rounded, color: _textSec, size: 36),
      const SizedBox(height: 12),
      Text(_search.isNotEmpty || _filterTopic != null
          ? 'No memories match your filters.'
          : 'No memories yet.',
          style: const TextStyle(color: _textSec, fontSize: 14)),
    ]));

    return Column(children: [
      _buildMarketHeat(),
      Expanded(child: _buildTopicGroupedList()),
    ]);
  }

  Widget _buildMarketHeat() {
    if (_trendsLoading) return const SizedBox(height: 36,
        child: Center(child: SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: _accent))));
    if (_trends.isEmpty) return const SizedBox.shrink();
    return Container(
      color: _surface,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.local_fire_department_rounded,
              color: _accent, size: 12),
          const SizedBox(width: 5),
          Text('Market Heat', style: GoogleFonts.inter(
              color: _textSec, fontSize: 11,
              fontWeight: FontWeight.w500, letterSpacing: 0.3)),
        ]),
        const SizedBox(height: 8),
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: _trends.map((t) {
              final isHot = t.status == 'hot';
              final col   = isHot ? _accent : const Color(0xFF60A8D8);
              final bgCol = isHot
                  ? const Color(0xFF2A1810)
                  : const Color(0xFF1A2030);
              return GestureDetector(
                onTap: () => _showTimeline(t.topic),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: bgCol,
                      borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                        isHot
                            ? Icons.local_fire_department_rounded
                            : Icons.ac_unit_rounded,
                        color: col, size: 12),
                    const SizedBox(width: 5),
                    Text(t.topic, style: GoogleFonts.inter(
                        color: col, fontSize: 11,
                        fontWeight: FontWeight.w600)),
                    const SizedBox(width: 5),
                    Text(
                        t.velocityScore >= 0
                            ? '+${t.velocityScore.toStringAsFixed(1)}'
                            : t.velocityScore.toStringAsFixed(1),
                        style: TextStyle(
                            color: col.withOpacity(0.7),
                            fontSize: 10, fontWeight: FontWeight.w500)),
                  ])));
            }).toList())),
      ]));
  }

  Widget _buildTopicGroupedList() {
    final grouped = <String, List<MemoryItem>>{};
    for (final m in _memories) {
      (grouped[m.topic] ??= []).add(m);
    }
    const validTopics = [
      'Monetary Policy', 'Geopolitics', 'Commodities', 'Equities',
      'Fixed Income', 'FX & Currency', 'Macro Data', 'Credit Markets',
      'Energy', 'Technology', 'General',
    ];
    final orderedTopics = grouped.keys.toList()
      ..sort((a, b) {
        final ai = validTopics.indexOf(a);
        final bi = validTopics.indexOf(b);
        if (ai == -1 && bi == -1) return a.compareTo(b);
        if (ai == -1) return 1;
        if (bi == -1) return -1;
        return ai.compareTo(bi);
      });

    return ListView(padding: const EdgeInsets.all(16), children: [
          ...orderedTopics.map((topic) {
            final items    = grouped[topic]!;
            final expanded = _topicExpanded[topic] ?? true;
            final topicCol = _topicColor(topic);
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(14)),
              child: Column(children: [
                GestureDetector(
                  onTap: () => setState(
                          () => _topicExpanded[topic] = !expanded),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                        color: topicCol.withOpacity(0.07),
                        borderRadius: BorderRadius.vertical(
                          top: const Radius.circular(14),
                          bottom: expanded
                              ? Radius.zero
                              : const Radius.circular(14))),
                    child: Row(children: [
                      Container(width: 10, height: 10,
                          decoration: BoxDecoration(
                              color: topicCol, shape: BoxShape.circle)),
                      const SizedBox(width: 10),
                      Text(topic, style: TextStyle(
                          color: topicCol, fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3)),
                      const SizedBox(width: 8),
                      Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                              color: topicCol.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(10)),
                          child: Text('${items.length}',
                              style: TextStyle(
                                  color: topicCol, fontSize: 11,
                                  fontWeight: FontWeight.bold))),
                      const Spacer(),
                      Icon(
                          expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: topicCol.withOpacity(0.6), size: 18),
                    ]))),
                if (expanded)
                  ...items.asMap().entries.map((entry) => Column(children: [
                    if (entry.key > 0)
                      Divider(height: 1,
                          color: topicCol.withOpacity(0.1),
                          indent: 16, endIndent: 16),
                    _memoryCard(entry.value, inGroup: true),
                  ])),
              ]));
          }),
        ]);
  }

  Widget _memoryCard(MemoryItem item, {bool inGroup = false}) {
    final topicCol = _topicColor(item.topic);
    return Container(
      margin: inGroup ? EdgeInsets.zero : const EdgeInsets.only(bottom: 10),
      decoration: inGroup
          ? null
          : BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(inGroup ? 16 : 12, 12, 12, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!inGroup)
            Container(width: 3, height: 44,
                margin: const EdgeInsets.only(right: 10, top: 2),
                decoration: BoxDecoration(color: topicCol,
                    borderRadius: BorderRadius.circular(2))),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title.isNotEmpty
                ? item.title
                : item.text.substring(0, item.text.length.clamp(0, 50)),
                style: const TextStyle(color: _textPri, fontSize: 14,
                    fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (item.summary.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(item.summary,
                  style: const TextStyle(color: _textSec, fontSize: 12,
                      height: 1.4),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 8),
            Row(children: [
              ...item.tags.take(3).map((tag) => Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(10)),
                  child: Text('#${tag}',
                      style: const TextStyle(
                          color: _textSec, fontSize: 10)))),
              const Spacer(),
              Text(_formatDate(item.createdAt),
                  style: const TextStyle(color: _textSec, fontSize: 10)),
            ]),
          ])),
          Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.edit_rounded,
                    size: 16, color: _textSec),
                onPressed: () => _showEditSheet(item)),
            IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.delete_outline_rounded,
                    size: 16, color: _textSec),
                onPressed: () => _deleteMemory(item)),
          ]),
        ])));
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day}/${dt.month}/${dt.year.toString().substring(2)}';
    } catch (_) { return ''; }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 1 — DIVERGENCE
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildDivergenceTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 48),
      child: _divergenceLoading
          ? _buildDivergenceLoading()
          : _buildDivergenceContent(),
    );
  }

  Widget _buildDivergenceLoading() => Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      const SizedBox(width: 14, height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: _accent)),
      const SizedBox(width: 12),
      Text('Scanning cross-asset signals…',
          style: GoogleFonts.inter(color: _textSec, fontSize: 13)),
    ]),
    const SizedBox(height: 32),
    Container(height: 28,
        decoration: BoxDecoration(color: _surface,
            borderRadius: BorderRadius.circular(4))),
    const SizedBox(height: 12),
    Container(height: 16, width: 200,
        decoration: BoxDecoration(color: _surface,
            borderRadius: BorderRadius.circular(4))),
  ]);

  Widget _buildDivergenceContent() {
    final d = _divergence;
    final hasAlert = d != null && d.hasAlert;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Label row
      Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: hasAlert ? _accent.withOpacity(0.12) : _surface,
            borderRadius: BorderRadius.circular(5)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.compare_arrows_rounded,
                color: hasAlert ? _accent : _textSec, size: 11),
            const SizedBox(width: 5),
            Text('CROSS-ASSET DIVERGENCE', style: GoogleFonts.inter(
                color: hasAlert ? _accent : _textSec,
                fontSize: 9.5, fontWeight: FontWeight.w700,
                letterSpacing: 0.9)),
          ])),
        const Spacer(),
        GestureDetector(
          onTap: _divergenceLoading ? null : _loadDivergence,
          child: RotationTransition(
            turns: _divergenceSpinCtrl,
            child: Icon(Icons.refresh_rounded, color: _textSec, size: 16))),
      ]),

      const SizedBox(height: 24),

      if (!hasAlert) ...[
        // Aligned state — soft and minimal
        const Icon(Icons.check_circle_outline_rounded,
            color: _textSec, size: 28),
        const SizedBox(height: 14),
        Text('Markets are currently aligned.',
            style: GoogleFonts.newsreader(
                color: _textPri, fontSize: 22,
                fontWeight: FontWeight.w700, height: 1.25)),
        const SizedBox(height: 12),
        Text(d?.description ?? 'No major divergences detected in recent memory.',
            style: GoogleFonts.newsreader(
                color: _textSec, fontSize: 15.5, height: 1.65)),
      ] else ...[
        // Divergence detected
        Text(d!.headline, style: GoogleFonts.newsreader(
            color: _textPri, fontSize: 24,
            fontWeight: FontWeight.w700, height: 1.2)),
        const SizedBox(height: 6),
        Container(width: 40, height: 2,
            decoration: BoxDecoration(
                color: _accent, borderRadius: BorderRadius.circular(1))),
        const SizedBox(height: 20),
        Text(d.description, style: GoogleFonts.newsreader(
            color: _textPri, fontSize: 15.5, height: 1.65)),
        const SizedBox(height: 28),
        // CTA to stress-test this divergence — full width
        SizedBox(
          width: double.infinity,
          child: GestureDetector(
            onTap: () {
              _stressCtrl.text = d.headline;
              setState(() => _activeTab = 2);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                  color: _accentDim,
                  borderRadius: BorderRadius.circular(10)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                const Icon(Icons.science_rounded,
                    color: _accent, size: 14),
                const SizedBox(width: 8),
                Text('Stress-test this divergence',
                    style: GoogleFonts.inter(
                        color: _accent, fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ])))),
      ],
    ]);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 2 — STRESS TEST
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildStressTestTab() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── Fixed input area ─────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('STRESS TEST', style: GoogleFonts.inter(
              color: _textSec, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 1.1)),
          const SizedBox(height: 14),

          // Input field — clearly an editable field
          Container(
            decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _border)),
            child: TextField(
              controller: _stressCtrl,
              style: GoogleFonts.inter(color: _textPri, fontSize: 14),
              maxLines: null,
              decoration: InputDecoration(
                  hintText: 'Enter a thesis or event to stress-test…',
                  hintStyle: GoogleFonts.inter(color: _textSec, fontSize: 14),
                  prefixIcon: const Icon(Icons.edit_note_rounded,
                      color: _textSec, size: 20),
                  suffixIcon: ListenableBuilder(
                    listenable: _stressCtrl,
                    builder: (_, __) => _stressCtrl.text.isEmpty
                        ? const SizedBox.shrink()
                        : GestureDetector(
                            onTap: () =>
                                setState(() => _stressCtrl.clear()),
                            child: const Icon(Icons.cancel_rounded,
                                color: _textSec, size: 16)),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14)))),

          const SizedBox(height: 12),

          // Action buttons
          Row(children: [
            _stressButton(label: 'Red Team',
                icon: Icons.gavel_rounded,
                mode: 'redTeam', activeColor: _accent),
            const SizedBox(width: 10),
            _stressButton(label: 'Simulate Contagion',
                icon: Icons.waves_rounded,
                mode: 'contagion',
                activeColor: const Color(0xFF4A8EC2)),
          ]),
          const SizedBox(height: 16),
        ])),

      // Thin divider between input and history
      Container(height: 1, color: _border),

      // ── Scrollable history feed ───────────────────────────────────────────
      Expanded(child: _buildStressHistory()),
    ]);
  }

  Widget _buildStressHistory() {
    if (_stressTestHistory.isEmpty) {
      return Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.science_outlined, color: _textSec, size: 36),
        const SizedBox(height: 12),
        Text('No analyses yet.',
            style: GoogleFonts.inter(color: _textSec, fontSize: 14)),
        const SizedBox(height: 4),
        Text('Enter a thesis above and run Red Team or Contagion.',
            style: GoogleFonts.inter(color: _textSec, fontSize: 12),
            textAlign: TextAlign.center),
      ]));
    }

    // Show history newest-first
    final reversed = _stressTestHistory.reversed.toList();

    return Column(children: [
      // Clear history row
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
        child: Row(children: [
          Text('${_stressTestHistory.length} '
              '${_stressTestHistory.length == 1 ? 'analysis' : 'analyses'}',
              style: GoogleFonts.inter(
                  color: _textSec, fontSize: 12)),
          const Spacer(),
          GestureDetector(
            onTap: () => setState(() => _stressTestHistory.clear()),
            child: Text('Clear history',
                style: GoogleFonts.inter(
                    color: _textSec, fontSize: 12,
                    decoration: TextDecoration.underline,
                    decorationColor: _textSec))),
        ])),

      Expanded(child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
        itemCount: reversed.length,
        itemBuilder: (_, i) => _stressHistoryCard(reversed[i]),
      )),
    ]);
  }

  Widget _stressHistoryCard(Map<String, dynamic> entry) {
    final mode     = entry['mode'] as String;
    final event    = entry['event'] as String;
    final result   = entry['result'] as String;
    final sources  = entry['sources'] as List<AnalysisSource>;
    final loading  = entry['loading'] as bool? ?? false;
    final ts       = entry['ts'] as DateTime;

    final modeColor = mode == 'redTeam' ? _accent : const Color(0xFF4A8EC2);
    final modeLabel = mode == 'redTeam' ? 'Red Team' : 'Ripple Effect';
    final modeIcon  = mode == 'redTeam'
        ? Icons.gavel_rounded : Icons.waves_rounded;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Card header: badge + event + time
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
                color: modeColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(5)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(modeIcon, color: modeColor, size: 10),
              const SizedBox(width: 4),
              Text(modeLabel.toUpperCase(), style: GoogleFonts.inter(
                  color: modeColor, fontSize: 9,
                  fontWeight: FontWeight.w700, letterSpacing: 0.7)),
            ])),
          const SizedBox(width: 8),
          Expanded(child: Text(event, style: GoogleFonts.inter(
              color: _textPri, fontSize: 12.5,
              fontWeight: FontWeight.w600),
              maxLines: 2, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Text('${ts.hour.toString().padLeft(2,'0')}:${ts.minute.toString().padLeft(2,'0')}',
              style: GoogleFonts.inter(
                  color: _textSec, fontSize: 10)),
        ]),

        const SizedBox(height: 14),

        // Body: loading skeleton or result
        if (loading)
          Row(children: [
            SizedBox(width: 12, height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: modeColor)),
            const SizedBox(width: 10),
            Text(mode == 'redTeam'
                ? 'Running Red Team analysis…'
                : 'Mapping contagion cascade…',
                style: GoogleFonts.inter(
                    color: _textSec, fontSize: 12)),
          ])
        else ...[
          MarkdownBody(
            data: result,
            styleSheet: MarkdownStyleSheet(
              p:      GoogleFonts.newsreader(color: _textPri,
                  fontSize: 15.5, height: 1.65),
              strong: GoogleFonts.newsreader(color: _textPri,
                  fontSize: 15.5, fontWeight: FontWeight.w700),
              em:     GoogleFonts.newsreader(color: _textPri,
                  fontSize: 15.5,
                  fontStyle: FontStyle.italic, height: 1.65),
              listBullet: GoogleFonts.newsreader(
                  color: _textSec, fontSize: 15.5),
              h2: GoogleFonts.newsreader(color: _textPri,
                  fontSize: 17, fontWeight: FontWeight.w700, height: 1.3),
              h3: GoogleFonts.newsreader(color: _textPri,
                  fontSize: 15.5, fontWeight: FontWeight.w600),
            )),
          if (sources.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(height: 1, color: _border),
            const SizedBox(height: 10),
            Text('Sources', style: GoogleFonts.inter(
                color: _textSec.withOpacity(0.8), fontSize: 11,
                fontWeight: FontWeight.w600, letterSpacing: 0.8)),
            const SizedBox(height: 8),
            ...sources.map(_stressSourceTile),
          ],
        ],
      ]));
  }

  Widget _stressButton({
    required String label,
    required IconData icon,
    required String mode,
    required Color activeColor,
  }) {
    final isActive = _stressSending && _stressActiveMode == mode;
    return Expanded(child: GestureDetector(
      onTap: _stressSending ? null : () => _runStressTest(mode),
      child: Opacity(
        opacity: (_stressSending && _stressActiveMode != mode) ? 0.35 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
              color: activeColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            isActive
                ? SizedBox(width: 13, height: 13,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: activeColor))
                : Icon(icon, color: activeColor, size: 14),
            const SizedBox(width: 7),
            Text(label, style: GoogleFonts.inter(
                color: activeColor, fontSize: 13,
                fontWeight: FontWeight.w600)),
          ])))));
  }

  Widget _stressSourceTile(AnalysisSource src) {
    final topicCol = _topicColor(src.topic);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Theme(
          data: ThemeData.dark().copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 10),
            dense: true,
            backgroundColor: _card,
            collapsedBackgroundColor: _card,
            iconColor: _accent,
            collapsedIconColor: _textSec,
            leading: Container(width: 22, height: 22,
                decoration: BoxDecoration(
                    color: _accentDim,
                    borderRadius: BorderRadius.circular(5)),
                child: Center(child: Text('[${src.index}]',
                    style: const TextStyle(color: _accent,
                        fontSize: 10, fontWeight: FontWeight.bold)))),
            title: Row(children: [
              if (src.topic.isNotEmpty) ...[
                Container(width: 6, height: 6,
                    decoration: BoxDecoration(
                        color: topicCol, shape: BoxShape.circle)),
                const SizedBox(width: 6),
              ],
              Expanded(child: Text(
                  src.text.length > 50
                      ? '${src.text.substring(0, 50)}…'
                      : src.text,
                  style: const TextStyle(color: _textSec, fontSize: 12))),
            ]),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(src.text,
                    style: GoogleFonts.newsreader(
                        color: _textPri, fontSize: 12.5,
                        height: 1.5, fontStyle: FontStyle.italic))),
            ]))));
  }
  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 3 — PORTFOLIO VULNERABILITY SCANNER
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _runPortfolioScan() async {
    final event = _portfolioCtrl.text.trim();
    if (event.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _portfolioLoading = true;
      _portfolioResult  = null;
      _portfolioSources = [];
    });
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/analyze/portfolio'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'event': event, 'portfolio': _mockPortfolio}),
      ).timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        if ((j['status'] as String?) == 'success') {
          setState(() {
            _portfolioResult  = j['content'] as String? ?? '';
            _portfolioSources = (j['sources'] as List? ?? [])
                .map((s) => AnalysisSource.fromJson(s as Map<String, dynamic>))
                .toList();
          });
        } else {
          setState(() => _portfolioResult = j['message'] ?? 'Analysis failed.');
        }
      } else {
        setState(() => _portfolioResult = 'Server error (${res.statusCode}).');
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _portfolioResult =
          'Analysis timed out — the model is taking too long. Tap Run to retry.');
    } on SocketException {
      if (!mounted) return;
      setState(() => _portfolioResult =
          'Network disconnected. Check Wi-Fi and that main.py is running.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _portfolioResult =
          'Request failed — check backend is running.');
    } finally {
      if (mounted) setState(() => _portfolioLoading = false);
    }
  }

  Widget _buildPortfolioTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Section label ───────────────────────────────────────────────────
        Text('PORTFOLIO', style: GoogleFonts.inter(
            color: _textSec, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 1.1)),
        const SizedBox(height: 14),

        // ── Holdings list ───────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border)),
          child: Column(
            children: _portfolioRows.asMap().entries.map((entry) {
              final isLast = entry.key == _portfolioRows.length - 1;
              final row    = entry.value;
              final barW   = (row.pct / 100).clamp(0.0, 1.0);
              return Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 13, 18, 13),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Ticker + full name
                      SizedBox(width: 110, child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(row.ticker, style: GoogleFonts.inter(
                              color: _textPri, fontSize: 14,
                              fontWeight: FontWeight.w700)),
                          const SizedBox(height: 1),
                          Text(row.name, style: GoogleFonts.inter(
                              color: _textSec, fontSize: 10)),
                        ])),
                      // Progress bar
                      Expanded(child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Stack(children: [
                          Container(height: 5, color: _card),
                          FractionallySizedBox(
                            widthFactor: barW,
                            child: Container(
                                height: 5,
                                decoration: BoxDecoration(
                                    color: row.barColor,
                                    borderRadius: BorderRadius.circular(3)))),
                        ]))),
                      const SizedBox(width: 14),
                      // Weight + asset-class badge
                      Column(crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(row.weight, style: GoogleFonts.inter(
                              color: _textPri, fontSize: 13,
                              fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: row.barColor.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: row.barColor.withOpacity(0.3),
                                    width: 0.6)),
                            child: Text(row.assetClass, style: GoogleFonts.inter(
                                color: row.barColor, fontSize: 9,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4))),
                        ]),
                    ])),
                if (!isLast)
                  Divider(height: 1, color: _border, indent: 18, endIndent: 18),
              ]);
            }).toList())),

        const SizedBox(height: 24),

        // ── Section label ───────────────────────────────────────────────────
        Text('MACRO SHOCK', style: GoogleFonts.inter(
            color: _textSec, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 1.1)),
        const SizedBox(height: 10),

        // ── Input field ─────────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border)),
          child: TextField(
            controller: _portfolioCtrl,
            style: GoogleFonts.inter(color: _textPri, fontSize: 14),
            maxLines: null,
            decoration: InputDecoration(
                hintText: 'e.g., Taiwan semiconductor fabs face indefinite shutdown…',
                hintStyle: GoogleFonts.inter(color: _textSec, fontSize: 14),
                prefixIcon: const Icon(Icons.crisis_alert_rounded,
                    color: _textSec, size: 20),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14)))),

        const SizedBox(height: 16),

        // ── Run button ──────────────────────────────────────────────────────
        ListenableBuilder(
          listenable: _portfolioCtrl,
          builder: (_, __) {
            final canRun = _portfolioCtrl.text.trim().isNotEmpty
                && !_portfolioLoading;
            return SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canRun ? _runPortfolioScan : null,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _accent.withOpacity(0.3),
                    disabledForegroundColor: Colors.white.withOpacity(0.4),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))),
                child: _portfolioLoading
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text('Run Vulnerability Scan',
                        style: GoogleFonts.inter(
                            fontSize: 14, fontWeight: FontWeight.w700)),
              ));
          }),

        // ── Result ──────────────────────────────────────────────────────────
        if (_portfolioResult != null) ...[
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _border)),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(
                      color: _accent, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text('RISK ASSESSMENT', style: GoogleFonts.inter(
                    color: _accent, fontSize: 10,
                    fontWeight: FontWeight.w700, letterSpacing: 1.0)),
              ]),
              const SizedBox(height: 14),
              MarkdownBody(
                data: _portfolioResult!,
                styleSheet: MarkdownStyleSheet(
                  p: GoogleFonts.newsreader(
                      color: _textPri, fontSize: 15, height: 1.65),
                  strong: GoogleFonts.newsreader(
                      color: _accent,
                      fontWeight: FontWeight.w700, fontSize: 15),
                  listBullet: GoogleFonts.newsreader(
                      color: _accent, fontSize: 15),
                  listIndent: 18,
                  blockSpacing: 10,
                ),
              ),
              // Sources
              if (_portfolioSources.isNotEmpty) ...[
                const SizedBox(height: 14),
                Divider(color: _border, height: 1),
                const SizedBox(height: 10),
                Text('Sources', style: GoogleFonts.inter(
                    color: _textSec.withOpacity(0.8), fontSize: 11,
                    fontWeight: FontWeight.w600, letterSpacing: 0.8)),
                const SizedBox(height: 8),
                ..._portfolioSources.map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 20, height: 20,
                        decoration: BoxDecoration(
                            color: _accentDim,
                            borderRadius: BorderRadius.circular(4)),
                        child: Center(child: Text('[${s.index}]',
                            style: const TextStyle(color: _accent,
                                fontSize: 9, fontWeight: FontWeight.bold)))),
                      const SizedBox(width: 8),
                      Expanded(child: Text(
                          s.text.length > 80
                              ? '${s.text.substring(0, 80)}…'
                              : s.text,
                          style: GoogleFonts.inter(
                              color: _textSec, fontSize: 12,
                              height: 1.4))),
                    ]))),
              ],
            ])),
        ],
      ]));
  }


}

// ═══════════════════════════════════════════════════════════════════════════════
//  TOPIC TIMELINE SHEET
// ═══════════════════════════════════════════════════════════════════════════════

class _TimelineSheet extends StatefulWidget {
  final String topic;
  const _TimelineSheet({required this.topic});
  @override
  State<_TimelineSheet> createState() => _TimelineSheetState();
}

class _TimelineSheetState extends State<_TimelineSheet> {
  String? _narrative;
  String? _error;
  bool _loading = true;
  String _spanStart = '';
  String _spanEnd = '';
  int _entryCount = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() { _loading = true; _error = null; });
    try {
      final encoded = Uri.encodeComponent(widget.topic);
      final res = await http
          .get(Uri.parse('$_baseUrl/topics/$encoded/timeline'))
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['status'] == 'success') {
        setState(() {
          _narrative   = j['narrative']    as String? ?? '';
          _spanStart   = j['span_start']   as String? ?? '';
          _spanEnd     = j['span_end']     as String? ?? '';
          _entryCount  = (j['entry_count'] as num?)?.toInt() ?? 0;
        });
      } else {
        setState(() => _error = j['message'] as String? ?? 'Unknown error');
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _error = 'LLM timed out generating the narrative. Tap to retry.');
    } on SocketException {
      if (!mounted) return;
      setState(() => _error = 'Network disconnected. Check Wi-Fi and that main.py is running.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach backend — check main.py is running.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topicCol = _topicColor(widget.topic);
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.85,
      expand: false,
      builder: (_, ctrl) => Container(
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          border: Border(top: BorderSide(color: _border, width: 0.5))),
        child: ListView(controller: ctrl, padding: const EdgeInsets.fromLTRB(28, 16, 28, 40),
          children: [
            // Handle
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),

            // Header
            Row(children: [
              Container(width: 10, height: 10,
                  decoration: BoxDecoration(color: topicCol, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.topic, style: GoogleFonts.inter(
                  color: topicCol, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.2))),
              const Icon(Icons.timeline_rounded, color: _textSec, size: 16),
            ]),
            const SizedBox(height: 4),

            // Span meta
            if (_spanStart.isNotEmpty)
              Text('$_entryCount entries  ·  $_spanStart → $_spanEnd',
                  style: const TextStyle(color: _textSec, fontSize: 11)),
            const SizedBox(height: 16),
            Divider(color: topicCol.withOpacity(0.15)),
            const SizedBox(height: 16),

            // Body
            if (_loading)
              Column(children: [
                const SizedBox(height: 20),
                const CircularProgressIndicator(strokeWidth: 2, color: _accent),
                const SizedBox(height: 16),
                const Text('Generating narrative…',
                    style: TextStyle(color: _textSec, fontSize: 13)),
              ])
            else if (_error != null)
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: const [
                  Icon(Icons.error_outline_rounded, color: const Color(0xFFC04828), size: 16),
                  SizedBox(width: 8),
                  Text('Failed to generate', style: TextStyle(
                      color: const Color(0xFFC04828), fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: _textSec, fontSize: 13)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _fetch,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _accentDim, foregroundColor: _accent),
                  icon: const Icon(Icons.refresh_rounded, size: 14),
                  label: const Text('Retry')),
              ])
            else if (_narrative != null)
              Text(_narrative!, style: GoogleFonts.newsreader(
                  color: _textPri, fontSize: 15.5, height: 1.70)),
          ])));
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  AUTO-ORGANIZE CONFIRMATION SCREEN
// ═══════════════════════════════════════════════════════════════════════════════

class _OrganizeConfirmScreen extends StatefulWidget {
  final List<OrganizeSuggestion> suggestions;
  final Future<void> Function(List<OrganizeSuggestion>) onApply;
  const _OrganizeConfirmScreen({required this.suggestions, required this.onApply});
  @override
  State<_OrganizeConfirmScreen> createState() => _OrganizeConfirmScreenState();
}

class _OrganizeConfirmScreenState extends State<_OrganizeConfirmScreen> {
  late List<OrganizeSuggestion> _suggestions;
  bool _applying = false;

  @override
  void initState() { super.initState(); _suggestions = widget.suggestions; }

  int get _acceptedCount => _suggestions.where((s) => s.accepted).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.close_rounded, color: _textPri),
          onPressed: () => Navigator.pop(context)),
        title: Text('AI Suggestions', style: GoogleFonts.newsreader(color: _textPri, fontSize: 16, fontWeight: FontWeight.w600)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _border)),
      ),
      body: Column(children: [
        // Info banner
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _accentDim, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _accent.withOpacity(0.3))),
          child: Row(children: [
            const Icon(Icons.auto_awesome_rounded, color: _accent, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'AI has analysed ${_suggestions.length} memories. Review and toggle suggestions before applying.',
              style: const TextStyle(color: _accent, fontSize: 13, height: 1.4))),
          ])),
        // Toggle all
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text('$_acceptedCount / ${_suggestions.length} selected',
              style: const TextStyle(color: _textSec, fontSize: 13)),
            const Spacer(),
            TextButton(onPressed: () => setState(() { for (final s in _suggestions) s.accepted = true; }),
              child: const Text('Select all', style: TextStyle(color: _accent, fontSize: 12))),
            TextButton(onPressed: () => setState(() { for (final s in _suggestions) s.accepted = false; }),
              child: const Text('None', style: TextStyle(color: _textSec, fontSize: 12))),
          ])),
        // Suggestion list
        Expanded(child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: _suggestions.length,
          itemBuilder: (_, i) {
            final s = _suggestions[i];
            final topicCol = _topicColor(s.topic);
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: s.accepted ? _surface : _card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: s.accepted ? topicCol.withOpacity(0.3) : _border)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Checkbox
                  GestureDetector(
                    onTap: () => setState(() => s.accepted = !s.accepted),
                    child: Container(width: 22, height: 22,
                      decoration: BoxDecoration(
                        color: s.accepted ? _accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: s.accepted ? _accent : _textSec)),
                      child: s.accepted ? const Icon(Icons.check_rounded, size: 14, color: Colors.black) : null)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.title, style: TextStyle(color: s.accepted ? _textPri : _textSec,
                      fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: topicCol.withOpacity(0.12), borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: topicCol.withOpacity(0.3))),
                        child: Text(s.topic, style: TextStyle(color: topicCol, fontSize: 11, fontWeight: FontWeight.w600))),
                      const SizedBox(width: 6),
                      ...s.tags.take(3).map((tag) => Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _border)),
                        child: Text('#$tag', style: const TextStyle(color: _textSec, fontSize: 10)))),
                    ]),
                    if (s.summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(s.summary, style: const TextStyle(color: _textSec, fontSize: 12, height: 1.4),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ])),
                ])));
          })),
        // Apply button
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: _border))),
          child: SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: (_acceptedCount == 0 || _applying) ? null : () async {
              setState(() => _applying = true);
              await widget.onApply(_suggestions.where((s) => s.accepted).toList());
              if (mounted) setState(() => _applying = false);
            },
            style: ElevatedButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white,
              disabledBackgroundColor: _accent.withOpacity(0.3),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _applying
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
              : Text('Apply $_acceptedCount changes', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))))),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  RISK BADGE
// ═══════════════════════════════════════════════════════════════════════════════

class _RiskBadge extends StatelessWidget {
  final int score;   // 0 = unscored
  const _RiskBadge({required this.score});

  @override
  Widget build(BuildContext context) {
    final col   = _riskColor(score);
    final label = score == 0 ? '…' : '$score';
    final tip   = score == 0 ? 'Scoring…'
                : score <= 3 ? 'Low risk'
                : score <= 6 ? 'Medium risk'
                : score <= 8 ? 'High risk'
                : 'Critical risk';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.72),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: col.withOpacity(0.7), width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        // Colour dot
        Container(width: 6, height: 6,
          decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        // Numeric score
        Text(label, style: TextStyle(
          color: col, fontSize: 11, fontWeight: FontWeight.w800,
          letterSpacing: 0.2)),
        const SizedBox(width: 3),
        // Text label
        Text(tip, style: TextStyle(
          color: col.withOpacity(0.85), fontSize: 9,
          fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  PULSING DOT
// ═══════════════════════════════════════════════════════════════════════════════

class _PulsingDot extends StatefulWidget {
  final Duration delay;
  final Color color;
  const _PulsingDot({required this.delay, required this.color});
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _anim = Tween(begin: 0.3, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    Future.delayed(widget.delay, () { if (mounted) _ctrl.repeat(reverse: true); });
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: FadeTransition(opacity: _anim,
      child: Container(width: 7, height: 7, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle))));
}
