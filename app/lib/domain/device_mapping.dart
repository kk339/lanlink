/// Pure projection of a live discovery peer onto the persisted device view
/// (M4 §4.2 "online column" rules).
///
/// **Layering (M4 §8.1):** pure Dart — imports only `domain/models.dart`, so it
/// compiles on Web and is unit-testable without Flutter. Side-effect free and
/// deterministic.
///
/// The receive path needs this mapping: `TransferService.received` carries a
/// [DiscoveredPeer] (the sender that just uploaded to this device), whereas
/// [SessionRepository.recordIncoming] persists a [PeerDevice] row. Keeping the
/// rule here — rather than as a controller-private helper — is what makes it
/// reachable by a test. (It is deliberately **not** in `data/real/mappers.dart`,
/// which maps the `core`/`store` models onto `domain` and must never be imported
/// from the pure layers.)
library;

import 'models.dart';

/// Projects the live [peer] onto the persisted [PeerDevice] shape.
///
/// The peer has just completed an upload to this device, so it is by definition
/// reachable where it was seen: its advertised [DiscoveredPeer.port] becomes
/// [PeerDevice.lastPort] (so a later send-tap from the history is dialable) and
/// its [DiscoveredPeer.address] becomes [PeerDevice.lastIp]. The history fields
/// — `lastPreview` / `lastActivityAt` / `conversationId` — are **not** derived
/// here: they belong to the repository, not to discovery (§4.2).
PeerDevice deviceFromDiscovered(DiscoveredPeer peer) => PeerDevice(
      fingerprint: peer.fingerprint,
      alias: peer.alias,
      kind: peer.kind,
      model: peer.model,
      isOnline: peer.isOnline,
      lastPort: peer.port,
      lastIp: peer.address,
      lastSeenAt: peer.lastSeen,
    );
