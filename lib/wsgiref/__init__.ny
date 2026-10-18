# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/wsgiref/__init__.ny - Python's wsgiref package (CPython 3.12's
# Lib/wsgiref): the WSGI (PEP 3333) reference library - util, headers,
# handlers, simple_server, validate, types.

"""wsgiref -- a WSGI (PEP 3333) Reference Library

Current Contents:

* util -- Miscellaneous useful functions and wrappers

* headers -- Manage response headers

* handlers -- base classes for server/gateway implementations

* simple_server -- a simple BaseHTTPServer that supports WSGI

* validate -- validation wrapper that sits between an app and a server
  to detect errors in either

* types -- collection of WSGI-related types for static type checking

To-Do:

* cgi_gateway -- Run WSGI apps under CGI (pending a deployment standard)

* cgi_wrapper -- Run CGI apps under WSGI

* router -- a simple middleware component that handles URL traversal
"""
