#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/gui.cpp
// SDL3 + SDL3_ttf + SDL3_image GUI backend for Nython
// ─────────────────────────────────────────────────────────────────────────────
// Implements all gui_* builtins called by lib/gui.ny.
// Link: -lSDL3 -lSDL3_ttf -lSDL3_image
// ─────────────────────────────────────────────────────────────────────────────

#include "NythonExecutor.hpp"
#include "builtins/gui.hpp"

using namespace nython::kernel;
using nython::kernel::bigint;

// SDL_MAIN_HANDLED is defined via -DSDL_MAIN_HANDLED in the build flags
// and also guarded in platform_compat.hpp — do not redefine here.
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_image/SDL_image.h>
#include <unordered_map>
#include <utility>      // std::pair  (used by the metrics cache)
#include <functional>   // std::hash  (used by the cache key hashers)
#include <string>
#include <vector>
#include <deque>
#include <cstring>
#include <cstdint>
#include <chrono>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <cmath>
#include <algorithm>
#include "NyConc.hpp"
// Built against a real SDL3, the SDL calls below go through the test
// harness (scripted input + frame capture for tools/ide_driver.py); with
// no harness variable set each wrapper is a direct SDL call.
#ifndef NYTHON_SDL_STUB
#include "builtins/gui_harness.hpp"
#endif

// ── Handle registries ───────────────────────────────────────────────────────
static int next_win_id  = 1;
static int next_font_id = 1;
static int next_img_id  = 1;

struct WinEntry {
    SDL_Window*   win = nullptr;
    SDL_Renderer* ren = nullptr;
    SDL_WindowID  sdl_id = 0;
    int last_w = 0, last_h = 0;          // last size reported in a "resize"
    std::vector<SDL_Rect> clip_stack{};  // gui_push_clip / gui_pop_clip
    // gui_push_offset: everything drawn is shifted by (ox, oy), so a scrolled
    // container moves all its descendants without touching their positions.
    float ox = 0.0f, oy = 0.0f;
    std::vector<std::pair<float,float>> off_stack{};
    // Layout-unit window (flag 16): sizes the application passes are the
    // sizes it would have at scale 1; min_uw/min_uh are kept in those units
    // so the minimum follows the window to a display of another scale.
    bool units = false;
    int min_uw = 0, min_uh = 0;
};

// Window points per layout unit. SDL3 has two HiDPI models (SDL's
// docs/README-highdpi.md): on Windows and X11 window coordinates are device
// pixels and the content scale says how much bigger to draw (200%: 2 points
// per unit); on macOS and Wayland they are points and a high-density window
// just has more pixels per point (1 point per unit). The window display
// scale (pixels per unit) over the pixel density (pixels per point) is the
// answer on both - measured on the window, so no platform table is needed.
static float units_k(SDL_Window* w) {
    float ds = SDL_GetWindowDisplayScale(w), pd = SDL_GetWindowPixelDensity(w);
    if (!(ds > 0.0f)) ds = 1.0f;
    if (!(pd > 0.0f)) pd = 1.0f;
    float k = ds / pd;
    return k < 0.25f ? 0.25f : (k > 8.0f ? 8.0f : k);
}
static int units_px(int v, float k) { return (int)((float)v * k + 0.5f); }

static std::unordered_map<int, WinEntry>      g_windows;
static std::unordered_map<int, TTF_Font*>     g_fonts;

// Images keep their decoded surface and get one texture per renderer, made
// on first draw. A texture belongs to the renderer that created it, so the
// old single texture (always made on whichever window the hash map listed
// first) could not be drawn in any other window, and a surface also lets an
// image be loaded before any window exists and be used as a window icon.
struct ImgEntry {
    SDL_Surface* surf = nullptr;
    int w = 0, h = 0;
    std::unordered_map<SDL_Renderer*, SDL_Texture*> tex{};
};
static std::unordered_map<int, ImgEntry> g_images;

// ── Rendered-text cache ─────────────────────────────────────────────────────
// Keyed by renderer + font handle + packed RGBA + the string itself. The
// renderer is part of the key because a texture can only be drawn by the
// renderer that made it: without it, text first drawn in one window was
// silently missing in every other window.
struct TextKey {
    SDL_Renderer* ren;
    int         font;
    Uint32      rgba;
    std::string text;
    bool operator==(const TextKey& o) const {
        return ren==o.ren && font==o.font && rgba==o.rgba && text==o.text;
    }
};
struct TextKeyHash {
    size_t operator()(const TextKey& k) const {
        size_t h = std::hash<std::string>{}(k.text);
        h ^= std::hash<int>{}(k.font)      + 0x9e3779b9 + (h<<6) + (h>>2);
        h ^= std::hash<Uint32>{}(k.rgba)   + 0x9e3779b9 + (h<<6) + (h>>2);
        h ^= std::hash<const void*>{}((const void*)k.ren) + 0x9e3779b9 + (h<<6) + (h>>2);
        return h;
    }
};
struct TextEntry { SDL_Texture* tex; int w; int h; };
static std::unordered_map<TextKey, TextEntry, TextKeyHash> g_text_cache;
static const size_t kTextCacheMax = 4096;

// Metrics cache: (font handle, string) -> (w, h)
struct MeasureKey {
    int         font;
    std::string text;
    bool operator==(const MeasureKey& o) const { return font==o.font && text==o.text; }
};
struct MeasureKeyHash {
    size_t operator()(const MeasureKey& k) const {
        size_t h = std::hash<std::string>{}(k.text);
        h ^= std::hash<int>{}(k.font) + 0x9e3779b9 + (h<<6) + (h>>2);
        return h;
    }
};
static std::unordered_map<MeasureKey, std::pair<int,int>, MeasureKeyHash> g_measure_cache;
static const size_t kMeasureCacheMax = 8192;

// Drops cached text textures. With a renderer, only that renderer's (it is
// about to be destroyed); without, all of them.
static void clear_text_cache(SDL_Renderer* only = nullptr) {
    for(auto it=g_text_cache.begin(); it!=g_text_cache.end();){
        if(!only || it->first.ren==only){
            if(it->second.tex) SDL_DestroyTexture(it->second.tex);
            it=g_text_cache.erase(it);
        } else ++it;
    }
}

static bool g_sdl_inited  = false;
static bool g_sdl_ok      = false;   // true only if SDL_Init succeeded
static std::string g_sdl_error;      // last SDL error string for Nython scripts
static Uint32 g_dialog_event = 0;    // registered user event for file dialogs

// System cursors, created lazily. They belong to the video subsystem, so they
// are destroyed before SDL_Quit (a static cache inside the builtin used to
// keep pointers that SDL_Quit had already freed).
static std::unordered_map<int, SDL_Cursor*> g_cursors;
static bool g_cursor_hidden = false;

// ── Error reporting ──────────────────────────────────────────────────────────
// On Windows GUI builds (type=0, no console), fprintf(stderr) is invisible.
// Use SDL_ShowSimpleMessageBox so the user always sees what went wrong.
static void nython_gui_error(const std::string& msg) {
    fprintf(stderr, "[Nython] %s\n", msg.c_str());
    // Show a message box — works before SDL is fully initialised
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Nython — Cannot open window",
                             msg.c_str(), nullptr);
}

// Only called from gui_create_window — not from every gui_ dispatch
static bool ensure_sdl_for_window() {
    if (g_sdl_inited) return g_sdl_ok;
    g_sdl_inited = true;
    // SDL_SetMainReady(): required when SDL_MAIN_HANDLED is defined.
    SDL_SetMainReady();
    // Let SDL3 auto-select the best renderer for this platform.
    // On Windows: Direct3D 11 (native, fast, correct colors).
    // On macOS:   Metal.
    // On Linux:   OpenGL or Vulkan.
    // Do NOT force "opengl" on Windows — the OpenGL renderer renders
    // to a white/invisible buffer on many Windows GPU configurations.
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        const char* sdl_err = SDL_GetError();
        g_sdl_error = (sdl_err && *sdl_err)
            ? std::string("SDL_Init failed: ") + sdl_err
            : "SDL_Init failed (no error detail — check SDL3.dll is present and correct architecture)";
        nython_gui_error(g_sdl_error);
        return false;
    }
    if (!TTF_Init()) {
        fprintf(stderr, "[Nython] TTF_Init failed: %s\n", SDL_GetError());
        // Non-fatal — continue without font rendering
    }
    // File dialogs report back from another thread; the answer is posted as
    // this event type and turned into a "dialog" event by the poll loop.
    if (!g_dialog_event) g_dialog_event = SDL_RegisterEvents(1);
    g_sdl_ok = true;
    return true;
}

// ── Value helpers ───────────────────────────────────────────────────────────
static inline int64_t bi64(bigint bi) {
    if (bi == 0) return 0;
    bool neg = bi < 0; if (neg) bi = -bi;
    int64_t r = 0; int shift = 0;
    while (bi > 0) { r |= ((int64_t)(bi % 256)) << shift; shift += 8; bi /= 256; }
    return neg ? -r : r;
}
static int    VI(const Value& v) { return v.type==ValueType::INTEGER?(int)bi64(v.value.i):v.type==ValueType::DOUBLE?(int)v.value.d:v.type==ValueType::BOOLEAN?(v.value.b?1:0):0; }
static float  VF(const Value& v) { return (float)(v.type==ValueType::DOUBLE?(double)v.value.d:v.type==ValueType::INTEGER?(double)bi64(v.value.i):0.0); }
static Uint8  VU(const Value& v) { return (Uint8)std::clamp(VI(v),0,255); }
static std::string VS(NythonExecutor& E, const Value& v) { return E.getStringValue(v); }
// Coordinates with the window's current drawing offset applied.
static inline float OX(const WinEntry* we, const Value& v) { return VF(v) + we->ox; }
static inline float OY(const WinEntry* we, const Value& v) { return VF(v) + we->oy; }

static Value make_int_list(NythonExecutor& E, const std::vector<int>& xs) {
    auto* lst=new Object((Runnable*)E.runner,"list",Type::LIST);
    for(size_t i=0;i<xs.size();i++) lst->set(std::to_string(i),Value(xs[i]));
    lst->set("__len__",Value((int)xs.size()));
    return Value((Collectable*)lst);
}
static Value make_str_list(NythonExecutor& E, const std::vector<std::string>& xs) {
    auto* lst=new Object((Runnable*)E.runner,"list",Type::LIST);
    for(size_t i=0;i<xs.size();i++) lst->set(std::to_string(i),E.makeStringValue(xs[i]));
    lst->set("__len__",Value((int)xs.size()));
    return Value((Collectable*)lst);
}

static WinEntry* win_of(const std::vector<Value>& args, size_t i = 0) {
    if(args.size()<=i) return nullptr;
    auto it=g_windows.find(VI(args[i]));
    return it==g_windows.end() ? nullptr : &it->second;
}

// Size of the drawing surface. With SDL_WINDOW_HIGH_PIXEL_DENSITY this is in
// pixels and differs from SDL_GetWindowSize (points); without it the two agree.
static void output_size(WinEntry& we, int& w, int& h) {
    w=0; h=0;
    if(!we.ren || !SDL_GetRenderOutputSize(we.ren,&w,&h) || w<=0 || h<=0)
        SDL_GetWindowSize(we.win,&w,&h);
}

