import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/meeting.dart';
import '../../../shared/timezone_utils.dart';
import '../../../shared/widgets/error_card.dart';
import '../../auth/data/auth_repository.dart';
import '../../users/data/user_repository.dart';
import '../data/meeting_repository.dart';

class CreateMeetingPage extends ConsumerStatefulWidget {
  const CreateMeetingPage({super.key, this.meetingId});

  final String? meetingId;

  @override
  ConsumerState<CreateMeetingPage> createState() => _CreateMeetingPageState();
}

class _CreateMeetingPageState extends ConsumerState<CreateMeetingPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  MeetingType _type = MeetingType.both;
  DateTime _date = DateTime.now().add(const Duration(days: 1));
  TimeOfDay _time = const TimeOfDay(hour: 10, minute: 0);
  int _durationMinutes = 60;
  bool _isLoading = false;
  bool _initialLoading = false;
  Meeting? _existing;
  final Set<String> _selectedStudentIds = {};

  bool get _isEdit => widget.meetingId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) _loadExisting();
  }

  Future<void> _loadExisting() async {
    setState(() => _initialLoading = true);
    try {
      final user = await ref.read(authRepositoryProvider).currentUser;
      final meeting = await ref
          .read(meetingRepositoryProvider)
          .getMeetingById(widget.meetingId!);
      if (!mounted) return;
      if (meeting == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Встреча не найдена')),
        );
        context.pop();
        return;
      }

      final local = asUserLocal(meeting.scheduledAt, user?.timezone);
      _titleController.text = meeting.title;
      _descriptionController.text = meeting.description ?? '';
      _type = meeting.type;
      _date = DateTime(local.year, local.month, local.day);
      _time = TimeOfDay(hour: local.hour, minute: local.minute);
      _durationMinutes = meeting.durationMinutes;
      _selectedStudentIds
        ..clear()
        ..addAll(meeting.participantIds);
      _existing = meeting;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
        context.pop();
      }
    } finally {
      if (mounted) setState(() => _initialLoading = false);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final first = DateTime.now().subtract(const Duration(days: 1));
    final initial = _date.isBefore(first) ? DateTime.now() : _date;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
    );
    if (picked != null) {
      setState(() => _time = picked);
    }
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final user = await ref.read(authRepositoryProvider).currentUser;
      if (user == null) {
        throw StateError('Пользователь не авторизован');
      }

      final students =
          await ref.read(userRepositoryProvider).streamStudents().first;

      final selectedStudents = students
          .where((s) => _selectedStudentIds.contains(s.id))
          .toList();

      final scheduledAt = buildScheduledInstant(
        year: _date.year,
        month: _date.month,
        day: _date.day,
        hour: _time.hour,
        minute: _time.minute,
        tzName: user.timezone,
      );

      final existingStatuses = {
        for (final p in _existing?.participants ?? const <MeetingParticipant>[])
          p.userId: p.status,
      };

      final participants = selectedStudents
          .map((s) => MeetingParticipant(
                userId: s.id,
                name: s.name,
                email: s.email,
                role: 'student',
                status: existingStatuses[s.id] ?? 'invited',
              ))
          .toList();

      final repo = ref.read(meetingRepositoryProvider);
      if (_isEdit) {
        await repo.updateMeeting(
          meetingId: widget.meetingId!,
          teacherId: user.id,
          teacherName: user.name,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          type: _type,
          scheduledAt: scheduledAt,
          durationMinutes: _durationMinutes,
          participantIds: selectedStudents.map((s) => s.id).toList(),
          participants: participants,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Изменения сохранены')),
          );
          context.pop(true);
        }
        return;
      }

      await repo.createMeeting(
            teacher: user,
            title: _titleController.text.trim(),
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
            type: _type,
            scheduledAt: scheduledAt,
            durationMinutes: _durationMinutes,
            participantIds: selectedStudents.map((s) => s.id).toList(),
            participants: participants,
          );

      if (mounted) {
        final count = selectedStudents.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count > 0
                  ? 'Встреча создана. Приглашено: $count'
                  : 'Встреча создана',
            ),
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Редактировать встречу' : 'Новая встреча'),
      ),
      body: SafeArea(
        child: _initialLoading
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
              // Title
              TextFormField(
                controller: _titleController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  hintText: 'Например: Алгебра — урок 5',
                  prefixIcon: Icon(Icons.title),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите название встречи';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Description
              TextFormField(
                controller: _descriptionController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Описание (необязательно)',
                  prefixIcon: Icon(Icons.notes),
                ),
              ),
              const SizedBox(height: 24),

              // Type
              Text(
                'Тип встречи',
                style: textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SegmentedButton<MeetingType>(
                segments: const [
                  ButtonSegment(
                    value: MeetingType.camera,
                    icon: Icon(Icons.videocam_outlined),
                    label: Text('Видео'),
                  ),
                  ButtonSegment(
                    value: MeetingType.screen,
                    icon: Icon(Icons.monitor_outlined),
                    label: Text('Экран'),
                  ),
                  ButtonSegment(
                    value: MeetingType.both,
                    icon: Icon(Icons.video_call_outlined),
                    label: Text('Оба'),
                  ),
                ],
                selected: {_type},
                onSelectionChanged: (selection) =>
                    setState(() => _type = selection.first),
              ),
              const SizedBox(height: 24),

              // Date & time
              Text(
                'Дата и время',
                style: textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _PickerTile(
                      icon: Icons.calendar_today,
                      label: _formatDate(_date),
                      onTap: _pickDate,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _PickerTile(
                      icon: Icons.schedule,
                      label: _time.format(context),
                      onTap: _pickTime,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Duration
              Text(
                'Длительность: $_durationMinutes минут',
                style: textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              Slider(
                value: _durationMinutes.toDouble(),
                min: 15,
                max: 180,
                divisions: 11,
                label: '$_durationMinutes мин',
                onChanged: (value) =>
                    setState(() => _durationMinutes = value.toInt()),
              ),
              const SizedBox(height: 24),

              // Participants
              Text(
                'Участники',
                style: textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'Выберите учеников для приглашения',
                style: textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              _StudentPicker(
                selectedIds: _selectedStudentIds,
                onChanged: (Set<String> ids) =>
                    setState(() => _selectedStudentIds..clear()..addAll(ids)),
              ),
              const SizedBox(height: 24),

              // Submit
              FilledButton.icon(
                onPressed: _isLoading ? null : _handleSubmit,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(_isEdit ? Icons.save_outlined : Icons.event_available),
                label: Text(_isEdit ? 'Сохранить изменения' : 'Создать встречу'),
              ),
                ],
              ),
            ),
          ),
        );
  }

  String _formatDate(DateTime date) {
    const months = [
      'января', 'февраля', 'марта', 'апреля',
      'мая', 'июня', 'июля', 'августа',
      'сентября', 'октября', 'ноября', 'декабря',
    ];
    return '${date.day} ${months[date.month - 1]}';
  }
}

class _StudentPicker extends ConsumerWidget {
  const _StudentPicker({
    required this.selectedIds,
    required this.onChanged,
  });

  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final studentsAsync = ref.watch(studentsProvider);

    return studentsAsync.when(
      loading: () => const SizedBox(
        height: 80,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ErrorCard(
        title: 'Ошибка загрузки списка учеников',
        error: e,
      ),
      data: (students) {
        if (students.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Пока нет зарегистрированных учеников',
                  ),
                ),
              ],
            ),
          );
        }

        return Container(
          constraints: const BoxConstraints(maxHeight: 220),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: students.length,
            itemBuilder: (context, index) {
              final student = students[index];
              final isSelected = selectedIds.contains(student.id);

              return CheckboxListTile(
                dense: true,
                value: isSelected,
                title: Text(student.name),
                subtitle: Text(student.email),
                secondary: CircleAvatar(
                  child: Text(student.initials),
                ),
                onChanged: (checked) {
                  final ids = Set<String>.from(selectedIds);
                  if (checked == true) {
                    ids.add(student.id);
                  } else {
                    ids.remove(student.id);
                  }
                  onChanged(ids);
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}