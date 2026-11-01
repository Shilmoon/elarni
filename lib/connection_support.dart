import 'connection_diagnostics.dart';
import 'platform_services.dart';
import 'strings.dart';

export 'connection_diagnostics.dart';

/// Public support copy is selected by code, never by a native error's text.
final class ConnectionIssue {
  const ConnectionIssue(this.code, this.message, this.remedy);
  final String code, message, remedy;

  static ConnectionIssue from(Object error) {
    if (error is! PlatformException) return forCode('operation_failed');
    if (error.details case final Map details) {
      final diagnostic = details['diagnostics'] is Map
          ? details['diagnostics'] as Map
          : details;
      if (diagnostic['code'] == 'target_dns_failed')
        return forCode('target_dns_failed');
      if (diagnostic['code'] == 'timeout') return forCode('healthFailure');
      if (diagnostic['httpStatus'] case final num status when status != 0)
        return forCode('invalidTarget');
    }
    return forCode(error.code);
  }

  static ConnectionIssue forCode(String code) {
    final issue = supportIssueCode(code);
    final (message, remedy) = switch (issue) {
      'permission_denied' => (
        l10n.issuePermissionDenied,
        l10n.issuePermissionDeniedRemedy,
      ),
      'vpn_configuration_failed' => (
        l10n.issueVpnConfigurationFailed,
        l10n.issueVpnConfigurationFailedRemedy,
      ),
      'listener_unavailable' => (
        l10n.issueListenerUnavailable,
        l10n.issueListenerUnavailableRemedy,
      ),
      'check_target_failed' => (
        l10n.issueCheckTargetFailed,
        l10n.issueCheckTargetFailedRemedy,
      ),
      'connection_failed' => (
        l10n.issueConnectionFailed,
        l10n.issueConnectionFailedRemedy,
      ),
      'unsupported_policy' => (
        l10n.issueUnsupportedPolicy,
        l10n.issueUnsupportedPolicyRemedy,
      ),
      'recovery_exhausted' => (
        l10n.issueRecoveryExhausted,
        l10n.issueRecoveryExhaustedRemedy,
      ),
      'missing_credentials' => (
        l10n.issueMissingCredentials,
        l10n.issueMissingCredentialsRemedy,
      ),
      'invalid_recovery' => (
        l10n.issueInvalidRecovery,
        l10n.issueInvalidRecoveryRemedy,
      ),
      'invalid_configuration' => (
        l10n.issueInvalidConfiguration,
        l10n.issueInvalidConfigurationRemedy,
      ),
      'recovery_required' => (
        l10n.issueRecoveryRequired,
        l10n.issueRecoveryRequiredRemedy,
      ),
      'previous_restored' => (
        l10n.issuePreviousRestored,
        l10n.issuePreviousRestoredRemedy,
      ),
      'status_unavailable' => (
        l10n.issueStatusUnavailable,
        l10n.issueStatusUnavailableRemedy,
      ),
      'check_failed' => (l10n.issueCheckFailed, l10n.issueCheckFailedRemedy),
      'provider_unavailable' => (
        l10n.issueProviderUnavailable,
        l10n.issueProviderUnavailableRemedy,
      ),
      'disconnect_unconfirmed' => (
        l10n.issueDisconnectUnconfirmed,
        l10n.issueDisconnectUnconfirmedRemedy,
      ),
      'vpn_firewall_unavailable' => (
        l10n.issueVpnFirewallUnavailable,
        l10n.issueVpnFirewallUnavailableRemedy,
      ),
      'vpn_guard_busy' => (
        l10n.issueVpnGuardBusy,
        l10n.issueVpnGuardBusyRemedy,
      ),
      'vpn_guard_stale' => (
        l10n.issueVpnGuardStale,
        l10n.issueVpnGuardStaleRemedy,
      ),
      'busy' => (l10n.issueBusy, l10n.issueBusyRemedy),
      'storage_unavailable' => (
        l10n.issueStorageUnavailable,
        l10n.issueStorageUnavailableRemedy,
      ),
      'per_app_target_missing' => (
        l10n.issuePerAppTargetMissing,
        l10n.issuePerAppTargetMissingRemedy,
      ),
      'cancelled' => (l10n.issueCancelled, l10n.issueCancelledRemedy),
      _ => (l10n.issueOperationFailed, l10n.issueOperationFailedRemedy),
    };
    return ConnectionIssue(issue, message, remedy);
  }

  String get description => '$message $remedy';
}
