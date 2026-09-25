// thirdparty/sdl3-stub/src/sdl3_stub.cpp
//
// Headless implementation of the SDL3 / SDL3_ttf / SDL3_image surface
// declared under thirdparty/sdl3-stub/include/. Nothing here talks to a
// real display, font rasteriser, or image decoder — every call is a no-op
// or returns plausible fake data, so that code written against the real
// SDL3 API (src/builtins/gui.cpp) can run to completion without a GPU,
// window system, or the real libraries installed.
//
// Environment variables (see HANDOFF.md / CLAUDE.md):
//   NY_STUB_AUTOQUIT=<n>    After n consecutive *empty* SDL_PollEvent polls
//                           (no other event pending), synthesize exactly one
//                           SDL_EVENT_QUIT and never again (latched). Lets
//                           GUI/IDE event loops terminate headlessly.
//   NY_STUB_DPI_SCALE=<f>   Fake content/display scale returned by the
//                           display- and window-scale queries.
//   NY_STUB_EVENTS=<file>   Scripted input. One command per line, read
//                           lazily — the file may still be growing (a
//                           driver process appends to it), so EOF only
//                           means "nothing yet". See "Scripted input" below
//                           for the command set. This is what lets the IDE
//                           be driven end to end headlessly: every earlier
//                           round could only construct it and quit.
//   NY_STUB_EVENT_GAP=<n>   Idle polls inserted after each scripted command
//                           (default 2), so every input gets frames drawn
//                           between it and the next, as with a real user.
//   NY_STUB_SNAP_ON_EXIT=<file>
//                           Write the last presented frame to <file> when
//                           the (auto)quit is delivered.
//
// Frame capture: when any of the three variables above is set, every draw
// call is recorded, and the last *presented* frame is kept as a display list
// (JSON lines: rects, lines, points, clip changes, and text runs with their
// font family, size, style and colour). tools/nyshot.py replays that list
// into a real PNG with real fonts — a headless screenshot.
//
// Every "object" (window, renderer, texture, surface, font, cursor) is a
// heap-allocated opaque struct with a non-null address, so identity/pointer
// checks in calling code behave sanely; nothing is ever double-freed because
// each destroy function nulls out via the caller's own handle registries in
// gui.cpp (this file does not need to track that).

#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_image/SDL_image.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include <string>
#include <atomic>
#include <vector>
#include <deque>
#include <unordered_map>
#include <cmath>

// ── Opaque struct definitions ───────────────────────────────────────────
struct SDL_Window   { std::string title; int w = 0, h = 0; int x = 0, y = 0; };
// Draw state is tracked (not just accepted and dropped) so frame capture can
// record what each primitive would actually have painted.
struct SDL_Renderer {
    SDL_Window* window = nullptr;
    Uint8 r = 0, g = 0, b = 0, a = 255;
    int vx = 0, vy = 0;              // viewport origin
};
// A texture made from a TTF surface remembers the text run it holds, since
// by the time SDL_RenderTexture draws it the string is otherwise long gone.
struct SDL_Texture  {
    int w = 0, h = 0;
    bool is_text = false;
    std::string text, family;
    float ptsize = 0.0f;
    int style = 0;
    SDL_Color color{255, 255, 255, 255};
};
struct SDL_Cursor   { SDL_SystemCursor id = SDL_SYSTEM_CURSOR_DEFAULT; };
struct TTF_Font     { float ptsize = 16.0f; TTF_FontStyleFlags style = TTF_STYLE_NORMAL; std::string path; };

// ── Frame capture ────────────────────────────────────────────────────────
// Stored compactly as structs and only formatted when a frame is written
// out, so recording costs a vector push per primitive.
struct CapOp {
    char kind;            // F fill, R rect, L line, P point, T text, K clip, k unclip, C clear
    float a, b, c, d;
    Uint8 r, g, bl, al;
    int str;              // index into CapFrame::texts for 'T'
};
struct CapText { std::string text, family; float size; int style; };
struct CapFrame {
    int w = 0, h = 0;
    long n = 0;
    std::vector<CapOp> ops;
    std::vector<CapText> texts;
    void clear() { ops.clear(); texts.clear(); }
};
static CapFrame g_cur, g_last;
static long g_frame_no = 0;
static int g_win_w = 0, g_win_h = 0;
static SDL_Window* g_last_window = nullptr;

static bool capture_enabled() {
    static int cached = -1;
    if (cached < 0) {
        const char* a = getenv("NY_STUB_EVENTS");
        const char* b = getenv("NY_STUB_SNAP_ON_EXIT");
        cached = ((a && *a) || (b && *b)) ? 1 : 0;
    }
    return cached == 1;
}

static void cap(char kind, SDL_Renderer* r, float a, float b, float c, float d) {
    if (!capture_enabled() || !r) return;
    g_cur.ops.push_back({kind, a + r->vx, b + r->vy, c, d, r->r, r->g, r->b, r->a, -1});
}

static void json_str(FILE* f, const std::string& s) {
    fputc('"', f);
    for (unsigned char ch : s) {
        if (ch == '"' || ch == '\\') { fputc('\\', f); fputc(ch, f); }
        else if (ch < 0x20) fprintf(f, "\\u%04x", ch);
        else fputc(ch, f);
    }
    fputc('"', f);
}

