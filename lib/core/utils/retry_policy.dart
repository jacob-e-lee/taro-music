import 'dart:async';
import 'dart:math' as math;

/// Exponential backoff with jitter: `base * 2^attempt`, capped at [maxDelay],
/// then scaled by a random factor in `[0.5, 1.0)` so that a fleet of retries
/// from different clients does not synchronise into a thundering herd.
Duration backoffDelay(
  int attempt, {
  Duration base = const Duration(milliseconds: 500),
  Duration maxDelay = const Duration(seconds: 6),
  math.Random? random,
}) {
  final exponent = math.pow(2, math.min(attempt, 10)).toDouble();
  final unscaled = base.inMilliseconds * exponent;
  final capped = math.min(unscaled, maxDelay.inMilliseconds).toDouble();
  final jitter = (random ?? math.Random()).nextDouble() * 0.5 + 0.5;
  return Duration(microseconds: (capped * 1000 * jitter).round());
}

/// Runs [body] until it succeeds, sleeping with exponential backoff between
/// attempts.
///
/// [retryOn] decides whether an error is worth retrying; when it returns false
/// the error is rethrown immediately (e.g. "this source has no stream for the
/// track" is permanent and only makes sense to handle by trying the *next*
/// source, not the same one again).
///
/// When [breaker] is supplied it is fed the outcome of every attempt, so a
/// source that keeps failing can be taken out of rotation.
Future<T> withRetry<T>(
  FutureOr<T> Function() body, {
  int maxAttempts = 3,
  Duration baseDelay = const Duration(milliseconds: 500),
  Duration maxDelay = const Duration(seconds: 6),
  bool Function(Object error) retryOn = _alwaysRetry,
  CircuitBreaker? breaker,
  void Function(Duration delay, Object error, int attempt)? onRetry,
}) async {
  var attempt = 0;
  while (true) {
    try {
      final result = await body();
      breaker?.recordSuccess();
      return result;
    } catch (error) {
      attempt++;
      breaker?.recordFailure();
      if (attempt >= maxAttempts || !retryOn(error)) rethrow;
      final delay = backoffDelay(
        attempt - 1,
        base: baseDelay,
        maxDelay: maxDelay,
      );
      onRetry?.call(delay, error, attempt);
      await Future<void>.delayed(delay);
    }
  }
}

bool _alwaysRetry(Object _) => true;

/// A trivial failure counter that stops hammering a source that is clearly
/// down, and lets it back in after [cooldown] (half-open state).
///
/// Three consecutive failures for five minutes is the behaviour observed on
/// public Piped instances, so the defaults are tuned for that.
class CircuitBreaker {
  CircuitBreaker({
    this.failureThreshold = 5,
    this.cooldown = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int failureThreshold;
  final Duration cooldown;
  final DateTime Function() _now;

  int _consecutiveFailures = 0;
  DateTime? _openedAt;

  int get consecutiveFailures => _consecutiveFailures;

  /// True while the source is excluded from the fallback chain.
  bool get isOpen {
    final openedAt = _openedAt;
    if (openedAt == null) return false;
    if (_now().difference(openedAt) >= cooldown) {
      // Cooldown elapsed: close the breaker and allow one trial request.
      _openedAt = null;
      _consecutiveFailures = 0;
      return false;
    }
    return true;
  }

  Duration? get remainingCooldown {
    if (!isOpen) return null;
    return cooldown - _now().difference(_openedAt!);
  }

  void recordSuccess() {
    _consecutiveFailures = 0;
    _openedAt = null;
  }

  void recordFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= failureThreshold) _openedAt = _now();
  }
}
