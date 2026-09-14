import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _timezonesInitialized = false;

void ensureTimezonesInitialized() {
  if (!_timezonesInitialized) {
    tzdata.initializeTimeZones();
    _timezonesInitialized = true;
  }
}

String? _cleanName(String? name) {
  if (name == null || name.trim().isEmpty) return null;
  return name.trim();
}

/// Список часовых поясов для выбора в профиле.
const List<String> kTimezoneOptions = [
  'Africa/Cairo',
  'Africa/Johannesburg',
  'Africa/Lagos',
  'America/Bogota',
  'America/Chicago',
  'America/Denver',
  'America/Lima',
  'America/Los_Angeles',
  'America/Mexico_City',
  'America/New_York',
  'America/Sao_Paulo',
  'America/Toronto',
  'Asia/Almaty',
  'Asia/Baku',
  'Asia/Bangkok',
  'Asia/Dubai',
  'Asia/Irkutsk',
  'Asia/Istanbul',
  'Asia/Jerusalem',
  'Asia/Kamchatka',
  'Asia/Karachi',
  'Asia/Kolkata',
  'Asia/Krasnoyarsk',
  'Asia/Magadan',
  'Asia/Novosibirsk',
  'Asia/Omsk',
  'Asia/Riyadh',
  'Asia/Shanghai',
  'Asia/Tashkent',
  'Asia/Tbilisi',
  'Asia/Tehran',
  'Asia/Tokyo',
  'Asia/Vladivostok',
  'Asia/Yakutsk',
  'Asia/Yekaterinburg',
  'Asia/Yerevan',
  'Australia/Perth',
  'Australia/Sydney',
  'Europe/Athens',
  'Europe/Berlin',
  'Europe/Helsinki',
  'Europe/Kaliningrad',
  'Europe/Kyiv',
  'Europe/London',
  'Europe/Minsk',
  'Europe/Moscow',
  'Europe/Paris',
  'Europe/Rome',
  'Europe/Samara',
  'Europe/Warsaw',
  'Pacific/Auckland',
  'UTC',
];

/// Текущее локальное время пользователя в его профильном часовом поясе.
DateTime asUserLocal(DateTime instant, String? tzName) {
  final name = _cleanName(tzName);
  if (name == null) return instant.toLocal();
  ensureTimezonesInitialized();
  final location = tz.getLocation(name);
  return tz.TZDateTime.from(instant.toUtc(), location);
}

/// «HH:mm» во времени пользователя.
String formatMeetingTime(DateTime instant, String? tzName) =>
    DateFormat('HH:mm').format(asUserLocal(instant, tzName));

/// «d MMM» (например «12 июл.») во времени пользователя.
String formatMeetingDay(DateTime instant, String? tzName) =>
    DateFormat('d MMM').format(asUserLocal(instant, tzName));

/// «d MMMM yyyy, HH:mm» — полная дата во времени пользователя.
String formatMeetingFull(DateTime instant, String? tzName) =>
    DateFormat('d MMMM yyyy, HH:mm').format(asUserLocal(instant, tzName));

String formatTimeZoneName(DateTime instant, String? tzName) {
  final name = _cleanName(tzName);
  if (name == null) return 'Местное время';
  ensureTimezonesInitialized();
  final local = tz.TZDateTime.from(instant.toUtc(), tz.getLocation(name));
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hours = offset.inHours.abs().toString().padLeft(2, '0');
  final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  return '$name (UTC$sign$hours:$minutes)';
}

/// Момент (абсолютное время) встречи по местному времени в поясе пользователя.
DateTime buildScheduledInstant({
  required int year,
  required int month,
  required int day,
  required int hour,
  required int minute,
  String? tzName,
}) {
  final name = _cleanName(tzName);
  if (name == null) return DateTime(year, month, day, hour, minute);
  ensureTimezonesInitialized();
  return tz.TZDateTime(tz.getLocation(name), year, month, day, hour, minute);
}