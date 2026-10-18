// builtins/nycurses.cpp - curses without ncurses (round 84).
//
// The native layer behind lib/_curses.ny, lib/_curses_panel.ny and the
// lib/curses package: the terminfo database, tparm, the curses screen model
// (windows, subwindows, pads, the virtual and the physical screen), the
// optimizing doupdate, the tty modes and key decoding. Nothing is linked:
// the terminal is driven through termios/ioctl on POSIX and through the
// Console API in virtual-terminal mode on Windows 10+.
//
// terminfo (term(5)): the legacy format (magic 0432, 16-bit numbers) and
// the extended-number format (01036, 32-bit numbers), with the extended
// capabilities section (user-defined booleans, numbers and strings, which
// is where xterm's kUP5 or XM live). The entry is looked for as ncurses
// does: $TERMINFO, ~/.terminfo, $TERMINFO_DIRS (an empty element stands for
// the system directories), /etc/terminfo, /lib/terminfo, /usr/share/terminfo
// (and /usr/lib/terminfo), each in the letter layout (x/xterm) and the
// hexadecimal one (78/xterm) used on case-insensitive file systems. When no
// database has the entry, xterm-256color and vt100 are built in (taken from
// ncurses' own compiled entries: nycurses_tables.inc), so Windows has them;
// NY_TERMINFO_BUILTIN=1 forces the built-in ones. Berkeley-DB hashed
// databases (*.db) are not read.
//
// tparm is the whole parameter language of terminfo(5) (%p %d %s %c %l %i
// %+ %- %* %/ %m %& %| %^ %= %> %< %A %O %! %~ %? %t %e %; %' %{ %P %g with
// the dynamic a-z and static A-Z variables and the printf-style %[:flags]
// [width[.precision]][doxXs] conversions), as ncurses' lib_tparm.c reads
// it: a %c of 0 gives 0200, division by zero gives 0, dynamic variables
// start at zero on every call and static ones persist. Padding ($<5>,
// $<100/>) is kept by tparm and taken out on output; a mandatory delay
// ('/'), and every delay of bel/flash, is honoured with a sleep - ncurses'
// tputs rules for terminals without padding_baud_rate.
//
// The screen model is ncurses' (lib_addch.c, lib_add_wch.c, lib_refresh.c,
// lib_pad.c, lib_scroll.c ...): per-line change ranges, subwindows sharing
// their parent's cells, render_char's background rules, wide characters in
// two cells and combining marks joining the cell before, the wrap/scroll
// rules at the margins, wnoutrefresh into the virtual screen and doupdate
// from it to the physical screen.
//
// doupdate sends only what changed (tty_update.c's algorithm, with its cost
// model): the hashing line matcher of hashmap.c (unique line hashes as
// anchors, hunks grown while cost_effective, bad shifts dropped - after
// Gosling 1981 and Miller & Myers 1985) finds lines that moved, and
// hardscroll.c's two passes scroll them with csr + ind/ri/indn/rin or
// il/dl; ClrBottom clears the bottom with ed; TransformLine updates a line
// with el/el1, ich/dch/smir when cheaper, rep and ech for runs, and skips
// runs of unchanged cells when a move is cheaper than rewriting them. Cursor
// motion is chosen by cost among cup, home/cr plus relative moves
// (cuu1/cud1/cuf1/cub1 repeated or cuu/cud/cuf/cub), hpa/vpa, tabs, and
// rewriting the characters already on the screen (ncurses' mvcur model).
// Beyond ncurses (round 84): attribute changes are chosen by cost among
// sgr0-and-set, the individual exits (rmul, rmso, ritm) and sgr, colors are
// re-sent only when they change (ncurses re-sends op + setaf + setab after
// every reset, and resets to normal at the end of every doupdate), and on
// ECMA-48 terminals the SGR sequences of one change are merged into a
// single CSI ... m; rep is used for ASCII runs in a UTF-8 locale too. In a
// UTF-8 locale ACS characters are written as their Unicode equivalents
// (lib_wacs.c's table), else through smacs/rmacs and acsc.
//
// Input: the tty is put in ncurses' program mode at initscr (cbreak, no
// echo, no ICRNL/INLCR/IGNCR, no ONLCR); keys are decoded with a trie built
// from the terminal's k* capabilities (ncurses' table, then every extended
// k* capability, numbered KEY_MAX + its index as ncurses does), waiting
// ESCDELAY ms (notimeout: forever) for the rest of a sequence; xterm mouse
// reports (SGR 1006 and X10) are read after kmous, press/release pairs
// within mouseinterval merged into clicks; SIGWINCH (a self-pipe) gives
// KEY_RESIZE after resizing the screen. Blocking reads release the GIL and
// run signal handlers (nyconc::wait_io_many).
//
// Natives: _curses_<op>(...) - lib/_curses.ny holds the argument parsing,
// the error messages and the window objects; window arguments are ids.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyConc.hpp"
#include "builtins/os.hpp"
#include "builtins/sysmods.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#ifdef _WIN32
#  include <windows.h>
#  include <io.h>
#else
#  include <fcntl.h>
#  include <unistd.h>
#  include <termios.h>
#  include <signal.h>
#  include <sys/ioctl.h>
#  include <sys/stat.h>
#endif

namespace {

#include "nycurses_tables.inc"

// ═══════════════════════════════════════════════════════════════════════════
// §1 constants, widths, UTF-8
// ═══════════════════════════════════════════════════════════════════════════
typedef uint32_t attr_t;
const attr_t XA_CHARTEXT = 0xffu, XA_COLOR = 0xff00u, XA_ATTRIBUTES = 0xffffff00u;
const attr_t XA_STANDOUT = 1u << 16, XA_UNDERLINE = 1u << 17, XA_REVERSE = 1u << 18, XA_BLINK = 1u << 19;
const attr_t XA_DIM = 1u << 20, XA_BOLD = 1u << 21, XA_ALTCHARSET = 1u << 22, XA_INVIS = 1u << 23;
const attr_t XA_PROTECT = 1u << 24, XA_ITALIC = 1u << 31;
const attr_t XA_NOCOLOR = XA_ATTRIBUTES & ~XA_COLOR;        // attribute bits of a cell
const attr_t NONBLANK_ATTR = XA_BOLD | XA_DIM | XA_BLINK | XA_ITALIC;
const int XOK = 0, XERR = -1;
const int XKEY_MIN = 0401, XKEY_MAX = 0777, XKEY_MOUSE = 0631, XKEY_RESIZE = 0632;
const int XKEY_BACKSPACE = 0407, XKEY_LEFT = 0404, XKEY_DOWN = 0402, XKEY_ENTER = 0527;
const uint32_t GARBAGE = 0xFFFFFFFFu;        // a physical cell nobody knows

bool in_ranges(const uint32_t (*tab)[2], size_t n, uint32_t c) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (c < tab[mid][0]) hi = mid;
        else if (c > tab[mid][1]) lo = mid + 1;
        else return true;
    }
    return false;
}
int wcw(uint32_t c) {
    if (c < 0x7f) return c == 0 ? 0 : 1;
    if (in_ranges(WC_ZERO, sizeof(WC_ZERO) / sizeof(WC_ZERO[0]), c)) return 0;
    if (in_ranges(WC_WIDE, sizeof(WC_WIDE) / sizeof(WC_WIDE[0]), c)) return 2;
    return 1;
}
void utf8_put(std::string& o, uint32_t c) {
    if (c < 0x80) o += (char)c;
    else if (c < 0x800) { o += (char)(0xC0 | (c >> 6)); o += (char)(0x80 | (c & 0x3F)); }
    else if (c < 0x10000) { o += (char)(0xE0 | (c >> 12)); o += (char)(0x80 | ((c >> 6) & 0x3F)); o += (char)(0x80 | (c & 0x3F)); }
    else { o += (char)(0xF0 | (c >> 18)); o += (char)(0x80 | ((c >> 12) & 0x3F)); o += (char)(0x80 | ((c >> 6) & 0x3F)); o += (char)(0x80 | (c & 0x3F)); }
}
std::vector<uint32_t> utf8_decode(const std::string& s) {
    std::vector<uint32_t> out;
    size_t i = 0, n = s.size();
    while (i < n) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x80) { out.push_back(c); i++; continue; }
        int len = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 0;
        if (len == 0 || i + len > n) { out.push_back(0xFFFD); i++; continue; }
        uint32_t v = c & (0x7F >> len);
        bool ok = true;
        for (int k = 1; k < len; k++) {
            unsigned char d = (unsigned char)s[i + k];
            if ((d & 0xC0) != 0x80) { ok = false; break; }
            v = (v << 6) | (d & 0x3F);
        }
        if (!ok) { out.push_back(0xFFFD); i++; continue; }
        out.push_back(v);
        i += len;
    }
    return out;
}
// the length of the UTF-8 sequence a lead byte starts (0 for a continuation)
int utf8_len(unsigned char c) { return c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 0; }

