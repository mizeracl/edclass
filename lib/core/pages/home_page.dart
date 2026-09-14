import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../features/auth/data/auth_repository.dart';
import '../../features/auth/data/profile_service.dart';
import '../../features/calendar/presentation/calendar_page.dart';
import '../../features/users/presentation/teachers_page.dart';
import '../../shared/timezone_utils.dart';
import '../models/user.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(authStateProvider);

    return userAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        body: Center(child: Text('Ошибка: $e')),
      ),
      data: (user) {
        if (user == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            context.go('/login');
          });
          return const Scaffold(body: SizedBox.shrink());
        }
        return HomeScaffold(user: user);
      },
    );
  }
}

class HomeScaffold extends ConsumerStatefulWidget {
  const HomeScaffold({super.key, required this.user});

  final AppUser user;

  @override
  ConsumerState<HomeScaffold> createState() => _HomeScaffoldState();
}

class _HomeScaffoldState extends ConsumerState<HomeScaffold> {
  int _currentTab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _currentTab, children: _pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (index) =>
            setState(() => _currentTab = index),
        destinations: _destinations,
      ),
    );
  }

  List<Widget> get _pages {
    final pages = <Widget>[
      const CalendarPage(),
      if (!widget.user.isTeacher) const TeachersPage(),
      _ProfilePage(user: widget.user),
    ];
    return pages;
  }

  List<NavigationDestination> get _destinations {
    return [
      const NavigationDestination(
        icon: Icon(Icons.calendar_month_outlined),
        selectedIcon: Icon(Icons.calendar_month),
        label: 'Календарь',
      ),
      if (!widget.user.isTeacher)
        const NavigationDestination(
          icon: Icon(Icons.school_outlined),
          selectedIcon: Icon(Icons.school),
          label: 'Учителя',
        ),
      const NavigationDestination(
        icon: Icon(Icons.person_outline),
        selectedIcon: Icon(Icons.person),
        label: 'Профиль',
      ),
    ];
  }
}

class _ProfilePage extends ConsumerWidget {
  const _ProfilePage({required this.user});

  final AppUser user;

  Future<void> _openEditDialog(
      BuildContext context, WidgetRef ref, AppUser user) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _EditProfileDialog(user: user),
    );
    if (saved == true) {
      ref.invalidate(authStateProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 16),
        Center(
          child: CircleAvatar(
            radius: 48,
            backgroundColor: colors.primary,
            child: Text(
              user.initials,
              style: textTheme.headlineLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            user.name,
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            user.isTeacher ? 'Учитель' : 'Ученик',
            style: textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 40),
        Card(
          child: ListTile(
            leading: const Icon(Icons.email_outlined),
            title: const Text('Email'),
            subtitle: Text(user.email),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.key),
            title: const Text('Статус'),
            subtitle: const Text('Активный пользователь'),
            trailing: const Icon(Icons.check_circle, color: Colors.green),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.cake_outlined),
            title: const Text('Дата рождения'),
            subtitle: Text(
              user.birthDate != null
                  ? DateFormat('d MMMM yyyy').format(user.birthDate!)
                  : 'Не указана',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Часовой пояс'),
            subtitle: Text(
              user.timezone != null
                  ? formatTimeZoneName(DateTime.now().toUtc(), user.timezone)
                  : 'Местное время устройства',
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () =>
              _openEditDialog(context, ref, user),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Редактировать профиль'),
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: () async {
            await ref.read(authRepositoryProvider).signOut();
            if (context.mounted) context.go('/login');
          },
          icon: const Icon(Icons.logout),
          label: const Text('Выйти'),
        ),
      ],
    );
  }
}

class _EditProfileDialog extends ConsumerStatefulWidget {
  const _EditProfileDialog({required this.user});

  final AppUser user;

  @override
  ConsumerState<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends ConsumerState<_EditProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController =
      TextEditingController(text: widget.user.name);
  late DateTime? _birthDate = widget.user.birthDate;
  late String? _timezone = widget.user.timezone;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(now.year - 120),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => _birthDate = picked);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      await ref.read(profileServiceProvider).updateProfile(
            widget.user.id,
            name: _nameController.text.trim(),
            birthDate: _birthDate,
            timezone: _timezone,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Профиль сохранён')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Редактировать профиль'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Имя и фамилия',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите имя';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: _pickBirthDate,
                borderRadius: BorderRadius.circular(12),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Дата рождения',
                    prefixIcon: Icon(Icons.cake_outlined),
                    suffixIcon: Icon(Icons.arrow_drop_down),
                  ),
                  child: Text(
                    _birthDate != null
                        ? DateFormat('d MMMM yyyy').format(_birthDate!)
                        : 'Не указана',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: _timezone,
                decoration: const InputDecoration(
                  labelText: 'Часовой пояс',
                  prefixIcon: Icon(Icons.schedule),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Местное время устройства'),
                  ),
                  for (final tzName in kTimezoneOptions)
                    DropdownMenuItem<String?>(
                      value: tzName,
                      child: Text(tzName),
                    ),
                ],
                onChanged: (value) => setState(() => _timezone = value),
              ),
              if (_timezone != null) ...[
                const SizedBox(height: 8),
                Text(
                  formatTimeZoneName(DateTime.now().toUtc(), _timezone),
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Сохранить'),
        ),
      ],
    );
  }
}
