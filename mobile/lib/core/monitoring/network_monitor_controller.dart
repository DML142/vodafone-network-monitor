import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _methodChannel = MethodChannel(
  'ua.networkdiagnostics.vodafone_network_monitor/methods',
);
const _eventChannel = EventChannel(
  'ua.networkdiagnostics.vodafone_network_monitor/events',
);

class NetworkMonitorController extends ChangeNotifier {
  static const probeInterval = Duration(seconds: 30);
  static const radioInterval = Duration(seconds: 60);
  static const _defaultHost = 'connectivitycheck.gstatic.com';
  static const _defaultProbeUrl =
      'https://connectivitycheck.gstatic.com/generate_204';

  StreamSubscription<Object?>? _eventSubscription;
  Timer? _probeTimer;
  Timer? _radioTimer;
  bool _started = false;
  bool _appForeground = true;
  bool _probeInProgress = false;
  bool _radioReadInProgress = false;
  bool routeAvailable = false;
  bool hasInternetCapability = false;
  bool osValidated = false;
  String transport = 'unknown';
  DateTime? routeChangedAt;
  String? routeChangeReason;
  DateTime? lastProbeAt;
  DateTime? lastSuccessfulProbeAt;
  int? dnsMillis;
  int? latencyMillis;
  int? httpStatus;
  String? failureStage;
  String? failureReason;
  int consecutiveFailures = 0;
  bool? internetReachable;
  DateTime? internetChangedAt;
  String? internetChangeReason;
  String? platformError;
  int totalProbes = 0;
  int failedProbes = 0;
  bool radioPermissionGranted = false;
  String radioStatus = 'permission_required';
  String? radioAccessTechnology;
  bool? radioRegistered;
  int? radioSignalDbm;
  int? radioRsrpDbm;
  int? radioRsrqDb;
  int? radioRssnrDb;
  int? radioChannel;
  int? radioAgeMillis;
  DateTime? radioObservedAt;
  bool isRecording = false;
  bool recordingActionInProgress = false;
  String? recordingSessionId;

