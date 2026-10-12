// builtins/nyreadline.cpp - lib/readline.ny's natives (round 83).
//
// Nython's interactive prompt has a line editor of its own (NythonREPL.hpp's
// MultilineEditor: history on Up/Down, Emacs-style keys, multi-line blocks),
// so readline works over it instead of loading libreadline: its history is
// the editor's (one list for the process), its completer is what Tab asks
// (through ReadlineState::complete, which the prompt sets per engine in
// src/main.cpp), and the history files are GNU readline's format (one entry
// per line), so ~/.python_history-style files are shared with CPython.
//
//   _rl_add_history(line)          _rl_get_history_item(index) -> str or none (1-based)
//   _rl_history_len()              _rl_remove_history_item(pos)   _rl_replace_history_item(pos, line)
//   _rl_clear_history()            _rl_read_history(path)         _rl_write_history(path, keep)
//   _rl_append_history(n, path, keep)                              (keep: history_length, -1: all)
//   _rl_set_auto_history(flag)     _rl_set_delims(text)           _rl_get_delims()
//   _rl_state() -> [line_buffer, begidx, endidx]                  _rl_insert_text(text)
//   _rl_interactive() -> bool      (the prompt is running its editor)
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NythonREPL.hpp"
#include "builtins/os.hpp"
#include "builtins/sysmods.hpp"
#include <cerrno>
#include <cstdio>
#include <fstream>

namespace {
using nython::repl_engine::readline_state;

int64_t iarg(std::vector<Value>& a, size_t i, int64_t d = 0) {
    if (i >= a.size() || a[i].type == ValueType::NONE) return d;
    return (int64_t)nyos::to_int(a[i], d);
}
std::string sarg(NythonExecutor& E, std::vector<Value>& a, size_t i) {
    if (i >= a.size()) return std::string();
    if (auto* b = E.bytesOf(a[i])) return b->s;
    return E.strOf(a[i]);
}
// history_truncate_file: keep the last `keep` lines
void truncate_file(const std::string& path, int64_t keep) {
    if (keep < 0) return;
    std::ifstream in(path, std::ios::binary);
    if (!in) return;
    std::vector<std::string> lines;
    std::string l;
    while (std::getline(in, l)) lines.push_back(l);
    in.close();
    if ((int64_t)lines.size() <= keep) return;
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    for (size_t i = lines.size() - (size_t)keep; i < lines.size(); i++) out << lines[i] << "\n";
}
} // namespace

std::vector<std::string> readline_builtin_names() {
    return {"_rl_add_history", "_rl_get_history_item", "_rl_history_len", "_rl_remove_history_item",
            "_rl_replace_history_item", "_rl_clear_history", "_rl_read_history", "_rl_write_history",
            "_rl_append_history", "_rl_set_auto_history", "_rl_set_delims", "_rl_get_delims", "_rl_state",
            "_rl_insert_text", "_rl_interactive"};
}

Value dispatch_readline(NythonExecutor& E, const std::string& name, std::vector<Value>& a, Context* ctx) {
    (void)ctx;
    auto& rs = readline_state();
    auto& h = rs.history;
    if (name == "_rl_add_history") { h.push_back(sarg(E, a, 0)); return NONE_VALUE; }
    if (name == "_rl_get_history_item") {
        int64_t i = iarg(a, 0);
        if (i < 1 || i > (int64_t)h.size()) return NONE_VALUE;
        return E.makeStringValue(h[(size_t)i - 1]);
    }
    if (name == "_rl_history_len") return Value((int64_t)h.size());
    if (name == "_rl_remove_history_item") {
        int64_t i = iarg(a, 0);
        if (i < 0) nyos::raise("ValueError", "History index cannot be negative");
        if (i >= (int64_t)h.size()) nyos::raise("ValueError", "No history item at position " + std::to_string(i));
        h.erase(h.begin() + i);
        return NONE_VALUE;
    }
    if (name == "_rl_replace_history_item") {
        int64_t i = iarg(a, 0);
        if (i < 0) nyos::raise("ValueError", "History index cannot be negative");
        if (i >= (int64_t)h.size()) nyos::raise("ValueError", "No history item at position " + std::to_string(i));
        h[(size_t)i] = sarg(E, a, 1);
        return NONE_VALUE;
    }
    if (name == "_rl_clear_history") { h.clear(); return NONE_VALUE; }
    if (name == "_rl_read_history") {
        std::string path = sarg(E, a, 0);
        std::ifstream in(path, std::ios::binary);
        if (!in) nyos::raise_errno(errno ? errno : ENOENT, path);
        std::string l;
        while (std::getline(in, l)) {
            if (!l.empty() && l.back() == '\r') l.pop_back();
            if (l.size() > 1 && l[0] == '#' && l.find_first_not_of("0123456789", 1) == std::string::npos) continue;   // a timestamp
            h.push_back(l);
        }
        return NONE_VALUE;
    }
    if (name == "_rl_write_history" || name == "_rl_append_history") {
        bool app = name == "_rl_append_history";
        size_t k = app ? 1 : 0;
        int64_t n = app ? iarg(a, 0) : (int64_t)h.size();
        std::string path = sarg(E, a, k);
        int64_t keep = iarg(a, k + 1, -1);
        if (app) {
            std::ifstream probe(path);
            if (!probe) nyos::raise_errno(ENOENT, path);   // GNU append_history needs the file
        }
        std::ofstream out(path, std::ios::binary | (app ? std::ios::app : std::ios::trunc));
        if (!out) nyos::raise_errno(errno ? errno : EACCES, path);
        size_t start = n < 0 || (size_t)n >= h.size() ? 0 : h.size() - (size_t)n;
        for (size_t i = start; i < h.size(); i++) out << h[i] << "\n";
        out.close();
        truncate_file(path, keep);
        return NONE_VALUE;
    }
    if (name == "_rl_set_auto_history") { rs.auto_history = iarg(a, 0, 1) != 0; return NONE_VALUE; }
    if (name == "_rl_set_delims") { rs.delims = sarg(E, a, 0); return NONE_VALUE; }
    if (name == "_rl_get_delims") return E.makeStringValue(rs.delims);
    if (name == "_rl_state") {
        std::vector<Value> v{E.makeStringValue(rs.line_buffer), Value((int64_t)rs.begidx), Value((int64_t)rs.endidx)};
        return E.makeListValue(v);
    }
    if (name == "_rl_insert_text") { rs.insert += sarg(E, a, 0); rs.line_buffer += sarg(E, a, 0); return NONE_VALUE; }
    if (name == "_rl_interactive") return Value(bool(rs.complete));
    return UNDEFINED_VALUE;
}
