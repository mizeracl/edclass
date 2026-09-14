import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/login_page.dart';
import '../../features/auth/presentation/register_page.dart';
import '../../features/calendar/presentation/create_meeting_page.dart';
import '../pages/home_page.dart';
import '../pages/splash_page.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      name: 'splash',
      builder: (context, state) => const SplashPage(),
    ),
    GoRoute(
      path: '/login',
      name: 'login',
      builder: (context, state) => const LoginPage(),
    ),
    GoRoute(
      path: '/register',
      name: 'register',
      builder: (context, state) => const RegisterPage(),
    ),
    GoRoute(
      path: '/home',
      name: 'home',
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: '/create-meeting',
      name: 'create-meeting',
      builder: (context, state) => const CreateMeetingPage(),
    ),
    GoRoute(
      path: '/edit-meeting/:meetingId',
      name: 'edit-meeting',
      builder: (context, state) => CreateMeetingPage(
        meetingId: state.pathParameters['meetingId'],
      ),
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(
      child: Text('Страница не найдена: ${state.uri}'),
    ),
  ),
);