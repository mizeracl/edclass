import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/meeting.dart';
import '../../../core/models/user.dart';

class MeetingRepository {
  final FirebaseFirestore _firestore;

  static const String _collection = 'meetings';

  MeetingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  FirebaseAuth get _auth => FirebaseAuth.instance;

  /// Реально-временный поток встреч текущего пользователя.
  Stream<List<Meeting>> streamMeetings({DateTime? from, DateTime? to}) {
    final userUid = _auth.currentUser?.uid;
    if (userUid == null) {
      return Stream.value(const []);
    }

    return _firestore
        .collection(_collection)
        .where(
          'participantIds',
          arrayContains: userUid,
        )
        .snapshots()
        .handleError((Object error, StackTrace st) {
          debugPrint('MEETINGS_STREAM_ERROR: $error');
          debugPrint('$st');
          Error.throwWithStackTrace(error, st);
        })
        .map((snapshot) {
          final meetings = snapshot.docs
              .map((doc) => Meeting.fromJson(doc.id, doc.data()))
              .where((meeting) {
                if (from != null && meeting.scheduledAt.isBefore(from)) {
                  return false;
                }
                if (to != null && meeting.scheduledAt.isAfter(to)) {
                  return false;
                }
                return true;
              })
              .toList()
            ..sort((a, b) => b.scheduledAt.compareTo(a.scheduledAt));
          for (final meeting in meetings) {
            _syncParticipantNames(meeting);
          }
          return meetings;
        });
  }

  /// Поток встреч, где пользователь — учитель.
  Stream<List<Meeting>> streamTeacherMeetings(String teacherId) {
    return _firestore
        .collection(_collection)
        .where('teacherId', isEqualTo: teacherId)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Meeting.fromJson(doc.id, doc.data()))
            .toList()
          ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt)));
  }

  Future<String> createMeeting({
    required AppUser teacher,
    required String title,
    String? description,
    required MeetingType type,
    required DateTime scheduledAt,
    required int durationMinutes,
    required List<String> participantIds,
    required List<MeetingParticipant> participants,
  }) async {
    final docRef =
        _firestore.collection(_collection).doc();

    final meeting = Meeting(
      id: docRef.id,
      teacherId: teacher.id,
      teacherName: teacher.name,
      title: title,
      description: description,
      type: type,
      scheduledAt: scheduledAt,
      durationMinutes: durationMinutes,
      participantIds: [...participantIds, teacher.id],
      participants: [
        MeetingParticipant(
          userId: teacher.id,
          name: teacher.name,
          email: teacher.email,
          role: 'teacher',
          status: 'accepted',
        ),
        ...participants,
      ],
      createdAt: DateTime.now(),
    );

    await docRef.set(meeting.toJson());
    return docRef.id;
  }

  Future<void> deleteMeeting(String meetingId) async {
    await _firestore.collection(_collection).doc(meetingId).delete();
  }

  Future<void> cancelMeeting(String meetingId) async {
    await _firestore.collection(_collection).doc(meetingId).update({
      'status': MeetingStatus.cancelled.name,
    });
  }

  Future<void> startMeeting(String meetingId) async {
    await _firestore.collection(_collection).doc(meetingId).update({
      'status': MeetingStatus.active.name,
    });
  }

  Future<void> completeMeeting(String meetingId) async {
    await _firestore.collection(_collection).doc(meetingId).update({
      'status': MeetingStatus.completed.name,
    });
  }

  Future<void> updateMeeting({
    required String meetingId,
    required String teacherId,
    required String teacherName,
    required String title,
    String? description,
    required MeetingType type,
    required DateTime scheduledAt,
    required int durationMinutes,
    required List<String> participantIds,
    required List<MeetingParticipant> participants,
  }) async {
    await _firestore.collection(_collection).doc(meetingId).update({
      'teacherId': teacherId,
      'teacherName': teacherName,
      'title': title,
      'description': description,
      'type': type.name,
      'scheduledAt': Timestamp.fromDate(scheduledAt),
      'durationMinutes': durationMinutes,
      'participantIds': participantIds,
      'participants': participants.map((p) => p.toJson()).toList(),
    });
  }

  Future<void> acceptInvite(
    String meetingId, {
    required AppUser user,
  }) async {
    final docRef = _firestore.collection(_collection).doc(meetingId);
    await _firestore.runTransaction((transaction) async {
      final doc = await transaction.get(docRef);
      if (!doc.exists) return;

      final data = Map<String, dynamic>.from(doc.data()!);
      final participants = (data['participants'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      final index =
          participants.indexWhere((p) => p['userId'] == user.id);
      if (index >= 0) {
        participants[index]['status'] = 'accepted';
      } else {
        participants.add(MeetingParticipant(
          userId: user.id,
          name: user.name,
          email: user.email,
          role: user.role.name,
          status: 'accepted',
        ).toJson());
      }

      transaction.update(docRef, {'participants': participants});
    });
  }

  Future<Meeting?> getMeetingById(String meetingId) async {
    final doc = await _firestore.collection(_collection).doc(meetingId).get();
    if (!doc.exists) return null;
    final meeting = Meeting.fromJson(doc.id, doc.data()!);
    await _syncParticipantNames(meeting);
    return meeting;
  }

  static const String _placeholderName = 'Пользователь';

  /// Чинит устаревшие встречи: подставляет настоящие имена участников
  /// из коллекции users вместо заглушек из старой версии приложения.
  Future<void> _syncParticipantNames(Meeting meeting) async {
    final placeholders = meeting.participants
        .where((p) =>
            p.name.trim().isEmpty || p.name == _placeholderName)
        .toList();
    if (placeholders.isEmpty) return;

    final ids = placeholders.map((p) => p.userId).toSet().toList();
    final liveUsers = await _fetchUsersByIds(ids);
    if (liveUsers.isEmpty) return;

    var changed = false;
    final updated = meeting.participants.map((p) {
      final live = liveUsers[p.userId];
      if (live == null || live.name == p.name) return p;
      changed = true;
      return MeetingParticipant(
        userId: p.userId,
        name: live.name,
        email: live.email,
        role: p.role,
        status: p.status,
      );
    }).toList();

    if (!changed) return;

    try {
      await _firestore.collection(_collection).doc(meeting.id).update({
        'participants': updated.map((p) => p.toJson()).toList(),
      });
    } catch (e) {
      debugPrint('SYNC_PARTICIPANTS_ERROR: $e');
    }
  }

  Future<Map<String, AppUser>> _fetchUsersByIds(List<String> ids) async {
    final result = <String, AppUser>{};
    for (var i = 0; i < ids.length; i += 10) {
      final end = (i + 10) > ids.length ? ids.length : i + 10;
      final chunk = ids.sublist(i, end);
      final snapshot = await _firestore
          .collection('users')
          .where('id', whereIn: chunk)
          .get();
      for (final doc in snapshot.docs) {
        final user = AppUser.fromJson(doc.data());
        result[user.id] = user;
      }
    }
    return result;
  }
}

final meetingRepositoryProvider = Provider<MeetingRepository>(
  (ref) => MeetingRepository(),
);

/// Поток всех встреч пользователя.
final allMeetingsProvider = StreamProvider<List<Meeting>>(
  (ref) => ref.watch(meetingRepositoryProvider).streamMeetings(),
);