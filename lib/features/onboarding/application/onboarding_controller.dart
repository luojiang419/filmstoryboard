import 'package:flutter/foundation.dart';

import '../data/onboarding_repository.dart';
import '../domain/onboarding_step.dart';

class OnboardingController extends ChangeNotifier {
  OnboardingController({required OnboardingRepository repository})
    : _repository = repository;

  final OnboardingRepository _repository;

  bool _visible = false;
  int _stepIndex = 0;
  int _originTabIndex = 0;
  bool _automatic = false;
  int? _exitTabIndex;

  bool get visible => _visible;
  int get stepIndex => _stepIndex;
  int get stepCount => onboardingSteps.length;
  OnboardingStep get currentStep => onboardingSteps[_stepIndex];
  bool get canGoBack => _stepIndex > 0;
  bool get isLastStep => _stepIndex == onboardingSteps.length - 1;
  bool get shouldStartAutomatically => _repository.isFirstRunPending;

  void start({required int originTabIndex, bool automatic = false}) {
    if (_visible) {
      return;
    }
    _originTabIndex = originTabIndex;
    _automatic = automatic;
    _exitTabIndex = null;
    _stepIndex = 0;
    _visible = true;
    notifyListeners();
  }

  void next() {
    if (!_visible) {
      return;
    }
    if (isLastStep) {
      _close(markCompleted: true);
      return;
    }
    _stepIndex += 1;
    notifyListeners();
  }

  void previous() {
    if (!_visible || !canGoBack) {
      return;
    }
    _stepIndex -= 1;
    notifyListeners();
  }

  void skip() {
    if (!_visible) {
      return;
    }
    _close(markCompleted: true);
  }

  int? takeExitTabIndex() {
    final value = _exitTabIndex;
    _exitTabIndex = null;
    return value;
  }

  void _close({required bool markCompleted}) {
    if (markCompleted) {
      _repository.markCompleted();
    }
    _visible = false;
    _stepIndex = 0;
    _exitTabIndex = _automatic ? 0 : _originTabIndex;
    _automatic = false;
    notifyListeners();
  }
}
