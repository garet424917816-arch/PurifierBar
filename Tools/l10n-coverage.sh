#!/bin/bash
# Approximate report of English UI literals missing from Ukrainian tables.
# Interpolation up to the first ')' becomes '%'; Swift tests check argument types.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json
import pathlib
import re

literal = r'"(?:\\.|[^"\\])*"'
entry = re.compile(r'(' + literal + r')\s*=\s*' + literal + r'\s*;')
format_specifier = re.compile(r'%%|%(?:[0-9]+\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:hh|ll|h|l|j|z|t|L)?[@diuoxXfFeEgGaAcCsSp]')


def normalize(text):
    text = re.sub(r'\\\([^)]*\)', '%', text)
    return format_specifier.sub('%', text)


tables = {}
for path in pathlib.Path('Resources/Localization/uk.lproj').glob('*.strings'):
    tables[path.stem] = {normalize(json.loads(m[1])) for m in entry.finditer(path.read_text())}

# Known SwiftUI constructors and project helpers taking LocalizedStringKey.
ui_call = re.compile(
    r'\b(?:Text|Label|Button|TextField|SecureField|Link|LocalizedStringKey|'
    r'sectionCard|hintText|field|statusLine|help|accessibilityLabel|accessibilityHint)\s*\(\s*'
    r'|\bString\s*\(\s*localized:\s*'
    r'|\b(?:StepperRow|ToggleRow)\s*\(\s*title:\s*'
)
token = re.compile(literal + r'|//[^\n]*|/\*[\s\S]*?\*/')
for source in sorted(pathlib.Path('Sources').rglob('*.swift')):
    if 'purifier-cli' in source.parts:
        continue
    text = source.read_text()
    # Keep strings intact and preserve line numbers while removing comments.
    text = token.sub(lambda m: m[0] if m[0].startswith('"') else re.sub(r'[^\n]', ' ', m[0]), text)
    for call in ui_call.finditer(text):
        match = re.match(literal, text[call.end():])
        if not match:
            continue
        raw = match[0]
        # Decode .strings-compatible escapes after replacing Swift interpolation.
        key = json.loads(re.sub(r'\\\([^)]*\)', lambda _: r'\u0001', raw))
        key = normalize(key).replace('\x01', '%')
        # Skip dynamic numbers and punctuation in views, but keep explicitly localized formats.
        if not re.search(r'[A-Za-z]', key) and not call[0].startswith('String'):
            continue
        table = 'Localizable'
        suffix = text[call.end() + match.end():]
        named_table = re.match(r'\s*,\s*table:\s*(' + literal + ')', suffix)
        if named_table:
            table = json.loads(named_table[1])
        if key not in tables.get(table, set()):
            line = text.count('\n', 0, call.end()) + 1
            print(f'{source}:{line}: {raw} (table: {table})')
PY