  void start() {
    if (_started) return;
    _started = true;
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object error) {
        platformError = 'Не удалось отслеживать системные события сети';
        notifyListeners();
      },
    );
    if (_appForeground) _startForegroundSampling();
  }

  void setAppForeground(bool isForeground) {
    if (_appForeground == isForeground) return;
    _appForeground = isForeground;
    if (isForeground && _started) {
      _startForegroundSampling();
    } else {
      _probeTimer?.cancel();
      _radioTimer?.cancel();
      _probeTimer = null;
      _radioTimer = null;
    }
  }

  void _startForegroundSampling() {
    unawaited(runProbe());
    unawaited(refreshRadio());
    unawaited(refreshRecordingState());
    _probeTimer = Timer.periodic(probeInterval, (_) => unawaited(runProbe()));
    _radioTimer = Timer.periodic(
      radioInterval,
      (_) => unawaited(refreshRadio()),
    );
  }

  Future<void> runProbe() async {
    if (_probeInProgress) return;
    _probeInProgress = true;
    try {
      final result = await _methodChannel.invokeMapMethod<String, dynamic>(
        'runProbe',
        {'host': _defaultHost, 'url': _defaultProbeUrl},
      );
      if (result == null) return;
      _applyProbe(result);
    } on PlatformException catch (error) {
      platformError = error.message ?? 'Сетевая проверка недоступна';
      notifyListeners();
    } on MissingPluginException {
      platformError = 'Сетевой адаптер доступен только в Android-приложении';
      notifyListeners();
    } finally {
      _probeInProgress = false;
    }
  }

  Future<void> refreshRadio() async {
    if (_radioReadInProgress) return;
    _radioReadInProgress = true;
    try {
      radioPermissionGranted =
          await _methodChannel.invokeMethod<bool>('hasRadioPermission') ??
          false;
      if (!radioPermissionGranted) {
        radioStatus = 'permission_required';
        _clearRadioSnapshot();
        notifyListeners();
        return;
      }

      final values = await _methodChannel.invokeMapMethod<String, dynamic>(
        'readRadioInfo',
      );
      if (values != null) _applyRadioInfo(values);
    } on PlatformException {
      radioStatus = 'read_error';
      _clearRadioSnapshot();
      notifyListeners();
    } on MissingPluginException {
      radioStatus = 'unsupported';
      _clearRadioSnapshot();
      notifyListeners();
    } finally {
      _radioReadInProgress = false;
    }
  }

  Future<bool> requestRadioPermission() async {
    try {
      radioPermissionGranted =
          await _methodChannel.invokeMethod<bool>('requestRadioPermission') ??
          false;
      if (radioPermissionGranted) {
        await refreshRadio();
      } else {
        radioStatus = 'permission_denied';
        _clearRadioSnapshot();
        notifyListeners();
      }
      return radioPermissionGranted;
    } on PlatformException {
      radioStatus = 'permission_denied';
      notifyListeners();
      return false;
    } on MissingPluginException {
      radioStatus = 'unsupported';
      notifyListeners();
      return false;
    }
  }

  Future<void> openAppSettings() async {
    try {
      await _methodChannel.invokeMethod<void>('openAppSettings');
    } on PlatformException {
      platformError = 'Не удалось открыть настройки разрешений';
      notifyListeners();
    } on MissingPluginException {
      platformError = 'Настройки разрешений доступны только на Android';
      notifyListeners();
    }
  }

  Future<bool> hasNotificationPermission() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'hasNotificationPermission',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> requestNotificationPermission() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> startRecording() async {
    if (recordingActionInProgress || isRecording) return isRecording;
    recordingActionInProgress = true;
    notifyListeners();
    try {
      isRecording =
          await _methodChannel.invokeMethod<bool>('startRecording') ?? false;
      if (!isRecording) recordingSessionId = null;
      return isRecording;
    } on PlatformException catch (error) {
      platformError = error.message ?? 'Не удалось начать запись';
      return false;
    } on MissingPluginException {
      platformError = 'Запись доступна только в Android-приложении';
      return false;
    } finally {
      recordingActionInProgress = false;
      notifyListeners();
    }
  }

  Future<void> stopRecording() async {
    if (recordingActionInProgress || !isRecording) return;
    recordingActionInProgress = true;
    notifyListeners();
    try {
      await _methodChannel.invokeMethod<void>('stopRecording');
    } on PlatformException catch (error) {
      platformError = error.message ?? 'Не удалось остановить запись';
    } on MissingPluginException {
      platformError = 'Запись доступна только в Android-приложении';
    } finally {
      recordingActionInProgress = false;
      notifyListeners();
    }
  }

  Future<void> refreshRecordingState() async {
    try {
      final values = await _methodChannel.invokeMapMethod<String, dynamic>(
        'getRecordingState',
      );
      if (values == null) return;
      isRecording = values['recording'] == true;
      recordingSessionId = values['sessionId'] as String?;
      notifyListeners();
    } on PlatformException {
      // The foreground service may not be available during initial startup.
    } on MissingPluginException {
      // Keep the unavailable state on targets outside Android.
    }
  }

  void _applyRadioInfo(Map<String, dynamic> values) {
    radioStatus = values['status'] as String? ?? 'read_error';
    radioAccessTechnology = values['accessTechnology'] as String?;
    radioRegistered = values['registered'] as bool?;
    radioSignalDbm = values['signalDbm'] as int?;
    radioRsrpDbm = values['rsrpDbm'] as int?;
    radioRsrqDb = values['rsrqDb'] as int?;
    radioRssnrDb = values['rssnrDb'] as int?;
    radioChannel = values['channel'] as int?;
    radioAgeMillis = values['ageMillis'] as int?;
    radioObservedAt = _dateTime(values['observedAtUtc']);
    notifyListeners();
  }

  void _clearRadioSnapshot() {
    radioAccessTechnology = null;
    radioRegistered = null;
    radioSignalDbm = null;
    radioRsrpDbm = null;
    radioRsrqDb = null;
    radioRssnrDb = null;
    radioChannel = null;
    radioAgeMillis = null;
    radioObservedAt = null;
  }

  void _onNativeEvent(Object? event) {
    if (event is! Map) return;
    final values = Map<String, dynamic>.from(event);
    if (values['eventType'] == 'recording') {
      isRecording = values['recording'] == true;
      recordingSessionId = values['sessionId'] as String?;
      notifyListeners();
      return;
    }
    if (values['eventType'] != 'network') return;

    final wasAvailable = routeAvailable;
    final previousTransport = transport;
    routeAvailable = values['routeAvailable'] == true;
    hasInternetCapability = values['hasInternetCapability'] == true;
    osValidated = values['osValidated'] == true;
    transport = values['transport'] as String? ?? 'unknown';

    if (wasAvailable != routeAvailable || previousTransport != transport) {
      routeChangedAt = _dateTime(values['observedAtUtc']);
      routeChangeReason = _routeReason(
        available: routeAvailable,
        currentTransport: transport,
      );
    }

    if (_appForeground &&
        routeAvailable &&
        (internetReachable == null || !internetReachable!)) {
      unawaited(runProbe());
    }
    notifyListeners();
  }

  void _applyProbe(Map<String, dynamic> values) {
    final previousReachability = internetReachable;
    lastProbeAt = _dateTime(values['observedAtUtc']);
    dnsMillis = values['dnsMillis'] as int?;
    latencyMillis = values['latencyMillis'] as int?;
    httpStatus = values['httpStatus'] as int?;
    failureStage = values['failureStage'] as String?;
    failureReason = values['failureReason'] as String?;
    internetReachable = values['success'] == true;
    totalProbes++;

    if (internetReachable!) {
      lastSuccessfulProbeAt = lastProbeAt;
      consecutiveFailures = 0;
    } else {
      consecutiveFailures++;
      failedProbes++;
    }

    if (previousReachability != internetReachable) {
      internetChangedAt = lastProbeAt;
      internetChangeReason = internetReachable!
          ? 'Контрольный HTTPS-узел ответил (HTTP 204)'
          : _failureDescription(failureStage, failureReason, httpStatus);
    }
    platformError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    _radioTimer?.cancel();
    _started = false;
    unawaited(_eventSubscription?.cancel());
    _started = false;
    super.dispose();
  }
}

