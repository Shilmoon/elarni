// Support evidence for diagnostics bundles; pure Dart, so the headless CLI uses it too.

const supportStates = {
  'disconnected',
  'prepared',
  'preparing',
  'connecting',
  'connected',
  'disconnecting',
  'reasserting',
  'reconnecting',
  'invalid',
  'failed',
  'unavailable',
};

const supportIssueCodes = {
  'permission_denied',
  'vpn_configuration_failed',
  'listener_unavailable',
  'check_target_failed',
  'connection_failed',
  'unsupported_policy',
  'recovery_exhausted',
  'missing_credentials',
  'invalid_recovery',
  'invalid_configuration',
  'recovery_required',
  'previous_restored',
  'status_unavailable',
  'check_failed',
  'provider_unavailable',
  'disconnect_unconfirmed',
  'cancelled',
  'operation_failed',
  'export_failed',
  'busy',
  'storage_unavailable',
  'vpn_firewall_unavailable',
  'vpn_guard_busy',
  'vpn_guard_stale',
};

/// Allowlist support fields; do not recursively copy arbitrary runtime maps.
Map<String, Object?> connectionDiagnostics({
  required String platform,
  required String state,
  required Map<String, Object?> provider,
  required Map<String, Object?> automation,
  Iterable<String> issueCodes = const [],
}) => {
  'schemaVersion': 2,
  'platform': {'windows', 'linux'}.contains(platform) ? platform : 'macos',
  'state': supportStates.contains(state) ? state : 'unavailable',
  'endpoint': '[REDACTED]',
  'recentIssues': issueCodes
      .take(8)
      .map(
        (code) => supportIssueCodes.contains(code) ? code : 'operation_failed',
      )
      .toList(),
  'recovery': {
    'enabled': automation['enabled'] == true,
    'policy':
        {
          'fixed',
          'orderedFallback',
          'lowestLatency',
        }.contains(automation['policy'])
        ? automation['policy']
        : 'unknown',
    'pendingRetry': automation['pendingRetry'] == true,
    'exhausted': automation['exhausted'] == true,
    'pathAvailable': automation['pathAvailable'] == true,
    if (automation['attempts'] case final num value when value.isFinite)
      'attempts': value,
    'lastResult':
        const {
          'healthy',
          'recovered',
          'selected',
          'disabled',
          'stopped',
          'waitingForPath',
          'offline',
          'sleeping',
          'replacing',
          'intentRequired',
          'connectedUnchecked',
        }.contains(automation['status'])
        ? automation['status']
        : supportIssueCode(automation['status'] as String? ?? ''),
  },
  'provider': {
    for (final key in const [
      'generation',
      'uptimeSeconds',
      'uplinkBytes',
      'downlinkBytes',
      'txBytes',
      'rxBytes',
      'tcpConnections',
      'udpConnections',
      'memoryBytes',
    ])
      if (provider[key] case final num value when value.isFinite) key: value,
    for (final key in const ['metricsAvailable', 'resourceRecoveryRequired'])
      if (provider[key] case final bool value) key: value,
    if (provider['counters'] case final Map counters)
      'counters': {
        for (final key in const [
          'uplinkBytes',
          'downlinkBytes',
          'packetsIn',
          'packetsOut',
          'activeTcpSessions',
          'activeUdpSessions',
          'heapAllocBytes',
          'memoryLimitBytes',
        ])
          if (counters[key] case final num value when value.isFinite)
            key: value,
      },
  },
};

/// The public issue code for a native or automation error code.
String supportIssueCode(String code) => switch (code.replaceFirst(
  RegExp(r'^automation_'),
  '',
)) {
  'elevation_denied' || 'permission_denied' => 'permission_denied',
  'elevation_failed' ||
  'vpn_configuration_failed' => 'vpn_configuration_failed',
  'listener_unavailable' => 'listener_unavailable',
  'invalidTarget' ||
  'target_dns_failed' ||
  'resolution_failed' => 'check_target_failed',
  'endpointFailure' || 'connection_failed' => 'connection_failed',
  'unsupportedPolicy' => 'unsupported_policy',
  'exhausted' ||
  'exhaustedCandidates' ||
  'unavailableProbePath' => 'recovery_exhausted',
  'missingCredentials' || 'missing_credentials' => 'missing_credentials',
  'invalid_automation' || 'invalidConfiguration' => 'invalid_recovery',
  'unsupported_profile' ||
  'invalid_profile' ||
  'invalid_configuration' ||
  'invalid_settings' => 'invalid_configuration',
  'quarantine' ||
  'restorationFailed' ||
  'rollback_failed' ||
  'node_switch_restore_failed' => 'recovery_required',
  'replacementRestored' || 'node_switch_failed_restored' => 'previous_restored',
  'status_unavailable' => 'status_unavailable',
  'indeterminate' || 'healthFailure' => 'check_failed',
  'providerFailure' || 'native_unavailable' => 'provider_unavailable',
  'disconnect_timed_out' => 'disconnect_unconfirmed',
  'vpn_firewall_unavailable' => 'vpn_firewall_unavailable',
  'vpn_guard_busy' => 'vpn_guard_busy',
  'vpn_guard_stale' => 'vpn_guard_stale',
  'busy' => 'busy',
  'storage_busy' ||
  'storage_corrupt' ||
  'storage_conflict' ||
  'storage_unavailable' => 'storage_unavailable',
  'per_app_target_missing' => 'per_app_target_missing',
  'cancelled' || 'operation_cancelled' => 'cancelled',
  _ => 'operation_failed',
};
