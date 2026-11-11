#!/usr/bin/env python3
"""Apply TrapTube-specific branding changes to the pinned YTLite v6.0 source.

This removes the first-launch Advanced Mode reminder and all outbound donation,
contributor-profile, and repository links from the tweak's in-app settings.
Third-party acknowledgements are retained separately in the app bundle.
"""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()
settings = root / "Settings.x"
tweak = root / "YTLite.x"
if not settings.is_file() or not tweak.is_file():
    raise SystemExit("Expected Settings.x and YTLite.x in the YTLite source root.")

s = settings.read_text()
# Remove the now-unused helper that creates outbound link rows.
link_helper = re.compile(
    r'%new\s+'
    r'- \(YTSettingsSectionItem \*\)linkWithTitle:.*?\n}\n',
    re.DOTALL,
)
s, helper_count = link_helper.subn('', s, count=1)
if helper_count != 1:
    raise SystemExit("Could not remove the outbound-link row helper.")

support_start = s.find('    YTSettingsSectionItem *support =')
version_start = s.find('    YTSettingsSectionItem *version =', support_start)
if support_start < 0 or version_start < 0:
    raise SystemExit("Could not locate the support/contributors/source-links settings block.")
s = s[:support_start] + s[version_start:]

for row in (
    '    [sectionItems addObject:thanks];\n',
    '    [sectionItems addObject:sources];\n',
    '    [sectionItems addObject:support];\n',
):
    s = s.replace(row, '')

s = s.replace('initWithNavTitle:LOC(@"About") pickerSectionTitle:nil',
              'initWithNavTitle:@"TrapTube" pickerSectionTitle:nil')
s = s.replace('title:@"YTLite" icon:nil',
              'title:@"TrapTube Extensions" icon:nil')
s = s.replace('title:@"YTLite" titleDescription:nil',
              'title:@"TrapTube Extensions" titleDescription:nil')

# These are runtime UI links, not source-code comments or license notices.
for forbidden in ("https://", "http://", "openURL:", "linkWithTitle:"):
    if forbidden in s:
        raise SystemExit(f"Unexpected external-link implementation remains in Settings.x: {forbidden}")
if 'YTSettingsSectionItem *support =' in s or 'YTSettingsSectionItem *thanks =' in s or 'YTSettingsSectionItem *sources =' in s:
    raise SystemExit("A removed external-link settings row is still present.")
settings.write_text(s)

t = tweak.read_text()
pattern = re.compile(
    r'    if \(!ytlBool\(@"advancedMode"\) && !ytlBool\(@"advancedModeReminder"\)\) \{.*?\n    \}',
    re.DOTALL,
)
replacement = (
    '    // TrapTube: enable the advanced settings path silently.\n'
    '    // Do not show YTLite/YouTube Plus first-launch reminder UI.\n'
    '    ytlSetBool(YES, @"advancedMode");\n'
    '    ytlSetBool(YES, @"advancedModeReminder");'
)
t2, count = pattern.subn(replacement, t, count=1)
if count != 1:
    raise SystemExit("Could not locate the first-launch Advanced Mode reminder in YTLite.x.")
if 'AdvancedModeReminder' in t2[t2.find('%ctor'):]:
    raise SystemExit("First-launch reminder reference remains in the constructor.")
tweak.write_text(t2)

# Record the exact source revision and patch scope for build verification.
(root / "TRAPTUBE-YTLITE-PATCH-REPORT.txt").write_text(
    "TrapTube YTLite v6.0 source patch\n"
    "- First-launch Advanced Mode reminder disabled; advanced settings enabled silently.\n"
    "- YTLite settings section renamed to TrapTube Extensions.\n"
    "- Donation/support, contributor-profile, and external repository rows removed.\n"
    "- Third-party notices remain separately bundled with the app.\n"
)
print("Patched YTLite source: first-launch reminder disabled; external settings links removed.")