DateTime? _dateTime(Object? epochMillis) {
  if (epochMillis is! int) return null;
  return DateTime.fromMillisecondsSinceEpoch(epochMillis).toLocal();
}

String _routeReason({
  required bool available,
  required String currentTransport,
}) {
  if (!available) return 'Маршрут через сеть потерян';
  final name = switch (currentTransport) {
    'cellular' => 'мобильная сеть',
    'wifi' => 'Wi-Fi',
    'ethernet' => 'Ethernet',
    'vpn' => 'VPN',
    _ => 'сеть',
  };
  return 'Появился маршрут через $name';
}

String _failureDescription(String? stage, String? reason, int? statusCode) {
  if (stage == 'dns') {
    return switch (reason) {
      'name_not_resolved' => 'DNS-имя контрольного узла не найдено',
      'timeout' => 'Истекло время ожидания DNS',
      _ => 'Ошибка DNS-проверки',
    };
  }
  if (statusCode != null) {
    return 'Контрольный узел ответил кодом HTTP $statusCode';
  }
  return switch (reason) {
    'timeout' => 'Истекло время ожидания HTTPS-ответа',
    'tls_error' => 'Ошибка защищённого TLS-соединения',
    'connection_error' => 'Не удалось подключиться к контрольному узлу',
    _ => 'Ошибка HTTPS-проверки',
  };
}
