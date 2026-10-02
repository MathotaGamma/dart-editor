// v4からの差分:
// - 仮想デバイスの幅・高さを指定できるように変更
// - 全画面表示のAppBarに「サイズ指定」ボタン(プリセット選択+数値入力)と「縦横入れ替え」ボタンを追加
// - 指定したサイズはアプリに保存され、下部パネルの仮想デバイスにも反映される

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dart_eval/dart_eval.dart' show Compiler, eval;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/flutter_eval.dart' show CompilerWidget, flutterEvalPlugin;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const DartEditorApp());
}

const String _sampleCode = r'''// Dart Editor へようこそ
// 右上の ▶ ボタンで実行できます

class Counter {
  int value = 0;

  void increment() {
    value++;
  }
}

void main() {
  final names = ['Dart', 'Flutter'];
  for (final name in names) {
    print('Hello, $name!');
  }

  final c = Counter();
  c.increment();
  c.increment();
  print('count = ${c.value}');

  var sum = 0;
  for (var i = 1; i <= 10; i++) {
    sum += i;
  }
  print('1から10の合計 = $sum');
}
''';

/// ソースを実行し、コンソール出力を文字列で返す(compute用のトップレベル関数)
String _evalEntry(String source) {
  final out = StringBuffer();
  try {
    runZoned(
      () {
        final result = eval(source, function: 'main');
        if (result != null) {
          out.writeln('=> $result');
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          out.writeln(line);
        },
      ),
    );
  } catch (e) {
    var msg = e.toString();
    if (msg.length > 1000) {
      msg = '${msg.substring(0, 1000)}...';
    }
    out.writeln('エラー: $msg');
  }
  return out.toString();
}

const String _flutterSample = r'''import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const CounterPage(),
    );
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({Key? key}) : super(key: key);

  @override
  State<CounterPage> createState() => CounterPageState();
}

class CounterPageState extends State<CounterPage> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('カウンター')),
      body: Center(
        child: Text('$count', style: const TextStyle(fontSize: 48)),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            count++;
          });
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
''';

/// runApp(...) を含むコードを、プレビュー用に変換する。
/// runApp の引数を取り出して devicePreviewRoot() として定義し直し、
/// 元の runApp 呼び出しは null に置き換える。runApp がなければ null を返す。
String? _wrapForPreview(String src) {
  final m = RegExp(r'\brunApp\s*\(').firstMatch(src);
  if (m == null) return null;

  var depth = 1;
  var i = m.end;
  String? quote;
  while (i < src.length && depth > 0) {
    final ch = src[i];
    if (quote != null) {
      if (ch == '\\') {
        i += 2;
        continue;
      }
      if (ch == quote) quote = null;
    } else if (ch == "'" || ch == '"') {
      quote = ch;
    } else if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
    }
    i++;
  }
  if (depth != 0) return null;

  final expr = src.substring(m.end, i - 1).trim();
  if (expr.isEmpty) return null;

  final replaced = src.replaceRange(m.start, i, 'null');
  return '$replaced\n\nWidget devicePreviewRoot() {\n  return $expr;\n}\n';
}

/// スマホ型のフレームの中にFlutterコードの実行結果を表示する
class _DeviceFrame extends StatelessWidget {
  const _DeviceFrame({
    super.key,
    required this.source,
    this.width = 360,
    this.height = 760,
  });

