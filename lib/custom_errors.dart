import 'dart:io';

import 'package:android_package_installer/android_package_installer.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/app_dialog_theme.dart';
import 'package:provider/provider.dart';

class ObtainiumError {
  late String message;
  bool unexpected;
  ObtainiumError(this.message, {this.unexpected = false});
  @override
  String toString() {
    return message;
  }
}

class RateLimitError extends ObtainiumError {
  late int remainingMinutes;
  RateLimitError(this.remainingMinutes)
    : super(plural('tooManyRequestsTryAgainInMinutes', remainingMinutes));
}

class InvalidURLError extends ObtainiumError {
  InvalidURLError(String sourceName)
    : super(tr('invalidURLForSource', args: [sourceName]));
}

class CredsNeededError extends ObtainiumError {
  CredsNeededError(String sourceName)
    : super(tr('requiresCredentialsInSettings', args: [sourceName]));
}

class NoReleasesError extends ObtainiumError {
  NoReleasesError({String? note})
    : super(
        '${tr('noReleaseFound')}${note?.isNotEmpty == true ? '\n\n$note' : ''}',
      );
}

class NoAPKError extends ObtainiumError {
  NoAPKError() : super(tr('noAPKFound'));
}

class NoVersionError extends ObtainiumError {
  NoVersionError() : super(tr('noVersionFound'));
}

class UnsupportedURLError extends ObtainiumError {
  UnsupportedURLError() : super(tr('urlMatchesNoSource'));
}

class DowngradeError extends ObtainiumError {
  DowngradeError(int currentVersionCode, int newVersionCode)
    : super(
        '${tr('cantInstallOlderVersion')} (versionCode $currentVersionCode ➔ $newVersionCode)',
      );
}

class InstallError extends ObtainiumError {
  InstallError(int code)
    : super(PackageInstallerStatus.byCode(code).name.substring(7));
}

class IDChangedError extends ObtainiumError {
  IDChangedError(String newId) : super('${tr('appIdMismatch')} - $newId');
}

class RepositoryRenamedError extends ObtainiumError {
  final String oldUrl;
  final String newUrl;
  RepositoryRenamedError(this.oldUrl, this.newUrl) : super(tr('repoRenamed'));
}

class DownloadCancelledError extends ObtainiumError {
  DownloadCancelledError() : super(tr('cancelled'));
}

/// Thrown when a background/silent install is skipped because its
/// VirusTotal scan came back flagged or errored and there was no one to ask
/// (see the install-flow rules in apps_provider.dart). Carries [status]/
/// [detail] so the catch site can fire a notification naming the specific
/// reason, distinct from a generic install failure.
class MalwareScanBlockedError extends ObtainiumError {
  final String status;
  final String? detail;
  MalwareScanBlockedError(this.status, this.detail, {required String appName})
    : super(
        tr(
          status == malwareScanStatusFlagged
              ? 'malwareScanFlaggedSkippedTitle'
              : 'malwareScanErrorSkippedTitle',
          args: [appName],
        ),
      );
}

class NotImplementedError extends ObtainiumError {
  NotImplementedError() : super(tr('functionNotImplemented'));
}

class MultiAppMultiError extends ObtainiumError {
  Map<String, dynamic> rawErrors = {};
  Map<String, List<String>> idsByErrorString = {};
  Map<String, String> appIdNames = {};

  MultiAppMultiError() : super(tr('placeholder'), unexpected: true);

  void add(String appId, dynamic error, {String? appName}) {
    if (error is SocketException) {
      error = error.message;
    }
    rawErrors[appId] = error;
    var string = error.toString();
    var tempIds = idsByErrorString.remove(string);
    tempIds ??= [];
    tempIds.add(appId);
    idsByErrorString.putIfAbsent(string, () => tempIds!);
    if (appName != null) {
      appIdNames[appId] = appName;
    }
  }

  String errorString(String appId, {bool includeIdsWithNames = false}) =>
      '${appIdNames.containsKey(appId) ? '${appIdNames[appId]}${includeIdsWithNames ? ' ($appId)' : ''}' : appId}: ${rawErrors[appId].toString()}';

  String errorsAppsString(
    String errString,
    List<String> appIds, {
    bool includeIdsWithNames = false,
  }) =>
      '$errString [${list2FriendlyString(appIds.map((id) => appIdNames.containsKey(id) == true ? '${appIdNames[id]}${includeIdsWithNames ? ' ($id)' : ''}' : id).toList())}]';

  @override
  String toString() => idsByErrorString.entries
      .map((e) => errorsAppsString(e.key, e.value))
      .join('\n\n');
}

void showMessage(
  dynamic e,
  BuildContext context, {
  bool isError = false,
  ThemeData? theme,
}) {
  Provider.of<LogsProvider>(
    context,
    listen: false,
  ).add(e.toString(), level: isError ? LogLevels.error : LogLevels.info);
  if (e is String || (e is ObtainiumError && !e.unexpected)) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(e.toString()),
        duration: const Duration(seconds: 4),
      ),
    );
  } else {
    showDialog(
      context: context,
      builder: (BuildContext ctx) {
        final Widget dialog = AlertDialog(
          scrollable: true,
          contentPadding: appDialogContentPadding,
          title: Text(
            e is MultiAppMultiError
                ? tr(isError ? 'someErrors' : 'updates')
                : tr(isError ? 'unexpectedError' : 'unknown'),
          ),
          content: GestureDetector(
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: e.toString()));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(tr('copiedToClipboard')),
                  duration: const Duration(seconds: 4),
                ),
              );
            },
            child: Text(e.toString()),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(null);
              },
              child: Text(tr('ok')),
            ),
          ],
        );
        return theme == null ? dialog : Theme(data: theme, child: dialog);
      },
    );
  }
}

void showError(dynamic e, BuildContext context, {ThemeData? theme}) {
  showMessage(e, context, isError: true, theme: theme);
}

String list2FriendlyString(List<String> list) {
  var isUsingEnglish = isEnglish();
  return list.length == 2
      ? '${list[0]} ${tr('and')} ${list[1]}'
      : list
            .asMap()
            .entries
            .map(
              (e) =>
                  e.value +
                  (e.key == list.length - 1
                      ? ''
                      : e.key == list.length - 2
                      ? '${isUsingEnglish ? ',' : ''} and '
                      : ', '),
            )
            .join('');
}
