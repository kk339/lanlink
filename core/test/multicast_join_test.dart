import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// `joinMulticast` fails for three very different reasons, and they used to
/// share the word `failed` — on **every** re-join, which is how a real failure
/// gets buried in noise. Only the last of these must alarm.
void main() {
  OSError osError(int code, String message) => OSError(message, code);

  test('EADDRINUSE (98): re-joining an interface we are already a member of',
      () {
    // The phone's log: `joinMulticast … failed: Address already in use, errno = 98`.
    expect(
      classifyJoinError(osError(98, 'Address already in use')),
      MulticastJoinOutcome.alreadyMember,
    );
  });

  test('WSAEADDRINUSE (10048) is the same case on Windows', () {
    expect(
      classifyJoinError(osError(10048, 'Address already in use')),
      MulticastJoinOutcome.alreadyMember,
    );
  });

  test('WSAEINVAL (10022): the interface cannot carry multicast at all', () {
    // The PC's log: `joinMulticast … failed: 提供了一个无效的参数, errno = 10022`
    // — a virtual/VPN adapter, which will never accept the join.
    expect(
      classifyJoinError(osError(10022, '提供了一个无效的参数')),
      MulticastJoinOutcome.unsupported,
    );
  });

  test('falls back to the message when the code is not one we know', () {
    expect(
      classifyJoinError(osError(1234, 'Address already in use')),
      MulticastJoinOutcome.alreadyMember,
    );
    expect(
      classifyJoinError(osError(1234, 'Invalid argument')),
      MulticastJoinOutcome.unsupported,
    );
  });

  test('every other error remains a failure — the one case that must alarm',
      () {
    expect(
      classifyJoinError(osError(101, 'Network is unreachable')),
      MulticastJoinOutcome.failed,
    );
    expect(
      classifyJoinError(StateError('boom')),
      MulticastJoinOutcome.failed,
    );
  });
}
