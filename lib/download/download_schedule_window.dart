/// Local-time recurring window for starting and continuing downloads.
/// Weekdays use Dart's Monday=1 ... Sunday=7 convention.
class DownloadScheduleWindow {
  const DownloadScheduleWindow({
    this.enabled = false,
    this.startMinute = 0,
    this.endMinute = 360,
    this.weekdays = 127,
  });

  final bool enabled;
  final int startMinute;
  final int endMinute;
  final int weekdays;

  bool allows(DateTime time) {
    if (!enabled) return true;
    final minute = time.hour * 60 + time.minute;
    bool selected(int weekday) => (weekdays & (1 << (weekday - 1))) != 0;
    if (startMinute == endMinute) return false;
    if (startMinute < endMinute) {
      return selected(time.weekday) &&
          minute >= startMinute && minute < endMinute;
    }
    final yesterday = time.weekday == DateTime.monday
        ? DateTime.sunday : time.weekday - 1;
    return (minute >= startMinute && selected(time.weekday)) ||
        (minute < endMinute && selected(yesterday));
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'startMinute': startMinute,
    'endMinute': endMinute,
    'weekdays': weekdays,
  };

  factory DownloadScheduleWindow.fromJson(Object? value) {
    if (value is! Map) return const DownloadScheduleWindow();
    final data = Map<String, dynamic>.from(value);
    return DownloadScheduleWindow(
      enabled: data['enabled'] == true,
      startMinute: ((data['startMinute'] as num?)?.toInt() ?? 0)
          .clamp(0, 1439).toInt(),
      endMinute: ((data['endMinute'] as num?)?.toInt() ?? 360)
          .clamp(0, 1439).toInt(),
      weekdays: ((data['weekdays'] as num?)?.toInt() ?? 127)
          .clamp(0, 127).toInt(),
    );
  }
}
