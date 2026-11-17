/// Unit tests for `selectors.dart::MessageTransferProgress` — the **single**
/// message-level progress aggregate (0.2.49).
///
/// The type exists because one message can carry N attachments (a multi-select is
/// **one** `MessageRecord` + N `MessageFileRecord`s) and the bubble used to draw
/// the progress of `files.first` alone: once that file finished, the bar froze at
/// 100 % for the whole batch — 「只显示某一个视频的传输过程，然后就一直呆在那」.
///
/// Each case below can fail in a way a reader can name:
///
/// * the sum is the sum, and a partly-uploaded batch is **not** 100 %;
/// * the "which file is in flight" index is the **first** attachment that is not
///   home, 1-based — the caption 「第 k/N 个」;
/// * a one-attachment message returns that attachment's row **verbatim**, so the
///   refactor cannot move a single-file bubble by one byte (including `-1`
///   "unknown total" and the row's `error`, which the two notes read);
/// * a folder's numbers and a flat multi-select's numbers come from the same
///   function, which is what stops the two from drifting apart again.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';

FileAttachment _file(String id, int size) => FileAttachment(
      id: id,
      messageId: 'm',
      fileName: '$id.bin',
      size: size,
      sha256: '00',
      localPath: '/src/$id.bin',
    );

TransferProgress _row(String id, int done, int total) =>
    TransferProgress(fileId: id, bytesDone: done, bytesTotal: total);

/// A lookup over [rows], indexed by file id.
TransferProgress? Function(String) _lookup(List<TransferProgress> rows) {
  final Map<String, TransferProgress> byId = <String, TransferProgress>{
    for (final TransferProgress row in rows) row.fileId: row,
  };
  return (String fileId) => byId[fileId];
}

