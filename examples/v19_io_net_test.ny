var pass_n = 0
var fail_n = 0
def t(name, actual, expected):
    if str(actual) == str(expected):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print "FAIL: " + name + " got=" + str(actual) + " exp=" + str(expected)

print "=== FILE I/O ==="
import io
# per run: the sweep runs this file on both engines at once
var P = os_path_join(os_gettempdir(), "ny19_" + str(os_getpid()) + "_")
write((P + "a.txt"), "hello nython")
t("write_read", cat((P + "a.txt")), "hello nython")
t("exists_t", exists((P + "a.txt")), true)
t("exists_f", exists((P + "nonexist")), false)
t("file_size", file_size((P + "a.txt")), 12)

print "=== READLINES ==="
writelines((P + "lines.txt"), ["alpha", "beta", "gamma"])
var lines_data = readlines((P + "lines.txt"))
t("readlines", len(lines_data), 3)
t("line0", lines_data[0], "alpha")
t("line2", lines_data[2], "gamma")

print "=== FILE HANDLE ==="
var fh = open((P + "handle.txt"), "w")
t("open", fh > 0, true)
file_write(fh, "handle test data")
file_close(fh)
var fh2 = open((P + "handle.txt"), "r")
t("fread", file_read(fh2), "handle test data")
file_close(fh2)

print "=== FILE OPS ==="
write((P + "orig.txt"), "original")
file_copy((P + "orig.txt"), (P + "cp.txt"))
t("copy", cat((P + "cp.txt")), "original")
file_rename((P + "cp.txt"), (P + "mv.txt"))
t("rename", cat((P + "mv.txt")), "original")
t("old_gone", exists((P + "cp.txt")), false)
file_delete((P + "mv.txt"))
t("delete", exists((P + "mv.txt")), false)

print "=== APPEND ==="
write((P + "app.txt"), "A")
file_append((P + "app.txt"), "B")
file_append((P + "app.txt"), "C")
t("append", cat((P + "app.txt")), "ABC")

print "=== NETWORK ==="
import net
t("dns", dns_resolve("localhost"), "127.0.0.1")
t("url_enc", url_encode("a b"), "a%20b")
t("url_dec", url_decode("a%20b"), "a b")

print "=== TCP ECHO ==="
var srv = socket_tcp()
socket_setsockopt(srv, "reuseaddr", 1)
# Port 0: the system picks a free one (the sweep runs this file on both
# engines at once; fixed ports made the two runs connect to each other).
socket_bind(srv, 0)
socket_listen(srv, 1)
var cli = socket_tcp()
socket_connect(cli, "127.0.0.1", socket_getsockname(srv)[1])
var conn = socket_accept(srv)
socket_send(cli, "ECHO_TEST")
var msg = socket_recv(conn, 1024)
t("tcp_echo", msg, "ECHO_TEST")
socket_send(conn, "REPLY:" + msg)
t("tcp_reply", socket_recv(cli, 1024), "REPLY:ECHO_TEST")
socket_close(cli)
socket_close(conn)
socket_close(srv)

print "=== UDP ==="
var us = socket_udp()
var ur = socket_udp()
socket_bind(ur, 0)
socket_sendto(us, "UDP_MSG", "127.0.0.1", socket_getsockname(ur)[1])
var udp_r = socket_recvfrom(ur, 1024)
t("udp", udp_r[0], "UDP_MSG")
socket_close(us)
socket_close(ur)

print "=== OUTPUT ==="
import io
write((P + "log.txt"), "")
print_to((P + "log.txt"), "log entry 1")
print_to((P + "log.txt"), "log entry 2")
var log_lines = readlines((P + "log.txt"))
t("print_to", len(log_lines), 2)

print ""
print "============================================"
print "  V19 IO+NET: " + str(pass_n) + " passed, " + str(fail_n) + " failed"
print "============================================"

for f in os_glob(P + "*"):
    os_remove(f)
