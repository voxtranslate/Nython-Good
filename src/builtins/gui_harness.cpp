// src/builtins/gui_harness.cpp - see include/builtins/gui_harness.hpp.
//
// Only compiled into real-SDL3 builds: the headless stub
// (thirdparty/sdl3-stub, NYTHON_SDL_STUB) implements the same harness
// inside its fake SDL. The command set, batching and display-list format
// match the stub's exactly, so tools/ide_driver.py and tools/ide_e2e.py
// run unchanged against either.
#ifndef NYTHON_SDL_STUB

#define NYH_IMPLEMENTATION
#include "builtins/gui_harness.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace nyh {

// ── Configuration ────────────────────────────────────────────────────────
static const char* env(const char* a, const char* b = nullptr) {
    const char* v = getenv(a);
    if ((!v || !*v) && b) v = getenv(b);
    return (v && *v) ? v : nullptr;
}
static const char* script_path() { return env("NY_STUB_EVENTS", "NY_TEST_EVENTS"); }
static bool capture_on() {
    static int c = -1;
    if (c < 0) c = (script_path() || env("NY_STUB_SNAP_ON_EXIT")) ? 1 : 0;
    return c == 1;
}
static bool scripted() {
    static int c = -1;
    if (c < 0) c = script_path() ? 1 : 0;
    return c == 1;
}
static bool real_pixels() {
    static int c = -1;
    if (c < 0) { const char* v = env("NY_REAL_PIXELS"); c = (v && v[0] != '0') ? 1 : 0; }
    return c == 1;
}
bool active() { return capture_on(); }

// ── Capture (same structures and JSON as the stub) ──────────────────────
struct CapOp { char kind; float a, b, c, d; Uint8 r, g, bl, al; int str; };
struct CapText { std::string text, family; float size; int style; };
struct CapFrame {
    int w = 0, h = 0; long n = 0; float density = 1.0f, scale = 1.0f;
    std::vector<CapOp> ops; std::vector<CapText> texts;
    void clear() { ops.clear(); texts.clear(); }
};
struct RState { Uint8 r = 0, g = 0, b = 0, a = 255; int vx = 0, vy = 0; SDL_Window* win = nullptr; };
struct FontInfo { std::string path; float size = 16.0f; int style = 0; };
struct TexText { CapText t; SDL_Color c; };

static CapFrame g_cur, g_last;
static long g_frame_no = 0;
static std::unordered_map<SDL_Renderer*, RState> g_rs;
static std::unordered_map<TTF_Font*, FontInfo> g_fonts;
static std::unordered_map<SDL_Surface*, TexText> g_surf_text;
static std::unordered_map<SDL_Texture*, TexText> g_tex_text;
static std::vector<SDL_Window*> g_windows;           // creation order
static SDL_Surface* g_last_pixels = nullptr;          // NY_REAL_PIXELS

static RState& rs(SDL_Renderer* r) { return g_rs[r]; }

