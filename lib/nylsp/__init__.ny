# nython: module    (a package: nylsp.protocol, nylsp.workspace, nylsp.server)
# nython: python    (Python's binding rule: a name a function binds is its local - round 86)
# lib/nylsp - a Language Server for Nython (Language Server Protocol 3.17),
# round 86. Every editor that speaks LSP (VS Code, Neovim, Emacs, Helix,
# Sublime, Kate ...) gets the analyses Nython's own IDE has:
#
#     nython -m nylsp                  # on standard input / output
#     nython -m nylsp --tcp 2087       # on one TCP connection (127.0.0.1)
#     nython -m nylsp --log /tmp/l     # with a log of failed requests
#
# The protocol (lib/nylsp/protocol.ny): JSON-RPC 2.0 with LSP's header part
# (Content-Length), requests, notifications, responses and errors with
# JSON-RPC's and LSP's codes; `initialize` / `initialized` / `shutdown` /
# `exit` (exit status 0 after shutdown, 1 otherwise; requests before
# initialize get ServerNotInitialized, after shutdown InvalidRequest);
# `$/cancelRequest` (a queued request is answered RequestCancelled at once,
# the running one at its next check - workspace-wide work checks, reading
# what has arrived without blocking); position encodings utf-16 (the
# default), utf-8 and utf-32, as the client offers them.
#
# What it answers (each from the real parser - the engines' own - over the
# document's current text; positions in the negotiated encoding):
#   textDocument/didOpen, didChange (incremental: each change's range is
#       applied to a per-document piece table - two buffers and a list of
#       pieces that know their line breaks - so an edit costs the pieces, not
#       the file; full-text changes too), didSave, didClose
#   textDocument/publishDiagnostics: syntax errors (several: see "error
#       recovery" below), NyScope's static checks (assigning a const,
#       `nonlocal` without a binding; for Nython-language files the places
#       where Nython's binding rule and Python's disagree, as information
#       with quick fixes), reads that run before the binding
#       (UnboundLocalError), undefined names, modules that cannot be found,
#       names a module does not define, and NyxAI's review rules
#       (lib/nyxai/review.ny: unused-import, unused-variable,
#       unreachable-code, shadowed-builtin, mutable-default, bare-except,
#       none-comparison, too-complex, missing-self, inconsistent-return) as
#       warnings with those codes. When a module's exports change, the open
#       documents that import it are checked again (the dependency graph).
#   textDocument/completion (+ completionItem/resolve): scope-aware - the
#       names visible at the position by the binding rules (locals,
#       parameters, enclosing functions, the module, what star and quoted
#       imports bring), keywords (Nython's soft ones in .ny files),
#       builtins; after a dot the members of what is before it: a class or
#       an instance of one (methods, class attributes, fields assigned
#       through self, base classes - of this file or another module's), a
#       module (its exports, a package's submodules; the runtime's own
#       modules by dir()), a builtin type; module names after import/from;
#       nothing inside strings and comments; resolve adds the signature and
#       the docstring
#   textDocument/hover: the signature, the docstring, and the kind - with
#       the type inferred from the binding (`x = C()` is a C, `n: int`,
#       a parameter's annotation, a literal, a call of a function whose
#       return annotation names a class)
#   textDocument/signatureHelp: the call around the position, found in the
#       text (so it works while the call is being typed), its active
#       parameter by position or by keyword
#   textDocument/definition, declaration, typeDefinition: across the
#       workspace's files, following imports through the engines' own
#       module search (.ny before .py, packages, relative imports, quoted
#       imports) and re-exports
#   textDocument/references, documentHighlight: by the binding analysis
#   textDocument/rename (+ prepareRename): a WorkspaceEdit that follows the
#       scopes - a local `x` of one function is not another's nor the
#       module's; in a .ny file a plain assignment in a function rebinds the
#       module's name (Nython's rule) and is renamed with it, in a .py file
#       (or `# nython: python`) it is the function's local (Python's) - across
#       modules: `from m import f`, `import m; m.f`, a class's members used
#       through instances and subclasses of other modules; keyword arguments
#       naming a parameter; an alias (`import f as g`) keeps its own name.
#       Builtins, modules and names defined outside the workspace are refused.
#   textDocument/documentSymbol (hierarchical) and workspace/symbol (the
#       native fuzzy_rank over every indexed module's definitions)
#   textDocument/foldingRange: blocks, brackets and #region markers
#       (text_fold_ranges), comment blocks and import groups
#   textDocument/formatting, rangeFormatting: text_format_nython, the
#       conservative formatter, as line edits (text_diff's Myers hunks)
#   textDocument/semanticTokens/full (+ /delta): the lexer's tokens
#       classified by the binding analysis (parameter, variable, function,
#       method, class, namespace, property, enum, enumMember, decorator,
#       keyword, string, number, comment) with modifiers (declaration,
#       definition, readonly for const, static, async, modification,
#       defaultLibrary for builtins); a delta is the one edit between the
#       previous result and this one
#   textDocument/codeAction: NyxAI's mechanical fixes as quick fixes, all
#       of them as source.fixAll.nyxai, and `global x` / `var x` for the
#       binding-rule notes
#   textDocument/inlayHint: parameter names at call sites
#   $/progress: work done progress while the workspace is indexed (after
#       window/workDoneProgress/create, when the client supports it); the
#       index is built between requests, a few files at a time
#   nython/stats, nython/analysis, nython/documentText: the server's timings, a
#       document's analysis and its text (Nython's own requests)
#
# Error recovery (the innovation; cf. Moonen's island grammars, 2001, and
# tree-sitter's error recovery, which keeps the well-formed subtrees around
# an error): when the source does not parse, the statement around the error
# is cut out by the indentation structure - from its first line (bracket
# depth 0, outside strings) to where its brackets close, or to the next
# line indented no deeper when they never do - and replaced, keeping the
# line count, by `pass`, or by `if 1:` when an indented block follows, so
# that block stays an island the analysis still sees (its names, its
# scopes); "expected an indented block" cuts the header without a body,
# "unexpected indent" the over-indented lines, and a cut that did not help
# grows to its enclosing block. The parse is tried again, ten times at
# most; each cut is a diagnostic. So completion, hover, symbols and
# semantic tokens keep working on a line that is being typed.
#
# Incremental analysis: an edit is applied to the piece table only; the
# document is parsed again when something asks (a request, or the
# diagnostics published while no message waits); the workspace index keeps
# per module its exports and imports, re-reads a file whose mtime changed,
# and re-checks the importers of a module whose exports changed. Parsing
# and analysis are native (src/builtins/nylsp.cpp): nython_ide.ny's chain
# (2,800-3,100 lines a file) parses and analyses in tens of milliseconds,
# and completion / hover after that are a few milliseconds (vm_audit122
# measures them).
#
# Not here: the types of what a call of another module's function returns,
# of containers' items, of what flows through calls (the inference is the
# binding's value and annotations only); call hierarchy, type hierarchy,
# code lens, document links, linked editing, selection ranges, on-type
# formatting, pull diagnostics (textDocument/diagnostic), notebook
# documents, file operations (willRenameFiles); renaming modules (files);
# the `range` form of semantic tokens. Names inside f-strings are found and
# renamed but not colored. NyxAI's review runs on files up to
# maxReviewLines (4000; initializationOptions or workspace/didChangeConfiguration
# with {"nylsp": {...}} set review, undefinedNames, inlayHints, maxReviewLines).

from nylsp.protocol import StdioTransport, SocketTransport, ProtocolError, encode_message
from nylsp.workspace import Workspace, uri_to_path, path_to_uri
from nylsp.server import Server, main, LspError, SEMANTIC_TOKEN_TYPES, SEMANTIC_TOKEN_MODIFIERS, VERSION

__all__ = ["Server", "main", "Workspace", "StdioTransport", "SocketTransport", "ProtocolError", "LspError",
           "uri_to_path", "path_to_uri", "encode_message", "SEMANTIC_TOKEN_TYPES", "SEMANTIC_TOKEN_MODIFIERS",
           "VERSION"]
