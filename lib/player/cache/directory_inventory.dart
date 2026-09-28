import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

typedef CacheFileStat = ({int size, DateTime modified});

/// A fresh inventory for one quota-lock transaction. Windows directory entries
/// already contain size and mtime; querying each file again costs thousands of
/// synchronous filesystem calls as a session approaches its disk quota.
({List<FileSystemEntity> entries, Map<String, CacheFileStat> stats})
readCacheDirectory(Directory directory, {required int maxEntries}) {
  if (Platform.isWindows) {
    try {
      return _readWindowsDirectory(directory, maxEntries: maxEntries);
    } on FileSystemException {
      // Never use a partial native inventory for quota accounting. Retry via
      // Dart's complete enumeration if Windows enumeration cannot finish.
    }
  }
  return _readPortableDirectory(directory, maxEntries: maxEntries);
}

({List<FileSystemEntity> entries, Map<String, CacheFileStat> stats})
_readPortableDirectory(Directory directory, {required int maxEntries}) {
  final entries = <FileSystemEntity>[];
  final stats = <String, CacheFileStat>{};
  for (final entry in directory.listSync(followLinks: false)) {
    if (entries.length >= maxEntries) {
      throw const FileSystemException('Cache file count limit');
    }
    entries.add(entry);
    if (entry is File) {
      final stat = entry.statSync();
      stats[entry.path] = (size: stat.size, modified: stat.modified);
    }
  }
  return (entries: entries, stats: stats);
}

({List<FileSystemEntity> entries, Map<String, CacheFileStat> stats})
_readWindowsDirectory(Directory directory, {required int maxEntries}) {
  final entries = <FileSystemEntity>[];
  final stats = <String, CacheFileStat>{};
  final path = directory.absolute.path.replaceAll('/', r'\');
  final prefix = path.endsWith(r'\') ? path : '$path\\';
  final entryPrefix = directory.path.endsWith(Platform.pathSeparator)
      ? directory.path
      : '${directory.path}${Platform.pathSeparator}';
  return using((arena) {
    final pattern = '$prefix*'.toNativeUtf16(allocator: arena);
    final data = arena<WIN32_FIND_DATA>();
    final first = FindFirstFile(PCWSTR(pattern), data);
    if (first.value == INVALID_HANDLE_VALUE) {
      if (first.error == ERROR_FILE_NOT_FOUND && directory.existsSync()) {
        return (entries: entries, stats: stats);
      }
      throw FileSystemException('Cache directory enumeration failed', path);
    }
    try {
      while (true) {
        final item = data.ref;
        final name = item.cFileName;
        if (name != '.' && name != '..') {
          if (entries.length >= maxEntries) {
            throw const FileSystemException('Cache file count limit');
          }
          final entryPath = '$entryPrefix$name';
          if (item.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0) {
            entries.add(Link(entryPath));
          } else if (item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) {
            entries.add(Directory(entryPath));
          } else {
            entries.add(File(entryPath));
            stats[entryPath] = (
              size: (item.nFileSizeHigh << 32) | item.nFileSizeLow,
              modified: item.ftLastWriteTime.toDateTime(),
            );
          }
        }
        final next = FindNextFile(first.value, data);
        if (!next.value) {
          if (next.error != ERROR_NO_MORE_FILES) {
            throw FileSystemException('Incomplete cache directory', path);
          }
          break;
        }
      }
      return (entries: entries, stats: stats);
    } finally {
      FindClose(first.value);
    }
  });
}
