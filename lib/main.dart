import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/config/firebase_options.dart';
import 'shared/timezone_utils.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // На платформах без настроенной Google-конфигурации Firebase
    // продолжаем работу — приложение откроется, а регистрация/вход будут
    // сообщать о недоступности сервиса.
    debugPrint('Firebase init failed: $e');
  }
  ensureTimezonesInitialized();
  runApp(const EdClassApp());
}