import 'package:flutter/material.dart';

import '../../core/monitoring/network_monitor_controller.dart';
import 'radio_info_card.dart';

class PermissionDiagnosticsScreen extends StatelessWidget {
  const PermissionDiagnosticsScreen({required this.monitor, super.key});

  final NetworkMonitorController monitor;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: Icon(Icons.check_circle_outline),
            title: Text('Базовая диагностика без разрешения на геолокацию'),
            subtitle: Text(
              'INTERNET и ACCESS_NETWORK_STATE нужны для проверки подключения. '
              'Они не дают доступ к телефону или SIM.',
            ),
          ),
        ),
        const SizedBox(height: 12),
        RadioInfoCard(monitor: monitor),
      ],
    );
  }
}
