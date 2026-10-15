import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../product.dart';
import '../ui/ui.dart';
import 'update_service.dart';

import 'package:rillight/app/ui/app_icons.dart';

/// Shared by desktop/TV settings and the phone's About section.
class UpdateCheck extends StatefulWidget {
  const UpdateCheck({super.key, this.check, this.openRelease});
  final Future<AppRelease> Function()? check;
  final Future<bool> Function(Uri)? openRelease;

  @override
  State<UpdateCheck> createState() => _UpdateCheckState();
}

class _UpdateCheckState extends State<UpdateCheck> {
  final _service = UpdateService();
  bool _busy = false;
  bool _opening = false;
  bool _failed = false;
  bool _openFailed = false;
  AppRelease? _release;

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
      _openFailed = false;
      _release = null;
    });
    try {
      final release = await (widget.check ?? _service.check)();
      if (mounted) setState(() => _release = release);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    final release = _release;
    if (release == null || _opening) return;
    setState(() {
      _opening = true;
      _openFailed = false;
    });
    try {
      final opened =
          await (widget.openRelease?.call(release.url) ??
              launchUrl(release.url, mode: LaunchMode.externalApplication));
      if (mounted) setState(() => _openFailed = !opened);
    } catch (_) {
      if (mounted) setState(() => _openFailed = true);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final release = _release;
    final newer = release?.isNewerThan(kAppVersion) ?? false;
    final message = _busy
        ? l.updateChecking
        : _failed
        ? l.updateCheckFailed
        : release == null
        ? l.mobileVersion(kAppVersion)
        : newer
        ? l.updateAvailable(release.version.toString())
        : l.updateCurrent;
    return Column(
      key: const Key('app-update-check'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, key: const Key('app-update-status')),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppButton.icon(
              key: const Key('app-update-check-button'),
              onPressed: _busy ? null : _check,
              icon: _busy
                  ? const CupertinoActivityIndicator()
                  : const Icon(
                      AppIcons.refresh,
                      fill: AppIcons.filled,
                      size: 18,
                    ),
              label: Text(l.updateCheck),
            ),
            if (newer)
              AppButton(
                key: const Key('app-update-open'),
                onPressed: _opening ? null : _open,
                child: Text(l.updateOpenRelease),
              ),
          ],
        ),
        if (newer && release != null && release.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          AppDisclosure(
            title: Text(l.updateNotes),
            children: [AppSelectableText(release.notes)],
          ),
        ],
        if (_openFailed && release != null) ...[
          const SizedBox(height: 8),
          Text(l.updateOpenFailed),
          AppSelectableText(release.url.toString()),
        ],
      ],
    );
  }
}
