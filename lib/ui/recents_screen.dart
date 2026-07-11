import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../data/contact_discovery.dart';
import '../data/models.dart';
import 'theme/modernist.dart';

/// Call history. Missed calls render in accent (red). Tapping a row calls that
/// person back in the row's mode.
///
/// First pass: incoming calls only (the existing query). Outgoing history needs
/// a small schema/index addition and lands next.
class RecentsScreen extends StatefulWidget {
  const RecentsScreen({
    super.key,
    required this.recents,
    required this.names,
    required this.onCall,
  });

  final List<CallDoc> recents;
  final ContactNames names;
  final void Function(Contact contact, {required bool video}) onCall;

  @override
  State<RecentsScreen> createState() => _RecentsScreenState();
}

class _RecentsScreenState extends State<RecentsScreen> {
  bool _missedOnly = false;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final rows = widget.recents
        .where((c) => !_missedOnly || c.state == CallState.missed)
        .toList();
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s4, Mod.s6, Mod.s3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(loc.recentsTitle, style: Mod.h2()),
                const SizedBox(height: 2),
                Text(loc.recentsHint, style: Mod.meta()),
              ],
            ),
          ),
          _filterTabs(loc),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Mod.s8),
                      child: Text(loc.recentsEmpty, style: Mod.body()),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: rows.length,
                    itemBuilder: (_, i) => _RecentRow(
                      call: rows[i],
                      names: widget.names,
                      onCall: widget.onCall,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterTabs(AppLocalizations loc) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Mod.divider, width: 2),
          bottom: BorderSide(color: Mod.divider, width: 2),
        ),
      ),
      child: Row(
        children: [
          _tab(loc.filterAll, !_missedOnly, () => setState(() => _missedOnly = false)),
          Container(width: 2, height: 44, color: Mod.divider),
          _tab(loc.filterMissed, _missedOnly, () => setState(() => _missedOnly = true)),
        ],
      ),
    );
  }

  Widget _tab(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            color: active ? Mod.accent : null,
            child: ExcludeSemantics(
              child: Text(label,
                  style: Mod.caption(color: active ? Mod.bg : Mod.text)
                      .copyWith(fontSize: 13)),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.call, required this.names, required this.onCall});

  final CallDoc call;
  final ContactNames names;
  final void Function(Contact contact, {required bool video}) onCall;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final missed = call.state == CallState.missed;
    // Prefer the name from the user's own address book over the server name.
    final name = names.resolve(call.callerId, call.callerName);
    final dir = missed ? loc.dirMissed : loc.dirIncoming;
    final kind = call.isVideo ? loc.kindVideo : loc.kindVoice;
    final nameColor = missed ? Mod.accent : Mod.text;

    return Semantics(
      button: true,
      label: '$name. $dir · $kind. ${loc.callContact(name)}',
      child: InkWell(
        onTap: () => onCall(
          Contact(uid: call.callerId, displayName: name, phone: call.callerPhone),
          video: call.isVideo,
        ),
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Mod.rowDivider))),
          padding: const EdgeInsets.symmetric(horizontal: Mod.s6, vertical: Mod.s3),
          child: ExcludeSemantics(
            child: Row(
              children: [
                InitialsTile(name: name),
                const SizedBox(width: Mod.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: Mod.name(color: nameColor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            call.isVideo ? Icons.videocam : Icons.call,
                            size: 13,
                            color: missed ? Mod.accent : Mod.neutral600,
                          ),
                          const SizedBox(width: 5),
                          Text('$dir · $kind',
                              style: Mod.meta(
                                  color: missed ? Mod.accent : Mod.neutral600)),
                        ],
                      ),
                    ],
                  ),
                ),
                Text(_formatTime(call.createdAt), style: Mod.time()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    if (sameDay) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
  }
}
