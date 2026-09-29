import 'package:flutter/material.dart';

import '../../app/empty_state_panel.dart';

class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(16),
      children: [
        EmptyStatePanel(
          icon: Icons.history,
          title: 'Сессий пока нет',
          message: 'Записи появятся после запуска и остановки мониторинга.',
        ),
      ],
    );
  }
}
