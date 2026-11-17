/// 0.2.54 — **manual probe**: "I typed an IP, is there a lanlink peer there?"
///
/// ## The situation this feature exists for
///
/// Discovery has two legs (UDP multicast + subnet broadcast). A locked-down AP
/// — client isolation, a firewall between the two machines, a hotspot with
/// multicast filtering — can eat **both**, and then two perfectly reachable
/// machines cannot see each other at all. The user's only escape is to type the
/// peer's address. This file pins the one capability that escape needs: dial one
/// `IP[:port]`, and if a lanlink peer answers, it becomes a **live peer**.
///
/// ## Why "it became a live peer" is the only thing worth asserting
///
/// Sending does not read an address from the database. `selectors.dart`'s
/// `mergeDeviceCards` copies a **live** peer's `address`/`port` over the card's
/// `lastIp`/`lastPort`, and `LanTransferService._clientFor` dials from the card
/// (`host: peer.lastIp, port: peer.lastPort`, both required, port > 0). So
/// "the device is sendable" is exactly:
///
/// 1. the peer is in the registry (`discovery.online`), and
/// 2. the merged card carries the probed address, the peer's port, `isOnline`.
///
/// Judgement 1 asserts all three, through the **real** adapter and the **real**
/// `core.PeerRegistry` — not through the fake, which would only prove the fake
/// works. `FakePeerDiscovery`'s own contract is judged separately at the end
/// (that is what the next step's UI tests will stand on).
///
/// ## Why the fingerprint judgement is separate (judgement 2)
///
/// The peer's frame carries a self-declared `fp`, and it is a **claim**. The
/// authoritative value is the SHA-256 of the certificate read out of the TLS
/// handshake (`PeerClient.observedFingerprint`). A registry keyed on the claim
/// would let a peer be dialled under an identity it never proved — and would put
/// a device in the list under a fingerprint that every *other* discovery leg
/// (which does use the observed value) treats as a different device. Judgement 2
/// builds exactly the disagreement: frame says one thing, the certificate says
/// another.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/lan_peer_discovery.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';
import 'package:lanlink_app/domain/selectors.dart';
import 'package:lanlink_core/lanlink_core.dart' as core;

import 'support/fakes.dart';

/// The peer's real identity: what its certificate hashes to.
final String _kPeerFp = 'A1' * 32;

/// What the same peer's *frame* claims in judgement 2. Different on purpose, and
/// nothing may ever key a device on it.
final String _kClaimedFp = 'DEADBEEF' * 8;

/// The port the fake peer says its receiver listens on.
const int _kPeerPort = 49494;

/// The address the fabric of these tests dials.
const String _kHost = '192.168.1.23';

/// One `core.DeviceInfo` as a peer would send it back in `hello.reply`.
core.DeviceInfo _reply({
  required String fingerprint,
  String alias = 'Alice Phone',
  int port = _kPeerPort,
}) =>
    core.DeviceInfo(
      alias: alias,
      fingerprint: fingerprint,
      port: port,
      deviceType: core.DeviceType.mobile,
    );

/// A `core.PeerClient` whose `/hello` round trip is decided by the test.
///
/// **Why a client double and not a socket:** the whole point is to model peers
/// that are *not on this machine* (a phone, a box behind a firewall) and to model
/// the TLS outcomes that a plain `SocketException` cannot reproduce — an
/// observable fingerprint that disagrees with the frame, a missing fingerprint, a
/// signed-but-not-lanlink peer. It also never opens a connection, so the suite
/// stays hermetic.
class _FakeProbeClient extends core.PeerClient {
  _FakeProbeClient({
    required super.host,
    required super.port,
    this.reply,
    this.observed,
    this.failure,
    this.neverReplies = false,
  }) : super(allowUnknownCertificate: true);

  /// The frame the peer would answer with, when it answers.
  final core.DeviceInfo? reply;

  /// What the (pretend) TLS handshake measured. `null` models "a peer that
  /// answered but presented nothing we could hash".
  final String? observed;

  /// Thrown instead of answering — the transport / TLS failure being modelled.
  final Object? failure;

  /// Never completes: a black-holed address.
  final bool neverReplies;

  @override
  String? get observedFingerprint => observed;

  @override
  Future<core.DeviceInfo> register({required core.DeviceInfo self}) {
    final Object? error = failure;
    if (error != null) {
      return Future<core.DeviceInfo>.error(error);
    }
    if (neverReplies) {
      return Completer<core.DeviceInfo>().future;
    }
    return Future<core.DeviceInfo>.value(reply!);
  }
}