int64_t now_ms() {
    return (int64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
void sleep_ms(int ms) {
    if (ms <= 0) return;
    nyconc::GilRelease un;
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// ═══════════════════════════════════════════════════════════════════════════
// §2 terminfo: the compiled database (term(5))
// ═══════════════════════════════════════════════════════════════════════════
struct TermInfo {
    std::string term, names, path;
    bool num32 = false;
    std::vector<signed char> b;        // 44 standard, then the extended ones
    std::vector<int> n;                // -1 absent, -2 cancelled
    std::vector<std::string> s;
    std::vector<signed char> sok;      // 1 present, 0 absent, -1 cancelled
    std::vector<std::string> xb, xn, xs;   // names of the extended ones
};

const int NBOOL = 44, NNUM = 39, NSTR = 414;

const std::unordered_map<std::string, int>& name_index(int kind) {
    static std::unordered_map<std::string, int> m[3];
    static bool made = false;
    if (!made) {
        for (int i = 0; i < NBOOL; i++) m[0][TI_BOOLNAMES[i]] = i;
        for (int i = 0; i < NNUM; i++) m[1][TI_NUMNAMES[i]] = i;
        for (int i = 0; i < NSTR; i++) m[2][TI_STRNAMES[i]] = i;
        made = true;
    }
    return m[kind];
}

bool ti_parse(const std::string& d, TermInfo& ti) {
    auto u16 = [&](size_t o) -> int { return (int)(unsigned char)d[o] | ((int)(unsigned char)d[o + 1] << 8); };
    auto s16 = [&](size_t o) -> int { int v = u16(o); return v >= 0x8000 ? v - 0x10000 : v; };
    auto s32 = [&](size_t o) -> int {
        uint32_t v = (uint32_t)(unsigned char)d[o] | ((uint32_t)(unsigned char)d[o + 1] << 8) |
                     ((uint32_t)(unsigned char)d[o + 2] << 16) | ((uint32_t)(unsigned char)d[o + 3] << 24);
        return (int)(int32_t)v;
    };
    if (d.size() < 12) return false;
    int magic = u16(0);
    if (magic == 0432) ti.num32 = false;
    else if (magic == 01036) ti.num32 = true;
    else return false;
    int namesz = s16(2), nb = s16(4), nn = s16(6), ns = s16(8), strsz = s16(10);
    if (namesz < 0 || nb < 0 || nn < 0 || ns < 0 || strsz < 0) return false;
    int nw = ti.num32 ? 4 : 2;
    size_t p = 12;
    if (p + namesz > d.size()) return false;
    ti.names = d.substr(p, namesz);
    size_t z = ti.names.find('\0');
    if (z != std::string::npos) ti.names.resize(z);
    p += namesz;
    ti.b.assign(NBOOL, 0);
    ti.n.assign(NNUM, -1);
    ti.s.assign(NSTR, std::string());
    ti.sok.assign(NSTR, 0);
    if (p + nb > d.size()) return false;
    for (int i = 0; i < nb; i++) {
        signed char v = (signed char)d[p + i];
        if (i < NBOOL) ti.b[i] = v == 1 ? 1 : 0;
    }
    p += nb;
    if (p % 2) p++;
    if (p + (size_t)nn * nw > d.size()) return false;
    for (int i = 0; i < nn; i++) {
        int v = ti.num32 ? s32(p + i * 4) : s16(p + i * 2);
        if (v < 0) v = v == -2 ? -2 : -1;
        if (i < NNUM) ti.n[i] = v;
    }
    p += (size_t)nn * nw;
    size_t offs = p;
    if (p + (size_t)ns * 2 > d.size()) return false;
    p += (size_t)ns * 2;
    size_t table = p;
    if (p + strsz > d.size()) return false;
    for (int i = 0; i < ns && i < NSTR; i++) {
        int off = s16(offs + i * 2);
        if (off == -1) continue;
        if (off == -2) { ti.sok[i] = -1; continue; }
        if (off < 0 || off >= strsz) continue;
        size_t e = d.find('\0', table + off);
        if (e == std::string::npos || e > table + strsz) e = table + strsz;
        ti.s[i] = d.substr(table + off, e - (table + off));
        ti.sok[i] = 1;
    }
    p = table + strsz;
    // the extended section, on an even boundary
    if (p % 2) p++;
    if (p + 10 > d.size()) return true;
    int xb = s16(p), xn = s16(p + 2), xs = s16(p + 4), xsz = s16(p + 8);
    if (xb < 0 || xn < 0 || xs < 0 || xsz < 0) return true;
    p += 10;
    if (p + xb > d.size()) return true;
    std::vector<signed char> xbv(xb);
    for (int i = 0; i < xb; i++) xbv[i] = (signed char)d[p + i] == 1 ? 1 : 0;
    p += xb;
    if (p % 2) p++;
    if (p + (size_t)xn * nw > d.size()) return true;
    std::vector<int> xnv(xn);
    for (int i = 0; i < xn; i++) {
        int v = ti.num32 ? s32(p + i * 4) : s16(p + i * 2);
        if (v < 0) v = v == -2 ? -2 : -1;
        xnv[i] = v;
    }
    p += (size_t)xn * nw;
    size_t xoffs = p;
    int nnames = xb + xn + xs;
    if (p + (size_t)(xs + nnames) * 2 > d.size()) return true;
    p += (size_t)(xs + nnames) * 2;
    size_t xtable = p;
    if (xtable + xsz > d.size()) return true;
    std::vector<std::string> xsv(xs);
    std::vector<signed char> xsok(xs, 0);
    size_t base = 0;
    for (int i = 0; i < xs; i++) {
        int off = s16(xoffs + i * 2);
        if (off == -1) continue;
        if (off == -2) { xsok[i] = -1; continue; }
        if (off < 0 || off >= xsz) continue;
        size_t e = d.find('\0', xtable + off);
        if (e == std::string::npos || e > xtable + xsz) e = xtable + xsz;
        xsv[i] = d.substr(xtable + off, e - (xtable + off));
        xsok[i] = 1;
        base += xsv[i].size() + 1;
    }
    std::vector<std::string> names(nnames);
    for (int i = 0; i < nnames; i++) {
        int off = s16(xoffs + (size_t)(xs + i) * 2);
        if (off < 0 || base + off >= (size_t)xsz) continue;
        size_t st = xtable + base + off;
        size_t e = d.find('\0', st);
        if (e == std::string::npos || e > xtable + xsz) e = xtable + xsz;
        names[i] = d.substr(st, e - st);
    }
    for (int i = 0; i < xb; i++) { ti.xb.push_back(names[i]); ti.b.push_back(xbv[i]); }
    for (int i = 0; i < xn; i++) { ti.xn.push_back(names[xb + i]); ti.n.push_back(xnv[i]); }
    for (int i = 0; i < xs; i++) { ti.xs.push_back(names[xb + xn + i]); ti.s.push_back(xsv[i]); ti.sok.push_back(xsok[i]); }
    return true;
}

bool read_file(const std::string& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}
bool is_dir(const std::string& p) {
#ifdef _WIN32
    DWORD a = GetFileAttributesA(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat st;
    return ::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
#endif
}

std::vector<std::string> ti_dirs() {
    std::vector<std::string> d;
    std::vector<std::string> sys = {"/etc/terminfo", "/lib/terminfo", "/usr/share/terminfo", "/usr/lib/terminfo"};
    if (const char* t = std::getenv("TERMINFO")) if (*t) d.push_back(t);
    if (const char* h = std::getenv("HOME")) if (*h) d.push_back(std::string(h) + "/.terminfo");
#ifdef _WIN32
    const char sep = ';';
#else
    const char sep = ':';
#endif
    bool added_sys = false;
    if (const char* td = std::getenv("TERMINFO_DIRS")) {
        std::string s = td, cur;
        for (size_t i = 0; i <= s.size(); i++) {
            if (i == s.size() || s[i] == sep) {
                if (cur.empty()) { for (auto& x : sys) d.push_back(x); added_sys = true; }
                else d.push_back(cur);
                cur.clear();
            } else cur += s[i];
        }
    }
    if (!added_sys) for (auto& x : sys) d.push_back(x);
    return d;
}

// 0 found, -1 no database at all, 1 database but no such terminal
int ti_load(const std::string& name, TermInfo& ti) {
    ti = TermInfo();
    ti.term = name;
    if (name.empty() || name.find('/') != std::string::npos || name.find('\\') != std::string::npos ||
        name == "." || name == "..")
        return 1;
    bool any_db = false;
    const char* force = std::getenv("NY_TERMINFO_BUILTIN");
    bool builtin_only = force && *force && std::string(force) != "0";
    if (!builtin_only) {
        char hex[3];
        std::snprintf(hex, sizeof hex, "%02x", (unsigned char)name[0]);
        for (auto& dir : ti_dirs()) {
            if (!is_dir(dir)) continue;
            any_db = true;
            for (const std::string& sub : {std::string(1, name[0]), std::string(hex)}) {
                std::string path = dir + "/" + sub + "/" + name, data;
                if (read_file(path, data) && ti_parse(data, ti)) {
                    ti.term = name;
                    ti.path = path;
                    return 0;
                }
                ti = TermInfo();
            }
        }
    }
    if (name == "xterm-256color" || name == "vt100") {
        std::string data = name == "vt100" ? std::string((const char*)TI_BUILTIN_VT100, sizeof TI_BUILTIN_VT100)
                                           : std::string((const char*)TI_BUILTIN_XTERM256, sizeof TI_BUILTIN_XTERM256);
        if (ti_parse(data, ti)) { ti.term = name; ti.path = ""; return 0; }
    }
    ti.term = name;
    return any_db ? 1 : -1;
}

// lookup by capability name: standard first, then the entry's extended ones
int ti_bool_idx(const TermInfo& ti, const std::string& nm) {
    if (ti.b.size() < (size_t)NBOOL) return -1;
    auto& m = name_index(0);
    auto it = m.find(nm);
    if (it != m.end()) return it->second;
    for (size_t i = 0; i < ti.xb.size(); i++) if (ti.xb[i] == nm) return NBOOL + (int)i;
    return -1;
}
int ti_num_idx(const TermInfo& ti, const std::string& nm) {
    if (ti.n.size() < (size_t)NNUM) return -1;
    auto& m = name_index(1);
    auto it = m.find(nm);
    if (it != m.end()) return it->second;
    for (size_t i = 0; i < ti.xn.size(); i++) if (ti.xn[i] == nm) return NNUM + (int)i;
    return -1;
}
int ti_str_idx(const TermInfo& ti, const std::string& nm) {
    if (ti.s.size() < (size_t)NSTR) return -1;
    auto& m = name_index(2);
    auto it = m.find(nm);
    if (it != m.end()) return it->second;
    for (size_t i = 0; i < ti.xs.size(); i++) if (ti.xs[i] == nm) return NSTR + (int)i;
    return -1;
}

// ═══════════════════════════════════════════════════════════════════════════
// §3 tparm (terminfo(5) "Parameterized Strings", lib_tparm.c's reading)
// ═══════════════════════════════════════════════════════════════════════════
struct TPArg { bool is_str = false; int64_t n = 0; std::string s; };
int64_t g_static_vars[26];

std::string tparm_fmt(const std::string& spec, char conv, const TPArg& v) {
    // spec: flags/width/precision (without the leading '%' and ':')
    std::string f = "%" + spec;
    char buf[512];
    if (conv == 's') {
        std::string sv = v.is_str ? v.s : std::to_string(v.n);
        f += 's';
        std::snprintf(buf, sizeof buf, f.c_str(), sv.c_str());
    } else {
        f += "ll";
        f += conv;
        std::snprintf(buf, sizeof buf, f.c_str(), (long long)v.n);
    }
    return buf;
}

// ncurses' reading in its corners (checked against it): '%{' takes the
// digits and always skips one character after them; "%'" takes the
// character and always skips the next; a %s or %l of a number is an error
// (tparm returns NULL); a width on %c is ignored; after ':' the flags are
// '-', '#' and ' ' only, and a character that starts no conversion is read
// as the operator it names ("%:+" adds).
bool g_tparm_null = false;
std::string tparm(const std::string& s, std::vector<TPArg> p) {
    g_tparm_null = false;
    while (p.size() < 9) p.push_back(TPArg());
    std::string out;
    std::vector<TPArg> st;
    int64_t dyn[26] = {0};
    auto pop = [&]() -> TPArg { if (st.empty()) return TPArg(); TPArg t = st.back(); st.pop_back(); return t; };
    auto popn = [&]() -> int64_t { TPArg t = pop(); if (t.is_str) return 0; return t.n; };
    auto pushn = [&](int64_t v) { TPArg t; t.n = v; st.push_back(t); };
    size_t i = 0, n = s.size();
    // skip forward to the %e or %; that ends this level (after a false %t)
    // or to its %; (after a then-part reached %e)
    auto skip = [&](bool to_else) {
        int level = 0;
        while (i < n) {
            if (s[i] == '%' && i + 1 < n) {
                char c = s[i + 1];
                i += 2;
                if (c == '?') level++;
                else if (c == ';') { if (level == 0) return; level--; }
                else if (c == 'e' && level == 0 && to_else) return;
                continue;
            }
            i++;
        }
    };
    while (i < n) {
        char c = s[i++];
        if (c != '%') { out += c; continue; }
        if (i >= n) break;
        c = s[i++];
    again:
        switch (c) {
        case '%': out += '%'; break;
        case 'c': { int64_t v = popn(); char ch = (char)v; if (ch == 0) ch = (char)0200; out += ch; break; }
        case 's': { TPArg v = pop(); if (!v.is_str) { g_tparm_null = true; return std::string(); } out += v.s; break; }
        case 'l': { TPArg v = pop(); if (!v.is_str) { g_tparm_null = true; return std::string(); } pushn((int64_t)v.s.size()); break; }
        case 'p':
            if (i < n && s[i] >= '1' && s[i] <= '9') { st.push_back(p[s[i] - '1']); i++; }
            break;
        case 'P':
            if (i < n) {
                char v = s[i++];
                if (v >= 'a' && v <= 'z') dyn[v - 'a'] = popn();
                else if (v >= 'A' && v <= 'Z') g_static_vars[v - 'A'] = popn();
            }
            break;
        case 'g':
            if (i < n) {
                char v = s[i++];
                if (v >= 'a' && v <= 'z') pushn(dyn[v - 'a']);
                else if (v >= 'A' && v <= 'Z') pushn(g_static_vars[v - 'A']);
            }
            break;
        case '\'':
            if (i < n) pushn((unsigned char)s[i]);
            i += 2;
            break;
        case '{': {
            int64_t v = 0;
            while (i < n && s[i] >= '0' && s[i] <= '9') v = v * 10 + (s[i++] - '0');
            i++;
            pushn(v);
            break;
        }
        case '+': case '-': case '*': case '/': case 'm': case '&': case '|': case '^':
        case '=': case '>': case '<': case 'A': case 'O': {
            int64_t y = popn(), x = popn(), r = 0;
            switch (c) {
            case '+': r = x + y; break;
            case '-': r = x - y; break;
            case '*': r = x * y; break;
            case '/': r = y ? x / y : 0; break;
            case 'm': r = y ? x % y : 0; break;
            case '&': r = x & y; break;
            case '|': r = x | y; break;
            case '^': r = x ^ y; break;
            case '=': r = x == y; break;
            case '>': r = x > y; break;
            case '<': r = x < y; break;
            case 'A': r = x && y; break;
            case 'O': r = x || y; break;
            }
            pushn(r);
            break;
        }
        case '!': pushn(!popn()); break;
        case '~': pushn(~popn()); break;
        case 'i':
            if (!p[0].is_str) p[0].n++;
            if (!p[1].is_str) p[1].n++;
            break;
        case '?': break;
        case 't': { int64_t v = popn(); if (!v) skip(true); break; }
        case 'e': skip(false); break;
        case ';': break;
        default: {
            // %[[:]flags][width[.precision]][doxXs]
            std::string spec;
            size_t j = i - 1;
            bool colon = s[j] == ':';
            if (colon) j++;
            while (j < n && ((colon && s[j] == '-') || s[j] == '#' || s[j] == ' ')) spec += s[j++];
            while (j < n && s[j] >= '0' && s[j] <= '9') spec += s[j++];
            if (j < n && s[j] == '.') { spec += s[j++]; while (j < n && s[j] >= '0' && s[j] <= '9') spec += s[j++]; }
            if (j < n && (s[j] == 'd' || s[j] == 'o' || s[j] == 'x' || s[j] == 'X')) {
                TPArg v = pop();
                out += tparm_fmt(spec, s[j], v);
                i = j + 1;
            } else if (j < n && s[j] == 's') {
                TPArg v = pop();
                if (!v.is_str) { g_tparm_null = true; return std::string(); }
                out += tparm_fmt(spec, 's', v);
                i = j + 1;
            } else if (j < n && s[j] == 'c') {
                int64_t v = popn(); char ch = (char)v; if (ch == 0) ch = (char)0200;
                out += ch;
                i = j + 1;
            } else if (colon && spec.empty() && j < n) {
                // "%:" and a character that is no flag: that character's operation
                c = s[j];
                i = j + 1;
                goto again;
            }
            // anything else: dropped, as ncurses does
            break;
        }
        }
    }
    return out;
}

// padding out of a capability: "$<5>", "$<100/>", "$<2*>"
std::string strip_pad(const std::string& s, int* mandatory_ms = nullptr, int* any_ms = nullptr) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '$' && i + 1 < s.size() && s[i + 1] == '<') {
            size_t e = s.find('>', i + 2);
            if (e != std::string::npos) {
                std::string body = s.substr(i + 2, e - i - 2);
                bool ok = !body.empty();
                double ms = 0;
                bool mand = false;
                size_t k = 0;
                std::string num;
                while (k < body.size() && ((body[k] >= '0' && body[k] <= '9') || body[k] == '.')) num += body[k++];
                if (num.empty()) ok = false;
                while (k < body.size()) {
                    if (body[k] == '/') mand = true;
                    else if (body[k] != '*') ok = false;
                    k++;
                }
                if (ok) {
                    ms = std::atof(num.c_str());
                    if (mand && mandatory_ms) *mandatory_ms += (int)ms;
                    if (any_ms) *any_ms += (int)ms;
                    i = e;
                    continue;
                }
            }
        }
        out += s[i];
    }
    return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// §4 the screen model
// ═══════════════════════════════════════════════════════════════════════════
struct Cell {
    uint32_t ch = ' ';
    attr_t attr = 0;          // attribute bits, no color
    int pair = 0;
    uint8_t wext = 0;         // 0 one column, 1 first cell of a wide char, 2 its second cell
    uint32_t comb = 0;        // interned combining marks
    bool operator==(const Cell& o) const {
        return ch == o.ch && attr == o.attr && pair == o.pair && wext == o.wext && comb == o.comb;
    }
    bool operator!=(const Cell& o) const { return !(*this == o); }
};

std::vector<std::u32string> g_comb(1);
std::map<std::u32string, uint32_t> g_comb_idx;
uint32_t comb_add(uint32_t old, uint32_t mark) {
    std::u32string s = g_comb[old];
    if (s.size() >= 4) return old;      // CCHARW_MAX - 1 marks
    s += (char32_t)mark;
    auto it = g_comb_idx.find(s);
    if (it != g_comb_idx.end()) return it->second;
    g_comb.push_back(s);
    uint32_t id = (uint32_t)(g_comb.size() - 1);
    g_comb_idx[s] = id;
    return id;
}

typedef std::vector<std::vector<Cell>> Store;

struct Win {
    int id = 0;
    int begy = 0, begx = 0, rows = 0, cols = 0;
    int cury = 0, curx = 0;
    int pary = -1, parx = -1;
    Win* parent = nullptr;
    int nsub = 0;
    bool is_pad = false, is_subpad = false, dead = false;
    std::shared_ptr<Store> store;
    int sy = 0, sx = 0;
    std::vector<int> fch, lch;
    attr_t attrs = 0;         // WINDOW_ATTRS, color bits included
    int pair = 0;             // the window's color pair (extended)
    Cell bkgd;                // _nc_bkgd
    uint32_t bkgd_ct = 0;     // _bkgd, what getbkgd() returns
    bool scroll = false, leave = false, clr = false, idl = false, idc = true, immed = false, sync = false;
    bool keypad = false, notimeout = false;
    int delay = -1;
    int regtop = 0, regbot = 0;
    bool wrapped = false, moved = false;
    int pad_y = -1, pad_x = -1, pad_top = 0, pad_left = 0, pad_bottom = 0, pad_right = 0;
    Cell& at(int y, int x) { return (*store)[sy + y][sx + x]; }
    int maxy() const { return rows - 1; }
    int maxx() const { return cols - 1; }
};

struct Caps {
    bool am = false, xenl = false, bce = false, msgr = false, mir = false, km = false, npc = false, hz = false;
    bool ccc = false, bw = false, xon = false;
    int colors = -1, pairs = -1, it = 8, lines = -1, cols = -1, ncv = -1;
    const std::string *cup = nullptr, *home = nullptr, *cr = nullptr, *cuu1 = nullptr, *cud1 = nullptr,
        *cuf1 = nullptr, *cub1 = nullptr, *cuu = nullptr, *cud = nullptr, *cuf = nullptr, *cub = nullptr,
        *hpa = nullptr, *vpa = nullptr, *el = nullptr, *el1 = nullptr, *ed = nullptr, *ech = nullptr,
        *ich = nullptr, *ich1 = nullptr, *dch = nullptr, *dch1 = nullptr, *il = nullptr, *il1 = nullptr,
        *dl = nullptr, *dl1 = nullptr, *csr = nullptr, *ind = nullptr, *ri = nullptr, *indn = nullptr,
        *rin = nullptr, *smcup = nullptr, *rmcup = nullptr, *smkx = nullptr, *rmkx = nullptr, *smir = nullptr,
        *rmir = nullptr, *ip = nullptr, *sgr0 = nullptr, *sgr = nullptr, *bold = nullptr, *dim = nullptr,
        *blink = nullptr, *rev = nullptr, *smul = nullptr, *rmul = nullptr, *smso = nullptr, *rmso = nullptr,
        *sitm = nullptr, *ritm = nullptr, *invis = nullptr, *prot = nullptr, *smacs = nullptr, *rmacs = nullptr,
        *enacs = nullptr, *acsc = nullptr, *setaf = nullptr, *setab = nullptr, *setf = nullptr, *setb = nullptr,
        *op = nullptr, *oc = nullptr, *initc = nullptr, *bel = nullptr, *flash = nullptr, *civis = nullptr,
        *cnorm = nullptr, *cvvis = nullptr, *clear = nullptr, *rep = nullptr, *smam = nullptr, *rmam = nullptr,
        *sc = nullptr, *rc = nullptr, *ht = nullptr, *cbt = nullptr, *kmous = nullptr, *XM = nullptr,
        *smm = nullptr, *rmm = nullptr, *ll = nullptr;
};

struct MouseEv { int id = 0, x = 0, y = 0, z = 0; uint64_t bstate = 0; };

struct Trie {
    std::map<unsigned char, std::unique_ptr<Trie>> kids;
    int code = 0;
};

struct State {
    // terminfo
    bool setup = false;
    TermInfo ti;
    Caps c;
    // the screen
    bool started = false, in_endwin = false;
    int ofd = 1, ifd = 0;
    int lines = 24, cols = 80;
    Win* stdscr = nullptr;
    Win* curscr = nullptr;
    Win* newscr = nullptr;
    // output
    std::string out;
    uint64_t bytes_total = 0, updates = 0;
    std::string mode = "optimize";   // NY_CURSES_UPDATE: optimize, noscroll, naive
    // the physical screen's state
    int py = -1, px = -1;
    attr_t pattr = 0;
    int pfg = -1, pbg = -1;
    bool pcolors_known = true;
    bool pins = false, pkeypad = false, pmouse = false;
    int pcurs = 1;
    // colors
    bool color_on = false, default_colors = false;
    int COLORS = 0, COLOR_PAIRS = 0;
    int default_fg = 7, default_bg = 0;
    std::vector<std::pair<int, int>> pairs;
    std::vector<std::array<int, 3>> palette;
    std::vector<bool> pair_used;
    // input
    std::deque<int> fifo;          // bytes read, codes pushed back
    std::deque<std::string> wch_back;   // unget_wch
    Trie keys;
    bool echo = true, nl = true, cbreak = false, raw = false, meta = true;
    int halfdelay = 0;
    int escdelay = 1000, tabsize = 8;
    bool use_env = true, filtered = false;
    int typeahead = 0;
    // mouse
    uint64_t mouse_mask = 0, mouse_held = 0;
    int mouse_interval = 166;
    std::deque<MouseEv> mouse_q;
    MouseEv mouse_last;
    bool have_mouse_last = false;
    // ACS
    bool utf8 = true;
    uint32_t acs_map[128];
    // costs
    int cost_cup = 0, cost_el = 0, cost_el1 = 0, cost_ech = 0, cost_rep = 0, cost_hpa = 0, cost_inline = 0;
    bool ecma48 = false;
    // tty modes
#ifndef _WIN32
    struct termios shell_tty, prog_tty, saved_tty, cur_tty;
#else
    DWORD shell_in = 0, shell_out = 0, prog_in = 0, prog_out = 0, saved_in = 0, saved_out = 0;
#endif
    bool have_tty = false, have_saved = false, have_prog = false;
};

State* G = nullptr;
std::unordered_map<int, Win*> g_wins;
int g_next_id = 1;
#ifndef _WIN32
int g_winch_pipe[2] = {-1, -1};
volatile sig_atomic_t g_winch = 0;
#endif

State& S() {
    if (!G) { G = new State(); for (int i = 0; i < 128; i++) G->acs_map[i] = 0; }
    return *G;
}

const std::string* cap_s(const char* nm) {
    State& g = S();
    int i = ti_str_idx(g.ti, nm);
    if (i < 0 || g.ti.sok[i] != 1) return nullptr;
    return &g.ti.s[i];
}
int cap_n(const char* nm) {
    State& g = S();
    int i = ti_num_idx(g.ti, nm);
    if (i < 0) return -1;
    return g.ti.n[i];
}
bool cap_b(const char* nm) {
    State& g = S();
    int i = ti_bool_idx(g.ti, nm);
    if (i < 0) return false;
    return g.ti.b[i] == 1;
}

void load_caps() {
    State& g = S();
    Caps& c = g.c;
    c = Caps();
    c.am = cap_b("am"); c.xenl = cap_b("xenl"); c.bce = cap_b("bce"); c.msgr = cap_b("msgr");
    c.mir = cap_b("mir"); c.km = cap_b("km"); c.npc = cap_b("npc"); c.hz = cap_b("hz"); c.ccc = cap_b("ccc");
    c.bw = cap_b("bw"); c.xon = cap_b("xon");
    c.colors = cap_n("colors"); c.pairs = cap_n("pairs"); c.it = cap_n("it"); c.lines = cap_n("lines");
    c.cols = cap_n("cols"); c.ncv = cap_n("ncv");
#define CAP(x) c.x = cap_s(#x)
    CAP(cup); CAP(home); CAP(cr); CAP(cuu1); CAP(cud1); CAP(cuf1); CAP(cub1); CAP(cuu); CAP(cud); CAP(cuf);
    CAP(cub); CAP(hpa); CAP(vpa); CAP(el); CAP(el1); CAP(ed); CAP(ech); CAP(ich); CAP(ich1); CAP(dch);
    CAP(dch1); CAP(il); CAP(il1); CAP(dl); CAP(dl1); CAP(csr); CAP(ind); CAP(ri); CAP(indn); CAP(rin);
    CAP(smcup); CAP(rmcup); CAP(smkx); CAP(rmkx); CAP(smir); CAP(rmir); CAP(ip); CAP(sgr0); CAP(sgr);
    CAP(bold); CAP(dim); CAP(blink); CAP(rev); CAP(smul); CAP(rmul); CAP(smso); CAP(rmso); CAP(sitm);
    CAP(ritm); CAP(invis); CAP(prot); CAP(smacs); CAP(rmacs); CAP(enacs); CAP(acsc); CAP(setaf); CAP(setab);
    CAP(setf); CAP(setb); CAP(op); CAP(oc); CAP(initc); CAP(bel); CAP(flash); CAP(civis); CAP(cnorm);
    CAP(cvvis); CAP(clear); CAP(rep); CAP(smam); CAP(rmam); CAP(sc); CAP(rc); CAP(ht); CAP(cbt); CAP(kmous);
    CAP(XM); CAP(smm); CAP(rmm); CAP(ll);
#undef CAP
    if (c.it <= 0) c.it = 8;
}

// ── the output buffer ───────────────────────────────────────────────────────
void out_raw(const std::string& s) { S().out += s; }
void out_cap(const std::string* s) {
    if (!s) return;
    int mand = 0;
    S().out += strip_pad(*s, &mand);
    (void)mand;
}
void out_tp(const std::string* s, std::initializer_list<int64_t> args) {
    if (!s) return;
    std::vector<TPArg> v;
    for (auto a : args) { TPArg t; t.n = a; v.push_back(t); }
    S().out += strip_pad(tparm(*s, v));
}
std::string tp(const std::string* s, std::initializer_list<int64_t> args) {
    if (!s) return std::string();
    std::vector<TPArg> v;
    for (auto a : args) { TPArg t; t.n = a; v.push_back(t); }
    return strip_pad(tparm(*s, v));
}
int cost_of(const std::string* s) { return s ? (int)strip_pad(*s).size() : 100000; }

void write_all(int fd, const std::string& s) {
    if (s.empty()) return;
    std::fflush(stdout);
    std::cout.flush();
    nyconc::GilRelease un;
#ifdef _WIN32
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    size_t off = 0;
    while (off < s.size()) {
        DWORD w = 0;
        if (!WriteFile(h, s.data() + off, (DWORD)(s.size() - off), &w, nullptr) || w == 0) break;
        off += w;
    }
#else
    size_t off = 0;
    while (off < s.size()) {
        ssize_t w = ::write(fd, s.data() + off, s.size() - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) { usleep(1000); continue; }
            break;
        }
        off += (size_t)w;
    }
#endif
}
void out_flush() {
    State& g = S();
    if (g.out.empty()) return;
    g.bytes_total += g.out.size();
    std::string s;
    s.swap(g.out);
    write_all(g.ofd, s);
}

// ── windows ─────────────────────────────────────────────────────────────────
Win* win_new(int rows, int cols, int by, int bx, bool pad) {
    Win* w = new Win();
    w->id = g_next_id++;
    w->rows = rows; w->cols = cols; w->begy = by; w->begx = bx;
    w->store = std::make_shared<Store>(rows, std::vector<Cell>(cols));
    // a new window is all changed (SVr4, ncurses' _nc_makenew), and one the
    // size of the screen clears it at its first refresh
    w->fch.assign(rows, 0);
    w->lch.assign(rows, cols - 1);
    w->regbot = rows - 1;
    w->is_pad = pad;
    w->clr = !pad && G && G->started && rows == G->lines && cols == G->cols;
    g_wins[w->id] = w;
    return w;
}
Win* win_get(int64_t id) {
    auto it = g_wins.find((int)id);
    if (it == g_wins.end() || it->second->dead) return nullptr;
    return it->second;
}
void touch_range(Win* w, int y, int x0, int x1) {
    if (y < 0 || y >= w->rows) return;
    if (x0 < 0) x0 = 0;
    if (x1 >= w->cols) x1 = w->cols - 1;
    if (x0 > x1) return;
    if (w->fch[y] < 0 || x0 < w->fch[y]) w->fch[y] = x0;
    if (w->lch[y] < 0 || x1 > w->lch[y]) w->lch[y] = x1;
}
void touch_line(Win* w, int y) { touch_range(w, y, 0, w->cols - 1); }
void touch_lines(Win* w, int y, int n) { for (int i = y; i < y + n && i < w->rows; i++) touch_line(w, i); }
void touchwin(Win* w) { touch_lines(w, 0, w->rows); }
void untouch(Win* w) { for (int i = 0; i < w->rows; i++) { w->fch[i] = -1; w->lch[i] = -1; } }
bool is_touched(Win* w) { for (int i = 0; i < w->rows; i++) if (w->fch[i] >= 0) return true; return false; }

void wsyncup(Win* w) {
    for (Win* p = w->parent; p && w; w = p, p = p->parent) {
        for (int y = 0; y < w->rows; y++) {
            if (w->fch[y] >= 0) touch_range(p, y + w->pary, w->fch[y] + w->parx, w->lch[y] + w->parx);
        }
    }
}
void wsyncdown(Win* w) {
    Win* p = w->parent;
    if (!p) return;
    wsyncdown(p);
    for (int y = 0; y < w->rows; y++) {
        int py = y + w->pary;
        if (py < 0 || py >= p->rows) continue;
        if (p->fch[py] >= 0) {
            int l = p->fch[py] - w->parx, r = p->lch[py] - w->parx;
            if (r >= 0 && l < w->cols) touch_range(w, y, l, r);
        }
    }
}
void wcursyncup(Win* w) {
    for (Win* p = w->parent; p; w = p, p = p->parent) {
        p->cury = w->cury + w->pary;
        p->curx = w->curx + w->parx;
    }
}

int wrefresh(Win* w);
void synchook(Win* w) {
    if (w->immed) wrefresh(w);
    if (w->sync) wsyncup(w);
}

// render_char (lib_addch.c): a character as it lands in the window
Cell render(Win* w, Cell ch) {
    attr_t a = w->attrs & XA_NOCOLOR;
    if (ch.ch == ' ' && ch.attr == 0 && ch.pair == 0 && ch.comb == 0 && ch.wext == 0) {
        Cell r = w->bkgd;
        r.attr = a | w->bkgd.attr;
        r.pair = w->pair ? w->pair : w->bkgd.pair;
        return r;
    }
    a |= w->bkgd.attr;
    if (ch.pair == 0) ch.pair = w->pair ? w->pair : w->bkgd.pair;
    ch.attr |= a;
    return ch;
}

bool newline_forces_scroll(Win* w, int* y) {
    bool r = false;
    if (*y >= w->regtop && *y <= w->regbot) {
        if (*y == w->regbot) { *y = w->regbot; r = true; }
        else if (*y < w->maxy()) *y = *y + 1;
    } else if (*y < w->maxy()) *y = *y + 1;
    return r;
}

void scroll_window(Win* w, int n, int top, int bot, const Cell& blank) {
    if (top < 0 || bot >= w->rows || top > bot || n == 0) return;
    if (n < 0) {
        int limit = top - n;
        for (int line = bot; line >= limit && line >= 0; line--)
            for (int x = 0; x < w->cols; x++) w->at(line, x) = w->at(line + n, x);
        for (int line = top; line < limit && line <= w->maxy(); line++)
            for (int x = 0; x < w->cols; x++) w->at(line, x) = blank;
    } else {
        int limit = bot - n;
        for (int line = top; line <= limit && line <= w->maxy(); line++)
            for (int x = 0; x < w->cols; x++) w->at(line, x) = w->at(line + n, x);
        for (int line = bot; line > limit && line >= 0; line--)
            for (int x = 0; x < w->cols; x++) w->at(line, x) = blank;
    }
    touch_lines(w, top, bot - top + 1);
}

int wscrl(Win* w, int n) {
    if (!w->scroll) return XERR;
    if (n != 0) {
        scroll_window(w, n, w->regtop, w->regbot, w->bkgd);
        synchook(w);
    }
    return XOK;
}

int wrap_to_next_line(Win* w) {
    w->wrapped = true;
    if (newline_forces_scroll(w, &w->cury)) {
        w->curx = w->maxx();
        if (!w->scroll) return XERR;
        scroll_window(w, 1, w->regtop, w->regbot, w->bkgd);
    }
    w->curx = 0;
    return XOK;
}

int add_literal(Win* w, Cell ch);
void fill_cells(Win* w, int count) {
    int sy = w->cury, sx = w->curx;
    Cell blank;
    while (count-- > 0) if (add_literal(w, blank) == XERR) break;
    w->cury = sy; w->curx = sx;
}

// wadd_wch_literal / waddch_literal
int add_literal(Win* w, Cell ch) {
    int x = w->curx, y = w->cury;
    if (x < 0 || y < 0 || x > w->maxx() || y > w->maxy()) return XERR;
    ch = render(w, ch);
    int len = (ch.attr & XA_ALTCHARSET) ? 1 : wcw(ch.ch);
    if (len == 0) {
        // a non-spacing character joins the cell before
        if (x > 0) {
            Cell& prev = w->at(y, x - 1);
            Cell* tgt = &prev;
            if (prev.wext == 2 && x > 1) tgt = &w->at(y, x - 2);
            tgt->comb = comb_add(tgt->comb, ch.ch);
            if (prev.wext == 2) prev.comb = tgt->comb;
            touch_range(w, y, x - (prev.wext == 2 ? 2 : 1), x - 1);
        } else if (y >= 1) {
            Cell& prev = w->at(y - 1, w->maxx());
            prev.comb = comb_add(prev.comb, ch.ch);
            touch_range(w, y - 1, w->maxx(), w->maxx());
        }
        w->curx = x;
        return XOK;
    }
    if (len > 1) {
        if (len > w->cols) return XERR;
        if (x + len > w->cols) {
            fill_cells(w, w->cols - x);
            if (wrap_to_next_line(w) == XERR) return XERR;
            x = w->curx; y = w->cury;
        }
        // orphaned halves of wide characters become blanks
        for (int i = 0; i < len; i++) {
            Cell& c = w->at(y, x + i);
            if (c.wext == 1) break;
            if (c.wext == 2) {
                for (int j = i; x + j <= w->maxx(); ++j) {
                    if (w->at(y, x + j).wext != 2) { fill_cells(w, j); break; }
                }
                break;
            }
        }
        for (int i = 0; i < len; i++) {
            Cell v = ch;
            v.wext = (uint8_t)(i + 1);
            w->at(y, x) = v;
            touch_range(w, y, x, x);
            ++x;
        }
    } else {
        Cell& cur = w->at(y, x);
        // overwriting half of a wide character blanks its other half
        if (cur.wext == 2 && x > 0) { w->at(y, x - 1) = render(w, Cell()); touch_range(w, y, x - 1, x - 1); }
        if (cur.wext == 1 && x + 1 <= w->maxx()) { w->at(y, x + 1) = render(w, Cell()); touch_range(w, y, x + 1, x + 1); }
        ch.wext = 0;
        w->at(y, x) = ch;
        touch_range(w, y, x, x);
        ++x;
    }
    if (x > w->maxx()) return wrap_to_next_line(w);
    w->curx = x;
    return XOK;
}

// unctrl() for a byte
std::string unctrl_str(unsigned c) {
    c &= 0xff;
    std::string s;
    if (c >= 128) { s = "M-"; c -= 128; }
    if (c < 32) { s += '^'; s += (char)(c + 64); }
    else if (c == 127) s += "^?";
    else s += (char)c;
    return s;
}

int waddch_nosync(Win* w, Cell ch, bool wide_call);
// the special characters (tab, newline, return, backspace) and control
// characters spelled with unctrl
int add_special(Win* w, Cell ch, bool wide_call) {
    int x = w->curx, y = w->cury;
    if (x < 0 || y < 0 || x > w->maxx() || y > w->maxy()) return XERR;
    uint32_t t = ch.ch;
    switch (t) {
    case '\t': {
        int tabsize = S().tabsize > 0 ? S().tabsize : 8;
        x = x + (tabsize - (x % tabsize));
        if ((!w->scroll && y == w->regbot) || x <= w->maxx()) {
            Cell blank;
            blank.attr = ch.attr;
            blank.pair = ch.pair;
            while (w->curx < x) if (add_literal(w, blank) == XERR) return XERR;
            return XOK;
        } else {
            // clear to the end of the line and wrap
            for (int i = w->curx; i <= w->maxx(); i++) w->at(y, i) = w->bkgd;
            touch_range(w, y, w->curx, w->maxx());
            w->wrapped = true;
            if (newline_forces_scroll(w, &y)) {
                x = w->maxx();
                if (w->scroll) { scroll_window(w, 1, w->regtop, w->regbot, w->bkgd); x = 0; }
            } else x = 0;
        }
        break;
    }
    case '\n':
        for (int i = w->curx; i <= w->maxx(); i++) w->at(y, i) = w->bkgd;
        touch_range(w, y, w->curx, w->maxx());
        if (newline_forces_scroll(w, &y)) {
            if (w->scroll) scroll_window(w, 1, w->regtop, w->regbot, w->bkgd);
            else return XERR;
        }
        x = 0;
        w->wrapped = false;
        break;
    case '\r':
        x = 0;
        w->wrapped = false;
        break;
    case '\b':
        if (x == 0) return XOK;
        x--;
        w->wrapped = false;
        break;
    default: {
        std::string s = unctrl_str(t);
        if (wide_call && t >= 0x80 && t < 0xa0) {
            // wunctrl of a C1 control: ~@ ... ~_ as ncurses spells them
            s = "~";
            s += (char)(t - 0x80 + 64);
        }
        for (char c : s) {
            Cell sc;
            sc.ch = (unsigned char)c;
            sc.attr = ch.attr;
            sc.pair = ch.pair;
            if (add_literal(w, sc) == XERR) return XERR;
        }
        return XOK;
    }
    }
    w->curx = x;
    w->cury = y;
    return XOK;
}

bool printable(uint32_t c) {
    if (c < 32 || c == 127) return false;
    if (c >= 0x80 && c < 0xa0) return false;
    return true;
}

int waddch_nosync(Win* w, Cell ch, bool wide_call) {
    if ((ch.attr & XA_ALTCHARSET) || printable(ch.ch)) return add_literal(w, ch);
    return add_special(w, ch, wide_call);
}
int waddch(Win* w, Cell ch, bool wide_call) {
    int r = waddch_nosync(w, ch, wide_call);
    if (r == XOK) synchook(w);
    return r;
}

// a chtype (char | attributes | COLOR_PAIR) as a cell
Cell from_chtype(uint32_t ct) {
    Cell c;
    c.ch = ct & XA_CHARTEXT;
    c.attr = ct & XA_NOCOLOR;
    c.pair = (int)((ct & XA_COLOR) >> 8);
    return c;
}
uint32_t to_chtype(const Cell& c) {
    uint32_t ch = c.ch;
    return ch | (c.attr & XA_NOCOLOR) | ((uint32_t)(c.pair & 0xff) << 8) | c.wext;
}

int wmove(Win* w, int y, int x) {
    if (x >= 0 && x <= w->maxx() && y >= 0 && y <= w->maxy()) {
        w->curx = x; w->cury = y;
        w->wrapped = false;
        w->moved = true;
        return XOK;
    }
    return XERR;
}

int wclrtoeol(Win* w) {
    int y = w->cury, x = w->curx;
    if (w->wrapped && y < w->maxy()) w->wrapped = false;
    if (w->wrapped || y > w->maxy() || x > w->maxx()) return XERR;
    for (int i = x; i <= w->maxx(); i++) w->at(y, i) = w->bkgd;
    touch_range(w, y, x, w->maxx());
    synchook(w);
    return XOK;
}
int wclrtobot(Win* w) {
    for (int y = w->cury; y <= w->maxy(); y++) {
        int start = y == w->cury ? w->curx : 0;
        for (int x = start; x <= w->maxx(); x++) w->at(y, x) = w->bkgd;
        touch_range(w, y, start, w->maxx());
    }
    synchook(w);
    return XOK;
}
int werase(Win* w) {
    for (int y = 0; y < w->rows; y++) {
        for (int x = 0; x < w->cols; x++) w->at(y, x) = w->bkgd;
        touch_line(w, y);
    }
    w->curx = w->cury = 0;
    w->wrapped = false;
    synchook(w);
    return XOK;
}

int winsdelln(Win* w, int n) {
    if (n != 0) {
        scroll_window(w, -n, w->cury, w->maxy(), w->bkgd);
        synchook(w);
    }
    return XOK;
}
int wdelch(Win* w) {
    int y = w->cury;
    for (int x = w->curx; x < w->maxx(); x++) w->at(y, x) = w->at(y, x + 1);
    w->at(y, w->maxx()) = w->bkgd;
    touch_range(w, y, w->curx, w->maxx());
    synchook(w);
    return XOK;
}

int insert_cell(Win* w, Cell ch) {
    // shift the line right by the character's width at the cursor
    if (w->curx > w->maxx()) return XOK;
    int y = w->cury;
    int len = (ch.attr & XA_ALTCHARSET) ? 1 : std::max(1, wcw(ch.ch));
    if (w->curx + len > w->cols) len = 1;
    for (int x = w->maxx(); x >= w->curx + len; x--) w->at(y, x) = w->at(y, x - len);
    Cell r = render(w, ch);
    for (int i = 0; i < len; i++) {
        Cell v = r;
        v.wext = len > 1 ? (uint8_t)(i + 1) : 0;
        w->at(y, w->curx + i) = v;
    }
    // a wide character cut at the margin
    Cell& last = w->at(y, w->maxx());
    if (last.wext == 1) last = w->bkgd;
    touch_range(w, y, w->curx, w->maxx());
    w->curx += len;
    return XOK;
}
int insert_ch(Win* w, Cell ch) {
    switch (ch.ch) {
    case '\t': {
        int ts = S().tabsize > 0 ? S().tabsize : 8;
        for (int count = ts - (w->curx % ts); count > 0; count--) {
            Cell sp; sp.attr = ch.attr; sp.pair = ch.pair;
            if (insert_ch(w, sp) != XOK) return XERR;
        }
        return XOK;
    }
    case '\n': case '\r': case '\b':
        return waddch_nosync(w, ch, false);
    default:
        if (printable(ch.ch) || (ch.attr & XA_ALTCHARSET)) {
            ch.attr |= w->attrs & XA_NOCOLOR;
            return insert_cell(w, ch);
        }
        for (char c : unctrl_str(ch.ch)) {
            Cell sc; sc.ch = (unsigned char)c; sc.attr = ch.attr; sc.pair = ch.pair;
            if (insert_ch(w, sc) != XOK) return XERR;
        }
        return XOK;
    }
}

// border characters: 0 means the ACS default
uint32_t acs_ct(char letter);
int wborder(Win* w, uint32_t ls, uint32_t rs, uint32_t ts, uint32_t bs, uint32_t tl, uint32_t tr, uint32_t bl, uint32_t br) {
    if (!ls) ls = acs_ct('x');
    if (!rs) rs = acs_ct('x');
    if (!ts) ts = acs_ct('q');
    if (!bs) bs = acs_ct('q');
    if (!tl) tl = acs_ct('l');
    if (!tr) tr = acs_ct('k');
    if (!bl) bl = acs_ct('m');
    if (!br) br = acs_ct('j');
    auto R = [&](uint32_t ct) { return render(w, from_chtype(ct)); };
    Cell L = R(ls), Rr = R(rs), T = R(ts), B = R(bs), TL = R(tl), TR = R(tr), BL = R(bl), BR = R(br);
    int ex = w->maxx(), ey = w->maxy();
    for (int i = 0; i <= ex; i++) { w->at(0, i) = T; w->at(ey, i) = B; }
    for (int i = 0; i <= ey; i++) { w->at(i, 0) = L; w->at(i, ex) = Rr; }
    w->at(0, 0) = TL; w->at(0, ex) = TR; w->at(ey, 0) = BL; w->at(ey, ex) = BR;
    touchwin(w);
    synchook(w);
    return XOK;
}
int whline(Win* w, uint32_t ct, int n, bool wide_given) {
    int y = w->cury, start = w->curx, end = start + n - 1;
    if (end > w->maxx()) end = w->maxx();
    Cell ch = (ct == 0 && !wide_given) ? from_chtype(acs_ct('q')) : (wide_given ? Cell() : from_chtype(ct));
    if (wide_given) { ch.ch = ct; }
    ch = render(w, ch);
    for (int x = start; x <= end; x++) w->at(y, x) = ch;
    touch_range(w, y, start, end);
    synchook(w);
    return XOK;
}
int wvline(Win* w, uint32_t ct, int n, bool wide_given) {
    int row = w->cury, col = w->curx, end = row + n - 1;
    if (end > w->maxy()) end = w->maxy();
    Cell ch = (ct == 0 && !wide_given) ? from_chtype(acs_ct('x')) : (wide_given ? Cell() : from_chtype(ct));
    if (wide_given) { ch.ch = ct; }
    ch = render(w, ch);
    for (int y = row; y <= end; y++) { w->at(y, col) = ch; touch_range(w, y, col, col); }
    synchook(w);
    return XOK;
}

void toggle_on(attr_t& s, attr_t at) {
    if (at & XA_COLOR) s = (s & ~XA_COLOR) | at; else s |= at;
}
void toggle_off(attr_t& s, attr_t at) {
    if (at & XA_COLOR) s &= ~(at | XA_COLOR); else s &= ~at;
}

void wbkgdset(Win* w, const Cell& ch) {
    attr_t off = w->bkgd.attr | ((attr_t)(w->bkgd.pair & 0xff) << 8);
    attr_t on = ch.attr | ((attr_t)(ch.pair & 0xff) << 8);
    toggle_off(w->attrs, off);
    toggle_on(w->attrs, on);
    if (w->bkgd.pair != 0) w->pair = 0;
    if (ch.pair != 0) w->pair = ch.pair;
    Cell nb = ch;
    if (nb.ch == 0) nb.ch = ' ';
    nb.wext = 0;
    w->bkgd = nb;
    uint32_t c8 = nb.ch < 256 ? nb.ch : ' ';
    w->bkgd_ct = c8 | (nb.attr & XA_NOCOLOR) | ((uint32_t)(w->pair & 0xff) << 8);
}
int wbkgd(Win* w, const Cell& ch) {
    Cell old = w->bkgd;
    wbkgdset(w, ch);
    // wattrset(win, AttrOf(_nc_bkgd)) - the pair comes from the background
    w->attrs = w->bkgd.attr | ((attr_t)(w->bkgd.pair & 0xff) << 8);
    w->pair = w->bkgd.pair;
    for (int y = 0; y < w->rows; y++)
        for (int x = 0; x < w->cols; x++) {
            Cell& c = w->at(y, x);
            if (c == old) c = w->bkgd;
            else {
                // ncurses 6.4, as measured through CPython: the old background's
                // attributes leave every cell and the new one's join it; a cell
                // in the old background's pair takes the new one's, a cell in
                // any other pair keeps it
                c.attr = (c.attr & ~(old.attr & ~XA_ALTCHARSET)) | (w->bkgd.attr & ~XA_ALTCHARSET);
                if (c.pair == old.pair) c.pair = w->bkgd.pair;
            }
        }
    touchwin(w);
    synchook(w);
    return XOK;
}

// ── copying between windows ─────────────────────────────────────────────────
int copywin(Win* src, Win* dst, int sminrow, int smincol, int dminrow, int dmincol, int dmaxrow, int dmaxcol, bool over) {
    if (dmaxrow > dst->maxy() || dmaxcol > dst->maxx() || dminrow < 0 || dmincol < 0 || sminrow < 0 || smincol < 0)
        return XERR;
    if (sminrow + (dmaxrow - dminrow) > src->maxy() || smincol + (dmaxcol - dmincol) > src->maxx()) return XERR;
    attr_t bk = dst->bkgd.attr;
    bool touched = false;
    for (int dy = dminrow, sy = sminrow; dy <= dmaxrow; dy++, sy++) {
        bool line = false;
        for (int dx = dmincol, sx = smincol; dx <= dmaxcol; dx++, sx++) {
            Cell s = src->at(sy, sx);
            Cell& d = dst->at(dy, dx);
            if (over) {
                if (s.ch != ' ' && d != s) {
                    d = s;
                    d.attr = (s.attr) | bk;
                    if (dst->bkgd.pair) d.pair = dst->bkgd.pair;
                    line = true;
                }
            } else if (d != s) {
                d = s;
                line = true;
            }
        }
        if (line) { touch_range(dst, dy, dmincol, dmaxcol); touched = true; }
    }
    (void)touched;
    return XOK;
}
int overlap_copy(Win* src, Win* dst, bool over) {
    int sx1 = src->begx, sy1 = src->begy, sx2 = sx1 + src->cols - 1, sy2 = sy1 + src->rows - 1;
    int dx1 = dst->begx, dy1 = dst->begy, dx2 = dx1 + dst->cols - 1, dy2 = dy1 + dst->rows - 1;
    if (dx2 >= sx1 && dx1 <= sx2 && dy2 >= sy1 && dy1 <= sy2) {
        int sminrow = std::max(sy1, dy1) - sy1, smincol = std::max(sx1, dx1) - sx1;
        int dminrow = std::max(sy1, dy1) - dy1, dmincol = std::max(sx1, dx1) - dx1;
        int dmaxrow = std::min(sy2, dy2) - dy1, dmaxcol = std::min(sx2, dx2) - dx1;
        return copywin(src, dst, sminrow, smincol, dminrow, dmincol, dmaxrow, dmaxcol, over);
    }
    return XERR;
}

int wresize(Win* w, int nrows, int ncols) {
    if (nrows <= 0 || ncols <= 0) return XERR;
    if (w->parent) {
        if (w->pary + nrows > w->parent->rows || w->parx + ncols > w->parent->cols) return XERR;
        w->rows = nrows; w->cols = ncols;
    } else {
        Store ns(nrows, std::vector<Cell>(ncols, w->bkgd));
        for (int y = 0; y < std::min(nrows, w->rows); y++)
            for (int x = 0; x < std::min(ncols, w->cols); x++) ns[y][x] = w->at(y, x);
        *w->store = ns;
        w->sy = w->sx = 0;
        w->rows = nrows; w->cols = ncols;
    }
    w->fch.assign(nrows, -1);
    w->lch.assign(nrows, -1);
    if (w->regbot > nrows - 1 || w->regbot == w->regtop || true) {
        if (w->regtop > nrows - 1) w->regtop = 0;
        w->regbot = nrows - 1;
    }
    if (w->cury > nrows - 1) w->cury = nrows - 1;
    if (w->curx > ncols - 1) w->curx = ncols - 1;
    touchwin(w);
    return XOK;
}

// ═══════════════════════════════════════════════════════════════════════════
// §5 output: attributes, colors, cursor motion, doupdate
// ═══════════════════════════════════════════════════════════════════════════
// ncurses' ACS table for a UTF-8 locale (lib_wacs.c), indexed by VT100 letter
uint32_t acs_unicode(uint32_t letter) {
    switch (letter) {
    case '`': return 0x25c6; case 'a': return 0x2592; case 'b': return 0x2409; case 'c': return 0x240c;
    case 'd': return 0x240d; case 'e': return 0x240a; case 'f': return 0x00b0; case 'g': return 0x00b1;
    case 'h': return 0x2592; case 'i': return 0x240b; case 'j': return 0x2518; case 'k': return 0x2510;
    case 'l': return 0x250c; case 'm': return 0x2514; case 'n': return 0x253c; case 'o': return 0x23ba;
    case 'p': return 0x23bb; case 'q': return 0x2500; case 'r': return 0x23bc; case 's': return 0x23bd;
    case 't': return 0x251c; case 'u': return 0x2524; case 'v': return 0x2534; case 'w': return 0x252c;
    case 'x': return 0x2502; case 'y': return 0x2264; case 'z': return 0x2265; case '{': return 0x03c0;
    case '|': return 0x2260; case '}': return 0x00a3; case '~': return 0x00b7; case ',': return 0x2190;
    case '+': return 0x2192; case '.': return 0x2193; case '-': return 0x2191; case '0': return 0x25ae;
    case 'L': return 0x250f; case 'M': return 0x2517; case 'K': return 0x2513; case 'J': return 0x251b;
    case 'T': return 0x2523; case 'U': return 0x252b; case 'V': return 0x253b; case 'W': return 0x2533;
    case 'Q': return 0x2501; case 'X': return 0x2503; case 'N': return 0x254b;
    case 'C': return 0x2554; case 'D': return 0x255a; case 'B': return 0x2557; case 'A': return 0x255d;
    case 'G': return 0x2560; case 'F': return 0x2563; case 'H': return 0x2569; case 'I': return 0x2566;
    case 'R': return 0x2550; case 'Y': return 0x2551; case 'E': return 0x256c;
    }
    return letter;
}
// ncurses' ASCII fallbacks when the terminal has no acsc entry (lib_acs.c)
char acs_ascii(char letter) {
    switch (letter) {
    case 'l': case 'm': case 'k': case 'j': case 'u': case 't': case 'v': case 'w': case 'n': case '`': return '+';
    case 'q': return '-'; case 'x': return '|'; case 'o': return '~'; case 's': return '_'; case 'a': return ':';
    case 'f': return '\''; case 'g': return '#'; case '~': return 'o'; case ',': return '<'; case '+': return '>';
    case '.': return 'v'; case '-': return '^'; case 'h': return '#'; case 'i': return '#'; case '0': return '#';
    case 'p': return '-'; case 'r': return '-'; case 'y': return '<'; case 'z': return '>'; case '{': return '*';
    case '|': return '!'; case '}': return 'f';
    case 'L': case 'M': case 'K': case 'J': case 'T': case 'U': case 'V': case 'W': case 'N': return '+';
    case 'Q': return '-'; case 'X': return '|';
    case 'C': case 'D': case 'B': case 'A': case 'G': case 'F': case 'H': case 'I': case 'E': return '+';
    case 'R': return '='; case 'Y': return '|';
    }
    return 0;
}
void init_acs() {
    State& g = S();
    const char* letters = "`afghijklmnopqrstuvwxyz{|}~,+.-0LMKJTUVWQXNCDBAGFHIRYE";
    for (int i = 0; i < 128; i++) g.acs_map[i] = 0;
    if (g.utf8) {
        // a UTF-8 locale draws every ACS character (from Unicode when the
        // terminal's acsc lacks it), so each is A_ALTCHARSET | its letter
        for (const char* p = letters; *p; p++) g.acs_map[(int)*p] = XA_ALTCHARSET | (unsigned char)*p;
        return;
    }
    for (const char* p = letters; *p; p++) g.acs_map[(int)*p] = (unsigned char)acs_ascii(*p);
    if (g.c.acsc) {
        const std::string& a = *g.c.acsc;
        for (size_t i = 0; i + 1 < a.size(); i += 2) {
            unsigned char k = (unsigned char)a[i];
            if (k < 128) g.acs_map[k] = XA_ALTCHARSET | (unsigned char)a[i + 1];
        }
    }
}
uint32_t acs_ct(char letter) {
    State& g = S();
    uint32_t v = g.acs_map[(int)(unsigned char)letter & 127];
    if (!v) v = XA_ALTCHARSET | (unsigned char)letter;
    return v;
}

// what a pair looks like: (fg, bg), -1 the terminal's default
std::pair<int, int> pair_colors(int pair) {
    State& g = S();
    if (!g.color_on) return {-1, -1};
    if (pair <= 0 || pair >= (int)g.pairs.size()) {
        if (pair == 0 && !g.pairs.empty()) return g.pairs[0];
        return {-1, -1};
    }
    return g.pairs[pair];
}

bool is_sgr_seq(const std::string& s, std::string& params) {
    if (s.size() < 3 || s[0] != '\x1b' || s[1] != '[' || s.back() != 'm') return false;
    for (size_t i = 2; i + 1 < s.size(); i++) if (!((s[i] >= '0' && s[i] <= '9') || s[i] == ';')) return false;
    params = s.substr(2, s.size() - 3);
    return true;
}
// merge adjacent CSI ... m sequences into one (ECMA-48 terminals)
std::string merge_sgr(const std::vector<std::string>& parts) {
    std::string out, pend;
    bool have = false;
    for (auto& p : parts) {
        std::string prm;
        if (S().ecma48 && is_sgr_seq(p, prm)) {
            if (prm.empty()) prm = "0";
            if (have) pend += ";" + prm;
            else { pend = prm; have = true; }
            continue;
        }
        if (have) { out += "\x1b[" + pend + "m"; have = false; }
        out += p;
    }
    if (have) out += "\x1b[" + pend + "m";
    return out;
}
bool resets_all(const std::string& s) {
    return s.find("\x1b[m") != std::string::npos || s.find("\x1b[0m") != std::string::npos ||
           s.find("\x1b[0;") != std::string::npos;
}

int color_index_setf(int c) {
    // setf/setb use the other order of the eight colors
    static const int map[8] = {0, 4, 2, 6, 1, 5, 3, 7};
    if (c >= 0 && c < 8) return map[c];
    return c;
}

// the escape sequences that set the colors from (pfg, pbg) to (fg, bg)
void color_parts(std::vector<std::string>& parts, int fg, int bg, int pfg, int pbg, bool known) {
    State& g = S();
    Caps& c = g.c;
    if (known && fg == pfg && bg == pbg) return;
    bool need_op = !known || (fg == -1 && pfg != -1) || (bg == -1 && pbg != -1);
    if (need_op && c.op) {
        parts.push_back(tp(c.op, {}));
        pfg = pbg = -1;
        known = true;
    }
    if (fg >= 0 && (!known || fg != pfg)) {
        if (c.setaf) parts.push_back(tp(c.setaf, {fg}));
        else if (c.setf) parts.push_back(tp(c.setf, {color_index_setf(fg)}));
    }
    if (bg >= 0 && (!known || bg != pbg)) {
        if (c.setab) parts.push_back(tp(c.setab, {bg}));
        else if (c.setb) parts.push_back(tp(c.setb, {color_index_setf(bg)}));
    }
}

// the cheapest way from the terminal's attributes to (attr, fg, bg)
void vidattr(attr_t attr, int pair) {
    State& g = S();
    Caps& c = g.c;
    attr &= XA_NOCOLOR;
    if (g.utf8) attr &= ~XA_ALTCHARSET;      // ACS characters are written as Unicode
    std::pair<int, int> col = pair_colors(pair);
    if (attr == g.pattr && g.pcolors_known && col.first == g.pfg && col.second == g.pbg) return;
    attr_t off = g.pattr & ~attr;
    attr_t on = attr & ~g.pattr;
    struct Opt { std::vector<std::string> parts; int cost = 0; attr_t res_attr = 0; int pfg = -1, pbg = -1; bool known = false; };
    auto enter = [&](std::vector<std::string>& v, attr_t a) {
        if (a & XA_STANDOUT) { if (c.smso) v.push_back(strip_pad(*c.smso)); }
        if (a & XA_UNDERLINE) { if (c.smul) v.push_back(strip_pad(*c.smul)); }
        if (a & XA_REVERSE) { if (c.rev) v.push_back(strip_pad(*c.rev)); }
        if (a & XA_BLINK) { if (c.blink) v.push_back(strip_pad(*c.blink)); }
        if (a & XA_DIM) { if (c.dim) v.push_back(strip_pad(*c.dim)); }
        if (a & XA_BOLD) { if (c.bold) v.push_back(strip_pad(*c.bold)); }
        if (a & XA_INVIS) { if (c.invis) v.push_back(strip_pad(*c.invis)); }
        if (a & XA_PROTECT) { if (c.prot) v.push_back(strip_pad(*c.prot)); }
        if (a & XA_ITALIC) { if (c.sitm) v.push_back(strip_pad(*c.sitm)); }
        if (a & XA_ALTCHARSET) { if (c.smacs) v.push_back(strip_pad(*c.smacs)); }
    };
    auto finish = [&](Opt& o) {
        if (g.color_on) color_parts(o.parts, col.first, col.second, o.pfg, o.pbg, o.known);
        std::string s = merge_sgr(o.parts);
        o.cost = (int)s.size();
        o.parts.assign(1, s);
    };
    std::vector<Opt> opts;
    // (a) the individual exits, when every attribute going off has one that
    // does not reset everything
    {
        Opt o;
        bool ok = true;
        std::string sg0 = c.sgr0 ? strip_pad(*c.sgr0) : std::string();
        auto exit_cap = [&](attr_t bit, const std::string* cap) {
            if (!(off & bit)) return;
            if (!cap) { ok = false; return; }
            std::string s = strip_pad(*cap);
            if (s == sg0 || resets_all(s)) { ok = false; return; }
            o.parts.push_back(s);
        };
        exit_cap(XA_UNDERLINE, c.rmul);
        exit_cap(XA_STANDOUT, c.rmso);
        exit_cap(XA_ITALIC, c.ritm);
        exit_cap(XA_ALTCHARSET, c.rmacs);
        if (off & ~(XA_UNDERLINE | XA_STANDOUT | XA_ITALIC | XA_ALTCHARSET)) ok = false;
        // standout is what sgr says it is (vt100: bold and reverse, smso only reverse)
        if ((on & XA_STANDOUT) && c.sgr) ok = false;
        if (ok) {
            enter(o.parts, on);
            o.pfg = g.pfg; o.pbg = g.pbg; o.known = g.pcolors_known;
            finish(o);
            opts.push_back(o);
        }
    }
    // (b) sgr0, then everything on
    if (c.sgr0 && !((attr & XA_STANDOUT) && c.sgr)) {
        Opt o;
        std::string s = strip_pad(*c.sgr0);
        o.parts.push_back(s);
        enter(o.parts, attr);
        if (resets_all(s)) { o.pfg = o.pbg = -1; o.known = true; }
        else { o.pfg = g.pfg; o.pbg = g.pbg; o.known = g.pcolors_known; }
        if (!g.color_on) { o.known = true; o.pfg = o.pbg = -1; }
        finish(o);
        opts.push_back(o);
    }
    // (c) sgr with the nine attributes, then italics
    if (c.sgr) {
        Opt o;
        std::string s = strip_pad(tparm(*c.sgr, [&]() {
            std::vector<TPArg> v(9);
            v[0].n = (attr & XA_STANDOUT) != 0; v[1].n = (attr & XA_UNDERLINE) != 0; v[2].n = (attr & XA_REVERSE) != 0;
            v[3].n = (attr & XA_BLINK) != 0; v[4].n = (attr & XA_DIM) != 0; v[5].n = (attr & XA_BOLD) != 0;
            v[6].n = (attr & XA_INVIS) != 0; v[7].n = (attr & XA_PROTECT) != 0; v[8].n = (attr & XA_ALTCHARSET) != 0;
            return v;
        }()));
        o.parts.push_back(s);
        if ((attr & XA_ITALIC) && c.sitm) o.parts.push_back(strip_pad(*c.sitm));
        bool missing_italic = (attr & XA_ITALIC) && !c.sitm;
        (void)missing_italic;
        if (resets_all(s)) { o.pfg = o.pbg = -1; o.known = true; }
        else { o.pfg = g.pfg; o.pbg = g.pbg; o.known = g.pcolors_known; }
        if (!g.color_on) { o.known = true; o.pfg = o.pbg = -1; }
        finish(o);
        opts.push_back(o);
    }
    if (opts.empty()) {
        g.pattr = attr;
        return;
    }
    size_t best = 0;
    for (size_t i = 1; i < opts.size(); i++) if (opts[i].cost < opts[best].cost) best = i;
    out_raw(opts[best].parts[0]);
    g.pattr = attr;
    if (g.color_on) { g.pfg = col.first; g.pbg = col.second; g.pcolors_known = true; }
}

// ── cursor motion (lib_mvcur.c's cost model) ────────────────────────────────
std::string repeat(const std::string& s, int n) { std::string o; for (int i = 0; i < n; i++) o += s; return o; }

// the characters already on the screen between columns [from, to) of row,
// when rewriting them moves the cursor the same way
bool overwrite_ok(int row, int from, int to, std::string& text) {
    State& g = S();
    if (!g.curscr) return false;
    for (int x = from; x < to; x++) {
        Cell& c = g.curscr->at(row, x);
        if (c.ch == GARBAGE || c.wext || c.comb) return false;
        attr_t a = c.attr & XA_NOCOLOR;
        if (g.utf8) a &= ~XA_ALTCHARSET;
        if (a != g.pattr) return false;
        if (c.attr & XA_ALTCHARSET) return false;
        if (g.color_on) {
            auto pc = pair_colors(c.pair);
            if (!g.pcolors_known || pc.first != g.pfg || pc.second != g.pbg) return false;
        }
        if (c.ch >= 0x80) return false;
        text += (char)c.ch;
    }
    return true;
}

std::string hmove(int row, int from, int to) {
    State& g = S();
    Caps& c = g.c;
    if (from == to) return std::string();
    std::string best;
    int bc = INT_MAX;
    auto consider = [&](const std::string& s, bool valid) {
        if (valid && (int)s.size() < bc) { bc = (int)s.size(); best = s; }
    };
    int n = to - from;
    if (n > 0) {
        if (c.cuf1) consider(repeat(strip_pad(*c.cuf1), n), true);
        if (c.cuf) consider(tp(c.cuf, {n}), true);
        std::string text;
        if (overwrite_ok(row, from, to, text)) consider(text, true);
        // tabs (the default stops every `it` columns), then the rest
        if (c.ht && c.it > 0) {
            int x = from;
            std::string tabs;
            while ((x / c.it + 1) * c.it <= to) { tabs += strip_pad(*c.ht); x = (x / c.it + 1) * c.it; }
            if (!tabs.empty()) {
                int rest = to - x;
                std::string r1 = rest == 0 ? std::string() : (c.cuf1 ? repeat(strip_pad(*c.cuf1), rest) : std::string(1, '\x01'));
                std::string r2 = rest == 0 ? std::string() : (c.cuf ? tp(c.cuf, {rest}) : std::string(1, '\x01'));
                std::string r = (!r1.empty() && r1[0] == '\x01') ? r2 : ((!r2.empty() && r2[0] == '\x01') ? r1 : (r1.size() <= r2.size() ? r1 : r2));
                if (r.empty() || r[0] != '\x01') consider(tabs + r, true);
            }
        }
    } else {
        int m = -n;
        if (c.cub1) consider(repeat(strip_pad(*c.cub1), m), true);
        if (c.cub) consider(tp(c.cub, {m}), true);
    }
    if (c.hpa) consider(tp(c.hpa, {to}), true);
    if (bc == INT_MAX) return std::string(1, '\x01');   // impossible
    return best;
}
std::string vmove(int from, int to) {
    State& g = S();
    Caps& c = g.c;
    if (from == to) return std::string();
    std::string best;
    int bc = INT_MAX;
    auto consider = [&](const std::string& s) { if ((int)s.size() < bc) { bc = (int)s.size(); best = s; } };
    int n = to - from;
    if (n > 0) {
        // \n is a plain line feed: initscr turned ONLCR off
        if (c.cud1) consider(repeat(strip_pad(*c.cud1), n));
        if (c.cud) consider(tp(c.cud, {n}));
    } else {
        if (c.cuu1) consider(repeat(strip_pad(*c.cuu1), -n));
        if (c.cuu) consider(tp(c.cuu, {-n}));
    }
    if (c.vpa) consider(tp(c.vpa, {to}));
    if (bc == INT_MAX) return std::string(1, '\x01');
    return best;
}
bool bad(const std::string& s) { return !s.empty() && s[0] == '\x01'; }

void goto_yx(int y, int x) {
    State& g = S();
    Caps& c = g.c;
    if (g.py == y && g.px == x) return;
    // moves with attributes on need msgr; insert mode needs mir
    if (!c.msgr && g.pattr) vidattr(0, 0);
    if (g.pins && !c.mir) { out_cap(c.rmir); g.pins = false; }
    std::string best;
    int bc = INT_MAX;
    auto consider = [&](const std::string& s) { if (!bad(s) && (int)s.size() < bc) { bc = (int)s.size(); best = s; } };
    if (c.cup) consider(tp(c.cup, {y, x}));
    if (g.py >= 0 && g.px >= 0) {
        std::string v = vmove(g.py, y), h = hmove(y, g.px, x);
        if (!bad(v) && !bad(h)) consider(v + h);
        if (c.cr) {
            std::string h0 = hmove(y, 0, x);
            if (!bad(v) && !bad(h0)) consider(strip_pad(*c.cr) + v + h0);
        }
    }
    if (c.home) {
        std::string v = vmove(0, y), h = hmove(y, 0, x);
        if (!bad(v) && !bad(h)) consider(strip_pad(*c.home) + v + h);
    }
    if (g.py >= 0 && g.px < 0 && c.cr) {
        // the column is unknown (pending wrap) but the row is not
        std::string v = vmove(g.py, y), h0 = hmove(y, 0, x);
        if (!bad(v) && !bad(h0)) consider(strip_pad(*c.cr) + v + h0);
    }
    if (bc == INT_MAX) return;
    out_raw(best);
    g.py = y;
    g.px = x;
}

// one cell to the terminal at the cursor
void emit_char(const Cell& ch) {
    State& g = S();
    vidattr(ch.attr, ch.pair);
    std::string s;
    uint32_t cp = ch.ch;
    if (ch.attr & XA_ALTCHARSET) {
        if (g.utf8) {
            // the cell holds acs_map's terminal character: back to the letter
            uint32_t letter = cp;
            if (g.c.acsc) {
                const std::string& a = *g.c.acsc;
                for (size_t i = 0; i + 1 < a.size(); i += 2)
                    if ((unsigned char)a[i + 1] == cp) { letter = (unsigned char)a[i]; break; }
            }
            utf8_put(s, acs_unicode(letter));
        } else s += (char)cp;
    } else if (cp == GARBAGE) {
        s += ' ';
    } else if (g.utf8) {
        utf8_put(s, cp);
        if (ch.comb) for (char32_t m : g_comb[ch.comb]) utf8_put(s, (uint32_t)m);
    } else {
        s += cp < 256 ? (char)cp : '?';
    }
    out_raw(s);
}

// PutChar with the lower-right corner rule (tty_update.c's PutCharLR)
void put_cell(int row, int col, const Cell& ch) {
    State& g = S();
    Caps& c = g.c;
    int w = (ch.wext == 1) ? 2 : 1;
    bool lr = row == g.lines - 1 && col + w - 1 == g.cols - 1;
    if (lr && c.am) {
        if (c.rmam && c.smam) {
            out_cap(c.rmam);
            emit_char(ch);
            out_cap(c.smam);
            g.px = -1;
            g.py = -1;
            return;
        }
        if (!c.xenl) {
            // no way to write the last cell without scrolling: leave it
            return;
        }
    }
    emit_char(ch);
    g.px += w;
    if (g.px >= g.cols) {
        if (c.am && c.xenl) { g.px = -1; }       // hung at the margin
        else if (c.am) { g.px = 0; g.py++; }
        else g.px = g.cols - 1;
    }
}

bool can_clear_with(const Cell& ch) {
    State& g = S();
    if (!g.c.bce && g.color_on) {
        auto pc = pair_colors(ch.pair);
        if (pc.first != -1 || pc.second != -1) return false;
    }
    return ch.ch == ' ' && ch.comb == 0 && ch.wext == 0 && (ch.attr & ~(NONBLANK_ATTR | XA_COLOR)) == 0;
}

void clr_to_eol(int row, int col, const Cell& blank) {
    State& g = S();
    vidattr(blank.attr, blank.pair);
    out_cap(g.c.el);
    for (int x = col; x < g.cols; x++) g.curscr->at(row, x) = blank;
}

// EmitRange: cells [first, first + num) of the new line at the cursor
int emit_range(int row, const std::vector<Cell>& nl, int first, int num) {
    State& g = S();
    Caps& c = g.c;
    int i = first, end = first + num;
    while (i < end) {
        const Cell& ch = nl[i];
        if (ch.wext == 2) { i++; continue; }
        int run = 1;
        while (i + run < end && nl[i + run] == ch && ch.wext == 0) run++;
        if (run > 1 && c.ech && run > g.cost_ech + g.cost_cup && can_clear_with(ch)) {
            vidattr(ch.attr, ch.pair);
            out_tp(c.ech, {run});
            for (int k = 0; k < run; k++) g.curscr->at(row, i + k) = ch;
            i += run;
            // ech leaves the cursor where it was
            if (i < end) goto_yx(row, i);
            else return 1;
            continue;
        }
        if (run > 1 && c.rep && run > g.cost_rep && ch.ch < 128 && !(ch.attr & XA_ALTCHARSET) && ch.comb == 0 &&
            !(row == g.lines - 1 && i + run >= g.cols)) {
            vidattr(ch.attr, ch.pair);
            bool wrap_possible = g.px + run >= g.cols;
            int rc = wrap_possible ? run - 1 : run;
            out_tp(c.rep, {(int64_t)ch.ch, rc});
            g.px += rc;
            for (int k = 0; k < rc; k++) g.curscr->at(row, i + k) = ch;
            i += rc;
            if (wrap_possible) { put_cell(row, i, ch); g.curscr->at(row, i) = ch; i++; }
            continue;
        }
        for (int k = 0; k < run; k++) {
            put_cell(row, i, ch);
            g.curscr->at(row, i) = ch;
            if (ch.wext == 1 && i + 1 < g.cols) g.curscr->at(row, i + 1) = nl[i + 1];
            i += ch.wext == 1 ? 2 : 1;
        }
    }
    return 0;
}

// PutRange: like emit_range, but runs of cells already right are skipped
// over with a move when that is cheaper than rewriting them
int put_range(int row, const std::vector<Cell>& ol, const std::vector<Cell>& nl, int first, int last) {
    State& g = S();
    if (last - first + 1 > g.cost_inline) {
        int same = 0, j;
        for (j = first; j <= last; j++) {
            if (!same && ol[j].wext == 2) continue;
            if (ol[j] == nl[j]) same++;
            else {
                if (same > g.cost_inline) {
                    emit_range(row, nl, first, j - same - first);
                    goto_yx(row, first = j);
                }
                same = 0;
            }
        }
        int r = emit_range(row, nl, first, j - same - first);
        return same == 0 ? r : 1;
    }
    return emit_range(row, nl, first, last - first + 1);
}

void ins_str(int row, const std::vector<Cell>& nl, int at, int count) {
    State& g = S();
    Caps& c = g.c;
    if (c.ich && count > 1) {
        out_tp(c.ich, {count});
        // the inserted blanks, then the text over them
        auto& cl = g.curscr->store->at(row);
        for (int k = 0; k < count; k++) { cl.insert(cl.begin() + at, Cell()); cl.pop_back(); }
        g.px = at;
        emit_range(row, nl, at, count);
        return;
    }
    if (c.smir && c.rmir) {
        if (!g.pins) { out_cap(c.smir); g.pins = true; }
        auto& cl = g.curscr->store->at(row);
        for (int k = 0; k < count; k++) {
            cl.insert(cl.begin() + at + k, nl[at + k]);
            cl.pop_back();
            emit_char(nl[at + k]);
            g.px++;
            if (c.ip) out_cap(c.ip);
        }
        out_cap(c.rmir);
        g.pins = false;
        return;
    }
    auto& cl = g.curscr->store->at(row);
    for (int k = 0; k < count; k++) {
        out_cap(c.ich1);
        cl.insert(cl.begin() + at + k, nl[at + k]);
        cl.pop_back();
        emit_char(nl[at + k]);
        g.px++;
    }
}
void del_char(int row, int at, int count, const Cell& blank) {
    State& g = S();
    Caps& c = g.c;
    if (c.dch && (count > 1 || !c.dch1)) out_tp(c.dch, {count});
    else for (int k = 0; k < count; k++) out_cap(c.dch1);
    auto& cl = g.curscr->store->at(row);
    for (int k = 0; k < count; k++) { cl.erase(cl.begin() + at); cl.push_back(blank); }
}
int ins_cost(int n) {
    State& g = S();
    Caps& c = g.c;
    if (c.ich) return (int)tp(c.ich, {n}).size() + n;
    if (c.smir && c.rmir) return cost_of(c.smir) + cost_of(c.rmir) + n;
    if (c.ich1) return (cost_of(c.ich1) + 1) * n;
    return 100000;
}
int del_cost(int n) {
    State& g = S();
    Caps& c = g.c;
    if (c.dch) return (int)tp(c.dch, {n}).size();
    if (c.dch1) return cost_of(c.dch1) * n;
    return 100000;
}

// TransformLine (tty_update.c)
void transform_line(int row) {
    State& g = S();
    Caps& c = g.c;
    std::vector<Cell>& nl = g.newscr->store->at(row);
    std::vector<Cell> ol = g.curscr->store->at(row);
    int cols = g.cols;
    int first = 0;
    Cell blank = Cell();
    if (c.el1 && can_clear_with(nl[0])) {
        blank = nl[0];
        int of, nf;
        for (of = 0; of < cols; of++) if (ol[of] != blank) break;
        for (nf = 0; nf < cols; nf++) if (nl[nf] != blank) break;
        if (nf == of) {
            first = nf;
            while (first < cols && nl[first] == ol[first]) first++;
        } else if (of > nf) {
            first = nf;
        } else {
            first = of;
            if (g.cost_el1 < nf - of) {
                if (nf >= cols && g.cost_el <= g.cost_el1) {
                    goto_yx(row, 0);
                    vidattr(blank.attr, blank.pair);
                    out_cap(c.el);
                } else {
                    goto_yx(row, nf - 1);
                    vidattr(blank.attr, blank.pair);
                    out_cap(c.el1);
                }
                while (first < nf) { ol[first] = blank; g.curscr->at(row, first) = blank; first++; }
            }
        }
    } else {
        while (first < cols && nl[first] == ol[first]) first++;
    }
    if (first >= cols) return;
    // a wide character starts the change
    if (first > 0 && nl[first].wext == 2) first--;
    blank = nl[cols - 1];
    if (!can_clear_with(blank) || !c.el) {
        int nlast = cols - 1;
        while (nlast > first && nl[nlast] == ol[nlast]) nlast--;
        if (nlast < cols - 1 && nl[nlast].wext == 1) nlast++;
        if (nlast >= first) {
            goto_yx(row, first);
            put_range(row, ol, nl, first, nlast);
        }
        for (int x = first; x <= nlast; x++) g.curscr->at(row, x) = nl[x];
        return;
    }
    int olast = cols - 1;
    while (olast > first && ol[olast] == blank) olast--;
    int nlast = cols - 1;
    while (nlast > first && nl[nlast] == blank) nlast--;
    if (nlast == first && g.cost_el < olast - nlast) {
        goto_yx(row, first);
        if (nl[first] != blank) { put_cell(row, first, nl[first]); }
        clr_to_eol(row, first + (nl[first] != blank ? (nl[first].wext == 1 ? 2 : 1) : 0), blank);
        if (nl[first] != blank) g.curscr->at(row, first) = nl[first];
        if (nl[first].wext == 1 && first + 1 < cols) g.curscr->at(row, first + 1) = nl[first + 1];
    } else if (nlast != olast && (nl[nlast] != ol[olast] || !(c.ich || c.ich1 || (c.smir && c.rmir)))) {
        goto_yx(row, first);
        if (olast - nlast > g.cost_el) {
            put_range(row, ol, nl, first, nlast);
            goto_yx(row, nlast + 1);
            clr_to_eol(row, nlast + 1, blank);
        } else {
            int n = std::max(nlast, olast);
            put_range(row, ol, nl, first, n);
        }
    } else {
        int nlastnb = nlast, olastnb = olast;
        // the last characters that really differ
        while (nlast >= 0 && olast >= 0 && nl[nlast] == ol[olast]) {
            if (nl[nlast].wext == 2 && nlast > 0 && olast > 0 && nl[nlast - 1] != ol[olast - 1]) break;
            nlast--;
            olast--;
            if (nlast == -1 || olast == -1) break;
        }
        int n = std::min(olast, nlast);
        if (n >= first) {
            goto_yx(row, first);
            put_range(row, ol, nl, first, n);
        }
        if (olast < nlast) {
            int m = std::max(nlastnb, olastnb);
            goto_yx(row, n + 1);
            if (nlast < nlastnb || ins_cost(nlast - olast) > m - n) {
                put_range(row, g.curscr->store->at(row), nl, n + 1, m);
            } else {
                ins_str(row, nl, n + 1, nlast - olast);
            }
        } else if (olast > nlast) {
            goto_yx(row, n + 1);
            if (del_cost(olast - nlast) > g.cost_el + nlastnb - (n + 1)) {
                put_range(row, g.curscr->store->at(row), nl, n + 1, nlastnb);
                goto_yx(row, nlastnb + 1);
                clr_to_eol(row, nlastnb + 1, blank);
            } else {
                vidattr(blank.attr, blank.pair);
                del_char(row, n + 1, olast - nlast, blank);
            }
        }
    }
    // the physical screen now shows the new line
    for (int x = first; x < cols; x++) g.curscr->at(row, x) = nl[x];
}

void clear_screen(const Cell& blank) {
    State& g = S();
    Caps& c = g.c;
    bool fast = true;
    if (g.color_on && !c.bce) {
        auto pc = pair_colors(blank.pair);
        if (pc.first != -1 || pc.second != -1) fast = false;
    }
    if (fast && c.clear) {
        vidattr(blank.attr, blank.pair);
        out_cap(c.clear);
        g.py = g.px = 0;
    } else if (fast && c.ed) {
        g.py = g.px = -1;
        goto_yx(0, 0);
        vidattr(blank.attr, blank.pair);
        out_cap(c.ed);
    } else if (fast && c.el) {
        for (int i = 0; i < g.lines; i++) { goto_yx(i, 0); vidattr(blank.attr, blank.pair); out_cap(c.el); }
        goto_yx(0, 0);
    } else {
        for (int i = 0; i < g.lines; i++) {
            goto_yx(i, 0);
            for (int j = 0; j < g.cols; j++) put_cell(i, j, blank);
        }
        goto_yx(0, 0);
    }
    for (int y = 0; y < g.lines; y++) for (int x = 0; x < g.cols; x++) g.curscr->at(y, x) = blank;
}

Cell clr_blank() {
    State& g = S();
    Cell b;
    if (g.c.bce && g.stdscr) b.pair = g.stdscr->bkgd.pair;
    return b;
}

int clr_bottom(int total) {
    State& g = S();
    Caps& c = g.c;
    int top = total;
    int last = g.cols;
    Cell blank = g.newscr->at(total - 1, last - 1);
    if (c.ed && can_clear_with(blank)) {
        for (int row = total - 1; row >= 0; row--) {
            bool ok = true;
            for (int col = 0; ok && col < last; col++) ok = g.newscr->at(row, col) == blank;
            if (!ok) break;
            for (int col = 0; ok && col < last; col++) ok = g.curscr->at(row, col) == blank;
            if (!ok) top = row;
        }
        if (top < total) {
            goto_yx(top, 0);
            vidattr(blank.attr, blank.pair);
            out_cap(c.ed);
            for (int y = top; y < g.lines; y++) for (int x = 0; x < g.cols; x++) g.curscr->at(y, x) = blank;
        }
    }
    return top;
}

// ── scrolling: hashmap.c and hardscroll.c ───────────────────────────────────
uint64_t line_hash(Win* w, int row) {
    uint64_t r = 0;
    auto& l = w->store->at(row);
    for (int x = 0; x < (int)l.size(); x++) {
        const Cell& c = l[x];
        uint64_t v = (uint64_t)c.ch * 31u + c.attr * 7u + (uint64_t)c.pair * 131u + c.wext + (uint64_t)c.comb * 1009u;
        r += (r << 5) + v;
    }
    return r;
}
int update_cost(const std::vector<Cell>& a, const std::vector<Cell>& b) {
    int n = 0;
    for (size_t i = 0; i < a.size(); i++) if (a[i] != b[i]) n++;
    return n;
}
int update_cost_blank(const std::vector<Cell>& b) {
    Cell blank;
    int n = 0;
    for (auto& c : b) if (c != blank) n++;
    return n;
}

struct HashMap {
    std::vector<int> oldnum;
    std::vector<uint64_t> oh, nh;
};
HashMap g_hm;

bool cost_effective(int from, int to, bool blank) {
    State& g = S();
    if (from == to) return false;
    int new_from = g_hm.oldnum[from];
    if (new_from < 0) new_from = from;
    auto& O = *g.curscr->store;
    auto& N = *g.newscr->store;
    int before = (blank ? update_cost_blank(N[to]) : update_cost(O[to], N[to])) + update_cost(O[new_from], N[from]);
    int after = (new_from == from ? update_cost_blank(N[from]) : update_cost(O[new_from], N[from])) + update_cost(O[from], N[to]);
    return before >= after;
}

void grow_hunks() {
    State& g = S();
    int L = g.lines;
    auto& on = g_hm.oldnum;
    int back_limit = 0, back_ref_limit = 0;
    int i = 0, next_hunk;
    while (i < L && on[i] < 0) i++;
    for (; i < L; i = next_hunk) {
        int start = i, shift = on[i] - i;
        i = start + 1;
        while (i < L && on[i] >= 0 && on[i] - i == shift) i++;
        int end = i;
        while (i < L && on[i] < 0) i++;
        next_hunk = i;
        int forward_limit = i, forward_ref_limit;
        if (i >= L || on[i] >= i) forward_ref_limit = i;
        else forward_ref_limit = on[i];
        i = start - 1;
        if (shift < 0) back_limit = back_ref_limit + (-shift);
        while (i >= back_limit) {
            if (i + shift < 0 || i + shift >= L) break;
            if (g_hm.nh[i] == g_hm.oh[i + shift] || cost_effective(i + shift, i, shift < 0)) {
                on[i] = i + shift;
            } else break;
            i--;
        }
        i = end;
        if (shift > 0) forward_limit = forward_ref_limit - shift;
        while (i < forward_limit) {
            if (i + shift < 0 || i + shift >= L) break;
            if (g_hm.nh[i] == g_hm.oh[i + shift] || cost_effective(i + shift, i, shift > 0)) {
                on[i] = i + shift;
            } else break;
            i++;
        }
        back_ref_limit = back_limit = i;
        if (shift > 0) back_ref_limit += shift;
    }
}

void hash_map() {
    State& g = S();
    int L = g.lines;
    g_hm.oldnum.assign(L, -1);
    g_hm.oh.resize(L);
    g_hm.nh.resize(L);
    for (int i = 0; i < L; i++) { g_hm.oh[i] = line_hash(g.curscr, i); g_hm.nh[i] = line_hash(g.newscr, i); }
    struct HE { uint64_t h; int oc = 0, nc = 0, oi = 0, ni = 0; };
    std::unordered_map<uint64_t, HE> tab;
    for (int i = 0; i < L; i++) { auto& e = tab[g_hm.oh[i]]; e.h = g_hm.oh[i]; e.oc++; e.oi = i; }
    for (int i = 0; i < L; i++) { auto& e = tab[g_hm.nh[i]]; e.h = g_hm.nh[i]; e.nc++; e.ni = i; }
    for (auto& kv : tab) {
        auto& e = kv.second;
        if (e.oc == 1 && e.nc == 1 && e.oi != e.ni) g_hm.oldnum[e.ni] = e.oi;
    }
    grow_hunks();
    auto& on = g_hm.oldnum;
    for (int i = 0; i < L;) {
        while (i < L && on[i] < 0) i++;
        if (i >= L) break;
        int start = i, shift = on[i] - i;
        i++;
        while (i < L && on[i] >= 0 && on[i] - i == shift) i++;
        int size = i - start;
        if (size < 3 || size + std::min(size / 8, 2) < std::abs(shift)) {
            while (start < i) { on[start] = -1; start++; }
        }
    }
    grow_hunks();
}

void scroll_curscr(int n, int top, int bot) {
    State& g = S();
    Cell blank = clr_blank();
    auto& O = *g.curscr->store;
    if (n > 0) {
        for (int line = top; line <= bot - n; line++) O[line] = O[line + n];
        for (int line = bot; line > bot - n && line >= top; line--) O[line].assign(g.cols, blank);
    } else {
        int m = -n;
        for (int line = bot; line >= top + m; line--) O[line] = O[line - m];
        for (int line = top; line < top + m && line <= bot; line++) O[line].assign(g.cols, blank);
    }
}

bool scroll_csr_forward(int n, int top, int bot, int miny, int maxy, const Cell& blank) {
    State& g = S();
    Caps& c = g.c;
    if (n == 1 && c.ind && top == miny && bot == maxy) {
        goto_yx(bot, 0); vidattr(blank.attr, blank.pair); out_cap(c.ind);
    } else if (n == 1 && c.dl1 && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); out_cap(c.dl1);
    } else if (c.indn && top == miny && bot == maxy) {
        goto_yx(bot, 0); vidattr(blank.attr, blank.pair); out_tp(c.indn, {n});
    } else if (c.dl && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); out_tp(c.dl, {n});
    } else if (c.ind && top == miny && bot == maxy) {
        goto_yx(bot, 0); vidattr(blank.attr, blank.pair); for (int i = 0; i < n; i++) out_cap(c.ind);
    } else if (c.dl1 && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); for (int i = 0; i < n; i++) out_cap(c.dl1);
    } else return false;
    return true;
}
bool scroll_csr_backward(int n, int top, int bot, int miny, int maxy, const Cell& blank) {
    State& g = S();
    Caps& c = g.c;
    if (n == 1 && c.ri && top == miny && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); out_cap(c.ri);
    } else if (n == 1 && c.il1 && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); out_cap(c.il1);
    } else if (c.rin && top == miny && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); out_tp(c.rin, {n});
    } else if (c.il && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); out_tp(c.il, {n});
    } else if (c.ri && top == miny && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); for (int i = 0; i < n; i++) out_cap(c.ri);
    } else if (c.il1 && bot == maxy) {
        goto_yx(top, 0); vidattr(blank.attr, blank.pair); for (int i = 0; i < n; i++) out_cap(c.il1);
    } else return false;
    return true;
}
bool scroll_idl(int n, int del, int ins, const Cell& blank) {
    State& g = S();
    Caps& c = g.c;
    if (!((c.dl || c.dl1) && (c.il || c.il1))) return false;
    goto_yx(del, 0);
    vidattr(blank.attr, blank.pair);
    if (n == 1 && c.dl1) out_cap(c.dl1);
    else if (c.dl) out_tp(c.dl, {n});
    else for (int i = 0; i < n; i++) out_cap(c.dl1);
    goto_yx(ins, 0);
    vidattr(blank.attr, blank.pair);
    if (n == 1 && c.il1) out_cap(c.il1);
    else if (c.il) out_tp(c.il, {n});
    else for (int i = 0; i < n; i++) out_cap(c.il1);
    return true;
}

