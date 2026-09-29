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
  static const _defaultHost = 'connectivitycheck.gstatic.com';
  static const _defaultProbeUrl =
      'https://connectivitycheck.gstatic.com/generate_204';

  StreamSubscription<Object?>? _eventSubscription;
  Timer? _probeTimer;
  bool _started = false;
  bool _probeInProgress = false;
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
    unawaited(runProbe());
    _probeTimer = Timer.periodic(probeInterval, (_) => unawaited(runProbe()));
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

  void _onNativeEvent(Object? event) {
    if (event is! Map) return;
    final values = Map<String, dynamic>.from(event);
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

    if (routeAvailable && (internetReachable == null || !internetReachable!)) {
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
