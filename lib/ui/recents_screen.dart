import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../data/contact_discovery.dart';
import '../data/models.dart';
import 'theme/modernist.dart';

/// Call history, both directions. Missed calls render in accent (red). Tapping
/// a row calls that person back in the row's mode.
///
/// "Missed" is only ever said of an INCOMING call. A call you placed that went
/// unanswered also ends up in `CallState.missed` — the callee's ring timed out —
/// but calling that "missed" on the caller's own screen would blame them for
/// not answering their own call, and colouring it red would put a permanent
/// alarm on the list of people who were simply out.
class RecentsScreen extends StatefulWidget {
  const RecentsScreen({
    super.key,
    required this.recents,
    required this.names,
    required this.avatars,
    required this.myUid,
    required this.onCall,
  });

  final List<CallDoc> recents;
  final ContactNames names;
  final PeerAvatars avatars;

  /// Which side of each call we were on — the only thing that distinguishes an
  /// incoming record from an outgoing one.
  final String myUid;
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
        .where((c) =>
            !_missedOnly ||
            (c.state == CallState.missed && c.callerId != widget.myUid))
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
                      avatars: widget.avatars,
                      myUid: widget.myUid,
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
  const _RecentRow({
    required this.call,
    required this.names,
    required this.avatars,
    required this.myUid,
    required this.onCall,
  });

  final CallDoc call;
  final ContactNames names;
  final PeerAvatars avatars;
  final String myUid;
  final void Function(Contact contact, {required bool video}) onCall;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final outgoing = call.callerId == myUid;
    // Only an incoming call can be missed — see the note on RecentsScreen.
    final missed = call.state == CallState.missed && !outgoing;
    // The same state on the other side of a call: we rang and nobody picked up.
    // Worth saying plainly — "did they answer?" is the first thing you want
    // from your own call list — but it is not an alarm the way a missed call
    // is, so it gets its own wording and icon rather than the accent colour.
    //
    // Only `missed` counts. `cancelled` also ends up here when the caller gave
    // up first, and it is additionally what a failed media connect writes, so
    // labelling that "no answer" would blame the callee for our own failure.
    final noAnswer = outgoing && call.state == CallState.missed;

    // The peer is whichever side we were not. The record carries the CALLER's
    // name and phone, so for an outgoing call there is nothing stored about the
    // person we rang and the address book has to supply it — which it can,
    // because you can only place a call to someone the Contacts screen matched
    // there in the first place.
    final peerUid = outgoing ? call.calleeId : call.callerId;
    final resolved =
        names.resolve(peerUid, outgoing ? '' : call.callerName).trim();
    final name = resolved.isEmpty ? loc.recentsUnknownPeer : resolved;
    // Likewise: no stored callee phone. It only feeds the native call screen's
    // subtitle, so an empty one costs nothing.
    final peerPhone = outgoing ? '' : call.callerPhone;

    final dir = missed
        ? loc.dirMissed
        : noAnswer
            ? loc.dirNoAnswer
            : outgoing
                ? loc.dirOutgoing
                : loc.dirIncoming;
    final kind = call.isVideo ? loc.kindVideo : loc.kindVoice;
    final nameColor = missed ? Mod.accent : Mod.text;

    return Semantics(
      button: true,
      label: '$name. $dir · $kind. ${loc.callContact(name)}',
      child: InkWell(
        onTap: () => onCall(
          Contact(uid: peerUid, displayName: name, phone: peerPhone),
          video: call.isVideo,
        ),
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Mod.rowDivider))),
          padding: const EdgeInsets.symmetric(horizontal: Mod.s6, vertical: Mod.s3),
          child: ExcludeSemantics(
            child: Row(
              children: [
                InitialsTile(name: name, imageUrl: avatars.urlFor(peerUid)),
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
                          // Direction at a glance; the kind stays in the text
                          // beside it. Separated by CONTRAST rather than hue:
                          // the palette is near-mono red-on-off-white, and the
                          // one saturated colour it has is already spoken for
                          // by "missed". Dark = someone called you, light =
                          // you called them, red = you missed one. Contrast
                          // also survives colour-blindness, which hue would
                          // not, and the row's text says the direction anyway.
                          // Colour carries the direction; the arrow shape
                          // repeats it for anyone who cannot separate the hues.
                          Icon(
                            missed
                                ? Icons.call_missed
                                : noAnswer
                                    ? Icons.call_missed_outgoing
                                    : outgoing
                                        ? Icons.call_made
                                        : Icons.call_received,
                            // 13 was too small to read an arrow's direction.
                            size: 16,
                            color: missed || noAnswer
                                ? Mod.callUnanswered
                                : outgoing
                                    ? Mod.callOutgoing
                                    : Mod.callIncoming,
                          ),
                          const SizedBox(width: 5),
                          // The label stays grey except when unanswered: three
                          // coloured labels down the list would compete with
                          // the names, and the arrow already carries direction.
                          Text('$dir · $kind',
                              style: Mod.meta(
                                  color: missed || noAnswer
                                      ? Mod.callUnanswered
                                      : Mod.neutral600)),
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
