# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 86)
# lib/nylsp/server.ny - the Language Server itself (round 86): the
# lifecycle, the message loop (cancellation, idle work), document sync and
# every request lib/nylsp/__init__.ny lists. The analyses are the native
# half's (_ny_lsp, src/builtins/nylsp.cpp); this file asks it small
# questions and puts the answers together across files.

import os
import sys
import socket
import select
from nylsp import protocol
from nylsp.protocol import StdioTransport, SocketTransport, ProtocolError
from nylsp.workspace import Workspace, uri_to_path, path_to_uri, BUILTIN_MODULES

__all__ = ["Server", "main", "LspError", "SEMANTIC_TOKEN_TYPES", "SEMANTIC_TOKEN_MODIFIERS", "VERSION"]

VERSION = "1.0"

# the legend: the native half numbers token types and modifiers in this order
SEMANTIC_TOKEN_TYPES = ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
                        "parameter", "variable", "property", "enumMember", "event", "function", "method",
                        "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator",
                        "decorator"]
SEMANTIC_TOKEN_MODIFIERS = ["declaration", "definition", "readonly", "static", "deprecated", "abstract",
                            "async", "modification", "documentation", "defaultLibrary"]

# LSP's CompletionItemKind / SymbolKind for the native half's symbol kinds
_COMPLETION_KIND = {"v": 6, "k": 21, "p": 6, "f": 3, "M": 2, "c": 7, "m": 9, "n": 6, "F": 5, "A": 5,
                    "e": 13, "E": 20, "I": 8, "N": 9, "u": 5}
_SYMBOL_KIND = {"v": 13, "k": 14, "p": 13, "f": 12, "M": 6, "c": 5, "m": 2, "n": 13, "F": 8, "A": 8,
                "e": 10, "E": 22, "I": 11, "N": 3, "u": 8}
_KIND_WORD = {"v": "variable", "k": "constant", "p": "parameter", "f": "function", "M": "method", "c": "class",
              "m": "module", "n": "import", "F": "field", "A": "attribute", "e": "enum", "E": "enum member",
              "I": "interface", "N": "namespace", "u": "attribute"}

# soft keywords of Nython that start a construct (keyword.nykwlist's), offered as completions
_NY_KEYWORDS = ["var", "let", "const", "enum", "struct", "interface", "namespace", "switch", "case", "default",
                "repeat", "unless", "until", "fn", "new", "throw", "catch"]


_DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]


class LspError(Exception):
    def __init__(self, code, message, data=None):
        Exception.__init__(self, message)
        self.code = code
        self.message = message
        self.data = data


class _Cancelled(Exception):
    pass


class Raw:
    """A result already encoded as JSON text (the native half's), sent as it is."""
    def __init__(self, text):
        self.text = text


# the time spent in each native operation (nython/stats)
NATIVE_MS = {}


def L(*args):
    t0 = time_ms()
    r = _ny_lsp(*args)
    _account(args[0], time_ms() - t0)
    return r


def J(*args):
    t0 = time_ms()
    r = _ny_lsp(*args)
    t1 = time_ms()
    v = json_decode(r)
    _account(args[0], t1 - t0, time_ms() - t1)
    return v


def _account(op, ms, decode_ms=0.0):
    a = NATIVE_MS.get(op)
    if a is None:
        a = [0, 0.0, 0.0]
        NATIVE_MS[op] = a
    a[0] += 1
    a[1] += ms
    a[2] += decode_ms


def _utf16_len(s):
    n = 0
    for ch in s:
        n += 2 if ord(ch) > 0xFFFF else 1
    return n


def _identifier(s):
    import keyword
    return isinstance(s, str) and s.isidentifier() and not keyword.iskeyword(s)


class _Ref:
    """A file target_of() can look at (as a Document: its path and handle)."""
    def __init__(self, path, h):
        self.path = path
        self.h = h


class Document:
    """An open text document: its native piece table and analysis."""
    def __init__(self, uri, path, text, version, language):
        self.uri = uri
        self.path = path
        self.version = version
        self.language = language
        self.h = int(L("open", text, path, ""))
        self.edits = 0
        self.analysis = None
        self.analysis_edits = -1
        self.published_edits = -1
        self.deps_dirty = False
        self.review = None
        self.review_edits = -1
        self.changed_at = 0.0
        self.python = None

    def analyze(self):
        if self.analysis_edits != self.edits:
            self.analysis = J("analyze", self.h)
            self.analysis_edits = self.edits
        return self.analysis

    def is_python(self):
        if self.python is None:
            self.python = self.analyze()["python"]
        return self.python

    def text(self):
        return L("text", self.h)

    def line(self, n):
        return L("line", self.h, n)

    def close(self):
        L("close", self.h)


