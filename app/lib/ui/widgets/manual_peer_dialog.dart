/// 「手动填写 IP 连接」 — the dialog the user reaches when discovery is blocked
/// (0.2.54).
///
/// ## What this widget is, and is not
///
/// It is **input**: one `TextField`, a 取消, a 连接. It does not probe, does not
/// parse, and does not know what an `IP:port` is — `_parseHostPort` lives in the
/// discovery adapter, and `PeerDiscovery.probeHost` is the single authority on
/// what an address is (`ManualProbeFailure.badInput`). So the string the user
/// typed leaves here **byte for byte**; the caller hands it to the controller.
///
/// ## Why there is only one field
///
/// No separate port box. lanlink uses one port (`kDefaultPort`) in the
/// overwhelming majority of cases, and a second empty field is a question the
/// user has to answer (`49494？不确定`) on top of the one thing they do know.
/// A typed `:5000` is still understood — by the adapter, from the same single
/// string (`[fe80::1]:5000` included).
///
/// ## Two modes, one widget
///
/// * **[onConnect] omitted** — 连接 closes immediately with the typed string.
///   That is what a caller wanting a plain "ask for an address" uses;
/// * **[onConnect] supplied** — 连接 stays open, disables both actions and shows a
///   spinner while the future runs, then either closes (on `null`) or shows the
///   returned sentence **in place** (on a message). This is how the probe's
///   3-second deadline stays visible instead of looking like a dead button, and
///   why a typo does not force the dialog to be reopened: the bad address is
///   still in the field, with the reason next to it.
///
/// ## Showing the local address, not only asking for one (0.2.58)
///
/// The dialog used to ask for the peer's address and say nothing about **this**
/// device — and on a desktop there was nowhere else to read our own `IP:port`
/// either. That made the one fact the other machine needs ("what do I type over
/// there?") readable only on the phone. So the top of the dialog now carries a
/// 本机地址 block with both values and a copy button each.
///
/// The block is drawn **only when the address is real** ([localAddress] non-null,
/// non-empty, not [kSelfAddressUnknown]). With no address there is no block and a
/// grey line says why instead — printing a plausible-looking `192.168.1.23` would
/// send the user to a device that does not exist, which is the one thing this
/// project keeps refusing to do.
///
/// The probing itself is the callback's job (`HomeController.addManualPeer`), so
/// this file never imports a controller — the caller wires them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../theme.dart';

/// Shows the 手动添加设备 dialog and answers the input the user accepted.
///
/// `null` means "nothing to do": cancelled, or dismissed by tapping outside /
/// pressing back. A non-null answer is the trimmed text exactly as typed — no
/// port is appended and no validation is performed here.
///
/// [onConnect] turns the dialog into its waiting mode (see the file header): the
/// returned `Future` is awaited with the spinner up, `null` closes the dialog,
/// and any string is shown beside the field as the reason it did not work.
///
/// [localAddress] / [localPort] are **this** device's own address, shown at the
/// top so the user can read it out to the other machine. Both are optional and
/// both are passed through untouched: `null` (or [kSelfAddressUnknown]) means
/// "not known yet", and the dialog then says so rather than guessing.
Future<String?> showManualPeerDialog(
  BuildContext context, {
  Future<String?> Function(String input)? onConnect,
  String? localAddress,
  int? localPort,
}) =>
    showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => ManualPeerDialog(
        onConnect: onConnect,
        localAddress: localAddress,
        localPort: localPort,
      ),
    );

/// The whole entry path, shared by **every** door into this feature (0.2.56):
/// ask for an address, hand the string to the controller, then re-read the
/// settings document.
///
/// ★ The reload is not politeness. `addManualPeer` writes
/// `AppSettings.manualPeers` through `PlatformPorts`, i.e. **behind
/// `SettingsController`'s back**; that controller holds its own copy of the
/// document. Without the reload, 设置 →「手动添加的设备」 would not list the
/// address that was just accepted — and could not remove it either, which would
/// make the feature unmaintainable from the one screen that shows the count.
///
/// [add] is `HomeController.addManualPeer`, [reload] is
/// `SettingsController.load`. Both arrive as callbacks so this file keeps
/// importing no controller (§9.6 layering).
///
/// [localAddress] / [localPort] are this device's own address (0.2.58) and are
/// forwarded to [showManualPeerDialog] unchanged — this function adds no rule of
/// its own about what "known" means (the dialog owns that one decision).
Future<void> openManualPeerDialog(
  BuildContext context, {
  required Future<String?> Function(String input) add,
  required Future<void> Function() reload,
  String? localAddress,
  int? localPort,
}) async {
  final String? accepted = await showManualPeerDialog(
    context,
    onConnect: add,
    localAddress: localAddress,
    localPort: localPort,
  );
  if (accepted == null) {
    // Cancelled, or every attempt failed and the user closed the dialog.
    return;
  }
  await reload();
}

