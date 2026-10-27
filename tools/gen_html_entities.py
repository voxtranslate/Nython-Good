# generate lib/html/entities.ny from python3's html.entities
import html.entities as E, sys

def lit(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif 32 <= o < 127:
            out.append(ch)
        elif o < 0x10000:
            out.append('\\u%04x' % o)
        else:
            out.append('\\U%08x' % o)
    return '"' + ''.join(out) + '"'

w = sys.stdout.write
w('''# nython: module    (import it by name: it runs in a module scope of its own)
# lib/html/entities.ny - Python's html.entities (3.11): the HTML character
# entity references.
#
#   name2codepoint  HTML 4's 252 entity names -> code points ("amp" -> 38)
#   codepoint2name  the reverse
#   entitydefs      name -> the character, for name2codepoint's names
#   html5           HTML5's 2231 named character references, with their ';'
#                   ("amp;" -> "&") and the legacy ones that may omit it
#                   ("amp" -> "&"), as https://html.spec.whatwg.org/
#                   multipage/named-characters.html lists them
#
# The tables are generated from CPython 3.11's Lib/html/entities.py
# (python3 tools/gen_html_entities.py > lib/html/entities.ny), so they are
# exactly Python's.

__all__ = ["html5", "name2codepoint", "codepoint2name", "entitydefs"]

''')
w('name2codepoint = {\n')
for k, v in E.name2codepoint.items():
    w('    %s: 0x%04x,\n' % (lit(k), v))
w('}\n\n')
w('html5 = {\n')
items = list(E.html5.items())
for i in range(0, len(items), 4):
    chunk = items[i:i + 4]
    w('    ' + ' '.join('%s: %s,' % (lit(k), lit(v)) for k, v in chunk) + '\n')
w('}\n\n')
w('''# maps the Unicode code point to the HTML entity name
codepoint2name = {}

# maps the HTML entity name to the character
# (or a character reference if the character is outside the Latin-1 range)
entitydefs = {}

for name, codepoint in name2codepoint.items():
    codepoint2name[codepoint] = name
    entitydefs[name] = chr(codepoint)

del name, codepoint
''')
