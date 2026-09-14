import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/meeting.dart';
import '../../../core/models/user.dart';
import '../../../shared/timezone_utils.dart';
import '../../auth/data/auth_repository.dart';
import '../../video/presentation/meeting_room_page.dart';
import '../data/meeting_repository.dart';

class MeetingDetailPage extends ConsumerWidget {
  const MeetingDetailPage({super.key, required this.meetingId});

  final String meetingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(authStateProvider);
    final meetingAsync = ref.watch(_meetingByIdProvider(meetingId));

    return Scaffold(
      appBar: AppBar(title: const Text('Встреча')),
      body: userAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Ошибка: $e')),
        data: (user) => meetingAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Ошибка: $e')),
          data: (meeting) {
            if (meeting == null) {
              return const Center(child: Text('Встреча не найдена'));
            }
            return _DetailBody(
              meeting: meeting,
              user: user!,
            );
          },
        ),
      ),
    );
  }
}

final _meetingByIdProvider =
    FutureProvider.autoDispose.family<Meeting?, String>(
  (ref, meetingId) =>
      ref.watch(meetingRepositoryProvider).getMeetingById(meetingId),
);

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.meeting, required this.user});

  final Meeting meeting;
  final AppUser user;

  bool get _isTeacher => meeting.teacherId == user.id;
  bool get _isInvited =>
      !meeting.participantIds.contains(user.id) && !_isTeacher;
  bool get _accepted => meeting.participants
      .any((p) => p.userId == user.id && p.status == 'accepted');

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return '${parts.first.characters.first}${parts.last.characters.first}'
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Type badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            meeting.typeLabel,
            style: TextStyle(color: colors.primary),
          ),
        ),
        const SizedBox(height: 16),

        Text(
          meeting.title,
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),

        if (meeting.description != null) ...[
          Text(meeting.description!),
          const SizedBox(height: 16),
        ],

        const Divider(),
        const SizedBox(height: 8),

        // Date & time
        _InfoRow(
          icon: Icons.calendar_today,
          text: formatMeetingFull(meeting.scheduledAt, user.timezone),
        ),
        const SizedBox(height: 12),

        if (user.timezone != null) ...[
          _InfoRow(
            icon: Icons.schedule,
            text: formatTimeZoneName(
              meeting.scheduledAt.toUtc(),
              user.timezone,
            ),
          ),
          const SizedBox(height: 12),
        ],

        _InfoRow(
          icon: Icons.timelapse,
          text: 'Длительность: ${meeting.durationMinutes} минут',
        ),
        const SizedBox(height: 12),

        _InfoRow(
          icon: Icons.person,
          text: _isTeacher
              ? 'Вы — организатор'
              : 'Преподаватель: ${meeting.teacherName}',
        ),
        const SizedBox(height: 16),

        Text(
          'Участники (${meeting.participants.length})',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (meeting.participants.isEmpty)
          Text(
            'Пока нет участников',
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final p in meeting.participants)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: colors.primary.withValues(alpha: 0.12),
                      child: Text(
                        _initials(p.name),
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(p.name),
                    subtitle: Text(p.email),
                    trailing: _StatusChip(
                      status: p.status,
                      isCurrentUser: p.userId == user.id,
                      isTeacher: p.role == 'teacher',
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),

        // Status / actions
        if (meeting.status != MeetingStatus.cancelled) ...[
          if (_isTeacher) ...[
            FilledButton.icon(
              onPressed: () => _openRoom(context, ref, start: true),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.videocam),
              label: Text(
                meeting.status == MeetingStatus.active
                    ? 'Присоединиться к звонку'
                    : 'Начать встречу',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _editMeeting(context, ref),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Редактировать'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _cancelMeeting(context, ref),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.error,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('Отменить встречу'),
            ),
          ] else if (meeting.status == MeetingStatus.active)
            FilledButton.icon(
              onPressed: () => _openRoom(context, ref, start: false),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.videocam),
              label: const Text('Присоединиться к звонку'),
            )
          else if (_isInvited || !_accepted)
            FilledButton.icon(
              onPressed: () => _acceptInvite(context, ref),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.check),
              label: const Text('Принять приглашение'),
            )
          else
            FilledButton.icon(
              onPressed: null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.alarm),
              label: const Text('Ожидаем начала урока'),
            ),
          ],
        ],
      );
  }

  Future<void> _editMeeting(BuildContext context, WidgetRef ref) async {
    final edited =
        await context.push<bool>('/edit-meeting/${meeting.id}');
    if (edited == true) ref.invalidate(_meetingByIdProvider(meeting.id));
  }

  Future<void> _openRoom(
      BuildContext context, WidgetRef ref, {required bool start}) async {
    if (start && meeting.status != MeetingStatus.active) {
      await ref.read(meetingRepositoryProvider).startMeeting(meeting.id);
    }
    if (!context.mounted) return;
    ref.invalidate(_meetingByIdProvider(meeting.id));

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeetingRoomPage(
          meetingId: meeting.id,
          uid: user.id,
          name: user.name,
          isTeacher: _isTeacher,
          onHangup: () async =>
              ref.read(meetingRepositoryProvider).completeMeeting(meeting.id),
        ),
      ),
    );
    ref.invalidate(_meetingByIdProvider(meeting.id));
  }

  Future<void> _acceptInvite(BuildContext context, WidgetRef ref) async {
    await ref
        .read(meetingRepositoryProvider)
        .acceptInvite(meeting.id, user: user);
    ref.invalidate(_meetingByIdProvider(meeting.id));
  }

  Future<void> _cancelMeeting(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отменить встречу?'),
        content: const Text('Встреча будет отменена для всех участников.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor:
                  Theme.of(context).colorScheme.error,
            ),
            child: const Text('Отменить'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(meetingRepositoryProvider).cancelMeeting(meeting.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Встреча отменена')),
        );
        Navigator.of(context).pop();
      }
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.status,
    required this.isCurrentUser,
    required this.isTeacher,
  });

  final String status;
  final bool isCurrentUser;
  final bool isTeacher;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final (label, icon, color) = isCurrentUser
        ? ('Это вы', Icons.person_pin, colors.primary)
        : isTeacher
            ? ('Организатор', Icons.school, colors.primary)
            : status == 'accepted'
                ? ('Принял', Icons.check_circle, Colors.green)
                : ('Приглашён', Icons.schedule, colors.onSurfaceVariant);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Row(
      children: [
        Icon(icon, size: 20, color: colors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ],
    );
  }
}