void main() {
  group('MessageTransferProgress.of', () {
    test('no attachments → the empty aggregate, and no bar', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        const <FileAttachment>[],
        progressOf: _lookup(const <TransferProgress>[]),
      );
      expect(progress.fileCount, 0);
      expect(progress.filesDone, 0);
      expect(progress.currentIndex, 0);
      expect(progress.bar, isNull);
      expect(progress.ordinal, isNull);
      expect(progress.isMultiFile, isFalse);
      expect(progress.fraction, isNull);
    });

    test('判据 1: 2 个附件，第 1 个 100%、第 2 个 30% → 1300/2000, 第 2/2 个', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 1000), _file('b', 1000)],
        progressOf: _lookup(<TransferProgress>[
          _row('a', 1000, 1000),
          _row('b', 300, 1000),
        ]),
      );

      expect(progress.bytesDone, 1300);
      expect(progress.bytesTotal, 2000);
      // The batch is not done: one file of two is.
      expect(progress.filesDone, 1);
      expect(progress.currentIndex, 2);
      expect(progress.ordinal, '第 2/2 个');
      expect(progress.fraction, closeTo(0.65, 1e-12));
      expect(progress.bar, isNotNull);
      expect(progress.bar!.bytesDone, 1300);
      expect(progress.bar!.bytesTotal, 2000);
      // The bar's id is the file being uploaded — not `files.first`.
      expect(progress.bar!.fileId, 'b');
    });

    test('判据 2: 两个等大文件里的第一个走到 50% → 总进度 25%', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 1000), _file('b', 1000)],
        progressOf: _lookup(<TransferProgress>[
          _row('a', 500, 1000),
          _row('b', 0, 1000),
        ]),
      );
      expect(progress.bytesDone, 500);
      expect(progress.bytesTotal, 2000);
      expect(progress.fraction, closeTo(0.25, 1e-12));
      expect(progress.ordinal, '第 1/2 个');
    });

    test('三件的批处理：序号是**第一个没到齐**的附件，不是第一个', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 100), _file('b', 100), _file('c', 100)],
        progressOf: _lookup(<TransferProgress>[
          _row('a', 100, 100),
          _row('b', 100, 100),
          _row('c', 0, 100),
        ]),
      );
      expect(progress.filesDone, 2);
      expect(progress.currentIndex, 3);
      expect(progress.ordinal, '第 3/3 个');
      expect(progress.bytesDone, 200);
      expect(progress.fraction, closeTo(2 / 3, 1e-12));
    });

    test('全部到齐：序号归 0，于是不画「第 k/N 个」', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 100), _file('b', 100)],
        progressOf: _lookup(<TransferProgress>[
          _row('a', 100, 100),
          _row('b', 100, 100),
        ]),
      );
      expect(progress.filesDone, 2);
      expect(progress.currentIndex, 0);
      expect(
        progress.ordinal,
        isNull,
        reason: '「第 2/2 个」 would claim file 2 is still uploading',
      );
      expect(progress.fraction, closeTo(1.0, 1e-12));
    });

    test('一行都没有（传输还没开始）→ 没有 bar，但仍知道 N 和总字节', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 1000), _file('b', 500)],
        progressOf: _lookup(const <TransferProgress>[]),
      );
      expect(progress.bar, isNull);
      expect(progress.bytesDone, 0);
      expect(progress.bytesTotal, 1500);
      expect(progress.filesDone, 0);
      expect(progress.currentIndex, 1);
      expect(progress.ordinal, '第 1/2 个');
    });

    test('判据 3: 单附件 → 就是库里那一行，逐字段相同（含 error / 未知总量）', () {
      const TransferProgress row =
          TransferProgress(fileId: 'a', bytesDone: 300, bytesTotal: -1);
      final MessageTransferProgress unknownTotal =
          MessageTransferProgress.of(
        <FileAttachment>[_file('a', -1)],
        progressOf: _lookup(<TransferProgress>[row]),
      );
      expect(
        unknownTotal.bar,
        row,
        reason: 'a one-file bubble must be untouched by the aggregation',
      );
      expect(unknownTotal.isMultiFile, isFalse);
      expect(unknownTotal.ordinal, isNull);

      const TransferProgress failed = TransferProgress(
        fileId: 'a',
        bytesDone: 10,
        bytesTotal: 100,
        error: '连接中断',
      );
      final MessageTransferProgress withError = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 100)],
        progressOf: _lookup(<TransferProgress>[failed]),
      );
      expect(withError.bar, failed);
      expect(withError.bar!.error, '连接中断');
    });

    test('单附件、还没有进度行 → 没有 bar（和改动前一致）', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 100)],
        progressOf: _lookup(const <TransferProgress>[]),
      );
      expect(progress.bar, isNull);
      expect(progress.bytesTotal, 100);
    });

    test('多附件：错误取**第一个**报错的附件，不是 files.first 的', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 100), _file('b', 100), _file('c', 100)],
        progressOf: _lookup(<TransferProgress>[
          _row('a', 100, 100),
          _row('b', 40, 100),
          const TransferProgress(
            fileId: 'c',
            bytesDone: 0,
            bytesTotal: 100,
            error: 'SocketException: 连接中断',
          ),
        ]),
      );
      expect(progress.bar?.error, 'SocketException: 连接中断');
      expect(progress.filesDone, 1);
      expect(progress.currentIndex, 2);
    });

    test('分子被夹到分母以内：一个虚高的 bytes_done 不能把批处理推过 100%', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', 100), _file('b', 100)],
        progressOf: _lookup(<TransferProgress>[
          _row('a', 400, 100),
          _row('b', 50, 100),
        ]),
      );
      expect(progress.bytesTotal, 200);
      expect(progress.bytesDone, 150);
      expect(progress.fraction, closeTo(0.75, 1e-12));
      expect(progress.filesDone, 1);
    });

    test('大小未知（-1）的附件用行里的总量，而不是 0 字节', () {
      final MessageTransferProgress progress = MessageTransferProgress.of(
        <FileAttachment>[_file('a', -1), _file('b', 100)],
        progressOf: _lookup(<TransferProgress>[
          _row('a', 50, 200),
          _row('b', 100, 100),
        ]),
      );
      expect(progress.bytesTotal, 300);
      expect(progress.bytesDone, 150);
      expect(progress.fraction, closeTo(0.5, 1e-12));
    });
  });

  group('summarizeFolder (delegates to the same aggregate)', () {
    test('判据 4: 声明 5 个、只有 3 行、2 个到齐 → 2/5，字节仍是这 3 个的和', () {
      final FolderProgress progress = summarizeFolder(
        declaredCount: 5,
        files: <FileAttachment>[_file('a', 100), _file('b', 100), _file('c', 100)],
        progressOf: _lookup(<TransferProgress>[
          _row('a', 100, 100),
          _row('b', 100, 100),
          _row('c', 30, 100),
        ]),
      );
      expect(progress.done, 2);
      expect(progress.total, 5);
      expect(progress.bytesTotal, 300);
      expect(progress.bytesDone, 230);
    });

    test('没有声明计数（旧的平铺多选）→ 分母回落到行数，绝不打印 0', () {
      final FolderProgress progress = summarizeFolder(
        declaredCount: 0,
        files: <FileAttachment>[_file('a', 10), _file('b', 10)],
        progressOf: _lookup(<TransferProgress>[_row('a', 10, 10)]),
      );
      expect(progress.total, 2);
      expect(progress.done, 1);
    });
  });
}
