import 'package:cloud_firestore/cloud_firestore.dart';

enum UserRole { student, teacher }

class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    this.avatarUrl,
    this.subjects = const [],
    this.birthDate,
    this.timezone,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        email: json['email'] as String? ?? '',
        name: json['name'] as String? ?? 'Пользователь',
        role: _roleFromString(json['role'] as String?),
        avatarUrl: json['avatar_url'] as String?,
        subjects: (json['subjects'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        birthDate: _dateFromJson(json['birth_date']),
        timezone: json['timezone'] as String?,
      );

  final String id;
  final String email;
  final String name;
  final UserRole role;
  final String? avatarUrl;
  final List<String> subjects;
  final DateTime? birthDate;
  final String? timezone;

  bool get isTeacher => role == UserRole.teacher;
  bool get isStudent => role == UserRole.student;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'name': name,
        'role': role.name,
        'avatar_url': avatarUrl,
        'subjects': subjects,
        'birth_date': birthDate,
        'timezone': timezone,
      };

  static UserRole _roleFromString(String? value) {
    switch (value) {
      case 'teacher':
        return UserRole.teacher;
      default:
        return UserRole.student;
    }
  }

  static DateTime? _dateFromJson(dynamic value) {
    if (value is DateTime) return value;
    if (value is Timestamp) return value.toDate();
    return null;
  }
}