// Written to <path>.tmp and renamed, so a driver polling for the file never
// reads a half-written frame.
static bool write_frame(const CapFrame& fr, const std::string& path) {
    std::string tmp = path + ".tmp";
    FILE* f = fopen(tmp.c_str(), "w");
    if (!f) return false;
    fprintf(f, "{\"op\":\"frame\",\"w\":%d,\"h\":%d,\"n\":%ld}\n", fr.w, fr.h, fr.n);
    for (const CapOp& o : fr.ops) {
        switch (o.kind) {
        case 'k': fprintf(f, "{\"op\":\"unclip\"}\n"); break;
        case 'K': fprintf(f, "{\"op\":\"clip\",\"x\":%g,\"y\":%g,\"w\":%g,\"h\":%g}\n", o.a, o.b, o.c, o.d); break;
        case 'T': {
            const CapText& t = fr.texts[(size_t)o.str];
            fprintf(f, "{\"op\":\"text\",\"x\":%g,\"y\":%g,\"w\":%g,\"h\":%g,\"c\":[%d,%d,%d,%d],\"size\":%g,\"style\":%d,\"font\":",
                    o.a, o.b, o.c, o.d, o.r, o.g, o.bl, o.al, t.size, t.style);
            json_str(f, t.family);
            fputs(",\"text\":", f);
            json_str(f, t.text);
            fputs("}\n", f);
            break;
        }
        default: {
            const char* name = o.kind == 'F' ? "fill" : o.kind == 'R' ? "rect" :
                               o.kind == 'L' ? "line" : o.kind == 'P' ? "point" : "clear";
            fprintf(f, "{\"op\":\"%s\",\"a\":[%g,%g,%g,%g],\"c\":[%d,%d,%d,%d]}\n",
                    name, o.a, o.b, o.c, o.d, o.r, o.g, o.bl, o.al);
        }
        }
    }
    fclose(f);
    return rename(tmp.c_str(), path.c_str()) == 0;
}

static std::unordered_map<SDL_Surface*, CapText> g_surface_text;
static std::unordered_map<SDL_Surface*, SDL_Color> g_surface_color;

// ── Error string ─────────────────────────────────────────────────────────
static thread_local std::string g_last_error;

bool SDL_SetError(const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    g_last_error = buf;
    return false;
}

const char* SDL_GetError(void) {
    return g_last_error.c_str();
}

// ── Message box (headless: print to stderr) ─────────────────────────────
bool SDL_ShowSimpleMessageBox(SDL_MessageBoxFlags flags, const char* title,
                               const char* message, SDL_Window* window) {
    (void)flags; (void)window;
    fprintf(stderr, "[SDL3-stub] messagebox: %s: %s\n",
            title ? title : "", message ? message : "");
    return true;
}

// ── Core lifecycle ───────────────────────────────────────────────────────
static bool g_inited = false;

void SDL_SetMainReady(void) { /* no-op: headless, no real main entry to hand off */ }

bool SDL_Init(SDL_InitFlags flags) {
    (void)flags;
    g_inited = true;
    return true;
}

void SDL_Quit(void) {
    g_inited = false;
}

int SDL_GetVersion(void) {
    // Fake "3.2.0" — matches the shape real SDL3 uses (major*1e6+minor*1e3+micro).
    return 3 * 1000000 + 2 * 1000 + 0;
}

// ── Window management ─────────────────────────────────────────────────────
SDL_Window* SDL_CreateWindow(const char* title, int w, int h, SDL_WindowFlags flags) {
    (void)flags;
    auto* win = new SDL_Window();
    win->title = title ? title : "";
    win->w = w;
    win->h = h;
    win->x = 0;
    win->y = 0;
    g_win_w = w;
    g_win_h = h;
    g_last_window = win;
    return win;
}

void SDL_DestroyWindow(SDL_Window* window) {
    if (window == g_last_window) g_last_window = nullptr;
    delete window;
}

bool SDL_SetWindowPosition(SDL_Window* window, int x, int y) {
    if (!window) return false;
    window->x = x;
    window->y = y;
    return true;
}

bool SDL_GetWindowPosition(SDL_Window* window, int* x, int* y) {
    if (!window) return false;
    if (x) *x = window->x;
    if (y) *y = window->y;
    return true;
}

bool SDL_SetWindowSize(SDL_Window* window, int w, int h) {
    if (!window) return false;
    window->w = w;
    window->h = h;
    g_win_w = w;
    g_win_h = h;
    return true;
}

bool SDL_GetWindowSize(SDL_Window* window, int* w, int* h) {
    if (!window) return false;
    if (w) *w = window->w;
    if (h) *h = window->h;
    return true;
}

bool SDL_SetWindowTitle(SDL_Window* window, const char* title) {
    if (!window) return false;
    window->title = title ? title : "";
    return true;
}

const char* SDL_GetWindowTitle(SDL_Window* window) {
    static const char* empty = "";
    return window ? window->title.c_str() : empty;
}

bool SDL_ShowWindow(SDL_Window* window)   { return window != nullptr; }
bool SDL_HideWindow(SDL_Window* window)   { return window != nullptr; }
bool SDL_RaiseWindow(SDL_Window* window)  { return window != nullptr; }
bool SDL_MaximizeWindow(SDL_Window* window) { return window != nullptr; }
bool SDL_MinimizeWindow(SDL_Window* window) { return window != nullptr; }
bool SDL_RestoreWindow(SDL_Window* window)  { return window != nullptr; }
bool SDL_StartTextInput(SDL_Window* window) { return window != nullptr; }
bool SDL_StopTextInput(SDL_Window* window)  { return window != nullptr; }

