import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/voiceprint/voiceprint_repository.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

void main() {
  test(
    'missing upload acknowledgement is not treated as a saved recording',
    () async {
      final client = ApiClient(
        baseUrl: 'https://test.example/api/v1/',
        dio: Dio()
          ..httpClientAdapter = TestAdapter((_) async => (200, envelope({}))),
      );
      client.accountId = () => 'owner';
      await expectLater(
        VoiceprintRepository(
          client,
          'owner',
        ).upload('enrollment', '0', Uint8List(44)),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
  test(
    'account change prevents voiceprint audio from being uploaded',
    () async {
      var requests = 0;
      final client = ApiClient(
        baseUrl: 'https://test.example/api/v1/',
        dio: Dio()
          ..httpClientAdapter = TestAdapter((_) async {
            requests++;
            return (
              200,
              envelope({
                'samples': {
                  'verification': {'status': 'processing'},
                },
              }),
            );
          }),
      )..accountId = () => 'different-account';
      final repository = VoiceprintRepository(client, 'original-account');
      await expectLater(
        repository.upload('enrollment', '0', Uint8List(44)),
        throwsA(isA<ApiFailure>()),
      );
      expect(requests, 0);
    },
  );

  test(
    'voiceprint uploads use raw WAV and authenticated account scope',
    () async {
      RequestOptions? captured;
      final client = ApiClient(
        baseUrl: 'https://test.example/api/v1/',
        dio: Dio()
          ..httpClientAdapter = TestAdapter((options) async {
            captured = options;
            return (
              200,
              envelope({
                'samples': {
                  'verification': {'status': 'processing'},
                },
              }),
            );
          }),
      );
      client.accountId = () => 'owner';
      client.accessToken = () async => 'test-only-token';
      await VoiceprintRepository(
        client,
        'owner',
      ).upload('enrollment', 'verification', Uint8List(44));
      expect(captured!.contentType, 'audio/wav');
      expect(captured!.headers['Authorization'], 'Bearer test-only-token');
      expect(captured!.extra['accountId'], 'owner');
      expect(captured!.path, endsWith('/verification'));
      expect(captured!.data, isA<Uint8List>());
    },
  );
}
