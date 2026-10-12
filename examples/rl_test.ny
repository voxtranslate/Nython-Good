import io
# Line-at-a-time reading. The test writes its own file (it used to read
# /tmp/ny_multi.txt, which nothing created, so it could only ever fail).
var pass_n = 0
var fail_n = 0
def t(name, actual, expected):
    if str(actual) == str(expected):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print "FAIL: " + name + " got=" + str(actual) + " exp=" + str(expected)

var path = "/tmp/ny_rl_" + string_replace(str(time_ms()), ".", "_") + "_" + str(random_int(0, 999999)) + ".txt"
write_file(path, "alpha\nbeta\r\ngamma")

# legacy handle API: the line ending is stripped and EOF is none
var h = file_open(path, "r")
t("h_line1", file_readline(h), "alpha")
t("h_line2", file_readline(h), "beta")
t("h_line3", file_readline(h), "gamma")
t("h_eof", file_readline(h), none)
file_close(h)

# keep_newline=true: the ending stays and EOF is "" (what file objects need).
# A text-mode handle reads \r\n as \n (Python's universal newlines), on
# every platform; "rb" keeps the bytes.
var k = file_open(path, "r")
t("k_line1", file_readline(k, true), "alpha\n")
t("k_line2", file_readline(k, true), "beta\n")
t("k_line3", file_readline(k, true), "gamma")
t("k_eof", file_readline(k, true), "")
file_close(k)

# file objects from open(), as in Python
var f = open(path, "r")
t("o_line1", f.readline(), "alpha\n")
t("o_rest", f.readlines(), ["beta\n", "gamma"])
t("o_eof", f.readline(), "")
f.close()
var n = 0
with open(path) as g:
    for line in g:
        n += 1
t("o_iter", n, 3)

var b = file_open(path, "rb")
file_readline(b, true)
t("rb_keeps_crlf", file_readline(b, true), "beta\r\n")
file_close(b)

os_remove(path)
print "  READLINE: " + str(pass_n) + " passed, " + str(fail_n) + " failed"
