// Manage the people whose voices the app can recognise.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';

class PeoplePage extends StatelessWidget {
  const PeoplePage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final people = provider.people;

    return Scaffold(
      appBar: AppBar(title: const Text('People & Voices')),
      body: people.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No one yet.\n\nOpen a conversation and tap a speaker to name '
                  'them. The app learns each person\'s voice from the clips '
                  'you label and recognises them in future conversations.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                for (final p in people)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(p.name.characters.first.toUpperCase()),
                    ),
                    title: Text(p.name),
                    subtitle: Text(
                      p.sampleCount == 0
                          ? 'No voice samples yet'
                          : '${p.sampleCount} voice sample${p.sampleCount == 1 ? '' : 's'}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) async {
                        if (action == 'rename') {
                          final name = await _askName(context, p.name);
                          if (name != null && name.trim().isNotEmpty) {
                            await provider.renamePerson(p.id, name);
                          }
                        } else if (action == 'delete') {
                          final ok = await _confirmDelete(context, p.name);
                          if (ok == true) await provider.deletePerson(p.id);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete voice & person'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Future<String?> _askName(BuildContext context, String current) {
    return showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: current),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, String name) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text(
          'Their saved voice samples are deleted, so they will no longer be '
          'recognised. Names already shown in past transcripts stay as text.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
