import 'dart:convert';

class SessionExporter {
  static const fields = <String>[
    'observed_at_local',
    'event_type',
    'event_reason',
    'route_available',
    'transport',
    'has_internet_capability',
    'os_validated',
    'probe_success',
    'dns_ms',
    'latency_ms',
    'http_status',
    'failure_stage',
    'failure_reason',
    'radio_technology',
    'radio_registered',
    'signal_dbm',
    'rsrp_dbm',
    'rsrq_db',
    'rssnr_db',
    'channel',
    'radio_age_ms',
    'download_mbps',
    'upload_mbps',
    'download_error',
    'upload_error',
  ];

  static String encodeJson(
    Map<String, dynamic> session,
    List<Map<String, dynamic>> measurements,
  ) => const JsonEncoder.withIndent('  ').convert({
    'exported_at_utc': DateTime.now().toUtc().toIso8601String(),
    'session': session,
    'measurements': measurements
        .map(
          (row) => {
            for (final entry in row.entries)
              if (entry.key != 'id') entry.key: entry.value,
            'observed_at_local': _localIso(row['observed_at_utc']),
          },
        )
        .toList(),
  });

  static String encodeCsv(
    Map<String, dynamic> session,
    List<Map<String, dynamic>> measurements,
  ) {
    final buffer = StringBuffer()
      ..writeln('# session_id,${_csv(session['id'])}')
      ..writeln(
        '# started_at_local,${_csv(_localIso(session['startedAtUtc']))}',
      )
      ..writeln('# ended_at_local,${_csv(_localIso(session['endedAtUtc']))}')
      ..writeln(fields.map(_csv).join(','));
    for (final row in measurements) {
      final values = <Object?>[
        _localIso(row['observed_at_utc']),
        for (final field in fields.skip(1)) row[field],
      ];
      buffer.writeln(values.map(_csv).join(','));
    }
    return buffer.toString();
  }

  static String _csv(Object? value) {
    if (value == null) return '';
    final text = '$value';
    if (!text.contains(RegExp('[,"\r\n]'))) return text;
    return '"${text.replaceAll('"', '""')}"';
  }

  static String _localIso(Object? milliseconds) {
    if (milliseconds is! int) return '';
    final local = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final absolute = offset.abs();
    final hours = absolute.inHours.toString().padLeft(2, '0');
    final minutes = (absolute.inMinutes % 60).toString().padLeft(2, '0');
    return '${local.toIso8601String()}$sign$hours:$minutes';
  }
}
