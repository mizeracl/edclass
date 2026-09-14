import 'package:cloud_firestore/cloud_firestore.dart';

enum MeetingType { camera, screen, both }

enum MeetingStatus { scheduled, active, completed, cancelled }

class MeetingParticipant {
  const MeetingParticipant({
    required this.userId,
    required this.name,
    required this.email,
    required this.role,
    this.status = 'invited',
  });

  final String userId;
  final String name;
  final String email;
  final String role;
  final String status;

  factory MeetingParticipant.fromJson(Map<String, dynamic> json) {
    return MeetingParticipant(
      userId: json['userId'] as String,
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      role: json['role'] as String? ?? 'student',
      status: json['status'] as String? ?? 'invited',
    );
  }

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'name': name,
        'email': email,
        'role': role,
        'status': status,
      };
}

class Meeting {
  const Meeting({
    required this.id,
    required this.teacherId,
    required this.teacherName,
    required this.title,
    this.description,
    required this.type,
    required this.scheduledAt,
    required this.durationMinutes,
    this.status = MeetingStatus.scheduled,
    this.participantIds = const [],
    this.participants = const [],
    this.createdAt,
  });

  final String id;
  final String teacherId;
  final String teacherName;
  final String title;
  final String? description;
  final MeetingType type;
  final DateTime scheduledAt;
  final int durationMinutes;
  final MeetingStatus status;
  final List<String> participantIds;
  final List<MeetingParticipant> participants;
  final DateTime? createdAt;

  DateTime get endsAt => scheduledAt.add(Duration(minutes: durationMinutes));

  bool get isPast => endsAt.isBefore(DateTime.now());

  String get typeLabel => switch (type) {
        MeetingType.camera => 'Видеозвонок',
        MeetingType.screen => 'Экран',
        MeetingType.both => 'Видео + Экран',
      };

  String get participantNamesLabel {
    if (participants.isEmpty) return 'Без участников';
    final names = participants.take(3).map((p) => p.name).join(', ');
    if (participants.length > 3) return '$names и ещё ${participants.length - 3}';
    return names;
  }

  factory Meeting.fromJson(String id, Map<String, dynamic> json) {
    return Meeting(
      id: id,
      teacherId: json['teacherId'] as String,
      teacherName: json['teacherName'] as String? ?? '',
      title: json['title'] as String,
      description: json['description'] as String?,
      type: _typeFromString(json['type'] as String?),
      scheduledAt: _dateFromJson(json['scheduledAt']),
      durationMinutes: (json['durationMinutes'] as num?)?.toInt() ?? 60,
      status: _statusFromString(json['status'] as String?),
      participantIds: (json['participantIds'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      participants: (json['participants'] as List<dynamic>?)
              ?.map((e) => MeetingParticipant.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      createdAt: (json['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toJson() => {
        'teacherId': teacherId,
        'teacherName': teacherName,
        'title': title,
        'description': description,
        'type': type.name,
        'scheduledAt': Timestamp.fromDate(scheduledAt),
        'durationMinutes': durationMinutes,
        'status': status.name,
        'participantIds': participantIds,
        'participants': participants.map((p) => p.toJson()).toList(),
        'createdAt': Timestamp.fromDate(createdAt ?? DateTime.now()),
      };

  static MeetingType _typeFromString(String? value) => switch (value) {
        'screen' => MeetingType.screen,
        'both' => MeetingType.both,
        _ => MeetingType.camera,
      };

  static MeetingStatus _statusFromString(String? value) => switch (value) {
        'active' => MeetingStatus.active,
        'completed' => MeetingStatus.completed,
        'cancelled' => MeetingStatus.cancelled,
        _ => MeetingStatus.scheduled,
      };

  static DateTime _dateFromJson(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
    return DateTime.now();
  }
}