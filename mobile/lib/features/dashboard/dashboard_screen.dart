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
                value: '—',
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
          RadioInfoCard(monitor: monitor),
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
