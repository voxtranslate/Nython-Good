import io
# Write, check and read back a file. It lives in /tmp under a per-run name:
# the sweep runs both engines at once, and this used to leave
# test_output.txt in the repository root.
var passed = 0
var failed = 0
def check(name, got, expected):
    if str(got) == str(expected):
        passed += 1
    else:
        failed += 1
        print "FAIL:", name, "| got:", str(got), "| expected:", str(expected)

var path = "/tmp/ny_io_" + string_replace(str(time_ms()), ".", "_") + "_" + str(random_int(0, 999999)) + ".txt"
write_file(path, "Hello from Nython!\nLine 2\nLine 3")
check("exists", file_exists(path), true)
var content = read_file(path)
check("content", content, "Hello from Nython!\nLine 2\nLine 3")
check("length", len(content), 32)
os_remove(path)
check("removed", file_exists(path), false)
print "IO: " + str(passed) + " passed, " + str(failed) + " failed"