bool scrolln(int n, int top, int bot, int maxy) {
    State& g = S();
    Caps& c = g.c;
    Cell blank = clr_blank();
    bool res;
    bool idlok = g.stdscr && g.stdscr->idl;
    if (n > 0) {
        res = scroll_csr_forward(n, top, bot, 0, maxy, blank);
        if (!res && c.csr) {
            bool saved = false;
            if (((n == 1 && c.ind) || c.indn) && (g.py == bot || g.py == bot - 1) && c.sc && c.rc) {
                saved = true;
                out_cap(c.sc);
            }
            out_tp(c.csr, {top, bot});
            if (saved) out_cap(c.rc); else g.py = g.px = -1;
            res = scroll_csr_forward(n, top, bot, top, bot, blank);
            out_tp(c.csr, {0, maxy});
            g.py = g.px = -1;
        }
        if (!res && idlok) res = scroll_idl(n, top, bot - n + 1, blank);
    } else {
        res = scroll_csr_backward(-n, top, bot, 0, maxy, blank);
        if (!res && c.csr) {
            bool saved = false;
            if (top != 0 && (g.py == top || g.py == top - 1) && c.sc && c.rc) {
                saved = true;
                out_cap(c.sc);
            }
            out_tp(c.csr, {top, bot});
            if (saved) out_cap(c.rc); else g.py = g.px = -1;
            res = scroll_csr_backward(-n, top, bot, top, bot, blank);
            out_tp(c.csr, {0, maxy});
            g.py = g.px = -1;
        }
        if (!res && idlok) res = scroll_idl(-n, bot + n + 1, top, blank);
    }
    if (!res) return false;
    scroll_curscr(n, top, bot);
    // the old hashes move too
    if ((int)g_hm.oh.size() == g.lines) {
        std::vector<uint64_t> oh = g_hm.oh;
        if (n > 0) { for (int i = top; i <= bot - n; i++) g_hm.oh[i] = oh[i + n]; for (int i = bot - n + 1; i <= bot; i++) if (i >= top) g_hm.oh[i] = line_hash(g.curscr, i); }
        else { int m = -n; for (int i = bot; i >= top + m; i--) g_hm.oh[i] = oh[i - m]; for (int i = top; i < top + m && i <= bot; i++) g_hm.oh[i] = line_hash(g.curscr, i); }
    }
    return true;
}

