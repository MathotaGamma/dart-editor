// Web専用のコードエディタ。
// Flutterの TextField ではなく、ブラウザ標準の <textarea> を HtmlElementView で埋め込む。
// (iPadのSafariで、タッチ位置とカーソル位置がずれる問題を避けるため)
//
// リポジトリ内の配置先: lib/web_code_editor_web.dart
// Web以外のビルドでは、lib/web_code_editor_stub.dart が使われる。

import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

@JS('eval')
external JSAny? _eval(JSString code);

@JS('dartEditorCreate')
external JSObject _createEditor(
  JSString text,
  JSNumber fontSize,
  JSFunction onChange,
);

@JS('dartEditorSetFontSize')
external void _setFontSize(JSObject el, JSNumber size);

@JS('dartEditorSetInteractive')
external void _setInteractive(JSObject el, JSBoolean on);

class WebCodeEditor extends StatefulWidget {
  const WebCodeEditor({
    super.key,
    required this.initialText,
    required this.fontSize,
    required this.onChanged,
    this.interactive = true,
  });

  final String initialText;
  final double fontSize;
  final ValueChanged<String> onChanged;

  /// false のとき、エディタはタッチを受け付けない
  /// (ドロワーやダイアログなど、Flutterの画面が上に重なっているとき用)
  final bool interactive;

  @override
  State<WebCodeEditor> createState() => _WebCodeEditorState();
}

class _WebCodeEditorState extends State<WebCodeEditor> {
  static bool _scriptReady = false;
  static int _nextId = 0;

  late final String _viewType;
  JSObject? _el;

