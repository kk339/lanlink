/// The four troubleshooting hints shown on the home empty state (spec §2
/// `troubleshoot_hints.dart`, PRD P0-10 / A2-1).
///
/// §8.4 designates `ui/format.dart` the single source of UI copy, but these four
/// strings were not added there in T01 and `format.dart` is frozen for T04. They
/// are therefore declared once, here, as [kTroubleshootHints] — a single named
/// source rather than inline literals — so the home page and the widget test
/// both read the same list.
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

/// The four ordered self-help steps shown when no device is discovered.
const List<String> kTroubleshootHints = <String>[
  '确认对方的 lanlink 应用已经打开',
  '确认两台设备连接在同一个 Wi-Fi / 局域网',
  '检查路由器是否开启了「AP 隔离」（无线设备之间相互隔离）',
  '检查 Windows 防火墙是否拦截了 lanlink 的入站连接',
];

/// A titled, numbered list of troubleshooting steps.
class TroubleshootHints extends StatelessWidget {
  /// Creates the hints block.
  ///
  /// [hints] defaults to [kTroubleshootHints] so pages and tests share one list.
  const TroubleshootHints({
    super.key,
    this.title = '找不到设备？按顺序排查：',
    this.hints = kTroubleshootHints,
  });

  /// The heading shown above the list.
  final String title;

  /// The ordered hint strings.
  final List<String> hints;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        for (int i = 0; i < hints.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${i + 1}. ',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
                Expanded(
                  child: Text(
                    hints[i],
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