// ── Events ──────────────────────────────────────────────────────────────────
// SDL events are converted into this plain record as soon as they are read
// (the strings SDL hands out are only valid until the next poll) and queued
// per window, so gui_poll_events(handle) returns only that window's events
// plus application-wide ones. Event maps are built from it on return.
struct EvData {
    std::string type{}, key{}, text{};
    int x=0, y=0, button=0, keycode=0, delta=0, w=0, h=0, clicks=0;
    bool ctrl=false, shift=false, alt=false, meta=false, repeat=false;
    double dx=0.0, dy=0.0;
    int window=0;                        // gui window handle, 0 = application
};
static std::deque<EvData> g_evq;
static float g_wheel_acc_x = 0.0f, g_wheel_acc_y = 0.0f;

static Value ev_value(NythonExecutor& E, const EvData& d) {
    auto* o = new Object((Runnable*)E.runner, "event", Type::MAP);
    o->set("type",   E.makeStringValue(d.type));
    o->set("x",      Value(d.x));  o->set("y",     Value(d.y));
    o->set("button", Value(d.button)); o->set("key", E.makeStringValue(d.key));
    o->set("keycode",Value(d.keycode)); o->set("text", E.makeStringValue(d.text));
    o->set("delta",  Value(d.delta)); o->set("w",   Value(d.w)); o->set("h", Value(d.h));
    o->set("ctrl",   Value(d.ctrl)); o->set("shift", Value(d.shift)); o->set("alt", Value(d.alt));
    o->set("meta",   Value(d.meta)); o->set("repeat", Value(d.repeat));
    o->set("clicks", Value(d.clicks));
    // Each entry costs a few hundred bytes the interpreter never gives back
    // (GC_NOTES.md), on every event, so the rest are only sent when they
    // mean something: the wheel's exact amounts, and the window when there
    // is more than one to tell apart (absent means the only window).
    if(d.type=="wheel"){ o->set("dx", Value(d.dx)); o->set("dy", Value(d.dy)); }
    if(g_windows.size()>1) o->set("window", Value(d.window));
    return Value(static_cast<Collectable*>(o));
}

static int handle_for_sdl_window(SDL_WindowID id) {
    if(!id) return 0;
    for(auto& kv : g_windows) if(kv.second.sdl_id==id) return kv.first;
    return 0;
}

// SDL_GetKeyName spells keys "Return", "Page Up", "Keypad Enter", ...; every
// widget compares against lowercase short names.
static std::string norm_key(SDL_Keycode code) {
    const char* raw = SDL_GetKeyName(code);
    std::string k = raw ? raw : "";
    for(auto& c:k) c=(char)tolower((unsigned char)c);
    if(k=="return" || k=="keypad enter" || k=="return2") return "enter";
    if(k=="page up")   return "pageup";
    if(k=="page down") return "pagedown";
    if(k=="left ctrl"  || k=="right ctrl")  return "ctrl";
    if(k=="left shift" || k=="right shift") return "shift";
    if(k=="left alt"   || k=="right alt")   return "alt";
    if(k=="left gui"   || k=="right gui")   return "super";
    return k;   // "escape", "backspace", "delete", "tab", "space", "up", "f1", ...
}

static void set_mods(EvData& d, SDL_Keymod mod) {
    d.ctrl  = (mod & SDL_KMOD_CTRL)  != 0;
    d.shift = (mod & SDL_KMOD_SHIFT) != 0;
    d.alt   = (mod & SDL_KMOD_ALT)   != 0;
    d.meta  = (mod & SDL_KMOD_GUI)   != 0;
}

// Size change for a window: reported in drawing coordinates, and only when it
// actually changed (RESIZED and PIXEL_SIZE_CHANGED usually arrive together).
static bool resize_event(int handle, int fallback_w, int fallback_h, EvData& d) {
    int w=fallback_w, h=fallback_h;
    auto it=g_windows.find(handle);
    if(it!=g_windows.end()){
        output_size(it->second,w,h);
        if(w==it->second.last_w && h==it->second.last_h) return false;
        it->second.last_w=w; it->second.last_h=h;
    }
    d.type="resize"; d.w=w; d.h=h;
    return true;
}

// Converts one SDL event; returns false for event types nobody asked for.
static bool convert_event(SDL_Event& ev, EvData& d) {
    SDL_WindowID wid = 0;
    switch(ev.type){
        case SDL_EVENT_MOUSE_MOTION:      wid=ev.motion.windowID; break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:   wid=ev.button.windowID; break;
        case SDL_EVENT_MOUSE_WHEEL:       wid=ev.wheel.windowID; break;
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:            wid=ev.key.windowID; break;
        case SDL_EVENT_TEXT_INPUT:        wid=ev.text.windowID; break;
        case SDL_EVENT_TEXT_EDITING:      wid=ev.edit.windowID; break;
        case SDL_EVENT_DROP_FILE:
        case SDL_EVENT_DROP_TEXT:         wid=ev.drop.windowID; break;
        case SDL_EVENT_QUIT:              wid=0; break;
        default:
            if(ev.type>=SDL_EVENT_WINDOW_FIRST && ev.type<=SDL_EVENT_WINDOW_LAST)
                wid=ev.window.windowID;
            else if(g_dialog_event && ev.type==g_dialog_event)
                wid=ev.user.windowID;
            break;
    }
    d.window = handle_for_sdl_window(wid);
    // Mouse positions in the renderer's coordinates: identical to window
    // coordinates normally, pixels when the window has high pixel density.
    auto wit = g_windows.find(d.window);
    if(wit!=g_windows.end() && wit->second.ren &&
       (ev.type==SDL_EVENT_MOUSE_MOTION || ev.type==SDL_EVENT_MOUSE_BUTTON_DOWN ||
        ev.type==SDL_EVENT_MOUSE_BUTTON_UP || ev.type==SDL_EVENT_MOUSE_WHEEL ||
        ev.type==SDL_EVENT_DROP_FILE || ev.type==SDL_EVENT_DROP_TEXT))
        SDL_ConvertEventToRenderCoordinates(wit->second.ren, &ev);

    switch(ev.type){
        case SDL_EVENT_QUIT: d.type="quit"; return true;
        case SDL_EVENT_WINDOW_CLOSE_REQUESTED: d.type="quit"; return true;
        case SDL_EVENT_WINDOW_RESIZED:
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            return resize_event(d.window, ev.window.data1, ev.window.data2, d);
        // The window can be mapped or uncovered AFTER the first frame
        // was presented. A caller that only repaints on change would
        // otherwise leave a blank window forever.
        case SDL_EVENT_WINDOW_EXPOSED:
        case SDL_EVENT_WINDOW_SHOWN:
        case SDL_EVENT_WINDOW_RESTORED:
            d.type="expose"; return true;
        // The window's display scale changed (it moved to a monitor of another
        // scale, or the system setting changed): dx is the new pixels per
        // layout unit. A layout-unit window's minimum size follows.
        case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED: {
            auto it = g_windows.find(d.window);
            if(it==g_windows.end()) return false;
            SDL_Window* w = it->second.win;
            d.type="scale"; d.dx = SDL_GetWindowDisplayScale(w);
            if(!(d.dx > 0.0f)) d.dx = 1.0f;
            if(it->second.units && (it->second.min_uw>0 || it->second.min_uh>0)){
                float k = units_k(w);
                SDL_SetWindowMinimumSize(w, units_px(it->second.min_uw,k), units_px(it->second.min_uh,k));
            }
            return true;
        }
        case SDL_EVENT_WINDOW_FOCUS_GAINED: d.type="focusgained"; return true;
        case SDL_EVENT_WINDOW_FOCUS_LOST:   d.type="focuslost";   return true;
        // Without this a hover highlight stayed lit after the pointer left the
        // window, and a drag in progress never learned it had left.
        case SDL_EVENT_WINDOW_MOUSE_LEAVE:  d.type="mouseleave";  return true;
        // Mouse events carry the modifier state (Shift+Click, Alt+Click).
        case SDL_EVENT_MOUSE_MOTION:
            d.type="mousemove"; d.x=(int)ev.motion.x; d.y=(int)ev.motion.y;
            set_mods(d, SDL_GetModState());
            return true;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
            d.type = ev.type==SDL_EVENT_MOUSE_BUTTON_DOWN ? "mousedown" : "mouseup";
            d.x=(int)ev.button.x; d.y=(int)ev.button.y; d.button=ev.button.button;
            // SDL counts consecutive clicks itself (double/triple click) with
            // the platform's own interval and distance.
            d.clicks=(int)ev.button.clicks;
            set_mods(d, SDL_GetModState());
            return true;
        case SDL_EVENT_MOUSE_WHEEL: {
            // wheel.x/y = scroll amount (fractional on trackpads);
            // wheel.mouse_x/y = cursor position. "delta" stays an integer for
            // existing widgets, but the fraction is carried over to the next
            // event instead of being truncated away - a trackpad sends many
            // events of 0.1-0.5, which all used to arrive as delta 0.
            float wy = ev.wheel.direction==SDL_MOUSEWHEEL_FLIPPED ? -ev.wheel.y : ev.wheel.y;
            float wx = ev.wheel.direction==SDL_MOUSEWHEEL_FLIPPED ? -ev.wheel.x : ev.wheel.x;
            if((wy>0 && g_wheel_acc_y<0) || (wy<0 && g_wheel_acc_y>0)) g_wheel_acc_y=0;
            g_wheel_acc_y += wy;
            int whole=(int)g_wheel_acc_y;
            g_wheel_acc_y -= (float)whole;
            if((wx>0 && g_wheel_acc_x<0) || (wx<0 && g_wheel_acc_x>0)) g_wheel_acc_x=0;
            g_wheel_acc_x += wx;
            g_wheel_acc_x -= (float)(int)g_wheel_acc_x;
            d.type="wheel"; d.x=(int)ev.wheel.mouse_x; d.y=(int)ev.wheel.mouse_y;
            d.delta=whole; d.dx=wx; d.dy=wy;
            set_mods(d, SDL_GetModState());
            return true;
        }
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:
            d.type = ev.type==SDL_EVENT_KEY_DOWN ? "keydown" : "keyup";
            d.key=norm_key(ev.key.key); d.keycode=(int)ev.key.key;
            d.repeat=ev.key.repeat;
            set_mods(d, SDL_GetModState());
            return true;
        case SDL_EVENT_TEXT_INPUT:
            d.type="textinput"; d.text=ev.text.text ? ev.text.text : "";
            return true;
        // IME composition in progress: text is the uncommitted string, x the
        // cursor within it and w the length of its selected part.
        case SDL_EVENT_TEXT_EDITING:
            d.type="textedit"; d.text=ev.edit.text ? ev.edit.text : "";
            d.x=ev.edit.start; d.w=ev.edit.length;
            return true;
        // One event per dropped file; SDL sends one DROP_FILE per file.
        case SDL_EVENT_DROP_FILE:
        case SDL_EVENT_DROP_TEXT:
            d.type = ev.type==SDL_EVENT_DROP_FILE ? "dropfile" : "droptext";
            d.text = ev.drop.data ? ev.drop.data : "";
            d.x=(int)ev.drop.x; d.y=(int)ev.drop.y;
            return true;
        default: break;
    }
    if(g_dialog_event && ev.type==g_dialog_event){
        d.type="dialog";
        if(ev.user.data1){ d.text=(const char*)ev.user.data1; SDL_free(ev.user.data1); }
        d.button=ev.user.code;          // 1 = a path was chosen, 0 = cancelled
        return true;
    }
    return false;
}

