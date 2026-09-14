import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../../core/models/meeting.dart';
import '../../../shared/timezone_utils.dart';
import '../../../shared/widgets/error_card.dart';
import '../../auth/data/auth_repository.dart';
import '../data/meeting_repository.dart';
import 'meeting_detail_page.dart';

class CalendarPage extends ConsumerWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meetingsAsync = ref.watch(allMeetingsProvider);
    final userAsync = ref.watch(authStateProvider);

    return Scaffold(
      body: userAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: ErrorCard(title: 'Ошибка загрузки профиля', error: e),
        ),
        data: (user) => meetingsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: ErrorCard(title: 'Ошибка загрузки встреч', error: e),
          ),
          data: (meetings) => _CalendarView(
            meetings: meetings,
            isTeacher: user?.isTeacher ?? false,
            timezone: user?.timezone,
          ),
        ),
      ),
    );
  }
}

class _CalendarView extends ConsumerStatefulWidget {
  const _CalendarView({
    required this.meetings,
    required this.isTeacher,
    this.timezone,
  });

  final List<Meeting> meetings;
  final bool isTeacher;
  final String? timezone;

  @override
  ConsumerState<_CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends ConsumerState<_CalendarView> {
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  // Все предстоящие встречи (ещё не прошли, не отменены)
  List<Meeting> get _upcomingMeetings {
    final now = DateTime.now();
    return widget.meetings
        .where((m) =>
            m.scheduledAt.isAfter(now) &&
            m.status != MeetingStatus.cancelled)
        .toList()
      ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
  }

  Map<DateTime, List<Meeting>> _groupByDay(List<Meeting> meetings) {
    final map = <DateTime, List<Meeting>>{};
    for (final meeting in meetings) {
      final local = asUserLocal(meeting.scheduledAt, widget.timezone);
      final day = DateTime(local.year, local.month, local.day);
      map.putIfAbsent(day, () => []).add(meeting);
    }
    return map;
  }

  void _goToCreateMeeting() {
    context.push('/create-meeting');
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final grouped = _groupByDay(widget.meetings);
    final upcoming = _upcomingMeetings;

    return DefaultTabController(
      length: 2,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Календарь',
                    style: textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (widget.isTeacher)
                  FilledButton.icon(
                    onPressed: _goToCreateMeeting,
                    icon: const Icon(Icons.add),
                    label: const Text('Встреча'),
                  ),
              ],
            ),
          ),

          // Calendar (не растягивается на весь экран — вся страница скроллится)
          Card(
            margin: const EdgeInsets.all(16),
            child: TableCalendar(
              firstDay: DateTime(DateTime.now().year - 1),
              lastDay: DateTime(DateTime.now().year + 2),
              focusedDay: _focusedDay,
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
              eventLoader: (day) => grouped[day] ?? const [],
              shouldFillViewport: false,
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                });
              },
              onPageChanged: (focusedDay) =>
                  setState(() => _focusedDay = focusedDay),
              calendarFormat: CalendarFormat.month,
              startingDayOfWeek: StartingDayOfWeek.monday,
              locale: 'ru_RU',
              headerStyle: const HeaderStyle(
                formatButtonVisible: false,
                titleCentered: true,
              ),
              calendarStyle: const CalendarStyle(
                outsideDaysVisible: false,
                markerDecoration: BoxDecoration(
                  color: Colors.transparent,
                ),
                markerSize: 0,
                todayDecoration: BoxDecoration(
                  color: Color(0x224F46E5),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),

          // Upcoming meetings list
          if (upcoming.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  Text(
                    'Предстоящие встречи',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${upcoming.length}',
                    style: textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          if (upcoming.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: _EmptyDay(
                icon: const Icon(
                  Icons.event_note,
                  size: 56,
                  color: Colors.transparent,
                ),
                text: 'Предстоящих встреч нет',
              ),
            )
          else
            for (final meeting in upcoming)
              _MeetingTile(
                meeting: meeting,
                timezone: widget.timezone,
                showDate: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MeetingDetailPage(meetingId: meeting.id),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay({this.icon, this.text = 'В этот день встреч нет'});

  final Widget? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon ?? Icon(Icons.event_busy, size: 56, color: colors.outline),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _MeetingTile extends StatelessWidget {
  const _MeetingTile({
    required this.meeting,
    required this.onTap,
    this.timezone,
    this.showDate = false,
  });

  final Meeting meeting;
  final VoidCallback onTap;
  final String? timezone;
  final bool showDate;

  static const _typeColors = {
    MeetingType.camera: Color(0xFF4F46E5),
    MeetingType.screen: Color(0xFFE67E22),
    MeetingType.both: Color(0xFF7C3AED),
  };

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final color = _typeColors[meeting.type] ?? primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 48,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meeting.title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${showDate ? '${formatMeetingDay(meeting.scheduledAt, timezone)} · ' : ''}'
                      '${formatMeetingTime(meeting.scheduledAt, timezone)} · '
                      '${meeting.teacherName}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    if (meeting.participants.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'С: ${meeting.participantNamesLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              _TypeBadge(type: meeting.type, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type, required this.color});

  final MeetingType type;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (type) {
      MeetingType.camera => (Icons.videocam, 'Видео'),
      MeetingType.screen => (Icons.monitor, 'Экран'),
      MeetingType.both => (Icons.video_call, 'Оба'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
  }
}