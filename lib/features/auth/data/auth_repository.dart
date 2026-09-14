import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/user.dart';
import 'profile_service.dart';

class AuthRepository {
  final FirebaseAuth _firebaseAuth;
  final ProfileService _profileService;

  AuthRepository({
    FirebaseAuth? firebaseAuth,
    ProfileService? profileService,
  })  : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance,
        _profileService = profileService ?? ProfileService();

  Stream<AppUser?> get authStateChanges =>
      _firebaseAuth.authStateChanges().asyncMap((user) async {
        if (user == null) return null;

        // Загружаем профиль из Firestore, чтобы получить роль
        final profile = await _profileService.getProfile(user.uid);
        if (profile != null) return profile;

        // Если профиля ещё нет — создаём временного пользователя
        return _mapFirebaseUser(user);
      });

  Future<AppUser?> get currentUser async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return null;

    final profile = await _profileService.getProfile(user.uid);
    return profile ?? _mapFirebaseUser(user);
  }

  Future<AppUser> signUpWithEmail({
    required String email,
    required String password,
    required String name,
    required UserRole role,
  }) async {
    try {
      final credential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      await credential.user?.updateDisplayName(name);

      final appUser = AppUser(
        id: credential.user!.uid,
        email: credential.user!.email ?? '',
        name: name,
        role: role,
        subjects: const [],
      );

      // Сохраняем профиль в Firestore (там хранится роль)
      await _profileService.saveProfile(appUser);

      return appUser;
    } on FirebaseAuthException catch (e) {
      throw AuthException(
        _mapAuthError(e.code, message: e.message),
      );
    }
  }

  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _firebaseAuth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Загружаем профиль из Firestore
      final profile = await _profileService.getProfile(credential.user!.uid);
      if (profile != null) return profile;

      return _mapFirebaseUser(credential.user!);
    } on FirebaseAuthException catch (e) {
      throw AuthException(
        _mapAuthError(e.code, message: e.message),
      );
    }
  }

  Future<void> signInWithGoogle() async {
    // TODO: Реализация Google Sign-In
    throw UnimplementedError('Google Sign-In пока не подключён');
  }

  Future<void> signOut() => _firebaseAuth.signOut();

  AppUser _mapFirebaseUser(User user, {UserRole? role}) {
    return AppUser(
      id: user.uid,
      email: user.email ?? '',
      name: user.displayName ?? 'Пользователь',
      role: role ?? UserRole.student,
    );
  }

  String _mapAuthError(String code, {String? message}) {
    switch (code) {
      case 'weak-password':
        return 'Пароль слишком короткий (минимум 6 символов)';
      case 'email-already-in-use':
        return 'Этот email уже зарегистрирован';
      case 'invalid-email':
        return 'Некорректный email';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Неверный email или пароль';
      case 'too-many-requests':
        return 'Слишком много попыток. Попробуйте позже';
      case 'network-request-failed':
        return 'Нет соединения с интернетом';
      default:
        return message ?? 'Произошла ошибка при входе';
    }
  }
}

class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(),
);

final authStateProvider = StreamProvider<AppUser?>(
  (ref) => ref.watch(authRepositoryProvider).authStateChanges,
);