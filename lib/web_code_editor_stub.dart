// Web以外(Android / iOS など)のビルドで使われるダミー実装。
// 実際のWeb用エディタは web_code_editor_web.dart にある。
//
// リポジトリ内の配置先: lib/web_code_editor_stub.dart

import 'package:flutter/widgets.dart';

class WebCodeEditor extends StatelessWidget {
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
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    throw UnsupportedError('WebCodeEditor は Web でのみ使えます');
  }
}
