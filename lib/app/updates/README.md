# Release checks

Desktop settings, phone About and TV settings expose an explicit Check for
updates action. It queries the official repository's GitHub latest-release API
using a separate client, with no media-server authentication. There is no startup
request or automatic installation.

Only non-draft stable releases are accepted. Semantic versions are compared
numerically; equal/older releases do not offer a download. Errors remain errors,
with a retry action. New releases show notes and open the official release page
in the system browser; if opening fails the URL can be copied.

`test/app/update_check_test.dart` exercises version ordering, response validation,
the API request, failure/retry, progress and the download action. Real release
availability and system browser behavior still depend on the target device.
