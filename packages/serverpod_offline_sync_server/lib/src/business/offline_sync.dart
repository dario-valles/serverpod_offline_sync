import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';

import 'offline_sync_spaces.dart';

/// The CRDT sync configured per [Serverpod] instance.
///
/// Keyed by the [Serverpod] instance so each pod owns its own [OfflineSyncEngine] (and
/// the [OfflineSyncDatabaseContext] it carries) instead of sharing a single
/// process-wide singleton.
final _offlineSyncByServerpod = Expando<OfflineSyncEngine>('offlineSync');

/// The merge callback configured per [Serverpod] instance by
/// [OfflineSyncInitialize.initializeOfflineSync].
///
/// Keyed like [_offlineSyncByServerpod] so a pod running several [Serverpod]
/// instances (tests, in particular) keeps one callback per instance.
final _onMergeSuccessByServerpod = Expando<OfflineSyncOnMergeSuccess>(
  'offlineSyncOnMergeSuccess',
);

/// Intercepts each Serverpod session database with a CRDT-aware database once
/// [OfflineSyncInitialize.initializeOfflineSync] has configured sync.
///
/// When sync has not been configured for the session's [Serverpod], the
/// original [inner] database is returned unchanged.
Database offlineSyncDatabaseInterceptor(Session session, Database inner) {
  final offlineSync = _offlineSyncByServerpod[session.server.serverpod];
  return offlineSync?.wrapDatabase(inner) ?? inner;
}

/// Extension methods for [Serverpod] to configure the CRDT sync on the server.
extension OfflineSyncInitialize on Serverpod {
  /// Configures the CRDT sync with the given sync tables.
  ///
  /// Must be called during server startup before any sync requests are made.
  /// Will override any previous initialization for this [Serverpod] instance.
  ///
  /// The [Serverpod] instance must be constructed with [offlineSyncDatabaseInterceptor]
  /// as its `databaseInterceptor`. Otherwise each session's [Session.db] stays a
  /// plain database and server-side ORM mutations on synced tables are not
  /// CRDT-tracked.
  ///
  /// [syncBatchSize] controls the maximum number of merge changes carried by
  /// each sync stream chunk.
  ///
  /// [continuousSyncInterval] controls how long a continuous sync session waits
  /// after completing one sync round before checking for local changes again.
  ///
  /// [onMergeSuccess] is called after every successful merge of a client's
  /// changes, with the space the merge landed in and the highest merged HLC.
  /// It is the server-side notification a sync session produces: without it an
  /// application that shows one user's synced rows to another user (a live
  /// dashboard, a supervisor view) has no signal that anything changed and has
  /// to poll. `OfflineSyncEndpoint` runs the sync session for every client and
  /// forwards the callback registered here.
  ///
  /// The callback is awaited inside the sync session, so it should be cheap —
  /// posting on [Session.messages] or scheduling work, not running a query
  /// chain. An error thrown from it fails the sync session.
  ///
  /// A project whose generated `Serverpod` subclass already calls this method
  /// registers the callback with [offlineSyncOnMergeSuccess] instead.
  void initializeOfflineSync({
    required List<Table> syncTables,
    int syncBatchSize = OfflineSyncEngine.defaultSyncBatchSize,
    Duration continuousSyncInterval = OfflineSyncEngine.defaultContinuousSyncInterval,
    OfflineSyncOnMergeSuccess? onMergeSuccess,
  }) {
    _offlineSyncByServerpod[this] = OfflineSyncEngine(
      syncTables: syncTables,
      serializationManager: serializationManager,
      syncBatchSize: syncBatchSize,
      continuousSyncInterval: continuousSyncInterval,
    );
    _onMergeSuccessByServerpod[this] = onMergeSuccess;
  }

  /// The callback reported to after every successful merge of a client's
  /// changes, or `null` when none is registered.
  ///
  /// Assign to it to register a callback on a [Serverpod] whose generated
  /// subclass already called [initializeOfflineSync] — which is every project
  /// generated with `experimental_features: databaseSync`, since the generator
  /// emits `initializeOfflineSync(syncTables: syncTables)` into a file the
  /// application must not edit:
  ///
  /// ```dart
  /// final pod = Serverpod(args, Protocol(), Endpoints());
  /// pod.offlineSyncOnMergeSuccess = (spaceUuid, syncedHlc) {
  ///   board.notifySpaceChanged(spaceUuid);
  /// };
  /// await pod.start();
  /// ```
  ///
  /// [initializeOfflineSync] overwrites it, so register after initialization.
  OfflineSyncOnMergeSuccess? get offlineSyncOnMergeSuccess =>
      _onMergeSuccessByServerpod[this];

  set offlineSyncOnMergeSuccess(OfflineSyncOnMergeSuccess? onMergeSuccess) {
    _onMergeSuccessByServerpod[this] = onMergeSuccess;
  }
}

/// Session-bound CRDT services configured for a [Serverpod] instance.
///
/// This facade is ephemeral: each `Session.offlineSync` access creates a small wrapper
/// around the shared [OfflineSyncEngine] instance and the current [Session].
class OfflineSyncSession {
  /// Creates CRDT services bound to a session.
  ///
  /// [onMergeSuccess] is the callback registered for the [Serverpod] instance
  /// with [OfflineSyncInitialize.initializeOfflineSync], used by [sync] when
  /// the caller does not pass one of its own.
  OfflineSyncSession(this._session, this._sync, {this.onMergeSuccess});

  final Session _session;
  final OfflineSyncEngine _sync;

  /// The merge callback configured for this session's [Serverpod] instance.
  final OfflineSyncOnMergeSuccess? onMergeSuccess;

  /// Returns the server-side space management service.
  OfflineSyncSpaces get spaces => OfflineSyncSpaces(_session);

  /// Runs a CRDT sync session with this [OfflineSyncSession]'s [Session] bound.
  ///
  /// Reports successful merges to [onMergeSuccess] unless the caller passes its
  /// own, which lets `OfflineSyncEndpoint` — and any endpoint an application
  /// writes itself — deliver the callback registered with
  /// [OfflineSyncInitialize.initializeOfflineSync] without knowing about it.
  Stream<OfflineSyncStreamEvent> sync({
    required UuidValue userId,
    required Stream<OfflineSyncStreamEvent> inbound,
    required OfflineSyncPeerMode mode,
    bool once = false,
    OfflineSyncOnMergeSuccess? onMergeSuccess,
  }) {
    return _sync.sync(
      _session,
      userId: userId,
      inbound: inbound,
      once: once,
      mode: mode,
      onMergeSuccess: onMergeSuccess ?? this.onMergeSuccess,
    );
  }
}

/// Extension to access CRDT services for [Session] from the [Serverpod] instance.
extension OfflineSyncSessionExtension on Session {
  /// Returns the CRDT services configured for this session.
  OfflineSyncSession get offlineSync {
    final sync = _offlineSyncByServerpod[server.serverpod];
    if (sync == null) {
      throw StateError(
        'The OfflineSyncEngine has not been initialized for this Serverpod instance. '
        'Call pod.initializeOfflineSync(...) during server startup to configure '
        'the CRDT sync.',
      );
    }
    return OfflineSyncSession(
      this,
      sync,
      onMergeSuccess: _onMergeSuccessByServerpod[server.serverpod],
    );
  }
}