void scroll_optimize() {
    State& g = S();
    int L = g.lines;
    hash_map();
    auto& on = g_hm.oldnum;
    for (int i = 0; i < L;) {
        while (i < L && (on[i] < 0 || on[i] <= i)) i++;
        if (i >= L) break;
        int shift = on[i] - i, start = i;
        i++;
        while (i < L && on[i] >= 0 && on[i] - i == shift) i++;
        int end = i - 1 + shift;
        if (end >= L) end = L - 1;
        scrolln(shift, start, end, L - 1);
    }
    for (int i = L - 1; i >= 0;) {
        while (i >= 0 && (on[i] < 0 || on[i] >= i)) i--;
        if (i < 0) break;
        int shift = on[i] - i, end = i;
        i--;
        while (i >= 0 && on[i] >= 0 && on[i] - i == shift) i--;
        int start = i + 1 - (-shift);
        if (start < 0) start = 0;
        scrolln(shift, start, end, L - 1);
    }
}

void tty_prog();
void resume_screen();

// doupdate: the virtual screen to the terminal
void do_update() {
    State& g = S();
    if (!g.started) return;
    if (g.in_endwin) resume_screen();
    g.updates++;
    if (g.mode == "naive") {
        // the baseline the optimizer is measured against: every line that
        // changed is repainted whole, from an absolute move
        bool full = g.curscr->clr || g.newscr->clr;
        if (full) clear_screen(clr_blank());
        for (int y = 0; y < g.lines; y++) {
            bool changed = full || g.newscr->fch[y] >= 0;
            if (!changed) continue;
            g.py = g.px = -1;
            goto_yx(y, 0);
            auto& nl = g.newscr->store->at(y);
            for (int x = 0; x < g.cols;) {
                if (y == g.lines - 1 && x == g.cols - 1 && g.c.am && !(g.c.rmam && g.c.smam) && !g.c.xenl) break;
                put_cell(y, x, nl[x]);
                g.curscr->at(y, x) = nl[x];
                if (nl[x].wext == 1 && x + 1 < g.cols) g.curscr->at(y, x + 1) = nl[x + 1];
                x += nl[x].wext == 1 ? 2 : 1;
                if (g.px < 0 && x < g.cols) { g.py = g.px = -1; goto_yx(y, x); }
            }
        }
        g.curscr->clr = g.newscr->clr = false;
    } else if (g.curscr->clr || g.newscr->clr) {
        clear_screen(clr_blank());
        int nonempty = clr_bottom(g.lines);
        for (int i = 0; i < nonempty; i++) transform_line(i);
        g.curscr->clr = g.newscr->clr = false;
    } else {
        if (g.mode != "noscroll" && ((g.c.ind && g.c.ri) || ((g.c.rin || g.c.il || g.c.il1) && (g.c.indn || g.c.dl || g.c.dl1))))
            scroll_optimize();
        int nonempty = clr_bottom(g.lines);
        for (int i = 0; i < nonempty; i++) {
            if (g.newscr->fch[i] >= 0 || g.newscr->store->at(i) != g.curscr->store->at(i)) transform_line(i);
        }
    }
    for (int i = 0; i < g.lines; i++) { g.newscr->fch[i] = -1; g.newscr->lch[i] = -1; }
    if (!g.newscr->leave) {
        g.curscr->cury = g.newscr->cury;
        g.curscr->curx = g.newscr->curx;
        goto_yx(g.newscr->cury, g.newscr->curx);
    }
    out_flush();
}