static float dpi_scale_from_env() {
    const char* s = getenv("NY_STUB_DPI_SCALE");
    if (!s || !*s) return 1.0f;
    float f = (float)atof(s);
    return f > 0.0f ? f : 1.0f;
}

float SDL_GetWindowDisplayScale(SDL_Window* window) {
    (void)window;
    return dpi_scale_from_env();
}

const char* SDL_GetCurrentVideoDriver(void) {
    return "ny-stub";
}

// ── Displays ───────────────────────────────────────────────────────────
SDL_DisplayID SDL_GetPrimaryDisplay(void) {
    return 1u;
}

float SDL_GetDisplayContentScale(SDL_DisplayID displayID) {
    (void)displayID;
    return dpi_scale_from_env();
}

bool SDL_GetDisplayUsableBounds(SDL_DisplayID displayID, SDL_Rect* rect) {
    (void)displayID;
    if (!rect) return false;
    rect->x = 0; rect->y = 0; rect->w = 1920; rect->h = 1080;
    return true;
}

bool SDL_GetDisplayBounds(SDL_DisplayID displayID, SDL_Rect* rect) {
    return SDL_GetDisplayUsableBounds(displayID, rect);
}

// ── Cursors ────────────────────────────────────────────────────────────
SDL_Cursor* SDL_CreateSystemCursor(SDL_SystemCursor id) {
    auto* c = new SDL_Cursor();
    c->id = id;
    return c;
}

bool SDL_SetCursor(SDL_Cursor* cursor) {
    (void)cursor;
    return true;
}

void SDL_DestroyCursor(SDL_Cursor* cursor) {
    delete cursor;
}

// ── Renderer ───────────────────────────────────────────────────────────
SDL_Renderer* SDL_CreateRenderer(SDL_Window* window, const char* name) {
    (void)name;
    auto* r = new SDL_Renderer();
    r->window = window;
    return r;
}

void SDL_DestroyRenderer(SDL_Renderer* renderer) {
    delete renderer;
}

bool SDL_SetRenderDrawColor(SDL_Renderer* renderer, Uint8 r, Uint8 g, Uint8 b, Uint8 a) {
    if (!renderer) return false;
    renderer->r = r; renderer->g = g; renderer->b = b; renderer->a = a;
    return true;
}

bool SDL_SetRenderDrawBlendMode(SDL_Renderer* renderer, SDL_BlendMode) {
    return renderer != nullptr;
}

bool SDL_SetRenderVSync(SDL_Renderer* renderer, int) {
    return renderer != nullptr;
}

bool SDL_RenderClear(SDL_Renderer* renderer) {
    if (!renderer) return false;
    if (capture_enabled()) {
        g_cur.clear();
        cap('C', renderer, 0, 0, (float)g_win_w, (float)g_win_h);
    }
    return true;
}

// Presenting ends a frame: it becomes "the screen" until the next present.
bool SDL_RenderPresent(SDL_Renderer* renderer) {
    if (!renderer) return false;
    if (capture_enabled()) {
        g_cur.w = g_win_w;
        g_cur.h = g_win_h;
        g_cur.n = ++g_frame_no;
        std::swap(g_last, g_cur);
        g_cur.clear();
    }
    return true;
}

bool SDL_RenderFillRect(SDL_Renderer* renderer, const SDL_FRect* rc) {
    if (!renderer) return false;
    if (rc) cap('F', renderer, rc->x, rc->y, rc->w, rc->h);
    else cap('F', renderer, 0, 0, (float)g_win_w, (float)g_win_h);
    return true;
}

bool SDL_RenderRect(SDL_Renderer* renderer, const SDL_FRect* rc) {
    if (!renderer) return false;
    if (rc) cap('R', renderer, rc->x, rc->y, rc->w, rc->h);
    return true;
}

bool SDL_RenderLine(SDL_Renderer* renderer, float x1, float y1, float x2, float y2) {
    if (!renderer) return false;
    cap('L', renderer, x1, y1, x2, y2);
    return true;
}

bool SDL_RenderPoint(SDL_Renderer* renderer, float x, float y) {
    if (!renderer) return false;
    cap('P', renderer, x, y, 0, 0);
    return true;
}

bool SDL_RenderTexture(SDL_Renderer* renderer, SDL_Texture* tex, const SDL_FRect*, const SDL_FRect* dst) {
    if (!renderer) return false;
    if (capture_enabled() && tex && tex->is_text && dst) {
        g_cur.texts.push_back({tex->text, tex->family, tex->ptsize, tex->style});
        g_cur.ops.push_back({'T', dst->x + renderer->vx, dst->y + renderer->vy, dst->w, dst->h,
                             tex->color.r, tex->color.g, tex->color.b, tex->color.a,
                             (int)g_cur.texts.size() - 1});
    }
    return true;
}

bool SDL_SetRenderClipRect(SDL_Renderer* renderer, const SDL_Rect* rc) {
    if (!renderer) return false;
    if (rc) cap('K', renderer, (float)rc->x, (float)rc->y, (float)rc->w, (float)rc->h);
    else cap('k', renderer, 0, 0, 0, 0);
    return true;
}

bool SDL_SetRenderViewport(SDL_Renderer* renderer, const SDL_Rect* rc) {
    if (!renderer) return false;
    renderer->vx = rc ? rc->x : 0;
    renderer->vy = rc ? rc->y : 0;
    return true;
}

