import 'package:flutter/foundation.dart';

class ReplicateShotNavigationController extends ChangeNotifier {
  String? get requestedShotId => _requestedShotId;
  String? _requestedShotId;

  void navigateTo(String shotId) {
    _requestedShotId = shotId;
    notifyListeners();
  }
}
