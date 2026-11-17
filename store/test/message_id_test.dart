import 'package:lanlink_store/lanlink_store.dart';
import 'package:test/test.dart';

// The vectors of spec §5.6.4. Every expected value was pre-computed with
// Python hashlib, so these assertions are a regression guard, not a restatement
// of the implementation.
const String fp =
    '580AC9D0BEAB379FEBCE64B56775E4A4C24ECC2993AD974F30176DBF7CF74A07';
const String shaA =
    '9162A3AEC1BC085B75A47FBCD3761B5677DA4A9022E3AE083C52024B7C728752';
const String shaB =
    '971941F4E9A533CD3EB7790A95225D8F4E12914A5423BABBAF6F440C47C6E53E';

const String v1Id =
    '9AF5C671087BA2B26D2F4AA0173EFA74A8952ED01B5CAE047D085882885D6A0D';
const String v2Id =
    '4B9B294A74B67101C10EF17AE73977F206A4B94895B3751DF0BDDD449CAC6DA7';

// The V1 body "ni hao, lanlink" written with ASCII escapes so this file stays
// pure ASCII.
const String v1Body = '\u4f60\u597d\uff0clanlink';

void main() {
  test('V1 - text/out content key and id', () {
    final contentKey = contentKeyForText(v1Body);
    expect(
      contentKey,
      '39234CF66771B436F47CDEC1BA692314AC486DC20E1607437212D89B6DF63247',
    );
    final id = computeMessageId(
      fingerprint: fp,
      direction: MessageDirection.outgoing,
      kind: MessageKind.text,
      eventNonce: 'nonce-text-1',
      contentKey: contentKey,
    );
    expect(id, v1Id);
  });

  test('V2 - single file/out', () {
    final id = _fileId(
      fingerprint: fp,
      direction: MessageDirection.outgoing,
      fileIds: const <String>['file-id-1'],
      files: const <FileContentKey>[
        FileContentKey(fileName: 'a', size: 9, sha256: shaA),
      ],
    );
    expect(id, v2Id);
  });

  test('V3 - two files, order-invariant', () {
    final forward = _fileId(
      fingerprint: fp,
      direction: MessageDirection.outgoing,
      fileIds: const <String>['file-id-1', 'file-id-2'],
      files: const <FileContentKey>[
        FileContentKey(fileName: 'a', size: 9, sha256: shaA),
        FileContentKey(fileName: 'b', size: 9, sha256: shaB),
      ],
    );
    final reversed = _fileId(
      fingerprint: fp,
      direction: MessageDirection.outgoing,
      fileIds: const <String>['file-id-2', 'file-id-1'],
      files: const <FileContentKey>[
        FileContentKey(fileName: 'b', size: 9, sha256: shaB),
        FileContentKey(fileName: 'a', size: 9, sha256: shaA),
      ],
    );
    expect(
      forward,
      '52BA0380C2B35A5D656E39E5911DBB71264976D9F205E90679BADAB03CC5B5FF',
    );
    expect(reversed, forward, reason: 'file order must not change the id');
  });

  test('V4 - a different event id yields a different message id', () {
    final id = _fileId(
      fingerprint: fp,
      direction: MessageDirection.outgoing,
      fileIds: const <String>['file-id-9'],
      files: const <FileContentKey>[
        FileContentKey(fileName: 'a', size: 9, sha256: shaA),
      ],
    );
    expect(
      id,
      '17260DF82947055366B667F74320AB30167C7C9FE074F8C89FAFA73A935B5A45',
    );
    expect(id, isNot(v2Id));
  });

  test('V5 - a retry recomputes the identical id', () {
    final first = _fileId(
      fingerprint: fp,
      direction: MessageDirection.outgoing,
      fileIds: const <String>['file-id-1'],
      files: const <FileContentKey>[
        FileContentKey(fileName: 'a', size: 9, sha256: shaA),
      ],
    );
    final second = _fileId(
      fingerprint: fp,
      direction: MessageDirection.outgoing,
      fileIds: const <String>['file-id-1'],
      files: const <FileContentKey>[
        FileContentKey(fileName: 'a', size: 9, sha256: shaA),
      ],
    );
    expect(second, first);
    expect(second, v2Id);
  });

  test('V6 - a lowercase fingerprint is normalised before hashing', () {
    final id = computeMessageId(
      fingerprint: fp.toLowerCase(),
      direction: MessageDirection.outgoing,
      kind: MessageKind.text,
      eventNonce: 'nonce-text-1',
      contentKey: contentKeyForText(v1Body),
    );
    expect(id, v1Id);
  });

  test('V7 - direction participates in the identity', () {
    final id = _fileId(
      fingerprint: fp,
      direction: MessageDirection.incoming,
      fileIds: const <String>['file-id-1'],
      files: const <FileContentKey>[
        FileContentKey(fileName: 'a', size: 9, sha256: shaA),
      ],
    );
    expect(
      id,
      '43F6DBFE46E84CF710C22E534DB9CEEE1191537A015BBFB418C4A3EA5D4B3C10',
    );
    expect(id, isNot(v2Id));
  });

  test('V8 - an empty fingerprint is still deterministic', () {
    final id = computeMessageId(
      fingerprint: '',
      direction: MessageDirection.outgoing,
      kind: MessageKind.text,
      eventNonce: 'nonce-empty',
      contentKey: contentKeyForText(''),
    );
    expect(
      id,
      'C85953CE444D62C599E7A8934DEE75E4355A5C12860DC7977C6FEB24869EFC51',
    );
  });

  test('ids are always 64 uppercase hex characters', () {
    for (final id in <String>[v1Id, v2Id]) {
      expect(id.length, 64);
      expect(RegExp(r'^[0-9A-F]{64}$').hasMatch(id), isTrue);
    }
  });

  test('the deterministic fallback key is used when no hash is declared', () {
    final key = contentKeyForFiles(const <FileContentKey>[
      FileContentKey(fileName: 'report.pdf', size: 42),
    ]);
    expect(key, 'n:report.pdf\u000042');
  });
}

/// Builds a file-message id from its parts.
String _fileId({
  required String fingerprint,
  required MessageDirection direction,
  required List<String> fileIds,
  required List<FileContentKey> files,
}) =>
    computeMessageId(
      fingerprint: fingerprint,
      direction: direction,
      kind: MessageKind.file,
      eventNonce: eventNonceForFiles(fileIds),
      contentKey: contentKeyForFiles(files),
    );