// ── Textures / surfaces ──────────────────────────────────────────────────
SDL_Texture* SDL_CreateTextureFromSurface(SDL_Renderer* renderer, SDL_Surface* surface) {
    (void)renderer;
    auto* t = new SDL_Texture();
    if (surface) {
        t->w = surface->w; t->h = surface->h;
        auto it = g_surface_text.find(surface);
        if (it != g_surface_text.end()) {
            t->is_text = true;
            t->text = it->second.text;
            t->family = it->second.family;
            t->ptsize = it->second.size;
            t->style = it->second.style;
            t->color = g_surface_color[surface];
        }
    }
    return t;
}

void SDL_DestroyTexture(SDL_Texture* texture) {
    delete texture;
}

bool SDL_SetTextureBlendMode(SDL_Texture* texture, SDL_BlendMode) {
    return texture != nullptr;
}

void SDL_DestroySurface(SDL_Surface* surface) {
    if (!surface) return;
    g_surface_text.erase(surface);
    g_surface_color.erase(surface);
    free(surface->pixels);
    delete surface;
}

// ── Keyboard ───────────────────────────────────────────────────────────
// Modifier state belongs to whichever scripted event was delivered last,
// exactly as SDL_GetModState() reflects the keyboard at the time the caller
// is processing an event.
static SDL_Keymod g_mods = SDL_KMOD_NONE;

SDL_Keymod SDL_GetModState(void) {
    return g_mods;
}

// Named keys use the same keycodes and SDL_GetKeyName() spellings real SDL3
// does, so src/builtins/gui.cpp's lowercase/normalise step is exercised on
// the same strings it sees in production ("Return" -> "enter", ...).
struct KeyDef { const char* token; const char* sdl_name; SDL_Keycode code; };
static const KeyDef kKeys[] = {
    {"enter", "Return", 13}, {"return", "Return", 13},
    {"escape", "Escape", 27}, {"esc", "Escape", 27},
    {"backspace", "Backspace", 8}, {"tab", "Tab", 9}, {"space", "Space", 32},
    {"delete", "Delete", 127}, {"del", "Delete", 127},
    {"up", "Up", 0x40000052}, {"down", "Down", 0x40000051},
    {"left", "Left", 0x40000050}, {"right", "Right", 0x4000004F},
    {"home", "Home", 0x4000004A}, {"end", "End", 0x4000004D},
    {"pageup", "PageUp", 0x4000004B}, {"pagedown", "PageDown", 0x4000004E},
    {"insert", "Insert", 0x40000049},
    {"f1", "F1", 0x4000003A}, {"f2", "F2", 0x4000003B}, {"f3", "F3", 0x4000003C},
    {"f4", "F4", 0x4000003D}, {"f5", "F5", 0x4000003E}, {"f6", "F6", 0x4000003F},
    {"f7", "F7", 0x40000040}, {"f8", "F8", 0x40000041}, {"f9", "F9", 0x40000042},
    {"f10", "F10", 0x40000043}, {"f11", "F11", 0x40000044}, {"f12", "F12", 0x40000045},
};

const char* SDL_GetKeyName(SDL_Keycode key) {
    static thread_local std::string name;
    for (const KeyDef& k : kKeys) {
        if (k.code == key) { name = k.sdl_name; return name.c_str(); }
    }
    if (key >= 'a' && key <= 'z') { name = std::string(1, (char)(key - 'a' + 'A')); return name.c_str(); }
    if (key > 32 && key < 127) { name = std::string(1, (char)key); return name.c_str(); }
    name = "Unknown";
    return name.c_str();
}

// ── Clipboard (in-process) ───────────────────────────────────────────────
static std::string g_clipboard;
static bool g_has_clipboard = false;

bool SDL_SetClipboardText(const char* text) {
    g_clipboard = text ? text : "";
    g_has_clipboard = !g_clipboard.empty();
    return true;
}

char* SDL_GetClipboardText(void) {
    char* out = (char*)malloc(g_clipboard.size() + 1);
    if (!out) return nullptr;
    memcpy(out, g_clipboard.c_str(), g_clipboard.size() + 1);
    return out;
}

bool SDL_HasClipboardText(void) { return g_has_clipboard; }

void SDL_free(void* mem) { free(mem); }

// ── Scripted input ─────────────────────────────────────────────────────
// NY_STUB_EVENTS=<file>, one command per line (blank lines and #comments
// ignored). Coordinates are window pixels; [mods] is e.g. ctrl, alt,
// ctrl+shift. Every command is delivered as its own poll batch, followed by
// NY_STUB_EVENT_GAP idle polls, so the application draws frames between
// inputs the way it would for a person — immediate-mode widgets hit-test
// while drawing, so a press and release in one batch would never register.
//
//   move X Y                 pointer motion
//   down X Y [BTN] [mods]    button press   (BTN 1 left, 2 middle, 3 right)
//   up   X Y [BTN] [mods]    button release
//   click X Y [BTN] [mods]   press, idle frames, release
//   dblclick X Y             two clicks in quick succession
//   drag X1 Y1 X2 Y2         press, move in steps, release
//   wheel X Y DY             wheel at X,Y (DY > 0 scrolls up)
//   key COMBO                key down/up, e.g. key ctrl+shift+p, key f5, key ctrl++
//   type TEXT                per character: key down + text input + key up.
//                            \n = Enter, \t = Tab, \\ = backslash
//   text TEXT                raw text-input event only (IME / paste style)
//   resize W H               window resized
//   wait N                   N idle polls
//   snap PATH                write the last presented frame to PATH
//   quit                     deliver SDL_EVENT_QUIT
struct PendingEvent {
    SDL_Event ev;
    SDL_Keymod mods;
    bool batch_end;       // end the poll batch after this event
    long wait_after;      // idle polls after the batch ends
};
static std::deque<PendingEvent> g_pending;
static std::deque<std::string> g_text_store;   // keeps SDL_TextInputEvent::text alive
static long g_wait = 0;
static bool g_batch_break = false;
static FILE* g_script = nullptr;
static bool g_script_checked = false;
static std::string g_partial;
static float g_mouse_x = 0.0f, g_mouse_y = 0.0f;

