import 'package:flutter/material.dart';
import 'core/network/api_client.dart';
import 'core/network/api_config.dart';
import 'features/auth/repositories/dio_auth_repository.dart';
import 'features/auth/views/account_bootstrap.dart';
import 'features/auth/services/session_store.dart';
import 'features/profile/repositories/profile_repository.dart';
import 'features/meeting/meeting_remote.dart';
import 'features/meeting/meeting_store.dart';
import 'features/progress/repositories/dio_progress_repository.dart';
import 'features/knowledge/repositories/dio_knowledge_repository.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'features/meeting/meeting_recorder_factory.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = ApiConfig.current;
  final baseUrl = environment.baseUrl;
  final root = await getApplicationSupportDirectory();
  final directory = environment.dataSubdirectory.isEmpty
      ? root
      : Directory('${root.path}/${environment.dataSubdirectory}');
  await directory.create(recursive: true);
  final meetings = LocalMeetingStore(directory: directory);
  final auth = DioAuthRepository(
    ApiClient(baseUrl: baseUrl),
    SecureSessionStore(baseUrl),
  );
  final profiles = ProfileRepository(
    LocalProfileStore(directory: directory),
    client: auth.client,
    initialSessionActive: false,
    sessionActiveOverride: false,
  );
  runApp(
    AccountBootstrap(
      auth: auth,
      apiClient: auth.client,
      profiles: profiles,
      meetingRemote: DioMeetingRepository(auth.client),
      knowledgeRepository: DioKnowledgeRepository(auth.client),
      progressRepository: DioProgressRepository(
        auth.client,
        meetingStore: meetings,
      ),
      meetingStore: meetings,
      meetingRecorder: createDeviceMeetingRecorder(
        directory: directory,
        apiClient: auth.client,
      ),
    ),
  );
}