// Reads SDL's queue into g_evq. With `wait`, blocks up to timeout_ms for the
// first event (so an idle window sleeps instead of spinning), then drains.
static void pump_events(bool wait, int timeout_ms) {
    SDL_Event ev;
    bool got;
    if (wait) {
        // Other Nython threads keep running while the window sleeps: the
        // wait touches no engine state, so the GIL is released for it.
        nyconc::GilRelease unlocked;
        got = SDL_WaitEventTimeout(&ev, (Sint32)timeout_ms);
    } else {
        got = SDL_PollEvent(&ev);
    }
    while(got){
        EvData d;
        if(convert_event(ev, d)) g_evq.push_back(std::move(d));
        got = SDL_PollEvent(&ev);
    }
}

static bool ev_for(const EvData& d, int handle) {
    if(handle<=0 || d.window==0 || d.window==handle) return true;
    return g_windows.find(d.window)==g_windows.end();   // window gone: anyone
}

static bool has_events_for(int handle) {
    for(auto& d:g_evq) if(ev_for(d,handle)) return true;
    return false;
}

// The event gui_next_event popped, read field by field with gui_event_get.
static EvData g_cur;
static int g_cur_handle = -1;
// A type missing from the code table (none today): code 0, as if no event.
static Value gui_next_event_unknown(const EvData&) { return Value(0); }

// ── File dialogs ────────────────────────────────────────────────────────────
// SDL may call this from another thread: post an event, never touch Values.
static void SDLCALL dialog_done(void* userdata, const char* const* filelist, int filter) {
    (void)filter;
    if(!g_dialog_event) return;
    SDL_Event ev;
    memset(&ev,0,sizeof(ev));
    ev.type = g_dialog_event;
    ev.user.windowID = (SDL_WindowID)(uintptr_t)userdata;
    if(filelist && filelist[0]){
        ev.user.code = 1;
        ev.user.data1 = SDL_strdup(filelist[0]);
    }
    SDL_PushEvent(&ev);
}

// ── Geometry helpers (SDL3 uses SDL_FRect for rendering) ─────────────────────
// Scanline fill: every pixel is covered exactly once. The previous version
// drew the body as three rectangles plus a full circle at each corner, so a
// translucent fill (hover backgrounds, the command centre) was blended two or
// three times where they overlapped and showed dark blobs at the corners.
static void fill_rounded_rect(SDL_Renderer* r,float x,float y,float w,float h,float rad,Uint8 cr,Uint8 cg,Uint8 cb,Uint8 ca) {
    SDL_SetRenderDrawColor(r,cr,cg,cb,ca);
    SDL_SetRenderDrawBlendMode(r,SDL_BLENDMODE_BLEND);
    if(w<=0||h<=0) return;
    rad=std::max(0.0f,std::min(rad,std::min(w/2,h/2)));
    int ir=(int)std::floor(rad);
    int ih=(int)std::floor(h);
    if(ir<=0){ SDL_FRect rc={x,y,w,h}; SDL_RenderFillRect(r,&rc); return; }
    for(int row=0;row<ir;row++){
        float dy=rad-(float)row-0.5f;
        float inset=rad-std::sqrt(std::max(0.0f,rad*rad-dy*dy));
        SDL_FRect top={x+inset,y+(float)row,w-2*inset,1.0f};
        SDL_FRect bot={x+inset,y+(float)(ih-1-row),w-2*inset,1.0f};
        SDL_RenderFillRect(r,&top);
        if(ih-1-row>=ir) SDL_RenderFillRect(r,&bot);
    }
    if(ih-2*ir>0){ SDL_FRect mid={x,y+(float)ir,w,(float)(ih-2*ir)}; SDL_RenderFillRect(r,&mid); }
}

// Horizontal extent of a rounded rect (x, w, radius rad, height ih rows) on
// row `row`: returns the inset from each side.
static float rr_inset(float rad, int ih, int row) {
    if(rad<=0) return 0.0f;
    int ir=(int)std::floor(rad);
    int k = row<ir ? row : (row>=ih-ir ? ih-1-row : -1);
    if(k<0) return 0.0f;
    float dy=rad-(float)k-0.5f;
    return rad-std::sqrt(std::max(0.0f,rad*rad-dy*dy));
}

// Rounded-rect outline `bw` pixels wide, drawn as the ring between the outer
// shape and the inner one (inset by bw, radius rad-bw), each pixel once.
// It used to ignore the width (focus rings were always 1px) and plot every
// corner as 90 separate points.
static void draw_rounded_rect(SDL_Renderer* r,float x,float y,float w,float h,float rad,Uint8 cr,Uint8 cg,Uint8 cb,Uint8 ca,int bw) {
    if(w<=0||h<=0) return;
    SDL_SetRenderDrawColor(r,cr,cg,cb,ca);
    SDL_SetRenderDrawBlendMode(r,SDL_BLENDMODE_BLEND);
    if(bw<1) bw=1;
    rad=std::max(0.0f,std::min(rad,std::min(w/2,h/2)));
    int ih=(int)std::floor(h);
    float fbw=(float)bw;
    if(2*bw>=ih || 2.0f*fbw>=w){ fill_rounded_rect(r,x,y,w,h,rad,cr,cg,cb,ca); return; }
    float irad=std::max(0.0f,rad-fbw);
    int inner_h=ih-2*bw;
    int band=std::max(bw,(int)std::ceil(rad));           // rows handled one by one
    band=std::min(band,ih/2);
    for(int row=0;row<ih;row++){
        if(row==band && ih-band>band){ row=ih-band-1; continue; }
        float oi=rr_inset(rad,ih,row);
        int irow=row-bw;
        if(irow<0 || irow>=inner_h){
            SDL_FRect rc={x+oi,y+(float)row,w-2*oi,1.0f}; SDL_RenderFillRect(r,&rc);
        } else {
            float ii=fbw+rr_inset(irad,inner_h,irow);
            SDL_FRect a={x+oi,y+(float)row,ii-oi,1.0f};
            SDL_FRect b={x+w-ii,y+(float)row,ii-oi,1.0f};
            if(a.w>0){ SDL_RenderFillRect(r,&a); SDL_RenderFillRect(r,&b); }
        }
    }
    if(ih-2*band>0){
        SDL_FRect l={x,y+(float)band,fbw,(float)(ih-2*band)};
        SDL_FRect rr={x+w-fbw,y+(float)band,fbw,(float)(ih-2*band)};
        SDL_RenderFillRect(r,&l); SDL_RenderFillRect(r,&rr);
    }
}
static void fill_circle_sdl(SDL_Renderer* r,float cx,float cy,float rad,Uint8 cr,Uint8 cg,Uint8 cb,Uint8 ca){
    SDL_SetRenderDrawColor(r,cr,cg,cb,ca);
    for(int dy=-(int)rad;dy<=(int)rad;dy++){
        float dx=std::sqrt(rad*rad-(float)(dy*dy));
        SDL_RenderLine(r,cx-dx,cy+dy,cx+dx,cy+dy);
    }
}
static void draw_circle_sdl(SDL_Renderer* r,float cx,float cy,float rad,Uint8 cr,Uint8 cg,Uint8 cb,Uint8 ca){
    SDL_SetRenderDrawColor(r,cr,cg,cb,ca);
    int ix=(int)rad,iy=0,err=0;
    while(ix>=iy){
        SDL_RenderPoint(r,cx+ix,cy+iy);SDL_RenderPoint(r,cx+iy,cy+ix);
        SDL_RenderPoint(r,cx-iy,cy+ix);SDL_RenderPoint(r,cx-ix,cy+iy);
        SDL_RenderPoint(r,cx-ix,cy-iy);SDL_RenderPoint(r,cx-iy,cy-ix);
        SDL_RenderPoint(r,cx+iy,cy-ix);SDL_RenderPoint(r,cx+ix,cy-iy);
        iy++;err+=1+2*iy;if(2*(err-ix)+1>0){ix--;err+=1-2*ix;}
    }
}

// Annular sector between radii r0 (0 = a pie slice) and r1, from angle a0 to
// a1 in degrees (0 = 3 o'clock, increasing clockwise on screen), as triangles.
static void fill_arc(SDL_Renderer* r,float cx,float cy,float r0,float r1,float a0,float a1,Uint8 cr,Uint8 cg,Uint8 cb,Uint8 ca){
    if(r1<=0 || a1==a0) return;
    if(r0<0) r0=0;
    if(r0>r1) std::swap(r0,r1);
    if(a1<a0) std::swap(a0,a1);
    if(a1-a0>360.0f) a1=a0+360.0f;
    float sweep=(a1-a0)*(float)M_PI/180.0f;
    int seg=(int)std::ceil(sweep*r1/3.0f);
    seg=std::clamp(seg,3,720);
    SDL_FColor col={cr/255.0f,cg/255.0f,cb/255.0f,ca/255.0f};
    std::vector<SDL_Vertex> v;
    std::vector<int> idx;
    auto vert=[&](float px,float py){ SDL_Vertex vx; vx.position={px,py}; vx.color=col; vx.tex_coord={0,0}; v.push_back(vx); };
    float s0=a0*(float)M_PI/180.0f;
    if(r0<=0.0f){
        vert(cx,cy);
        for(int i=0;i<=seg;i++){ float t=s0+sweep*(float)i/(float)seg; vert(cx+r1*std::cos(t),cy+r1*std::sin(t)); }
        for(int i=0;i<seg;i++){ idx.push_back(0); idx.push_back(1+i); idx.push_back(2+i); }
    } else {
        for(int i=0;i<=seg;i++){
            float t=s0+sweep*(float)i/(float)seg, c=std::cos(t), s=std::sin(t);
            vert(cx+r0*c,cy+r0*s); vert(cx+r1*c,cy+r1*s);
        }
        for(int i=0;i<seg;i++){
            int a=2*i;
            idx.push_back(a); idx.push_back(a+1); idx.push_back(a+3);
            idx.push_back(a); idx.push_back(a+3); idx.push_back(a+2);
        }
    }
    SDL_SetRenderDrawBlendMode(r,SDL_BLENDMODE_BLEND);
    SDL_RenderGeometry(r,nullptr,v.data(),(int)v.size(),idx.data(),(int)idx.size());
}

// Even-odd scanline fill, sampled at pixel centres: exact for concave and
// self-intersecting outlines. The old fan-from-centroid version started every
// span at the centroid's x, painting outside the shape, and double-blended
// translucent fills where the fan's triangles met.
static void fill_polygon_sdl(SDL_Renderer* r,const std::vector<float>& xs,const std::vector<float>& ys){
    int n=(int)xs.size();
    if(n<3) return;
    float miny=ys[0],maxy=ys[0];
    for(int i=1;i<n;i++){ miny=std::min(miny,ys[i]); maxy=std::max(maxy,ys[i]); }
    std::vector<float> hits;
    for(int y=(int)std::floor(miny); y<=(int)std::ceil(maxy); y++){
        float sy=(float)y+0.5f;
        hits.clear();
        for(int i=0;i<n;i++){
            int j=(i+1)%n;
            float y0=ys[i],y1=ys[j];
            if((y0<=sy && sy<y1) || (y1<=sy && sy<y0))
                hits.push_back(xs[i]+(xs[j]-xs[i])*(sy-y0)/(y1-y0));
        }
        std::sort(hits.begin(),hits.end());
        for(size_t k=0;k+1<hits.size();k+=2){
            float x0=std::round(hits[k]), x1=std::round(hits[k+1]);
            if(x1>x0){ SDL_FRect rc={x0,(float)y,x1-x0,1.0f}; SDL_RenderFillRect(r,&rc); }
        }
    }
}