static long event_gap() {
    static long cached = -2;
    if (cached == -2) {
        const char* s = getenv("NY_STUB_EVENT_GAP");
        cached = (s && *s) ? atol(s) : 2;
        if (cached < 0) cached = 0;
    }
    return cached;
}

static void snap_on_exit() {
    const char* p = getenv("NY_STUB_SNAP_ON_EXIT");
    if (p && *p) write_frame(g_last, p);
}

// Reads one complete line. The file may still be being appended to by a
// driver, so a line without its newline yet is held back until it arrives.
static bool read_command(std::string& line) {
    if (!g_script_checked) {
        g_script_checked = true;
        const char* p = getenv("NY_STUB_EVENTS");
        if (p && *p) {
            g_script = fopen(p, "r");
            if (!g_script) fprintf(stderr, "[SDL3-stub] cannot open NY_STUB_EVENTS=%s\n", p);
        }
    }
    if (!g_script) return false;
    char buf[8192];
    while (fgets(buf, sizeof(buf), g_script)) {
        g_partial += buf;
        if (!g_partial.empty() && g_partial.back() == '\n') {
            line = g_partial;
            g_partial.clear();
            while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
            return true;
        }
    }
    clearerr(g_script);
    return false;
}

static SDL_Keymod parse_mods(const std::string& spec) {
    SDL_Keymod m = SDL_KMOD_NONE;
    size_t i = 0;
    while (i <= spec.size()) {
        size_t j = spec.find('+', i);
        if (j == std::string::npos) j = spec.size();
        std::string t = spec.substr(i, j - i);
        for (auto& c : t) c = (char)tolower((unsigned char)c);
        if (t == "ctrl" || t == "control") m |= SDL_KMOD_LCTRL;
        else if (t == "shift") m |= SDL_KMOD_LSHIFT;
        else if (t == "alt" || t == "option") m |= SDL_KMOD_LALT;
        else if (t == "super" || t == "gui" || t == "cmd" || t == "meta") m |= SDL_KMOD_GUI;
        i = j + 1;
    }
    return m;
}

// "ctrl+shift+p" -> mods + keycode. A trailing "++" means the '+' key.
static bool parse_combo(const std::string& combo, SDL_Keymod& mods, SDL_Keycode& code) {
    std::string keypart, modpart;
    if (combo.size() >= 2 && combo.substr(combo.size() - 2) == "++") {
        keypart = "+";
        modpart = combo.substr(0, combo.size() - 2);
    } else if (combo == "+") {
        keypart = "+";
    } else {
        size_t k = combo.rfind('+');
        if (k == std::string::npos) keypart = combo;
        else { keypart = combo.substr(k + 1); modpart = combo.substr(0, k); }
    }
    mods = parse_mods(modpart);
    std::string low = keypart;
    for (auto& c : low) c = (char)tolower((unsigned char)c);
    for (const KeyDef& k : kKeys) {
        if (low == k.token) { code = k.code; return true; }
    }
    if (keypart.size() == 1) {
        unsigned char c = (unsigned char)keypart[0];
        if (c >= 'A' && c <= 'Z') { mods |= SDL_KMOD_LSHIFT; c = (unsigned char)(c - 'A' + 'a'); }
        code = (SDL_Keycode)c;
        return true;
    }
    return false;
}

static PendingEvent blank_event(Uint32 type, SDL_Keymod mods) {
    PendingEvent pe;
    memset(&pe.ev, 0, sizeof(SDL_Event));
    pe.ev.type = type;
    pe.mods = mods;
    pe.batch_end = true;
    pe.wait_after = event_gap();
    return pe;
}

static void push_mouse(Uint32 type, float x, float y, int btn, SDL_Keymod mods, long wait) {
    PendingEvent pe = blank_event(type, mods);
    if (type == SDL_EVENT_MOUSE_MOTION) {
        pe.ev.motion.x = x; pe.ev.motion.y = y;
    } else {
        pe.ev.button.x = x; pe.ev.button.y = y;
        pe.ev.button.button = (Uint8)btn;
        pe.ev.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
        pe.ev.button.clicks = 1;
    }
    pe.wait_after = wait;
    g_pending.push_back(pe);
}

