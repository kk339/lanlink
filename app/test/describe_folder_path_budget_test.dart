/// CR-2 ② — the **production door**, not the policy function.
///
/// `folder_send_test.dart` proves the walk drops what the receiver cannot place,
/// but only if someone hands it `receiverRejectsPath`. This test walks the path a
/// real 「发送文件夹…」 / drop actually takes
/// (`SystemPlatformPorts.describeFolderForSending`) over a real temp directory,
/// so the wiring — the part a reviewer cannot see in the pure-function test — is
/// covered too: a missing `rejectsPath:` argument here would restore the original
/// bug (one long name ⇒ the receiver answers `400` for the whole batch) without
/// failing a single policy test.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_core/lanlink_core.dart' show kMaxRelativePathChars;

import 'package:lanlink_app/data/real/system_platform_ports.dart';
import 'package:lanlink_app/domain/folder_send.dart';

void main() {
  test('★ describeFolderForSending skips the unplaceable file and keeps the '
      'other two', () async {
    // Android has no filesystem-path folder door (`supportsSendFolder` is false
    // and the SAF walk is native), so this test is desktop-only by nature.
    if (Platform.isAndroid) {
      return;
    }
    final Directory root =
        await Directory.systemTemp.createTemp('lanlink_budget_');
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final String sep = Platform.pathSeparator;
    // One over the receiver's budget: it would answer 400 for the whole batch.
    final String tooLong = 'x' * (kMaxRelativePathChars + 5);
    for (final String name in <String>['ok-1.jpg', '$tooLong.jpg', 'ok-2.jpg']) {
      await File('${root.path}$sep$name').writeAsBytes(<int>[1, 2, 3]);
    }

    final SystemPlatformPorts ports = SystemPlatformPorts(
      settingsPath: '${root.path}${sep}settings.json',
      defaultAlias: 'Me',
      defaultSaveDirectory: root.path,
    );
    final SendFolderSelection selection =
        await ports.describeFolderForSending(root.path);

    expect(selection.outcome, PickSendFolderOutcome.picked);
    expect(
      <String>[for (final String path in selection.paths) path.split(sep).last],
      <String>['ok-1.jpg', 'ok-2.jpg'],
      reason: '★ the file the receiver cannot place is gone; the rest is sent',
    );
    expect(selection.skippedPathTooLong, 1);
    expect(selection.relativePaths, <String>['ok-1.jpg', 'ok-2.jpg'],
        reason: 'and the positions still line up with the paths');
    expect(selection.availableCount, 2);
    expect(selection.canSend, isTrue);
  });
}