/// What one probe attempt dialled, recorded by the seam.
class _Dial {
  const _Dial(this.host, this.port);

  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

/// A real `LanPeerDiscovery` over a real `core.PeerRegistry`, with the probe's
/// HTTP client replaced by [_FakeProbeClient].
///
/// The adapter is **not started**: nothing here needs multicast, and starting it
/// would bind sockets. `probeHost` is deliberately usable without `start()` —
/// that is the case it exists for (discovery failed, user types an address).
class _Seam {
  _Seam(this.certificate) {
    discovery = LanPeerDiscovery(
      certificate: certificate,
      registry: registry,
      clock: FixedClock(fixedEpoch),
      selfPort: 53317,
      alias: 'self',
      registrations: const Stream<DiscoveredPeer>.empty(),
      onLog: logs.add,
      probeClient: _buildClient,
    );
    _sub = discovery.events.listen(events.add);
  }

  final core.DeviceCertificate certificate;
  final core.PeerRegistry registry = core.PeerRegistry();
  final List<String> logs = <String>[];
  final List<_Dial> dials = <_Dial>[];
  final List<DiscoveryEvent> events = <DiscoveryEvent>[];

  late final LanPeerDiscovery discovery;
  late final StreamSubscription<DiscoveryEvent> _sub;

  /// The next probe's behaviour. `null` means "build the real client", which is
  /// how the one genuine socket test (a refused connection) is wired.
  _FakeProbeClient Function(String host, int port)? respond;

  core.PeerClient _buildClient({required String host, required int port}) {
    dials.add(_Dial(host, port));
    final _FakeProbeClient Function(String, int)? build = respond;
    if (build == null) {
      return core.PeerClient(
        host: host,
        port: port,
        allowUnknownCertificate: true,
        certificate: certificate,
        onLog: logs.add,
      );
    }
    return build(host, port);
  }

  /// What the home screen would render, from the live peers this adapter reports.
  List<PeerDevice> cards(FakeBackend backend) => mergeDeviceCards(
        online: discovery.online,
        conversations: backend.repo.conversations(),
        devices: backend.repo.devices(),
      );