static void apply_clip(WinEntry& we, const SDL_Rect* rc) {
    SDL_SetRenderClipRect(we.ren, rc);
}
// Intersection of a requested clip with the innermost pushed one.
static SDL_Rect clip_isect(const WinEntry& we, SDL_Rect rc) {
    if(rc.w<0) rc.w=0;
    if(rc.h<0) rc.h=0;
    if(we.clip_stack.empty()) return rc;
    const SDL_Rect& t=we.clip_stack.back();
    int x0=std::max(rc.x,t.x), y0=std::max(rc.y,t.y);
    int x1=std::min(rc.x+rc.w,t.x+t.w), y1=std::min(rc.y+rc.h,t.y+t.h);
    return SDL_Rect{x0,y0,std::max(0,x1-x0),std::max(0,y1-y0)};
}

// Greedy word wrap of `text` at `width` pixels in `font`; '\n' always breaks.
// A word longer than a line is broken between characters (UTF-8 aware).
static std::pair<int,int> measure(int fid, TTF_Font* f, const std::string& s) {
    MeasureKey mk{fid,s};
    auto mit=g_measure_cache.find(mk);
    if(mit!=g_measure_cache.end()) return mit->second;
    int w=0,h=0;
    TTF_GetStringSize(f,s.c_str(),0,&w,&h);
    if(g_measure_cache.size()>=kMeasureCacheMax) g_measure_cache.clear();
    g_measure_cache[mk]=std::make_pair(w,h);
    return std::make_pair(w,h);
}
static std::vector<std::string> wrap_text(int fid, TTF_Font* f, const std::string& text, int width) {
    std::vector<std::string> out;
    size_t p=0;
    while(true){
        size_t nl=text.find('\n',p);
        std::string para=text.substr(p, nl==std::string::npos ? std::string::npos : nl-p);
        if(width<=0){ out.push_back(para); }
        else {
            std::string line;
            size_t i=0;
            while(i<=para.size()){
                size_t sp=para.find(' ',i);
                std::string word=para.substr(i, sp==std::string::npos ? std::string::npos : sp-i);
                std::string cand = line.empty() ? word : line + " " + word;
                if(measure(fid,f,cand).first<=width || (line.empty() && word.empty())){
                    line=cand;
                } else {
                    if(!line.empty()){ out.push_back(line); line.clear(); }
                    // the word alone may still be too long: split it
                    std::string piece;
                    size_t c=0;
                    while(c<word.size()){
                        unsigned char ch=(unsigned char)word[c];
                        size_t len= ch<0x80?1:(ch>>5)==6?2:(ch>>4)==14?3:4;
                        std::string next=piece+word.substr(c,len);
                        if(!piece.empty() && measure(fid,f,next).first>width){ out.push_back(piece); piece.clear(); continue; }
                        piece=next; c+=len;
                    }
                    line=piece;
                }
                if(sp==std::string::npos) break;
                i=sp+1;
            }
            out.push_back(line);
        }
        if(nl==std::string::npos) break;
        p=nl+1;
    }
    return out;
}

// Draws one run of text through the texture cache; returns its width.
static int draw_text_run(WinEntry& we, int fid, TTF_Font* f, const std::string& text, float x, float y, SDL_Color c) {
    if(text.empty()) return 0;
    // ── Glyph cache ────────────────────────────────────────────────
    // The IDE issues ~85 draw_text calls per frame, and previously each
    // one re-rasterised the string with TTF_RenderText_Blended and
    // re-uploaded a GPU texture, every frame, for text that rarely
    // changes. Cache by (renderer, font, colour, string) and reuse it.
    TextKey key{we.ren, fid,
                ((Uint32)c.r<<24)|((Uint32)c.g<<16)|((Uint32)c.b<<8)|(Uint32)c.a,
                text};
    TextEntry* entry=nullptr;
    auto cit=g_text_cache.find(key);
    if(cit!=g_text_cache.end()){
        entry=&cit->second;
    } else {
        SDL_Surface* surf=TTF_RenderText_Blended(f,text.c_str(),0,c);
        if(!surf) return 0;
        SDL_Texture* tex=SDL_CreateTextureFromSurface(we.ren,surf);
        int sw=surf->w, sh=surf->h;
        SDL_DestroySurface(surf);
        if(!tex) return 0;
        // Text textures have alpha — without this the text is invisible.
        SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
        // Bound the cache so long editing sessions cannot grow without limit.
        if(g_text_cache.size()>=kTextCacheMax) clear_text_cache();
        entry=&(g_text_cache[key]={tex,sw,sh});
    }
    SDL_FRect dst={x,y,(float)entry->w,(float)entry->h};
    SDL_RenderTexture(we.ren,entry->tex,nullptr,&dst);
    return entry->w;
}

static SDL_Texture* image_texture(ImgEntry& im, SDL_Renderer* ren) {
    auto it=im.tex.find(ren);
    if(it!=im.tex.end()) return it->second;
    if(!im.surf) return nullptr;
    SDL_Texture* t=SDL_CreateTextureFromSurface(ren,im.surf);
    if(t) SDL_SetTextureBlendMode(t,SDL_BLENDMODE_BLEND); // required for PNG alpha
    im.tex[ren]=t;
    return t;
}