/// The dialog's body. Public so a test can mount it directly.
class ManualPeerDialog extends StatefulWidget {
  /// Creates the dialog.
  ///
  /// [onConnect] is optional; see the file header for the two modes.
  ///
  /// [localAddress] / [localPort] are this device's own address, shown at the top
  /// so the user can read it out to the other machine (0.2.58). Both optional:
  /// absent means "not known", which draws a grey explanation instead of a
  /// made-up address.
  const ManualPeerDialog({
    super.key,
    this.onConnect,
    this.localAddress,
    this.localPort,
  });

  /// Runs the connection attempt for the typed address, or `null` for the
  /// pure-input mode.
  final Future<String?> Function(String input)? onConnect;

  /// This device's LAN address, or `null` / [kSelfAddressUnknown] while unknown.
  final String? localAddress;

  /// This device's listening port, or `null` while unknown. Only meaningful
  /// together with a real [localAddress]: a port on its own is not an address.
  final int? localPort;

  @override
  State<ManualPeerDialog> createState() => _ManualPeerDialogState();
}

class _ManualPeerDialogState extends State<ManualPeerDialog> {
  final TextEditingController _field = TextEditingController();

  /// True while [ManualPeerDialog.onConnect] is running — both actions are
  /// disabled and a spinner is drawn, so the ≤3 s probe cannot read as "点了没反应".
  bool _busy = false;

  /// The sentence shown under the field when the last attempt failed.
  String? _problem;

  /// True once the address has really reached the clipboard (0.2.58).
  bool _copiedAddress = false;

  /// True once the port has really reached the clipboard.
  bool _copiedPort = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  /// The local address this dialog may honestly show, or `null`.
  ///
  /// Three states have to collapse into "nothing to show": `null` (the NIC is not
  /// chosen), `''` (the same thing after a trim), and [kSelfAddressUnknown] (the
  /// placeholder the 本机信息 sheet is handed for that state). Anything else is
  /// shown verbatim — this is not a validator, only a "is this a fact" test.
  String? get _realLocalAddress {
    final String? raw = widget.localAddress?.trim();
    if (raw == null || raw.isEmpty || raw == kSelfAddressUnknown) {
      return null;
    }
    return raw;
  }

  /// Copies the **bare** address — never `IP:port`.
  ///
  /// The two values have separate buttons precisely so each one is pasted into
  /// the field the other machine shows: that field takes an address, and a
  /// `:49494` glued to it would have to be edited out by hand.
  ///
  /// The tick is the whole confirmation. A `SnackBar` is the app's usual "it
  /// worked" gesture, but a dialog route's barrier sits **above** the Scaffold
  /// that owns the messenger, so the toast would come up dimmed behind the very
  /// dialog the user is looking at. A grey ✓ where the button was needs no
  /// timer and cannot be missed.
  Future<void> _copyAddress(String address) async {
    await Clipboard.setData(ClipboardData(text: address));
    if (!mounted) {
      return;
    }
    setState(() => _copiedAddress = true);
  }

  /// Copies the port on its own, as its digits.
  Future<void> _copyPort(int port) async {
    await Clipboard.setData(ClipboardData(text: '$port'));
    if (!mounted) {
      return;
    }
    setState(() => _copiedPort = true);
  }