static void cap(char kind, SDL_Renderer* r, float a, float b, float c, float d) {
    if (!capture_on() || !r) return;
    RState& s = rs(r);
    g_cur.ops.push_back({kind, a + s.vx, b + s.vy, c, d, s.r, s.g, s.b, s.a, -1});
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

static bool write_frame(const CapFrame& fr, const std::string& path) {
    std::string tmp = path + ".tmp";
    FILE* f = fopen(tmp.c_str(), "w");
    if (!f) return false;
    fprintf(f, "{\"op\":\"frame\",\"w\":%d,\"h\":%d,\"n\":%ld,\"density\":%g,\"scale\":%g,\"backend\":\"sdl3\"}\n",
            fr.w, fr.h, fr.n, fr.density, fr.scale);
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

// A snapshot is the display list; with real pixels read back it is also a
// PNG of what SDL actually rendered, next to it. The PNG is written (to a
// temporary name, then renamed) BEFORE the display list, because a driver
// takes the display list's appearance to mean the snapshot is complete - the
// other order let it read a half-written PNG.
static void write_snap(const std::string& path) {
    if (g_last_pixels) {
        std::string png = path + ".png", tmp = png + ".tmp.png";
        if (!IMG_SavePNG(g_last_pixels, tmp.c_str()) || rename(tmp.c_str(), png.c_str()) != 0)
            fprintf(stderr, "[nyh] snap: cannot write %s: %s\n", png.c_str(), SDL_GetError());
    }
    if (!write_frame(g_last, path)) fprintf(stderr, "[nyh] snap: cannot write %s\n", path.c_str());
}

// ── Render wrappers ─────────────────────────────────────────────────────
bool SetRenderDrawColor(SDL_Renderer* r, Uint8 cr, Uint8 cg, Uint8 cb, Uint8 ca) {
    if (capture_on() && r) { RState& s = rs(r); s.r = cr; s.g = cg; s.b = cb; s.a = ca; }
    return ::SDL_SetRenderDrawColor(r, cr, cg, cb, ca);
}
bool SetRenderViewport(SDL_Renderer* r, const SDL_Rect* rc) {
    if (capture_on() && r) { RState& s = rs(r); s.vx = rc ? rc->x : 0; s.vy = rc ? rc->y : 0; }
    return ::SDL_SetRenderViewport(r, rc);
}
bool RenderClear(SDL_Renderer* r) {
    if (capture_on() && r) {
        int w = 0, h = 0;
        ::SDL_GetRenderOutputSize(r, &w, &h);
        g_cur.clear();
        cap('C', r, 0, 0, (float)w, (float)h);
    }
    return ::SDL_RenderClear(r);
}
bool RenderPresent(SDL_Renderer* r) {
    if (capture_on() && r) {
        int w = 0, h = 0;
        ::SDL_GetRenderOutputSize(r, &w, &h);
        SDL_Window* win = rs(r).win;
        g_cur.w = w; g_cur.h = h;
        g_cur.density = win ? ::SDL_GetWindowPixelDensity(win) : 1.0f;
        g_cur.scale = win ? ::SDL_GetWindowDisplayScale(win) : 1.0f;
        if (g_cur.density <= 0.0f) g_cur.density = 1.0f;
        if (g_cur.scale <= 0.0f) g_cur.scale = 1.0f;
        g_cur.n = ++g_frame_no;
        std::swap(g_last, g_cur);
        g_cur.clear();
        if (real_pixels()) {
            // Read back before presenting: after SDL_RenderPresent the back
            // buffer's contents are undefined.
            SDL_Surface* px = ::SDL_RenderReadPixels(r, nullptr);
            if (px) {
                if (g_last_pixels) ::SDL_DestroySurface(g_last_pixels);
                g_last_pixels = px;
            }
        }
    }
    return ::SDL_RenderPresent(r);
}
bool RenderFillRect(SDL_Renderer* r, const SDL_FRect* rc) {
    if (capture_on() && r) {
        if (rc) cap('F', r, rc->x, rc->y, rc->w, rc->h);
        else { int w = 0, h = 0; ::SDL_GetRenderOutputSize(r, &w, &h); cap('F', r, 0, 0, (float)w, (float)h); }
    }
    return ::SDL_RenderFillRect(r, rc);
}
bool RenderRect(SDL_Renderer* r, const SDL_FRect* rc) {
    if (rc) cap('R', r, rc->x, rc->y, rc->w, rc->h);
    return ::SDL_RenderRect(r, rc);
}
bool RenderLine(SDL_Renderer* r, float x1, float y1, float x2, float y2) {
    cap('L', r, x1, y1, x2, y2);
    return ::SDL_RenderLine(r, x1, y1, x2, y2);
}
bool RenderPoint(SDL_Renderer* r, float x, float y) {
    cap('P', r, x, y, 0, 0);
    return ::SDL_RenderPoint(r, x, y);
}
bool RenderTexture(SDL_Renderer* r, SDL_Texture* t, const SDL_FRect* src, const SDL_FRect* dst) {
    if (capture_on() && r && t && dst) {
        auto it = g_tex_text.find(t);
        if (it != g_tex_text.end()) {
            RState& s = rs(r);
            g_cur.texts.push_back(it->second.t);
            const SDL_Color& c = it->second.c;
            g_cur.ops.push_back({'T', dst->x + s.vx, dst->y + s.vy, dst->w, dst->h, c.r, c.g, c.b, c.a,
                                 (int)g_cur.texts.size() - 1});
        }
    }
    return ::SDL_RenderTexture(r, t, src, dst);
}
bool SetRenderClipRect(SDL_Renderer* r, const SDL_Rect* rc) {
    if (rc) cap('K', r, (float)rc->x, (float)rc->y, (float)rc->w, (float)rc->h);
    else cap('k', r, 0, 0, 0, 0);
    return ::SDL_SetRenderClipRect(r, rc);
}
// Triangles are recorded as the one-pixel horizontal spans they cover, so
// arcs and pies read as ordinary fills in the display list (as in the stub).
bool RenderGeometry(SDL_Renderer* r, SDL_Texture* t, const SDL_Vertex* v, int nv, const int* idx, int ni) {
    if (capture_on() && r && v && nv >= 3) {
        RState& s = rs(r);
        Uint8 sr = s.r, sg = s.g, sb = s.b, sa = s.a;
        s.r = (Uint8)std::lround(v[0].color.r * 255.0f);
        s.g = (Uint8)std::lround(v[0].color.g * 255.0f);
        s.b = (Uint8)std::lround(v[0].color.b * 255.0f);
        s.a = (Uint8)std::lround(v[0].color.a * 255.0f);
        int count = idx ? ni : nv;
        for (int tri = 0; tri + 2 < count; tri += 3) {
            const SDL_FPoint* p[3];
            for (int k = 0; k < 3; k++) p[k] = &v[idx ? idx[tri + k] : tri + k].position;
            float y0 = std::min({p[0]->y, p[1]->y, p[2]->y});
            float y1 = std::max({p[0]->y, p[1]->y, p[2]->y});
            for (int y = (int)std::floor(y0); y <= (int)std::ceil(y1); y++) {
                float sy = (float)y + 0.5f, lo = 1e30f, hi = -1e30f;
                for (int e = 0; e < 3; e++) {
                    const SDL_FPoint* a = p[e];
                    const SDL_FPoint* b = p[(e + 1) % 3];
                    if ((a->y <= sy && sy < b->y) || (b->y <= sy && sy < a->y)) {
                        float x = a->x + (b->x - a->x) * (sy - a->y) / (b->y - a->y);
                        lo = std::min(lo, x);
                        hi = std::max(hi, x);
                    }
                }
                float xa = std::round(lo), xb = std::round(hi);
                if (xb > xa) cap('F', r, xa, (float)y, xb - xa, 1.0f);
            }
        }
        s.r = sr; s.g = sg; s.b = sb; s.a = sa;
    }
    return ::SDL_RenderGeometry(r, t, v, nv, idx, ni);
}

SDL_Renderer* CreateRenderer(SDL_Window* w, const char* name) {
    SDL_Renderer* r = ::SDL_CreateRenderer(w, name);
    if (r) rs(r).win = w;
    return r;
}
void DestroyRenderer(SDL_Renderer* r) {
    g_rs.erase(r);
    ::SDL_DestroyRenderer(r);
}
SDL_Window* CreateWindow(const char* title, int w, int h, SDL_WindowFlags flags) {
    SDL_Window* win = ::SDL_CreateWindow(title, w, h, flags);
    if (win) g_windows.push_back(win);
    return win;
}
void DestroyWindow(SDL_Window* w) {
    g_windows.erase(std::remove(g_windows.begin(), g_windows.end(), w), g_windows.end());
    ::SDL_DestroyWindow(w);
}

// ── Text: remember which run each surface / texture holds ───────────────
TTF_Font* OpenFont(const char* file, float ptsize) {
    TTF_Font* f = ::TTF_OpenFont(file, ptsize);
    if (f && capture_on()) g_fonts[f] = {file ? file : "", ptsize, 0};
    return f;
}
void SetFontStyle(TTF_Font* f, TTF_FontStyleFlags style) {
    if (f && capture_on()) g_fonts[f].style = (int)style;
    ::TTF_SetFontStyle(f, style);
}
SDL_Surface* RenderText_Blended(TTF_Font* f, const char* text, size_t len, SDL_Color fg) {
    SDL_Surface* s = ::TTF_RenderText_Blended(f, text, len, fg);
    if (s && capture_on() && f) {
        size_t n = len ? len : (text ? strlen(text) : 0);
        const FontInfo& fi = g_fonts[f];
        g_surf_text[s] = {{std::string(text ? text : "", n), fi.path, fi.size, fi.style}, fg};
    }
    return s;
}
SDL_Texture* CreateTextureFromSurface(SDL_Renderer* r, SDL_Surface* s) {
    SDL_Texture* t = ::SDL_CreateTextureFromSurface(r, s);
    if (t && capture_on()) {
        auto it = g_surf_text.find(s);
        if (it != g_surf_text.end()) g_tex_text[t] = it->second;
    }
    return t;
}
void DestroyTexture(SDL_Texture* t) {
    g_tex_text.erase(t);
    ::SDL_DestroyTexture(t);
}
void DestroySurface(SDL_Surface* s) {
    g_surf_text.erase(s);
    ::SDL_DestroySurface(s);
}

// ── Scripted input (the stub's command set) ─────────────────────────────
struct KeyDef { const char* token; SDL_Keycode code; };
static const KeyDef kKeys[] = {
    {"enter", SDLK_RETURN}, {"return", SDLK_RETURN}, {"escape", SDLK_ESCAPE}, {"esc", SDLK_ESCAPE},
    {"backspace", SDLK_BACKSPACE}, {"tab", SDLK_TAB}, {"space", SDLK_SPACE},
    {"delete", SDLK_DELETE}, {"del", SDLK_DELETE},
    {"up", SDLK_UP}, {"down", SDLK_DOWN}, {"left", SDLK_LEFT}, {"right", SDLK_RIGHT},
    {"home", SDLK_HOME}, {"end", SDLK_END}, {"pageup", SDLK_PAGEUP}, {"pagedown", SDLK_PAGEDOWN},
    {"insert", SDLK_INSERT},
    {"f1", SDLK_F1}, {"f2", SDLK_F2}, {"f3", SDLK_F3}, {"f4", SDLK_F4}, {"f5", SDLK_F5},
    {"f6", SDLK_F6}, {"f7", SDLK_F7}, {"f8", SDLK_F8}, {"f9", SDLK_F9}, {"f10", SDLK_F10},
    {"f11", SDLK_F11}, {"f12", SDLK_F12}, {"kp_enter", SDLK_KP_ENTER},
};

struct Pending { SDL_Event ev; SDL_Keymod mods; bool batch_end; long wait_after; };
static std::deque<Pending> g_pending;
static std::deque<std::string> g_text_store;
static long g_wait = 0;
static bool g_batch_break = false;
static FILE* g_script = nullptr;
static bool g_script_checked = false;
static std::string g_partial;
static float g_mouse_x = 0, g_mouse_y = 0;
static SDL_Keymod g_mods = SDL_KMOD_NONE;
static SDL_Window* g_target = nullptr;
static std::string g_clipboard;
static SDL_DialogFileCallback g_dialog_cb = nullptr;
static void* g_dialog_ud = nullptr;
static std::atomic<long> g_empty_polls{0};
static std::atomic<bool> g_quit_delivered{false};

static long event_gap() {
    static long c = -2;
    if (c == -2) { const char* s = env("NY_STUB_EVENT_GAP"); c = s ? atol(s) : 2; if (c < 0) c = 0; }
    return c;
}
static long autoquit() {
    static long c = -2;
    if (c == -2) { const char* s = env("NY_STUB_AUTOQUIT"); c = s ? atol(s) : -1; }
    return c;
}
static void snap_on_exit() {
    const char* p = env("NY_STUB_SNAP_ON_EXIT");
    if (p) write_snap(p);
}

static bool read_command(std::string& line) {
    if (!g_script_checked) {
        g_script_checked = true;
        const char* p = script_path();
        if (p) { g_script = fopen(p, "r"); if (!g_script) fprintf(stderr, "[nyh] cannot open %s\n", p); }
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
        else if (t == "super" || t == "gui" || t == "cmd" || t == "meta") m |= SDL_KMOD_LGUI;
        i = j + 1;
    }
    return m;
}
static bool parse_combo(const std::string& combo, SDL_Keymod& mods, SDL_Keycode& code) {
    std::string keypart, modpart;
    if (combo.size() >= 2 && combo.substr(combo.size() - 2) == "++") { keypart = "+"; modpart = combo.substr(0, combo.size() - 2); }
    else if (combo == "+") keypart = "+";
    else {
        size_t k = combo.rfind('+');
        if (k == std::string::npos) keypart = combo;
        else { keypart = combo.substr(k + 1); modpart = combo.substr(0, k); }
    }
    mods = parse_mods(modpart);
    std::string low = keypart;
    for (auto& c : low) c = (char)tolower((unsigned char)c);
    for (const KeyDef& k : kKeys) if (low == k.token) { code = k.code; return true; }
    if (keypart.size() == 1) {
        unsigned char c = (unsigned char)keypart[0];
        if (c >= 'A' && c <= 'Z') { mods |= SDL_KMOD_LSHIFT; c = (unsigned char)(c - 'A' + 'a'); }
        code = (SDL_Keycode)c;
        return true;
    }
    return false;
}

static SDL_Window* target_window() {
    if (g_target && std::find(g_windows.begin(), g_windows.end(), g_target) != g_windows.end()) return g_target;
    return g_windows.empty() ? nullptr : g_windows.back();
}
static Pending blank(Uint32 type, SDL_Keymod mods) {
    Pending p;
    memset(&p.ev, 0, sizeof(SDL_Event));
    p.ev.type = type;
    p.ev.common.timestamp = SDL_GetTicksNS();
    SDL_Window* w = target_window();
    p.ev.window.windowID = w ? ::SDL_GetWindowID(w) : 0;
    p.mods = mods;
    p.batch_end = true;
    p.wait_after = event_gap();
    return p;
}
static void push_mouse(Uint32 type, float x, float y, int btn, SDL_Keymod mods, long wait) {
    Pending p = blank(type, mods);
    if (type == SDL_EVENT_MOUSE_MOTION) { p.ev.motion.x = x; p.ev.motion.y = y; }
    else {
        p.ev.button.x = x; p.ev.button.y = y;
        p.ev.button.button = (Uint8)btn;
        p.ev.button.down = (type == SDL_EVENT_MOUSE_BUTTON_DOWN);
        p.ev.button.clicks = 1;
    }
    p.wait_after = wait;
    g_pending.push_back(p);
}
static const char* keep(const std::string& s) {
    g_text_store.push_back(s);
    if (g_text_store.size() > 256) g_text_store.pop_front();
    return g_text_store.back().c_str();
}
static void push_key(SDL_Keycode code, SDL_Keymod mods, const std::string* text, bool last, int repeats = 0) {
    Pending d = blank(SDL_EVENT_KEY_DOWN, mods);
    d.ev.key.key = code; d.ev.key.mod = mods; d.ev.key.down = true;
    d.ev.key.scancode = ::SDL_GetScancodeFromKey(code, nullptr);
    d.batch_end = false;
    g_pending.push_back(d);
    for (int r = 0; r < repeats; r++) { d.ev.key.repeat = true; g_pending.push_back(d); }
    if (text) {
        Pending t = blank(SDL_EVENT_TEXT_INPUT, mods);
        t.ev.text.text = keep(*text);
        t.batch_end = false;
        g_pending.push_back(t);
    }
    Pending u = blank(SDL_EVENT_KEY_UP, mods);
    u.ev.key.key = code; u.ev.key.mod = mods; u.ev.key.down = false;
    u.ev.key.scancode = d.ev.key.scancode;
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
static std::string rest_after(const std::string& line, const std::string& cmd) {
    size_t at = line.find(cmd) + cmd.size();
    if (at < line.size() && line[at] == ' ') at++;
    return line.substr(at);
}

// `resize W H` resizes the real window (W, H in points, as SDL takes them)
// and delivers the events SDL itself produced for it; a driver that
// produced none (some offscreen setups) gets them synthesized.
static void do_resize(int w, int h) {
    SDL_Window* win = target_window();
    if (!win) return;
    ::SDL_SetWindowSize(win, w, h);
    ::SDL_SyncWindow(win);
    ::SDL_PumpEvents();
    SDL_Event evs[16];
    int n = ::SDL_PeepEvents(evs, 16, SDL_GETEVENT, SDL_EVENT_WINDOW_RESIZED, SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED);
    bool got = false;
    for (int i = 0; i < n; i++) {
        if (evs[i].type != SDL_EVENT_WINDOW_RESIZED && evs[i].type != SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) continue;
        Pending p = blank(evs[i].type, SDL_KMOD_NONE);
        p.ev = evs[i];
        p.batch_end = false;
        g_pending.push_back(p);
        got = true;
    }
    if (!got) {
        Pending r = blank(SDL_EVENT_WINDOW_RESIZED, SDL_KMOD_NONE);
        r.ev.window.data1 = w; r.ev.window.data2 = h;
        r.batch_end = false;
        g_pending.push_back(r);
        int pw = w, ph = h;
        ::SDL_GetWindowSizeInPixels(win, &pw, &ph);
        Pending px = blank(SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, SDL_KMOD_NONE);
        px.ev.window.data1 = pw; px.ev.window.data2 = ph;
        g_pending.push_back(px);
    } else {
        g_pending.back().batch_end = true;
        g_pending.back().wait_after = event_gap();
    }
}

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
    auto btn_mods = [&](size_t from, int& btn, SDL_Keymod& mods) {
        btn = 1; mods = SDL_KMOD_NONE;
        for (size_t i = from; i < a.size(); i++) {
            if (isdigit((unsigned char)a[i][0])) btn = atoi(a[i].c_str());
            else mods = parse_mods(a[i]);
        }
    };
    long gap = event_gap();
    if (cmd == "wait") { g_wait += (long)num(1, 1); return; }
    if (cmd == "snap") { if (a.size() >= 2) write_snap(line.substr(line.find(a[1]))); return; }
    if (cmd == "quit") { g_pending.push_back(blank(SDL_EVENT_QUIT, SDL_KMOD_NONE)); return; }
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
        if (cmd == "up") { push_mouse(SDL_EVENT_MOUSE_BUTTON_UP, x, y, btn, mods, gap); return; }
        push_mouse(SDL_EVENT_MOUSE_MOTION, x, y, 0, SDL_KMOD_NONE, 1);
        int reps = cmd == "dblclick" ? 2 : 1;
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
        SDL_Keymod wm = SDL_KMOD_NONE;
        float wdx = 0.0f;
        for (size_t i = 4; i < a.size(); i++) {
            char c0 = a[i].empty() ? 0 : a[i][0];
            if (isdigit((unsigned char)c0) || c0 == '-' || c0 == '+' || c0 == '.') wdx = (float)atof(a[i].c_str());
            else wm = parse_mods(a[i]);
        }
        Pending w = blank(SDL_EVENT_MOUSE_WHEEL, wm);
        w.ev.wheel.mouse_x = num(1, g_mouse_x);
        w.ev.wheel.mouse_y = num(2, g_mouse_y);
        w.ev.wheel.y = num(3, 0);
        w.ev.wheel.x = wdx;
        w.ev.wheel.integer_y = (Sint32)w.ev.wheel.y;
        w.ev.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
        g_pending.push_back(w);
        return;
    }
    if (cmd == "resize") { do_resize((int)num(1, 800), (int)num(2, 600)); return; }
    // A real display's scale cannot be changed from a script (the stub's
    // `scale F` fakes it); the command is accepted and does nothing, so one
    // script runs on both.
    if (cmd == "scale") { fprintf(stderr, "[nyh] scale: not supported on a real display\n"); return; }
    if (cmd == "drop" || cmd == "droptext") {
        Pending d = blank(cmd == "drop" ? SDL_EVENT_DROP_FILE : SDL_EVENT_DROP_TEXT, SDL_KMOD_NONE);
        d.ev.drop.data = keep(rest_after(line, cmd));
        d.ev.drop.x = g_mouse_x; d.ev.drop.y = g_mouse_y;
        g_pending.push_back(d);
        return;
    }
    if (cmd == "leave") { g_pending.push_back(blank(SDL_EVENT_WINDOW_MOUSE_LEAVE, SDL_KMOD_NONE)); return; }
    if (cmd == "focus") {
        bool on = a.size() < 2 || a[1] != "0";
        g_pending.push_back(blank(on ? SDL_EVENT_WINDOW_FOCUS_GAINED : SDL_EVENT_WINDOW_FOCUS_LOST, SDL_KMOD_NONE));
        return;
    }
    if (cmd == "window") {
        int n = (int)num(1, 1);
        g_target = (n >= 1 && n <= (int)g_windows.size()) ? g_windows[(size_t)n - 1] : nullptr;
        return;
    }
    if (cmd == "textedit") {
        Pending t = blank(SDL_EVENT_TEXT_EDITING, SDL_KMOD_NONE);
        std::string s = rest_after(line, cmd);
        t.ev.edit.text = keep(s);
        t.ev.edit.start = (Sint32)s.size();
        g_pending.push_back(t);
        return;
    }
    if (cmd == "dialog") {
        std::string path = rest_after(line, cmd);
        while (!path.empty() && path[0] == ' ') path.erase(0, 1);
        if (!g_dialog_cb) { fprintf(stderr, "[nyh] dialog: no dialog was started\n"); return; }
        const char* one[2] = {path.c_str(), nullptr};
        const char* none[1] = {nullptr};
        SDL_DialogFileCallback cb = g_dialog_cb;
        g_dialog_cb = nullptr;
        cb(g_dialog_ud, path.empty() ? none : one, -1);
        return;
    }
    if (cmd == "keyrepeat" || cmd == "key") {
        if (a.size() < 2) return;
        SDL_Keymod mods; SDL_Keycode code;
        if (!parse_combo(a[1], mods, code)) { fprintf(stderr, "[nyh] unknown key: %s\n", a[1].c_str()); return; }
        push_key(code, mods, nullptr, true, cmd == "keyrepeat" ? (int)num(2, 2) : 0);
        return;
    }
    if (cmd == "type" || cmd == "text") {
        std::string body = rest_after(line, cmd);
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
            Pending t = blank(SDL_EVENT_TEXT_INPUT, SDL_KMOD_NONE);
            t.ev.text.text = keep(all);
            g_pending.push_back(t);
            return;
        }
        for (size_t i = 0; i < units.size(); i++) {
            const std::string& u = units[i];
            bool last = i + 1 == units.size();
            if (u == "\n") { push_key(SDLK_RETURN, SDL_KMOD_NONE, nullptr, last); continue; }
            if (u == "\t") { push_key(SDLK_TAB, SDL_KMOD_NONE, nullptr, last); continue; }
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
    fprintf(stderr, "[nyh] unknown script command: %s\n", line.c_str());
}

// In scripted mode the real queue still carries what SDL itself generates
// for the window (resizes, exposure, pixel-size and display changes, a
// close request); those are passed through. Input from the real display
// (a stray pointer on the X server) is dropped, so a run is reproducible.
static bool real_passthrough(SDL_Event* e) {
    SDL_Event ev;
    while (::SDL_PollEvent(&ev)) {
        bool window_ev = ev.type >= SDL_EVENT_WINDOW_FIRST && ev.type <= SDL_EVENT_WINDOW_LAST;
        bool display_ev = ev.type >= SDL_EVENT_DISPLAY_FIRST && ev.type <= SDL_EVENT_DISPLAY_LAST;
        bool user_ev = ev.type >= SDL_EVENT_USER;
        if (window_ev && (ev.type == SDL_EVENT_WINDOW_MOUSE_ENTER || ev.type == SDL_EVENT_WINDOW_MOUSE_LEAVE ||
                          ev.type == SDL_EVENT_WINDOW_FOCUS_GAINED || ev.type == SDL_EVENT_WINDOW_FOCUS_LOST))
            continue;   // focus and hover belong to the script
        if (window_ev || display_ev || user_ev || ev.type == SDL_EVENT_QUIT) {
            if (e) *e = ev;
            return true;
        }
    }
    return false;
}

bool PollEvent(SDL_Event* e) {
    if (!scripted()) {
        if (autoquit() >= 0) {
            if (::SDL_PollEvent(e)) { g_empty_polls = 0; return true; }
            if (!g_quit_delivered && ++g_empty_polls >= autoquit()) {
                g_quit_delivered = true;
                snap_on_exit();
                if (e) { memset(e, 0, sizeof(SDL_Event)); e->type = SDL_EVENT_QUIT; }
                return true;
            }
            return false;
        }
        return ::SDL_PollEvent(e);
    }
    if (real_passthrough(e)) return true;
    if (g_batch_break) { g_batch_break = false; return false; }
    if (g_wait > 0) { g_wait--; return false; }
    if (g_pending.empty()) {
        std::string line;
        while (g_pending.empty() && g_wait == 0 && read_command(line)) exec_command(line);
        if (g_pending.empty() && g_wait > 0) { g_wait--; return false; }
    }
    if (!g_pending.empty()) {
        Pending p = g_pending.front();
        g_pending.pop_front();
        if (e) *e = p.ev;
        g_mods = p.mods;
        if (p.ev.type == SDL_EVENT_MOUSE_MOTION) { g_mouse_x = p.ev.motion.x; g_mouse_y = p.ev.motion.y; }
        if (p.batch_end) { g_batch_break = true; g_wait = p.wait_after; }
        g_empty_polls = 0;
        if (p.ev.type == SDL_EVENT_QUIT) { g_quit_delivered = true; snap_on_exit(); }
        return true;
    }
    long th = autoquit();
    if (th >= 0 && !g_quit_delivered) {
        if (++g_empty_polls >= th) {
            g_quit_delivered = true;
            snap_on_exit();
            if (e) { memset(e, 0, sizeof(SDL_Event)); e->type = SDL_EVENT_QUIT; }
            return true;
        }
    }
    return false;
}

bool WaitEventTimeout(SDL_Event* e, Sint32 ms) {
    if (!scripted() && autoquit() < 0) return ::SDL_WaitEventTimeout(e, ms);
    if (PollEvent(e)) return true;
    if (ms != 0) std::this_thread::sleep_for(std::chrono::milliseconds(ms < 0 ? 16 : std::min<int>(ms, 16)));
    return false;
}

// Events the application posts (dialog results, wake-ups) are their own
// batch while a script runs, as in the stub.
bool PushEvent(SDL_Event* e) {
    if (!scripted() || !e) return ::SDL_PushEvent(e);
    Pending p;
    p.ev = *e;
    p.mods = g_mods;
    p.batch_end = true;
    p.wait_after = event_gap();
    g_pending.push_back(p);
    return true;
}

SDL_Keymod GetModState(void) { return scripted() ? g_mods : ::SDL_GetModState(); }

// A scripted run keeps its own clipboard: the tests must not read or
// overwrite the desktop's.
bool SetClipboardText(const char* text) {
    if (!scripted()) return ::SDL_SetClipboardText(text);
    g_clipboard = text ? text : "";
    return true;
}
char* GetClipboardText(void) {
    if (!scripted()) return ::SDL_GetClipboardText();
    return ::SDL_strdup(g_clipboard.c_str());
}

// Nothing may block a scripted run: message boxes go to stderr, dialogs are
// answered by the script's `dialog` command.
bool ShowSimpleMessageBox(SDL_MessageBoxFlags flags, const char* title, const char* msg, SDL_Window* w) {
    if (!scripted()) return ::SDL_ShowSimpleMessageBox(flags, title, msg, w);
    fprintf(stderr, "[nyh] messagebox: %s: %s\n", title ? title : "", msg ? msg : "");
    return true;
}
void ShowOpenFileDialog(SDL_DialogFileCallback cb, void* ud, SDL_Window* w,
                        const SDL_DialogFileFilter* f, int nf, const char* def, bool many) {
    if (!scripted()) { ::SDL_ShowOpenFileDialog(cb, ud, w, f, nf, def, many); return; }
    g_dialog_cb = cb; g_dialog_ud = ud;
}
void ShowSaveFileDialog(SDL_DialogFileCallback cb, void* ud, SDL_Window* w,
                        const SDL_DialogFileFilter* f, int nf, const char* def) {
    if (!scripted()) { ::SDL_ShowSaveFileDialog(cb, ud, w, f, nf, def); return; }
    g_dialog_cb = cb; g_dialog_ud = ud;
}
void ShowOpenFolderDialog(SDL_DialogFileCallback cb, void* ud, SDL_Window* w, const char* def, bool many) {
    if (!scripted()) { ::SDL_ShowOpenFolderDialog(cb, ud, w, def, many); return; }
    g_dialog_cb = cb; g_dialog_ud = ud;
}

}  // namespace nyh

#endif  // NYTHON_SDL_STUB
