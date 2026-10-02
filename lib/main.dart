// v1からの差分:
// - dart_eval によるDartコードの実行機能を追加(AppBarの▶ボタン)
// - 実行結果を表示するコンソール欄を追加(閉じるボタン付き、選択コピー可)
// - 実行は compute で別Isolateに逃がし、10秒でタイムアウト(Webは同一スレッド)
// - サンプルコードを dart_eval で動く内容に変更

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    setState(() {
      _running = true;
      _output = '実行中...';
    });
    await Future.delayed(const Duration(milliseconds: 80));
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

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _files[_current] ?? ''));
    if (mounted) _snack('全文をコピーしました');
  }

  Widget _buildConsole() {
    return Container(
      height: 180,
      width: double.infinity,
      color: const Color(0xFF181818),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 32,
            color: _C.bar,
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                const Text(
                  'コンソール',
                  style: TextStyle(fontSize: 13, color: _C.gutter),
                ),
                if (_running) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                const Spacer(),
                IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _output = null),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
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
            ),
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
          if (_output != null) _buildConsole(),
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
