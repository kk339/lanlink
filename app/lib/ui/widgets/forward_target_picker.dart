/// Picking the **devices** to forward messages to (0.2.41, multi-select 0.2.46,
/// single-select 0.2.62).
///
/// 「会话 = 设备」 in this app, so "forward" is not a copy of a record — it is
/// "send these again to that device". The picker therefore lists **devices**, not
/// conversations: a peer that has never exchanged a message with us is still a
/// legitimate target, and a peer we have a conversation with but that is offline
/// still is too (the outbox queues it and the pump sends it when it comes back).
///
/// The list comes from the same pure selector the home screen uses
/// ([mergeDeviceCards]) over the same three sources, so the two screens cannot
/// disagree about who exists or whether someone is online. It is read **once**,
/// when the sheet opens: this is a short-lived modal, and a live-updating list
/// behind a barrier would be motion with no decision attached to it.
///
/// **0.2.46 — the picker returns a LIST, and that is the change.** Until then it
/// answered one device, because the only door was 「⋯ → 多选 → 转发」 and one
/// device per run was the scope. The user's request ("转给其他设备…我要转给两台怎么办")
/// turns one forward into a fan-out, so the dialog now has checkboxes and its
/// confirm button says how many are picked.
///
/// **0.2.62 — the same sheet also answers 「分享进来的文件发给谁」.** That
/// question has exactly one right answer (a draft has one destination), so the
/// caller passes [showForwardTargetPicker]'s `singleSelect`: one tap on a row
/// picks it and closes, and the answer is a list of length 0 or 1. Multi-select
/// stays the default, so 「转发到…」 is byte-for-byte what it was.
///
/// Two rules the dialog must keep, both of them ways this could be built wrong:
///
/// * **a closed dialog is an empty list, never "everything"** — [showForwardTargetPicker]
///   answers `const <PeerDevice>[]` for both 取消 and a barrier dismissal, and in
///   multi-select the confirm button is **disabled** at zero picks, so there is no
///   path from "no choice" to "sent to all" (this is criterion 4 of the change).
///   In single-select there is no confirm button at all: the only way out with a
///   device is tapping it, which is the same "a closed dialog chooses nothing"
///   guarantee by construction;
/// * **an offline device is not disabled** — it is the one row that needs an
///   explanation rather than a ban: the send queues and the outbox pump delivers
///   it when the device comes back (Q9), which is why the subtitle says so
///   instead of the row greying out.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/selectors.dart';
import '../scope.dart';
import 'device_row.dart';

/// The 转发 sheet's title — the wording of the door that existed first
/// (0.2.41). Kept as a constant so the share intake can pass its own title
/// without either call site spelling the other's string.
const String kForwardPickerTitle = '转发到';

/// The line shown when there is not a single sendable device (转发 wording).
const String kForwardPickerEmptyMessage = '还没有可以转发到的设备';

/// The line shown when there is not a single sendable device (分享 wording).
const String kShareTargetPickerEmptyMessage = '还没有可以发送的设备';

/// Shows the device list and returns the picked devices.
///
/// Always a list, never `null`: an empty list means "nothing was chosen" —
/// dismissed, cancelled, or (multi-select only) confirmed with zero picks — and
/// the caller must send nothing for it.
///
/// [singleSelect] (0.2.62) makes the sheet a **chooser** instead of a
/// multi-select form: tapping a row picks that one device and closes the sheet,
/// so the answer is either `[]` (nothing chosen) or exactly one device. The
/// return type stays a list so both doors — 「转发到…」 and 「分享发给谁」 — read
/// the same value and a caller written for the old signature keeps compiling.
///
/// [title] names the question; [emptyMessage] says there is nobody to ask. The
/// defaults are 转发's strings, so the pre-0.2.62 call sites are unchanged.
Future<List<PeerDevice>> showForwardTargetPicker(
  BuildContext context, {
  bool singleSelect = false,
  String title = kForwardPickerTitle,
  String emptyMessage = kForwardPickerEmptyMessage,
}) async {
  final List<PeerDevice> devices = mergeDeviceCards(
    online: context.deps.discovery.online,
    conversations: context.deps.repo.conversations(),
    devices: context.deps.repo.devices(),
  );
  // A device with no port has never been reachable in either direction, so it can
  // neither receive a dial nor be queued for one — it is not a candidate at all
  // (`PeerDevice.canSend`). Listing it would be a row that always fails.
  final List<PeerDevice> targets =
      devices.where((PeerDevice d) => d.canSend).toList();
  if (targets.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: Text(title),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Text(emptyMessage),
          ),
        ],
      ),
    );
    return const <PeerDevice>[];
  }
  final List<PeerDevice>? picked = await showDialog<List<PeerDevice>>(
    context: context,
    builder: (BuildContext dialogContext) => _ForwardTargetDialog(
      devices: targets,
      singleSelect: singleSelect,
      title: title,
    ),
  );
  // `null` is Flutter's dismissal (barrier tap / back). It is **not** a licence
  // to forward to everybody — see this file's header, rule 1.
  return picked ?? const <PeerDevice>[];
}

