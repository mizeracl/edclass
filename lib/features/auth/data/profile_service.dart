import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/user.dart';

class ProfileService {
  final FirebaseFirestore _firestore;

  static const String _collection = 'users';

  ProfileService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  Future<void> saveProfile(AppUser user) async {
    await _firestore.collection(_collection).doc(user.id).set({
      'id': user.id,
      'email': user.email,
      'name': user.name,
      'role': user.role.name,
      'avatar_url': user.avatarUrl,
      'subjects': user.subjects,
      'birth_date': user.birthDate,
      'timezone': user.timezone,
      'created_at': FieldValue.serverTimestamp(),
    });
  }

  Future<AppUser?> getProfile(String uid) async {
    // Короткий ретрай: профиль может создаваться в тот же момент,
    // что и событие входа (Firebase Auth иногда срабатывает раньше Firestore)
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final doc = await _firestore.collection(_collection).doc(uid).get();
        if (doc.exists) {
          return AppUser.fromJson(doc.data()!);
        }
      } on FirebaseException {
        // Права доступа не настроены или нет сети
        return null;
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    return null;
  }

  Future<void> updateProfile(
    String uid, {
    String? name,
    String? avatarUrl,
    DateTime? birthDate,
    String? timezone,
  }) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (avatarUrl != null) data['avatar_url'] = avatarUrl;
    if (birthDate != null) data['birth_date'] = birthDate;
    if (timezone != null) data['timezone'] = timezone;
    if (data.isNotEmpty) {
      await _firestore.collection(_collection).doc(uid).update(data);
    }
  }
}

final profileServiceProvider = Provider<ProfileService>(
  (ref) => ProfileService(),
);