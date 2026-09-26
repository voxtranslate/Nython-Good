# Test 29: the native event layer, driven through the headless SDL3 stub.
#
# Writes a NY_STUB_EVENTS script before the first poll, so the stub replays
# it: dropped files, pointer leaving, focus changes, IME composition, key
# auto-repeat and the Cmd/Win modifier, fractional wheel steps, a resize, a
# native file dialog's answer, and input addressed to a second window. Then
# checks that Window.run sleeps instead of spinning while nothing changes.
#
# With a real SDL3 (no stub) nothing is scripted; the event checks are then
# reported as skipped rather than failed.
import "lib/gui.ny"

var npass = 0
var nfail = 0
def check(name, got, want):
    if got == want:
        npass = npass + 1
    else:
        nfail = nfail + 1
        print "  FAIL [" + name + "] got=" + str(got) + " want=" + str(want)
def check_true(name, c):
    check(name, c, true)

print "=== Test 29: native events ==="

var script_path = "/tmp/nython_test29_" + str(time_ms()) + "_" + str(random_int(0, 1000000)) + ".txt"
var script = "window 1\n"
script = script + "dialog /tmp/picked file.ny\n"
script = script + "move 10 10\n"
script = script + "drop /tmp/a.txt\n"
script = script + "drop /tmp/b.txt\n"
script = script + "droptext some text\n"
script = script + "leave\n"
script = script + "focus 0\n"
script = script + "focus 1\n"
script = script + "textedit nihon\n"
script = script + "keyrepeat kp_enter 2\n"
script = script + "key super+s\n"
script = script + "wheel 50 50 0.5 -0.25\n"
script = script + "wheel 50 50 0.75\n"
script = script + "resize 640 480\n"
script = script + "window 2\n"
script = script + "key a\n"
script = script + "window 1\n"
script = script + "quit\n"
write_file(script_path, script)
os_setenv("NY_STUB_EVENTS", script_path)

var h = gui_create_window("a", -1, -1, 400, 300, 1)
var h2 = gui_create_window("b", -1, -1, 200, 100, 1)
check_true("two windows", h != none and h2 != none and h != h2)
check_true("dialog started", gui_show_open_dialog(h, "Open", "", false))
check_true("min size", gui_set_min_size(h, 300, 200))
check_true("fullscreen on", gui_set_fullscreen(h, true))
check_true("is fullscreen", gui_is_fullscreen(h))
gui_set_fullscreen(h, false)
check("fullscreen off", gui_is_fullscreen(h), false)
check_true("text input area", gui_set_text_input_area(h, 10, 20, 100, 18, 5))

# Collect window 1's events until the scripted quit.
var types = []
var got = {}
var drops = []
var keydowns = []
var wheels = []
var n = 0
var done = false
while not done and n < 200:
    var evs = gui_wait_events(h, 20)
    var i = 0
    while i < len(evs):
        var e = evs[i]
        var t = e["type"]
        types.append(t)
        got[t] = e
        if t == "dropfile":
            drops.append(e["text"])
        if t == "keydown":
            keydowns.append(e)
        if t == "wheel":
            wheels.append(e)
        if t == "quit":
            done = true
        i = i + 1
    n = n + 1

var scripted = len(types) > 1
if not scripted:
    print "  (no scripted events: not running on the headless stub - event checks skipped)"
else:
    check("dialog answer", got["dialog"]["text"], "/tmp/picked file.ny")
    check("one dropfile event per file", len(drops), 2)
    check("dropped paths in order", drops[1], "/tmp/b.txt")
    check("droptext", got["droptext"]["text"], "some text")
    check_true("mouseleave delivered", got["mouseleave"] != none)
    check_true("focuslost delivered", got["focuslost"] != none)
    check_true("focusgained delivered", got["focusgained"] != none)
    check("IME composition", got["textedit"]["text"], "nihon")
    check("keypad enter reads enter", keydowns[0]["key"], "enter")
    check("first press is not a repeat", keydowns[0]["repeat"], false)
    check("held key repeats", keydowns[1]["repeat"], true)
    check("repeats counted", len(keydowns), 4)
    check("meta modifier", keydowns[3]["meta"], true)
    check("fractional wheel keeps dy", wheels[0]["dy"], 0.5)
    check("horizontal wheel dx", wheels[0]["dx"], -0.25)
    check("fraction carried: first step is 0", wheels[0]["delta"], 0)
    check("fraction carried: 0.5 + 0.75 makes a step", wheels[1]["delta"], 1)
    var resizes = 0
    var k = 0
    while k < len(types):
        if types[k] == "resize":
            resizes = resizes + 1
        k = k + 1
    check("RESIZED + PIXEL_SIZE_CHANGED reported once", resizes, 1)
    check("resize size", got["resize"]["w"], 640)
    check("window of the event", got["resize"]["window"], h)
    check("window size follows", gui_get_window_size(h)[0], 640)
    # The key for window 2 waited in its own queue.
    var evs2 = gui_poll_events(h2)
    check("second window's input kept for it", len(evs2), 2)
    check("second window's key", evs2[0]["key"], "a")
    check("tagged with its window", evs2[0]["window"], h2)
gui_destroy_window(h2)
gui_destroy_window(h)
os_remove(script_path)

# ── The loop sleeps while nothing changes ───────────────────────────────────
# A callback that reports "nothing changed" (returns false) makes the loop
# wait for input between turns instead of redrawing; one that paints (returns
# none, as every older callback does) keeps it polling and presenting.
var idle_calls = [0]
def idle_cb(r, e):
    idle_calls[0] = idle_calls[0] + 1
    return false
var w1 = Window(320, 200, "idle")
check_true("window started", w1.start())
var s1 = 0
while s1 < 10:
    w1.step(idle_cb)
    s1 = s1 + 1
check("idle turns wait for input", w1.waits, 9)
check("idle turns present nothing", w1.frames, 0)
check("idle callback called each turn", idle_calls[0], 10)
def paint_cb(r, e):
    r.clear(Color(0, 0, 0, 255))
var waits_before = w1.waits
var s2 = 0
while s2 < 5:
    w1.step(paint_cb)
    s2 = s2 + 1
check("painting turns present", w1.frames, 5)
check("after a painted frame the loop only polls", w1.waits - waits_before, 1)
w1.destroy()

print "Results: " + str(npass) + " passed, " + str(nfail) + " failed"
if nfail == 0:
    print "=== TEST 29 PASSED ==="
else:
    print "=== TEST 29 FAILED ==="
