import 'package:flutter/material.dart';

import 'app/remote_app.dart';
import 'core/api/remote_api.dart';
import 'features/workspace/remote_app_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    FilmStoryboardRemoteApp(
      controller: RemoteAppController(api: HttpRemoteApi()),
    ),
  );
}
