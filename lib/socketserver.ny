# nython: module    (import it by name: it runs in a module scope of its own)
# lib/socketserver.ny - Python's socketserver (round 77): TCPServer,
# UDPServer, ThreadingTCPServer/ThreadingUDPServer (ThreadingMixIn),
# BaseRequestHandler, StreamRequestHandler, DatagramRequestHandler.
#
#     class Echo(socketserver.StreamRequestHandler):
#         def handle(self):
#             self.wfile.write(self.rfile.readline())
#     with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo) as srv:
#         srv.serve_forever()
import socket
import select
import threading

class BaseServer:
    timeout = none

    def __init__(self, server_address, RequestHandlerClass):
        self.server_address = server_address
        self.RequestHandlerClass = RequestHandlerClass
        self._shutdown_request = false
        self._is_shut_down = threading.Event()
        self._is_shut_down.set()

    def serve_forever(self, poll_interval=0.5):
        # Handles requests until shutdown(); each wait is at most
        # poll_interval seconds, so shutdown() is noticed.
        self._is_shut_down.clear()
        try:
            while not self._shutdown_request:
                var r = select.select([self], [], [], poll_interval)
                if self._shutdown_request:
                    break
                if len(r[0]) > 0:
                    self._handle_request_noblock()
                self.service_actions()
        finally:
            self._shutdown_request = false
            self._is_shut_down.set()

    def shutdown(self):
        # From another thread: serve_forever() returns.
        self._shutdown_request = true
        self._is_shut_down.wait()

    def service_actions(self):
        pass

    def handle_request(self):
        var t = self.socket.gettimeout()
        if t == none:
            t = self.timeout
        elif self.timeout != none:
            t = min(t, self.timeout)
        var r = select.select([self], [], [], t)
        if len(r[0]) == 0:
            self.handle_timeout()
            return
        self._handle_request_noblock()

    def _handle_request_noblock(self):
        var pair = none
        try:
            pair = self.get_request()
        except OSError:
            return
        if self.verify_request(pair[0], pair[1]):
            try:
                self.process_request(pair[0], pair[1])
            except Exception as e:
                self.handle_error(pair[0], pair[1])
                self.shutdown_request(pair[0])
        else:
            self.shutdown_request(pair[0])

    def handle_timeout(self):
        pass

    def verify_request(self, request, client_address):
        return true

    def process_request(self, request, client_address):
        self.finish_request(request, client_address)
        self.shutdown_request(request)

    def finish_request(self, request, client_address):
        self.RequestHandlerClass(request, client_address, self)

    def shutdown_request(self, request):
        self.close_request(request)

    def close_request(self, request):
        pass

    def handle_error(self, request, client_address):
        eprint("Exception occurred during processing of request from " + str(client_address))

    def server_close(self):
        pass

    def fileno(self):
        return self.socket.fileno()

    def fileno_handle(self):
        return self.socket.fileno_handle()

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.server_close()
        return false

class TCPServer(BaseServer):
    address_family = socket.AF_INET
    socket_type = socket.SOCK_STREAM
    request_queue_size = 5
    allow_reuse_address = false
    allow_reuse_port = false

    def __init__(self, server_address, RequestHandlerClass, bind_and_activate=true):
        BaseServer.__init__(self, server_address, RequestHandlerClass)
        self.socket = socket.socket(self.address_family, self.socket_type)
        if bind_and_activate:
            try:
                self.server_bind()
                self.server_activate()
            except BaseException:
                self.server_close()
                raise

    def server_bind(self):
        if self.allow_reuse_address:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()

    def server_activate(self):
        self.socket.listen(self.request_queue_size)

    def server_close(self):
        self.socket.close()

    def get_request(self):
        return self.socket.accept()

    def shutdown_request(self, request):
        try:
            request.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        self.close_request(request)

    def close_request(self, request):
        request.close()

class UDPServer(TCPServer):
    allow_reuse_address = false
    socket_type = socket.SOCK_DGRAM
    max_packet_size = 8192

    def get_request(self):
        var r = self.socket.recvfrom(self.max_packet_size)
        return ((r[0], self.socket), r[1])

    def server_activate(self):
        pass

    def shutdown_request(self, request):
        self.close_request(request)

    def close_request(self, request):
        pass

class ThreadingMixIn:
    # Each request on a thread of its own (daemon_threads: do not wait for
    # them at exit; block_on_close: server_close() joins them).
    daemon_threads = false
    block_on_close = true

    def process_request_thread(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)

    def process_request(self, request, client_address):
        var t = threading.Thread(target=self.process_request_thread, args=(request, client_address), daemon=self.daemon_threads)
        if not hasattr(self, "_threads"):
            self._threads = []
        # server_close() waits for the non-daemon ones (as Python's: a daemon
        # thread may be blocked on a kept-alive connection)
        if not self.daemon_threads and self.block_on_close:
            self._threads = [x for x in self._threads if x.is_alive()]
            self._threads.append(t)
        t.start()

    def server_close(self):
        TCPServer.server_close(self)
        if self.block_on_close and hasattr(self, "_threads"):
            for t in self._threads:
                t.join()
            self._threads = []

class ThreadingTCPServer(ThreadingMixIn, TCPServer):
    pass

class ThreadingUDPServer(ThreadingMixIn, UDPServer):
    pass

class BaseRequestHandler:
    def __init__(self, request, client_address, server):
        self.request = request
        self.client_address = client_address
        self.server = server
        self.setup()
        try:
            self.handle()
        finally:
            self.finish()

    def setup(self):
        pass

    def handle(self):
        pass

    def finish(self):
        pass

class StreamRequestHandler(BaseRequestHandler):
    rbufsize = -1
    wbufsize = 0
    timeout = none
    disable_nagle_algorithm = false

    def setup(self):
        self.connection = self.request
        if self.timeout != none:
            self.connection.settimeout(self.timeout)
        if self.disable_nagle_algorithm:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.rfile = self.connection.makefile("rb")
        self.wfile = self.connection.makefile("wb")

    def finish(self):
        try:
            self.wfile.flush()
        except OSError:
            pass
        self.wfile.close()
        self.rfile.close()

class DatagramRequestHandler(BaseRequestHandler):
    def setup(self):
        self.packet = self.request[0]
        self.socket = self.request[1]
        self.rfile = _BytesReader(self.packet)
        self.wfile = _BytesWriter()

    def finish(self):
        self.socket.sendto(self.wfile.getvalue(), self.client_address)

class _BytesReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, n=-1):
        if n < 0:
            n = len(self.data) - self.pos
        var out = self.data[self.pos:self.pos + n]
        self.pos = self.pos + len(out)
        return out

    def readline(self):
        var i = self.data.find(b"\n", self.pos)
        var end = len(self.data)
        if i >= 0:
            end = i + 1
        var out = self.data[self.pos:end]
        self.pos = end
        return out

class _BytesWriter:
    def __init__(self):
        self.parts = []

    def write(self, b):
        self.parts.append(bytes(b))
        return len(b)

    def getvalue(self):
        return b"".join(self.parts)
