# nython: module    (import it by name: it runs in a module scope of its own)
# lib/cgitb.ny - Python's cgitb (CPython 3.12's Lib/cgitb.py,
# deprecated for removal in 3.13 - importing it warns): the traceback
# formatter for CGI scripts - html() and text() reports with the source
# around each frame and its variables, Hook, enable, handler, reset.
#
# The report's per-line variable dump needs lib/tokenize.ny (without it the
# frames are listed without their variables); pydoc's reprs are used when
# lib/pydoc.ny has them, CPython's HTMLRepr/TextRepr carried here otherwise.

"""More comprehensive traceback formatting for Python scripts.

To enable this module, do:

    import cgitb; cgitb.enable()

at the top of your script.  The optional arguments to enable() are:

    display     - if true, tracebacks are displayed in the web browser
    logdir      - if set, tracebacks are written to files in this directory
    context     - number of lines of source code to show for each stack frame
    format      - 'text' or 'html' controls the output format

By default, tracebacks are displayed but not saved, the context is 5 lines
and the output format is 'html' (for backwards compatibility with the
original use of this module)

Alternatively, if you have caught an exception and want cgitb to display it
for you, call cgitb.handler().  The optional argument to handler() is a
3-item tuple (etype, evalue, etb) just like the value of sys.exc_info().
The default handler displays output as HTML.

"""
import inspect
import keyword
import linecache
import os
import sys
import tempfile
import time
import traceback
import warnings
from html import escape as html_escape
try:
    import tokenize
except ImportError:                 # (Nython: tokenize may be absent - no variable dump then)
    tokenize = None


