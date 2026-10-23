import 'dart:async';

/// One shared token bucket for JDM's in-process HTTP and MPEG-TS HLS workers.
/// The external FFmpeg process does not pass through this limiter.
class DownloadRateLimiter {
  DownloadRateLimiter({int bytesPerSecond = 0})
      : _bytesPerSecond = bytesPerSecond < 0 ? 0 : bytesPerSecond {
    _clock.start();
  }

  final Stopwatch _clock = Stopwatch();
  int _lastMicroseconds = 0;
  int _bytesPerSecond;
  double _tokens = 0;

  int get bytesPerSecond => _bytesPerSecond;

  void setBytesPerSecond(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value');
    _refill();
    _bytesPerSecond = value;
    // Allow a new limit a one-second burst; don't carry excess older credit.
    _tokens = _tokens.clamp(0.0, value.toDouble()).toDouble();
  }

  void _refill() {
    final now = _clock.elapsedMicroseconds;
    final elapsed = now - _lastMicroseconds;
    _lastMicroseconds = now;
    if (_bytesPerSecond > 0) {
      _tokens = (_tokens + elapsed * _bytesPerSecond / 1000000)
          .clamp(0.0, _bytesPerSecond.toDouble()).toDouble();
    } else {
      _tokens = 0;
    }
  }

  Future<void> acquire(int bytes, {required bool Function() isActive}) async {
    if (bytes <= 0) return;
    var remaining = bytes;
    while (remaining > 0) {
      if (!isActive()) return;
      if (_bytesPerSecond == 0) return;
      _refill();
      final available = _tokens.floor();
      if (available > 0) {
        final granted = available < remaining ? available : remaining;
        _tokens -= granted;
        remaining -= granted;
      } else {
        // Short waits allow cancellation and rate-setting changes promptly.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}