/// The dialog itself: one row per device, plus the actions that mode needs.
///
/// A [StatefulWidget] rather than `StatefulBuilder` so the multi-select picks
/// survive the rebuilds `AlertDialog` does and so the widget tree has a stable
/// identity per device (the keys below are what the tests tap).
class _ForwardTargetDialog extends StatefulWidget {
  /// Creates the dialog for [devices] (already filtered to the sendable ones).
  const _ForwardTargetDialog({
    required this.devices,
    this.singleSelect = false,
    this.title = kForwardPickerTitle,
  });

  /// Every device that can be a target, in the selector's order (online first).
  final List<PeerDevice> devices;

  /// `true` = tap a row and it is the answer (分享); `false` = checkboxes + 转发.
  final bool singleSelect;

  /// The question this sheet asks (「转发到」 / 「把 N 个文件发给谁」).
  final String title;

  @override
  State<_ForwardTargetDialog> createState() => _ForwardTargetDialogState();
}

class _ForwardTargetDialogState extends State<_ForwardTargetDialog> {
  /// The picked fingerprints, in pick order — a `Set` alone would lose the order
  /// the user tapped in, and the fan-out happens in that order.
  final List<String> _picked = <String>[];

  bool _isPicked(PeerDevice device) =>
      _picked.contains(device.fingerprint);

  void _toggle(PeerDevice device) {
    setState(() {
      if (!_picked.remove(device.fingerprint)) {
        _picked.add(device.fingerprint);
      }
    });
  }

  /// The picked devices, in the order they were picked.
  List<PeerDevice> get _pickedDevices => <PeerDevice>[
        for (final String fingerprint in _picked)
          for (final PeerDevice device in widget.devices)
            if (device.fingerprint == fingerprint) device,
      ];

  /// The name a row shows: the alias, or the fingerprint when it has none.
  String _nameOf(PeerDevice device) =>
      device.alias.isEmpty ? device.fingerprint : device.alias;

  /// The subtitle both modes share: presence, and why an offline row still
  /// works (it queues) — see this file's header, rule 2.
  String _presenceOf(PeerDevice device) =>
      device.isOnline ? '在线' : '离线 · 会排队，等它上线再发';

  /// One row in **single-select** mode: a tap is the whole interaction.
  Widget _chooserRow(PeerDevice device, ThemeData theme) => ListTile(
        // The same key in both modes on purpose: "a row means the same thing in
        // both doors", and the tests address a device the same way either way.
        key: ValueKey<String>('forward-target-${device.fingerprint}'),
        onTap: () => Navigator.of(context).pop(<PeerDevice>[device]),
        leading: Icon(
          deviceKindIcon(device.kind),
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          _nameOf(device),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(_presenceOf(device)),
      );

  /// One row in **multi-select** mode (the 转发 form).
  Widget _checkboxRow(PeerDevice device, ThemeData theme) =>
      CheckboxListTile(
        key: ValueKey<String>('forward-target-${device.fingerprint}'),
        value: _isPicked(device),
        // Offline devices stay **tappable**: the send is queued and the
        // outbox pump delivers it later (Q9). Disabling the row would
        // silently remove the one ability that makes an offline peer
        // useful — see this file's header, rule 2.
        onChanged: (bool? _) => _toggle(device),
        controlAffinity: ListTileControlAffinity.leading,
        secondary: Icon(
          deviceKindIcon(device.kind),
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          _nameOf(device),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(_presenceOf(device)),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool single = widget.singleSelect;
    final bool anyPicked = _picked.isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.only(top: 12, bottom: 8),
      content: SizedBox(
        width: 360,
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final PeerDevice device in widget.devices)
              if (single)
                _chooserRow(device, theme)
              else
                _checkboxRow(device, theme),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('forward-cancel'),
          onPressed: () => Navigator.of(context).pop(const <PeerDevice>[]),
          child: const Text('取消'),
        ),
        // Single-select has **no confirm button**: the row tap already answered,
        // and a 转发（N） button here would be a second, meaningless way to say
        // the same thing (see this file's header, rule 1).
        if (!single)
          FilledButton(
            key: const ValueKey<String>('forward-confirm'),
            // ★ Disabled at zero picks. This is the whole of criterion 4: there is
            // no button that can turn "I did not choose" into a send.
            onPressed: anyPicked
                ? () => Navigator.of(context).pop(_pickedDevices)
                : null,
            child: Text('转发（${_picked.length}）'),
          ),
      ],
    );
  }
}