  @override
  void initState() {
    super.initState();
    if (!_scriptReady) {
      _eval(_script.toJS);
      _scriptReady = true;
    }
    _viewType = 'darteditor-web-code-editor-${_nextId++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final el = _createEditor(
        widget.initialText.toJS,
        widget.fontSize.toJS,
        ((JSString t) {
          widget.onChanged(t.toDart);
        }).toJS,
      );
      _el = el;
      _setInteractive(el, widget.interactive.toJS);
      return el;
    });
  }

  @override
  void didUpdateWidget(WebCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final el = _el;
    if (el == null) return;
    if (oldWidget.fontSize != widget.fontSize) {
      _setFontSize(el, widget.fontSize.toJS);
    }
    if (oldWidget.interactive != widget.interactive) {
      _setInteractive(el, widget.interactive.toJS);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}

// ---------------------------------------------------------------------------
// ブラウザ側で動くエディタ本体(JavaScript)
// ---------------------------------------------------------------------------
// 構成: 行番号 | [色付きの<pre>(背面) + 透明な<textarea>(前面)] と、下部の記号入力バー。
// 入力・カーソル・選択・スクロールは <textarea> がブラウザ標準の動作で行う。
const String _script = r'''
(function () {
  var COLORS = {
    comment: "#6a9955", string: "#ce9178", annotation: "#c586c0",
    number: "#b5cea8", keyword: "#569cd6", type: "#4ec9b0", fn: "#dcdcaa"
  };
  var KEYWORDS = {};
  ("abstract as assert async await base break case catch class const continue " +
   "covariant default deferred do dynamic else enum export extends extension " +
   "external factory false final finally for Function get hide if implements " +
   "import in interface is late library mixin new null on operator part " +
   "required rethrow return sealed set show static super switch sync this " +
   "throw true try typedef var void when while with yield").split(" ").forEach(function (k) {
    KEYWORDS[k] = 1;
  });
  var LOWER_TYPES = { "int": 1, "double": 1, "num": 1, "bool": 1 };

  var TOKEN = /(\/\/[^\n]*|\/\*[\s\S]*?(?:\*\/|$))|(r?\x27\x27\x27[\s\S]*?(?:\x27\x27\x27|$)|r?\x22\x22\x22[\s\S]*?(?:\x22\x22\x22|$)|r?\x27(?:\\.|[^\x27\\\n])*\x27?|r?\x22(?:\\.|[^\x22\\\n])*\x22?)|(@[A-Za-z_]\w*)|(\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|([A-Za-z_$][A-Za-z0-9_$]*)/g;

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function highlight(src) {
    var out = "", last = 0, m;
    TOKEN.lastIndex = 0;
    while ((m = TOKEN.exec(src)) !== null) {
      if (m.index > last) out += esc(src.slice(last, m.index));
      var tok = m[0], color = null;
      if (m[1] !== undefined) color = COLORS.comment;
      else if (m[2] !== undefined) color = COLORS.string;
      else if (m[3] !== undefined) color = COLORS.annotation;
      else if (m[4] !== undefined) color = COLORS.number;
      else {
        var c = tok.charCodeAt(0);
        if (KEYWORDS[tok] === 1) color = COLORS.keyword;
        else if (LOWER_TYPES[tok] === 1 || (c >= 65 && c <= 90)) color = COLORS.type;
        else {
          var i = m.index + tok.length;
          while (i < src.length && src.charAt(i) === " ") i++;
          if (src.charAt(i) === "(") color = COLORS.fn;
        }
      }
      if (color) out += "<span style=\"color:" + color + "\">" + esc(tok) + "</span>";
      else out += esc(tok);
      last = m.index + tok.length;
    }
    if (last < src.length) out += esc(src.slice(last));
    return out;
  }

  var SYMBOLS = [
    ["Tab", "  ", 0], ["{ }", "{}", 1], ["( )", "()", 1], ["[ ]", "[]", 1],
    [";", ";", 0], [":", ":", 0], ["\x27 \x27", "\x27\x27", 1], ["\x22 \x22", "\x22\x22", 1],
    ["$", "$", 0], ["${ }", "${}", 1], ["=>", "=>", 0], ["=", "=", 0],
    [".", ".", 0], [",", ",", 0], ["< >", "<>", 1], ["!", "!", 0],
    ["?", "?", 0], ["&&", "&&", 0], ["||", "||", 0], ["/", "/", 0],
    ["_", "_", 0], ["+", "+", 0], ["-", "-", 0], ["*", "*", 0], ["%", "%", 0]
  ];

  window.dartEditorCreate = function (initialText, fontSize, onChange) {
    var FF = "ui-monospace, SFMono-Regular, Menlo, Consolas, \"Courier New\", monospace";
    var PAD_V = 12;
    var fs = 16, lh = 23;

    var styleEl = document.createElement("style");
    styleEl.textContent =
      ".dce-ta::selection{background:rgba(38,79,120,0.85);}" +
      ".dce-ta{-webkit-text-fill-color:transparent;}" +
      ".dce-bar::-webkit-scrollbar{display:none;}" +
      ".dce-btn:active{background:#3a3a3a;}";

    var root = document.createElement("div");
    root.style.cssText =
      "position:relative;width:100%;height:100%;display:flex;flex-direction:column;" +
      "background:#1e1e1e;color:#d4d4d4;overflow:hidden;-webkit-tap-highlight-color:transparent;";
    root.appendChild(styleEl);

    var area = document.createElement("div");
    area.style.cssText = "flex:1;min-height:0;display:flex;overflow:hidden;";
    root.appendChild(area);

    var gutter = document.createElement("div");
    gutter.style.cssText =
      "flex:none;overflow:hidden;text-align:right;color:#858585;box-sizing:content-box;" +
      "padding:" + PAD_V + "px 10px " + PAD_V + "px 8px;white-space:pre;" +
      "user-select:none;-webkit-user-select:none;pointer-events:none;";
    area.appendChild(gutter);

    var wrap = document.createElement("div");
    wrap.style.cssText = "position:relative;flex:1;min-width:0;";
    area.appendChild(wrap);

    var pre = document.createElement("pre");
    pre.setAttribute("aria-hidden", "true");
    pre.style.cssText =
      "position:absolute;left:0;top:0;right:0;bottom:0;margin:0;overflow:hidden;" +
      "box-sizing:border-box;padding:" + PAD_V + "px 8px " + PAD_V + "px 6px;" +
      "white-space:pre;pointer-events:none;";
    wrap.appendChild(pre);

    var ta = document.createElement("textarea");
    ta.className = "dce-ta";
    ta.setAttribute("wrap", "off");
    ta.setAttribute("spellcheck", "false");
    ta.setAttribute("autocapitalize", "off");
    ta.setAttribute("autocomplete", "off");
    ta.setAttribute("autocorrect", "off");
    ta.style.cssText =
      "position:absolute;left:0;top:0;width:100%;height:100%;margin:0;border:0;outline:none;" +
      "resize:none;background:transparent;color:transparent;caret-color:#ffffff;" +
      "box-sizing:border-box;padding:" + PAD_V + "px 8px " + PAD_V + "px 6px;" +
      "white-space:pre;overflow:auto;touch-action:auto;";
    ta.value = initialText;
    wrap.appendChild(ta);

    var bar = document.createElement("div");
    bar.className = "dce-bar";
    bar.style.cssText =
      "flex:none;height:44px;display:flex;align-items:center;background:#252526;" +
      "border-top:1px solid #333;overflow-x:auto;overflow-y:hidden;" +
      "-webkit-overflow-scrolling:touch;";
    root.appendChild(bar);

    function applyFont(size) {
      fs = Math.max(16, size);
      lh = Math.round(fs * 1.45);
      [gutter, pre, ta].forEach(function (e) {
        e.style.fontFamily = FF;
        e.style.fontSize = fs + "px";
        e.style.lineHeight = lh + "px";
        e.style.letterSpacing = "0";
        e.style.tabSize = "2";
      });
    }

    var lineCount = -1;
    function sync() {
      pre.scrollTop = ta.scrollTop;
      pre.scrollLeft = ta.scrollLeft;
      gutter.scrollTop = ta.scrollTop;
    }
    function render() {
      var v = ta.value;
      pre.innerHTML = highlight(v) + "\n";
      var n = v.split("\n").length;
      if (n !== lineCount) {
        lineCount = n;
        var nums = [];
        for (var i = 1; i <= n; i++) nums.push(String(i));
        gutter.textContent = nums.join("\n");
        gutter.style.width = Math.max(2, String(n).length) + "ch";
      }
      sync();
    }

    function insertText(s, back) {
      ta.focus();
      var ok = false;
      try { ok = document.execCommand("insertText", false, s); } catch (e) { ok = false; }
      if (!ok) {
        ta.setRangeText(s, ta.selectionStart, ta.selectionEnd, "end");
        ta.dispatchEvent(new Event("input", { bubbles: true }));
      }
      if (back) {
        var p = ta.selectionStart - back;
        ta.setSelectionRange(p, p);
      }
    }

    function onBeforeInput(e) {
      if (e.inputType !== "insertLineBreak" && e.inputType !== "insertParagraph") return;
      var v = ta.value, s = ta.selectionStart, en = ta.selectionEnd;
      if (s !== en) return;
      var lineStart = v.lastIndexOf("\n", s - 1) + 1;
      var prev = v.slice(lineStart, s);
      var indent = (prev.match(/^[ \t]*/) || [""])[0];
      var opens = /[\{\(\[]\s*$/.test(prev);
      var extra = opens ? "  " : "";
      var next = v.charAt(s);
      var closes = next === "}" || next === ")" || next === "]";
      e.preventDefault();
      if (opens && closes) {
        insertText("\n" + indent + extra + "\n" + indent, 0);
        var p = s + 1 + indent.length + extra.length;
        ta.setSelectionRange(p, p);
      } else {
        insertText("\n" + indent + extra, 0);
      }
    }

    function makeButton(label, fn) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "dce-btn";
      b.textContent = label;
      b.tabIndex = -1;
      b.style.cssText =
        "flex:none;min-width:44px;height:44px;padding:0 10px;background:none;border:0;" +
        "color:#d4d4d4;font-size:16px;font-family:" + FF + ";user-select:none;" +
        "-webkit-user-select:none;cursor:pointer;";
      b.addEventListener("mousedown", function (e) { e.preventDefault(); });
      b.addEventListener("click", function (e) { e.preventDefault(); fn(); });
      bar.appendChild(b);
    }

    makeButton("\u21B6", function () { ta.focus(); document.execCommand("undo"); });
    makeButton("\u21B7", function () { ta.focus(); document.execCommand("redo"); });
    SYMBOLS.forEach(function (s) {
      makeButton(s[0], function () { insertText(s[1], s[2]); });
    });

    ta.addEventListener("input", function () { render(); onChange(ta.value); });
    ta.addEventListener("scroll", sync);
    ta.addEventListener("beforeinput", onBeforeInput);
    ta.addEventListener("keydown", function (e) {
      if (e.key === "Tab" && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
        e.preventDefault();
        insertText("  ", 0);
      }
    });

    function applyInteractive(on) {
      var v = on ? "auto" : "none";
      root.style.pointerEvents = v;
      if (root.parentElement) root.parentElement.style.setProperty("pointer-events", v, "important");
    }

    root.__api = {
      setFontSize: function (n) { applyFont(n); render(); },
      setInteractive: function (on) {
        applyInteractive(on);
        if (!on) ta.blur();
        setTimeout(function () { applyInteractive(on); }, 50);
      }
    };

    applyFont(fontSize);
    render();
    return root;
  };

  window.dartEditorSetFontSize = function (el, n) { el.__api.setFontSize(n); };
  window.dartEditorSetInteractive = function (el, on) { el.__api.setInteractive(on); };
})();
''';