  /// 连接 (or Enter). Never sends an empty string: a blank field is not an
  /// address, and answering `''` would make the caller produce a `badInput`
  /// sentence about a field the user never filled.
  Future<void> _submit() async {
    final String input = _field.text.trim();
    if (input.isEmpty || _busy) {
      return;
    }
    final Future<String?> Function(String input)? connect = widget.onConnect;
    if (connect == null) {
      // Pure-input mode: hand the text back untouched.
      Navigator.of(context).pop(input);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    final String? problem = await connect(input);
    if (!mounted) {
      return;
    }
    if (problem == null) {
      Navigator.of(context).pop(input);
      return;
    }
    // Keep the dialog up, keep the text, and say what went wrong — the user's
    // next move (fix a digit, check the other device) is one keystroke away.
    setState(() {
      _busy = false;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? address = _realLocalAddress;
    return AlertDialog(
      title: const Text(kManualPeerDialogTitle),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 本机地址 first, and above the input: the user is here because they
            // have a *second* machine open, and this is the half of the exchange
            // they can only produce here (0.2.58).
            if (address != null) ...<Widget>[
              _localAddressBlock(theme, address),
              const SizedBox(height: 16),
            ],
            TextField(
              key: const ValueKey<String>('manual-peer-input'),
              controller: _field,
              autofocus: true,
              enabled: !_busy,
              // A raw number and a colon: the keyboard that offers digits, `.`
              // and `:` is the URL one, not the prose one.
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (String _) => _submit(),
              decoration: const InputDecoration(
                labelText: '对方地址',
                hintText: '192.168.1.23 或 192.168.1.23:49494',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            // No address, no block — and **no invented one**. The line says what
            // to do about it instead of printing a plausible `192.168.1.x`, which
            // would be the one failure the user cannot detect.
            if (address == null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                kManualPeerLocalAddressMissing,
                key: const ValueKey<String>('manual-peer-local-address-missing'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            if (_problem != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _problem!,
                key: const ValueKey<String>('manual-peer-problem'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('manual-peer-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('manual-peer-connect'),
          // Disabled while a probe is in flight — a second tap must not start a
          // second dial.
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('连接'),
        ),
      ],
    );
  }

  /// The 本机地址 card: heading, the address with a copy button, a hairline, then
  /// the port with its own copy button.
  ///
  /// The two values are **separate rows** because they are pasted into two
  /// different things: an address into the peer's 对方地址 field here, and a port
  /// into whatever that machine's dialog calls its port field. One "copy both"
  /// button would produce `192.168.1.23:49494`, which neither field wants.
  Widget _localAddressBlock(ThemeData theme, String address) {
    // Monospace, not the theme's prose face: an IP is read digit by digit
    // (「是 1 还是 7」), and a proportional face makes that harder. `monospace`
    // is the generic family; the fallbacks cover Windows/macOS where the generic
    // name is not resolved.
    final TextStyle mono = (theme.textTheme.bodyLarge ?? const TextStyle())
        .copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const <String>['Menlo', 'Consolas', 'Courier New'],
      letterSpacing: 0.3,
    );
    final String port =
        widget.localPort?.toString() ?? kManualPeerLocalPortMissing;
    return Container(
      key: const ValueKey<String>('manual-peer-local-address'),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
      decoration: BoxDecoration(
        // A tint of the dialog's own surface, not a fixed hex: it has to follow
        // light/dark like the rest of the sheet family.
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kRadiusCard),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            kManualPeerLocalAddressTitle,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono,
                ),
              ),
              _copyButton(
                key: const ValueKey<String>('manual-peer-copy-address'),
                theme: theme,
                copied: _copiedAddress,
                onPressed: () => unawaited(_copyAddress(address)),
              ),
            ],
          ),
          Divider(height: 1, thickness: 1, color: theme.colorScheme.outlineVariant),
          Row(
            children: <Widget>[
              Text(
                kManualPeerPortLabel,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  port,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono,
                ),
              ),
              _copyButton(
                key: const ValueKey<String>('manual-peer-copy-port'),
                theme: theme,
                copied: _copiedPort,
                // Nothing to copy without a port; a button that copies the
                // string '未获取' would be a lie the user can only discover by
                // pasting.
                onPressed: widget.localPort == null
                    ? null
                    : () => unawaited(_copyPort(widget.localPort!)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One copy button, ✓ once the value really is on the clipboard.
  ///
  /// Sized by the framework's own 48dp `IconButton` constraints (only the glyph
  /// is small): `kMinTapTarget` is not something a copy button gets to opt out
  /// of for looking tidier.
  Widget _copyButton({
    required Key key,
    required ThemeData theme,
    required bool copied,
    required VoidCallback? onPressed,
  }) =>
      IconButton(
        key: key,
        tooltip: kManualPeerCopyLabel,
        iconSize: 20,
        padding: EdgeInsets.zero,
        icon: Icon(
          copied ? Icons.check : Icons.copy,
          color: copied
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        onPressed: onPressed,
      );
}
