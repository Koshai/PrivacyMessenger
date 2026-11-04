import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol_messages.dart';
import 'openmls_encryption_service.dart';

/// Isolated Alice/Bob device harness for C1 tests (not production UI).
class MlsDeviceHarness {
  MlsDeviceHarness({
    required this.label,
    required this.dbFile,
    required this.dbKey,
  });

  final String label;
  final File dbFile;
  final Uint8List dbKey;

  late OpenMlsEncryptionService service;
  DeviceIdentityRecord? identity;
  String? groupIdHex;

  static Future<MlsDeviceHarness> create(String label, Directory root) async {
    final key = OpenMlsEncryptionService.generateDatabaseKey();
    final file = File('${root.path}${Platform.pathSeparator}mls_$label.db');
    if (await file.exists()) {
      await file.delete();
    }
    final harness = MlsDeviceHarness(label: label, dbFile: file, dbKey: key);
    harness.service = OpenMlsEncryptionService(
      dbPath: file.path,
      databaseEncryptionKey: key,
    );
    await harness.service.openEngine();
    harness.identity = await harness.service.createIdentity(label: label);
    return harness;
  }

  Future<KeyPackageRecord> keyPackage() => service.createKeyPackage();

  Future<String> createGroup() async {
    groupIdHex = await service.createGroup();
    return groupIdHex!;
  }

  Future<({MlsWireMessage welcome, MlsWireMessage commit})> invite(
    KeyPackageRecord package,
  ) async {
    final groupId = groupIdHex;
    if (groupId == null) {
      throw StateError('$label has no group');
    }
    return service.addMember(
      groupIdHex: groupId,
      keyPackageBytes: package.keyPackageBytes,
    );
  }

  Future<void> join(MlsWireMessage welcome) async {
    if (welcome.kind != MlsWireKind.welcome) {
      throw ArgumentError('Expected Welcome wire message');
    }
    groupIdHex = await service.joinFromWelcome(welcomeBytes: welcome.bytes);
  }

  Future<MlsWireMessage> sendText(String text) async {
    final groupId = groupIdHex;
    if (groupId == null) {
      throw StateError('$label has no group');
    }
    return service.encryptApplication(
      groupIdHex: groupId,
      plaintext: utf8.encode(text),
    );
  }

  Future<String> receiveText(MlsWireMessage wire) async {
    final groupId = groupIdHex;
    if (groupId == null) {
      throw StateError('$label has no group');
    }
    final decrypted = await service.processIncoming(
      groupIdHex: groupId,
      messageBytes: wire.bytes,
    );
    if (decrypted == null) {
      throw StateError('No application plaintext');
    }
    return utf8.decode(decrypted.plaintext);
  }

  Future<void> restart() async {
    final id = identity;
    if (id == null) {
      throw StateError('Cannot restart without persisted identity');
    }
    await service.reopenAfterRestart(identity: id);
  }

  Future<void> dispose() async {
    await service.persistAndClose();
  }
}