  final String source;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: width / height,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.grey.shade700, width: 2),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: width,
                height: height,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: Size(width, height),
                    padding: EdgeInsets.zero,
                    viewInsets: EdgeInsets.zero,
                    viewPadding: EdgeInsets.zero,
                  ),
                  child: CompilerWidget(
                    packages: {
                      'preview': {'main.dart': source},
                    },
                    library: 'package:preview/main.dart',
                    function: 'devicePreviewRoot',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 仮想デバイスのサイズ プリセット
class _Preset {
  const _Preset(this.name, this.w, this.h);

  final String name;
  final double w;
  final double h;
}

const List<_Preset> _presets = [
  _Preset('標準スマホ', 360, 760),
  _Preset('iPhone SE', 375, 667),
  _Preset('iPhone 15', 393, 852),
  _Preset('Pixel', 412, 915),
  _Preset('小型タブレット', 600, 960),
  _Preset('iPad', 820, 1180),
];

/// 仮想デバイスの全画面表示
class _DevicePage extends StatefulWidget {
  const _DevicePage({
    required this.source,
    required this.width,
    required this.height,
    required this.onSizeChanged,
  });

  final String source;
  final double width;
  final double height;
  final void Function(double w, double h) onSizeChanged;

  @override
  State<_DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<_DevicePage> {
  late double _w = widget.width;
  late double _h = widget.height;

  void _apply(double w, double h) {
    setState(() {
      _w = w;
      _h = h;
    });
    widget.onSizeChanged(w, h);
  }

  Future<void> _edit() async {
    final r = await showDialog<Size>(
      context: context,
      builder: (_) => _SizeDialog(width: _w, height: _h),
    );
    if (r != null) _apply(r.width, r.height);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('仮想デバイス  ${_w.round()} × ${_h.round()}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.screen_rotation),
            tooltip: '縦横を入れ替え',
            onPressed: () => _apply(_h, _w),
          ),
          IconButton(
            icon: const Icon(Icons.aspect_ratio),
            tooltip: 'サイズを指定',
            onPressed: _edit,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _DeviceFrame(
          source: widget.source,
          width: _w,
          height: _h,
        ),
      ),
    );
  }
}

/// サイズ指定ダイアログ(プリセット + 数値入力)
class _SizeDialog extends StatefulWidget {
  const _SizeDialog({required this.width, required this.height});

  final double width;
  final double height;

  @override
  State<_SizeDialog> createState() => _SizeDialogState();
}

class _SizeDialogState extends State<_SizeDialog> {
  late final TextEditingController _wc =
      TextEditingController(text: widget.width.round().toString());
  late final TextEditingController _hc =
      TextEditingController(text: widget.height.round().toString());

  @override
  void dispose() {
    _wc.dispose();
    _hc.dispose();
    super.dispose();
  }

  void _usePreset(_Preset p) {
    setState(() {
      _wc.text = p.w.round().toString();
      _hc.text = p.h.round().toString();
    });
  }

  void _ok() {
    final w = double.tryParse(_wc.text.trim());
    final h = double.tryParse(_hc.text.trim());
    if (w == null || h == null) return;
    Navigator.pop(
      context,
      Size(
        w.clamp(200.0, 2000.0).toDouble(),
        h.clamp(200.0, 3000.0).toDouble(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('デバイスのサイズ'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final p in _presets)
                  ActionChip(
                    label: Text(p.name),
                    onPressed: () => _usePreset(p),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _wc,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '幅 (width)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hc,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '高さ (height)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '幅は200〜2000、高さは200〜3000の範囲で指定できます',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(onPressed: _ok, child: const Text('OK')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// カラー定義
// ---------------------------------------------------------------------------
class _C {
  static const bg = Color(0xFF1E1E1E);
  static const bar = Color(0xFF252526);
  static const text = Color(0xFFD4D4D4);
  static const gutter = Color(0xFF858585);
  static const keyword = Color(0xFF569CD6);
  static const string = Color(0xFFCE9178);
  static const comment = Color(0xFF6A9955);
  static const number = Color(0xFFB5CEA8);
  static const type = Color(0xFF4EC9B0);
  static const function = Color(0xFFDCDCAA);
  static const annotation = Color(0xFFC586C0);
}

// ---------------------------------------------------------------------------
// アプリ本体
// ---------------------------------------------------------------------------
class DartEditorApp extends StatelessWidget {
  const DartEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dart Editor',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: _C.bg,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF323233),
          foregroundColor: Colors.white,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// シンタックスハイライト付きコントローラ
// ---------------------------------------------------------------------------
class DartCodeController extends TextEditingController {
  DartCodeController({super.text});

  static final RegExp _token = RegExp(
    r'(//[^\n]*|/\*[\s\S]*?(?:\*/|$))'
    r'|(\x27\x27\x27[\s\S]*?(?:\x27\x27\x27|$)|\x22\x22\x22[\s\S]*?(?:\x22\x22\x22|$)|r?\x27(?:\\.|[^\x27\\\n])*\x27?|r?\x22(?:\\.|[^\x22\\\n])*\x22?)'
    r'|(@[A-Za-z_]\w*)'
    r'|(\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)'
    r'|([A-Za-z_$][A-Za-z0-9_$]*)',
  );

  static const Set<String> _keywords = {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
    'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
    'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
    'external', 'factory', 'false', 'final', 'finally', 'for', 'Function',
    'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is',
    'late', 'library', 'mixin', 'new', 'null', 'on', 'operator', 'part',
    'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static',
    'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'typedef',
    'var', 'void', 'when', 'while', 'with', 'yield',
  };

  static const Set<String> _lowerTypes = {'int', 'double', 'num', 'bool'};

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 日本語入力などの変換中は、下線表示を優先してハイライトしない
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final src = text;
    final spans = <TextSpan>[];
    var last = 0;

    for (final m in _token.allMatches(src)) {
      if (m.start > last) {
        spans.add(TextSpan(text: src.substring(last, m.start)));
      }
      final tok = m[0]!;
      Color? color;
      if (m[1] != null) {
        color = _C.comment;
      } else if (m[2] != null) {
        color = _C.string;
      } else if (m[3] != null) {
        color = _C.annotation;
      } else if (m[4] != null) {
        color = _C.number;
      } else {
        final first = tok.codeUnitAt(0);
        if (_keywords.contains(tok)) {
          color = _C.keyword;
        } else if (_lowerTypes.contains(tok) || (first >= 65 && first <= 90)) {
          color = _C.type;
        } else {
          var i = m.end;
          while (i < src.length && src[i] == ' ') {
            i++;
          }
          if (i < src.length && src[i] == '(') {
            color = _C.function;
          }
        }
      }
      spans.add(TextSpan(text: tok, style: TextStyle(color: color)));
      last = m.end;
    }
    if (last < src.length) {
      spans.add(TextSpan(text: src.substring(last)));
    }
    return TextSpan(style: style, children: spans);
  }
}

// ---------------------------------------------------------------------------
// 自動インデント
// ---------------------------------------------------------------------------
class _AutoIndentFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final sel = newValue.selection;
    if (newValue.text.length != oldValue.text.length + 1 ||
        !sel.isCollapsed ||
        !oldValue.selection.isCollapsed ||
        sel.baseOffset < 1 ||
        oldValue.selection.baseOffset != sel.baseOffset - 1 ||
        newValue.text[sel.baseOffset - 1] != '\n') {
      return newValue;
    }

    final pos = sel.baseOffset;
    final before = newValue.text.substring(0, pos - 1);
    final after = newValue.text.substring(pos);
    final lineStart = before.lastIndexOf('\n') + 1;
    final prevLine = before.substring(lineStart);
    final indent = RegExp(r'^[ \t]*').stringMatch(prevLine) ?? '';
    final trimmed = prevLine.trimRight();
    final opens = trimmed.endsWith('{') ||
        trimmed.endsWith('(') ||
        trimmed.endsWith('[');
    final extra = opens ? '  ' : '';
    final nextChar = after.isEmpty ? '' : after[0];
    final closes = nextChar == '}' || nextChar == ')' || nextChar == ']';

    if (opens && closes) {
      final inserted = '\n$indent$extra\n$indent';
      return TextEditingValue(
        text: before + inserted + after,
        selection: TextSelection.collapsed(
          offset: before.length + 1 + indent.length + extra.length,
        ),
      );
    }

    final inserted = '\n$indent$extra';
    return TextEditingValue(
      text: before + inserted + after,
      selection: TextSelection.collapsed(offset: before.length + inserted.length),
    );
  }
}

// ---------------------------------------------------------------------------
// ホーム画面(ファイル管理)
// ---------------------------------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  SharedPreferences? _prefs;
  Map<String, String> _files = {};
  String _current = '';
  double _fontSize = 14;
  bool _loaded = false;
  Timer? _saveTimer;
  String? _output;
  bool _running = false;
  int _panelTab = 0;
  String? _previewSource;
  int _runId = 0;
  double _deviceW = 360;
  double _deviceH = 760;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _saveNow();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _saveNow();
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    var files = <String, String>{};
    final raw = prefs.getString('files');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        files = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        files = {};
      }
    }
    if (files.isEmpty) {
      files = {'main.dart': _sampleCode};
    }
    var current = prefs.getString('current') ?? '';
    if (!files.containsKey(current)) {
      current = files.keys.first;
    }
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _files = files;
      _current = current;
      _fontSize = prefs.getDouble('fontSize') ?? 14;
      _deviceW = prefs.getDouble('deviceW') ?? 360;
      _deviceH = prefs.getDouble('deviceH') ?? 760;
      _loaded = true;
    });
  }

  void _saveNow() {
    _saveTimer?.cancel();
    final p = _prefs;
    if (p == null) return;
    p.setString('files', jsonEncode(_files));
    p.setString('current', _current);
    p.setDouble('fontSize', _fontSize);
    p.setDouble('deviceW', _deviceW);
    p.setDouble('deviceH', _deviceH);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveNow);
  }

  String? _normalizeName(String raw) {
    final s = raw.trim();
    if (s.isEmpty || s.contains('/') || s.contains('\\')) return null;
    return s.contains('.') ? s : '$s.dart';
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _newFile() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(title: '新しいファイル'),
    );
    if (raw == null || !mounted) return;
    final name = _normalizeName(raw);
    if (name == null) {
      _snack('使えないファイル名です');
      return;
    }
    if (_files.containsKey(name)) {
      _snack('同じ名前のファイルが既にあります');
      return;
    }
    setState(() {
      _files[name] = '';
      _current = name;
    });
    _saveNow();
  }

  Future<void> _renameFile(String old) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: '名前を変更', initial: old),
    );
    if (raw == null || !mounted) return;
    final name = _normalizeName(raw);
    if (name == null) {
      _snack('使えないファイル名です');
      return;
    }
    if (name == old) return;
    if (_files.containsKey(name)) {
      _snack('同じ名前のファイルが既にあります');
      return;
    }
    setState(() {
      _files = Map.fromEntries(
        _files.entries.map((e) => MapEntry(e.key == old ? name : e.key, e.value)),
      );
      if (_current == old) _current = name;
    });
    _saveNow();
  }

  Future<void> _deleteFile(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ファイルを削除'),
        content: Text('「$name」を削除しますか?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _files.remove(name);
      if (_files.isEmpty) {
        _files['main.dart'] = '';
      }
      if (!_files.containsKey(_current)) {
        _current = _files.keys.first;
      }
    });
    _saveNow();
  }

  void _changeFontSize(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(10, 28).toDouble();
    });
    _saveNow();
  }

  Future<void> _run() async {
    if (_running) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final source = _files[_current] ?? '';
    final wrapped = _wrapForPreview(source);
    setState(() {
      _running = true;
      _panelTab = 0;
      _output = '実行中...';
    });
    await Future.delayed(const Duration(milliseconds: 80));

    // runApp を含むFlutterコード: 仮想デバイスに表示
    if (wrapped != null) {
      String? error;
      try {
        final compiler = Compiler()..addPlugin(flutterEvalPlugin);
        compiler.compile({
          'preview': {'main.dart': wrapped},
        });
      } catch (e) {
        error = e.toString();
      }
      if (!mounted) return;
      final err = error;
      setState(() {
        _running = false;
        if (err == null) {
          _previewSource = wrapped;
          _runId++;
          _panelTab = 1;
          _output = 'コンパイルに成功しました。仮想デバイスに表示しています。';
        } else {
          final msg = err.length > 1000 ? '${err.substring(0, 1000)}...' : err;
          _output = 'エラー: $msg';
        }
      });
      return;
    }

    // それ以外: コンソールで実行
    String result;
    try {
      result = await compute(_evalEntry, source).timeout(
        const Duration(seconds: 10),
        onTimeout: () => 'タイムアウト(10秒)で中断しました',
      );
    } catch (e) {
      result = 'エラー: $e';
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _output = result.isEmpty ? '(出力なし)' : result;
    });
  }

  void _addFlutterSample() {
    var name = 'flutter_sample.dart';
    var i = 2;
    while (_files.containsKey(name)) {
      name = 'flutter_sample_$i.dart';
      i++;
    }
    setState(() {
      _files[name] = _flutterSample;
      _current = name;
    });
    _saveNow();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _files[_current] ?? ''));
    if (mounted) _snack('全文をコピーしました');
  }

  Widget _tabButton(String label, int index) {
    final selected = _panelTab == index;
    return TextButton(
      onPressed: () => setState(() => _panelTab = index),
      style: TextButton.styleFrom(
        foregroundColor: selected ? Colors.white : _C.gutter,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _buildConsoleTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        width: double.infinity,
        child: SelectableText(
          _output ?? '',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: _fontSize,
            color: _C.text,
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceTab() {
    final src = _previewSource;
    if (src == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'runApp を含むFlutterのコードを ▶ で実行すると、ここに表示されます',
            textAlign: TextAlign.center,
            style: TextStyle(color: _C.gutter),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: _DeviceFrame(
        key: ValueKey(_runId),
        source: src,
        width: _deviceW,
        height: _deviceH,
      ),
    );
  }

  Widget _buildPanel() {
    final isDevice = _panelTab == 1;
    final screenH = MediaQuery.of(context).size.height;
    final height = isDevice ? (screenH * 0.5).clamp(260.0, 440.0).toDouble() : 180.0;
    final src = _previewSource;

    return Container(
      height: height,
      width: double.infinity,
      color: const Color(0xFF181818),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 36,
            color: _C.bar,
            padding: const EdgeInsets.only(left: 4),
            child: Row(
              children: [
                _tabButton('コンソール', 0),
                _tabButton('仮想デバイス', 1),
                if (_running) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                const Spacer(),
                if (isDevice && src != null)
                  IconButton(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                    tooltip: '全画面表示',
                    icon: const Icon(Icons.fullscreen),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _DevicePage(
                            source: src,
                            width: _deviceW,
                            height: _deviceH,
                            onSizeChanged: (w, h) {
                              setState(() {
                                _deviceW = w;
                                _deviceH = h;
                              });
                              _saveNow();
                            },
                          ),
                        ),
                      );
                    },
                  ),
                IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: '閉じる',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _output = null),
                ),
              ],
            ),
          ),
          Expanded(
            child: isDevice ? _buildDeviceTab() : _buildConsoleTab(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final name = _current;
    return Scaffold(
      appBar: AppBar(
        title: Text(name, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow, color: Colors.greenAccent),
            tooltip: '実行',
            onPressed: _running ? null : _run,
          ),
          IconButton(
            icon: const Icon(Icons.text_decrease),
            tooltip: '文字を小さく',
            onPressed: () => _changeFontSize(-1),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            tooltip: '文字を大きく',
            onPressed: () => _changeFontSize(1),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '全文コピー',
            onPressed: _copyAll,
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              const ListTile(
                title: Text('ファイル', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: [
                    for (final f in _files.keys)
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(f),
                        selected: f == _current,
                        onTap: () {
                          Navigator.pop(context);
                          setState(() => _current = f);
                          _saveNow();
                        },
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            Navigator.pop(context);
                            if (v == 'rename') _renameFile(f);
                            if (v == 'delete') _deleteFile(f);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('名前を変更')),
                            PopupMenuItem(value: 'delete', child: Text('削除')),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: const Text('Flutterサンプルを追加'),
                onTap: () {
                  Navigator.pop(context);
                  _addFlutterSample();
                },
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('新しいファイル'),
                onTap: () {
                  Navigator.pop(context);
                  _newFile();
                },
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: EditorView(
              key: ValueKey(name),
              initialText: _files[name] ?? '',
              fontSize: _fontSize,
              onChanged: (t) {
                _files[name] = t;
                _scheduleSave();
              },
            ),
          ),
          if (_output != null) _buildPanel(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ファイル名入力ダイアログ
// ---------------------------------------------------------------------------
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, this.initial = ''});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'example.dart'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// エディタ本体
// ---------------------------------------------------------------------------
class _Sym {
  const _Sym(this.label, this.text, [this.back = 0]);

  final String label;
  final String text;
  final int back;
}

const List<_Sym> _symbols = [
  _Sym('Tab', '  '),
  _Sym('{ }', '{}', 1),
  _Sym('( )', '()', 1),
  _Sym('[ ]', '[]', 1),
  _Sym(';', ';'),
  _Sym(':', ':'),
  _Sym("' '", "''", 1),
  _Sym('" "', '""', 1),
  _Sym('\$', '\$'),
  _Sym('\${ }', '\${}', 1),
  _Sym('=>', '=>'),
  _Sym('=', '='),
  _Sym('.', '.'),
  _Sym(',', ','),
  _Sym('< >', '<>', 1),
  _Sym('!', '!'),
  _Sym('?', '?'),
  _Sym('&&', '&&'),
  _Sym('||', '||'),
  _Sym('/', '/'),
  _Sym('_', '_'),
  _Sym('+', '+'),
  _Sym('-', '-'),
  _Sym('*', '*'),
  _Sym('%', '%'),
];

class EditorView extends StatefulWidget {
  const EditorView({
    super.key,
    required this.initialText,
    required this.fontSize,
    required this.onChanged,
  });

  final String initialText;
  final double fontSize;
  final ValueChanged<String> onChanged;

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  static const double _lineHeight = 1.45;

  late final DartCodeController _controller;
  final UndoHistoryController _undo = UndoHistoryController();
  final FocusNode _focus = FocusNode();

  double _cachedFontSize = -1;
  double _cachedCharWidth = 8;

  @override
  void initState() {
    super.initState();
    _controller = DartCodeController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    _undo.dispose();
    _focus.dispose();
    super.dispose();
  }

  double _charWidth(TextStyle style) {
    if (_cachedFontSize != widget.fontSize) {
      final tp = TextPainter(
        text: TextSpan(text: 'MMMMMMMMMM', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      _cachedCharWidth = tp.width / 10;
      _cachedFontSize = widget.fontSize;
    }
    return _cachedCharWidth;
  }

  void _insert(String s, {int back = 0}) {
    final v = _controller.value;
    var start = v.selection.start;
    var end = v.selection.end;
    if (start < 0 || end < 0) {
      start = v.text.length;
      end = v.text.length;
    }
    final text = v.text.replaceRange(start, end, s);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + s.length - back),
    );
    widget.onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    final fs = widget.fontSize;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'],
      fontSize: fs,
      height: _lineHeight,
      color: _C.text,
    );
    final strut = StrutStyle(
      fontFamily: 'monospace',
      fontSize: fs,
      height: _lineHeight,
      forceStrutHeight: true,
    );

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              return ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) {
                  final lines = value.text.split('\n');
                  var maxLen = 0;
                  for (final l in lines) {
                    if (l.length > maxLen) maxLen = l.length;
                  }
                  final cw = _charWidth(style);
                  final digits = math.max(2, lines.length.toString().length);
                  final gutterW = digits * cw + 22;
                  final contentW = math.max(
                    c.maxWidth - gutterW,
                    (maxLen + 6) * cw + 24,
                  );
                  final numbers = List.generate(
                    lines.length,
                    (i) => '${i + 1}',
                  ).join('\n');

                  return SingleChildScrollView(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _focus.requestFocus(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: c.maxHeight),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: gutterW,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(0, 12, 10, 80),
                                child: Text(
                                  numbers,
                                  textAlign: TextAlign.right,
                                  style: style.copyWith(color: _C.gutter),
                                  strutStyle: strut,
                                ),
                              ),
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SizedBox(
                                  width: contentW,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(4, 12, 0, 80),
                                    child: TextField(
                                      controller: _controller,
                                      focusNode: _focus,
                                      undoController: _undo,
                                      maxLines: null,
                                      keyboardType: TextInputType.multiline,
                                      autocorrect: false,
                                      smartDashesType: SmartDashesType.disabled,
                                      smartQuotesType: SmartQuotesType.disabled,
                                      style: style,
                                      strutStyle: strut,
                                      cursorColor: Colors.white,
                                      inputFormatters: [_AutoIndentFormatter()],
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      onChanged: widget.onChanged,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        Container(
          height: 44,
          color: _C.bar,
          child: ExcludeFocus(
            child: Row(
              children: [
                ValueListenableBuilder<UndoHistoryValue>(
                  valueListenable: _undo,
                  builder: (context, v, _) {
                    return Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.undo),
                          tooltip: '元に戻す',
                          onPressed: v.canUndo ? _undo.undo : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.redo),
                          tooltip: 'やり直す',
                          onPressed: v.canRedo ? _undo.redo : null,
                        ),
                      ],
                    );
                  },
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final s in _symbols)
                        InkWell(
                          onTap: () => _insert(s.text, back: s.back),
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 44),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              s.label,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 16,
                                color: _C.text,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