class Server:
    def __init__(self, transport, log=None):
        self.t = transport
        self.log_file = log
        self.docs = {}              # uri -> Document
        self.ws = Workspace()
        self.queue = []
        self.cancelled = set()
        self.running = None         # the id of the request being handled
        self.initialized = False    # initialize answered
        self.ready = False          # initialized received
        self.shutdown_requested = False
        self.exit_code = None
        self.client_caps = {}
        self.options = {"review": True, "undefinedNames": True, "maxReviewLines": 4000, "inlayHints": True,
                        "diagnosticDelay": 150}
        self.wait_ms = None         # the idle work waits this long (a debounced publish)
        self.encoding = "utf-16"
        self.next_id = 1
        self.waiting = {}           # our request id -> callback(result, error)
        self.progress_token = None
        self.progress_total = 0
        self.indexing = False
        self.index_started = 0
        self.index_ms = 0
        self.builtins = {}          # name -> value (the runtime's builtins)
        self.stats = {"requests": 0, "notifications": 0, "cancelled": 0}
        self.timings = {}           # method -> [count, total ms, max ms]
        self.member_cache = {}      # (file, class symbol, on the class) -> (stamp, completion items)
        self.completion_key = None  # the last completion's question, and its answer (JSON)
        self.completion_result = None
        self._load_builtins()
        self.requests = {
            "initialize": self.on_initialize,
            "shutdown": self.on_shutdown,
            "textDocument/completion": self.on_completion,
            "completionItem/resolve": self.on_completion_resolve,
            "textDocument/hover": self.on_hover,
            "textDocument/signatureHelp": self.on_signature_help,
            "textDocument/definition": self.on_definition,
            "textDocument/declaration": self.on_declaration,
            "textDocument/typeDefinition": self.on_type_definition,
            "textDocument/references": self.on_references,
            "textDocument/documentHighlight": self.on_document_highlight,
            "textDocument/prepareRename": self.on_prepare_rename,
            "textDocument/rename": self.on_rename,
            "textDocument/documentSymbol": self.on_document_symbol,
            "workspace/symbol": self.on_workspace_symbol,
            "textDocument/foldingRange": self.on_folding_range,
            "textDocument/formatting": self.on_formatting,
            "textDocument/rangeFormatting": self.on_range_formatting,
            "textDocument/semanticTokens/full": self.on_semantic_tokens,
            "textDocument/semanticTokens/full/delta": self.on_semantic_tokens_delta,
            "textDocument/codeAction": self.on_code_action,
            "textDocument/inlayHint": self.on_inlay_hint,
            "nython/stats": self.on_stats,
            "nython/analysis": self.on_analysis,
            "nython/documentText": self.on_document_text,
        }
        self.notifications = {
            "initialized": self.on_initialized,
            "exit": self.on_exit,
            "textDocument/didOpen": self.on_did_open,
            "textDocument/didChange": self.on_did_change,
            "textDocument/didClose": self.on_did_close,
            "textDocument/didSave": self.on_did_save,
            "workspace/didChangeWatchedFiles": self.on_did_change_watched,
            "workspace/didChangeConfiguration": self.on_did_change_configuration,
            "workspace/didChangeWorkspaceFolders": self.on_did_change_folders,
            "$/cancelRequest": self.on_cancel,
            "$/setTrace": self.on_ignore,
            "window/workDoneProgress/cancel": self.on_ignore,
        }

    # ── logging ──
    def log(self, *parts):
        if self.log_file is not None:
            try:
                self.log_file.write(" ".join(str(p) for p in parts) + "\n")
                self.log_file.flush()
            except Exception:
                pass

    def _load_builtins(self):
        d = _ny_builtins_dict()
        lines = []
        for k in d:
            v = d[k]
            if isinstance(v, type):
                kind = "c"
            elif callable(v):
                kind = "f"
            else:
                kind = "v"
            self.builtins[k] = v
            lines.append(k + "\t" + kind)
        for k in ("__file__", "__name__", "__doc__", "__package__", "__spec__", "__loader__", "__builtins__",
                  "__path__", "__annotations__", "__dict__", "__debug__"):
            if k not in self.builtins:
                self.builtins[k] = None
                lines.append(k + "\tv")
        L("builtins", "\n".join(lines))

    # ── sending ──
    def send(self, msg):
        self.t.write_message(msg)

    def respond(self, id, result):
        if isinstance(result, Raw):
            self.t.write_raw('{"jsonrpc": "2.0", "id": ' + json_encode(id) + ', "result": ' + result.text + '}')
        else:
            self.send(protocol.response(id, result))

    def notify(self, method, params):
        self.send(protocol.notification(method, params))

    def request(self, method, params, callback=None):
        id = "nylsp-" + str(self.next_id)
        self.next_id += 1
        self.waiting[id] = callback
        self.send(protocol.request(id, method, params))
        return id

    # ── the loop ──
    def pull(self):
        """Reads what has arrived (never blocks); cancellations take effect at once."""
        while self.t.pending():
            try:
                msg = self.t.read_message(0)
            except ProtocolError as e:
                self.send(protocol.error_response(None, e.code, str(e)))
                continue
            if msg is None:
                break
            if msg.get("method") == "$/cancelRequest":
                self.on_cancel(msg.get("params") or {})
                continue
            self.queue.append(msg)

    def check_cancel(self):
        """Raises _Cancelled when the request being handled was cancelled."""
        self.pull()
        if self.running is not None and self.running in self.cancelled:
            raise _Cancelled()

    def run(self):
        while self.exit_code is None:
            self.pull()
            if self.queue:
                msg = self.queue.pop(0)
                self.handle(msg)
                continue
            if self.idle():
                continue
            try:
                msg = self.t.read_message(None if self.wait_ms is None else self.wait_ms / 1000.0)
            except ProtocolError as e:
                self.send(protocol.error_response(None, e.code, str(e)))
                continue
            if msg is None:
                if self.t.closed:
                    # the end of input without exit: the client went away
                    self.exit_code = 0 if self.shutdown_requested else 1
                    break
                continue   # (the debounce delay passed)
            if msg.get("method") == "$/cancelRequest":
                self.on_cancel(msg.get("params") or {})
                continue
            self.queue.append(msg)
        for d in list(self.docs.values()):
            d.close()
        return self.exit_code

    def handle(self, msg):
        if "method" not in msg:
            # a response to one of our requests
            cb = self.waiting.pop(msg.get("id"), None)
            if cb is not None:
                try:
                    cb(msg.get("result"), msg.get("error"))
                except Exception as e:
                    self.log("response callback:", e)
            return
        method = msg["method"]
        params = msg.get("params")
        if "id" in msg:
            self.stats["requests"] += 1
            self.handle_request(msg["id"], method, params)
        else:
            self.stats["notifications"] += 1
            fn = self.notifications.get(method)
            if fn is None:
                return
            if not self.initialized and method != "exit":
                return
            try:
                fn(params if params is not None else {})
            except Exception as e:
                self.log("notification", method, "failed:", repr(e))

    def handle_request(self, id, method, params):
        if id in self.cancelled:
            self.cancelled.discard(id)
            self.stats["cancelled"] += 1
            self.send(protocol.error_response(id, protocol.RequestCancelled, "the request was cancelled"))
            return
        if not self.initialized and method != "initialize":
            self.send(protocol.error_response(id, protocol.ServerNotInitialized, "the server is not initialized"))
            return
        if self.shutdown_requested:
            self.send(protocol.error_response(id, protocol.InvalidRequest, "the server is shutting down"))
            return
        if method == "initialize" and self.initialized:
            self.send(protocol.error_response(id, protocol.InvalidRequest, "initialize was sent twice"))
            return
        fn = self.requests.get(method)
        if fn is None:
            self.send(protocol.error_response(id, protocol.MethodNotFound, "unhandled method " + method))
            return
        self.running = id
        t0 = time_ms()
        try:
            result = fn(params if params is not None else {})
            if id in self.cancelled:
                raise _Cancelled()
            self.respond(id, result)
        except _Cancelled:
            self.stats["cancelled"] += 1
            self.send(protocol.error_response(id, protocol.RequestCancelled, "the request was cancelled"))
        except LspError as e:
            self.send(protocol.error_response(id, e.code, e.message, e.data))
        except Exception as e:
            import traceback
            self.log("request", method, "failed:", traceback.format_exc())
            self.send(protocol.error_response(id, protocol.InternalError, method + ": " + repr(e)))
        dt = time_ms() - t0
        tm = self.timings.setdefault(method, [0, 0.0, 0.0])
        tm[0] += 1
        tm[1] += dt
        if dt > tm[2]:
            tm[2] = dt
        self.cancelled.discard(id)
        self.running = None

    def idle(self):
        """Work done while no message waits: diagnostics, then the index. True
        when something was done (input is looked at again first). A document's
        diagnostics wait until it has not changed for diagnosticDelay ms
        (typing is not slowed down by them)."""
        self.wait_ms = None
        now = time_ms()
        delay = self.options.get("diagnosticDelay", 150) or 0
        for d in list(self.docs.values()):
            if d.published_edits != d.edits or d.deps_dirty:
                left = delay - (now - d.changed_at) if d.published_edits != d.edits else 0
                if left <= 0:
                    self.publish_diagnostics(d)
                    return True
                if self.wait_ms is None or left < self.wait_ms:
                    self.wait_ms = left
        if self.indexing:
            left = self.ws.index_step(25)
            done = self.progress_total - left
            if self.progress_token is not None:
                pct = int(done * 100 / self.progress_total) if self.progress_total else 100
                self.notify("$/progress", {"token": self.progress_token, "value": {
                    "kind": "report", "message": str(done) + "/" + str(self.progress_total) + " files",
                    "percentage": pct}})
            if left == 0:
                self.indexing = False
                self.index_ms = time_ms() - self.index_started
                if self.progress_token is not None:
                    self.notify("$/progress", {"token": self.progress_token, "value": {
                        "kind": "end", "message": "indexed " + str(self.progress_total) + " files"}})
                # what the open documents import may have become known
                for d in self.docs.values():
                    d.deps_dirty = True
            return True
        return False

    # ── lifecycle ──
    def on_initialize(self, p):
        self.client_caps = p.get("capabilities") or {}
        opts = p.get("initializationOptions")
        if isinstance(opts, dict):
            for k in opts:
                self.options[k] = opts[k]
        encs = ((self.client_caps.get("general") or {}).get("positionEncodings")) or []
        self.encoding = "utf-16"
        for e in encs:
            if e in ("utf-16", "utf-8", "utf-32"):
                self.encoding = e
                break
        L("encoding", self.encoding)
        folders = p.get("workspaceFolders")
        if folders:
            for f in folders:
                self.ws.add_root(uri_to_path(f["uri"]))
        elif p.get("rootUri"):
            self.ws.add_root(uri_to_path(p["rootUri"]))
        elif p.get("rootPath"):
            self.ws.add_root(p["rootPath"])
        self.initialized = True
        return {
            "capabilities": {
                "positionEncoding": self.encoding,
                "textDocumentSync": {"openClose": True, "change": 2, "save": {"includeText": False}},
                "completionProvider": {"triggerCharacters": ["."], "resolveProvider": True,
                                       "completionItem": {"labelDetailsSupport": True}},
                "hoverProvider": True,
                "signatureHelpProvider": {"triggerCharacters": ["(", ","], "retriggerCharacters": [")"]},
                "definitionProvider": True,
                "declarationProvider": True,
                "typeDefinitionProvider": True,
                "referencesProvider": True,
                "documentHighlightProvider": True,
                "renameProvider": {"prepareProvider": True},
                "documentSymbolProvider": {"label": "Nython"},
                "workspaceSymbolProvider": True,
                "foldingRangeProvider": True,
                "documentFormattingProvider": True,
                "documentRangeFormattingProvider": True,
                "semanticTokensProvider": {
                    "legend": {"tokenTypes": SEMANTIC_TOKEN_TYPES, "tokenModifiers": SEMANTIC_TOKEN_MODIFIERS},
                    "full": {"delta": True},
                    "range": False},
                "codeActionProvider": {"codeActionKinds": ["quickfix", "source.fixAll"], "resolveProvider": False},
                "inlayHintProvider": {"resolveProvider": False},
                "workspace": {"workspaceFolders": {"supported": True, "changeNotifications": True}},
            },
            "serverInfo": {"name": "nylsp", "version": VERSION},
        }

    def on_initialized(self, p):
        self.ready = True
        if not self.ws.roots:
            return
        n = self.ws.scan()
        self.progress_total = n
        self.indexing = n > 0
        self.index_started = time_ms()
        window = self.client_caps.get("window") or {}
        if self.indexing and window.get("workDoneProgress"):
            token = "nylsp-index"
            self.progress_token = token
            self.request("window/workDoneProgress/create", {"token": token})
            self.notify("$/progress", {"token": token, "value": {
                "kind": "begin", "title": "Indexing the workspace", "cancellable": False,
                "message": "0/" + str(n) + " files", "percentage": 0}})

    def on_shutdown(self, p):
        self.shutdown_requested = True
        return None

    def on_exit(self, p):
        self.exit_code = 0 if self.shutdown_requested else 1

    def on_cancel(self, p):
        id = p.get("id")
        if id is None:
            return
        # a queued request is answered at once; the running one at its next check
        for i in range(len(self.queue)):
            m = self.queue[i]
            if m.get("id") == id and "method" in m:
                self.queue.pop(i)
                self.stats["cancelled"] += 1
                self.send(protocol.error_response(id, protocol.RequestCancelled, "the request was cancelled"))
                return
        if self.running == id:
            self.cancelled.add(id)

    def on_ignore(self, p):
        return None

    def on_did_change_configuration(self, p):
        s = p.get("settings")
        if isinstance(s, dict):
            sub = s.get("nylsp", s)
            if isinstance(sub, dict):
                for k in sub:
                    self.options[k] = sub[k]
        for d in self.docs.values():
            d.deps_dirty = True

    def on_did_change_folders(self, p):
        ev = p.get("event") or {}
        for f in ev.get("added") or []:
            self.ws.add_root(uri_to_path(f["uri"]))
        for f in ev.get("removed") or []:
            r = os.path.normpath(uri_to_path(f["uri"]))
            if r in self.ws.roots:
                self.ws.roots.remove(r)
        n = self.ws.scan()
        self.progress_total = n
        self.indexing = n > 0

    # ── documents ──
    def doc(self, p):
        td = p.get("textDocument") or {}
        uri = td.get("uri")
        d = self.docs.get(uri)
        if d is None:
            raise LspError(protocol.InvalidParams, "the document is not open: " + str(uri))
        return d

    def on_did_open(self, p):
        td = p["textDocument"]
        uri = td["uri"]
        old = self.docs.get(uri)
        if old is not None:
            old.close()
        path = os.path.normpath(os.path.abspath(uri_to_path(uri))) if uri.startswith("file:") else uri
        d = Document(uri, path, td.get("text", ""), td.get("version", 0), td.get("languageId", "nython"))
        self.docs[uri] = d
        self.ws.open_docs[path] = d.h
        self.ws.forget_handle(path)
        self.ws.entry(path, d.edits)

    def on_did_change(self, p):
        d = self.doc(p)
        v = (p.get("textDocument") or {}).get("version")
        for ch in p.get("contentChanges") or []:
            r = ch.get("range")
            if r is None:
                L("set_text", d.h, ch.get("text", ""))
            else:
                L("edit", d.h, r["start"]["line"], r["start"]["character"], r["end"]["line"], r["end"]["character"],
                  ch.get("text", ""))
            d.edits += 1
        d.changed_at = time_ms()
        if v is not None:
            d.version = v

    def on_did_close(self, p):
        td = p.get("textDocument") or {}
        d = self.docs.pop(td.get("uri"), None)
        if d is None:
            return
        self.ws.open_docs.pop(d.path, None)
        d.close()
        self.notify("textDocument/publishDiagnostics", {"uri": d.uri, "diagnostics": []})
        # the file on disk is what the workspace has again
        e = self.ws.files.get(d.path)
        if e is not None:
            e.mtime = -2
        self.after_change(d.path)

    def on_did_save(self, p):
        d = self.docs.get((p.get("textDocument") or {}).get("uri"))
        if d is not None:
            d.deps_dirty = True

    def on_did_change_watched(self, p):
        for ch in p.get("changes") or []:
            path = os.path.normpath(uri_to_path(ch["uri"]))
            if path in self.ws.open_docs:
                continue
            self.ws.forget_handle(path)
            t = ch.get("type", 2)
            if t == 3:   # deleted
                e = self.ws.files.pop(path, None)
                if path in self.ws.listed:
                    self.ws.listed.remove(path)
            else:
                if (path.endswith(".ny") or path.endswith(".py")) and path not in self.ws.listed and self.ws.in_workspace(path):
                    self.ws.listed.append(path)
                self.ws.entry(path)
            self.after_change(path)

    def after_change(self, path):
        """A module's exports may have changed: re-check the open documents that import it."""
        for imp in self.ws.importers_of(path):
            for d in self.docs.values():
                if d.path == imp:
                    d.deps_dirty = True

    # ── diagnostics ──
    def publish_diagnostics(self, d):
        before = self.ws.files.get(d.path)
        ver_before = before.version if before is not None else -1
        diags = self.diagnostics(d)
        d.published_edits = d.edits
        d.deps_dirty = False
        self.notify("textDocument/publishDiagnostics", {"uri": d.uri, "version": d.version, "diagnostics": diags})
        e = self.ws.files.get(d.path)
        if e is not None and e.version != ver_before:
            self.after_change(d.path)

    def diagnostics(self, d):
        a = d.analyze()
        out = list(a["diagnostics"])
        e = self.ws.entry(d.path, d.edits)
        # imports: modules not found, names a module does not have
        star_names = set()
        star_known = True
        for im in e.imports:
            target = self.ws.resolve_import(d.path, im)
            rng = im.get("moduleRange") or im.get("stmtRange")
            if target is None:
                top = im["module"].split(".")[0]
                if im["quoted"]:
                    out.append(self.diag(rng, 2, "unresolved-import", "Cannot find the file '" + im["module"] + "'"))
                    star_known = False
                elif im["level"] == 0 and (im["module"] in BUILTIN_MODULES or top in BUILTIN_MODULES or self.builtin_module(im["module"])):
                    if im["name"] == "*":
                        star_known = False
                else:
                    out.append(self.diag(rng, 2, "unresolved-import", "No module named '" + im["module"] + "'"))
                    if im["name"] == "*":
                        star_known = False
                continue
            if im["name"] == "*" or im["quoted"]:
                te = self.ws.entry(target)
                if te.star or te.has_getattr:
                    star_known = False
                for n in te.exports:
                    if not n.startswith("_") or im["quoted"]:
                        star_names.add(n)
                continue
            if im["from"]:
                te = self.ws.entry(target)
                nm = im["name"]
                if nm not in te.exports and not te.star and not te.has_getattr:
                    # a submodule of a package is importable too
                    sub = (im["module"] + "." + nm) if im["module"].strip(".") else nm
                    if self.ws.resolve_module(d.path, sub, im["level"]) is None:
                        out.append(self.diag(im.get("nameRange") or rng, 2, "unresolved-import-name",
                                             "cannot import name '" + nm + "' from '" + im["module"] + "'"))
        # (not while something was cut out by the error recovery: a cut def's
        # parameters would read as undefined in its island)
        if self.options.get("undefinedNames", True) and star_known and a["recoveries"] == 0:
            seen = set()
            for u in a["unresolved"]:
                n = u["name"]
                if n in star_names or n in self.builtins:
                    continue
                key = (n, u["range"]["start"]["line"], u["range"]["start"]["character"])
                if key in seen:
                    continue
                seen.add(key)
                out.append(self.diag(u["range"], 2, "undefined-name", "name '" + n + "' is not defined"))
        if self.options.get("review", True) and a["lines"] <= self.options.get("maxReviewLines", 4000):
            for f in self.review(d):
                out.append(self.review_diag(d, f))
        return out

    def diag(self, rng, severity, code, message, source="nython"):
        return {"range": rng, "severity": severity, "code": code, "source": source, "message": message}

    def review(self, d):
        """NyxAI's review findings for the document (cached per edit)."""
        if d.review_edits != d.edits:
            try:
                from nyxai.review import Reviewer
                rv = Reviewer()
                # a document that does not parse is reviewed as the error
                # recovery left it (the same lines; what was cut is not reviewed)
                wt = J("work_text", d.h)
                text = wt["text"] or d.text()
                cut = set(wt["patched"])
                # a const / nonlocal error stops ny_facts' parse: that line is left out too
                lines = text.split("\n")
                for g in d.analyze()["diagnostics"]:
                    if g["code"] in ("nython-const", "nython-nonlocal"):
                        gl = g["range"]["start"]["line"]
                        if gl < len(lines):
                            lines[gl] = lines[gl][:len(lines[gl]) - len(lines[gl].lstrip())] + "pass"
                            cut.add(gl)
                text = "\n".join(lines)
                d.review = rv.review_text(text, os.path.basename(d.path))
                d.review = [f for f in d.review if f.rule != "syntax-error" and (f.line - 1) not in cut
                            and not any((e["line"] - 1) in cut or (e["end"] - 1) in cut for e in f.edits)]
            except Exception as e:
                self.log("review failed:", repr(e))
                d.review = []
            d.review_edits = d.edits
        return d.review

    def review_diag(self, d, f):
        ln = max(0, f.line - 1)
        text = d.line(ln)
        start = len(text) - len(text.lstrip())
        sev = 1 if f.severity == "error" else 3 if f.severity in ("convention", "refactor") else 2
        msg = f.message
        if f.suggestion:
            msg = msg + " (" + f.suggestion + ")"
        return {"range": {"start": {"line": ln, "character": self.col(text, start)},
                          "end": {"line": ln, "character": self.col(text, len(text))}},
                "severity": sev, "code": f.rule, "source": "nyxai", "message": msg,
                "data": {"fixable": f.fixable()}}

    def col(self, text, i):
        """Character index i of `text` in the client's encoding."""
        if self.encoding == "utf-32":
            return i
        if self.encoding == "utf-8":
            return len(text[:i].encode("utf-8"))
        return _utf16_len(text[:i])

    def builtin_module(self, name):
        bm = getattr(sys, "builtin_module_names", ())
        return name in bm

    # ── helpers over the native half ──
    def pos(self, p):
        q = p.get("position") or {}
        return q.get("line", 0), q.get("character", 0)

    def at(self, d, p):
        line, ch = self.pos(p)
        return J("at", d.h, line, ch)

    def handle_of(self, path):
        for d in self.docs.values():
            if d.path == path:
                return d.h
        return self.ws.handle(path)

    def uri_of(self, path):
        for d in self.docs.values():
            if d.path == path:
                return d.uri
        return path_to_uri(path)

    def module_symbol(self, path, name):
        h = self.handle_of(path)
        if h is None:
            return None
        return J("find", h, name)

    def follow_import(self, path, imod, iname, ilevel, depth=0):
        """Where `from imod import iname` (iname "": `import imod`) leads: (file, symbol or None)."""
        if depth > 6:
            return None
        target = self.ws.resolve_module(path, imod, ilevel)
        if target is None:
            return None
        if not iname:
            return (target, None)
        s = self.module_symbol(target, iname)
        if s is not None:
            if s["kind"] == "n" and s["imod"]:
                further = self.follow_import(target, s["imod"], s["iname"], s["ilevel"], depth + 1)
                if further is not None:
                    return further
            if s["kind"] == "m" and s["imod"]:
                further = self.follow_import(target, s["imod"], "", 0, depth + 1)
                if further is not None:
                    return further
            return (target, s)
        # a submodule of a package
        sub = (imod + "." + iname) if imod.strip(".") else (imod + iname)
        t2 = self.ws.resolve_module(path, sub, ilevel)
        if t2 is not None:
            return (t2, None)
        return None

    def follow_ext(self, path, ext):
        """An attribute of an imported module / class: (file, symbol) or None."""
        if ext["rk"] == "M":
            mod = ext["imod"] + ("." + ext["path"] if ext["path"] else "")
            t = self.ws.resolve_module(path, mod, 0)
            if t is not None:
                s = self.module_symbol(t, ext["attr"])
                if s is not None:
                    return self.deref(t, s)
                sub = self.ws.resolve_module(path, mod + "." + ext["attr"], 0)
                if sub is not None:
                    return (sub, None)
            # m.a.attr where a is a name of module m
            if ext["path"]:
                base = self.ws.resolve_module(path, ext["imod"], 0)
                if base is not None:
                    parts = ext["path"].split(".")
                    s = self.module_symbol(base, parts[0])
                    if s is not None and s["kind"] == "c" and len(parts) == 1:
                        m = J("find_member", self.handle_of(base), parts[0], ext["attr"])
                        if m is not None:
                            return (base, m)
            return None
        if ext["rk"] == "X":
            if ext["recvKind"] != "n":
                return None
            r = self.follow_import(path, ext["imod"], ext["iname"], 0)
            if r is None or r[1] is None:
                return None
            tpath, cls = r
            if ext["path"]:
                return None
            if cls["kind"] in ("c", "e", "I", "N"):
                m = J("find_member", self.handle_of(tpath), cls["name"], ext["attr"])
                if m is not None:
                    return (tpath, m)
            return None
        return None

    def deref(self, path, s):
        """A symbol that is an import: what it imports."""
        if s is not None and s["kind"] == "n" and s["imod"]:
            r = self.follow_import(path, s["imod"], s["iname"], s["ilevel"])
            if r is not None and r[1] is not None:
                return r
        return (path, s)

    def location(self, path, s):
        zero = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}
        if s is None:
            return {"uri": self.uri_of(path), "range": zero}
        # (a binding the parser made has no name token: its statement)
        return {"uri": self.uri_of(path), "range": s.get("range") or s.get("full") or zero}

    def target_of(self, d, info):
        """The definition a position means: (file, symbol), (file, None) for a module, or None."""
        if info is None:
            return None
        if info.get("module") is not None and info.get("sym", -1) < 0:
            r = self.follow_import(d.path, info["module"], "", 0)
            return r
        s = info.get("symbol")
        if s is not None:
            if s["kind"] == "n":
                r = self.follow_import(d.path, s["imod"], s["iname"], s["ilevel"])
                if r is not None:
                    return r
                return (d.path, s)
            if s["kind"] == "m":
                if info.get("module") is not None:
                    r = self.follow_import(d.path, info["module"], "", 0)
                    if r is not None:
                        return r
                r = self.follow_import(d.path, s["imod"], "", 0)
                if r is not None:
                    return r
                return (d.path, s)
            if s["kind"] == "u":
                # a member defined nowhere in this file: a base class of another module's
                found = self.member_in_bases(d, s)
                if found is not None:
                    return found
            return (d.path, s)
        ext = info.get("ext")
        if ext is not None:
            return self.follow_ext(d.path, ext)
        if info.get("importedFrom") is not None:
            return self.follow_import(d.path, info["importedFrom"], info["importedName"], 0)
        if info.get("sym", -1) < 0 and info.get("objType") is None and not info.get("keyword"):
            # a name this file does not bind: a star or quoted import's
            r = self.star_target(d.path, info["name"])
            if r is not None:
                return r
        return None

    def member_in_bases(self, d, s):
        """A member of a class of d that one of its bases (another module's) defines."""
        cls = J("sym", d.h, self.class_sym(d, s))
        if cls is None:
            return None
        return self.bases_member(d.path, self.handle_of(d.path), cls, s["name"], 0)

    def bases_member(self, path, h, cls, attr, depth):
        """`attr` as one of class `cls`'s bases defines it, across files: (file, member) or None."""
        if depth > 12 or h is None:
            return None
        bts = cls.get("baseTypes") or []
        texts = cls.get("bases") or []
        for i in range(len(bts)):
            bt = bts[i]
            r = None
            if bt["k"] == "x" and bt["sym"] >= 0 and not bt["text"]:
                b = J("sym", h, bt["sym"])
                r = self.follow_import(path, b["imod"], b["iname"], b["ilevel"])
            elif bt["k"] == "c" and bt["sym"] >= 0:
                r = (path, J("sym", h, bt["sym"]))
            elif bt["k"] == "0" and i < len(texts) and texts[i].isidentifier():
                r = self.star_target(path, texts[i])
            if r is None or r[1] is None or r[1]["kind"] not in ("c", "e", "I", "N"):
                continue
            found = self.member_deep(r[0], r[1], attr, depth + 1)
            if found is not None:
                return found
        return None

    def member_deep(self, path, cls, attr, depth=0):
        """`attr` of class `cls` (a symbol of `path`), its bases in any file included."""
        h = self.handle_of(path)
        if h is None or depth > 12:
            return None
        if cls.get("scope", 0) == 0:
            m = J("find_member", h, cls["name"], attr)
            if m is not None:
                return (path, m)
        return self.bases_member(path, h, cls, attr, depth)

    def star_target(self, path, name, depth=0, seen=None):
        """What `name` is in `path` when a star import or a quoted import (Nython's
        include: the file runs in the importer's scope) brings it: (file, symbol)."""
        if seen is None:
            seen = set()
        if depth > 8 or path in seen:
            return None
        seen.add(path)
        e = self.ws.files.get(path)
        if e is None or e.export_key is None:
            e = self.ws.entry(path)
        for im in e.imports:
            if im["name"] != "*" and not im["quoted"]:
                continue
            t = self.ws.resolve_import(path, im)
            if t is None:
                continue
            te = self.ws.entry(t)
            s = te.exports.get(name)
            if s is not None and s["kind"] not in ("u",) and (im["quoted"] or not name.startswith("_")):
                return self.deref(t, s)
            if te.star:
                r = self.star_target(t, name, depth + 1, seen)
                if r is not None:
                    return r
        return None

    def class_sym(self, d, s):
        """The class symbol a member's scope belongs to."""
        o = J("owner", d.h, s["scope"])
        return o["id"] if o is not None else -1

    # ── completion ──
    def on_completion(self, p):
        d = self.doc(p)
        line, ch = self.pos(p)
        cx = J("context", d.h, line, ch)
        if cx.get("none") or cx["inComment"] or cx["inString"] or cx.get("naming"):
            return {"isIncomplete": False, "items": []}
        prefix = cx["prefix"]
        # the same question about the same analysis: the answer kept (typing in a
        # line keeps the analysis, so `self.` asked again costs nothing)
        gen = L("generation", d.h)
        rt = cx.get("receiverType") or {}
        key = (d.uri, gen, cx.get("import"), cx.get("module"), cx.get("receiver"), rt.get("k"), rt.get("sym"),
               rt.get("text"), prefix, cx.get("scope"), line if cx.get("receiver") is None else -1)
        if key == self.completion_key:
            return self.completion_result
        items = []
        imp = cx.get("import")
        if imp is not None:
            items = self.complete_import(d, imp, cx)
        elif cx.get("receiver") is not None:
            items = self.complete_members(d, cx)
        else:
            items = self.complete_names(d, line, ch)
        items = self.rank(items, prefix)
        items.sort(key=lambda it: it["sortText"])
        result = Raw(json_encode({"isIncomplete": False, "items": items}))
        self.completion_key = key
        self.completion_result = result
        return result

    def rank(self, items, prefix):
        if not prefix:
            for i in range(len(items)):
                items[i]["sortText"] = self.sort_key(items[i], 0, i)
            return items
        out = []
        for i in range(len(items)):
            it = items[i]
            lab = it["label"]
            sc = fuzzy_score(prefix, lab)
            if sc is None or sc < 0:
                continue
            exact = 0 if lab.startswith(prefix) else 1 if lab.lower().startswith(prefix.lower()) else 2
            it["sortText"] = self.sort_key(it, exact, 100000 - int(sc))
            out.append(it)
        return out

    def sort_key(self, it, exact, k):
        group = it.pop("_group", 5)
        lab = it["label"]
        return _DIGITS[exact] + _DIGITS[group] + ("1" if lab.startswith("__") else "0") + str(1000000 + k) + lab

    def item(self, label, kind, detail="", data=None, group=5):
        it = {"label": label, "kind": kind, "_group": group}
        if detail:
            it["detail"] = detail
        if data is not None:
            it["data"] = data
        return it

    def sym_item(self, d, s, group, data=None):
        kind = _COMPLETION_KIND.get(s["kind"], 6)
        if s.get("property"):
            kind = 10
        det = s.get("detail") or ""
        if s["kind"] in ("f", "M") and det:
            det = "def " + s["name"] + det
        elif s["kind"] == "c":
            det = "class " + s["name"] + det
        it = self.item(s["name"], kind, det, data if data is not None else {"uri": d.uri, "sym": s["id"]}, group)
        return it

    def complete_names(self, d, line, ch):
        items = []
        seen = set()
        for v in J("visible", d.h, line, ch):
            if v["name"] in seen:
                continue
            seen.add(v["name"])
            s = {"name": v["name"], "kind": v["kind"], "id": v["id"], "detail": v["detail"], "property": v["property"]}
            items.append(self.sym_item(d, s, 1 + min(v["depth"], 2)))
        # names a star or quoted import brings in (the index's entry as it is: no parse)
        e = self.ws.files.get(d.path)
        for im in (e.imports if e is not None else []):
            if im["name"] != "*" and not im["quoted"]:
                continue
            t = self.ws.resolve_import(d.path, im)
            if t is None:
                continue
            te = self.ws.entry(t)
            for n in te.exports:
                s = te.exports[n]
                if n in seen or (n.startswith("_") and not im["quoted"]) or s["kind"] in ("m", "n"):
                    continue
                seen.add(n)
                items.append(self.sym_item(d, s, 4, {"path": t, "name": n}))
        import keyword
        kws = list(keyword.kwlist)
        if not d.is_python():
            kws = kws + _NY_KEYWORDS
        for k in kws:
            if k not in seen:
                seen.add(k)
                items.append(self.item(k, 14, "keyword", {"keyword": k}, 6))
        for n in self.builtins:
            if n in seen or n.startswith("_"):
                continue
            v = self.builtins[n]
            kind = 7 if isinstance(v, type) else 3 if callable(v) else 6
            items.append(self.item(n, kind, "builtin", {"builtin": n}, 7))
        return items

    def complete_members(self, d, cx):
        t = cx.get("receiverType") or {}
        k = t.get("k")
        items = []
        if k in ("c", "i") and t["sym"] >= 0:
            items = self.class_items(d, d.h, t["sym"], d.path, k == "c")
        elif k == "m":
            mod = cx.get("receiverImod", "") + ("." + t["text"] if t.get("text") else "")
            items = self.module_items(d, mod)
        elif k in ("x", "X"):
            r = self.follow_import(d.path, cx.get("receiverImod", ""), cx.get("receiverIname", ""), 0)
            if r is not None:
                tpath, s = r
                if s is None:
                    items = self.module_items(d, self.ws.module_name(tpath), tpath)
                elif s["kind"] in ("c", "e", "I", "N") and not t.get("text"):
                    items = self.class_items(d, self.handle_of(tpath), s["id"], tpath, k == "x")
        elif k in ("b", "B"):
            items = self.builtin_type_items(t["text"])
        return items

    def stamp(self, path):
        """What changes when a file's text does: an open document's edit count, else its mtime."""
        for od in self.docs.values():
            if od.path == path:
                return ("doc", od.edits)
        try:
            return ("file", os.stat(path).st_mtime)
        except OSError:
            return ("gone", 0)

    def class_items(self, d, h, cls_id, path, on_class, depth=0):
        # another file's class: its members as they were, while that file is unchanged
        key = None
        if path != d.path:
            key = (path, cls_id, on_class)
            hit = self.member_cache.get(key)
            if hit is not None and hit[0] == self.stamp(path):
                return [dict(it) for it in hit[1]]
        items = self.class_items_now(d, h, cls_id, path, on_class, depth)
        if key is not None:
            self.member_cache[key] = (self.stamp(path), [dict(it) for it in items])
        return items

    def class_items_now(self, d, h, cls_id, path, on_class, depth):
        items = []
        m = J("members", h, cls_id)
        seen = set()
        uri = self.uri_of(path)
        for s in m["members"]:
            if s["name"] in seen:
                continue
            seen.add(s["name"])
            s2 = {"name": s["name"], "kind": s["kind"], "id": s["id"], "detail": s["detail"], "property": s["property"]}
            items.append(self.sym_item(d, s2, 1, {"uri": uri, "path": path, "sym": s["id"]}))
        for bt in m["externalBases"]:
            if bt["k"] == "x" and bt["sym"] >= 0:
                b = J("sym", h, bt["sym"])
                r = self.follow_import(path, b["imod"], b["iname"], b["ilevel"])
                if r is not None and r[1] is not None:
                    for it in self.class_items(d, self.handle_of(r[0]), r[1]["id"], r[0], on_class, depth + 1):
                        if it["label"] not in seen:
                            seen.add(it["label"])
                            it["_group"] = 2
                            items.append(it)
            elif bt["k"] == "B":
                for it in self.builtin_type_items(bt["text"]):
                    if it["label"] not in seen:
                        seen.add(it["label"])
                        items.append(it)
            elif bt["k"] == "?":
                r = self.star_target(path, bt["text"])
                if r is not None and r[1] is not None and r[1]["kind"] in ("c", "e", "I", "N") and depth < 12:
                    for it in self.class_items(d, self.handle_of(r[0]), r[1]["id"], r[0], on_class, depth + 1):
                        if it["label"] not in seen:
                            seen.add(it["label"])
                            it["_group"] = 2
                            items.append(it)
        return items

    def module_items(self, d, mod, path=None):
        items = []
        if path is None:
            path = self.ws.resolve_module(d.path, mod, 0)
        if path is not None:
            e = self.ws.entry(path)
            for n in e.exports:
                s = e.exports[n]
                if n.startswith("_") and not n.startswith("__"):
                    continue
                items.append(self.sym_item(d, s, 1, {"path": path, "name": n}))
            if os.path.basename(path).startswith("__init__."):
                for name, pkg in self.ws.list_modules(d.path, mod):
                    if name not in e.exports:
                        items.append(self.item(name, 9, "module", {"module": mod + "." + name}, 2))
            return items
        if mod in BUILTIN_MODULES or self.builtin_module(mod):
            try:
                import importlib
                m = importlib.import_module(mod)
                for n in dir(m):
                    if n.startswith("_"):
                        continue
                    v = getattr(m, n, None)
                    kind = 7 if isinstance(v, type) else 3 if callable(v) else 9 if type(v).__name__ == "module" else 6
                    items.append(self.item(n, kind, mod + "." + n, {"modattr": [mod, n]}, 1))
            except Exception:
                pass
        return items

    def sample(self, name):
        """A value of builtin type `name` (dir() of the type itself lists little)"""
        samples = {"str": "", "list": [], "dict": {}, "int": 0, "float": 0.0, "bytes": b"", "set": set(),
                   "tuple": (), "bool": True, "bytearray": bytearray(), "frozenset": frozenset(), "complex": 1j}
        if name in samples:
            return samples[name]
        tp = self.builtins.get(name)
        return tp if isinstance(tp, type) else None

    def builtin_type_items(self, name):
        items = []
        v0 = self.sample(name)
        if v0 is None:
            return items
        for n in dir(v0):
            if n.startswith("_"):
                continue
            v = getattr(v0, n, None)
            items.append(self.item(n, 2 if callable(v) else 10, name + "." + n, {"typeattr": [name, n]}, 1))
        return items

    def complete_import(self, d, imp, cx):
        items = []
        kind = imp
        mod = cx.get("module", "")
        if kind in ("module", "from-module"):
            m = mod.split(",")[-1].strip()
            pkg = m.rsplit(".", 1)[0] if "." in m else ""
            for name, is_pkg in self.ws.list_modules(d.path, pkg):
                items.append(self.item(name, 9, "package" if is_pkg else "module", {"module": (pkg + "." if pkg else "") + name}, 1))
        elif kind == "from-name":
            items = self.module_items(d, mod)
        return items

    def on_completion_resolve(self, item):
        data = item.get("data") or {}
        doc = ""
        detail = item.get("detail", "")
        try:
            if "sym" in data:
                path = data.get("path")
                h = self.handle_of(path) if path else None
                if h is None:
                    dd = self.docs.get(data.get("uri"))
                    h = dd.h if dd is not None else None
                    path = dd.path if dd is not None else None
                if h is not None:
                    s = J("sym", h, data["sym"])
                    if s is not None:
                        path2, s2 = self.deref(path, s)
                        detail = self.signature_text(s2)
                        doc = s2.get("doc", "")
            elif "path" in data and "name" in data:
                s = self.module_symbol(data["path"], data["name"])
                if s is not None:
                    path2, s2 = self.deref(data["path"], s)
                    detail = self.signature_text(s2)
                    doc = s2.get("doc", "")
            elif "builtin" in data:
                v = self.builtins.get(data["builtin"])
                doc = getattr(v, "__doc__", None) or ""
                detail = self.builtin_signature(data["builtin"], v) or detail
            elif "typeattr" in data:
                tp = self.sample(data["typeattr"][0])
                v = getattr(tp, data["typeattr"][1], None)
                doc = getattr(v, "__doc__", None) or ""
            elif "modattr" in data:
                import importlib
                m = importlib.import_module(data["modattr"][0])
                v = getattr(m, data["modattr"][1], None)
                doc = getattr(v, "__doc__", None) or ""
            elif "module" in data:
                p = self.ws.resolve_module(None, data["module"], 0)
                if p is not None:
                    h = self.handle_of(p)
                    if h is not None:
                        doc = J("analyze", h)["moduleDoc"]
        except Exception as e:
            self.log("resolve:", repr(e))
        out = dict(item)
        if detail:
            out["detail"] = detail
        if doc:
            out["documentation"] = {"kind": "markdown", "value": "```python\n" + (detail or item["label"]) + "\n```\n" + doc}
        return out

    def signature_text(self, s):
        if s is None:
            return ""
        k = s["kind"]
        if k in ("f", "M"):
            if s.get("property"):
                return "(property) " + s["name"] + (": " + s["returns"] if s.get("returns") else "")
            return ("async def " if s.get("async") else "def ") + s["name"] + (s.get("detail") or "()")
        if k == "c":
            return "class " + s["name"] + (s.get("detail") or "")
        t = self.type_name(s.get("type"))
        txt = s["name"]
        if t:
            txt += ": " + t
        if s.get("value") and k in ("k", "E"):
            txt += " = " + s["value"]
        return txt

    def type_name(self, t):
        if not t:
            return ""
        k = t.get("k")
        if k == "b":
            return t["text"]
        if k == "i":
            return t["name"]
        if k == "c":
            return "type[" + t["name"] + "]"
        if k == "f":
            return "function"
        if k == "m":
            return "module"
        if k == "X":
            return t["name"] + ("." + t["text"] if t.get("text") else "")
        if k == "B":
            return "type[" + t["text"] + "]"
        return ""

    def builtin_signature(self, name, v):
        try:
            import inspect
            return name + str(inspect.signature(v))
        except Exception:
            pass
        doc = getattr(v, "__doc__", None) or ""
        first = doc.split("\n")[0].strip()
        if first.startswith(name + "(") and first.endswith(")") or (first.startswith(name + "(") and " -> " in first):
            return first
        return ""

    # ── hover ──
    def on_hover(self, p):
        d = self.doc(p)
        info = self.at(d, p)
        if info is None:
            return None
        rng = info["range"]
        md = self.hover_markdown(d, info)
        if not md:
            return None
        return {"contents": {"kind": "markdown", "value": md}, "range": rng}

    def hover_markdown(self, d, info):
        s = info.get("symbol")
        if info.get("keyword"):
            return None
        if s is None:
            b = info.get("builtin")
            if info.get("objType") is None:
                r0 = self.star_target(d.path, info["name"])
                if r0 is not None and r0[1] is not None:
                    return self.md(self.hover_head(r0[1], r0[0]), r0[1].get("doc", ""))
            if b is not None:
                name = info["name"]
                v = self.builtins.get(name)
                kind = "(builtin class) class " if b == "c" else "(builtin function) " if b == "f" else "(builtin) "
                sig = self.builtin_signature(name, v) if b == "f" else name
                doc = getattr(v, "__doc__", None) or ""
                return self.md(kind + (sig or name), doc)
            r = self.target_of(d, info)
            if r is not None and r[1] is not None:
                return self.md(self.hover_head(r[1], r[0]), r[1].get("doc", ""))
            if info.get("module") is not None and r is not None:
                h = self.handle_of(r[0])
                doc = J("analyze", h)["moduleDoc"] if h is not None else ""
                return self.md("(module) " + info["module"], doc)
            if info.get("objType") is not None:
                return self.md("(attribute) " + info["name"], "")
            return None
        if s["kind"] in ("n", "m") or s["kind"] == "u":
            r = self.target_of(d, info)
            if r is not None and r[1] is not None and (r[0] != d.path or r[1]["id"] != s["id"]):
                return self.md(self.hover_head(r[1], r[0]), r[1].get("doc", ""))
            if r is not None and r[1] is None:
                h = self.handle_of(r[0])
                doc = J("analyze", h)["moduleDoc"] if h is not None else ""
                return self.md("(module) " + (s["imod"] or s["name"]), doc)
            if s["kind"] == "n":
                return self.md("(import) from " + s["imod"] + " import " + s["iname"], "")
            if s["kind"] == "m":
                return self.md("(module) " + (s["imod"] or s["name"]), "")
        return self.md(self.hover_head(s, d.path), s.get("doc", ""))

    def hover_head(self, s, path):
        k = s["kind"]
        cont = s.get("container") or ""
        prefix = cont + "." if cont and s.get("member") else ""
        if k in ("f", "M"):
            if s.get("property"):
                return "(property) " + prefix + s["name"] + (": " + s["returns"] if s.get("returns") else "")
            what = "(method) " if k == "M" else "(function) "
            if s.get("generator"):
                what = "(generator) " if k == "f" else "(generator method) "
            return what + ("async def " if s.get("async") else "def ") + prefix + s["name"] + (s.get("detail") or "()")
        if k == "c":
            return "(class) class " + s["name"] + (s.get("detail") or "")
        if k == "e":
            return "(enum) " + s["name"]
        if k == "I":
            return "(interface) " + s["name"]
        if k == "N":
            return "(namespace) " + s["name"]
        word = _KIND_WORD.get(k, "variable")
        if s.get("const"):
            word = "constant"
        t = self.type_name(s.get("type"))
        txt = "(" + word + ") " + prefix + s["name"]
        if t:
            txt += ": " + t
        if s.get("value") and (k in ("k", "E") or s.get("const") or ((s.get("type") or {}).get("k") == "b" and k in ("v", "A", "F"))):
            txt += " = " + s["value"]
        return txt

    def md(self, head, doc):
        out = "```python\n" + head + "\n```"
        if doc:
            out += "\n---\n" + doc.strip()
        return out

    # ── signature help ──
    def on_signature_help(self, p):
        d = self.doc(p)
        line, ch = self.pos(p)
        c = J("call_at", d.h, line, ch)
        if c is None:
            return None
        tg = c["target"]
        sig = self.signature_of(d, tg, c["callee"])
        if sig is None:
            return None
        label, params, doc, pnames = sig
        if c["kw"]:
            active = pnames.index(c["kw"]) if c["kw"] in pnames else len(pnames)
        else:
            active = c["active"]
            for i in range(len(params)):
                if params[i].startswith("*") and not params[i].startswith("**") and params[i] != "*" and active >= i:
                    active = i
                    break
        info = {"label": label, "parameters": []}
        if doc:
            info["documentation"] = {"kind": "markdown", "value": doc}
        # each parameter as [start, end] in the label (UTF-16 offsets, LSP's)
        lp = label.find("(")
        off = lp + 1
        for prm in params:
            i = label.find(prm, off)
            if i < 0:
                info["parameters"].append({"label": prm})
                continue
            a = _utf16_len(label[:i])
            info["parameters"].append({"label": [a, a + _utf16_len(prm)]})
            off = i + len(prm)
        info["activeParameter"] = active
        return {"signatures": [info], "activeSignature": 0, "activeParameter": active}

    def signature_of(self, d, tg, callee):
        """[label, parameters as written, doc, parameter names] of what a call calls."""
        params = None
        pnames = None
        name = callee.split(".")[-1].replace("()", "")
        doc = ""
        ret = ""
        bound = tg["bound"]
        if tg["fsym"] >= 0:
            params = list(tg["params"])
            pnames = list(tg["pnames"])
            doc = tg.get("doc", "")
            name = tg["name"] if tg.get("cls", -1) < 0 else tg.get("className", tg["name"])
            if tg.get("cls", -1) >= 0 and tg.get("classDoc"):
                doc = tg["classDoc"]
            det = tg.get("detail", "")
            if " -> " in det and tg.get("cls", -1) < 0:
                ret = det[det.rfind(" -> "):]
        elif tg.get("cls", -1) >= 0:
            params = []
            pnames = []
            name = tg.get("className", name)
            doc = tg.get("classDoc", "")
        elif tg["ext"]["k"] != "0":
            r = None
            ext = tg["ext"]
            if ext["k"] in ("x", "X") and not ext["text"]:
                r = self.follow_import(d.path, tg.get("extImod", ""), tg.get("extIname", ""), 0)
            elif ext["k"] in ("x", "X") and "." not in ext["text"]:
                # a member of a class of another module (C.m / C().m)
                rc = self.follow_import(d.path, tg.get("extImod", ""), tg.get("extIname", ""), 0)
                if rc is not None and rc[1] is not None and rc[1]["kind"] in ("c", "e", "I", "N"):
                    m = J("find_member", self.handle_of(rc[0]), rc[1]["name"], ext["text"])
                    if m is not None:
                        r = (rc[0], m)
                        if ext["k"] == "X" and m["kind"] == "M" and not m.get("static"):
                            bound = True
            elif ext["k"] == "m" and ext["text"]:
                parts = ext["text"].split(".")
                mod = tg.get("extImod", "") + ("." + ".".join(parts[:-1]) if len(parts) > 1 else "")
                t = self.ws.resolve_module(d.path, mod, 0)
                if t is not None:
                    s = self.module_symbol(t, parts[-1])
                    if s is not None:
                        r = self.deref(t, s)
            if r is not None and r[1] is not None:
                s = r[1]
                if s["kind"] == "c":
                    init = J("find_member", self.handle_of(r[0]), s["name"], "__init__")
                    doc = s.get("doc", "")
                    name = s["name"]
                    if init is not None:
                        params = list(init["params"])
                        pnames = list(init["pnames"])
                        bound = True
                    else:
                        params = []
                        pnames = []
                elif s["kind"] in ("f", "M"):
                    params = list(s["params"])
                    pnames = list(s["pnames"])
                    doc = s.get("doc", "")
                    name = s["name"]
                    if s.get("returns"):
                        ret = " -> " + s["returns"]
        elif tg["builtin"]:
            v = self.builtins.get(tg["builtin"])
            sig = self.builtin_signature(tg["builtin"], v)
            doc = getattr(v, "__doc__", None) or ""
            if not sig:
                return None
            inner = sig[sig.find("(") + 1:sig.rfind(")")]
            params = self.split_params(inner)
            pnames = [q.split("=")[0].split(":")[0].strip().lstrip("*") for q in params]
            name = tg["builtin"]
            if " -> " in sig[sig.rfind(")"):]:
                ret = sig[sig.rfind(")") + 1:]
        if params is None:
            return None
        if bound and params:
            params = params[1:]
            pnames = pnames[1:]
        label = name + "(" + ", ".join(params) + ")" + ret
        return [label, params, doc, pnames]

    def split_params(self, s):
        out = []
        depth = 0
        cur = ""
        for ch in s:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            if ch == "," and depth == 0:
                if cur.strip():
                    out.append(cur.strip())
                cur = ""
            else:
                cur += ch
        if cur.strip():
            out.append(cur.strip())
        return out

    # ── definition, declaration, type definition ──
    def on_definition(self, p):
        d = self.doc(p)
        info = self.at(d, p)
        r = self.target_of(d, info)
        if r is None:
            return None
        return [self.location(r[0], r[1])]

    def on_declaration(self, p):
        d = self.doc(p)
        info = self.at(d, p)
        if info is None:
            return None
        s = info.get("symbol")
        if s is not None and s.get("range") is not None:
            return [self.location(d.path, s)]
        return self.on_definition(p)

    def on_type_definition(self, p):
        d = self.doc(p)
        info = self.at(d, p)
        if info is None:
            return None
        s = info.get("symbol")
        t = None
        path = d.path
        if s is not None:
            r = self.target_of(d, info)
            if r is not None and r[1] is not None:
                path = r[0]
                s = r[1]
            t = s.get("type")
        elif info.get("objType") is not None:
            return None
        if not t:
            return None
        k = t.get("k")
        h = self.handle_of(path)
        if k in ("i", "c") and t["sym"] >= 0:
            cls = J("sym", h, t["sym"])
            return [self.location(path, cls)]
        if k in ("X", "x") and t["sym"] >= 0 and not t.get("text"):
            b = J("sym", h, t["sym"])
            r = self.follow_import(path, b["imod"], b["iname"], b["ilevel"])
            if r is not None and r[1] is not None:
                return [self.location(r[0], r[1])]
        return None

    # ── references, highlights, rename ──
    def references_of(self, d, p, include_decl=True):
        """Every place the symbol at a position is named: {uri: [range, ...]},
        and the defining file and symbol."""
        info = self.at(d, p)
        if info is None or info.get("keyword"):
            return None
        r = self.target_of(d, info)
        if r is None:
            if info.get("sym", -1) >= 0:
                r = (d.path, info["symbol"])
            else:
                return None
        tpath, ts = r
        if ts is None:
            return None
        out = {}
        def add(path, rng):
            uri = self.uri_of(path)
            lst = out.setdefault(uri, [])
            for x in lst:
                if x == rng:
                    return
            lst.append(rng)
        th = self.handle_of(tpath)
        for ref in J("refs", th, ts["id"]):
            if not include_decl and ref["role"] == "d":
                continue
            add(tpath, ref["range"])
        if ts["kind"] == "p":
            # a parameter of a module-level function: keyword arguments naming
            # it in the modules that import the function
            self.kwarg_refs(tpath, ts, add)
            return [out, tpath, ts]
        local = ts["scope"] != 0 and not ts.get("member")
        if local:
            return [out, tpath, ts]
        # the module's other users
        cls_name = None
        if ts.get("member"):
            cont = ts.get("container")
            if cont and ts.get("containerKind") in ("c", "e", "I", "N"):
                outer = self.module_symbol(tpath, cont)
                if outer is not None and outer["body"] == ts["scope"]:
                    cls_name = cont
            if cls_name is None:
                return [out, tpath, ts]
        users = set(self.ws.importers_of(tpath))
        for od in self.docs.values():
            if od.path != tpath:
                e = self.ws.entry(od.path, od.edits)
                if tpath in e.deps:
                    users.add(od.path)
        # the files a star or quoted import (Nython's include) brings tpath's
        # names into, transitively: their reads of the name that they do not bind
        star_users = self.star_importers(tpath)
        users |= star_users
        for upath in sorted(star_users):
            self.check_cancel()
            h = self.handle_of(upath)
            if h is None or upath == tpath:
                continue
            if cls_name is None:
                for u in J("analyze", h)["unresolved"]:
                    if u["name"] == ts["name"]:
                        add(upath, u["range"])
        # members read through self in subclasses of other files ('C': this
        # file defines no such member) whose bases lead to the class
        if cls_name is not None:
            for upath in sorted(users | set(od.path for od in self.docs.values())):
                if upath == tpath:
                    continue
                h = self.handle_of(upath)
                if h is None:
                    continue
                ref = _Ref(upath, h)
                for x in J("ext", h):
                    if x["rk"] != "C" or x["attr"] != ts["name"]:
                        continue
                    mem = J("at", h, x["range"]["start"]["line"], x["range"]["start"]["character"])
                    if mem is None or mem.get("sym", -1) < 0:
                        continue
                    r = self.target_of(ref, mem)
                    if r is not None and r[0] == tpath and r[1] is not None and r[1]["id"] == ts["id"]:
                        for rr in J("refs", h, mem["sym"]):
                            add(upath, rr["range"])
        for upath in sorted(users):
            self.check_cancel()
            if upath == tpath:
                continue
            e = self.ws.entry(upath)
            h = self.handle_of(upath)
            if h is None:
                continue
            ext = None
            for im in e.imports:
                if self.ws.resolve_import(upath, im) != tpath:
                    continue
                if cls_name is None:
                    if im["from"] and im["name"] == ts["name"]:
                        if im.get("alias"):
                            if im.get("nameRange"):
                                add(upath, im["nameRange"])
                        elif im["sym"] >= 0:
                            for ref in J("refs", h, im["sym"]):
                                add(upath, ref["range"])
                    elif not im["from"] and im["sym"] >= 0:
                        if ext is None:
                            ext = J("ext", h)
                        for x in ext:
                            if x["rk"] == "M" and x["recv"] == im["sym"] and not x["path"] and x["attr"] == ts["name"]:
                                add(upath, x["range"])
                else:
                    if im["from"] and im["name"] == cls_name and im["sym"] >= 0:
                        if ext is None:
                            ext = J("ext", h)
                        for x in ext:
                            if x["rk"] == "X" and x["recv"] == im["sym"] and not x["path"] and x["attr"] == ts["name"]:
                                add(upath, x["range"])
                        # members found in the file's own subclasses ('C': unresolved there)
                        for x in ext:
                            if x["rk"] == "C" and x["attr"] == ts["name"]:
                                cls = J("sym", h, x["recv"])
                                if cls is not None:
                                    for bt in cls.get("baseTypes") or []:
                                        if bt["k"] == "x" and bt["sym"] == im["sym"]:
                                            mem = J("at", h, x["range"]["start"]["line"], x["range"]["start"]["character"])
                                            if mem is not None and mem.get("sym", -1) >= 0:
                                                for ref in J("refs", h, mem["sym"]):
                                                    add(upath, ref["range"])
                                            else:
                                                add(upath, x["range"])
        return [out, tpath, ts]

    def star_importers(self, tpath):
        """The files that import tpath by a star or quoted import, and those that
        import one of them so, and so on."""
        out = set()
        todo = [tpath]
        while todo:
            p = todo.pop()
            for imp in self.ws.importers_of(p):
                if imp in out or imp == tpath:
                    continue
                e = self.ws.entry(imp)
                for im in e.imports:
                    if (im["name"] == "*" or im["quoted"]) and self.ws.resolve_import(imp, im) == p:
                        out.add(imp)
                        todo.append(imp)
                        break
        return out

    def kwarg_refs(self, tpath, param, add):
        fn = self.module_symbol(tpath, param.get("container") or "")
        if fn is None or fn["body"] != param["scope"] or fn["kind"] not in ("f", "c"):
            return
        for upath in sorted(self.ws.importers_of(tpath) | set(od.path for od in self.docs.values() if od.path != tpath)):
            self.check_cancel()
            if upath == tpath:
                continue
            e = self.ws.entry(upath)
            binds = [im["sym"] for im in e.imports if im["from"] and im["name"] == fn["name"] and im["sym"] >= 0
                     and self.ws.resolve_import(upath, im) == tpath]
            if not binds:
                continue
            h = self.handle_of(upath)
            for call in J("calls", h, 0, 1 << 30):
                ext = call["target"]["ext"]
                if ext["k"] != "x" or ext["sym"] not in binds or ext["text"]:
                    continue
                for a in call["args"]:
                    if a is not None and a["kw"] == param["name"] and a.get("kwRange"):
                        add(upath, a["kwRange"])

    def on_references(self, p):
        d = self.doc(p)
        ctx = p.get("context") or {}
        res = self.references_of(d, p, ctx.get("includeDeclaration", True))
        if res is None:
            return None
        out = []
        for uri in sorted(res[0]):
            for rng in res[0][uri]:
                out.append({"uri": uri, "range": rng})
        return out

    def on_document_highlight(self, p):
        d = self.doc(p)
        info = self.at(d, p)
        if info is None or info.get("sym", -1) < 0:
            return None
        out = []
        for ref in J("refs", d.h, info["sym"]):
            out.append({"range": ref["range"], "kind": 2 if ref["role"] == "r" else 3})
        return out

    def renamable(self, d, info):
        """[range, placeholder] or raises LspError: what a rename at a position renames."""
        if info is None or info.get("keyword"):
            raise LspError(protocol.RequestFailed, "There is no symbol to rename here")
        if info.get("sym", -1) < 0 and info.get("ext") is None and self.star_target(d.path, info["name"]) is None:
            if info.get("builtin") is not None:
                raise LspError(protocol.RequestFailed, "'" + info["name"] + "' is a builtin and cannot be renamed")
            raise LspError(protocol.RequestFailed, "'" + info["name"] + "' cannot be resolved, so it cannot be renamed")
        s = info.get("symbol")
        if s is not None and s["kind"] == "m" and not s.get("iname") and info["name"] == (s["imod"] or "").split(".")[0] and not self.alias_binding(d, s):
            raise LspError(protocol.RequestFailed, "renaming a module needs its file renamed")
        r = self.target_of(d, info)
        if r is not None and r[1] is not None and not self.ws.in_workspace(r[0]) and not any(od.path == r[0] for od in self.docs.values()):
            raise LspError(protocol.RequestFailed, "'" + info["name"] + "' is defined outside the workspace (" + r[0] + ")")
        return [info["range"], info["name"]]

    def alias_binding(self, d, s):
        for im in J("imports", d.h):
            if im["sym"] == s["id"] and im.get("alias"):
                return True
        return False

    def on_prepare_rename(self, p):
        d = self.doc(p)
        info = self.at(d, p)
        rng, name = self.renamable(d, info)
        return {"range": rng, "placeholder": name}

    def on_rename(self, p):
        d = self.doc(p)
        new = p.get("newName", "")
        if not _identifier(new):
            raise LspError(protocol.InvalidParams, "'" + str(new) + "' is not a valid identifier")
        info = self.at(d, p)
        self.renamable(d, info)
        res = self.references_of(d, p, True)
        if res is None:
            raise LspError(protocol.RequestFailed, "There is no symbol to rename here")
        changes = {}
        for uri in res[0]:
            changes[uri] = [{"range": rng, "newText": new} for rng in res[0][uri]]
        caps = ((self.client_caps.get("workspace") or {}).get("workspaceEdit") or {})
        if caps.get("documentChanges"):
            dc = []
            for uri in sorted(changes):
                od = self.docs.get(uri)
                dc.append({"textDocument": {"uri": uri, "version": od.version if od is not None else None},
                           "edits": changes[uri]})
            return {"documentChanges": dc}
        return {"changes": changes}

    # ── symbols ──
    def on_document_symbol(self, p):
        d = self.doc(p)
        return Raw(L("symbols", d.h))

    def on_workspace_symbol(self, p):
        q = p.get("query", "")
        # what is still to index first (the request waits for it, cancellable)
        while self.ws.pending:
            self.check_cancel()
            self.ws.index_step(25)
        syms = self.ws.workspace_symbols()
        names = [s[0] for s in syms]
        if q:
            idx = fuzzy_rank(q, names, 200)
            # the name itself first, then names it starts, then the fuzzy order
            ql = q.lower()
            order = {}
            for k in range(len(idx)):
                order[idx[k]] = k
            idx = sorted(idx, key=lambda i: (0 if names[i] == q else 1 if names[i].lower() == ql else
                                             2 if names[i].startswith(q) else 3 if names[i].lower().startswith(ql) else 4,
                                             order[i]))
        else:
            idx = list(range(min(200, len(names))))
        out = []
        for i in idx:
            s = syms[i]
            info = {"name": s[0], "kind": s[1], "location": {"uri": self.uri_of(s[2]), "range": s[3]}}
            if s[4]:
                info["containerName"] = s[4]
            out.append(info)
        return out

    # ── folding ──
    def on_folding_range(self, p):
        d = self.doc(p)
        text = d.text()
        out = []
        seen = set()
        for f in J("folds", d.h):
            out.append(f)
            seen.add((f["startLine"], f["endLine"]))
        for r in text_fold_ranges(text):
            key = (r[0], r[1])
            if key in seen or r[1] <= r[0]:
                continue
            seen.add(key)
            out.append({"startLine": r[0], "endLine": r[1]})
        out.sort(key=lambda f: (f["startLine"], f["endLine"]))
        return out

    # ── formatting ──
    def format_edits(self, d, opts, lo=None, hi=None):
        text = d.text()
        unit = " " * int(opts.get("tabSize", 4)) if opts.get("insertSpaces", True) else "\t"
        new = text_format_nython(text, unit, {})
        if new == text:
            return []
        a = text.split("\n")
        b = new.split("\n")
        edits = []
        for h in text_diff(a, b):
            a0, al, b0, bl = h[0], h[1], h[2], h[3]
            if lo is not None and (a0 + max(al, 1) - 1 < lo or a0 > hi):
                continue
            if a0 + al < len(a):
                edits.append({"range": {"start": {"line": a0, "character": 0}, "end": {"line": a0 + al, "character": 0}},
                              "newText": "".join(x + "\n" for x in b[b0:b0 + bl])})
            elif a0 < len(a):
                last = len(a) - 1
                edits.append({"range": {"start": {"line": a0, "character": 0},
                                        "end": {"line": last, "character": self.col(a[last], len(a[last]))}},
                              "newText": "\n".join(b[b0:b0 + bl])})
            else:
                last = len(a) - 1
                end = {"line": last, "character": self.col(a[last], len(a[last]))}
                edits.append({"range": {"start": end, "end": end}, "newText": "\n" + "\n".join(b[b0:b0 + bl])})
        return edits

    def on_formatting(self, p):
        d = self.doc(p)
        return self.format_edits(d, p.get("options") or {})

    def on_range_formatting(self, p):
        d = self.doc(p)
        r = p["range"]
        return self.format_edits(d, p.get("options") or {}, r["start"]["line"], r["end"]["line"])

    # ── semantic tokens ──
    def on_semantic_tokens(self, p):
        d = self.doc(p)
        return Raw(L("tokens", d.h))

    def on_semantic_tokens_delta(self, p):
        d = self.doc(p)
        return Raw(L("tokens_delta", d.h, p.get("previousResultId", "")))

    # ── code actions ──
    def line_edit(self, d, e, nlines):
        """A NyxAI line edit {"line", "end", "new"} as a TextEdit."""
        lo = e["line"] - 1
        hi = e["end"]
        new = "".join(x + "\n" for x in e["new"])
        if hi < e["line"]:   # an insertion before `line`
            return {"range": {"start": {"line": lo, "character": 0}, "end": {"line": lo, "character": 0}}, "newText": new}
        if hi < nlines:
            return {"range": {"start": {"line": lo, "character": 0}, "end": {"line": hi, "character": 0}}, "newText": new}
        last = nlines - 1
        lt = d.line(last)
        return {"range": {"start": {"line": lo, "character": 0}, "end": {"line": last, "character": self.col(lt, len(lt))}},
                "newText": new[:-1] if new.endswith("\n") else new}

    def on_code_action(self, p):
        d = self.doc(p)
        r = p.get("range") or {"start": {"line": 0}, "end": {"line": 0}}
        lo = r["start"]["line"]
        hi = r["end"]["line"]
        only = (p.get("context") or {}).get("only")
        want_fix = only is None or any(k == "quickfix" or k.startswith("quickfix") for k in only)
        want_all = only is None or any(k == "source" or k.startswith("source.fixAll") for k in only)
        nlines = int(L("line_count", d.h))
        findings = self.review(d) if self.options.get("review", True) else []
        out = []
        if want_fix:
            for f in findings:
                if not f.fixable() or f.line - 1 < lo or f.line - 1 > hi:
                    continue
                diag = self.review_diag(d, f)
                edits = [self.line_edit(d, e, nlines) for e in f.edits]
                out.append({"title": "NyxAI: " + (f.suggestion or f.message), "kind": "quickfix", "diagnostics": [diag],
                            "isPreferred": True, "edit": {"changes": {d.uri: edits}}})
            # Nython's scope rule: declare the rebinding, or make a local
            a = d.analyze()
            for g in a["diagnostics"]:
                if g["code"] != "nython-scope":
                    continue
                gl = g["range"]["start"]["line"]
                if gl < lo or gl > hi:
                    continue
                msg = g["message"]
                q = msg.find("declare '")
                if q < 0:
                    continue
                decl = msg[q + 9:msg.find("'", q + 9)]
                name = decl.split(" ")[-1]
                text = d.line(gl)
                ind = text[:len(text) - len(text.lstrip())]
                out.append({"title": "Declare '" + decl + "' (keep rebinding the outer '" + name + "')", "kind": "quickfix",
                            "diagnostics": [g], "edit": {"changes": {d.uri: [{"range": {"start": {"line": gl, "character": 0},
                                                                                     "end": {"line": gl, "character": 0}},
                                                                           "newText": ind + decl + "\n"}]}}})
                st = g["range"]["start"]
                if text.lstrip().startswith(name):
                    out.append({"title": "Make '" + name + "' a local (var " + name + ")", "kind": "quickfix",
                                "diagnostics": [g], "edit": {"changes": {d.uri: [{"range": {"start": st, "end": st},
                                                                               "newText": "var "}]}}})
        if want_all:
            fixable = [f for f in findings if f.fixable()]
            if fixable:
                from nyxai.review import apply_edits
                all_edits = []
                for f in fixable:
                    for e in f.edits:
                        all_edits.append(e)
                used = apply_edits(d.text().split("\n"), all_edits)[1]
                edits = [self.line_edit(d, e, nlines) for e in used]
                out.append({"title": "NyxAI: fix all (" + str(len(fixable)) + ")", "kind": "source.fixAll.nyxai",
                            "edit": {"changes": {d.uri: edits}}})
        return out

    # ── inlay hints ──
    def on_inlay_hint(self, p):
        d = self.doc(p)
        if not self.options.get("inlayHints", True):
            return []
        r = p["range"]
        out = []
        for c in J("calls", d.h, r["start"]["line"], r["end"]["line"]):
            tg = c["target"]
            params = None
            if tg["fsym"] >= 0:
                params = list(tg["params"])
                pnames = list(tg["pnames"])
                if tg["bound"] and params:
                    params = params[1:]
                    pnames = pnames[1:]
            elif tg["ext"]["k"] != "0":
                sig = self.signature_of(d, tg, "")
                if sig is not None:
                    params = sig[1]
                    pnames = sig[3]
            if not params:
                continue
            for i in range(len(c["args"])):
                a = c["args"][i]
                if a is None or a["kw"] or a["star"]:
                    break
                if i >= len(params):
                    break
                prm = params[i]
                if prm.startswith("*") or prm == "/":
                    break
                name = pnames[i]
                if not name or a["name"] == name:
                    continue
                if a["pos"]["line"] < r["start"]["line"] or a["pos"]["line"] > r["end"]["line"]:
                    continue
                out.append({"position": a["pos"], "label": name + ":", "kind": 2, "paddingRight": True})
        return out

    # ── Nython's own requests ──
    def on_stats(self, p):
        docs = []
        for d in self.docs.values():
            a = d.analyze()
            docs.append({"uri": d.uri, "lines": a["lines"], "msParse": a["msParse"], "msTotal": a["msTotal"],
                         "recoveries": a["recoveries"], "pieces": int(L("pieces", d.h))})
        native = {}
        for op in NATIVE_MS:
            v = NATIVE_MS[op]
            native[op] = {"calls": v[0], "ms": round(v[1], 2), "decodeMs": round(v[2], 2)}
        return {"documents": docs, "indexed": len(self.ws.files), "pending": len(self.ws.pending), "native": native,
                "indexMs": self.index_ms, "requests": self.stats, "timings": self.timings,
                "encoding": self.encoding, "roots": self.ws.roots}

    def on_analysis(self, p):
        d = self.doc(p)
        return d.analyze()

    def on_document_text(self, p):
        d = self.doc(p)
        return {"text": d.text(), "version": d.version, "pieces": int(L("pieces", d.h)),
                "lines": int(L("line_count", d.h))}


