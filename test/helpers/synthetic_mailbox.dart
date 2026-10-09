import 'dart:convert';
import 'dart:io';

/// Consume only a complete, closed message. On Windows a reader can observe
/// the bytes before the writer closes its handle, while deletion is still
/// denied. Leave the message for the next bounded poll in that case.
Future<Map<String, dynamic>?> consumeSyntheticMessage(File file) async {
  try {
    final message =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    await file.delete();
    return message;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}