  Future<void> dispose() async {
    await _sub.cancel();
    await discovery.dispose();
    await registry.dispose();
  }
}

/// A backend with one **offline, address-less** device row for [_kPeerFp] — the
/// state the user is looking at when they decide to type an address.
FakeBackend _backend() => FakeBackend(
      devices: <PeerDevice>[
        PeerDevice(
          fingerprint: _kPeerFp,
          alias: 'Alice Phone',
          kind: DeviceKind.mobile,
          isOnline: false,
          lastSeenAt: fixedEpoch,
        ),
      ],
    );

void main() {
  late core.DeviceCertificate certificate;

  setUpAll(() {
    // One RSA keygen for the whole file (~a second, once).
    certificate =
        core.DeviceCertificate.generate(commonName: 'lanlink-manual-probe-test');
  });

  group('1. a probed peer becomes sendable', () {
    test('the card turns online, at the probed address, with the peer\'s port',
        () async {
      final FakeBackend backend = _backend();
      addTearDown(backend.dispose);
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            reply: _reply(fingerprint: _kPeerFp),
            observed: _kPeerFp,
          );

      // Precondition: without a probe the device is in the list but not
      // sendable — no live peer, no address, so nothing can be dialled.
      expect(seam.cards(backend).single.isOnline, isFalse);
      expect(seam.cards(backend).single.lastIp, isNull);

      final ManualProbeResult result =
          await seam.discovery.probeHost('$_kHost:$_kPeerPort');

      expect(result, isA<ManualProbeOk>(),
          reason: 'a hello.reply from the address means the probe succeeded');
      final ManualProbeOk ok = result as ManualProbeOk;
      expect(ok.fingerprint, _kPeerFp);
      expect(ok.alias, 'Alice Phone');
      expect(ok.port, _kPeerPort);
      expect(ok.host, _kHost);
      expect(seam.dials.single.toString(), '$_kHost:$_kPeerPort',
          reason: 'the address the user typed is the address that gets dialled');

      // (a) The registry is where "is it live?" is answered.
      expect(seam.registry.byFingerprint(_kPeerFp), isNotNull,
          reason: 'the peer must be a live peer, not just a returned value');
      expect(seam.registry.byFingerprint(_kPeerFp)!.address, _kHost);

      // (b) The merged card is what the send path reads its destination from.
      final List<PeerDevice> cards = seam.cards(backend);
      expect(cards, hasLength(1),
          reason: 'the probe must not invent a second card for one device');
      final PeerDevice card = cards.single;
      expect(card.isOnline, isTrue);
      expect(card.lastIp, _kHost,
          reason: 'mergeDeviceCards takes lastIp from the live peer.address');
      expect(card.lastPort, _kPeerPort,
          reason: 'mergeDeviceCards takes lastPort from the live peer.port');
      // (c) Sendable: `canSend` is `lastPort != 0`, and `_clientFor` additionally
      // needs a non-empty host — both are asserted above.
      expect(card.canSend, isTrue);
      expect(card.isDialable, isTrue);
    });

    test('probing this device does not put itself in the device list', () async {
      final FakeBackend backend = _backend();
      addTearDown(backend.dispose);
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      // The peer at the typed address turns out to be us (a plausible typo, and
      // the classic "which of these two IPs am I?" mistake).
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            reply: _reply(
              fingerprint: certificate.fingerprint,
              alias: 'self',
              port: 53317,
            ),
            observed: certificate.fingerprint,
          );

      final ManualProbeResult result =
          await seam.discovery.probeHost('127.0.0.1');

      expect(result, isA<ManualProbeOk>(),
          reason: 'the probe did reach a lanlink peer — that part is true');
      expect(seam.registry.length, 0,
          reason: 'but a device row for ourselves would be a phantom device: '
              'every other discovery leg filters self out for that reason');
      expect(seam.cards(backend).single.isOnline, isFalse);
    });
  });

  group('2. the fingerprint is the measured one, never the claimed one', () {
    test('the registry is keyed on the TLS-observed fingerprint', () async {
      final FakeBackend backend = _backend();
      addTearDown(backend.dispose);
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      // The peer's frame lies (or is simply stale); the certificate does not.
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            reply: _reply(fingerprint: _kClaimedFp),
            observed: _kPeerFp,
          );

      final ManualProbeResult result = await seam.discovery.probeHost(_kHost);

      expect(result, isA<ManualProbeOk>());
      expect((result as ManualProbeOk).fingerprint, _kPeerFp,
          reason: 'observedFingerprint is measured from the certificate; the '
              'frame\'s `fp` is only a claim');
      expect(seam.registry.byFingerprint(_kPeerFp), isNotNull,
          reason: 'the device must be filed under the identity it proved');
      expect(seam.registry.byFingerprint(_kClaimedFp), isNull,
          reason: 'a claimed fingerprint must never create a second identity');
      expect(seam.discovery.online.single.fingerprint, _kPeerFp);
      // The card that the send path reads must also be the observed one, or the
      // probe would have "worked" while leaving the user with an unsendable card.
      expect(seam.cards(backend).single.fingerprint, _kPeerFp);
      expect(seam.cards(backend).single.isOnline, isTrue);
    });
  });

  group('3. the four failure classes', () {
    test('unreachable — a refused connection', () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            failure: const SocketException('Connection refused'),
          );

      final ManualProbeResult result = await seam.discovery.probeHost(_kHost);

      expect(result, isA<ManualProbeError>());
      expect((result as ManualProbeError).reason, ManualProbeFailure.unreachable);
      expect(result.detail, contains('Connection refused'));
      expect(seam.registry.length, 0);
    });

    test('unreachable — a real socket nobody is listening on', () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      // A port that was bound and then released: something guarantees it is
      // closed, and the refusal is produced by the OS, not by a double.
      final ServerSocket socket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int port = socket.port;
      await socket.close();

      final ManualProbeResult result =
          await seam.discovery.probeHost('127.0.0.1:$port');

      expect(result, isA<ManualProbeError>());
      expect((result as ManualProbeError).reason, ManualProbeFailure.unreachable,
          reason: 'no listener is the ordinary "对方没开 or 不在这个 IP" case');
      expect(seam.registry.length, 0);
    });

    test('certificateMismatch — the TLS handshake fails', () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            failure: const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
          );

      final ManualProbeResult result = await seam.discovery.probeHost(_kHost);

      expect(result, isA<ManualProbeError>());
      expect((result as ManualProbeError).reason,
          ManualProbeFailure.certificateMismatch);
      expect(seam.registry.length, 0,
          reason: 'a peer whose certificate we could not read must not be filed '
              'under any identity at all');
    });

    test('certificateMismatch — a reply with no observable certificate',
        () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            reply: _reply(fingerprint: _kClaimedFp),
            observed: null,
          );

      final ManualProbeResult result = await seam.discovery.probeHost(_kHost);

      expect(result, isA<ManualProbeError>());
      expect((result as ManualProbeError).reason,
          ManualProbeFailure.certificateMismatch,
          reason: 'without an observed fingerprint there is only the claim, and '
              'a claim is never enough to identify a device');
      expect(seam.registry.length, 0);
    });

    test('notLanlink — a TLS peer that does not answer like lanlink', () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            failure: core.PeerHttpException(
              200,
              'hello failed',
              '<html><body>some other service</body></html>',
            ),
          );

      final ManualProbeResult result = await seam.discovery.probeHost(_kHost);

      expect(result, isA<ManualProbeError>());
      expect((result as ManualProbeError).reason, ManualProbeFailure.notLanlink,
          reason: 'the connection and the handshake worked, so this is not '
              '"unreachable" — it is the wrong peer / the wrong port');
      expect(seam.registry.length, 0);
    });

    test('notLanlink — a peer whose frame identity contradicts its certificate',
        () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      // Exactly what `PeerClient._enforceFrameIdentity` throws (R-SEC-1).
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            failure: core.PeerHttpException(
              200,
              'peer identity mismatch (R-SEC-1): frame fp=$_kClaimedFp != '
                  'TLS-observed $_kPeerFp',
            ),
          );

      final ManualProbeResult result = await seam.discovery.probeHost(_kHost);

      expect(result, isA<ManualProbeError>());
      expect((result as ManualProbeError).reason,
          ManualProbeFailure.certificateMismatch,
          reason: 'a peer that lies about who it is is a certificate problem, '
              'not a "wrong port" problem — the UI must not offer to send to it');
      expect(seam.registry.length, 0);
    });

    test('badInput — nothing shaped like IP[:port] is ever dialled', () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            reply: _reply(fingerprint: _kPeerFp),
            observed: _kPeerFp,
          );

      const List<String> inputs = <String>[
        '',
        '   ',
        '192.168.1.300', // not an IPv4 literal
        'abc', // not an address at all
        '1.2.3.4:0', // port 0 is not a dial target
        '1.2.3.4:65536', // out of range
        '1.2.3.4:', // empty port
        ':49494', // empty host
        '[fe80::1]:abc', // non-numeric port
      ];

      for (final String input in inputs) {
        final ManualProbeResult result = await seam.discovery.probeHost(input);
        expect(result, isA<ManualProbeError>(), reason: 'input "$input"');
        expect((result as ManualProbeError).reason, ManualProbeFailure.badInput,
            reason: 'input "$input"');
      }
      expect(seam.dials, isEmpty,
          reason: 'a malformed input must not produce a connection attempt — '
              'that is the difference between "typo" and "no peer"');
    });
  });

  group('4. host:port parsing', () {
    test('the default port, an explicit port, and IPv6 keep their shape',
        () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            reply: _reply(fingerprint: _kPeerFp),
            observed: _kPeerFp,
          );

      const List<List<String>> cases = <List<String>>[
        // input, dialled host, dialled port
        <String>['1.2.3.4', '1.2.3.4', '49494'],
        <String>['1.2.3.4:5000', '1.2.3.4', '5000'],
        <String>[' 1.2.3.4:5000 ', '1.2.3.4', '5000'],
        <String>['[fe80::1]:49494', 'fe80::1', '49494'],
        <String>['[fe80::1]', 'fe80::1', '49494'],
        // A bare IPv6 literal cannot carry a port (`fe80::1:49494` would be
        // ambiguous), so the whole string is the host.
        <String>['fe80::1', 'fe80::1', '49494'],
      ];

      for (final List<String> testCase in cases) {
        final ManualProbeResult result =
            await seam.discovery.probeHost(testCase[0]);
        expect(result, isA<ManualProbeOk>(), reason: 'input "${testCase[0]}"');
        expect(seam.dials.last.host, testCase[1],
            reason: 'input "${testCase[0]}"');
        expect(seam.dials.last.port, int.parse(testCase[2]),
            reason: 'input "${testCase[0]}"');
        expect((result as ManualProbeOk).host, testCase[1],
            reason: 'the result reports the address that was dialled');
      }
    });
  });

  group('5. a probe cannot hang', () {
    test('a peer that never answers gives up in bounded time', () async {
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            neverReplies: true,
          );

      final Stopwatch stopwatch = Stopwatch()..start();
      final ManualProbeResult result = await seam.discovery.probeHost(_kHost);
      stopwatch.stop();

      expect((result as ManualProbeError).reason, ManualProbeFailure.unreachable,
          reason: 'silence is indistinguishable from unreachable, and pretending '
              'otherwise would keep the user waiting');
      expect(stopwatch.elapsed, lessThanOrEqualTo(const Duration(seconds: 4)),
          reason: 'the probe must carry its own deadline; measured '
              '${stopwatch.elapsedMilliseconds}ms');
    });
  });

  group('6. a probe persists nothing', () {
    test('no device row and no conversation are written', () async {
      final FakeBackend backend = _backend();
      addTearDown(backend.dispose);
      final _Seam seam = _Seam(certificate);
      addTearDown(seam.dispose);
      seam.respond = (String host, int port) => _FakeProbeClient(
            host: host,
            port: port,
            reply: _reply(fingerprint: _kPeerFp),
            observed: _kPeerFp,
          );
      final int devicesBefore = backend.repo.devices().length;
      final int conversationsBefore = backend.repo.conversations().length;

      final ManualProbeResult result = await seam.discovery.probeHost(_kHost);

      expect(result, isA<ManualProbeOk>(),
          reason: 'the probe itself must have succeeded, or the judgement '
              'below would be vacuous');
      expect(seam.discovery.online.single.fingerprint, _kPeerFp,
          reason: 'and it did reach the live peer set');
      expect(backend.repo.devices().length, devicesBefore,
          reason: 'discovery state is volatile: `devices.last_ip` is not where '
              'addresses live (nothing in production ever writes it), so a '
              'probe must not start writing rows either');
      expect(backend.repo.device(_kPeerFp)?.lastIp, isNull);
      expect(backend.repo.conversations().length, conversationsBefore,
          reason: 'a device that has never exchanged a message has no thread');
      expect(
          backend.repo.messagesByStatus(<MessageStatus>{
            ...MessageStatus.values,
          }),
          isEmpty);
    });
  });

  group('7. the fake says the same thing (what the UI tests will stand on)',
      () {
    test('an Ok outcome appears in online, emits, and merges as online',
        () async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      final FakePeerDiscovery discovery = backend.discovery;
      final List<DiscoveryEvent> events = <DiscoveryEvent>[];
      final StreamSubscription<DiscoveryEvent> sub =
          discovery.events.listen(events.add);
      addTearDown(sub.cancel);

      discovery.setManualProbeOutcome(
        const ManualProbeOk(
          fingerprint: 'A1A1A1A1',
          alias: 'Alice Phone',
          port: _kPeerPort,
          host: _kHost,
        ),
      );
      expect(discovery.online, isEmpty);

      final ManualProbeResult result =
          await discovery.probeHost('$_kHost:$_kPeerPort');
      await Future<void>.delayed(Duration.zero);

      expect(result, isA<ManualProbeOk>());
      expect(discovery.probeHostCalls, <String>['$_kHost:$_kPeerPort'],
          reason: 'the fake records the raw input, so a test can judge that the '
              'entry point passed on exactly what the user typed');
      expect(discovery.online, hasLength(1));
      expect(discovery.online.single.address, _kHost);
      expect(discovery.online.single.port, _kPeerPort);
      expect(events.whereType<PeerAppeared>(), hasLength(1),
          reason: 'the UI repaints off the event stream, not off a poll');

      final List<PeerDevice> cards = mergeDeviceCards(
        online: discovery.online,
        conversations: backend.repo.conversations(),
        devices: backend.repo.devices(),
      );
      expect(cards.single.isOnline, isTrue);
      expect(cards.single.lastIp, _kHost);
      expect(cards.single.lastPort, _kPeerPort);
      expect(cards.single.canSend, isTrue);
    });

    test('an error outcome adds nothing to the list', () async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      final FakePeerDiscovery discovery = backend.discovery;
      discovery.setManualProbeOutcome(
        const ManualProbeError(ManualProbeFailure.notLanlink),
      );

      final ManualProbeResult result = await discovery.probeHost(_kHost);

      expect(result, isA<ManualProbeError>());
      expect(discovery.online, isEmpty,
          reason: 'a failed probe must leave the device list exactly as it was');
    });

    test('an un-scheduled probe is loud, not a silent "some failure"', () async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);

      await expectLater(
        backend.discovery.probeHost(_kHost),
        throwsA(isA<StateError>()),
        reason: 'a fake that invented an outcome would let a broken UI test pass '
            'by accident, so it refuses instead',
      );
    });
  });
}