int wnoutrefresh(Win* w) {
    State& g = S();
    if (!g.started || w->is_pad) return XERR;
    Win* N = g.newscr;
    N->bkgd = w->bkgd;
    N->attrs = w->attrs;
    wsyncdown(w);
    int limit_x = w->maxx();
    if (limit_x > N->maxx() - w->begx) limit_x = N->maxx() - w->begx;
    for (int sr = 0, dr = w->begy; sr <= w->maxy() && dr <= N->maxy(); sr++, dr++) {
        if (dr < 0) { w->fch[sr] = w->lch[sr] = -1; continue; }
        if (w->fch[sr] >= 0) {
            int last = w->lch[sr];
            if (last > limit_x) last = limit_x;
            int sc = w->fch[sr], dc = sc + w->begx;
            if (sc <= last) {
                // whole wide characters at both ends
                if (w->at(sr, sc).wext == 2 && sc > 0) { sc--; dc--; }
                if (last < w->maxx() && w->at(sr, last).wext == 1 && last + 1 <= limit_x) last++;
                int ld = w->begx + last;
                int fl = dc, fr = ld;
                if (dc >= 0 && dc <= N->maxx() && N->at(dr, dc).wext == 2 && dc > 0) fl = dc - 1;
                if (ld + 1 <= N->maxx() && N->at(dr, ld).wext == 1) fr = ld + 1;
                if (fl < dc || fr > ld) for (int j = fl; j <= fr; j++) if (j >= 0 && j <= N->maxx()) { N->at(dr, j) = Cell(); touch_range(N, dr, j, j); }
                for (; sc <= last; sc++, dc++) {
                    if (dc < 0 || dc > N->maxx()) continue;
                    if (w->at(sr, sc) != N->at(dr, dc)) { N->at(dr, dc) = w->at(sr, sc); touch_range(N, dr, dc, dc); }
                }
            }
        }
        w->fch[sr] = w->lch[sr] = -1;
    }
    if (w->clr) { w->clr = false; N->clr = true; }
    if (!w->leave) { N->cury = w->cury + w->begy; N->curx = w->curx + w->begx; }
    N->leave = w->leave;
    w->moved = false;
    return XOK;
}

int pnoutrefresh(Win* w, int pminrow, int pmincol, int sminrow, int smincol, int smaxrow, int smaxcol) {
    State& g = S();
    if (!g.started || !w->is_pad) return XERR;
    Win* N = g.newscr;
    if (pminrow < 0) pminrow = 0;
    if (pmincol < 0) pmincol = 0;
    if (sminrow < 0) sminrow = 0;
    if (smincol < 0) smincol = 0;
    int pmaxrow = pminrow + smaxrow - sminrow, pmaxcol = pmincol + smaxcol - smincol;
    if (smaxrow >= g.lines || smaxcol >= g.cols || sminrow > smaxrow || smincol > smaxcol) return XERR;
    if (pmaxrow > w->maxy()) { smaxrow -= pmaxrow - w->maxy(); pmaxrow = pminrow + smaxrow - sminrow; }
    if (pmaxcol > w->maxx()) { smaxcol -= pmaxcol - w->maxx(); pmaxcol = pmincol + smaxcol - smincol; }
    if (smaxrow < sminrow || smaxcol < smincol) return XERR;
    for (int i = pminrow, m = sminrow; i <= pmaxrow && m <= N->maxy(); i++, m++) {
        for (int j = pmincol, n = smincol; j <= pmaxcol; j++, n++) {
            Cell ch = w->at(i, j);
            if (ch.wext == 2 && j == pmincol) ch = Cell();              // half a wide char at the left edge
            if (ch.wext == 1 && j == pmaxcol) ch = Cell();              // or at the right
            if (ch != N->at(m, n)) { N->at(m, n) = ch; touch_range(N, m, n, n); }
        }
        w->fch[i] = w->lch[i] = -1;
    }
    if (!w->leave && w->cury >= pminrow && w->curx >= pmincol && w->cury <= pmaxrow && w->curx <= pmaxcol) {
        N->cury = w->cury - pminrow + w->begy + sminrow;
        N->curx = w->curx - pmincol + w->begx + smincol;
    }
    N->leave = w->leave;
    w->moved = false;
    w->pad_y = pminrow; w->pad_x = pmincol; w->pad_top = sminrow; w->pad_left = smincol;
    w->pad_bottom = smaxrow; w->pad_right = smaxcol;
    return XOK;
}

int wrefresh(Win* w) {
    State& g = S();
    if (!g.started) return XERR;
    if (w == g.curscr) { g.curscr->clr = true; do_update(); return XOK; }
    if (w->is_pad) return XERR;
    int r = wnoutrefresh(w);
    if (r == XOK) do_update();
    return r;
}

void redrawln(Win* w, int beg, int num) {
    State& g = S();
    if (!g.started) return;
    for (int i = beg; i < beg + num && i < w->rows; i++) {
        int crow = w->begy + i;
        if (crow < 0 || crow >= g.lines) continue;
        for (int x = 0; x < w->cols; x++) {
            int cx = w->begx + x;
            if (cx >= 0 && cx < g.cols) g.curscr->at(crow, cx).ch = GARBAGE;
        }
        touch_line(w, i);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// §6 the terminal: tty modes, size, initscr/endwin
// ═══════════════════════════════════════════════════════════════════════════
#ifndef _WIN32
void winch_handler(int) {
    g_winch = 1;
    if (g_winch_pipe[1] >= 0) { char c = 1; ssize_t r = ::write(g_winch_pipe[1], &c, 1); (void)r; }
}
void install_winch() {
    struct sigaction old;
    if (sigaction(SIGWINCH, nullptr, &old) != 0) return;
    if (old.sa_handler != SIG_DFL && old.sa_handler != SIG_IGN && old.sa_handler != winch_handler) return;
    if (g_winch_pipe[0] < 0) {
        if (pipe(g_winch_pipe) != 0) return;
        for (int k = 0; k < 2; k++) {
            fcntl(g_winch_pipe[k], F_SETFL, fcntl(g_winch_pipe[k], F_GETFL) | O_NONBLOCK);
            fcntl(g_winch_pipe[k], F_SETFD, FD_CLOEXEC);
        }
    }
    struct sigaction sa;
    std::memset(&sa, 0, sizeof sa);
    sa.sa_handler = winch_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGWINCH, &sa, nullptr);
}
#endif

void get_size(int& lines, int& cols) {
    State& g = S();
    lines = cols = 0;
#ifdef _WIN32
    CONSOLE_SCREEN_BUFFER_INFO bi;
    if (GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &bi)) {
        cols = bi.srWindow.Right - bi.srWindow.Left + 1;
        lines = bi.srWindow.Bottom - bi.srWindow.Top + 1;
    }
#else
    struct winsize ws;
    if (ioctl(g.ofd, TIOCGWINSZ, &ws) == 0 || ioctl(g.ifd, TIOCGWINSZ, &ws) == 0) {
        lines = ws.ws_row;
        cols = ws.ws_col;
    }
#endif
    if (g.use_env) {
        if (const char* l = std::getenv("LINES")) { int v = std::atoi(l); if (v > 0) lines = v; }
        if (const char* c = std::getenv("COLUMNS")) { int v = std::atoi(c); if (v > 0) cols = v; }
    }
    if (lines <= 0) lines = g.c.lines > 0 ? g.c.lines : 24;
    if (cols <= 0) cols = g.c.cols > 0 ? g.c.cols : 80;
    if (g.filtered) lines = 1;
}

#ifndef _WIN32
bool tty_get(struct termios& t) { return tcgetattr(S().ifd, &t) == 0 || tcgetattr(S().ofd, &t) == 0; }
void tty_set(const struct termios& t) {
    State& g = S();
    if (tcsetattr(g.ifd, TCSADRAIN, &t) != 0) tcsetattr(g.ofd, TCSADRAIN, &t);
    g.cur_tty = t;
}
#endif

// the program mode from the current flags (ncurses' _nc_initscr plus cbreak/raw)
void tty_prog() {
    State& g = S();
    if (!g.have_tty) return;
#ifndef _WIN32
    struct termios t = g.cur_tty;
    t.c_lflag &= ~(ECHO | ECHONL);
    t.c_iflag &= ~(ICRNL | INLCR | IGNCR);
    t.c_oflag &= ~(ONLCR);
    if (g.raw) {
        t.c_lflag &= ~(ICANON | ISIG | IEXTEN);
        t.c_iflag &= ~(IXON | BRKINT | PARMRK);
    } else {
        t.c_lflag |= ISIG | IEXTEN;
        t.c_iflag |= IXON;
        if (g.cbreak) t.c_lflag &= ~ICANON;
        else { t.c_lflag |= ICANON; }
    }
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    tty_set(t);
#else
    HANDLE hin = GetStdHandle(STD_INPUT_HANDLE), hout = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD im = 0x0200 /* ENABLE_VIRTUAL_TERMINAL_INPUT */;
    if (!g.raw) im |= ENABLE_PROCESSED_INPUT;
    if (!g.cbreak && !g.raw) im |= ENABLE_LINE_INPUT;
    SetConsoleMode(hin, im);
    DWORD om = ENABLE_PROCESSED_OUTPUT | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */ | 0x0008 /* DISABLE_NEWLINE_AUTO_RETURN */;
    SetConsoleMode(hout, om);
#endif
}

void tty_save_shell() {
    State& g = S();
#ifndef _WIN32
    if (tty_get(g.shell_tty)) { g.have_tty = true; g.cur_tty = g.shell_tty; g.meta = (g.shell_tty.c_cflag & CSIZE) == CS8 && !(g.shell_tty.c_iflag & ISTRIP); }
#else
    if (GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &g.shell_in)) g.have_tty = true;
    GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &g.shell_out);
#endif
}
void tty_restore_shell() {
    State& g = S();
    if (!g.have_tty) return;
#ifndef _WIN32
    tty_set(g.shell_tty);
#else
    SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), g.shell_in);
    SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), g.shell_out);
#endif
}

void build_keys();
void init_costs() {
    State& g = S();
    Caps& c = g.c;
    g.cost_cup = c.cup ? (int)tp(c.cup, {23, 23}).size() : 1000;
    g.cost_hpa = c.hpa ? (int)tp(c.hpa, {23}).size() : 1000;
    g.cost_el = c.el ? cost_of(c.el) : 1000;
    g.cost_el1 = c.el1 ? cost_of(c.el1) : 1000;
    g.cost_ech = c.ech ? (int)tp(c.ech, {23}).size() : 1000;
    g.cost_rep = c.rep ? (int)tp(c.rep, {' ', 23}).size() : 1000;
    g.cost_inline = std::min(g.cost_cup, g.cost_hpa);
    std::string s0 = c.sgr0 ? strip_pad(*c.sgr0) : std::string();
    g.ecma48 = s0 == "\x1b[m" || s0 == "\x1b[0m" || s0 == "\x1b(B\x1b[m" || s0 == "\x1b[m\x0f" || s0 == "\x1b[0m\x0f" ||
               s0 == "\x1b(B\x1b[0m";
}

bool locale_utf8() {
    const char* v = std::getenv("LC_ALL");
    if (!v || !*v) v = std::getenv("LC_CTYPE");
    if (!v || !*v) v = std::getenv("LANG");
    if (!v || !*v) return true;                 // C/POSIX: Nython (and CPython 3.7+) run in UTF-8
    std::string s = v;
    for (auto& ch : s) ch = (char)std::tolower((unsigned char)ch);
    if (s == "c" || s == "posix") return true;
    return s.find("utf-8") != std::string::npos || s.find("utf8") != std::string::npos;
}

