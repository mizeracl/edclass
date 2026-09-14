import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/user.dart';

class UserRepository {
  final FirebaseFirestore _firestore;

  static const String _collection = 'users';

  UserRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  Stream<List<AppUser>> streamTeachers() {
    return _firestore
        .collection(_collection)
        .where('role', isEqualTo: 'teacher')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => AppUser.fromJson(doc.data()))
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())));
  }

  Stream<List<AppUser>> streamStudents() {
    return _firestore
        .collection(_collection)
        .where('role', isEqualTo: 'student')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => AppUser.fromJson(doc.data()))
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())));
  }
}

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => UserRepository(),
);

final teachersProvider = StreamProvider<List<AppUser>>(
  (ref) => ref.watch(userRepositoryProvider).streamTeachers(),
);

final studentsProvider = StreamProvider<List<AppUser>>(
  (ref) => ref.watch(userRepositoryProvider).streamStudents(),
);