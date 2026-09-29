import 'package:flutter/material.dart';

import '../../core/monitoring/network_monitor_controller.dart';
import '../permissions/radio_info_card.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({required this.monitor, super.key});

  final NetworkMonitorController monitor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: monitor,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    monitor.internetReachable == true
                        ? Icons.check_circle_outline
                        : monitor.routeAvailable
                        ? Icons.wifi_tethering_error_rounded
                        : Icons.signal_wifi_off,
                    size: 32,
                    color: monitor.internetReachable == true
                        ? Colors.green
                        : monitor.routeAvailable
                        ? Theme.of(context).colorScheme.tertiary
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_headline),
                        SizedBox(height: 6),
                        Text(_statusDescription),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Состояние', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          _MetricCard(
            icon: Icons.cell_tower,
            label: 'Тип активной сети',
            value: _transportLabel,
          ),
          _MetricCard(
            icon: Icons.public,
            label: 'Доступ в интернет',
            value: monitor.internetReachable == null
                ? 'Проверяется'
                : monitor.internetReachable!
                ? 'Доступ есть'
                : 'Нет ответа',
          ),
          const SizedBox(height: 20),
          Text(
            'Последние показатели',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _MetricCard(
                icon: Icons.speed,
                label: 'Задержка',
                value: monitor.latencyMillis?.toString() ?? '—',
                unit: 'мс',
              ),
              _MetricCard(
                icon: Icons.warning_amber_outlined,
                label: 'Потери проб',
                value: _failurePercent,
                unit: '%',
              ),
              _MetricCard(
                icon: Icons.download_outlined,
                label: 'Скорость',
                value: _speedValue(monitor.lastSpeedTest?['downloadMbps']),
                unit: 'Мбит/с',
              ),
              _MetricCard(
                icon: Icons.signal_cellular_alt,
                label: 'Радиосигнал',
                value: monitor.radioRsrpDbm?.toString() ?? 'Нет данных',
                unit: monitor.radioRsrpDbm == null ? null : 'dBm',
              ),
            ],
          ),
          const SizedBox(height: 20),
          _speedTestCard(context),
          const SizedBox(height: 20),
          RadioInfoCard(monitor: monitor),
          const SizedBox(height: 20),
          _recordingCard(context),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('Последняя успешная проверка'),
                  subtitle: Text(_formatTime(monitor.lastSuccessfulProbeAt)),
                ),
                if (monitor.routeChangeReason != null)
                  ListTile(
                    leading: const Icon(Icons.swap_horiz),
                    title: Text(monitor.routeChangeReason!),
                    subtitle: Text(_formatTime(monitor.routeChangedAt)),
                    dense: true,
                  ),
                if (monitor.internetChangeReason != null)
                  ListTile(
                    leading: const Icon(Icons.public),
                    title: Text(monitor.internetChangeReason!),
                    subtitle: Text(_formatTime(monitor.internetChangedAt)),
                    dense: true,
                  ),
                if (monitor.failureReason != null)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(_failureLabel),
                    subtitle: Text('Этап: ${monitor.failureStage ?? '—'}'),
                    dense: true,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: monitor.runProbe,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Проверить сейчас'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _headline {
    if (!monitor.routeAvailable) return 'Нет активного маршрута сети';
    if (monitor.internetReachable == true) return 'Интернет доступен';
    if (monitor.internetReachable == false) return 'Внешняя проверка не прошла';
    return 'Сеть подключена, ждём проверку';
  }

  String get _statusDescription {
    if (!monitor.routeAvailable) {
      return 'Android не сообщил о сети с маршрутом по умолчанию.';
    }
    if (monitor.internetReachable == true) {
      return 'Контрольный HTTPS-узел ответил. Системная проверка Android: '
          '${monitor.osValidated ? 'пройдена' : 'нет подтверждения'}.';
    }
    if (monitor.internetReachable == false) {
      return 'Сеть подключена, но отдельная DNS/HTTPS-проверка не получила '
          'ожидаемый ответ.';
    }
    return 'Наличие сети и доступ в интернет проверяются отдельно.';
  }

  String get _transportLabel => switch (monitor.transport) {
    'cellular' => 'Мобильная сеть',
    'wifi' => 'Wi-Fi',
    'ethernet' => 'Ethernet',
    'vpn' => 'VPN',
    'none' => 'Нет подключения',
    _ => 'Неизвестно',
  };

  String get _failurePercent {
    if (monitor.totalProbes == 0) return '—';
    final loss = monitor.failedProbes / monitor.totalProbes * 100;
    return '${loss.toStringAsFixed(0)}%';
  }

  String get _failureLabel => switch (monitor.failureReason) {
    'timeout' => 'Истекло время ожидания ответа',
    'name_not_resolved' => 'DNS-имя узла не найдено',
    'tls_error' => 'Ошибка TLS',
    'connection_error' => 'Ошибка соединения',
    'unexpected_http_status' => 'Неожиданный HTTP-код ${monitor.httpStatus}',
    _ => 'Проверка не удалась: ${monitor.failureReason}',
  };

  Widget _recordingCard(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              monitor.isRecording
                  ? Icons.fiber_manual_record
                  : Icons.radio_button_unchecked,
              color: monitor.isRecording
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            title: Text(
              monitor.isRecording ? 'Запись активна' : 'Запись остановлена',
            ),
            subtitle: Text(
              monitor.isRecording
                  ? 'Измерения сохраняются локально. Остановить можно здесь или из уведомления.'
                  : 'Запускайте и останавливайте сбор вручную.',
            ),
            trailing: monitor.isRecording && monitor.recordingSessionId != null
                ? const Icon(Icons.check_circle_outline)
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: monitor.recordingActionInProgress
                    ? null
                    : () => _toggleRecording(context),
                icon: Icon(
                  monitor.isRecording
                      ? Icons.stop_circle_outlined
                      : Icons.fiber_manual_record,
                ),
                label: Text(
                  monitor.isRecording ? 'Остановить запись' : 'Начать запись',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _speedTestCard(BuildContext context) {
    final result = monitor.lastSpeedTest;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Ручной скоростной тест'),
            subtitle: Text(
              result == null
                  ? 'Разовая проверка скачивания и отдачи.'
                  : '↓ ${_speedValue(result['downloadMbps'])} Мбит/с · '
                        '↑ ${_speedValue(result['uploadMbps'])} Мбит/с',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: monitor.speedTestInProgress
                    ? null
                    : () => _runSpeedTest(context),
                icon: monitor.speedTestInProgress
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.speed),
                label: Text(
                  monitor.speedTestInProgress
                      ? 'Измерение скорости…'
                      : 'Запустить тест',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runSpeedTest(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Запустить скоростной тест?'),
        content: const Text(
          'Для каждого направления будет передано до 10 МБ сгенерированных '
          'данных на speed.cloudflare.com. Cloudflare увидит IP-адрес сетевого '
          'соединения; файлы и журналы приложения не отправляются. Тест использует '
          'мобильный трафик, если сейчас подключена мобильная сеть. Результат сохранится в истории.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Запустить'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    final result = await monitor.runSpeedTest();
    if (!context.mounted) return;
    final download = result?['downloadMbps'];
    final upload = result?['uploadMbps'];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == null
              ? monitor.platformError ?? 'Скоростной тест не завершился.'
              : 'Скачивание: ${_speedValue(download)} Мбит/с · '
                    'отдача: ${_speedValue(upload)} Мбит/с',
        ),
      ),
    );
  }

  static String _speedValue(Object? value) =>
      value is num ? value.toStringAsFixed(1) : '—';

  Future<void> _toggleRecording(BuildContext context) async {
    if (monitor.isRecording) {
      await monitor.stopRecording();
      return;
    }

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Начать сетевую запись?'),
        content: const Text(
          'Приложение будет сохранять локально состояние сети и лёгкую '
          'HTTPS-проверку раз в 30 секунд. Радиоданные добавляются только '
          'если вы разрешили их отдельно. Постоянное уведомление покажет '
          'активную запись и позволит остановить её. Скоростной тест запускается отдельно.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Не сейчас'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;

    var notificationPermission = await monitor.hasNotificationPermission();
    if (!notificationPermission) {
      notificationPermission = await monitor.requestNotificationPermission();
    }
    if (!context.mounted) return;
    if (!notificationPermission) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Без разрешения на уведомление запись не запущена.'),
        ),
      );
      return;
    }

    final started = await monitor.startRecording();
    if (!context.mounted || started) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(monitor.platformError ?? 'Не удалось начать запись.'),
      ),
    );
  }

  static String _formatTime(DateTime? value) {
    if (value == null) return 'Нет данных';
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      child: SizedBox(
        width: 164,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: colors.primary),
              const SizedBox(height: 14),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 6),
              Text(
                unit == null ? value : '$value $unit',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
