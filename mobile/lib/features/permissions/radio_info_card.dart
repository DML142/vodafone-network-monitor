import 'package:flutter/material.dart';

import '../../core/monitoring/network_monitor_controller.dart';

class RadioInfoCard extends StatelessWidget {
  const RadioInfoCard({required this.monitor, super.key});

  final NetworkMonitorController monitor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: monitor,
      builder: (context, _) {
        final hasData = monitor.radioStatus == 'available';
        final hasLteMetrics =
            monitor.radioAccessTechnology == 'LTE' ||
            monitor.radioAccessTechnology == 'NR';
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.cell_tower,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Радиоданные телефона',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(_statusDescription),
                        ],
                      ),
                    ),
                    if (hasData && monitor.radioAgeMillis != null)
                      Text(_formatAge(monitor.radioAgeMillis!)),
                  ],
                ),
                if (hasData) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 14,
                    runSpacing: 8,
                    children: [
                      _value('Тип', monitor.radioAccessTechnology ?? '—'),
                      _value(
                        'Регистрация',
                        monitor.radioRegistered == true ? 'Да' : 'Нет',
                      ),
                      _value(
                        'Сигнал',
                        _withUnit(monitor.radioSignalDbm, 'dBm'),
                      ),
                      if (hasLteMetrics) ...[
                        _value('RSRP', _withUnit(monitor.radioRsrpDbm, 'dBm')),
                        _value('RSRQ', _withUnit(monitor.radioRsrqDb, 'dB')),
                        _value('RSSNR', _withUnit(monitor.radioRssnrDb, 'dB')),
                      ],
                      _value(
                        'Канал',
                        monitor.radioChannel?.toString() ?? 'Нет данных',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${hasLteMetrics ? 'Возраст берётся из отметки Android.' : 'RSRP, RSRQ и RSSNR Android предоставляет для LTE/5G; для ${monitor.radioAccessTechnology ?? 'этого типа сети'} эти показатели неприменимы.'} '
                    'Идентификатор соты не запрашивается и не сохраняется.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else if (_needsPermission) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Без разрешения базовые проверки сети продолжают работать. '
                    'Приложение не считывает координаты, телефонный номер или SIM ID.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () => _requestPermission(context),
                          icon: const Icon(Icons.location_searching),
                          label: const Text('Разрешить радиоданные'),
                        ),
                      ),
                      if (monitor.radioStatus == 'permission_denied') ...[
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Открыть настройки приложения',
                          onPressed: monitor.openAppSettings,
                          icon: const Icon(Icons.settings_outlined),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  bool get _needsPermission =>
      monitor.radioStatus == 'permission_required' ||
      monitor.radioStatus == 'permission_denied' ||
      monitor.radioStatus == 'permission_unavailable';

  String get _statusDescription => switch (monitor.radioStatus) {
    'available' =>
      '${monitor.radioAccessTechnology ?? 'Сотовая сеть'} · '
          '${monitor.radioRegistered == true ? 'зарегистрирована' : 'сота не зарегистрирована'}',
    'permission_required' =>
      'Нужно разрешение Android на точное местоположение',
    'permission_denied' => 'Разрешение не выдано',
    'permission_unavailable' => 'Android не разрешил чтение радиоданных',
    'radio_feature_missing' =>
      'Android не объявил поддержку сотового радио для этой прошивки',
    'telephony_service_unavailable' =>
      'Android не предоставил службу Telephony',
    'api_unsupported' => 'Прошивка не поддерживает CellInfo API',
    'modem_timeout' => 'Модем не ответил на запрос радиоданных',
    'modem_error' => 'Модем вернул ошибку при запросе радиоданных',
    'cell_info_error' => 'Android не смог получить сведения о радиосети',
    'unsupported' => 'Радиоданные недоступны на этом устройстве',
    'os_returned_no_cell_info' => 'Android пока не вернул сведения о соте',
    'cell_info_for_data_network_missing' =>
      'Сеть данных ${monitor.radioAccessTechnology ?? 'сотовая'}; Android не вернул сведения о соответствующей радиоячейке',
    _ => 'Данные пока недоступны',
  };

  static Widget _value(String label, String value) => Text('$label: $value');

  static String _withUnit(int? value, String unit) =>
      value == null ? 'Нет данных' : '$value $unit';

  static String _formatAge(int millis) {
    if (millis < 1000) return 'меньше секунды';
    final seconds = millis ~/ 1000;
    if (seconds < 60) return '$seconds с назад';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '$minutes мин назад';
    return '${minutes ~/ 60} ч назад';
  }

  Future<void> _requestPermission(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Разрешить просмотр радиоданных?'),
        content: const Text(
          'Android требует разрешение на точное местоположение, чтобы вернуть '
          'параметры сотовой соты. Приложение не запрашивает координаты и не '
          'сохраняет идентификатор соты. Без разрешения проверка интернета и '
          'запись сетевых сбоев продолжат работать.',
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
    if (accepted != true) return;

    final granted = await monitor.requestRadioPermission();
    if (!context.mounted || granted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Разрешение отклонено; проверка интернета работает без него.',
        ),
      ),
    );
  }
}
