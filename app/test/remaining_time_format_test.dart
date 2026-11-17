/// Copy tests for the remaining-time line (0.2.25).
///
/// The three shapes and the `即将完成` floor are pinned here because they are the
/// app's only wording for "how long" — a wrong boundary (59 s → `剩 1 分`) or a
/// sloppy unit reads as a bug in the estimate itself.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/ui/format.dart';

void main() {
  group('remainingTimeText', () {
    test('under a minute: seconds', () {
      expect(remainingTimeText(const Duration(seconds: 45)), '剩 45 秒');
      expect(remainingTimeText(const Duration(seconds: 2)), '剩 2 秒');
      // 59.9 s is still "under a minute" — it must not round up into 分.
      expect(
        remainingTimeText(
          const Duration(seconds: 59, milliseconds: 900),
        ),
        '剩 59 秒',
      );
    });

    test('one second or less (and anything negative): 即将完成', () {
      expect(remainingTimeText(const Duration(seconds: 1)), '即将完成');
      expect(remainingTimeText(const Duration(milliseconds: 400)), '即将完成');
      expect(remainingTimeText(Duration.zero), '即将完成');
      expect(remainingTimeText(const Duration(seconds: -5)), '即将完成');
    });

    test('under an hour: minutes and seconds', () {
      expect(remainingTimeText(const Duration(seconds: 200)), '剩 3 分 20 秒');
      expect(remainingTimeText(const Duration(seconds: 60)), '剩 1 分');
      expect(remainingTimeText(const Duration(seconds: 3599)), '剩 59 分 59 秒');
    });

    test('an hour or more: hours and minutes', () {
      expect(remainingTimeText(const Duration(seconds: 3900)), '剩 1 小时 5 分');
      expect(remainingTimeText(const Duration(hours: 2)), '剩 2 小时');
      expect(
        remainingTimeText(const Duration(hours: 99, minutes: 59)),
        '剩 99 小时 59 分',
      );
    });
  });
}