static void push_key(SDL_Keycode code, SDL_Keymod mods, const std::string* text, bool last) {
    PendingEvent d = blank_event(SDL_EVENT_KEY_DOWN, mods);
    d.ev.key.key = code; d.ev.key.mod = mods; d.ev.key.down = true;
    d.batch_end = false;
    g_pending.push_back(d);
    if (text) {
        PendingEvent t = blank_event(SDL_EVENT_TEXT_INPUT, mods);
        g_text_store.push_back(*text);
        if (g_text_store.size() > 256) g_text_store.pop_front();
        t.ev.text.text = g_text_store.back().c_str();
        t.batch_end = false;
        g_pending.push_back(t);
    }
    PendingEvent u = blank_event(SDL_EVENT_KEY_UP, mods);
    u.ev.key.key = code; u.ev.key.mod = mods; u.ev.key.down = false;
    u.wait_after = last ? event_gap() : 0;
    g_pending.push_back(u);
}

static std::vector<std::string> split_ws(const std::string& s) {
    std::vector<std::string> out;
    size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && isspace((unsigned char)s[i])) i++;
        size_t j = i;
        while (j < s.size() && !isspace((unsigned char)s[j])) j++;
        if (j > i) out.push_back(s.substr(i, j - i));
        i = j;
    }
    return out;
}

// Expands one script line into pending events (or performs it directly).
static void exec_command(const std::string& raw) {
    std::string line = raw;
    size_t first = line.find_first_not_of(" \t");
    if (first == std::string::npos) return;
    line = line.substr(first);
    if (line[0] == '#') return;
    std::vector<std::string> a = split_ws(line);
    if (a.empty()) return;
    const std::string& cmd = a[0];
    auto num = [&](size_t i, float def) -> float { return i < a.size() ? (float)atof(a[i].c_str()) : def; };
    // Optional trailing "[BTN] [mods]" after X Y.
    auto btn_mods = [&](size_t from, int& btn, SDL_Keymod& mods) {
        btn = 1; mods = SDL_KMOD_NONE;
        for (size_t i = from; i < a.size(); i++) {
            if (isdigit((unsigned char)a[i][0])) btn = atoi(a[i].c_str());
            else mods = parse_mods(a[i]);
        }
    };
    long gap = event_gap();

    if (cmd == "wait") { g_wait += (long)num(1, 1); return; }
    if (cmd == "snap") {
        if (a.size() >= 2) {
            std::string path = line.substr(line.find(a[1]));
            if (!write_frame(g_last, path)) fprintf(stderr, "[SDL3-stub] snap: cannot write %s\n", path.c_str());
        }
        return;
    }
    if (cmd == "quit") {
        PendingEvent q = blank_event(SDL_EVENT_QUIT, SDL_KMOD_NONE);
        g_pending.push_back(q);
        return;
    }
    if (cmd == "move") {
        g_mouse_x = num(1, 0); g_mouse_y = num(2, 0);
        push_mouse(SDL_EVENT_MOUSE_MOTION, g_mouse_x, g_mouse_y, 0, SDL_KMOD_NONE, gap);
        return;
    }
    if (cmd == "down" || cmd == "up" || cmd == "click" || cmd == "dblclick") {
        float x = num(1, g_mouse_x), y = num(2, g_mouse_y);
        int btn; SDL_Keymod mods;
        btn_mods(3, btn, mods);
        g_mouse_x = x; g_mouse_y = y;
        if (cmd == "down") { push_mouse(SDL_EVENT_MOUSE_BUTTON_DOWN, x, y, btn, mods, gap); return; }
        if (cmd == "up")   { push_mouse(SDL_EVENT_MOUSE_BUTTON_UP, x, y, btn, mods, gap); return; }
        push_mouse(SDL_EVENT_MOUSE_MOTION, x, y, 0, SDL_KMOD_NONE, 1);
        int reps = (cmd == "dblclick") ? 2 : 1;
        for (int r = 0; r < reps; r++) {
            push_mouse(SDL_EVENT_MOUSE_BUTTON_DOWN, x, y, btn, mods, 1);
            g_pending.back().ev.button.clicks = (Uint8)(r + 1);
            push_mouse(SDL_EVENT_MOUSE_BUTTON_UP, x, y, btn, mods, r + 1 < reps ? 1 : gap);
            g_pending.back().ev.button.clicks = (Uint8)(r + 1);
        }
        return;
    }
    if (cmd == "drag") {
        float x1 = num(1, 0), y1 = num(2, 0), x2 = num(3, 0), y2 = num(4, 0);
        push_mouse(SDL_EVENT_MOUSE_MOTION, x1, y1, 0, SDL_KMOD_NONE, 1);
        push_mouse(SDL_EVENT_MOUSE_BUTTON_DOWN, x1, y1, 1, SDL_KMOD_NONE, 1);
        for (int i = 1; i <= 6; i++) {
            float t = (float)i / 6.0f;
            push_mouse(SDL_EVENT_MOUSE_MOTION, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 0, SDL_KMOD_NONE, 1);
        }
        push_mouse(SDL_EVENT_MOUSE_BUTTON_UP, x2, y2, 1, SDL_KMOD_NONE, gap);
        g_mouse_x = x2; g_mouse_y = y2;
        return;
    }
    if (cmd == "wheel") {
        PendingEvent w = blank_event(SDL_EVENT_MOUSE_WHEEL, SDL_KMOD_NONE);
        w.ev.wheel.mouse_x = num(1, g_mouse_x);
        w.ev.wheel.mouse_y = num(2, g_mouse_y);
        w.ev.wheel.y = num(3, 0);
        w.ev.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
        g_pending.push_back(w);
        return;
    }
    if (cmd == "resize") {
        PendingEvent r = blank_event(SDL_EVENT_WINDOW_RESIZED, SDL_KMOD_NONE);
        r.ev.window.data1 = (Sint32)num(1, 800);
        r.ev.window.data2 = (Sint32)num(2, 600);
        g_win_w = r.ev.window.data1;
        g_win_h = r.ev.window.data2;
        if (g_last_window) { g_last_window->w = g_win_w; g_last_window->h = g_win_h; }
        g_pending.push_back(r);
        return;
    }
    if (cmd == "key") {
        if (a.size() < 2) return;
        SDL_Keymod mods; SDL_Keycode code;
        if (!parse_combo(a[1], mods, code)) {
            fprintf(stderr, "[SDL3-stub] unknown key: %s\n", a[1].c_str());
            return;
        }
        push_key(code, mods, nullptr, true);
        return;
    }
    if (cmd == "type" || cmd == "text") {
        size_t at = line.find(cmd) + cmd.size();
        if (at < line.size() && line[at] == ' ') at++;
        std::string body = line.substr(at);
        // Decode escapes, then split into UTF-8 code points.
        std::vector<std::string> units;
        for (size_t i = 0; i < body.size();) {
            if (body[i] == '\\' && i + 1 < body.size()) {
                char n = body[i + 1];
                units.push_back(n == 'n' ? "\n" : n == 't' ? "\t" : std::string(1, n));
                i += 2;
                continue;
            }
            unsigned char c = (unsigned char)body[i];
            size_t len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : 4;
            units.push_back(body.substr(i, len));
            i += len;
        }
        if (cmd == "text") {
            std::string all;
            for (auto& u : units) all += u;
            PendingEvent t = blank_event(SDL_EVENT_TEXT_INPUT, SDL_KMOD_NONE);
            g_text_store.push_back(all);
            t.ev.text.text = g_text_store.back().c_str();
            g_pending.push_back(t);
            return;
        }
        for (size_t i = 0; i < units.size(); i++) {
            const std::string& u = units[i];
            bool last = (i + 1 == units.size());
            if (u == "\n") { push_key(13, SDL_KMOD_NONE, nullptr, last); continue; }
            if (u == "\t") { push_key(9, SDL_KMOD_NONE, nullptr, last); continue; }
            SDL_Keycode code = 0;
            SDL_Keymod mods = SDL_KMOD_NONE;
            if (u.size() == 1) {
                unsigned char c = (unsigned char)u[0];
                if (c >= 'A' && c <= 'Z') { mods = SDL_KMOD_LSHIFT; code = c - 'A' + 'a'; }
                else code = c;
            }
            push_key(code, mods, &u, last);
        }
        return;
    }
    fprintf(stderr, "[SDL3-stub] unknown script command: %s\n", line.c_str());
}

