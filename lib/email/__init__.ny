# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/email/__init__.ny - Python's email package (CPython 3.12's Lib/email,
# ported file by file with its structure kept, so parsing and generating give
# CPython's bytes and strings). message_from_string / message_from_bytes /
# message_from_file / message_from_binary_file here; the parts are
# email.message (Message, EmailMessage, MIMEPart), email.parser and
# email.feedparser (Parser, BytesParser, HeaderParser, FeedParser,
# BytesFeedParser), email.generator (Generator, BytesGenerator,
# DecodedGenerator), email.policy (compat32, default, SMTP, SMTPUTF8, HTTP,
# strict, EmailPolicy), email.headerregistry, email.header, email.utils,
# email.mime.*, email.charset, email.encoders, email.contentmanager,
# email.iterators, email.errors, email.base64mime, email.quoprimime,
# email._header_value_parser (RFC 5322 parsing), email._encoded_words,
# email._parseaddr, email._policybase.

# Copyright (C) 2001-2007 Python Software Foundation
# Author: Barry Warsaw
# Contact: email-sig@python.org

"""A package for parsing, handling, and generating email messages."""

__all__ = [
    'base64mime',
    'charset',
    'encoders',
    'errors',
    'feedparser',
    'generator',
    'header',
    'iterators',
    'message',
    'message_from_file',
    'message_from_binary_file',
    'message_from_string',
    'message_from_bytes',
    'mime',
    'parser',
    'quoprimime',
    'utils',
    ]


# Some convenience routines.  Don't import Parser and Message as side-effects
# of importing email since those cascadingly import most of the rest of the
# email package.
def message_from_string(s, *args, **kws):
    """Parse a string into a Message object model.

    Optional _class and strict are passed to the Parser constructor.
    """
    from email.parser import Parser
    return Parser(*args, **kws).parsestr(s)

def message_from_bytes(s, *args, **kws):
    """Parse a bytes string into a Message object model.

    Optional _class and strict are passed to the Parser constructor.
    """
    from email.parser import BytesParser
    return BytesParser(*args, **kws).parsebytes(s)

def message_from_file(fp, *args, **kws):
    """Read a file and parse its contents into a Message object model.

    Optional _class and strict are passed to the Parser constructor.
    """
    from email.parser import Parser
    return Parser(*args, **kws).parse(fp)

def message_from_binary_file(fp, *args, **kws):
    """Read a binary file and parse its contents into a Message object model.

    Optional _class and strict are passed to the Parser constructor.
    """
    from email.parser import BytesParser
    return BytesParser(*args, **kws).parse(fp)
