import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart'
    as client;
import 'package:serverpod_offline_sync_test_server/src/generated/protocol.dart'
    as server;
import 'package:test/test.dart';

import '../test_tools/client_session.dart';
import '../test_tools/serverpod_test_tools.dart';

void main() {
  initTestClientSession(withPersistentUser: true);

  final clientSyncTables = [
    client.Address.t,
    client.Person.t,
    client.Types.t,
    client.Unique.t,
  ];

  final serverSyncTables = [
    server.Address.t,
    server.Person.t,
    server.Types.t,
    server.Unique.t,
  ];

  /// The merges reported to the callback registered on the pod, with the names
  /// the merged space held while the callback ran.
  final merges = <({UuidValue spaceUuid, Hlc syncedHlc, List<String> names})>[];

  late client.Client testClient;
  late OfflineSyncDatabaseSession clientSession;

  withServerpod(
    '[CRDT merge hook]',
    rollbackDatabase: RollbackDatabase.disabled,
    (sessionBuilder, _) {
      final rawServerSession = sessionBuilder.build();

      rawServerSession.serverpod
        ..initializeOfflineSync(
          syncTables: serverSyncTables,
          onMergeSuccess: (spaceUuid, syncedHlc) async {
            final people = await server.Person.db.find(rawServerSession);
            merges.add((
              spaceUuid: spaceUuid,
              syncedHlc: syncedHlc,
              names: [for (final person in people) person.name],
            ));
          },
        )
        ..authenticationHandler = (session, token) async => AuthenticationInfo(
          testCrdtUserId.toString(),
          <Scope>{},
          authId: const Uuid().v4(),
        );

      setUp(() async {
        merges.clear();

        testClient = client.Client(
          'http://localhost:${rawServerSession.server.port}',
        )..authKeyProvider = TestClientAuthKeyProvider();

        clientSession = OfflineSyncDatabaseSession.wraps(
          testSession,
          syncTables: clientSyncTables,
          persistentUserId: testCrdtUserId,
        );
        await clientSession.db.initialize();
      });

      group('Given a pending client person,', () {
        setUp(() async {
          await client.Person.db.insertRow(
            clientSession,
            client.Person(id: const Uuid().v7obj(), name: 'client-person'),
          );
        });

        test(
          'when client syncOnce is called, '
          'then the callback registered on the pod reports the space the '
          'changes landed in.',
          () async {
            await testClient.offlineSync.syncOnce(clientSession);

            expect(merges, hasLength(1));
            expect(merges.single.spaceUuid, testCrdtUserId);
            expect(
              merges.single.syncedHlc.datetime.isAfter(DateTime.utc(2020)),
              isTrue,
            );
          },
        );

        test(
          'when client syncOnce is called, '
          'then the merged row is already readable when the callback runs.',
          () async {
            await testClient.offlineSync.syncOnce(clientSession);

            expect(merges.single.names, contains('client-person'));
          },
        );

        test(
          'when a callback is registered on the pod after initialization, '
          'then it replaces the one passed to initializeOfflineSync.',
          () async {
            final lateSpaces = <UuidValue>[];
            final pod = rawServerSession.serverpod;
            final registered = pod.offlineSyncOnMergeSuccess;
            addTearDown(() => pod.offlineSyncOnMergeSuccess = registered);

            pod.offlineSyncOnMergeSuccess = (spaceUuid, syncedHlc) =>
                lateSpaces.add(spaceUuid);

            await testClient.offlineSync.syncOnce(clientSession);

            expect(lateSpaces, [testCrdtUserId]);
            expect(merges, isEmpty);
          },
        );
      });

      group('Given no pending changes on either side,', () {
        test(
          'when client syncOnce is called, '
          'then the callback registered on the pod is not called.',
          () async {
            await testClient.offlineSync.syncOnce(clientSession);

            expect(merges, isEmpty);
          },
        );
      });
    },
  );
}

class TestClientAuthKeyProvider implements ClientAuthKeyProvider {
  @override
  Future<String?> get authHeaderValue async => 'Bearer token';
}