// ── Events ───────────────────────────────────────────────────────────────
// NY_STUB_AUTOQUIT=<n>: after n consecutive empty polls, deliver ONE
// SDL_EVENT_QUIT and never again (latched), so `while (SDL_PollEvent(&e))`
// drain loops terminate instead of spinning forever headlessly.
static long autoquit_threshold() {
    static long cached = -2; // -2 = not yet read
    if (cached == -2) {
        const char* s = getenv("NY_STUB_AUTOQUIT");
        cached = (s && *s) ? atol(s) : -1; // -1 = disabled
    }
    return cached;
}

static std::atomic<long> g_empty_polls{0};
static std::atomic<bool> g_quit_delivered{false};

bool SDL_PollEvent(SDL_Event* event) {
    // One scripted command per poll batch: after its events, report "no more
    // events" once so the caller finishes the batch and draws.
    if (g_batch_break) {
        g_batch_break = false;
        return false;
    }
    if (g_wait > 0) {
        g_wait--;
        return false;
    }
    if (g_pending.empty()) {
        std::string line;
        while (g_pending.empty() && g_wait == 0 && read_command(line)) exec_command(line);
        if (g_pending.empty() && g_wait > 0) {
            g_wait--;
            return false;
        }
    }
    if (!g_pending.empty()) {
        PendingEvent pe = g_pending.front();
        g_pending.pop_front();
        if (event) *event = pe.ev;
        g_mods = pe.mods;
        if (pe.ev.type == SDL_EVENT_MOUSE_MOTION) { g_mouse_x = pe.ev.motion.x; g_mouse_y = pe.ev.motion.y; }
        if (pe.batch_end) {
            g_batch_break = true;
            g_wait = pe.wait_after;
        }
        g_empty_polls.store(0);
        if (pe.ev.type == SDL_EVENT_QUIT) {
            g_quit_delivered.store(true);
            snap_on_exit();
        }
        return true;
    }

    long threshold = autoquit_threshold();
    if (threshold >= 0 && !g_quit_delivered.load()) {
        long n = ++g_empty_polls;
        if (n >= threshold) {
            g_quit_delivered.store(true);
            snap_on_exit();
            if (event) {
                memset(event, 0, sizeof(SDL_Event));
                event->type = SDL_EVENT_QUIT;
            }
            return true;
        }
    }
    return false; // no events pending
}