void start_screen_output() {
    State& g = S();
    Caps& c = g.c;
    out_cap(c.enacs);
    out_cap(c.smcup);
    if (c.csr) out_tp(c.csr, {0, g.lines - 1});
    g.py = g.px = -1;
    out_cap(c.sgr0);
    g.pattr = 0;
    g.pfg = g.pbg = -1;
    g.pcolors_known = true;
    if (c.smir) out_cap(c.rmir);
    g.pins = false;
    if (c.smam && c.am) out_cap(c.smam);
}

void resume_screen() {
    State& g = S();
    g.in_endwin = false;
    tty_prog();
    start_screen_output();
    if (g.pkeypad) { out_cap(g.c.smkx); }
    if (g.pcurs != 1) {
        if (g.pcurs == 0) out_cap(g.c.civis); else out_cap(g.c.cvvis);
    }
    if (g.pmouse && g.mouse_mask) {
        if (g.c.XM) out_tp(g.c.XM, {1}); else out_raw("\x1b[?1000h");
    }
    g.curscr->clr = true;
}

int do_setupterm(const std::string& term, int fd, std::string& err) {
    State& g = S();
    TermInfo ti;
    int r = ti_load(term, ti);
    if (r != 0) {
        err = r == -1 ? "setupterm: could not find terminfo database" : "setupterm: could not find terminal";
        return XERR;
    }
    g.ti = ti;
    g.setup = true;
    g.ofd = fd >= 0 ? fd : 1;
    load_caps();
    return XOK;
}

Win* make_screen_win(int rows, int cols) {
    Win* w = new Win();
    w->id = 0;
    w->rows = rows; w->cols = cols;
    w->store = std::make_shared<Store>(rows, std::vector<Cell>(cols));
    w->fch.assign(rows, -1);
    w->lch.assign(rows, -1);
    w->regbot = rows - 1;
    return w;
}

int do_initscr() {
    State& g = S();
    if (g.started) {
        // a second initscr is a refresh
        return g.stdscr->id;
    }
    if (const char* m = std::getenv("NY_CURSES_UPDATE")) if (*m) g.mode = m;
    g.utf8 = locale_utf8();
    tty_save_shell();
    if (const char* e = std::getenv("ESCDELAY")) { int v = std::atoi(e); if (v > 0) g.escdelay = v; }
    if (const char* t = std::getenv("TABSIZE")) { int v = std::atoi(t); if (v > 0) g.tabsize = v; }
    get_size(g.lines, g.cols);
    g.started = true;
    g.cbreak = true;
    g.echo = true;
    g.nl = true;
    tty_prog();
#ifndef _WIN32
    if (g.have_tty) { g.prog_tty = g.cur_tty; g.have_prog = true; }
    install_winch();
#else
    tty_prog();
#endif
    init_costs();
    init_acs();
    build_keys();
    g.curscr = make_screen_win(g.lines, g.cols);
    g.newscr = make_screen_win(g.lines, g.cols);
    g.curscr->clr = true;
    g.stdscr = win_new(g.lines, g.cols, 0, 0, false);
    g.stdscr->clr = true;
    start_screen_output();
    out_flush();
    return g.stdscr->id;
}

int do_endwin() {
    State& g = S();
    if (!g.started || g.in_endwin) return XERR;
    Caps& c = g.c;
    // ncurses' order: _mouse_wrap, _nc_screen_wrap, _nc_mvcur_wrap, reset_shell_mode
    if (g.pmouse) {
        if (c.XM) out_tp(c.XM, {0}); else out_raw("\x1b[?1000l");
        if (g.mouse_mask & ((uint64_t)1 << 28)) out_raw("\x1b[?1003l");
    }
    if (g.pattr) { out_cap(c.sgr0); g.pattr = 0; }
    if (g.pins) { out_cap(c.rmir); g.pins = false; }
    if (g.color_on && c.op) { out_cap(c.op); g.pfg = g.pbg = -1; }
    if (g.color_on && !g.default_colors && c.el) {
        // the bottom line is cleared in the terminal's own colors
        goto_yx(g.lines - 1, 0);
        out_cap(c.el);
        if (g.curscr && g.curscr->rows == g.lines)
            for (int x = 0; x < g.curscr->cols; x++) g.curscr->at(g.lines - 1, x) = Cell();
    }
    goto_yx(g.lines - 1, 0);
    if (g.pcurs != 1) out_cap(c.cnorm);
    out_cap(c.rmcup);
    out_raw("\r");               // resets the terminal's tab counter, as ncurses does
    // reset_shell_mode turns the keypad off whatever it was; getch turns it
    // back on after a resume
    out_cap(c.rmkx);
    g.pkeypad = false;
    out_flush();
    tty_restore_shell();
    g.in_endwin = true;
    // the refresh that comes back repaints stdscr's content and what is
    // refreshed after it, not the other windows shown before (ncurses does)
    if (g.stdscr && g.newscr && g.stdscr->rows == g.newscr->rows && g.stdscr->cols == g.newscr->cols)
        for (int y = 0; y < g.lines; y++)
            for (int x = 0; x < g.cols; x++) g.newscr->at(y, x) = g.stdscr->at(y, x);
    g.py = g.px = -1;
    return XOK;
}

// ═══════════════════════════════════════════════════════════════════════════
// §7 colors
// ═══════════════════════════════════════════════════════════════════════════
int do_start_color() {
    State& g = S();
    if (!g.started) return XERR;
    if (g.c.colors <= 0 || !(g.c.setaf || g.c.setf)) return XERR;
    g.COLORS = g.c.colors > 0x7fff ? 0x7fff : g.c.colors;
    int pairs = g.c.pairs > 0 ? g.c.pairs : 64;
    if (pairs > 0x10000) pairs = 0x10000;
    g.COLOR_PAIRS = pairs;
    g.pairs.assign(pairs, {0, 0});
    g.pair_used.assign(pairs, false);
    g.default_fg = 7;
    g.default_bg = 0;
    g.pairs[0] = {g.default_fg, g.default_bg};
    g.palette.assign(g.COLORS, {0, 0, 0});
    for (int i = 0; i < g.COLORS; i++) {
        int k = i % 8, v = i < 8 ? 680 : 1000;
        g.palette[i] = {(k & 1) ? v : 0, (k & 2) ? v : 0, (k & 4) ? v : 0};
    }
    g.color_on = true;
    if (g.c.op) { out_cap(g.c.op); }
    g.pfg = g.pbg = -1;
    g.pcolors_known = true;
    return XOK;
}

int do_init_pair(int pair, int fg, int bg) {
    State& g = S();
    if (!g.color_on || pair < 1 || pair >= g.COLOR_PAIRS) return XERR;
    if (!g.default_colors && (fg < 0 || bg < 0)) return XERR;
    if (fg >= g.COLORS || bg >= g.COLORS || fg < -1 || bg < -1) return XERR;
    auto old = g.pairs[pair];
    g.pairs[pair] = {fg, bg};
    if (old != g.pairs[pair] && g.curscr) {
        // cells of this pair already on the screen are repainted
        for (int y = 0; y < g.lines; y++) {
            bool ch = false;
            for (int x = 0; x < g.cols; x++) if (g.curscr->at(y, x).pair == pair) { g.curscr->at(y, x).ch = GARBAGE; ch = true; }
            if (ch) touch_line(g.newscr, y);
        }
    }
    return XOK;
}

// ═══════════════════════════════════════════════════════════════════════════
// §8 input
// ═══════════════════════════════════════════════════════════════════════════
void trie_add(const std::string& s, int code) {
    if (s.empty() || code == 0) return;
    Trie* t = &S().keys;
    for (unsigned char ch : s) {
        auto& k = t->kids[ch];
        if (!k) k.reset(new Trie());
        t = k.get();
    }
    t->code = code;
}
bool trie_has_code(const Trie& t, int code) {
    if (t.code == code) return true;
    for (auto& kv : t.kids) if (trie_has_code(*kv.second, code)) return true;
    return false;
}
bool key_defined(const std::string& s) {
    const Trie* t = &S().keys;
    for (unsigned char ch : s) {
        auto it = t->kids.find(ch);
        if (it == t->kids.end()) return false;
        t = it->second.get();
    }
    return t->code != 0;
}
void build_keys() {
    State& g = S();
    g.keys = Trie();
    for (auto& fk : TI_FKEYS) {
        if (fk.cap < NSTR && g.ti.sok[fk.cap] == 1) trie_add(g.ti.s[fk.cap], fk.code);
    }
    for (size_t i = 0; i < g.ti.xs.size(); i++) {
        const std::string& nm = g.ti.xs[i];
        if (nm.empty() || nm[0] != 'k') continue;
        if (g.ti.sok[NSTR + i] != 1) continue;
        const std::string& v = g.ti.s[NSTR + i];
        if (v.empty() || key_defined(v)) continue;
        trie_add(v, (int)i + XKEY_MAX);
    }
}

// one byte from the terminal, waiting up to timeout_ms (< 0: forever);
// -1 on a timeout, -2 on a resize
int read_byte(int timeout_ms) {
    State& g = S();
#ifndef _WIN32
    int64_t deadline = timeout_ms >= 0 ? now_ms() + timeout_ms : -1;
    while (true) {
        if (g_winch) return -2;
        std::vector<nyconc::IoReq> reqs(1);
        reqs[0].fd = g.ifd;
        reqs[0].events = nyconc::IO_READ;
        if (g_winch_pipe[0] >= 0) {
            nyconc::IoReq r2;
            r2.fd = g_winch_pipe[0];
            r2.events = nyconc::IO_READ;
            reqs.push_back(r2);
        }
        double left = -1;
        if (deadline >= 0) { left = (double)(deadline - now_ms()); if (left < 0) left = 0; }
        int n = nyconc::wait_io_many(reqs, left);
        if (g_winch) return -2;
        if (reqs.size() > 1 && reqs[1].revents) {
            char buf[64];
            while (::read(g_winch_pipe[0], buf, sizeof buf) > 0) {}
            if (g_winch) return -2;
        }
        if (n > 0 && reqs[0].revents) {
            unsigned char ch;
            ssize_t r;
            { nyconc::GilRelease un; r = ::read(g.ifd, &ch, 1); }
            if (r == 1) return ch;
            if (r == 0) return -1;
            if (errno == EINTR || errno == EAGAIN) continue;
            return -1;
        }
        if (deadline >= 0 && now_ms() >= deadline) return -1;
        if (n == 0 && deadline < 0) continue;
    }
#else
    HANDLE h = GetStdHandle(STD_INPUT_HANDLE);
    int64_t deadline = timeout_ms >= 0 ? now_ms() + timeout_ms : -1;
    while (true) {
        int lines, cols;
        get_size(lines, cols);
        if (g.started && (lines != g.lines || cols != g.cols)) return -2;
        DWORD wait = 50;
        if (deadline >= 0) { int64_t left = deadline - now_ms(); if (left < 0) left = 0; if (left < wait) wait = (DWORD)left; }
        DWORD r;
        { nyconc::GilRelease un; r = WaitForSingleObject(h, wait); }
        if (r == WAIT_OBJECT_0) {
            // console events that are not key presses are dropped
            INPUT_RECORD rec;
            DWORD got = 0;
            if (PeekConsoleInputW(h, &rec, 1, &got) && got == 1 && rec.EventType != KEY_EVENT) {
                ReadConsoleInputW(h, &rec, 1, &got);
                continue;
            }
            unsigned char ch;
            DWORD rd = 0;
            BOOL ok;
            { nyconc::GilRelease un; ok = ReadFile(h, &ch, 1, &rd, nullptr); }
            if (ok && rd == 1) return ch;
            if (!ok) return -1;
            continue;
        }
        if (deadline >= 0 && now_ms() >= deadline) return -1;
    }
#endif
}

int do_resizeterm(int lines, int cols);
// the next raw input: a pushed-back code, a byte, ERR, KEY_RESIZE
int fifo_get(int timeout_ms) {
    State& g = S();
    if (!g.fifo.empty()) { int v = g.fifo.front(); g.fifo.pop_front(); return v; }
    int b = read_byte(timeout_ms);
    if (b == -2) {
#ifndef _WIN32
        g_winch = 0;
#endif
        int l, c;
        get_size(l, c);
        do_resizeterm(l, c);
        return XKEY_RESIZE;
    }
    return b < 0 ? XERR : b;
}

uint64_t MASK(int b, uint64_t m) { return m << ((b - 1) * 5); }
const uint64_t B_RELEASED = 1, B_PRESSED = 2, B_CLICKED = 4, B_DOUBLE = 010, B_TRIPLE = 020;
const uint64_t B_CTRL = (uint64_t)1 << 25, B_SHIFT = (uint64_t)1 << 26, B_ALT = (uint64_t)1 << 27, B_POSITION = (uint64_t)1 << 28;

// the rest of a mouse report after kmous; true with an event
bool read_mouse(MouseEv& ev, bool sgr, int timeout) {
    State& g = S();
    ev = MouseEv();
    if (sgr) {
        int params[3] = {0, 0, 0}, k = 0;
        int final = 0;
        while (true) {
            int b = fifo_get(timeout);
            if (b == XERR || b == XKEY_RESIZE) return false;
            if (b >= '0' && b <= '9') { if (k < 3) params[k] = params[k] * 10 + (b - '0'); }
            else if (b == ';') { k++; }
            else { final = b; break; }
        }
        if (final != 'M' && final != 'm') return false;
        int b = params[0];
        int b3 = 1 + (b & 3);
        bool wheel = (b & 64) == 64;
        if (b >= 64) b3 = 4 + (b & 3);
        if (final == 'M') {
            if (wheel) {
                if ((b & 3) == 0) ev.bstate = MASK(4, B_PRESSED);
                else if ((b & 3) == 1) ev.bstate = MASK(5, B_PRESSED);
                else ev.bstate = B_POSITION;
            } else if ((b & 3) == 3) {
                ev.bstate = B_POSITION;
            } else if (b & 32) {
                ev.bstate = B_POSITION;
            } else {
                ev.bstate = MASK(b3, B_PRESSED);
                g.mouse_held |= MASK(b3, B_PRESSED);
            }
        } else {
            if (b3 <= 5 && (g.mouse_held & MASK(b3, B_PRESSED))) {
                ev.bstate = MASK(b3, B_RELEASED);
                g.mouse_held &= ~MASK(b3, B_PRESSED);
            } else ev.bstate = B_POSITION;
        }
        if (b & 4) ev.bstate |= B_SHIFT;
        if (b & 8) ev.bstate |= B_ALT;
        if (b & 16) ev.bstate |= B_CTRL;
        ev.x = params[1] ? params[1] - 1 : 0;
        ev.y = params[2] ? params[2] - 1 : 0;
        return true;
    }
    int c[3];
    for (int i = 0; i < 3; i++) { c[i] = fifo_get(timeout); if (c[i] == XERR || c[i] == XKEY_RESIZE) return false; }
    int intro = c[0] - 32;
    if ((intro & 3) == 3 && !(intro & 64)) {
        ev.bstate = 0;
        for (int b = 1; b <= 3; b++) if (g.mouse_held & MASK(b, B_PRESSED)) ev.bstate |= MASK(b, B_RELEASED);
        g.mouse_held = 0;
        if (!ev.bstate) ev.bstate = B_POSITION;
    } else if (intro & 64) {
        ev.bstate = (intro & 3) == 0 ? MASK(4, B_PRESSED) : MASK(5, B_PRESSED);
    } else {
        int b = (intro & 3) + 1;
        ev.bstate = MASK(b, B_PRESSED);
        g.mouse_held |= MASK(b, B_PRESSED);
    }
    if (intro & 4) ev.bstate |= B_SHIFT;
    if (intro & 8) ev.bstate |= B_ALT;
    if (intro & 16) ev.bstate |= B_CTRL;
    ev.x = c[1] - 33;
    ev.y = c[2] - 33;
    return true;
}

// clicks from press/release pairs (lib_mouse.c's _nc_mouse_parse, simplified)
std::vector<MouseEv> mouse_merge(std::vector<MouseEv> evs) {
    State& g = S();
    uint64_t mask = g.mouse_mask;
    std::vector<MouseEv> out;
    for (size_t i = 0; i < evs.size(); i++) {
        MouseEv e = evs[i];
        bool merged = false;
        for (int b = 1; b <= 5; b++) {
            if ((e.bstate & MASK(b, B_PRESSED)) && i + 1 < evs.size() && (evs[i + 1].bstate & MASK(b, B_RELEASED)) &&
                (mask & MASK(b, B_CLICKED | B_DOUBLE | B_TRIPLE))) {
                MouseEv c = e;
                c.bstate = (e.bstate & ~MASK(b, B_PRESSED)) | MASK(b, B_CLICKED);
                // a click right after a click
                if (!out.empty() && (out.back().bstate & MASK(b, B_CLICKED)) && (mask & MASK(b, B_DOUBLE))) {
                    out.back().bstate = (out.back().bstate & ~MASK(b, B_CLICKED)) | MASK(b, B_DOUBLE);
                } else if (!out.empty() && (out.back().bstate & MASK(b, B_DOUBLE)) && (mask & MASK(b, B_TRIPLE))) {
                    out.back().bstate = (out.back().bstate & ~MASK(b, B_DOUBLE)) | MASK(b, B_TRIPLE);
                } else out.push_back(c);
                i++;
                merged = true;
                break;
            }
        }
        if (!merged) out.push_back(e);
    }
    std::vector<MouseEv> kept;
    for (auto& e : out) {
        uint64_t mods = e.bstate & (B_CTRL | B_SHIFT | B_ALT);
        uint64_t rest = e.bstate & ~mods;
        if (rest & mask) kept.push_back(e);
    }
    return kept;
}

int key_decode(Win* w, int first, bool forever) {
    State& g = S();
    const Trie* t = &g.keys;
    std::vector<int> seen;
    int ch = first;
    while (true) {
        if (ch == XERR || ch == XKEY_RESIZE || ch >= 256) {
            if (seen.empty()) return ch;
            // the sequence stopped: give back what was read
            if (ch != XERR) g.fifo.push_front(ch);
            break;
        }
        auto it = t->kids.find((unsigned char)ch);
        if (it == t->kids.end()) {
            if (seen.empty()) return ch;
            g.fifo.push_front(ch);
            break;
        }
        seen.push_back(ch);
        t = it->second.get();
        if (t->code) {
            if (t->code == XKEY_MOUSE && g.c.kmous) {
                bool sgr = strip_pad(*g.c.kmous) == "\x1b[<";
                std::vector<MouseEv> evs;
                MouseEv ev;
                if (!read_mouse(ev, sgr, g.escdelay)) return XERR;
                evs.push_back(ev);
                // more reports inside the click interval are read too
                while (g.mouse_interval > 0) {
                    int b = fifo_get(g.mouse_interval);
                    if (b == XERR) break;
                    // only another report continues the event
                    std::string km = strip_pad(*g.c.kmous);
                    std::vector<int> got{b};
                    bool is_mouse = b == (unsigned char)km[0];
                    for (size_t k = 1; is_mouse && k < km.size(); k++) {
                        int nb = fifo_get(g.escdelay);
                        got.push_back(nb);
                        if (nb != (unsigned char)km[k]) is_mouse = false;
                    }
                    if (!is_mouse) {
                        for (auto r = got.rbegin(); r != got.rend(); ++r) if (*r != XERR) g.fifo.push_front(*r);
                        break;
                    }
                    if (!read_mouse(ev, sgr, g.escdelay)) break;
                    evs.push_back(ev);
                }
                auto kept = mouse_merge(evs);
                if (kept.empty()) return -3;      // nothing the mask asked for: read on
                for (auto& e : kept) g.mouse_q.push_back(e);
                return XKEY_MOUSE;
            }
            return t->code;
        }
        if (t->kids.empty()) break;
        int timeout = forever ? -1 : g.escdelay;
        ch = fifo_get(timeout);
        if (ch == XERR) break;
    }
    // no key: the first byte now, the rest stays queued
    for (size_t i = seen.size(); i-- > 1;) g.fifo.push_front(seen[i]);
    return seen[0];
}

bool g_in_getch = false;
// wgetch (lib_getch.c); -1 on ERR
int wgetch(Win* w, bool for_wch = false) {
    State& g = S();
    if (!g.started) return XERR;
    if (w->keypad != g.pkeypad) {
        out_cap(w->keypad ? g.c.smkx : g.c.rmkx);
        g.pkeypad = w->keypad;
    }
    if ((is_touched(w) || w->moved) && !w->is_pad) wrefresh(w);
    out_flush();
    int timeout = w->delay;
    if (g.halfdelay > 0 && timeout < 0) timeout = g.halfdelay * 100;
    int ch;
    while (true) {
        int first = fifo_get(timeout);
        if (first == XERR) return XERR;
        if (w->keypad && first < 256) {
            ch = key_decode(w, first, w->notimeout);
            if (ch == -3) continue;
        } else ch = first;
        break;
    }
    if (ch == XERR) return XERR;
    if (ch < 256) {
        if (ch == '\r' && g.nl) ch = '\n';
        if (!g.meta && (ch & 0x80)) ch &= 0x7f;
    }
    if (g.echo && !w->is_pad && !for_wch) {
        int back = ch == XKEY_BACKSPACE ? '\b' : ch;
        if (back < XKEY_MIN) {
            Cell c = from_chtype((uint32_t)back & 0xff);
            waddch(w, c, false);
            wrefresh(w);
        }
    }
    return ch;
}

int do_resizeterm(int lines, int cols) {
    State& g = S();
    if (!g.started || lines <= 0 || cols <= 0) return XERR;
    if (lines == g.lines && cols == g.cols) return XOK;
    int ol = g.lines, oc = g.cols;
    g.lines = lines;
    g.cols = cols;
    // windows that touched the old edges follow them; the others are cut
    for (auto& kv : g_wins) {
        Win* w = kv.second;
        if (w->dead || w->is_pad || w->parent) continue;
        int nr = w->rows, nc = w->cols;
        if (w == g.stdscr) { nr = lines; nc = cols; }
        else {
            if (w->begy + w->rows == ol && w->begy < lines) nr = lines - w->begy;
            if (w->begx + w->cols == oc && w->begx < cols) nc = cols - w->begx;
            if (w->begy + nr > lines) nr = std::max(1, lines - w->begy);
            if (w->begx + nc > cols) nc = std::max(1, cols - w->begx);
        }
        if (nr != w->rows || nc != w->cols) wresize(w, nr, nc);
    }
    for (Win* sw : {g.curscr, g.newscr}) {
        Store ns(lines, std::vector<Cell>(cols));
        for (int y = 0; y < std::min(lines, sw->rows); y++)
            for (int x = 0; x < std::min(cols, sw->cols); x++) ns[y][x] = sw->at(y, x);
        *sw->store = ns;
        sw->rows = lines; sw->cols = cols;
        sw->fch.assign(lines, -1);
        sw->lch.assign(lines, -1);
        sw->regbot = lines - 1;
        if (sw->cury >= lines) sw->cury = lines - 1;
        if (sw->curx >= cols) sw->curx = cols - 1;
    }
    g.curscr->clr = true;
    if (g.c.csr) { out_tp(g.c.csr, {0, lines - 1}); g.py = g.px = -1; }
    for (auto& kv : g_wins) if (!kv.second->dead) touchwin(kv.second);
    return XOK;
}

// get_wch: a whole character from UTF-8 input, or a key code
// returns [kind, value]: kind 0 none, 1 char (value: code point), 2 key code
std::pair<int, int> wget_wch(Win* w) {
    State& g = S();
    int b = wgetch(w, true);
    if (b == XERR) return {0, 0};
    if (b >= 256) return {2, b};
    if (b < 0x80 || !g.utf8) {
        if (g.echo && !w->is_pad) { Cell c; c.ch = (uint32_t)b; waddch(w, c, true); wrefresh(w); }
        return {1, b};
    }
    int need = utf8_len((unsigned char)b);
    std::string s(1, (char)b);
    for (int i = 1; i < need; i++) {
        int nb = fifo_get(g.escdelay);
        if (nb == XERR || nb >= 256 || (nb & 0xC0) != 0x80) {
            if (nb != XERR) g.fifo.push_front(nb);
            break;
        }
        s += (char)nb;
    }
    auto cps = utf8_decode(s);
    uint32_t cp = cps.empty() ? 0xFFFD : cps[0];
    if (g.echo && !w->is_pad) { Cell c; c.ch = cp; waddch(w, c, true); wrefresh(w); }
    return {1, (int)cp};
}

