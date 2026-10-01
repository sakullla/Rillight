#import <CoreGraphics/CoreGraphics.h>
#import <stdio.h>
#import <string.h>

// Prints on-screen and off-screen windows for one pid, or every Rillight
// owner when no pid is given. System Events does not enumerate Flutter windows.
int main(int argc, char** argv) {
  const int filter = argc > 1 ? atoi(argv[1]) : 0;
  CFArrayRef list =
      CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  if (!list) return 1;
  const CFIndex count = CFArrayGetCount(list);
  for (CFIndex i = 0; i < count; i++) {
    CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
    int pid = 0;
    CFNumberRef pid_value = CFDictionaryGetValue(info, kCGWindowOwnerPID);
    if (pid_value) CFNumberGetValue(pid_value, kCFNumberIntType, &pid);
    char owner[256] = {0};
    CFStringRef owner_value = CFDictionaryGetValue(info, kCGWindowOwnerName);
    if (owner_value)
      CFStringGetCString(owner_value, owner, sizeof owner,
                         kCFStringEncodingUTF8);
    const int match = filter ? pid == filter
                             : strcasestr(owner, "rillight") ||
                                   strstr(owner, "灯川");
    if (!match) continue;
    CGRect rect = CGRectZero;
    CFDictionaryRef bounds = CFDictionaryGetValue(info, kCGWindowBounds);
    if (!bounds || !CGRectMakeWithDictionaryRepresentation(bounds, &rect))
      continue;
    if (rect.size.width < 32 || rect.size.height < 32) continue;
    char title[256] = {0};
    CFStringRef title_value = CFDictionaryGetValue(info, kCGWindowName);
    if (title_value)
      CFStringGetCString(title_value, title, sizeof title,
                         kCFStringEncodingUTF8);
    const char* label = title[0] ? title : owner;
    printf("%d|%s|%.0f,%.0f,%.0f,%.0f\n", pid, label, rect.origin.x,
           rect.origin.y, rect.size.width, rect.size.height);
  }
  CFRelease(list);
  return 0;
}