# pydoc's html.repr/escape/preformat and text.repr (CPython's HTMLRepr and
# TextRepr), used when lib/pydoc.ny lacks them.
def _pydoc_fallback():
    import re
    from reprlib import Repr

    def replace(text, *pairs):
        while pairs:
            text = pairs[1].join(text.split(pairs[0]))
            pairs = pairs[2:]
        return text

    def cram(text, maxlen):
        if len(text) > maxlen:
            pre = max(0, (maxlen-3)//2)
            post = max(0, maxlen-3-pre)
            return text[:pre] + '...' + text[len(text)-post:]
        return text

    _re_stripid = re.compile(r' at 0x[0-9a-f]{6,16}(>+)$', re.IGNORECASE)
    def stripid(text):
        return _re_stripid.sub(r'\1', text)

    class TextRepr(Repr):
        def __init__(self):
            Repr.__init__(self)
            self.maxlist = self.maxtuple = 20
            self.maxdict = 10
            self.maxstring = self.maxother = 100

        def repr1(self, x, level):
            if hasattr(type(x), '__name__'):
                methodname = 'repr_' + '_'.join(type(x).__name__.split())
                if hasattr(self, methodname):
                    return getattr(self, methodname)(x, level)
            return cram(stripid(repr(x)), self.maxother)

        def repr_string(self, x, level):
            test = cram(x, self.maxstring)
            testrepr = repr(test)
            if '\\' in test and '\\' not in replace(testrepr, r'\\', ''):
                return 'r' + testrepr[0] + test + testrepr[0]
            return testrepr

        repr_str = repr_string

        def repr_instance(self, x, level):
            try:
                return cram(stripid(repr(x)), self.maxstring)
            except:
                return '<%s instance>' % x.__class__.__name__

    class HTMLRepr(Repr):
        def __init__(self):
            Repr.__init__(self)
            self.maxlist = self.maxtuple = 20
            self.maxdict = 10
            self.maxstring = self.maxother = 100

        def escape(self, text):
            return replace(text, '&', '&amp;', '<', '&lt;', '>', '&gt;')

        def repr(self, object):
            return Repr.repr(self, object)

        def repr1(self, x, level):
            if hasattr(type(x), '__name__'):
                methodname = 'repr_' + '_'.join(type(x).__name__.split())
                if hasattr(self, methodname):
                    return getattr(self, methodname)(x, level)
            return self.escape(cram(stripid(repr(x)), self.maxother))

        def repr_string(self, x, level):
            test = cram(x, self.maxstring)
            testrepr = repr(test)
            if '\\' in test and '\\' not in replace(testrepr, r'\\', ''):
                return 'r' + testrepr[0] + self.escape(test) + testrepr[0]
            return re.sub(r'((\\[\\abfnrtv\'"]|\\[0-9]..|\\x..|\\u....)+)',
                          r'<span class="repr">\1</span>',
                          self.escape(testrepr))

        repr_str = repr_string

        def repr_instance(self, x, level):
            try:
                return self.escape(cram(stripid(repr(x)), self.maxstring))
            except:
                return self.escape('<%s instance>' % x.__class__.__name__)

    class _Html:
        def __init__(self):
            r = HTMLRepr()
            self.repr = r.repr
            self.escape = r.escape

        def preformat(self, text):
            text = self.escape(text.expandtabs())
            return replace(text, '\n\n', '\n \n', '\n\n', '\n \n',
                                 ' ', '&nbsp;', '\n', '<br>\n')

    class _Text:
        def __init__(self):
            self.repr = TextRepr().repr

    class _Pydoc:
        pass
    m = _Pydoc()
    m.html = _Html()
    m.text = _Text()
    return m

try:
    import pydoc
    pydoc.html.repr, pydoc.html.escape, pydoc.html.preformat, pydoc.text.repr
except (ImportError, AttributeError):
    pydoc = _pydoc_fallback()

warnings._deprecated(__name__, remove=(3, 13))


def reset():
    """Return a string that resets the CGI and browser to a known state."""
    return '''<!--: spam
Content-Type: text/html

<body bgcolor="#f0f0f8"><font color="#f0f0f8" size="-5"> -->
<body bgcolor="#f0f0f8"><font color="#f0f0f8" size="-5"> --> -->
</font> </font> </font> </script> </object> </blockquote> </pre>
</table> </table> </table> </table> </table> </font> </font> </font>'''

__UNDEF__ = []                          # a special sentinel object
def small(text):
    if text:
        return '<small>' + text + '</small>'
    else:
        return ''

def strong(text):
    if text:
        return '<strong>' + text + '</strong>'
    else:
        return ''

def grey(text):
    if text:
        return '<font color="#909090">' + text + '</font>'
    else:
        return ''

def lookup(name, frame, locals):
    """Find the value for a given name in the given environment."""
    if name in locals:
        return 'local', locals[name]
    if name in frame.f_globals:
        return 'global', frame.f_globals[name]
    if '__builtins__' in frame.f_globals:
        builtins = frame.f_globals['__builtins__']
        if isinstance(builtins, dict):
            if name in builtins:
                return 'builtin', builtins[name]
        else:
            if hasattr(builtins, name):
                return 'builtin', getattr(builtins, name)
    return None, __UNDEF__

def scanvars(reader, frame, locals):
    """Scan one logical line of Python and look up values of variables used."""
    vars, lasttoken, parent, prefix, value = [], None, None, '', __UNDEF__
    if tokenize is None:
        return vars
    for ttype, token, start, end, line in tokenize.generate_tokens(reader):
        if ttype == tokenize.NEWLINE: break
        if ttype == tokenize.NAME and token not in keyword.kwlist:
            if lasttoken == '.':
                if parent is not __UNDEF__:
                    value = getattr(parent, token, __UNDEF__)
                    vars.append((prefix + token, prefix, value))
            else:
                where, value = lookup(token, frame, locals)
                vars.append((token, where, value))
        elif token == '.':
            prefix += lasttoken + '.'
            parent = value
        else:
            parent, prefix = None, ''
        lasttoken = token
    return vars

def html(einfo, context=5):
    """Return a nice HTML document describing a given traceback."""
    etype, evalue, etb = einfo
    if isinstance(etype, type):
        etype = etype.__name__
    pyver = 'Python ' + sys.version.split()[0] + ': ' + sys.executable
    date = time.ctime(time.time())
    head = f'''
<body bgcolor="#f0f0f8">
<table width="100%" cellspacing=0 cellpadding=2 border=0 summary="heading">
<tr bgcolor="#6622aa">
<td valign=bottom>&nbsp;<br>
<font color="#ffffff" face="helvetica, arial">&nbsp;<br>
<big><big><strong>{html_escape(str(etype))}</strong></big></big></font></td>
<td align=right valign=bottom>
<font color="#ffffff" face="helvetica, arial">{pyver}<br>{date}</font></td>
</tr></table>
<p>A problem occurred in a Python script.  Here is the sequence of
function calls leading up to the error, in the order they occurred.</p>'''

    indent = '<tt>' + small('&nbsp;' * 5) + '&nbsp;</tt>'
    frames = []
    records = inspect.getinnerframes(etb, context)
    for frame, file, lnum, func, lines, index in records:
        if file:
            file = os.path.abspath(file)
            link = '<a href="file://%s">%s</a>' % (file, pydoc.html.escape(file))
        else:
            file = link = '?'
        args, varargs, varkw, locals = inspect.getargvalues(frame)
        call = ''
        if func != '?':
            call = 'in ' + strong(pydoc.html.escape(func))
            if func != "<module>":
                call += inspect.formatargvalues(args, varargs, varkw, locals,
                    formatvalue=lambda value: '=' + pydoc.html.repr(value))

        highlight = {}
        def reader(lnum=[lnum]):
            highlight[lnum[0]] = 1
            try: return linecache.getline(file, lnum[0])
            finally: lnum[0] += 1
        vars = scanvars(reader, frame, locals)

        rows = ['<tr><td bgcolor="#d8bbff">%s%s %s</td></tr>' %
                ('<big>&nbsp;</big>', link, call)]
        if index is not None:
            i = lnum - index
            for line in lines:
                num = small('&nbsp;' * (5-len(str(i))) + str(i)) + '&nbsp;'
                if i in highlight:
                    line = '<tt>=&gt;%s%s</tt>' % (num, pydoc.html.preformat(line))
                    rows.append('<tr><td bgcolor="#ffccee">%s</td></tr>' % line)
                else:
                    line = '<tt>&nbsp;&nbsp;%s%s</tt>' % (num, pydoc.html.preformat(line))
                    rows.append('<tr><td>%s</td></tr>' % grey(line))
                i += 1

        done, dump = {}, []
        for name, where, value in vars:
            if name in done: continue
            done[name] = 1
            if value is not __UNDEF__:
                if where in ('global', 'builtin'):
                    name = ('<em>%s</em> ' % where) + strong(name)
                elif where == 'local':
                    name = strong(name)
                else:
                    name = where + strong(name.split('.')[-1])
                dump.append('%s&nbsp;= %s' % (name, pydoc.html.repr(value)))
            else:
                dump.append(name + ' <em>undefined</em>')

        rows.append('<tr><td>%s</td></tr>' % small(grey(', '.join(dump))))
        frames.append('''
<table width="100%%" cellspacing=0 cellpadding=0 border=0>
%s</table>''' % '\n'.join(rows))

    exception = ['<p>%s: %s' % (strong(pydoc.html.escape(str(etype))),
                                pydoc.html.escape(str(evalue)))]
    for name in dir(evalue):
        if name[:1] == '_': continue
        value = pydoc.html.repr(getattr(evalue, name, None))   # (Nython: not every name dir() lists reads)
        exception.append('\n<br>%s%s&nbsp;=\n%s' % (indent, name, value))

    return head + ''.join(frames) + ''.join(exception) + '''


<!-- The above is a description of an error in a Python program, formatted
     for a web browser because the 'cgitb' module was enabled.  In case you
     are not reading this in a web browser, here is the original traceback:

%s
-->
''' % pydoc.html.escape(
          ''.join(traceback.format_exception(etype, evalue, etb)))

def text(einfo, context=5):
    """Return a plain text document describing a given traceback."""
    etype, evalue, etb = einfo
    if isinstance(etype, type):
        etype = etype.__name__
    pyver = 'Python ' + sys.version.split()[0] + ': ' + sys.executable
    date = time.ctime(time.time())
    head = "%s\n%s\n%s\n" % (str(etype), pyver, date) + '''
A problem occurred in a Python script.  Here is the sequence of
function calls leading up to the error, in the order they occurred.
'''

    frames = []
    records = inspect.getinnerframes(etb, context)
    for frame, file, lnum, func, lines, index in records:
        file = file and os.path.abspath(file) or '?'
        args, varargs, varkw, locals = inspect.getargvalues(frame)
        call = ''
        if func != '?':
            call = 'in ' + func
            if func != "<module>":
                call += inspect.formatargvalues(args, varargs, varkw, locals,
                    formatvalue=lambda value: '=' + pydoc.text.repr(value))

        highlight = {}
        def reader(lnum=[lnum]):
            highlight[lnum[0]] = 1
            try: return linecache.getline(file, lnum[0])
            finally: lnum[0] += 1
        vars = scanvars(reader, frame, locals)

        rows = [' %s %s' % (file, call)]
        if index is not None:
            i = lnum - index
            for line in lines:
                num = '%5d ' % i
                rows.append(num+line.rstrip())
                i += 1

        done, dump = {}, []
        for name, where, value in vars:
            if name in done: continue
            done[name] = 1
            if value is not __UNDEF__:
                if where == 'global': name = 'global ' + name
                elif where != 'local': name = where + name.split('.')[-1]
                dump.append('%s = %s' % (name, pydoc.text.repr(value)))
            else:
                dump.append(name + ' undefined')

        rows.append('\n'.join(dump))
        frames.append('\n%s\n' % '\n'.join(rows))

    exception = ['%s: %s' % (str(etype), str(evalue))]
    for name in dir(evalue):
        value = pydoc.text.repr(getattr(evalue, name, None))   # (Nython: not every name dir() lists reads)
        exception.append('\n%s%s = %s' % (" "*4, name, value))

    return head + ''.join(frames) + ''.join(exception) + '''

The above is a description of an error in a Python program.  Here is
the original traceback:

%s
''' % ''.join(traceback.format_exception(etype, evalue, etb))

class Hook:
    """A hook to replace sys.excepthook that shows tracebacks in HTML."""

    def __init__(self, display=1, logdir=None, context=5, file=None,
                 format="html"):
        self.display = display          # send tracebacks to browser if true
        self.logdir = logdir            # log tracebacks to files if not None
        self.context = context          # number of source code lines per frame
        self.file = file or sys.stdout  # place to send the output
        self.format = format

    def __call__(self, etype, evalue, etb):
        self.handle((etype, evalue, etb))

    def handle(self, info=None):
        info = info or sys.exc_info()
        if self.format == "html":
            self.file.write(reset())

        formatter = (self.format=="html") and html or text
        plain = False
        try:
            doc = formatter(info, self.context)
        except:                         # just in case something goes wrong
            doc = ''.join(traceback.format_exception(*info))
            plain = True

        if self.display:
            if plain:
                doc = pydoc.html.escape(doc)
                self.file.write('<pre>' + doc + '</pre>\n')
            else:
                self.file.write(doc + '\n')
        else:
            self.file.write('<p>A problem occurred in a Python script.\n')

        if self.logdir is not None:
            suffix = ['.txt', '.html'][self.format=="html"]
            (fd, path) = tempfile.mkstemp(suffix=suffix, dir=self.logdir)

            try:
                with os.fdopen(fd, 'w') as file:
                    file.write(doc)
                msg = '%s contains the description of this error.' % path
            except:
                msg = 'Tried to save traceback to %s, but failed.' % path

            if self.format == 'html':
                self.file.write('<p>%s</p>\n' % msg)
            else:
                self.file.write(msg + '\n')
        try:
            self.file.flush()
        except: pass

handler = Hook().handle
def enable(display=1, logdir=None, context=5, format="html"):
    """Install an exception handler that formats tracebacks as HTML.

    The optional argument 'display' can be set to 0 to suppress sending the
    traceback to the browser, and 'logdir' can be set to a directory to cause
    tracebacks to be written to files there."""
    sys.excepthook = Hook(display=display, logdir=logdir,
                          context=context, format=format)