// WipeOut (lib_getstr.c)
void wipe_out(Win* w, int y, int x, std::vector<std::string>& chars, bool echoed) {
    if (chars.empty()) return;
    chars.pop_back();
    if (echoed) {
        int y1 = w->cury, x1 = w->curx;
        wmove(w, y, x);
        for (auto& s : chars) for (uint32_t cp : utf8_decode(s)) { Cell c; c.ch = cp; waddch(w, c, true); }
        int ny = w->cury, nx = w->curx;
        while (w->cury < y1 || (w->cury == y1 && w->curx < x1)) { Cell sp; waddch(w, sp, true); }
        wmove(w, ny, nx);
    }
}

// wgetnstr: one line, with erase and kill, echoed as typed when echo is on
std::string wgetnstr(Win* w, int maxlen, bool& err) {
    State& g = S();
    err = false;
    bool oldnl = g.nl, oldecho = g.echo, oldraw = g.raw, oldcbreak = g.cbreak;
    g.nl = true; g.echo = false; g.raw = false; g.cbreak = true;
    tty_prog();
    int erasec = 0x7f, killc = 0x15;
#ifndef _WIN32
    if (g.have_tty) { erasec = (unsigned char)g.shell_tty.c_cc[VERASE]; killc = (unsigned char)g.shell_tty.c_cc[VKILL]; }
#endif
    int y = w->cury, x = w->curx;
    if (is_touched(w) || w->moved) wrefresh(w);
    std::vector<std::string> chars;   // the characters typed so far (UTF-8 each)
    size_t len = 0;
    int ch;
    std::string partial;
    while ((ch = wgetch(w)) != XERR) {
        if (ch == '\n' || ch == '\r' || ch == XKEY_DOWN || ch == XKEY_ENTER) {
            if (oldecho && w->cury == w->maxy() && w->scroll) { Cell nlc; nlc.ch = '\n'; waddch(w, nlc, false); wrefresh(w); }
            break;
        }
        if (ch == XKEY_RESIZE) break;
        if (ch == erasec || ch == XKEY_LEFT || ch == XKEY_BACKSPACE || ch == 8) {
            if (!chars.empty()) { len -= chars.back().size(); wipe_out(w, y, x, chars, oldecho); }
        } else if (ch == killc) {
            while (!chars.empty()) { len -= chars.back().size(); wipe_out(w, y, x, chars, oldecho); }
        } else if (ch >= XKEY_MIN || (int)len >= maxlen) {
            if (g.c.bel) { out_cap(g.c.bel); out_flush(); }
        } else {
            partial += (char)ch;
            int need = utf8_len((unsigned char)partial[0]);
            if (need == 0) need = 1;
            if ((int)partial.size() < need) continue;
            chars.push_back(partial);
            len += partial.size();
            std::string got = partial;
            partial.clear();
            if (oldecho) {
                int oldy = w->cury;
                bool failed = false;
                for (uint32_t cp : utf8_decode(got)) { Cell c; c.ch = cp; if (waddch(w, c, true) == XERR) failed = true; }
                if (failed) {
                    w->wrapped = false;
                    Cell sp; waddch(w, sp, true);
                    len -= chars.back().size();
                    wipe_out(w, y, x, chars, oldecho);
                    continue;
                } else if (w->wrapped) {
                    if (w->scroll && oldy == w->maxy() && w->cury == w->maxy()) { if (--y <= 0) y = 0; }
                    w->wrapped = false;
                }
                wrefresh(w);
            }
        }
    }
    w->curx = 0;
    w->wrapped = false;
    if (w->cury < w->maxy()) w->cury++;
    wrefresh(w);
    g.nl = oldnl; g.echo = oldecho; g.raw = oldraw; g.cbreak = oldcbreak;
    tty_prog();
    std::string out;
    for (auto& s : chars) out += s;
    if (ch == XERR) err = true;
    return out;
}

std::string keyname_of(int k) {
    State& g = S();
    if (k < 0) return std::string();
    if (k < 256) return unctrl_str((unsigned)k);
    for (auto& kn : TI_KEYNAMES) if (kn.code == k) return kn.name;
    if (k >= XKEY_MAX) {
        size_t i = (size_t)(k - XKEY_MAX);
        if (i < g.ti.xs.size()) return g.ti.xs[i];
    }
    return std::string();
}

// putwin/getwin: Nython's own format (not ncurses'): "NYCURSESWIN1\n",
// then the numbers of the window, then each cell as five numbers
std::string putwin(Win* w) {
    std::ostringstream o;
    o << "NYCURSESWIN1\n" << w->rows << ' ' << w->cols << ' ' << w->begy << ' ' << w->begx << ' ' << w->cury << ' '
      << w->curx << ' ' << w->attrs << ' ' << w->pair << ' ' << w->bkgd.ch << ' ' << w->bkgd.attr << ' ' << w->bkgd.pair
      << ' ' << (int)w->scroll << ' ' << (int)w->keypad << ' ' << w->delay << ' ' << w->regtop << ' ' << w->regbot
      << ' ' << (int)w->is_pad << '\n';
    for (int y = 0; y < w->rows; y++) {
        for (int x = 0; x < w->cols; x++) {
            Cell& c = w->at(y, x);
            o << c.ch << ' ' << c.attr << ' ' << c.pair << ' ' << (int)c.wext << ' ';
            std::u32string cm = g_comb[c.comb];
            o << cm.size();
            for (char32_t m : cm) o << ',' << (uint32_t)m;
            o << (x + 1 < w->cols ? ' ' : '\n');
        }
    }
    return o.str();
}
Win* getwin(const std::string& data) {
    std::istringstream in(data);
    std::string magic;
    std::getline(in, magic);
    if (magic != "NYCURSESWIN1") return nullptr;
    int rows, cols, by, bx, cy, cx, pair, bpair, scroll, keypad, delay, rt, rb, pad;
    uint32_t attrs, bch, battr;
    if (!(in >> rows >> cols >> by >> bx >> cy >> cx >> attrs >> pair >> bch >> battr >> bpair >> scroll >> keypad >> delay >> rt >> rb >> pad))
        return nullptr;
    if (rows <= 0 || cols <= 0 || rows > 10000 || cols > 10000) return nullptr;
    Win* w = win_new(rows, cols, by, bx, pad != 0);
    w->cury = cy; w->curx = cx; w->attrs = attrs; w->pair = pair;
    w->bkgd.ch = bch; w->bkgd.attr = battr; w->bkgd.pair = bpair;
    w->scroll = scroll != 0; w->keypad = keypad != 0; w->delay = delay; w->regtop = rt; w->regbot = rb;
    for (int y = 0; y < rows; y++)
        for (int x = 0; x < cols; x++) {
            Cell c;
            int wext;
            std::string comb;
            if (!(in >> c.ch >> c.attr >> c.pair >> wext >> comb)) break;
            c.wext = (uint8_t)wext;
            size_t p = comb.find(',');
            uint32_t idx = 0;
            while (p != std::string::npos) {
                size_t q = comb.find(',', p + 1);
                uint32_t m = (uint32_t)std::strtoul(comb.substr(p + 1, q == std::string::npos ? std::string::npos : q - p - 1).c_str(), nullptr, 10);
                idx = comb_add(idx, m);
                p = q;
            }
            c.comb = idx;
            w->at(y, x) = c;
        }
    touchwin(w);
    return w;
}

void delwin(Win* w) {
    if (w->nsub > 0) return;
    if (w->parent) w->parent->nsub--;
    g_wins.erase(w->id);
    if (S().stdscr == w) S().stdscr = nullptr;
    delete w;
}

} // namespace

// ═══════════════════════════════════════════════════════════════════════════
// §9 the natives
// ═══════════════════════════════════════════════════════════════════════════
namespace {

const char* const CURSES_NAMES[] = {
    "_curses_setupterm", "_curses_setup_done", "_curses_tigetflag", "_curses_tigetnum", "_curses_tigetstr",
    "_curses_tparm", "_curses_putp", "_curses_termname", "_curses_longname", "_curses_termattrs", "_curses_has_ic",
    "_curses_has_il", "_curses_initscr", "_curses_started", "_curses_endwin", "_curses_isendwin", "_curses_doupdate",
    "_curses_lines_cols", "_curses_acs_map", "_curses_newwin", "_curses_newpad", "_curses_subwin", "_curses_delwin",
    "_curses_start_color", "_curses_has_colors", "_curses_can_change_color", "_curses_color_info",
    "_curses_init_pair", "_curses_init_color", "_curses_pair_content", "_curses_color_content",
    "_curses_use_default_colors", "_curses_mode", "_curses_curs_set", "_curses_beep", "_curses_flash",
    "_curses_napms", "_curses_baudrate", "_curses_erasechar", "_curses_killchar", "_curses_keyname",
    "_curses_unctrl", "_curses_has_key", "_curses_ungetch", "_curses_unget_wch", "_curses_flushinp",
    "_curses_getmouse", "_curses_ungetmouse", "_curses_mousemask", "_curses_mouseinterval", "_curses_escdelay",
    "_curses_tabsize", "_curses_resizeterm", "_curses_is_term_resized", "_curses_use_env", "_curses_filter",
    "_curses_getsyx", "_curses_setsyx", "_curses_stats", "_curses_putwin", "_curses_getwin", "_curses_wmove",
    "_curses_wgetyx", "_curses_waddstr", "_curses_waddch", "_curses_winsstr", "_curses_winsch", "_curses_wdelch",
    "_curses_winsdelln", "_curses_wechochar", "_curses_wclear", "_curses_werase", "_curses_wclrtoeol",
    "_curses_wclrtobot", "_curses_wborder", "_curses_whline", "_curses_wvline", "_curses_wattr",
    "_curses_wchgat", "_curses_wbkgd", "_curses_wbkgdset", "_curses_getbkgd", "_curses_winch", "_curses_winstr",
    "_curses_wgetch", "_curses_wget_wch", "_curses_wgetstr", "_curses_wrefresh", "_curses_wnoutrefresh",
    "_curses_prefresh", "_curses_wscrl", "_curses_wflag", "_curses_wsetscrreg", "_curses_wtimeout",
    "_curses_touch", "_curses_is_touched", "_curses_redrawln", "_curses_overlay", "_curses_copywin",
    "_curses_mvwin", "_curses_mvderwin", "_curses_wresize", "_curses_sync", "_curses_wenclose", "_curses_winfo",
    "_curses_term_info"};

int64_t I(std::vector<Value>& a, size_t i, int64_t d = 0) {
    if (i >= a.size() || a[i].type == ValueType::NONE) return d;
    return (int64_t)nyos::to_int(a[i], d);
}
std::string Sv(NythonExecutor& E, std::vector<Value>& a, size_t i) {
    if (i >= a.size()) return std::string();
    if (auto* b = E.bytesOf(a[i])) return b->s;
    return E.strOf(a[i]);
}
Value L(NythonExecutor& E, std::initializer_list<int64_t> v) {
    std::vector<Value> out;
    for (auto x : v) out.push_back(Value((int64_t)x));
    return E.makeListValue(out);
}

Win* W(std::vector<Value>& a, size_t i = 0) { return win_get(I(a, i, -1)); }

} // namespace

std::vector<std::string> curses_builtin_names() {
    std::vector<std::string> v;
    for (const char* n : CURSES_NAMES) v.push_back(n);
    return v;
}