def main(argv):
    """`nython -m nylsp [--stdio] [--tcp PORT [--host H]] [--log FILE]`"""
    tcp = None
    host = "127.0.0.1"
    log = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--stdio":
            pass
        elif a == "--tcp" and i + 1 < len(argv):
            i += 1
            tcp = int(argv[i])
        elif a.startswith("--tcp="):
            tcp = int(a[6:])
        elif a == "--host" and i + 1 < len(argv):
            i += 1
            host = argv[i]
        elif a == "--log" and i + 1 < len(argv):
            i += 1
            log = open(argv[i], "a")
        elif a in ("-h", "--help"):
            sys.stdout.write("usage: nython -m nylsp [--stdio | --tcp PORT [--host H]] [--log FILE]\n")
            return 0
        elif a == "--version":
            sys.stdout.write("nylsp " + VERSION + "\n")
            return 0
        i += 1
    if tcp is not None:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((host, tcp))
        srv.listen(1)
        sys.stderr.write("nylsp: listening on " + host + ":" + str(srv.getsockname()[1]) + "\n")
        sys.stderr.flush()
        conn, addr = srv.accept()
        srv.close()
        transport = SocketTransport(conn)
    else:
        transport = StdioTransport()
    server = Server(transport, log)
    code = server.run()
    return code