// ── SDL3_ttf ───────────────────────────────────────────────────────────
// Advance widths of printable ASCII (32..126) in 1/1000 em, measured from
// DejaVu Sans / DejaVu Sans Bold / DejaVu Sans Mono - the fonts
// src/builtins/gui.cpp loads on Linux. With these the stub measures text the
// way the real SDL_ttf would, so a headless screenshot's layout (tab widths,
// right-aligned labels, caret positions) matches a real run instead of a
// flat 0.6 em per character.
static const short kAdvSans[95] = {
    318, 401, 460, 838, 636, 950, 780, 275, 390, 390, 500, 838, 318, 361, 318, 337,
    636, 636, 636, 636, 636, 636, 636, 636, 636, 636, 337, 337, 838, 838, 838, 531,
    1000, 684, 686, 698, 770, 632, 575, 775, 752, 295, 295, 656, 557, 863, 748, 787,
    603, 787, 695, 635, 611, 732, 684, 989, 685, 611, 685, 390, 337, 390, 838, 500,
    500, 613, 635, 550, 635, 615, 352, 635, 634, 278, 278, 579, 278, 974, 634, 612,
    635, 635, 411, 521, 392, 634, 592, 818, 592, 592, 525, 636, 337, 636, 838,
};
static const short kAdvBold[95] = {
    348, 456, 521, 838, 696, 1002, 872, 306, 457, 457, 523, 838, 380, 415, 380, 365,
    696, 696, 696, 696, 696, 696, 696, 696, 696, 696, 400, 400, 838, 838, 838, 580,
    1000, 774, 762, 734, 830, 683, 683, 821, 837, 372, 372, 775, 637, 995, 837, 850,
    733, 850, 770, 720, 682, 812, 774, 1103, 771, 724, 725, 457, 365, 457, 838, 500,
    500, 675, 716, 593, 716, 678, 435, 716, 712, 343, 343, 665, 343, 1042, 712, 687,
    716, 716, 493, 595, 478, 712, 652, 924, 645, 652, 582, 712, 365, 712, 838,
};
static const short kAdvMono[95] = {
    602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602,
    602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602,
    602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602,
    602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602,
    602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602,
    602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602, 602,
};

static bool icontains(const std::string& hay, const char* needle) {
    std::string h = hay, n = needle;
    for (auto& c : h) c = (char)tolower((unsigned char)c);
    return h.find(n) != std::string::npos;
}

// Pixel width of a UTF-8 run in `font`. Non-ASCII code points count as one
// glyph each (an icon font's glyphs are square, one em).
static int stub_text_width(TTF_Font* font, const char* text, size_t len) {
    float size = font ? font->ptsize : 16.0f;
    const std::string path = font ? font->path : std::string();
    bool icon = icontains(path, "codicon");
    bool mono = !icon && (icontains(path, "mono") || icontains(path, "consol") || icontains(path, "cour"));
    bool bold = font && (font->style & TTF_STYLE_BOLD);
    const short* tab = mono ? kAdvMono : (bold ? kAdvBold : kAdvSans);
    long total = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c >= 32 && c < 127) total += tab[c - 32];
        else if (c >= 0xC0) total += icon ? 1000 : (mono ? 602 : 620);
        // continuation bytes and control characters add nothing
    }
    return (int)(total * size / 1000.0f + 0.5f);
}

static int stub_text_height(TTF_Font* font) {
    float size = font ? font->ptsize : 16.0f;
    return (int)(size * 1.17f + 0.5f);
}

bool TTF_Init(void) { return true; }
void TTF_Quit(void) {}

TTF_Font* TTF_OpenFont(const char* file, float ptsize) {
    (void)file;
    auto* f = new TTF_Font();
    f->ptsize = ptsize > 0 ? ptsize : 16.0f;
    f->path = file ? file : "";
    return f;
}

void TTF_CloseFont(TTF_Font* font) {
    delete font;
}

void TTF_SetFontStyle(TTF_Font* font, TTF_FontStyleFlags style) {
    if (font) font->style = style;
}

TTF_FontStyleFlags TTF_GetFontStyle(TTF_Font* font) {
    return font ? font->style : TTF_STYLE_NORMAL;
}

SDL_Surface* TTF_RenderText_Blended(TTF_Font* font, const char* text, size_t text_len,
                                     SDL_Color fg) {
    size_t len = text_len ? text_len : (text ? strlen(text) : 0);
    auto* surf = new SDL_Surface();
    surf->w = text ? stub_text_width(font, text, len) : 1;
    surf->h = stub_text_height(font);
    if (surf->w < 1) surf->w = 1;
    size_t bytes = (size_t)surf->w * (size_t)surf->h * 4;
    surf->pixels = bytes ? calloc(1, bytes) : nullptr;
    if (capture_enabled() && font) {
        g_surface_text[surf] = {std::string(text ? text : "", len), font->path, font->ptsize, (int)font->style};
        g_surface_color[surf] = fg;
    }
    return surf;
}

bool TTF_GetStringSize(TTF_Font* font, const char* text, size_t text_len,
                        int* w, int* h) {
    size_t len = text_len ? text_len : (text ? strlen(text) : 0);
    if (w) *w = text ? stub_text_width(font, text, len) : 0;
    if (h) *h = stub_text_height(font);
    return true;
}

// ── SDL3_image ────────────────────────────────────────────────────────
SDL_Surface* IMG_Load(const char* file) {
    (void)file;
    // No real decoder available headlessly: report failure the same way the
    // real library does for an unreadable/unsupported file, rather than
    // fabricating pixel data callers might mistake for a real image.
    g_last_error = "IMG_Load: image loading unavailable in headless SDL3 stub";
    return nullptr;
}