Value dispatch_curses(NythonExecutor& E, const std::string& name, std::vector<Value>& a, Context* ctx) {
    (void)ctx;
    static std::unordered_map<std::string, int> idx;
    if (idx.empty()) {
        int k = 0;
        for (const char* n : CURSES_NAMES) idx[n] = k++;
    }
    auto it = idx.find(name);
    if (it == idx.end()) return UNDEFINED_VALUE;
    State& g = S();
    const std::string op = name.substr(8);
    auto R = [](int v) { return Value((int64_t)v); };
    // ── terminfo ────────────────────────────────────────────────────────
    if (op == "setupterm") {
        std::string term;
        bool given = a.size() > 0 && a[0].type != ValueType::NONE;
        if (given) term = Sv(E, a, 0);
        else if (const char* t = std::getenv("TERM")) term = t;
        if (term.empty()) {
#ifdef _WIN32
            term = "xterm-256color";
#else
            term = "unknown";
#endif
        }
        std::string err;
        if (do_setupterm(term, (int)I(a, 1, 1), err) != XOK) return E.makeStringValue(err);
        return E.makeStringValue("");
    }
    if (op == "setup_done") return Value(g.setup);
    if (op == "tigetflag") {
        std::string n = Sv(E, a, 0);
        int i = ti_bool_idx(g.ti, n);
        if (i < 0) return R(-1);
        return R(g.ti.b[i] == 1 ? 1 : 0);
    }
    if (op == "tigetnum") {
        std::string n = Sv(E, a, 0);
        int i = ti_num_idx(g.ti, n);
        if (i < 0) return R(-2);
        int v = g.ti.n[i];
        return R(v < 0 ? -1 : v);
    }
    if (op == "tigetstr") {
        std::string n = Sv(E, a, 0);
        int i = ti_str_idx(g.ti, n);
        if (i < 0 || g.ti.sok[i] != 1) return NONE_VALUE;
        return E.makeBytesValue(g.ti.s[i]);
    }
    if (op == "tparm") {
        std::string s = Sv(E, a, 0);
        std::vector<TPArg> args;
        if (a.size() > 1) {
            for (auto& v : nyos::list_items(a[1])) {
                TPArg t;
                if (E.bytesOf(v)) { t.is_str = true; t.s = E.bytesOf(v)->s; }
                else t.n = (int64_t)nyos::to_int(v, 0);
                args.push_back(t);
            }
        }
        std::string r = tparm(s, args);
        if (g_tparm_null) return NONE_VALUE;
        return E.makeBytesValue(r);
    }
    if (op == "putp") {
        std::string s = Sv(E, a, 0);
        int mand = 0;
        std::string o = strip_pad(s, &mand);
        out_flush();
        write_all(g.ofd, o);
        if (mand) sleep_ms(mand);
        return R(XOK);
    }
    if (op == "termname") {
        std::string t = g.ti.term;
        if (t.size() > 14) t.resize(14);
        return E.makeBytesValue(t);
    }
    if (op == "longname") {
        std::string n = g.ti.names;
        size_t p = n.rfind('|');
        return E.makeBytesValue(p == std::string::npos ? n : n.substr(p + 1));
    }
    if (op == "termattrs") {
        attr_t at = 0;
        Caps& c = g.c;
        if (c.smacs) at |= XA_ALTCHARSET;
        if (c.blink) at |= XA_BLINK;
        if (c.bold) at |= XA_BOLD;
        if (c.dim) at |= XA_DIM;
        if (c.rev) at |= XA_REVERSE;
        if (c.smso) at |= XA_STANDOUT;
        if (c.prot) at |= XA_PROTECT;
        if (c.invis) at |= XA_INVIS;
        if (c.smul) at |= XA_UNDERLINE;
        if (g.color_on) at |= XA_COLOR;
        if (c.sitm) at |= XA_ITALIC;
        return Value((int64_t)at);
    }
    if (op == "has_ic") return Value((g.c.ich || g.c.ich1 || g.c.smir) && (g.c.dch || g.c.dch1));
    if (op == "has_il") return Value((g.c.il || g.c.il1) && (g.c.dl || g.c.dl1));
    if (op == "term_info") {
        // Nython: the entry as read - [names, path, num32, bools, nums, strs] (for tests and tools)
        std::vector<Value> bools, nums, strs;
        for (int i = 0; i < (int)g.ti.b.size(); i++) {
            if (g.ti.b[i] != 1) continue;
            std::string nm = i < NBOOL ? TI_BOOLNAMES[i] : g.ti.xb[i - NBOOL];
            bools.push_back(E.makeStringValue(nm));
        }
        for (int i = 0; i < (int)g.ti.n.size(); i++) {
            if (g.ti.n[i] < 0) continue;
            std::string nm = i < NNUM ? TI_NUMNAMES[i] : g.ti.xn[i - NNUM];
            std::vector<Value> pr{E.makeStringValue(nm), Value((int64_t)g.ti.n[i])};
            nums.push_back(E.makeListValue(pr));
        }
        for (int i = 0; i < (int)g.ti.s.size(); i++) {
            if (g.ti.sok[i] != 1) continue;
            std::string nm = i < NSTR ? TI_STRNAMES[i] : g.ti.xs[i - NSTR];
            std::vector<Value> pr{E.makeStringValue(nm), E.makeBytesValue(g.ti.s[i])};
            strs.push_back(E.makeListValue(pr));
        }
        std::vector<Value> out{E.makeStringValue(g.ti.names), E.makeStringValue(g.ti.path), Value(g.ti.num32),
                               E.makeListValue(bools), E.makeListValue(nums), E.makeListValue(strs)};
        return E.makeListValue(out);
    }
    // ── the screen ──────────────────────────────────────────────────────
    if (op == "initscr") {
        if (!g.setup) {
            std::string err;
            const char* t = std::getenv("TERM");
            if (do_setupterm(t && *t ? t : "unknown", 1, err) != XOK) return E.makeStringValue(err);
        }
        return R(do_initscr());
    }
    if (op == "started") return Value(g.started);
    if (op == "endwin") return R(do_endwin());
    if (op == "isendwin") return Value(g.started && g.in_endwin);
    if (op == "doupdate") { if (!g.started) return R(XERR); do_update(); return R(XOK); }
    if (op == "lines_cols") return L(E, {g.lines, g.cols});
    if (op == "acs_map") {
        std::vector<Value> out;
        for (int i = 0; i < 128; i++) out.push_back(Value((int64_t)g.acs_map[i]));
        return E.makeListValue(out);
    }
    if (op == "newwin") {
        int nl = (int)I(a, 0), nc = (int)I(a, 1), by = (int)I(a, 2), bx = (int)I(a, 3);
        if (!g.started) return R(-1);
        if (nl == 0) nl = g.lines - by;
        if (nc == 0) nc = g.cols - bx;
        // a window may reach past the screen (ncurses' newwin; refreshes clip it)
        if (nl <= 0 || nc <= 0 || by < 0 || bx < 0) return R(-1);
        return R(win_new(nl, nc, by, bx, false)->id);
    }
    if (op == "newpad") {
        int nl = (int)I(a, 0), nc = (int)I(a, 1);
        if (nl <= 0 || nc <= 0) return R(-1);
        return R(win_new(nl, nc, 0, 0, true)->id);
    }
    if (op == "subwin") {
        // subwin(parent, nlines, ncols, y, x, relative): derwin/subpad when relative
        Win* p = W(a);
        if (!p) return R(-1);
        int nl = (int)I(a, 1), nc = (int)I(a, 2), y = (int)I(a, 3), x = (int)I(a, 4);
        bool rel = I(a, 5) != 0;
        int py = rel ? y : y - p->begy, px = rel ? x : x - p->begx;
        if (nl == 0) nl = p->rows - py;
        if (nc == 0) nc = p->cols - px;
        if (py < 0 || px < 0 || nl <= 0 || nc <= 0 || py + nl > p->rows || px + nc > p->cols) return R(-1);
        Win* w = new Win();
        w->id = g_next_id++;
        w->rows = nl; w->cols = nc;
        w->pary = py; w->parx = px;
        w->begy = p->is_pad ? py : p->begy + py;
        w->begx = p->is_pad ? px : p->begx + px;
        w->parent = p;
        p->nsub++;
        w->store = p->store;
        w->sy = p->sy + py;
        w->sx = p->sx + px;
        w->fch.assign(nl, 0);
        w->lch.assign(nl, nc - 1);
        w->regbot = nl - 1;
        w->attrs = p->attrs;
        w->pair = p->pair;
        w->bkgd = p->bkgd;
        w->bkgd_ct = p->bkgd_ct;
        w->is_pad = p->is_pad;
        w->is_subpad = p->is_pad;
        g_wins[w->id] = w;
        return R(w->id);
    }
    if (op == "delwin") {
        Win* w = W(a);
        if (!w) return R(XERR);
        if (w->nsub > 0 || w == g.stdscr) return R(XERR);
        delwin(w);
        return R(XOK);
    }
    // ── colors ──────────────────────────────────────────────────────────
    if (op == "start_color") return R(do_start_color());
    if (op == "has_colors") return Value(g.c.colors > 0 && (g.c.setaf || g.c.setf) && (g.c.op || g.c.oc));
    if (op == "can_change_color") return Value(g.c.ccc && g.c.initc != nullptr);
    if (op == "color_info") return L(E, {g.color_on ? 1 : 0, g.COLORS, g.COLOR_PAIRS, g.c.colors, g.c.pairs});
    if (op == "init_pair") return R(do_init_pair((int)I(a, 0), (int)I(a, 1), (int)I(a, 2)));
    if (op == "init_color") {
        int c = (int)I(a, 0), r = (int)I(a, 1), gg = (int)I(a, 2), b = (int)I(a, 3);
        if (!g.color_on || !g.c.initc || !g.c.ccc || c < 0 || c >= g.COLORS || r < 0 || r > 1000 || gg < 0 || gg > 1000 || b < 0 || b > 1000)
            return R(XERR);
        g.palette[c] = {r, gg, b};
        out_tp(g.c.initc, {c, r, gg, b});
        out_flush();
        return R(XOK);
    }
    if (op == "pair_content") {
        int p = (int)I(a, 0);
        if (!g.color_on || p < 0 || p >= g.COLOR_PAIRS) return NONE_VALUE;
        return L(E, {g.pairs[p].first, g.pairs[p].second});
    }
    if (op == "color_content") {
        int c = (int)I(a, 0);
        if (!g.color_on || c < 0 || c >= g.COLORS) return NONE_VALUE;
        return L(E, {g.palette[c][0], g.palette[c][1], g.palette[c][2]});
    }
    if (op == "use_default_colors") {
        if (!g.color_on || !(g.c.op || g.c.oc)) return R(XERR);
        g.default_colors = true;
        g.default_fg = g.default_bg = -1;
        g.pairs[0] = {-1, -1};
        return R(XOK);
    }
    // ── modes ───────────────────────────────────────────────────────────
    if (op == "mode") {
        // _curses_mode(name, flag)
        std::string m = Sv(E, a, 0);
        bool on = I(a, 1, 1) != 0;
        if (m == "cbreak") { g.cbreak = on; g.halfdelay = 0; if (!on) g.raw = false; tty_prog(); }
        else if (m == "raw") { g.raw = on; if (on) g.cbreak = true; tty_prog(); }
        else if (m == "echo") g.echo = on;
        else if (m == "nl") g.nl = on;
        else if (m == "halfdelay") { int t = (int)I(a, 1); if (t < 1 || t > 255) return R(XERR); g.halfdelay = t; g.cbreak = true; tty_prog(); }
        else if (m == "meta") {
            g.meta = on;
            if (g.started) { out_cap(on ? g.c.smm : g.c.rmm); out_flush(); }
        } else if (m == "intrflush" || m == "qiflush") {
#ifndef _WIN32
            if (g.have_tty) { struct termios t = g.cur_tty; if (on) t.c_lflag &= ~NOFLSH; else t.c_lflag |= NOFLSH; tty_set(t); }
#endif
        } else if (m == "savetty") {
#ifndef _WIN32
            if (g.have_tty) { g.saved_tty = g.cur_tty; g.have_saved = true; }
#endif
        } else if (m == "resetty") {
#ifndef _WIN32
            if (g.have_saved) tty_set(g.saved_tty); else return R(XERR);
#endif
        } else if (m == "def_prog_mode") {
#ifndef _WIN32
            if (g.have_tty) { g.prog_tty = g.cur_tty; g.have_prog = true; }
#endif
        } else if (m == "def_shell_mode") {
#ifndef _WIN32
            if (g.have_tty) g.shell_tty = g.cur_tty;
#endif
        } else if (m == "reset_prog_mode") {
#ifndef _WIN32
            if (g.have_prog) tty_set(g.prog_tty); else tty_prog();
#endif
        } else if (m == "reset_shell_mode") {
            tty_restore_shell();
        } else if (m == "typeahead") {
            g.typeahead = (int)I(a, 1);
        } else return R(XERR);
        return R(XOK);
    }
    if (op == "curs_set") {
        int v = (int)I(a, 0);
        int old = g.pcurs;
        const std::string* cap = v == 0 ? g.c.civis : v == 1 ? g.c.cnorm : v == 2 ? g.c.cvvis : nullptr;
        if (v < 0 || v > 2) return R(XERR);
        if (!cap) {
            if (v == 2 && g.c.cnorm) cap = g.c.cnorm;
            else return R(XERR);
        }
        out_cap(cap);
        out_flush();
        g.pcurs = v;
        return R(old);
    }
    if (op == "beep" || op == "flash") {
        const std::string* cap = op == "beep" ? (g.c.bel ? g.c.bel : g.c.flash) : (g.c.flash ? g.c.flash : g.c.bel);
        if (!cap || !g.started) return R(XERR);
        int any = 0;
        std::string s = strip_pad(*cap, nullptr, &any);
        out_flush();
        write_all(g.ofd, s);
        if (any) sleep_ms(any);
        return R(XOK);
    }
    if (op == "napms") { sleep_ms((int)I(a, 0)); return R(XOK); }
    if (op == "baudrate") {
#ifndef _WIN32
        if (g.have_tty) {
            speed_t sp = cfgetospeed(&g.cur_tty);
            static const std::pair<speed_t, int> tab[] = {
                {B0, 0}, {B50, 50}, {B75, 75}, {B110, 110}, {B134, 134}, {B150, 150}, {B200, 200}, {B300, 300},
                {B600, 600}, {B1200, 1200}, {B1800, 1800}, {B2400, 2400}, {B4800, 4800}, {B9600, 9600},
                {B19200, 19200}, {B38400, 38400},
#ifdef B57600
                {B57600, 57600},
#endif
#ifdef B115200
                {B115200, 115200},
#endif
#ifdef B230400
                {B230400, 230400},
#endif
            };
            for (auto& p : tab) if (p.first == sp) return R(p.second);
        }
#endif
        return R(38400);
    }
    if (op == "erasechar" || op == "killchar") {
        int c = op == "erasechar" ? 0x7f : 0x15;
#ifndef _WIN32
        if (g.have_tty) c = (unsigned char)g.shell_tty.c_cc[op == "erasechar" ? VERASE : VKILL];
#endif
        return E.makeBytesValue(std::string(1, (char)c));
    }
    if (op == "keyname") return E.makeBytesValue(keyname_of((int)I(a, 0)));
    if (op == "unctrl") return E.makeBytesValue(unctrl_str((unsigned)I(a, 0)));
    if (op == "has_key") return Value(trie_has_code(g.keys, (int)I(a, 0)));
    if (op == "ungetch") {
        int c = (int)I(a, 0);
        g.fifo.push_front(c);
        return R(XOK);
    }
    if (op == "unget_wch") {
        // a character as its UTF-8 bytes, so get_wch reads it whole
        std::string s;
        utf8_put(s, (uint32_t)I(a, 0));
        for (size_t i = s.size(); i-- > 0;) g.fifo.push_front((unsigned char)s[i]);
        return R(XOK);
    }
    if (op == "flushinp") {
        g.fifo.clear();
#ifndef _WIN32
        if (g.have_tty) tcflush(g.ifd, TCIFLUSH);
#else
        FlushConsoleInputBuffer(GetStdHandle(STD_INPUT_HANDLE));
#endif
        return R(XOK);
    }
    if (op == "getmouse") {
        if (g.mouse_q.empty()) return NONE_VALUE;
        MouseEv e = g.mouse_q.front();
        g.mouse_q.pop_front();
        return L(E, {e.id, e.x, e.y, e.z, (int64_t)e.bstate});
    }
    if (op == "ungetmouse") {
        MouseEv e;
        e.id = (int)I(a, 0); e.x = (int)I(a, 1); e.y = (int)I(a, 2); e.z = (int)I(a, 3);
        e.bstate = (uint64_t)I(a, 4);
        g.mouse_q.push_front(e);
        g.fifo.push_front(XKEY_MOUSE);
        return R(XOK);
    }
    if (op == "mousemask") {
        uint64_t nm = (uint64_t)I(a, 0);
        uint64_t old = g.mouse_mask;
        if (!g.c.kmous) return L(E, {0, (int64_t)old});
        uint64_t avail = nm & (((uint64_t)1 << 29) - 1);
        g.mouse_mask = avail;
        if (avail && !g.pmouse) {
            if (g.c.XM) out_tp(g.c.XM, {1}); else out_raw("\x1b[?1000h");
            g.pmouse = true;
        } else if (!avail && g.pmouse) {
            if (g.c.XM) out_tp(g.c.XM, {0}); else out_raw("\x1b[?1000l");
            g.pmouse = false;
        }
        if (avail & B_POSITION) out_raw("\x1b[?1003h");
        else if (old & B_POSITION) out_raw("\x1b[?1003l");
        out_flush();
        return L(E, {(int64_t)avail, (int64_t)old});
    }
    if (op == "mouseinterval") {
        int old = g.mouse_interval;
        int v = (int)I(a, 0, -1);
        if (v >= 0) g.mouse_interval = v;
        return R(old);
    }
    if (op == "escdelay") { int v = (int)I(a, 0, -1); if (v >= 0) g.escdelay = v; return R(g.escdelay); }
    if (op == "tabsize") { int v = (int)I(a, 0, -1); if (v > 0) g.tabsize = v; return R(g.tabsize); }
    if (op == "resizeterm") {
        int l = (int)I(a, 0), c = (int)I(a, 1);
        int r = do_resizeterm(l, c);
        return R(r);
    }
    if (op == "is_term_resized") return Value(I(a, 0) != g.lines || I(a, 1) != g.cols);
    if (op == "use_env") { g.use_env = I(a, 0) != 0; return R(XOK); }
    if (op == "filter") { g.filtered = true; return R(XOK); }
    if (op == "getsyx") {
        if (!g.newscr) return L(E, {0, 0});
        if (g.newscr->leave) return L(E, {-1, -1});
        return L(E, {g.newscr->cury, g.newscr->curx});
    }
    if (op == "setsyx") {
        int y = (int)I(a, 0), x = (int)I(a, 1);
        if (!g.newscr) return R(XERR);
        if (y == -1 && x == -1) g.newscr->leave = true;
        else { g.newscr->leave = false; g.newscr->cury = y; g.newscr->curx = x; }
        return R(XOK);
    }
    if (op == "stats") {
        // Nython: [bytes written, doupdate calls, the update mode]
        std::vector<Value> out{Value((int64_t)g.bytes_total), Value((int64_t)g.updates), E.makeStringValue(g.mode)};
        return E.makeListValue(out);
    }
    if (op == "putwin") { Win* w = W(a); if (!w) return NONE_VALUE; return E.makeBytesValue(putwin(w)); }
    if (op == "getwin") { Win* w = getwin(Sv(E, a, 0)); return R(w ? w->id : -1); }
    // ── window operations: the first argument is the window ─────────────
    Win* w = W(a);
    if (!w) return R(XERR);
    if (op == "wmove") return R(wmove(w, (int)I(a, 1), (int)I(a, 2)));
    if (op == "wgetyx") {
        // which: 0 cursor, 1 begin, 2 max, 3 parent
        int which = (int)I(a, 1);
        if (which == 0) return L(E, {w->cury, w->curx});
        if (which == 1) return L(E, {w->begy, w->begx});
        if (which == 2) return L(E, {w->rows, w->cols});
        return L(E, {w->parent ? w->pary : -1, w->parent ? w->parx : -1});
    }
    auto moved_ok = [&](size_t yi) -> bool {
        int64_t y = I(a, yi, -1), x = I(a, yi + 1, -1);
        if (y == -1 && x == -1) return true;
        return wmove(w, (int)y, (int)x) == XOK;
    };
    if (op == "waddstr") {
        // waddstr(w, y, x, text, n, attr, use_attr, wide): n < 0 for all
        if (!moved_ok(1)) return R(XERR);
        std::string s = Sv(E, a, 3);
        int n = (int)I(a, 4, -1);
        bool use_attr = I(a, 6) != 0;
        bool wide = I(a, 7, 1) != 0;
        attr_t oa = w->attrs;
        int op_ = w->pair;
        if (use_attr) { w->attrs = (attr_t)I(a, 5); w->pair = (int)((w->attrs & XA_COLOR) >> 8); }
        int r = XOK;
        if (wide) {
            auto cps = utf8_decode(s);
            int k = 0;
            for (uint32_t cp : cps) {
                if (n >= 0 && k >= n) break;
                if (cp == 0) break;
                Cell c; c.ch = cp;
                if (waddch_nosync(w, c, true) == XERR) { r = XERR; break; }
                k++;
            }
        } else {
            int k = 0;
            for (unsigned char ch : s) {
                if (n >= 0 && k >= n) break;
                if (ch == 0) break;
                Cell c; c.ch = ch;
                if (waddch_nosync(w, c, false) == XERR) { r = XERR; break; }
                k++;
            }
        }
        synchook(w);
        if (use_attr) { w->attrs = oa; w->pair = op_; }
        return R(r);
    }
    if (op == "waddch") {
        // waddch(w, y, x, value, is_char, attr): value a chtype, or a code point when is_char
        if (!moved_ok(1)) return R(XERR);
        uint32_t v = (uint32_t)I(a, 3);
        bool is_char = I(a, 4) != 0;
        attr_t at = (attr_t)I(a, 5);
        Cell c;
        if (is_char) { c.ch = v; c.attr = at & XA_NOCOLOR; c.pair = (int)((at & XA_COLOR) >> 8); }
        else c = from_chtype(v | at);
        return R(waddch(w, c, is_char));
    }
    if (op == "wechochar") {
        uint32_t v = (uint32_t)I(a, 1);
        bool is_char = I(a, 2) != 0;
        attr_t at = (attr_t)I(a, 3);
        Cell c;
        if (is_char) { c.ch = v; c.attr = at & XA_NOCOLOR; c.pair = (int)((at & XA_COLOR) >> 8); }
        else c = from_chtype(v | at);
        int r = waddch(w, c, is_char);
        if (w->is_pad) {
            if (w->pad_y >= 0) { pnoutrefresh(w, w->pad_y, w->pad_x, w->pad_top, w->pad_left, w->pad_bottom, w->pad_right); do_update(); }
        } else wrefresh(w);
        return R(r);
    }
    if (op == "winsstr") {
        // winsstr(w, y, x, text, n, attr, use_attr)
        if (!moved_ok(1)) return R(XERR);
        std::string s = Sv(E, a, 3);
        int n = (int)I(a, 4, -1);
        bool use_attr = I(a, 6) != 0;
        attr_t oa = w->attrs;
        int op_ = w->pair;
        if (use_attr) { w->attrs = (attr_t)I(a, 5); w->pair = (int)((w->attrs & XA_COLOR) >> 8); }
        int oy = w->cury, ox = w->curx;
        auto cps = utf8_decode(s);
        int k = 0, r = XOK;
        for (uint32_t cp : cps) {
            if (n >= 0 && k >= n) break;
            if (cp == 0) break;
            Cell c; c.ch = cp;
            if (insert_ch(w, c) != XOK) { r = XERR; break; }
            k++;
        }
        w->cury = oy; w->curx = ox;
        synchook(w);
        if (use_attr) { w->attrs = oa; w->pair = op_; }
        return R(r);
    }
    if (op == "winsch") {
        if (!moved_ok(1)) return R(XERR);
        uint32_t v = (uint32_t)I(a, 3);
        bool is_char = I(a, 4) != 0;
        attr_t at = (attr_t)I(a, 5);
        Cell c;
        if (is_char) { c.ch = v; c.attr = at & XA_NOCOLOR; c.pair = (int)((at & XA_COLOR) >> 8); }
        else c = from_chtype(v | at);
        int oy = w->cury, ox = w->curx;
        int r = insert_ch(w, c);
        w->cury = oy; w->curx = ox;
        synchook(w);
        return R(r);
    }
    if (op == "wdelch") { if (!moved_ok(1)) return R(XERR); return R(wdelch(w)); }
    if (op == "winsdelln") return R(winsdelln(w, (int)I(a, 1)));
    if (op == "wclear") { werase(w); w->clr = true; return R(XOK); }
    if (op == "werase") return R(werase(w));
    if (op == "wclrtoeol") return R(wclrtoeol(w));
    if (op == "wclrtobot") return R(wclrtobot(w));
    if (op == "wborder") {
        return R(wborder(w, (uint32_t)I(a, 1), (uint32_t)I(a, 2), (uint32_t)I(a, 3), (uint32_t)I(a, 4),
                         (uint32_t)I(a, 5), (uint32_t)I(a, 6), (uint32_t)I(a, 7), (uint32_t)I(a, 8)));
    }
    if (op == "whline" || op == "wvline") {
        // (w, y, x, value, is_char, attr, n)
        if (!moved_ok(1)) return R(XERR);
        uint32_t v = (uint32_t)I(a, 3);
        bool is_char = I(a, 4) != 0;
        attr_t at = (attr_t)I(a, 5);
        int n = (int)I(a, 6);
        int oy = w->cury, ox = w->curx;
        int r;
        if (is_char) {
            Cell c; c.ch = v; c.attr = at & XA_NOCOLOR; c.pair = (int)((at & XA_COLOR) >> 8);
            c = render(w, c);
            if (op == "whline") { int e = std::min(w->maxx(), w->curx + n - 1); for (int x = w->curx; x <= e; x++) w->at(w->cury, x) = c; touch_range(w, w->cury, w->curx, e); }
            else { int e = std::min(w->maxy(), w->cury + n - 1); for (int y = w->cury; y <= e; y++) { w->at(y, w->curx) = c; touch_range(w, y, w->curx, w->curx); } }
            synchook(w);
            r = XOK;
        } else {
            r = op == "whline" ? whline(w, v | at, n, false) : wvline(w, v | at, n, false);
        }
        w->cury = oy; w->curx = ox;
        return R(r);
    }
    if (op == "wattr") {
        // wattr(w, op, value): op "on", "off", "set", "get"
        std::string o = Sv(E, a, 1);
        attr_t v = (attr_t)I(a, 2);
        if (o == "on") { toggle_on(w->attrs, v); if (v & XA_COLOR) w->pair = (int)((v & XA_COLOR) >> 8); }
        else if (o == "off") { toggle_off(w->attrs, v); if (v & XA_COLOR) w->pair = 0; }
        else if (o == "set") { w->attrs = v; w->pair = (int)((v & XA_COLOR) >> 8); }
        else if (o == "get") return Value((int64_t)((w->attrs & XA_NOCOLOR) | ((attr_t)(w->pair & 0xff) << 8)));
        return R(XOK);
    }
    if (op == "wchgat") {
        // wchgat(w, y, x, n, attr): n < 0 to the end of the line
        if (!moved_ok(1)) return R(XERR);
        int n = (int)I(a, 3, -1);
        attr_t at = (attr_t)I(a, 4);
        int pair = (int)((at & XA_COLOR) >> 8);
        int y = w->cury;
        int end = n < 0 ? w->maxx() : std::min(w->maxx(), w->curx + n - 1);
        for (int x = w->curx; x <= end; x++) {
            Cell& c = w->at(y, x);
            c.attr = (c.attr & XA_ALTCHARSET) | (at & XA_NOCOLOR & ~XA_ALTCHARSET) | (at & XA_ALTCHARSET);
            c.attr = (at & XA_NOCOLOR) | (c.attr & XA_ALTCHARSET);
            c.pair = pair;
        }
        touch_range(w, y, w->curx, end);
        synchook(w);
        return R(XOK);
    }
    if (op == "wbkgd" || op == "wbkgdset") {
        // (w, value, is_char, attr)
        uint32_t v = (uint32_t)I(a, 1);
        bool is_char = I(a, 2) != 0;
        attr_t at = (attr_t)I(a, 3);
        Cell c;
        if (is_char) { c.ch = v; c.attr = at & XA_NOCOLOR; c.pair = (int)((at & XA_COLOR) >> 8); }
        else c = from_chtype(v | at);
        if (op == "wbkgd") return R(wbkgd(w, c));
        wbkgdset(w, c);
        return R(XOK);
    }
    if (op == "getbkgd") return Value((int64_t)w->bkgd_ct);
    if (op == "winch") {
        if (!moved_ok(1)) return R(-1);
        return Value((int64_t)to_chtype(w->at(w->cury, w->curx)));
    }
    if (op == "winstr") {
        // winstr(w, y, x, n): bytes, n bytes at most, whole characters
        if (!moved_ok(1)) return NONE_VALUE;
        int n = (int)I(a, 3, 1023);
        std::string out;
        for (int x = w->curx; x <= w->maxx(); x++) {
            Cell& c = w->at(w->cury, x);
            if (c.wext == 2) continue;
            std::string s;
            if (c.attr & XA_ALTCHARSET) s += (char)(c.ch & 0x7f);
            else {
                utf8_put(s, c.ch);
                if (c.comb) for (char32_t m : g_comb[c.comb]) utf8_put(s, (uint32_t)m);
            }
            if ((int)(out.size() + s.size()) > n) break;
            out += s;
        }
        return E.makeBytesValue(out);
    }
    if (op == "wgetch") {
        if (!moved_ok(1)) return R(XERR);
        return R(wgetch(w));
    }
    if (op == "wget_wch") {
        if (!moved_ok(1)) return L(E, {-1, 0});
        auto r = wget_wch(w);
        return L(E, {r.first, r.second});
    }
    if (op == "wgetstr") {
        if (!moved_ok(1)) return NONE_VALUE;
        int n = (int)I(a, 3, 1023);
        bool err;
        std::string s = wgetnstr(w, n, err);
        if (err) return NONE_VALUE;
        return E.makeBytesValue(s);
    }
    if (op == "wrefresh") return R(wrefresh(w));
    if (op == "wnoutrefresh") return R(wnoutrefresh(w));
    if (op == "prefresh") {
        // prefresh(w, pminrow, pmincol, sminrow, smincol, smaxrow, smaxcol, now)
        int r = pnoutrefresh(w, (int)I(a, 1), (int)I(a, 2), (int)I(a, 3), (int)I(a, 4), (int)I(a, 5), (int)I(a, 6));
        if (r == XOK && I(a, 7) != 0) do_update();
        return R(r);
    }
    if (op == "wscrl") return R(wscrl(w, (int)I(a, 1, 1)));
    if (op == "wflag") {
        // wflag(w, name, value): window options; value -1 reads
        std::string f = Sv(E, a, 1);
        int64_t v = I(a, 2, -1);
        bool on = v != 0;
        bool* p = nullptr;
        if (f == "scrollok") p = &w->scroll;
        else if (f == "leaveok") p = &w->leave;
        else if (f == "clearok") p = &w->clr;
        else if (f == "idlok") p = &w->idl;
        else if (f == "idcok") p = &w->idc;
        else if (f == "immedok") p = &w->immed;
        else if (f == "syncok") p = &w->sync;
        else if (f == "keypad") p = &w->keypad;
        else if (f == "notimeout") p = &w->notimeout;
        else if (f == "is_pad") return Value(w->is_pad);
        else if (f == "is_subwin") return Value(w->parent != nullptr);
        else if (f == "nodelay") { if (v >= 0) w->delay = on ? 0 : -1; return Value(w->delay == 0); }
        if (!p) return R(XERR);
        if (v < 0) return Value(*p);
        *p = on;
        if (f == "keypad" && g.started && !g.in_endwin && w->keypad != g.pkeypad) {
            out_cap(w->keypad ? g.c.smkx : g.c.rmkx);
            g.pkeypad = w->keypad;
            out_flush();
        }
        if (f == "clearok" && w == g.stdscr && false) g.curscr->clr = on;
        return R(XOK);
    }
    if (op == "wsetscrreg") {
        int t = (int)I(a, 1), b = (int)I(a, 2);
        if (t < 0 || t > w->maxy() || b < 0 || b > w->maxy() || b <= t) return R(XERR);
        w->regtop = t; w->regbot = b;
        return R(XOK);
    }
    if (op == "wtimeout") { w->delay = (int)I(a, 1, -1); return R(XOK); }
    if (op == "touch") {
        // touch(w, how, y, n): "win", "untouch", "line" (y, n, changed)
        std::string h = Sv(E, a, 1);
        if (h == "win") touchwin(w);
        else if (h == "untouch") untouch(w);
        else if (h == "range") {
            // touch(w, "range", y, x0, x1): ncurses' CHANGED_RANGE (the panel library)
            touch_range(w, (int)I(a, 2), (int)I(a, 3), (int)I(a, 4));
        } else if (h == "line") {
            int y = (int)I(a, 2), n = (int)I(a, 3);
            bool changed = I(a, 4, 1) != 0;
            if (y < 0 || y > w->maxy()) return R(XERR);
            for (int i = y; i < y + n && i <= w->maxy(); i++) {
                if (changed) touch_line(w, i); else { w->fch[i] = w->lch[i] = -1; }
            }
        }
        return R(XOK);
    }
    if (op == "is_touched") {
        int64_t y = I(a, 1, -1);
        if (y < 0) return Value(is_touched(w));
        if (y > w->maxy()) return R(XERR);
        return Value(w->fch[y] >= 0);
    }
    if (op == "redrawln") {
        int beg = (int)I(a, 1), num = (int)I(a, 2);
        if (beg < 0 || num < 0 || beg + num > w->rows) return R(XERR);
        redrawln(w, beg, num);
        return R(XOK);
    }
    if (op == "overlay") {
        // overlay(src, dst, over)
        Win* d = W(a, 1);
        if (!d) return R(XERR);
        return R(overlap_copy(w, d, I(a, 2) != 0));
    }
    if (op == "copywin") {
        Win* d = W(a, 1);
        if (!d) return R(XERR);
        return R(copywin(w, d, (int)I(a, 2), (int)I(a, 3), (int)I(a, 4), (int)I(a, 5), (int)I(a, 6), (int)I(a, 7), I(a, 8) != 0));
    }
    if (op == "mvwin") {
        int y = (int)I(a, 1), x = (int)I(a, 2);
        if (w->is_pad) return R(XERR);
        if (w->parent) {
            Win* p = w->parent;
            if (y < p->begy || x < p->begx || y + w->rows > p->begy + p->rows || x + w->cols > p->begx + p->cols) return R(XERR);
        } else if (y < 0 || x < 0 || y + w->rows > g.lines || x + w->cols > g.cols) return R(XERR);
        w->begy = y; w->begx = x;
        touchwin(w);
        return R(XOK);
    }
    if (op == "mvderwin") {
        Win* p = w->parent;
        int y = (int)I(a, 1), x = (int)I(a, 2);
        if (!p) return R(XERR);
        if (y < 0 || x < 0 || y + w->rows > p->rows || x + w->cols > p->cols) return R(XERR);
        wsyncup(w);
        w->pary = y; w->parx = x;
        w->sy = p->sy + y; w->sx = p->sx + x;
        return R(XOK);
    }
    if (op == "wresize") return R(wresize(w, (int)I(a, 1), (int)I(a, 2)));
    if (op == "sync") {
        std::string h = Sv(E, a, 1);
        if (h == "up") wsyncup(w);
        else if (h == "down") wsyncdown(w);
        else if (h == "cursor") wcursyncup(w);
        return R(XOK);
    }
    if (op == "wenclose") {
        int y = (int)I(a, 1), x = (int)I(a, 2);
        return Value(y >= w->begy && x >= w->begx && y < w->begy + w->rows && x < w->begx + w->cols);
    }
    if (op == "winfo") {
        // Nython: what the window holds as text, for debugging
        std::vector<Value> rows;
        for (int y = 0; y < w->rows; y++) {
            std::string s;
            for (int x = 0; x < w->cols; x++) { Cell& c = w->at(y, x); if (c.wext != 2) utf8_put(s, c.attr & XA_ALTCHARSET ? acs_unicode(c.ch) : c.ch); }
            rows.push_back(E.makeStringValue(s));
        }
        return E.makeListValue(rows);
    }
    return UNDEFINED_VALUE;
}