// Everything owned by SDL's video subsystem, released before SDL_Quit.
static void release_video_objects() {
    for(auto& kv:g_cursors) if(kv.second) SDL_DestroyCursor(kv.second);
    g_cursors.clear();
    for(auto& kv:g_images){
        for(auto& t:kv.second.tex) if(t.second) SDL_DestroyTexture(t.second);
        kv.second.tex.clear();
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// DISPATCH
// ═════════════════════════════════════════════════════════════════════════════
Value dispatch_gui(NythonExecutor& E,const std::string& name,std::vector<Value>& args,Context* ctx) {
    (void)ctx;
    if(name.size()<4||name.substr(0,4)!="gui_") return UNDEFINED_VALUE;
    // NOTE: SDL is NOT initialised here — only gui_create_window triggers init.
    // This prevents SDL_Init from running at import time before a display is ready.

    // gui_get_error() -> string: surface last SDL error to Nython scripts
    if(name=="gui_get_error") return E.makeStringValue(g_sdl_error);

    // gui_ticks() -> int: milliseconds on a monotonic clock, for UI timers
    // (tooltip delays, toast lifetimes, frame pacing). It never jumps with the
    // wall clock, and it is milliseconds on both engines - the VM's time_ms()
    // becomes seconds once nytorch (imported by gui.ny) is loaded.
    if(name=="gui_ticks"){
        static const auto t0 = std::chrono::steady_clock::now();
        auto dt = std::chrono::steady_clock::now() - t0;
        return Value((int64_t)std::chrono::duration_cast<std::chrono::milliseconds>(dt).count());
    }

    // gui_sdl_version() -> string: returns SDL3 runtime version (e.g. "3.2.4")
    // Useful to confirm SDL3.dll is loaded correctly on Windows.
    if(name=="gui_sdl_version"){
        int v=SDL_GetVersion();
        int major=v/1000000, minor=(v/1000)%1000, patch=v%1000;
        return E.makeStringValue(std::to_string(major)+"."+std::to_string(minor)+"."+std::to_string(patch));
    }

    // ── WINDOW ──────────────────────────────────────────────────────────
    // gui_create_window(title, x, y, w, h, flags) -> handle
    // flags: 1 resizable, 2 borderless, 4 always on top, 8 high pixel density,
    //        16 layout units: w/h (and later min/set sizes) are the size at
    //        scale 1, and the window is made that many layout units big on
    //        whatever display it opens on - the same workbench on a 200%
    //        Windows/X11 panel (twice the points) as on a Retina Mac (the same
    //        points, twice the pixels). Events still report pixels.
    if(name=="gui_create_window"){
        if(args.size()<6){
            // Previously returned NONE silently, leaving g_sdl_error empty — which
            // made gui.ny report a phantom "SDL_CreateWindow returned NULL" failure.
            g_sdl_error = "gui_create_window() needs 6 arguments "
                          "(title, x, y, w, h, flags) but got "
                          + std::to_string(args.size());
            nython_gui_error(g_sdl_error);
            return NONE_VALUE;
        }
        if(!ensure_sdl_for_window()){
            return NONE_VALUE;
        }
        std::string title=VS(E,args[0]);
        int x=VI(args[1]),y=VI(args[2]),w=VI(args[3]),h=VI(args[4]),fl=VI(args[5]);
        // Guard against non-numeric / zero dimensions (e.g. arguments passed in the
        // wrong order). SDL3 will happily produce a 0-sized or failed window here,
        // which is very hard to diagnose from the Nython side.
        if(w<=0||h<=0){
            fprintf(stderr,"[Nython] Invalid window size %dx%d — falling back to 640x480\n",w,h);
            if(w<=0) w=640;
            if(h<=0) h=480;
        }
        // Do NOT use SDL_WINDOW_OPENGL here — that flag means "I will manage OpenGL
        // myself via SDL_GL_CreateContext". SDL_CreateRenderer manages its own context.
        // Using SDL_WINDOW_OPENGL + SDL_CreateRenderer("opengl") causes a context
        // conflict and makes rendering unreliable (text invisible, crashes).
        SDL_WindowFlags sf = 0;
        if(fl&1) sf|=SDL_WINDOW_RESIZABLE;
        if(fl&2) sf|=SDL_WINDOW_BORDERLESS;
        if(fl&4) sf|=SDL_WINDOW_ALWAYS_ON_TOP;
        // High pixel density is opt-in: the drawing surface is then in real
        // pixels (sharp on Retina/Wayland scaling) and every coordinate the
        // application sees - mouse, sizes, resize events - is in pixels too.
        // Some Windows GPU drivers refused to create such a window, so a
        // failure is retried without it rather than reported.
        SDL_Window* win=SDL_CreateWindow(title.c_str(),w,h,sf | ((fl&8) ? SDL_WINDOW_HIGH_PIXEL_DENSITY : 0));
        if(!win && (fl&8)) win=SDL_CreateWindow(title.c_str(),w,h,sf);
        if(!win){
            const char* sdl_err = SDL_GetError();
            const char* drv     = SDL_GetCurrentVideoDriver();
            std::string where = std::string(" [video driver: ")
                              + (drv && *drv ? drv : "none") + ", size "
                              + std::to_string(w) + "x" + std::to_string(h) + "]";
            g_sdl_error = (sdl_err && *sdl_err)
                ? std::string("SDL_CreateWindow failed: ") + sdl_err + where
                : std::string("SDL_CreateWindow failed with no SDL error") + where;
            nython_gui_error(g_sdl_error);
            return NONE_VALUE;
        }
        if(x>=0&&y>=0) SDL_SetWindowPosition(win,x,y);
        else           SDL_SetWindowPosition(win,SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED);
        // Try auto-select first (Direct3D 11 on Windows), fall back to software
        SDL_Renderer* ren = SDL_CreateRenderer(win, NULL);
        if(!ren){
            fprintf(stderr,"[Nython] Hardware renderer failed (%s), trying software...\n",SDL_GetError());
            ren = SDL_CreateRenderer(win, "software");
        }
        if(!ren){
            const char* sdl_err = SDL_GetError();
            g_sdl_error = (sdl_err && *sdl_err)
                ? std::string("SDL_CreateRenderer failed: ") + sdl_err
                : "SDL_CreateRenderer failed — no rendering backend available";
            nython_gui_error(g_sdl_error);
            SDL_DestroyWindow(win);
            return NONE_VALUE;
        }
        SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_BLEND);
        // VSync: optional — don't fail if unsupported
        SDL_SetRenderVSync(ren, 1);
        // Make sure the window is actually mapped and in front. Harmless when it
        // already is, but avoids an invisible window on some window managers.
        SDL_ShowWindow(win);
        SDL_RaiseWindow(win);
        // Enable text input events (SDL3: per-window)
        SDL_StartTextInput(win);
        int id=next_win_id++;
        WinEntry we;
        we.win=win; we.ren=ren; we.sdl_id=SDL_GetWindowID(win);
        we.units=(fl&16)!=0;
        if(we.units){
            float k=units_k(win);
            if(k<0.99f || k>1.01f){
                int nw=units_px(w,k), nh=units_px(h,k);
                SDL_Rect ub;
                SDL_DisplayID dsp=SDL_GetDisplayForWindow(win);
                if(dsp && SDL_GetDisplayUsableBounds(dsp,&ub) && ub.w>0 && ub.h>0){
                    if(nw>ub.w) nw=ub.w;
                    if(nh>ub.h) nh=ub.h;
                }
                SDL_SetWindowSize(win,nw,nh);
                if(x<0||y<0) SDL_SetWindowPosition(win,SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED);
                SDL_SyncWindow(win);
            }
        }
        g_windows[id]=we;
        // The drawing surface can differ from the size asked for (a HiDPI
        // window in pixels, or a window manager that clamped it); tell the
        // application straight away instead of letting it lay out for a size
        // it does not have.
        int ow=0, oh=0;
        output_size(g_windows[id],ow,oh);
        g_windows[id].last_w=ow; g_windows[id].last_h=oh;
        if(ow!=w || oh!=h){
            EvData d; d.type="resize"; d.w=ow; d.h=oh; d.window=id;
            g_evq.push_back(d);
        }
        return Value(id);
    }
    // gui_display_scale() -> float.  Content scale of the primary display: 1.0
    // on a standard monitor, 2.0 on a Retina/4K panel.
    // ── Immediate-mode ID hashing ────────────────────────────────────────────
    // Dear ImGui derives a widget's identity from a hash of its label combined
    // with the enclosing ID stack, so a widget needs no persistent object — the
    // ID alone locates its state. That hash runs for EVERY widget EVERY frame,
    // so it is the one piece of the IM core that must not be interpreted.
    //
    // ImGui uses CRC32 with a seed; this uses FNV-1a 32-bit, which has the same
    // properties that matter here (good avalanche on short ASCII labels, seed
    // chaining for the ID stack) and needs no lookup table.
    //
    //   gui_hash_id(label)          -> id
    //   gui_hash_id(label, seed)    -> id chained under a parent scope
    //
    // ImGui's "###" convention is honoured: everything before it is display
    // text and is excluded from the hash, so a button whose caption changes
    // every frame ("Frame 12###status") keeps a stable identity.
    if(name=="gui_hash_id"){
        if(args.empty()) return Value((int64_t)0);
        std::string s0 = VS(E,args[0]);
        uint32_t seed = args.size()>=2 ? (uint32_t)VI(args[1]) : 0u;
        size_t start = 0;
        size_t hh = s0.find("###");
        if(hh != std::string::npos) start = hh;          // hash from ### onward
        uint32_t h = seed ? seed : 2166136261u;
        for(size_t i=start;i<s0.size();++i){
            h ^= (uint32_t)(unsigned char)s0[i];
            h *= 16777619u;
        }
        // "##" hides the suffix from display but keeps it in the hash, which is
        // already the case here since the whole string is hashed.
        return Value((int64_t)(h & 0x7fffffffu));
    }

    // gui_video_driver() -> the SDL video driver in use ("windows", "x11",
    // "wayland", "cocoa", "offscreen", ...; "ny-stub" for the headless stub),
    // "" when there is no video.
    if(name=="gui_video_driver"){
        const char* d = ensure_sdl_for_window() ? SDL_GetCurrentVideoDriver() : nullptr;
        return E.makeStringValue(d ? d : "");
    }
    if(name=="gui_display_scale"){
        float sc = 1.0f;
        SDL_DisplayID d = SDL_GetPrimaryDisplay();
        if(d){
            float q = SDL_GetDisplayContentScale(d);
            if(q > 0.0f) sc = q;
        }
        return Value((double)sc);
    }

    // gui_window_scale([handle]) -> float.  Per-window scale, which can differ
    // from the primary display's when a window is dragged to a second monitor.
    if(name=="gui_window_scale"){
        float sc = 1.0f;
        int wid = args.empty() ? -1 : VI(args[0]);
        SDL_Window* w = nullptr;
        if(wid >= 0){
            auto it = g_windows.find(wid);
            if(it != g_windows.end()) w = it->second.win;
        } else if(!g_windows.empty()){
            w = g_windows.begin()->second.win;
        }
        if(w){
            float q = SDL_GetWindowDisplayScale(w);
            if(q > 0.0f) sc = q;
        }
        return Value((double)sc);
    }

    // gui_set_cursor(name) -> bool.  Named system cursors, created lazily and
    // cached until the last window closes. "hidden" hides the pointer; any
    // other name shows it again.
    if(name=="gui_set_cursor"){
        if(args.empty()) return Value(false);
        std::string want = VS(E,args[0]);
        if(want=="hidden" || want=="none"){
            if(!g_cursor_hidden){ SDL_HideCursor(); g_cursor_hidden=true; }
            return Value(true);
        }
        static const std::unordered_map<std::string, SDL_SystemCursor> kMap = {
            {"arrow",   SDL_SYSTEM_CURSOR_DEFAULT},
            {"default", SDL_SYSTEM_CURSOR_DEFAULT},
            {"ibeam",   SDL_SYSTEM_CURSOR_TEXT},
            {"text",    SDL_SYSTEM_CURSOR_TEXT},
            {"hand",    SDL_SYSTEM_CURSOR_POINTER},
            {"pointer", SDL_SYSTEM_CURSOR_POINTER},
            {"wait",    SDL_SYSTEM_CURSOR_WAIT},
            {"progress",SDL_SYSTEM_CURSOR_PROGRESS},
            {"crosshair",SDL_SYSTEM_CURSOR_CROSSHAIR},
            {"sizewe",  SDL_SYSTEM_CURSOR_EW_RESIZE},
            {"sizens",  SDL_SYSTEM_CURSOR_NS_RESIZE},
            {"sizenwse",SDL_SYSTEM_CURSOR_NWSE_RESIZE},
            {"sizenesw",SDL_SYSTEM_CURSOR_NESW_RESIZE},
            {"move",    SDL_SYSTEM_CURSOR_MOVE},
            {"no",      SDL_SYSTEM_CURSOR_NOT_ALLOWED}
        };
        auto mit = kMap.find(want);
        if(mit == kMap.end()) return Value(false);
        int key = (int)mit->second;
        auto cit = g_cursors.find(key);
        SDL_Cursor* cur = nullptr;
        if(cit != g_cursors.end()) cur = cit->second;
        else { cur = SDL_CreateSystemCursor(mit->second); if(cur) g_cursors[key] = cur; }
        if(!cur) return Value(false);
        SDL_SetCursor(cur);
        if(g_cursor_hidden){ SDL_ShowCursor(); g_cursor_hidden=false; }
        return Value(true);
    }
    // ── System clipboard ────────────────────────────────────────────────
    // gui_set_clipboard(text) -> bool, gui_get_clipboard() -> string.
    // The IDE kept its clipboard in a Nython string, so Copy inside the
    // editor could never be pasted into another application and vice versa.
    if(name=="gui_set_clipboard"){
        if(args.empty() || !g_sdl_ok) return Value(false);
        return Value(SDL_SetClipboardText(VS(E,args[0]).c_str()));
    }
    if(name=="gui_get_clipboard"){
        if(!g_sdl_ok) return E.makeStringValue("");
        char* txt = SDL_GetClipboardText();
        std::string out = txt ? txt : "";
        if(txt) SDL_free(txt);
        return E.makeStringValue(out);
    }
    if(name=="gui_get_display_size"){
        // Returns [w,h] of the usable primary display area, so callers can size
        // a window that actually fits the screen. Without this the IDE asked for
        // a fixed 1600x960 window, which Windows silently clamped on a smaller
        // display while the layout kept drawing at the unclamped size.
        int dw=0, dh=0;
        if(ensure_sdl_for_window()){
            SDL_DisplayID d = SDL_GetPrimaryDisplay();
            SDL_Rect r;
            if(d && SDL_GetDisplayUsableBounds(d,&r)){ dw=r.w; dh=r.h; }
            else if(d && SDL_GetDisplayBounds(d,&r)){ dw=r.w; dh=r.h; }
        }
        if(dw<=0||dh<=0){ dw=1280; dh=720; }
        return make_int_list(E,{dw,dh});
    }
    // gui_get_window_size(handle) -> [w, h] of the drawing surface (pixels for
    // a high-pixel-density window, the same as the window size otherwise).
    if(name=="gui_get_window_size"){
        int ww=0, hh=0;
        if(WinEntry* we=win_of(args)) output_size(*we,ww,hh);
        return make_int_list(E,{ww,hh});
    }
    // A layout-unit window (flag 16) takes both sizes in layout units.
    if(name=="gui_set_window_size"){
        if(args.size()>=3){ if(WinEntry* we=win_of(args)){
            float k = we->units ? units_k(we->win) : 1.0f;
            SDL_SetWindowSize(we->win,units_px(VI(args[1]),k),units_px(VI(args[2]),k));
        } }
        return NONE_VALUE;
    }
    // gui_set_min_size(handle, w, h): the window cannot be resized smaller.
    if(name=="gui_set_min_size"){
        if(args.size()>=3){ if(WinEntry* we=win_of(args)){
            float k = we->units ? units_k(we->win) : 1.0f;
            we->min_uw=VI(args[1]); we->min_uh=VI(args[2]);
            return Value(SDL_SetWindowMinimumSize(we->win,units_px(we->min_uw,k),units_px(we->min_uh,k)));
        } }
        return Value(false);
    }
    // gui_display_density() -> pixels per point a high-density window gets on
    // the primary display (2.0 on a Retina Mac or a 200% Wayland output, 1.0
    // on Windows and X11, whose points are pixels). Times gui_display_scale()
    // it predicts a window's display scale - the factor to draw at - before
    // the window exists; the window's own "scale" event corrects it.
    if(name=="gui_display_density"){
        float pd = 1.0f;
        if(ensure_sdl_for_window()){
            const SDL_DisplayMode* m = SDL_GetDesktopDisplayMode(SDL_GetPrimaryDisplay());
            if(m && m->pixel_density > 0.0f) pd = m->pixel_density;
        }
        return Value((double)pd);
    }
    // gui_set_fullscreen(handle, on) -> bool ; gui_is_fullscreen(handle) -> bool
    if(name=="gui_set_fullscreen"){
        if(args.size()>=2){ if(WinEntry* we=win_of(args)) return Value(SDL_SetWindowFullscreen(we->win,VI(args[1])!=0)); }
        return Value(false);
    }
    if(name=="gui_is_fullscreen"){
        if(WinEntry* we=win_of(args)) return Value((SDL_GetWindowFlags(we->win) & SDL_WINDOW_FULLSCREEN)!=0);
        return Value(false);
    }
    if(name=="gui_destroy_window"){
        if(args.empty()) return NONE_VALUE;
        auto it=g_windows.find(VI(args[0]));
        if(it!=g_windows.end()){
            SDL_StopTextInput(it->second.win);
            // Textures belong to this renderer — destroy them BEFORE the
            // renderer goes away, otherwise they become dangling pointers.
            clear_text_cache(it->second.ren);
            for(auto& kv:g_images){
                auto t=kv.second.tex.find(it->second.ren);
                if(t!=kv.second.tex.end()){ if(t->second) SDL_DestroyTexture(t->second); kv.second.tex.erase(t); }
            }
            SDL_DestroyRenderer(it->second.ren);
            SDL_DestroyWindow(it->second.win);
            int gone=it->first;
            g_windows.erase(it);
            for(auto q=g_evq.begin(); q!=g_evq.end();) q = q->window==gone ? g_evq.erase(q) : q+1;
            if(g_windows.empty()){
                release_video_objects();
                g_evq.clear();
                SDL_Quit(); g_sdl_inited=false; g_sdl_ok=false; g_dialog_event=0;
            }
        }
        return NONE_VALUE;
    }
    if(name=="gui_center_window"){
        if(WinEntry* we=win_of(args)) SDL_SetWindowPosition(we->win,SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED);
        return NONE_VALUE;
    }
    if(name=="gui_maximize_window"){ if(WinEntry* we=win_of(args)) SDL_MaximizeWindow(we->win); return NONE_VALUE; }
    if(name=="gui_minimize_window"){ if(WinEntry* we=win_of(args)) SDL_MinimizeWindow(we->win); return NONE_VALUE; }
    if(name=="gui_restore_window") { if(WinEntry* we=win_of(args)) SDL_RestoreWindow(we->win);  return NONE_VALUE; }
    if(name=="gui_set_window_title"){
        if(args.size()>=2){ if(WinEntry* we=win_of(args)) SDL_SetWindowTitle(we->win,VS(E,args[1]).c_str()); }
        return NONE_VALUE;
    }
    // gui_set_window_icon(handle, image_handle) -> bool
    if(name=="gui_set_window_icon"){
        if(args.size()<2) return Value(false);
        WinEntry* we=win_of(args);
        auto iit=g_images.find(VI(args[1]));
        if(!we || iit==g_images.end() || !iit->second.surf) return Value(false);
        return Value(SDL_SetWindowIcon(we->win, iit->second.surf));
    }
    // gui_set_text_input_area(handle, x, y, w, h, cursor_x): where the text
    // being edited is, so the IME puts its candidate window next to it.
    if(name=="gui_set_text_input_area"){
        if(args.size()<5) return Value(false);
        WinEntry* we=win_of(args);
        if(!we) return Value(false);
        // Arguments are in drawing coordinates; SDL wants window coordinates.
        int ow=0,oh=0,ww=0,wh=0;
        output_size(*we,ow,oh);
        SDL_GetWindowSize(we->win,&ww,&wh);
        float sx = ow>0 ? (float)ww/(float)ow : 1.0f;
        float sy = oh>0 ? (float)wh/(float)oh : 1.0f;
        SDL_Rect rc={(int)(OX(we,args[1])*sx),(int)(OY(we,args[2])*sy),(int)(VF(args[3])*sx),(int)(VF(args[4])*sy)};
        int cursor = args.size()>=6 ? (int)(VF(args[5])*sx) : 0;   // relative to the rect
        return Value(SDL_SetTextInputArea(we->win,&rc,cursor));
    }

    // gui_show_open_dialog(handle, title, default_path, folder) -> bool
    // gui_show_save_dialog(handle, title, default_path) -> bool
    // The native dialog runs without blocking; its answer arrives later as a
    // {type: "dialog", text: path or "" if cancelled} event. The title is not
    // passed to SDL: the plain dialog calls, available in every SDL 3.2, take
    // none, and the platform supplies its own.
    if(name=="gui_show_open_dialog" || name=="gui_show_save_dialog"){
        WinEntry* we=win_of(args);
        if(!we || !g_dialog_event) return Value(false);
        std::string def = args.size()>=3 ? VS(E,args[2]) : "";
        const char* loc = def.empty() ? nullptr : def.c_str();
        void* ud=(void*)(uintptr_t)we->sdl_id;
        if(name=="gui_show_save_dialog")
            SDL_ShowSaveFileDialog(dialog_done, ud, we->win, nullptr, 0, loc);
        else if(args.size()>=4 && VI(args[3])!=0)
            SDL_ShowOpenFolderDialog(dialog_done, ud, we->win, loc, false);
        else
            SDL_ShowOpenFileDialog(dialog_done, ud, we->win, nullptr, 0, loc, false);
        return Value(true);
    }

    // ── RENDERING ───────────────────────────────────────────────────────
    if(name=="gui_clear"){
        if(args.size()<5) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){SDL_SetRenderDrawColor(we->ren,VU(args[1]),VU(args[2]),VU(args[3]),VU(args[4]));SDL_RenderClear(we->ren);}
        return NONE_VALUE;
    }
    if(name=="gui_present"){
        if(WinEntry* we=win_of(args)){
            // A frame ends here: clips pushed and never popped do not leak
            // into the next one.
            if(!we->clip_stack.empty()){ we->clip_stack.clear(); apply_clip(*we,nullptr); }
            we->off_stack.clear(); we->ox=0; we->oy=0;
            SDL_RenderPresent(we->ren);
        }
        return NONE_VALUE;
    }
    // gui_fill_rect(handle, x, y, w, h, r, g, b, a)
    if(name=="gui_fill_rect"){
        if(args.size()<9) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            SDL_FRect rc={OX(we,args[1]),OY(we,args[2]),VF(args[3]),VF(args[4])};
            SDL_SetRenderDrawColor(we->ren,VU(args[5]),VU(args[6]),VU(args[7]),VU(args[8]));
            SDL_SetRenderDrawBlendMode(we->ren,SDL_BLENDMODE_BLEND);
            SDL_RenderFillRect(we->ren,&rc);
        }
        return NONE_VALUE;
    }
    // gui_draw_rect(handle, x, y, w, h, r, g, b, a, border_w)
    if(name=="gui_draw_rect"){
        if(args.size()<10) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            SDL_SetRenderDrawColor(we->ren,VU(args[5]),VU(args[6]),VU(args[7]),VU(args[8]));
            int bw=std::max(1,VI(args[9]));
            for(int i=0;i<bw;i++){SDL_FRect r2={OX(we,args[1])+(float)i,OY(we,args[2])+(float)i,VF(args[3])-2.0f*i,VF(args[4])-2.0f*i};SDL_RenderRect(we->ren,&r2);}
        }
        return NONE_VALUE;
    }
    // gui_fill_rounded_rect(handle, x, y, w, h, r, g, b, a, radius)
    if(name=="gui_fill_rounded_rect"){
        if(args.size()<10) return NONE_VALUE;
        if(WinEntry* we=win_of(args)) fill_rounded_rect(we->ren,OX(we,args[1]),OY(we,args[2]),VF(args[3]),VF(args[4]),VF(args[9]),VU(args[5]),VU(args[6]),VU(args[7]),VU(args[8]));
        return NONE_VALUE;
    }
    // gui_draw_rounded_rect(handle, x, y, w, h, r, g, b, a, radius, border_w)
    if(name=="gui_draw_rounded_rect"){
        if(args.size()<10) return NONE_VALUE;
        int bw = args.size()>=11 ? VI(args[10]) : 1;
        if(WinEntry* we=win_of(args)) draw_rounded_rect(we->ren,OX(we,args[1]),OY(we,args[2]),VF(args[3]),VF(args[4]),VF(args[9]),VU(args[5]),VU(args[6]),VU(args[7]),VU(args[8]),bw);
        return NONE_VALUE;
    }
    // gui_draw_arc(handle, cx, cy, r_inner, r_outer, start_deg, end_deg, r, g, b, a)
    // A filled annular sector; r_inner 0 is a pie slice. Angles in degrees,
    // 0 at 3 o'clock, increasing clockwise.
    if(name=="gui_draw_arc"){
        if(args.size()<11) return NONE_VALUE;
        if(WinEntry* we=win_of(args)) fill_arc(we->ren,OX(we,args[1]),OY(we,args[2]),VF(args[3]),VF(args[4]),VF(args[5]),VF(args[6]),VU(args[7]),VU(args[8]),VU(args[9]),VU(args[10]));
        return NONE_VALUE;
    }
    // gui_draw_text(handle, text, x, y, font_handle, r, g, b, a) -> width drawn
    if(name=="gui_draw_text"){
        if(args.size()<9) return NONE_VALUE;
        WinEntry* we=win_of(args);
        auto fit=g_fonts.find(VI(args[4]));
        if(we&&fit!=g_fonts.end()){
            SDL_Color c={VU(args[5]),VU(args[6]),VU(args[7]),VU(args[8])};
            draw_text_run(*we,VI(args[4]),fit->second,VS(E,args[1]),OX(we,args[2]),OY(we,args[3]),c);
        }
        return NONE_VALUE;
    }
    // gui_draw_text_wrapped(handle, text, x, y, font, r, g, b, a, width [, line_h])
    //   -> height used. Word-wraps at `width` pixels; '\n' always breaks.
    if(name=="gui_draw_text_wrapped"){
        if(args.size()<10) return Value(0);
        WinEntry* we=win_of(args);
        auto fit=g_fonts.find(VI(args[4]));
        if(!we||fit==g_fonts.end()) return Value(0);
        int fid=VI(args[4]);
        int lh = args.size()>=11 ? VI(args[10]) : 0;
        if(lh<=0) lh=TTF_GetFontLineSkip(fit->second);
        if(lh<=0) lh=measure(fid,fit->second,"Ag").second;
        SDL_Color c={VU(args[5]),VU(args[6]),VU(args[7]),VU(args[8])};
        auto lines=wrap_text(fid,fit->second,VS(E,args[1]),VI(args[9]));
        float y=OY(we,args[3]);
        for(auto& ln:lines){ draw_text_run(*we,fid,fit->second,ln,OX(we,args[2]),y,c); y+=(float)lh; }
        return Value((int)lines.size()*lh);
    }
    // gui_wrap_text(font, text, width) -> list of lines
    if(name=="gui_wrap_text"){
        if(args.size()<3 || !g_sdl_ok) return make_str_list(E,{});
        auto fit=g_fonts.find(VI(args[0]));
        if(fit==g_fonts.end()) return make_str_list(E,{});
        return make_str_list(E,wrap_text(VI(args[0]),fit->second,VS(E,args[1]),VI(args[2])));
    }
    // gui_font_metrics(font) -> [height, ascent, descent, line_skip]
    if(name=="gui_font_metrics"){
        if(args.empty() || !g_sdl_ok) return NONE_VALUE;
        auto fit=g_fonts.find(VI(args[0]));
        if(fit==g_fonts.end()) return NONE_VALUE;
        TTF_Font* f=fit->second;
        return make_int_list(E,{TTF_GetFontHeight(f),TTF_GetFontAscent(f),TTF_GetFontDescent(f),TTF_GetFontLineSkip(f)});
    }
    // gui_draw_image(handle, image_handle, x, y, w, h)
    if(name=="gui_draw_image"){
        if(args.size()<6) return NONE_VALUE;
        WinEntry* we=win_of(args);
        auto iit=g_images.find(VI(args[1]));
        if(we&&iit!=g_images.end()){
            SDL_Texture* t=image_texture(iit->second,we->ren);
            if(t){
                SDL_FRect dst={OX(we,args[2]),OY(we,args[3]),VF(args[4]),VF(args[5])};
                SDL_RenderTexture(we->ren,t,nullptr,&dst);
            }
        }
        return NONE_VALUE;
    }
    // gui_draw_line(handle, x1, y1, x2, y2, r, g, b, a, thickness)
    if(name=="gui_draw_line"){
        if(args.size()<10) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            SDL_SetRenderDrawColor(we->ren,VU(args[5]),VU(args[6]),VU(args[7]),VU(args[8]));
            SDL_SetRenderDrawBlendMode(we->ren,SDL_BLENDMODE_BLEND);
            float x1=OX(we,args[1]),y1=OY(we,args[2]),x2=OX(we,args[3]),y2=OY(we,args[4]);
            int thick=std::max(1,VI(args[9]));
            float dx=x2-x1, dy=y2-y1;
            float len=std::sqrt(dx*dx+dy*dy);
            if(thick==1 || len<=0){
                SDL_RenderLine(we->ren,x1,y1,x2,y2);
            } else {
                // `thick` parallel lines centred on the requested one, offset
                // perpendicular to it (an even thickness used to draw one
                // line too many).
                float nx=-dy/len, ny=dx/len;
                for(int t=0;t<thick;t++){
                    float o=(float)t-(float)(thick-1)/2.0f;
                    SDL_RenderLine(we->ren,x1+nx*o,y1+ny*o,x2+nx*o,y2+ny*o);
                }
            }
        }
        return NONE_VALUE;
    }
    // gui_draw_circle(handle, cx, cy, radius, r, g, b, a)
    if(name=="gui_draw_circle"){
        if(args.size()<8) return NONE_VALUE;
        if(WinEntry* we=win_of(args)) draw_circle_sdl(we->ren,OX(we,args[1]),OY(we,args[2]),VF(args[3]),VU(args[4]),VU(args[5]),VU(args[6]),VU(args[7]));
        return NONE_VALUE;
    }
    // gui_fill_circle(handle, cx, cy, radius, r, g, b, a)
    if(name=="gui_fill_circle"){
        if(args.size()<8) return NONE_VALUE;
        if(WinEntry* we=win_of(args)) fill_circle_sdl(we->ren,OX(we,args[1]),OY(we,args[2]),VF(args[3]),VU(args[4]),VU(args[5]),VU(args[6]),VU(args[7]));
        return NONE_VALUE;
    }
    // gui_draw_shadow(handle, x, y, w, h, blur, ox, oy, r, g, b, a)
    if(name=="gui_draw_shadow"){
        if(args.size()<12) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            float x=OX(we,args[1])+VF(args[6]),y=OY(we,args[2])+VF(args[7]),w=VF(args[3]),h=VF(args[4]);
            int blur=std::max(1,VI(args[5]));
            Uint8 sr=VU(args[8]),sg=VU(args[9]),sb=VU(args[10]),sa=VU(args[11]);
            SDL_SetRenderDrawBlendMode(we->ren,SDL_BLENDMODE_BLEND);
            // Layer from outermost (most transparent) inward (most opaque)
            // alpha = sa * (1 - i/blur)^2  (quadratic falloff outward)
            for(int i=blur;i>0;i--){
                float t=(float)(blur-i)/(float)blur; // 0 at edge, 1 at centre
                Uint8 alpha=(Uint8)(sa*(1.0f-t*t)*0.7f);
                SDL_SetRenderDrawColor(we->ren,sr,sg,sb,alpha);
                SDL_FRect rc={x-(float)i,y-(float)i,w+2.0f*i,h+2.0f*i};
                SDL_RenderFillRect(we->ren,&rc);
            }
        }
        return NONE_VALUE;
    }
    // gui_draw_gradient(handle, x, y, w, h, r1, g1, b1, r2, g2, b2, vertical [, a1, a2])
    if(name=="gui_draw_gradient"){
        if(args.size()<12) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            float x=OX(we,args[1]),y=OY(we,args[2]),w=VF(args[3]),h=VF(args[4]);
            int r1=VI(args[5]),g1=VI(args[6]),b1=VI(args[7]),r2=VI(args[8]),g2=VI(args[9]),b2=VI(args[10]);
            bool vert=VI(args[11])!=0; int steps=vert?(int)h:(int)w; if(steps<1)steps=1;
            // Optional trailing alpha pair (a1, a2). Without it the gradient
            // was always opaque, so a translucent "gloss" highlight painted a
            // solid white slab over the IDE's Run button.
            int a1=args.size()>=13?VI(args[12]):255, a2=args.size()>=14?VI(args[13]):255;
            SDL_SetRenderDrawBlendMode(we->ren,SDL_BLENDMODE_BLEND);
            for(int i=0;i<steps;i++){
                float t=(float)i/(float)steps;
                SDL_SetRenderDrawColor(we->ren,(Uint8)(r1+t*(r2-r1)),(Uint8)(g1+t*(g2-g1)),(Uint8)(b1+t*(b2-b1)),(Uint8)(a1+t*(a2-a1)));
                if(vert) SDL_RenderLine(we->ren,x,y+(float)i,x+w,y+(float)i);
                else     SDL_RenderLine(we->ren,x+(float)i,y,x+(float)i,y+h);
            }
        }
        return NONE_VALUE;
    }
    // gui_draw_polygon(handle, points_list, n, r, g, b, a)
    // gui_fill_polygon(handle, points_list, n, r, g, b, a)
    // points_list = [[x0,y0],[x1,y1],...]  or flat [x0,y0,x1,y1,...]
    if(name=="gui_draw_polygon"||name=="gui_fill_polygon"){
        if(args.size()<7) return NONE_VALUE;
        WinEntry* we=win_of(args);
        if(we&&args[1].isCollectable()&&args[1].value.gc){
            auto* pts=dynamic_cast<Container*>(args[1].value.gc);
            if(pts&&pts->container){
                int n=VI(args[2]);
                SDL_SetRenderDrawColor(we->ren,VU(args[3]),VU(args[4]),VU(args[5]),VU(args[6]));
                SDL_SetRenderDrawBlendMode(we->ren,SDL_BLENDMODE_BLEND);
                std::vector<float> xs,ys;
                auto p0=pts->container->find("0");
                bool flat = p0!=pts->container->end() && !p0->second.isCollectable();
                for(int i=0;i<n;i++){
                    if(flat){
                        auto xi=pts->container->find(std::to_string(2*i));
                        auto yi=pts->container->find(std::to_string(2*i+1));
                        if(xi==pts->container->end()||yi==pts->container->end()) break;
                        xs.push_back(VF(xi->second)+we->ox); ys.push_back(VF(yi->second)+we->oy);
                        continue;
                    }
                    auto pi=pts->container->find(std::to_string(i));
                    if(pi!=pts->container->end()&&pi->second.isCollectable()&&pi->second.value.gc){
                        auto* p=dynamic_cast<Container*>(pi->second.value.gc);
                        if(p&&p->container){
                            float px=0,py=0;
                            auto x0=p->container->find("0"); if(x0!=p->container->end()) px=VF(x0->second);
                            auto y0=p->container->find("1"); if(y0!=p->container->end()) py=VF(y0->second);
                            xs.push_back(px+we->ox); ys.push_back(py+we->oy);
                        }
                    }
                }
                int np=(int)xs.size();
                if(name=="gui_draw_polygon"){
                    for(int i=0;i<np;i++){
                        int j=(i+1)%np;
                        SDL_RenderLine(we->ren,xs[i],ys[i],xs[j],ys[j]);
                    }
                } else {
                    fill_polygon_sdl(we->ren,xs,ys);
                }
            }
        }
        return NONE_VALUE;
    }
    // gui_set_clip(handle, x, y, w, h) — inside a pushed clip, the result is
    // the intersection with it.
    if(name=="gui_set_clip"){
        if(args.size()<5) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            SDL_Rect rc=clip_isect(*we,SDL_Rect{(int)std::lround(OX(we,args[1])),(int)std::lround(OY(we,args[2])),VI(args[3]),VI(args[4])});
            apply_clip(*we,&rc);
        }
        return NONE_VALUE;
    }
    // gui_clear_clip(handle) — back to the innermost pushed clip, if any.
    // Widgets clear their own clip when they finish drawing; before the clip
    // stack that also removed the clip of the container they were drawn in.
    if(name=="gui_clear_clip"){
        if(WinEntry* we=win_of(args)){
            if(we->clip_stack.empty()) apply_clip(*we,nullptr);
            else apply_clip(*we,&we->clip_stack.back());
        }
        return NONE_VALUE;
    }
    // gui_push_clip(handle, x, y, w, h) / gui_pop_clip(handle): nested clips.
    if(name=="gui_push_clip"){
        if(args.size()<5) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            SDL_Rect rc=clip_isect(*we,SDL_Rect{(int)std::lround(OX(we,args[1])),(int)std::lround(OY(we,args[2])),VI(args[3]),VI(args[4])});
            we->clip_stack.push_back(rc);
            apply_clip(*we,&rc);
            return Value((int)we->clip_stack.size());
        }
        return NONE_VALUE;
    }
    if(name=="gui_pop_clip"){
        if(WinEntry* we=win_of(args)){
            if(!we->clip_stack.empty()) we->clip_stack.pop_back();
            if(we->clip_stack.empty()) apply_clip(*we,nullptr);
            else apply_clip(*we,&we->clip_stack.back());
            return Value((int)we->clip_stack.size());
        }
        return NONE_VALUE;
    }
    // gui_push_offset(handle, dx, dy) / gui_pop_offset(handle): shift all
    // drawing (and clip rects) by (dx, dy), cumulatively. A scroll container
    // pushes (-scroll_x, -scroll_y) and draws its children where they are.
    if(name=="gui_push_offset"){
        if(args.size()<3) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            we->off_stack.push_back(std::make_pair(we->ox,we->oy));
            we->ox+=VF(args[1]); we->oy+=VF(args[2]);
            return Value((int)we->off_stack.size());
        }
        return NONE_VALUE;
    }
    if(name=="gui_pop_offset"){
        if(WinEntry* we=win_of(args)){
            if(!we->off_stack.empty()){
                we->ox=we->off_stack.back().first; we->oy=we->off_stack.back().second;
                we->off_stack.pop_back();
            } else { we->ox=0; we->oy=0; }
            return Value((int)we->off_stack.size());
        }
        return NONE_VALUE;
    }
    // gui_set_viewport(handle, x, y, w, h) — shifts render origin + clips
    if(name=="gui_set_viewport"){
        if(args.size()<5) return NONE_VALUE;
        if(WinEntry* we=win_of(args)){
            SDL_Rect rc={VI(args[1]),VI(args[2]),VI(args[3]),VI(args[4])};
            SDL_SetRenderViewport(we->ren,&rc);
        }
        return NONE_VALUE;
    }
    // gui_clear_viewport(handle) — restore full viewport
    if(name=="gui_clear_viewport"){
        if(WinEntry* we=win_of(args)) SDL_SetRenderViewport(we->ren,nullptr);
        return NONE_VALUE;
    }

    // ── FONTS ───────────────────────────────────────────────────────────
    // gui_load_font(family, size [, bold, italic]) -> handle
    // GUARD: only call TTF_OpenFont if TTF is initialized (after gui_create_window).
    // Called before SDL init (e.g. from Font.__init__ at class-definition time)
    // silently returns NONE so Font.ensure_loaded() can retry later.
    if(name=="gui_load_font"){
        if(args.size()<2) return NONE_VALUE;
        if(!g_sdl_ok) return NONE_VALUE;  // TTF not initialized — retry later via ensure_loaded()
        std::string family=VS(E,args[0]); int size=VI(args[1]);
        bool bold   = args.size()>=3 && VI(args[2])!=0;
        bool italic = args.size()>=4 && VI(args[3])!=0;
        std::vector<std::string> paths;
        // Try the family as a literal path first, so an application can ship its
        // own font — Font("assets/fonts/codicon.ttf", 16, ...). Without this the
        // family was only ever matched against a fixed list of system font
        // names, and a bundled font could not be loaded at all.
        if(family.size()>4){
            std::string tail=family.substr(family.size()-4);
            for(auto& c:tail) c=(char)tolower((unsigned char)c);
            if(tail==".ttf"||tail==".otf"||tail==".ttc") paths.push_back(family);
        }
        bool mono = family=="monospace"||family=="mono"||family=="Consolas"||family=="Menlo";
#ifdef _WIN32
        // %WINDIR%\Fonts: Windows is not always on C:.
        std::string fd = "C:\\Windows";
        if(const char* wd=getenv("WINDIR")) fd=wd; else if(const char* sr=getenv("SystemRoot")) fd=sr;
        fd += "\\Fonts\\";
        if(bold && mono) paths.push_back(fd+"consolab.ttf");
        if(mono) { paths.push_back(fd+"consola.ttf"); paths.push_back(fd+"cour.ttf"); }
        if(bold) paths.push_back(fd+"segoeuib.ttf");
        paths.push_back(fd+"segoeui.ttf");
        if(bold) paths.push_back(fd+"arialbd.ttf");
        paths.push_back(fd+"arial.ttf");
        paths.push_back(fd+"tahoma.ttf");
#elif defined(__APPLE__)
        if(mono){
            paths.push_back("/System/Library/Fonts/SFNSMono.ttf");
            paths.push_back("/System/Library/Fonts/Menlo.ttc");
            paths.push_back("/System/Library/Fonts/Monaco.ttf");
        }
        paths.push_back("/System/Library/Fonts/SFNS.ttf");
        paths.push_back("/System/Library/Fonts/Helvetica.ttc");
        paths.push_back("/System/Library/Fonts/Supplemental/Arial.ttf");
        paths.push_back("/Library/Fonts/Arial.ttf");
#else
        // Debian/Ubuntu, then Arch and Fedora layouts.
        static const char* kDirs[] = {"/usr/share/fonts/truetype/dejavu/", "/usr/share/fonts/TTF/",
                                      "/usr/share/fonts/dejavu-sans-fonts/", "/usr/share/fonts/dejavu-sans-mono-fonts/",
                                      "/usr/share/fonts/dejavu/"};
        if(mono){
            for(const char* d:kDirs){ if(bold) paths.push_back(std::string(d)+"DejaVuSansMono-Bold.ttf"); paths.push_back(std::string(d)+"DejaVuSansMono.ttf"); }
            paths.push_back("/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf");
        }
        for(const char* d:kDirs){ if(bold) paths.push_back(std::string(d)+"DejaVuSans-Bold.ttf"); paths.push_back(std::string(d)+"DejaVuSans.ttf"); }
        if(bold) paths.push_back("/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf");
        paths.push_back("/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf");
        paths.push_back("/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf");
        paths.push_back("/usr/share/fonts/truetype/freefont/FreeSans.ttf");
#endif
        paths.insert(paths.begin(),family);
        TTF_Font* font=nullptr;
        for(auto& p:paths){font=TTF_OpenFont(p.c_str(),(float)size);if(font)break;}
        if(!font) return NONE_VALUE;
        int style = TTF_STYLE_NORMAL;
        if(bold)   style |= TTF_STYLE_BOLD;
        if(italic) style |= TTF_STYLE_ITALIC;
        if(style != TTF_STYLE_NORMAL) TTF_SetFontStyle(font, (TTF_FontStyleFlags)style);
        int id=next_font_id++; g_fonts[id]=font;
        return Value(id);
    }
    // gui_measure_text_w(font_handle, text) -> w
    // Same metrics as gui_measure_text but returns a plain number. The list
    // form allocates an Object per call, and callers that only need the width
    // (caret placement, selection spans, right-aligned labels, tab widths) were
    // paying that on every draw call of every frame.
    if(name=="gui_measure_text_w"){
        if(args.size()<2) return Value(0);
        if(!g_sdl_ok) return Value(0);
        auto fit=g_fonts.find(VI(args[0]));if(fit==g_fonts.end()) return Value(0);
        return Value(measure(VI(args[0]),fit->second,VS(E,args[1])).first);
    }

    // gui_measure_text(font_handle, text) -> [w, h]
    if(name=="gui_measure_text"){
        if(args.size()<2) return NONE_VALUE;
        if(!g_sdl_ok) return NONE_VALUE;  // TTF not initialized
        auto fit=g_fonts.find(VI(args[0]));if(fit==g_fonts.end()) return NONE_VALUE;
        // Metrics for a given (font, string) never change, but UI code calls this
        // once per text run per frame for layout, so it is memoised.
        auto wh=measure(VI(args[0]),fit->second,VS(E,args[1]));
        auto* lst=new Object((Runnable*)E.runner,"measure",Type::LIST);
        lst->set("0",Value(wh.first)); lst->set("1",Value(wh.second)); lst->set("__len__",Value(2));
        return Value(static_cast<Collectable*>(lst));
    }

    // ── IMAGES ──────────────────────────────────────────────────────────
    // gui_load_image(path) -> handle. Needs no window: the texture for each
    // renderer is made the first time the image is drawn there.
    if(name=="gui_load_image"){
        if(args.empty()) return NONE_VALUE;
        SDL_Surface* surf=IMG_Load(VS(E,args[0]).c_str());
        if(!surf) return NONE_VALUE;
        int id=next_img_id++;
        ImgEntry& im=g_images[id];
        im.surf=surf; im.w=surf->w; im.h=surf->h;
        return Value(id);
    }
    // gui_image_size(image_handle) -> [w, h]  (none if unknown)
    if(name=="gui_image_size"){
        if(args.empty()) return NONE_VALUE;
        auto iit=g_images.find(VI(args[0]));
        if(iit==g_images.end()) return NONE_VALUE;
        return make_int_list(E,{iit->second.w,iit->second.h});
    }
    // gui_free_image(image_handle)
    if(name=="gui_free_image"){
        if(args.empty()) return NONE_VALUE;
        auto iit=g_images.find(VI(args[0]));
        if(iit!=g_images.end()){
            for(auto& t:iit->second.tex) if(t.second) SDL_DestroyTexture(t.second);
            if(iit->second.surf) SDL_DestroySurface(iit->second.surf);
            g_images.erase(iit);
        }
        return NONE_VALUE;
    }

    // ── EVENTS ──────────────────────────────────────────────────────────
    // gui_poll_events(window_handle) -> list of event maps, without waiting.
    // gui_wait_events(window_handle, timeout_ms) -> the same, but when nothing
    // is pending it sleeps until the first event arrives or timeout_ms passes,
    // so an idle window costs no CPU yet still reacts at once.
    //
    // Only the given window's events are returned, plus application-wide ones
    // (quit) and any whose window no longer exists; other windows' events stay
    // queued for their own poll.
    //
    // Nearly every poll is empty (a window that is simply open polls 60 times
    // a second), and the interpreter never reclaims containers (GC_NOTES.md):
    // a fresh empty list per poll was ~1 KB of permanent garbage per frame.
    // Empty polls therefore share one list that is never written to; a poll
    // that has events gets its own list as before. (Reusing containers across
    // polls is NOT safe: Object::set does not overwrite an existing key.)
    if(name=="gui_poll_events" || name=="gui_wait_events"){
        static Object* empty_list=nullptr;
        if(!empty_list){
            empty_list=new Object((Runnable*)E.runner,"events",Type::LIST);
            empty_list->set("__len__",Value(0));
        }
        int handle = args.empty() ? -1 : VI(args[0]);
        bool wait = name=="gui_wait_events" && !has_events_for(handle);
        int timeout = (name=="gui_wait_events" && args.size()>=2) ? VI(args[1]) : 0;
        pump_events(wait, timeout);
        Object* list=nullptr;
        int idx=0;
        for(auto it=g_evq.begin(); it!=g_evq.end();){
            if(ev_for(*it,handle)){
                if(!list) list=new Object((Runnable*)E.runner,"events",Type::LIST);
                list->set(std::to_string(idx++),ev_value(E,*it));
                it=g_evq.erase(it);
            } else ++it;
        }
        if(!list) return Value(static_cast<Collectable*>(empty_list));
        list->set("__len__",Value(idx));
        return Value(static_cast<Collectable*>(list));
    }

    // gui_next_event(handle, timeout_ms) -> int type code, 0 when none
    // gui_event_get(field) -> a field of that event, as a number or string
    //
    // The same events as gui_wait_events (timeout_ms 0 = do not wait), one at
    // a time and without building a map: an event map is ~6 KB that the
    // interpreter never reclaims (GC_NOTES.md), on every mouse move and key.
    // Window.run reads events this way. The code indexes gui.ny's
    // GUI_EVENT_TYPES (kEventTypes below, same order), so even the type name
    // needs no new string. gui_event_get("more") says whether another event
    // of the same batch is already waiting (a batch is what one poll drains).
    if(name=="gui_next_event"){
        static const char* kEventTypes[] = {"", "quit", "resize", "expose", "focusgained",
            "focuslost", "mouseleave", "mousemove", "mousedown", "mouseup", "wheel",
            "keydown", "keyup", "textinput", "textedit", "dropfile", "droptext", "dialog", "scale"};
        int handle = args.empty() ? -1 : VI(args[0]);
        int timeout = args.size()>=2 ? VI(args[1]) : 0;
        g_cur_handle = handle;
        if(!has_events_for(handle)) pump_events(timeout!=0, timeout);
        for(auto it=g_evq.begin(); it!=g_evq.end(); ++it){
            if(!ev_for(*it,handle)) continue;
            g_cur = *it;
            g_evq.erase(it);
            for(int k=1;k<(int)(sizeof(kEventTypes)/sizeof(kEventTypes[0]));k++)
                if(g_cur.type==kEventTypes[k]) return Value(k);
            return gui_next_event_unknown(g_cur);
        }
        g_cur = EvData();
        return Value(0);
    }
    if(name=="gui_event_get"){
        if(args.empty()) return NONE_VALUE;
        std::string f = VS(E,args[0]);
        const EvData& d = g_cur;
        if(f=="x") return Value(d.x);
        if(f=="y") return Value(d.y);
        if(f=="button") return Value(d.button);
        if(f=="delta") return Value(d.delta);
        if(f=="clicks") return Value(d.clicks);
        if(f=="w") return Value(d.w);
        if(f=="h") return Value(d.h);
        if(f=="keycode") return Value(d.keycode);
        if(f=="window") return Value(d.window);
        if(f=="ctrl") return Value(d.ctrl);
        if(f=="shift") return Value(d.shift);
        if(f=="alt") return Value(d.alt);
        if(f=="meta") return Value(d.meta);
        if(f=="repeat") return Value(d.repeat);
        if(f=="dx") return Value(d.dx);
        if(f=="dy") return Value(d.dy);
        if(f=="key") return E.makeStringValue(d.key);
        if(f=="text") return E.makeStringValue(d.text);
        if(f=="type") return E.makeStringValue(d.type);
        if(f=="more") return Value(has_events_for(g_cur_handle));
        return NONE_VALUE;
    }

    // ── VIDEO STUBS ─────────────────────────────────────────────────────
    if(name=="gui_load_video")     return NONE_VALUE;
    if(name=="gui_video_play")     return NONE_VALUE;
    if(name=="gui_video_pause")    return NONE_VALUE;
    if(name=="gui_video_stop")     return NONE_VALUE;
    if(name=="gui_video_seek")     return NONE_VALUE;
    if(name=="gui_video_time")     return Value(0.0);
    if(name=="gui_video_duration") return Value(0.0);
    if(name=="gui_video_volume")   return NONE_VALUE;
    if(name=="gui_video_render")   return NONE_VALUE;

    return UNDEFINED_VALUE;
}

#pragma GCC diagnostic pop
