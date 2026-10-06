#ifndef _WIN32
#include <sys/resource.h>
#include <unistd.h>
#endif
// main.cpp
// ─────────────────────────────────────────────────────────────────────────────
// Nython interpreter entry point.
//
// COMPILATION FLAGS:
//   NYTHON_WITH_IDE=1  (default) — no-arg launch opens NythonIDE GUI
//   NYTHON_WITH_IDE=0            — no-arg launch opens terminal REPL
//
// Build IDE version (default):
//   make
// Build CLI-only version:
//   make NYTHON_WITH_IDE=0
// ─────────────────────────────────────────────────────────────────────────────
#include "NythonExecutor.hpp"
#include "ConsoleManager.hpp"
#include <algorithm>
#include <sstream>
#include <fstream>
// ^ explicit: libstdc++ supplies these transitively, MinGW does not.

using namespace std;
using namespace nython;
using namespace nython::io;
using namespace nython::node;
using namespace nython::lexer;
using namespace nython::kernel;
using namespace nython::parser;
using namespace nython::reader;
using namespace nython::exception;

// Compile-time switch: IDE is enabled unless explicitly disabled
#ifndef NYTHON_WITH_IDE
#  define NYTHON_WITH_IDE 1
#endif

// ════════════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════════════

void print_header() {
    std::cout << "\n"
              << "\x1b[1;36m  _   _       _   _                 \x1b[0m\n"
              << "\x1b[1;36m | \\ | |     | | | |                \x1b[0m\n"
              << "\x1b[1;36m |  \\| |_   _| |_| |__   ___  _ __  \x1b[0m\n"
              << "\x1b[1;36m | . ` | | | | __| '_ \\ / _ \\| '_ \\ \x1b[0m\n"
              << "\x1b[1;36m | |\\  | |_| | |_| | | | (_) | | | |\x1b[0m\n"
              << "\x1b[1;36m |_| \\_|\\__, |\\__|_| |_|\\___/|_| |_|\x1b[0m\n"
              << "\x1b[1;36m         __/ |                       \x1b[0m\n"
              << "\x1b[1;36m        |___/                        \x1b[0m\n"
              << "\n"
              << "\x1b[1mNython " << NYTHON_VERSION << "\x1b[0m — AI-Powered Multi-Paradigm Language\n"
              << "Type \x1b[36mhelp\x1b[0m for commands, \x1b[36mexit\x1b[0m to quit. "
              << "Syntax: \x1b[33mPython\x1b[0m · \x1b[33mC/JS\x1b[0m · \x1b[33mLua\x1b[0m\n";
}

// Returns a process exit status: 0 on success, non-zero if the file could not
// be read, parsed or executed.
//
// This used to return void and swallow every error, printing a "[DBG ...]" line
// and exiting 0. Any harness that judged success by exit status — including this
// project's own example sweep — therefore counted files that failed to parse as
// passing.
// ─── Compiler diagnostics ────────────────────────────────────────────────────
// Syntax and lexing errors already carry a full Location (file, row, column);
// every report site printed only e.what() and threw that away, so the whole
// diagnostic was "Expected ParenClose, but found Var" with no indication of
// WHERE. On a 3,000-line file that is close to useless.
//
// Prints the standard file:line:column form, plus the offending source line
// with a caret under the column, the way every mainstream compiler does.
static void report_compiler_error(const std::string& kind,
                                  nython::lexer::Location loc,
                                  const std::string& message) {
    std::cerr << loc.filename << ":" << loc.row << ":" << loc.column
              << ": " << kind << ": " << message << "\n";

    // Echo the source line and point at the column. Best effort: if the file
    // cannot be re-read (stdin, a deleted temp) the message above still stands.
    std::ifstream in(loc.filename);
    if (in) {
        std::string line;
        uint32_t n = 0;
        while (n < loc.row && std::getline(in, line)) n++;
        if (n == loc.row) {
            std::cerr << "  " << line << "\n  ";
            // loc.column counts characters (a UTF-8 sequence is one).
            uint32_t col = 1;
            for (size_t i = 0; i < line.size() && col < loc.column; ++i) {
                unsigned char c = static_cast<unsigned char>(line[i]);
                if ((c & 0xC0) == 0x80) continue;
                std::cerr << (c == '\t' ? '\t' : ' ');
                col++;
            }
            std::cerr << "^\n";
        }
    }
}

// --trace <out.jsonl>: record every statement executed in the user's files
// (see NythonExecutor::traceStatement). Used by the IDE's debugger.
static std::string g_trace_path;

// Where an uncaught runtime error happened. Most runtime errors carried no
// location at all ("ValueError: bad thing"), so the Problems panel could not
// point at a line; the executor now remembers the statement it was running.
static void report_uncaught_where(const std::string& msg) {
    NythonExecutor::traceException(msg);
    if (msg.find(" at line ") != std::string::npos) return;
    std::string where = NythonExecutor::last_stmt_where();
    if (!where.empty()) std::cerr << "  at " << where << "\n";
}

// An uncaught Nython exception (a tagged std::string): reported; the exit status.
static int report_uncaught_string(const std::string& s) {
    std::string msg = s;
    if (msg.rfind("__exc__:", 0) == 0) {
        msg = msg.substr(8);
        auto colon = msg.find(':');
        if (colon != std::string::npos)
            msg = msg.substr(0, colon) + ": " + msg.substr(colon + 1);
    }
    if (msg.rfind("KeyboardInterrupt", 0) == 0) {
        // As Python: the bare name, and the status of a process ended by SIGINT.
        NythonExecutor::traceException(msg);
        std::cerr << "KeyboardInterrupt\n";
        return 130;
    }
    if (msg.rfind("SystemExit", 0) == 0) {
        // exit(n) / sys.exit(n): the status, no report
        std::string rest = msg.size() > 12 ? msg.substr(12) : std::string();
        return nyrt::system_exit_status(rest);
    }
    std::cerr << "[Nython] Uncaught exception — " << msg << "\n";
    report_uncaught_where(msg);
    return 1;
}

// What to run (round 77): a file, or program text (-c, stdin) with a name
// for messages ("<string>", "<stdin>").
struct Program {
    bool is_file = true;
    std::string path, text, name;
    std::string display() const { return is_file ? path : name; }
};
static SourceCode source_of(const Program& p) {
    return p.is_file ? SourceCode(p.path) : SourceCode::from_text(p.text, p.name);
}
// -i: the interactive prompt after the program, in its scope.
static bool g_inspect = false;
// SystemExit raised at the prompt: the status the process ends with (-1: none).
static int g_repl_exit = -1;
// -q: no banner on the prompt.
static bool g_quiet = false;
static void setenv_quiet() { g_quiet = true; }
// -u / NYTHONUNBUFFERED: every write reaches the terminal or pipe at once.
static void setenv_default_unbuffered() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);
    std::cout.setf(std::ios::unitbuf);
    std::cerr.setf(std::ios::unitbuf);
}
static void interactive_interp(NythonExecutor& exec, Runnable* runner, bool banner);

int run_program(const Program& prog, bool show_ast = false) {
    const std::string filename = prog.display();
    struct stat buf;
    if (prog.is_file && stat(filename.c_str(), &buf) != 0) {
        std::cerr << "[Nython] No such file: " << filename << "\n";
        return 2;
    }
    // Closes a --trace recording on the way out. Declared outside the try:
    // inside it, the unwinding exception closed the file before the catch
    // below could record that exception in it.
    struct TraceCloser { ~TraceCloser() {
        auto& T = NythonExecutor::tracer();
        if (T.f) { fclose(T.f); T.f = nullptr; }
    } } trace_closer;
    try {
        auto source = source_of(prog);
        auto reporter = std::make_shared<Reporter>(source);
        auto lexer = std::make_shared<Lexer>(source);
        auto vm_ptr = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
        auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)vm_ptr.get(), lexer.get());
        auto tokens = lexer->tokenize();
        auto ast = parser->parse();
        if (show_ast && ast) {
            nython::utils::PrettyPrinter pp;
            ast->writeToStdOut(pp);
            return 0;
        }


        NythonExecutor exec((Runnable*)vm_ptr.get());
        // Wait for non-daemon threads before the executor is torn down, also
        // when the main program ends with an uncaught exception (round 74).
        struct JoinThreadsAtExit { ~JoinThreadsAtExit() { nyconc::join_nondaemon_at_exit(); } } join_threads_at_exit;
        if (!g_trace_path.empty()) {
            auto& T = NythonExecutor::tracer();
            T.f = fopen(g_trace_path.c_str(), "w");
            if (!T.f) { std::cerr << "[Nython] cannot write trace file " << g_trace_path << "\n"; return 2; }
            T.main_file = filename;
            auto cut = filename.find_last_of("/\\");
            T.main_dir = cut == std::string::npos ? std::string() : filename.substr(0, cut + 1);
            if (ast) exec.collectTopLevelNames(ast, T.globals);
            // Module-level variables worth showing are the ones the user's own
            // file mentions (loop variables included), not the hundreds of
            // names an import defines.
            {
                std::string src = prog.text;
                if (prog.is_file) {
                    std::ifstream in(filename);
                    src.assign((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
                }
                size_t i = 0;
                while (i < src.size()) {
                    unsigned char c = (unsigned char)src[i];
                    if (isalpha(c) || c == '_') {
                        size_t j = i;
                        while (j < src.size() && (isalnum((unsigned char)src[j]) || src[j] == '_')) j++;
                        T.globals.insert(src.substr(i, j - i));
                        i = j;
                    } else i++;
                }
            }
            if (const char* mx = getenv("NY_TRACE_MAX")) {
                long v = atol(mx);
                if (v > 0) T.max_events = v;
            }
        }
        try {
            exec.execute(ast);
        } catch (std::string& s) {
            // Reported before the program's threads are waited for, as
            // Python prints the traceback first: Python's frames (round 77),
            // then the located line the IDE and the tools read.
            if (s.rfind("__exc__:SystemExit", 0) != 0 && s.rfind("__exc__:KeyboardInterrupt", 0) != 0)
                std::cerr << exec.uncaughtTracebackText(s);
            int rc = report_uncaught_string(s);
            if (g_inspect) { interactive_interp(exec, (Runnable*)vm_ptr.get(), false); exec.runAtexit(); return g_repl_exit >= 0 ? g_repl_exit : rc; }
            nyconc::join_nondaemon_at_exit();
            exec.runAtexit();   // round 77: atexit handlers, after the threads
            return rc;
        }
        if (g_inspect) interactive_interp(exec, (Runnable*)vm_ptr.get(), false);
        nyconc::join_nondaemon_at_exit();
        exec.runAtexit();   // round 77: atexit handlers, after the threads
        // Generators the program left suspended are closed now, oldest
        // first, so their finally blocks and __exit__ run (as when CPython
        // shuts down).
        nygen::close_all(exec);
        nygen::shutdown();
        // --profile: emit measured per-function counts and timings after the
        // program finishes. Delimited so a caller can separate the report from
        // the program's own stdout.
        if (NythonExecutor::profiling_enabled()) {
            std::cout << "__NY_PROFILE__\n" << exec.profile_report();
        }
    } catch (exception::UnexpectedCharError& e) {
        report_compiler_error("error", e.location(), e.message()); return 1;
    } catch (exception::SyntaxError& e) {
        report_compiler_error("syntax error", e.location(), e.message()); return 1;
    } catch (std::string& s) {
        // Nython raises uncaught exceptions as tagged std::string. Without this
        // handler they escaped main() and the process died via std::terminate
        // ("terminate called after throwing an instance of std::string").
        return report_uncaught_string(s);
    } catch (std::runtime_error& e) {
        if (std::string(e.what()).rfind("KeyboardInterrupt", 0) == 0) { std::cerr << "KeyboardInterrupt\n"; return 130; }
        std::cerr << "runtime error: " << e.what() << "\n";
        report_uncaught_where(e.what());
        return 1;
    } catch (std::exception& e) {
        std::cerr << "error: " << e.what() << "\n";
        report_uncaught_where(e.what());
        return 1;
    }
    return g_repl_exit >= 0 ? g_repl_exit : 0;
}

int run_file(const std::string& filename, bool show_ast = false) {
    Program p;
    p.path = filename;
    return run_program(p, show_ast);
}

// ────────────────────────────────────────────────────────────────────────────
// Helper: extract directory from argv[0], handling both / and \ separators.
// On Windows, uses GetModuleFileNameW to get the true exe path — argv[0]
// may be just "nython.exe" when launched by double-click or from a shortcut.
// ────────────────────────────────────────────────────────────────────────────
static std::string get_binary_dir(const char* argv0) {
#ifdef _WIN32
    // Get the full path of the running exe — reliable regardless of how launched
    wchar_t wpath[4096] = {};
    if (GetModuleFileNameW(nullptr, wpath, 4095) > 0) {
        // Convert UTF-16 → UTF-8
        char path[4096] = {};
        WideCharToMultiByte(CP_UTF8, 0, wpath, -1, path, sizeof(path)-1, nullptr, nullptr);
        std::string p = path;
        auto sep = p.rfind('\\');
        if (sep == std::string::npos) sep = p.rfind('/');
        if (sep != std::string::npos) return p.substr(0, sep);
        return ".";
    }
#endif
    // Fallback: parse argv[0]
    std::string p = argv0;
    auto slash = p.rfind('/');
    auto bslash = p.rfind('\\');
    auto sep = std::string::npos;
    if (slash != std::string::npos && bslash != std::string::npos)
        sep = std::max(slash, bslash);
    else if (slash != std::string::npos) sep = slash;
    else if (bslash != std::string::npos) sep = bslash;
    return (sep != std::string::npos) ? p.substr(0, sep) : ".";
}

// Absolute path of the running executable. argv[0] is only a name when the
// binary was started through PATH, which made get_binary_dir() return ".".
static std::string g_argv0;
[[maybe_unused]] static std::string get_exe_path() {
#ifdef _WIN32
    wchar_t wpath[4096] = {};
    if (GetModuleFileNameW(nullptr, wpath, 4095) > 0) {
        char path[4096] = {};
        WideCharToMultiByte(CP_UTF8, 0, wpath, -1, path, sizeof(path)-1, nullptr, nullptr);
        return path;
    }
    return g_argv0;
#else
    char buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) { buf[n] = 0; return buf; }
    char rp[4096];
    if (!g_argv0.empty() && realpath(g_argv0.c_str(), rp)) return rp;
    return g_argv0;
#endif
}

[[maybe_unused]] static void set_env_default(const char* key, const std::string& val) {
    const char* cur = getenv(key);
    if (cur && *cur) return;       // an explicit setting always wins
#ifdef _WIN32
    _putenv_s(key, val.c_str());
#else
    setenv(key, val.c_str(), 0);
#endif
}

// ────────────────────────────────────────────────────────────────────────────
// IDE launcher: runs nython_ide.ny via the VM
// Searches for the IDE file alongside the binary, then in CWD, then in
// examples/ and tests/
// ────────────────────────────────────────────────────────────────────────────
#if NYTHON_WITH_IDE
static bool launch_ide(const std::string& binary_dir) {
    // Use platform-appropriate separator
#ifdef _WIN32
    const std::string S = "\\";
#else
    const std::string S = "/";
#endif
    // Candidate paths for nython_ide.ny
    std::vector<std::string> candidates = {
        binary_dir + S + "nython_ide.ny",
        binary_dir + S + ".." + S + "nython_ide.ny",
        binary_dir + S + ".." + S + "examples" + S + "nython_ide.ny",
        "nython_ide.ny",
        "examples/nython_ide.ny",
        "examples\\nython_ide.ny",
        "../nython_ide.ny",
        "..\\nython_ide.ny",
    };
    std::string ide_path;
    for (auto& c : candidates) {
        struct stat sb;
        if (stat(c.c_str(), &sb) == 0) { ide_path = c; break; }
    }
    if (ide_path.empty()) {
        std::string msg = "[Nython] nython_ide.ny not found.\n\n"
                          "Searched in:\n  " + binary_dir + "\\\n  (current directory)\n\n"
                          "Make sure nython_ide.ny and the lib\\ folder\n"
                          "are in the same folder as nython.exe.";
#ifdef _WIN32
        MessageBoxA(nullptr, msg.c_str(), "NythonIDE — File Not Found", MB_OK | MB_ICONWARNING);
#else
        std::cerr << msg << "\n";
#endif
        return false;
    }
    // Tell the IDE where it lives and which binary is running it. Its assets
    // (assets/fonts/codicon.ttf) and the interpreter it runs programs with
    // were both looked up relative to the working directory, so opening the
    // IDE anywhere but its own folder lost every icon and could not Run.
    {
        std::string home = ide_path;
#ifndef _WIN32
        char rp[4096];
        if (realpath(ide_path.c_str(), rp)) home = rp;
#endif
        auto cut = home.find_last_of("/\\");
        home = (cut == std::string::npos) ? std::string(".") : home.substr(0, cut);
        set_env_default("NYTHON_HOME", home);
        set_env_default("NYTHON_EXE", get_exe_path());
    }
    try {
        auto source = SourceCode(ide_path);
        auto reporter = std::make_shared<Reporter>(source);
        auto lexer2   = std::make_shared<Lexer>(source);
        auto vm2      = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
        auto parser2  = std::make_shared<Parser>(reporter.get(), (Runnable*)vm2.get(), lexer2.get());
        lexer2->tokenize();
        auto ast = parser2->parse();
        // ── CRITICAL ────────────────────────────────────────────────────────
        // Execute the IDE through NythonExecutor, NOT through vm2->run(ast).
        //
        // The bytecode VM (VirtualMachine.hpp) registers only a subset of
        // builtins as natives (print/len/time_ms/json_encode/...). It knows
        // NOTHING about the module dispatch chain in NythonExecutor::callBuiltin,
        // so every gui_* and lang_* call inside the VM silently evaluated to
        // `none`. That made gui_create_window() return none WITHOUT ever
        // reaching SDL_CreateWindow, and gui_sdl_version() return none — which
        // is what produced the bogus
        //     "Window creation failed (SDL3 none is loaded)"
        // message blaming GPU drivers for what was really a missing builtin.
        //
        // run_file() already uses NythonExecutor; the IDE must use it too.
        if (ast) {
            // NY_PROFILE_OUT=<file>: profile the IDE itself (time and, per
            // function, the objects and strings it allocates - which on the
            // interpreter is what it keeps), written when the IDE exits.
            const char* prof_out = getenv("NY_PROFILE_OUT");
            if (prof_out && *prof_out) NythonExecutor::profiling_enabled() = true;
            NythonExecutor exec((Runnable*)vm2.get());
            exec.execute(ast);
            if (prof_out && *prof_out) {
                std::ofstream pf(prof_out);
                pf << exec.profile_report();
            }
        }
        return true;
    } catch (exception::UnexpectedCharError& e) {
        // A syntax error in the IDE's own source, or in a module it imports,
        // located like any other; this used to reach std::terminate.
        report_compiler_error("error", e.location(), e.message());
        std::cerr << "[IDE Error] the IDE could not be loaded\n";
        return false;
    } catch (exception::SyntaxError& e) {
        report_compiler_error("syntax error", e.location(), e.message());
        std::cerr << "[IDE Error] the IDE could not be loaded\n";
        return false;
    } catch (std::exception& e) {
        std::string msg = std::string("[IDE Error] ") + e.what();
#ifdef _WIN32
        MessageBoxA(nullptr, msg.c_str(), "NythonIDE — Runtime Error", MB_OK | MB_ICONERROR);
#else
        std::cerr << msg << "\n";
#endif
        return false;
    } catch (std::string& s) {
        // Nython raises uncaught exceptions as tagged std::string (run_file()
        // already handles this). Only std::exception was caught here, so any
        // uncaught error while the IDE started - an ImportError from launching
        // outside the repository, say - killed the process via std::terminate
        // with no message at all.
        std::string msg = s;
        if (msg.rfind("__exc__:", 0) == 0) {
            msg = msg.substr(8);
            auto colon = msg.find(':');
            if (colon != std::string::npos)
                msg = msg.substr(0, colon) + ": " + msg.substr(colon + 1);
        }
        msg = "[IDE Error] " + msg;
#ifdef _WIN32
        MessageBoxA(nullptr, msg.c_str(), "NythonIDE — Runtime Error", MB_OK | MB_ICONERROR);
#else
        std::cerr << msg << "\n";
#endif
        return false;
    }
}
#endif // NYTHON_WITH_IDE

// ────────────────────────────────────────────────────────────────────────────
// Terminal REPL
// ────────────────────────────────────────────────────────────────────────────
// ── The interactive prompt (round 77) ───────────────────────────────────────
// One loop for both engines: a value typed at the prompt is shown as its
// repr (as Python does: 0.1 + 0.2 is 0.30000000000000004, 'a' is quoted
// with escapes) and kept in `_`; an exception reads "ValueError: message"
// (it was the internal "__exc__:ValueError:message"). NYTHONSTARTUP runs
// first, as PYTHONSTARTUP does.

// "__exc__:Type:message" -> "Type: message"
static std::string exc_text(const std::string& s) {
    std::string type, msg;
    if (nython::ny_split_exc_message(s, type, msg)) return msg.empty() ? type : type + ": " + msg;
    return s;
}

// Whether a parsed chunk is one expression (so the prompt shows its value).
static bool is_expression_chunk(const nython::node::node_ptr& ast) { return nython::node::is_expression_program(ast); }

// The prompt loop: run_chunk(code) runs what was typed.
static void interactive_loop(const std::function<void(const std::string&)>& run_chunk, bool banner, const char* engine) {
    if (banner && !g_quiet && isatty(STDIN_FILENO)) {
        print_header();
        std::cout << "\x1b[90m(" << engine << ")\x1b[0m\n";
    }
    if (const char* st = getenv("NYTHONSTARTUP")) {
        std::ifstream in(st);
        if (in) {
            std::string code((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            run_chunk(code);
        }
    }
    if (!isatty(STDIN_FILENO)) {
        // Not a terminal (-i with piped input): plain lines, no line
        // editing; a block (a line ending with ':' or '{') runs at the
        // blank line or the next unindented line that ends it.
        std::string block, line;
        auto flush = [&]() {
            if (block.find_first_not_of(" \t\r\n") != std::string::npos && g_repl_exit < 0) run_chunk(block);
            block.clear();
        };
        while (std::getline(std::cin, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            std::string t = line;
            while (!t.empty() && (t.back() == ' ' || t.back() == '\t')) t.pop_back();
            bool opens = !t.empty() && (t.back() == ':' || t.back() == '{');
            bool indented = !line.empty() && (line[0] == ' ' || line[0] == '\t');
            if (!block.empty()) {
                if (t.empty()) { flush(); continue; }
                if (indented || t[0] == '}' || t.rfind("else", 0) == 0 || t.rfind("elif", 0) == 0 || t.rfind("except", 0) == 0 || t.rfind("finally", 0) == 0) {
                    block += line + "\n";
                    continue;
                }
                flush();
                if (g_repl_exit >= 0) return;
            }
            if (t == "exit" || t == "quit" || t == "exit()" || t == "quit()") return;
            if (opens) { block = line + "\n"; continue; }
            run_chunk(line);
            if (g_repl_exit >= 0) return;
        }
        flush();
        return;
    }
    nython::repl_engine::MultilineCollector collector;
    std::cout << "\n";
    while (true) {
        std::string code;
        auto result = collector.collect(code);
        if (result == nython::repl_engine::MultilineCollector::EXIT_REQ) break;
        if (result == nython::repl_engine::MultilineCollector::CANCEL) continue;
        if (result == nython::repl_engine::MultilineCollector::EMPTY) continue;
        auto s = code.find_first_not_of(" \t\r\n");
        if (s == std::string::npos) continue;
        code = code.substr(s);
        auto e = code.find_last_not_of(" \t\r\n");
        if (e != std::string::npos) code = code.substr(0, e + 1);
        if (code == "exit" || code == "quit" || code == "exit()" || code == "quit()") break;
        if (code == "help" || code == "help()") {
            std::cout << "\x1b[1mNython " << NYTHON_VERSION << "\x1b[0m\n\n"
                      << "  \x1b[36mCommands:\x1b[0m  exit, help, version, clear\n"
                      << "  \x1b[36mKeys:\x1b[0m      Up/Down=history, Ctrl+C=cancel, Ctrl+D=exit\n"
                      << "             Ctrl+L=clear, Ctrl+A=home, Ctrl+E=end, Tab=indent\n"
                      << "  \x1b[36mMultiline:\x1b[0m Lines ending with : { or do continue; an empty line submits\n"
                      << "  \x1b[36mValues:\x1b[0m    an expression's value is shown and kept in _\n\n";
            continue;
        }
        if (code == "version") { std::cout << "Nython " << NYTHON_VERSION << "\n"; continue; }
        if (code == "clear") { std::cout << "\x1b[2J\x1b[H"; continue; }
#if NYTHON_WITH_IDE
        if (code == "ide") { std::cout << "Launching NythonIDE...\n"; launch_ide("."); continue; }
#endif
        run_chunk(code);
        if (g_repl_exit >= 0) break;
    }
    if (isatty(STDIN_FILENO)) std::cout << "\x1b[1mGoodbye!\x1b[0m\n";
}

// What a chunk defined (functions, classes) points into its AST: every
// chunk's parse is kept for the session.
static std::vector<std::shared_ptr<void>>& repl_keep() {
    static auto* k = new std::vector<std::shared_ptr<void>>();
    return *k;
}

// One chunk on the interpreter, in exec's global scope.
static void interp_chunk(NythonExecutor& exec, Runnable* runner, const std::string& code, bool echo) {
    try {
        auto src = SourceCode::from_text(code, "<stdin>");
        auto rep = std::make_shared<Reporter>(src);
        auto lex = std::make_shared<Lexer>(src);
        lex->tokenize();
        auto par = std::make_shared<Parser>(rep.get(), runner, lex.get());
        auto ast = par->parse();
        if (!ast) return;
        repl_keep().push_back(ast); repl_keep().push_back(par); repl_keep().push_back(lex); repl_keep().push_back(rep);
        bool expr = is_expression_chunk(ast);
        Value val = exec.execute(ast);
        if (echo && expr && val.type != ValueType::NONE && val.type != ValueType::UNDEFINED) {
            std::cout << exec.reprOf(val, exec.global_ctx) << std::endl;
            exec.global_ctx->defineByName("_", val);
        }
    } catch (exception::SyntaxError& se) {
        std::cerr << "SyntaxError: " << se.what() << std::endl;
    } catch (exception::UnexpectedCharError& e) {
        std::cerr << "SyntaxError: " << e.message() << std::endl;
    } catch (std::string& err) {
        std::string et, em;
        if (err == "break" || err == "continue") std::cerr << "SyntaxError: '" << err << "' outside loop\n";
        else if (nython::ny_split_exc_message(err, et, em) && et == "SystemExit") g_repl_exit = nyrt::system_exit_status(em);
        else std::cerr << exc_text(err) << "\n";
    } catch (nython::node::ReturnSignal&) {
        std::cerr << "SyntaxError: 'return' outside function\n";
    } catch (std::exception& ex) {
        std::string w = ex.what();
        std::cerr << (w.rfind("KeyboardInterrupt", 0) == 0 ? std::string("KeyboardInterrupt") : exc_text(w)) << "\n";
    } catch (...) {
        std::cerr << "Unknown error\n";
    }
}

static void interactive_interp(NythonExecutor& exec, Runnable* runner, bool banner) {
    interactive_loop([&](const std::string& code) { interp_chunk(exec, runner, code, true); }, banner, "interpreter");
}

void repl() {
    auto reporter_src = SourceCode::from_text("", "<stdin>");
    auto reporter = std::make_shared<Reporter>(reporter_src);
    auto vm_ptr = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
    NythonExecutor exec((Runnable*)vm_ptr.get());
    struct JoinThreadsAtExit { ~JoinThreadsAtExit() { nyconc::join_nondaemon_at_exit(); } } join_threads_at_exit;
    // Not a terminal (a pipe, a file): the whole input is one program -
    // unless -i asked for the prompt anyway (Python's: values echoed).
    if (!isatty(STDIN_FILENO) && !g_inspect) {
        std::string all_code((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
        if (all_code.find_first_not_of(" \t\r\n") == std::string::npos) return;
        interp_chunk(exec, (Runnable*)vm_ptr.get(), all_code, false);
        return;
    }
    interactive_interp(exec, (Runnable*)vm_ptr.get(), true);
}

// ════════════════════════════════════════════════════════════════════════════
// main
// ════════════════════════════════════════════════════════════════════════════

// ── VM -> interpreter builtin bridge ─────────────────────────────────────────
// The bytecode VM implements a small set of natives; the interpreter registers
// 536. This converts values between the two representations so a program run
// with --vm can call the whole standard library.
namespace {

using nython::vm::VMVal;
using nython::vm::VMType;
using nython::vm::VMMap;

// One bridged call's conversions. Each VM list/map/instance argument becomes
// one interpreter container (shared parts stay shared, a cycle stays a cycle),
// and a container coming back that started as a VM value converts back to
// that same VM object - so a builtin that returns (part of) its argument
// hands back the caller's object, not a copy. After the call, every VM
// container whose interpreter copy the builtin changed is updated in place:
// a builtin that mutates its argument (shuffle, heappush, dict updates, ...)
// mutated a copy before, and the caller never saw it.
struct BridgeConv {
    NythonExecutor& exec;
    std::unordered_map<const void*, Value> to_interp;   // VM list/map ptr -> container
    std::vector<std::pair<Container*, VMVal>> origin;   // container -> VM original
    std::unordered_map<const Container*, size_t> origin_of;
    // bytearrays passed in: the interpreter copy and the VM original
    std::vector<std::pair<nyheap::Bytes*, VMVal>> barrays;
    nython::vm::VirtualMachine* vm = nullptr;   // builds sets (their keys are the VM's)
    // What a VM value with no interpreter form (a function, a class, a
    // generator) becomes: none - except for lib/json's encoder, which must
    // see that such a value is there (undefined: not plain data, so the
    // document goes to the Nython encoder and default=) rather than null.
    Value opaque = NONE_VALUE;
    explicit BridgeConv(NythonExecutor& e) : exec(e) {}

    static const void* key_of(const VMVal& v) {
        if (v.type == VMType::LIST) return v.list.get();
        if (v.type == VMType::MAP || v.type == VMType::INSTANCE) return v.map.get();
        return nullptr;
    }

    Value to_value(const VMVal& v) {
        switch (v.type) {
            case VMType::NONE:   return NONE_VALUE;
            case VMType::BOOL:   return Value(v.b);
            case VMType::INT: {
                if (!v.s.empty()) {
                    nypy::BigInt b;
                    if (nypy::BigInt::parse(v.s, 10, b)) return intValue(b);
                }
                return Value((int64_t)v.i);
            }
            case VMType::FLOAT:  return Value(v.d);
            case VMType::STRING: return exec.makeStringValue(v.s);
            case VMType::BYTES: {
                // a bytearray converts to one interpreter bytearray, changes
                // copied back after the call (copy_back)
                if (!v.b) return exec.makeBytesValue(v.s, false);
                const void* k = v.list.get();
                auto hit = to_interp.find(k);
                if (hit != to_interp.end()) return hit->second;
                Value out = exec.makeBytesValue(v.bdata(), true);
                to_interp.emplace(k, out);
                barrays.emplace_back(exec.bytesOf(out), v);
                return out;
            }
            case VMType::LIST:
            case VMType::MAP:
            case VMType::INSTANCE: {
                const void* k = key_of(v);
                if (!k) return NONE_VALUE;
                if (v.type == VMType::MAP && v.class_name == "__kwargs__") {
                    // keyword arguments: one map marked as such
                    auto* kwo = new Object((Runnable*)exec.runner, "map", Type::MAP);
                    Value kout(static_cast<Collectable*>(kwo));
                    for (auto& kv : *v.map) (*kwo->container)[kv.first] = to_value(kv.second);
                    (*kwo->container)["__kwargs__"] = Value(1);
                    return kout;
                }
                auto hit = to_interp.find(k);
                if (hit != to_interp.end()) return hit->second;
                bool is_list = v.type == VMType::LIST;
                auto* obj = new Object((Runnable*)exec.runner, is_list ? (v.b ? "tuple" : "list") : "map",
                                       is_list ? Type::LIST : Type::MAP);
                Value out(static_cast<Collectable*>(obj));
                to_interp.emplace(k, out);
                origin_of.emplace(obj, origin.size());
                origin.emplace_back(obj, v);
                if (is_list && v.is_set()) {
                    (*obj->container)["__set__"] = intValue(v.is_frozenset() ? 2 : 1);
                    (*obj->container)["__len__"] = intValue(0);
                    for (auto& e : *v.list) exec.setAdd(obj, to_value(e));
                } else if (is_list) {
                    int64_t n = 0;
                    for (auto& e : *v.list) (*obj->container)[std::to_string(n++)] = to_value(e);
                    (*obj->container)["__len__"] = intValue(n);
                    if (v.b) (*obj->container)["__tuple__"] = Value(1);
                } else {
                    // An instance crosses as a map of its attributes plus
                    // "__class__" - enough for builtins that read fields (the
                    // file functions take a file object's "handle").
                    for (auto& kv : *v.map) {
                        // not the engine's hidden fields ("\x01weakref", round 77)
                        if (!kv.first.empty() && kv.first[0] == '\x01') continue;
                        (*obj->container)[kv.first] = to_value(kv.second);
                    }
                    if (v.type == VMType::INSTANCE)
                        (*obj->container)["__class__"] = exec.makeStringValue(v.class_name);
                }
                return out;
            }
            default: return opaque;
        }
    }

    // A fresh VM value for an interpreter value; containers that began as VM
    // values come back as those same VM objects.
    VMVal to_vm(const Value& v) {
        if (auto* bo = exec.bytesOf(v)) {
            for (auto& ba : barrays) if (ba.first == bo) return ba.second;   // the caller's own bytearray
            return VMVal::make_bytes(bo->s, bo->mut);
        }
        if (exec.isStringValue(v)) return VMVal::make_str(exec.getStringValue(v));
        switch (v.type) {
            case ValueType::NONE:    return VMVal::make_none();
            case ValueType::BOOLEAN: return VMVal::make_bool(v.value.b);
            case ValueType::INTEGER: {
                int64_t i;
                if (bigint_fits_i64(v.value.i, i)) return VMVal::make_int(i);
                return VMVal::make_bigint(bigint_to_nbig(v.value.i));
            }
            case ValueType::DOUBLE:  return VMVal::make_float((double)v.value.d);
            default: break;
        }
        // The collectable lives in Value::value.gc, not value.p.
        auto* c = dynamic_cast<Container*>(as_collectable(v));
        if (!c || !c->container) return VMVal::make_none();
        auto oit = origin_of.find(c);
        if (oit != origin_of.end()) return origin[oit->second].second;
        return build(c);
    }

    // Converts a container's contents, without consulting its own origin.
    VMVal build(Container* c) {
        auto& m = *c->container;
        auto len_it = m.find("__len__");
        if (len_it != m.end()) {
            std::vector<VMVal> out;
            int64_t n = bigint_to_i64(len_it->second.value.i);
            out.reserve((size_t)std::max<int64_t>(n, 0));
            for (int64_t i = 0; i < n; i++) {
                auto it = m.find(std::to_string(i));
                out.push_back(it == m.end() ? VMVal::make_none() : to_vm(it->second));
            }
            if (m.count("__set__") && vm) return vm->make_set_value(out, NythonExecutor::isFrozenCont(c));
            return m.count("__tuple__") ? VMVal::make_tuple(std::move(out)) : VMVal::make_list(std::move(out));
        }
        VMVal r = VMVal::make_map();
        for (auto& kv : m) (*r.map)[kv.first] = to_vm(kv.second);
        return r;
    }

    // True when the interpreter value still is what the VM value was.
    bool same(const Value& a, const VMVal& b) {
        if (auto* bo = exec.bytesOf(a)) {
            if (b.type != VMType::BYTES || b.b != bo->mut) return false;
            for (auto& ba : barrays) if (ba.first == bo) return ba.second.list.get() == b.list.get();
            return !bo->mut && bo->s == b.s;
        }
        if (exec.isStringValue(a)) return b.type == VMType::STRING && exec.getStringValue(a) == b.s;
        switch (a.type) {
            case ValueType::NONE:    return b.type == VMType::NONE;
            case ValueType::BOOLEAN: return b.type == VMType::BOOL && b.b == a.value.b;
            case ValueType::INTEGER: {
                if (b.type != VMType::INT) return false;
                int64_t i;
                if (bigint_fits_i64(a.value.i, i)) return b.s.empty() && b.i == i;
                return !b.s.empty() && bigint_to_nbig(a.value.i).to_string() == b.s;
            }
            case ValueType::DOUBLE:  return b.type == VMType::FLOAT && (b.d == (double)a.value.d || (b.d != b.d && a.value.d != a.value.d));
            default: break;
        }
        auto* c = dynamic_cast<Container*>(as_collectable(a));
        if (!c) return b.type == VMType::NONE;
        auto oit = origin_of.find(c);
        return oit != origin_of.end() && key_of(origin[oit->second].second) == key_of(b);
    }

    // Writes back every VM container whose interpreter copy was changed.
    void copy_back() {
        for (auto& ba : barrays) {
            VMVal vm = ba.second;
            if (vm.bdata() != ba.first->s) vm.bdata_mut() = ba.first->s;
        }
        for (size_t oi = 0; oi < origin.size(); oi++) {
            Container* c = origin[oi].first;
            VMVal vm = origin[oi].second;   // shares the list/map
            auto& m = *c->container;
            if (vm.type == VMType::LIST) {
                if (vm.b) continue;          // tuples are immutable
                auto len_it = m.find("__len__");
                if (len_it == m.end()) continue;
                int64_t n = bigint_to_i64(len_it->second.value.i);
                bool changed = n != (int64_t)vm.list->size();
                for (int64_t i = 0; !changed && i < n; i++) {
                    auto it = m.find(std::to_string(i));
                    changed = it == m.end() || !same(it->second, (*vm.list)[(size_t)i]);
                }
                if (!changed) continue;
                std::vector<VMVal> out;
                out.reserve((size_t)std::max<int64_t>(n, 0));
                for (int64_t i = 0; i < n; i++) {
                    auto it = m.find(std::to_string(i));
                    out.push_back(it == m.end() ? VMVal::make_none() : to_vm(it->second));
                }
                *vm.list = std::move(out);
            } else {
                bool inst = vm.type == VMType::INSTANCE;
                size_t n = 0, hidden = 0;
                bool changed = false;
                for (auto& kv : *vm.map) if (!kv.first.empty() && kv.first[0] == '\x01') hidden++;
                for (auto& kv : m) {
                    if (inst && kv.first == "__class__") continue;
                    n++;
                    auto it = vm.map->find(kv.first);
                    if (it == vm.map->end() || !same(kv.second, it->second)) { changed = true; break; }
                }
                if (!changed && n + hidden == vm.map->size()) continue;
                VMMap fresh;
                for (auto& kv : m) {
                    if (inst && kv.first == "__class__") continue;
                    fresh[kv.first] = to_vm(kv.second);
                }
                // the engine's hidden fields stay as they are (round 77)
                for (auto& kv : *vm.map) if (!kv.first.empty() && kv.first[0] == '\x01') fresh[kv.first] = kv.second;
                *vm.map = std::move(fresh);
            }
        }
    }
};

// Kept alive for the process: the bridge closures capture it.
std::shared_ptr<NythonExecutor> g_bridge_exec;

void install_vm_builtin_bridge(Runnable* runner) {
    if (g_bridge_exec) return;
    g_bridge_exec = std::make_shared<NythonExecutor>(runner);
    NythonExecutor* ex = g_bridge_exec.get();
    auto* vm = static_cast<nython::vm::VirtualMachine*>(runner);
    nython::vm::VirtualMachine::bridge_exists() = [ex](const std::string& n) {
        return ex->hasBuiltin(n);
    };
    nython::vm::VirtualMachine::bridge_names() = [ex]() {
        std::vector<std::string> out;
        for (auto& kv : ex->builtin_ptrs) out.push_back(kv.first);
        return out;
    };
    nython::vm::VirtualMachine::bridge_call() =
        [ex, vm](const std::string& n, std::vector<VMVal>& a) -> VMVal {
            BridgeConv conv(*ex);
            conv.vm = vm;
            if (n.compare(0, 6, "_json_") == 0) conv.opaque = UNDEFINED_VALUE;
            // Path-like objects (__fspath__) as the strings they stand for,
            // in a copy: the caller's arguments are left as they were.
            std::vector<VMVal> path_args;
            std::vector<VMVal>* src = &a;
            if (!a.empty() && nyrt::takes_paths(n)) {
                path_args = a;
                vm->fspath_args(path_args);
                src = &path_args;
            }
            std::vector<Value> args;
            args.reserve(src->size());
            for (auto& v : *src) args.push_back(conv.to_value(v));
            Value r;
            // Interpreter builtins raise Nython exceptions as a tagged
            // std::string ("__exc__:FileNotFoundError:msg"), which the VM's
            // exception handling does not see: it unwound past every try and
            // ended the program. Raise it the way Op::RAISE would instead -
            // an instance of the builtin exception type.
            try {
                r = ex->callBuiltin(n, args, ex->globalContext());
            } catch (std::string& s) {
                std::string type, msg;
                nyrt::parse_exc(s, type, msg);
                vm->raise_native_exception(type.empty() ? "Exception" : type, msg);
            } catch (std::runtime_error& e) {
                // e.g. std::ios_base::failure from a stream
                vm->raise_native_exception(nyrt::native_exc_type(e), e.what());
            } catch (std::logic_error& e) {
                // std::out_of_range, std::invalid_argument, ...
                vm->raise_native_exception(nyrt::native_exc_type(e), e.what());
            } catch (std::bad_alloc& e) {
                vm->raise_native_exception("MemoryError", e.what());
            }
            conv.copy_back();
            return conv.to_vm(r);
        };
}

} // namespace


// ── The bytecode VM: a program, and the prompt on it (round 77) ─────────────
static void interactive_vm(nython::vm::VirtualMachine& vm, VMMap& session, bool banner);

static void vm_chunk(nython::vm::VirtualMachine& vm, VMMap& session, const std::string& code, bool echo) {
    try {
        auto src = SourceCode::from_text(code, "<stdin>");
        auto rep = std::make_shared<Reporter>(src);
        auto lex = std::make_shared<Lexer>(src);
        lex->tokenize();
        auto par = std::make_shared<Parser>(rep.get(), (Runnable*)&vm, lex.get());
        auto ast = par->parse();
        if (!ast) return;
        repl_keep().push_back(ast); repl_keep().push_back(par); repl_keep().push_back(lex); repl_keep().push_back(rep);
        bool expr = echo && is_expression_chunk(ast);
        if (expr) {
            // the value lands in a variable the prompt then shows
            auto src2 = SourceCode::from_text("__ny_repl_v__ = (" + code + ")", "<stdin>");
            auto rep2 = std::make_shared<Reporter>(src2);
            auto lex2 = std::make_shared<Lexer>(src2);
            lex2->tokenize();
            auto par2 = std::make_shared<Parser>(rep2.get(), (Runnable*)&vm, lex2.get());
            try {
                auto a2 = par2->parse();
                if (a2) { ast = a2; repl_keep().push_back(a2); repl_keep().push_back(par2); repl_keep().push_back(lex2); repl_keep().push_back(rep2); }
                else expr = false;
            }
            catch (...) { expr = false; }
        }
        vm.run(ast, &session);
        if (nython::vm::VirtualMachine::exit_status() >= 0) { g_repl_exit = nython::vm::VirtualMachine::exit_status(); return; }
        if (expr) {
            auto it = session.find("__ny_repl_v__");
            if (it != session.end()) {
                VMVal v = it->second;
                session.erase("__ny_repl_v__");
                if (v.type != VMType::NONE && v.type != VMType::UNDEFINED) {
                    std::cout << vm.repr_of(v) << std::endl;
                    session["_"] = v;
                }
            }
        }
    } catch (exception::SyntaxError& se) {
        std::cerr << "SyntaxError: " << se.what() << std::endl;
    } catch (exception::UnexpectedCharError& e) {
        std::cerr << "SyntaxError: " << e.message() << std::endl;
    } catch (std::string& err) {
        std::cerr << exc_text(err) << "\n";
    } catch (std::exception& ex) {
        std::cerr << exc_text(ex.what()) << "\n";
    }
}

static void interactive_vm(nython::vm::VirtualMachine& vm, VMMap& session, bool banner) {
    interactive_loop([&](const std::string& code) { vm_chunk(vm, session, code, true); }, banner, "bytecode VM");
}

static int run_program_vm(const Program& prog, bool inspect) {
    // SourceCode treats a string that is not an existing file as program
    // TEXT, so a mistyped path used to be run as code (`--vm t/x.ny`
    // evaluated `t / x.ny`). Refuse it like the interpreter does.
    if (prog.is_file) {
        struct stat vm_st;
        if (stat(prog.path.c_str(), &vm_st) != 0) {
            std::cerr << "[Nython] No such file: " << prog.path << "\n";
            return 2;
        }
    }
    try {
        auto source = source_of(prog);
        auto reporter = std::make_shared<Reporter>(source);
        auto lexer2 = std::make_shared<Lexer>(source);
        auto vm2 = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
        // Non-daemon threads finish before the VM goes away (round 74).
        struct JoinThreadsAtExit { ~JoinThreadsAtExit() { nyconc::join_nondaemon_at_exit(); } } join_threads_at_exit;
        // Imports resolve relative to the script (the interpreter's rule).
        if (prog.is_file) vm2->set_script_dir(prog.path);
        auto parser2 = std::make_shared<Parser>(reporter.get(), (Runnable*)vm2.get(), lexer2.get());
        install_vm_builtin_bridge((Runnable*)vm2.get());
        lexer2->tokenize();
        auto ast = parser2->parse();
        // run() reports an uncaught exception itself and returns RUNTIME_ERROR.
        VMMap session;
        int rc = 0;
        if (ast) {
            auto res = vm2->run(ast, inspect ? &session : nullptr);
            if (res == decltype(res)::RUNTIME_ERROR) {
                int st = nython::vm::VirtualMachine::exit_status();
                rc = nython::vm::VirtualMachine::keyboard_interrupted() ? 130 : st >= 0 ? st : 1;
            }
        }
        if (inspect) interactive_vm(*vm2, session, false);
        return g_repl_exit >= 0 ? g_repl_exit : rc;
    } catch (exception::SyntaxError& e) {
        report_compiler_error("syntax error", e.location(), e.message()); return 1;
    } catch (exception::UnexpectedCharError& e) {
        report_compiler_error("error", e.location(), e.message()); return 1;
    } catch (std::string& msg) {
        std::cerr << "VM Error: " << exc_text(msg) << "\n"; return 1;
    } catch (std::exception& e) {
        std::cerr << "VM Error: " << e.what() << "\n"; return 1;
    }
}

static void repl_vm() {
    auto src = SourceCode::from_text("", "<stdin>");
    auto reporter = std::make_shared<Reporter>(src);
    auto vm = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
    install_vm_builtin_bridge((Runnable*)vm.get());
    struct JoinThreadsAtExit { ~JoinThreadsAtExit() { nyconc::join_nondaemon_at_exit(); } } join_threads_at_exit;
    VMMap session;
    if (!isatty(STDIN_FILENO) && !g_inspect) {
        std::string all((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
        if (all.find_first_not_of(" \t\r\n") != std::string::npos) vm_chunk(*vm, session, all, false);
        return;
    }
    interactive_vm(*vm, session, true);
}

// --check: parse (and, on the VM, compile) without running: "ok", or the
// error located as when running; status 0 or 1.
static int check_program(const Program& prog, bool vm) {
    if (prog.is_file) {
        struct stat st;
        if (stat(prog.path.c_str(), &st) != 0) { std::cerr << "[Nython] No such file: " << prog.path << "\n"; return 2; }
    }
    try {
        auto source = source_of(prog);
        auto reporter = std::make_shared<Reporter>(source);
        auto lex = std::make_shared<Lexer>(source);
        auto vmp = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
        auto par = std::make_shared<Parser>(reporter.get(), (Runnable*)vmp.get(), lex.get());
        lex->tokenize();
        auto ast = par->parse();
        if (vm && ast) vmp->compile_ast(ast);
        std::cout << prog.display() << ": ok\n";
        return 0;
    } catch (exception::SyntaxError& e) {
        report_compiler_error("syntax error", e.location(), e.message()); return 1;
    } catch (exception::UnexpectedCharError& e) {
        report_compiler_error("error", e.location(), e.message()); return 1;
    } catch (std::string& s) {
        std::cerr << exc_text(s) << "\n"; return 1;
    } catch (std::exception& e) {
        std::cerr << e.what() << "\n"; return 1;
    }
}

// -m: a library module's file (a/b.ny, or a package's a/b/__main__.ny),
// looked up where `import` looks: the working directory and its lib/, then
// NYTHONPATH and the library beside the interpreter.
static bool find_module_file(const std::string& mod, std::string& out) {
    std::string rel = mod;
    std::replace(rel.begin(), rel.end(), '.', '/');
    std::vector<std::string> dirs = {"", "lib/"};
    for (auto& d : nyrt::library_dirs()) dirs.push_back(d);
    struct stat st;
    for (auto& d : dirs) {
        std::string f = d + rel + ".ny";
        if (stat(f.c_str(), &st) == 0 && !S_ISDIR(st.st_mode)) { out = f; return true; }
        std::string m = d + rel + "/__main__.ny";
        if (stat(m.c_str(), &st) == 0) { out = m; return true; }
    }
    return false;
}

static void print_usage() {
    std::cout
        << "Usage: nython [option] ... [-c cmd | -m mod | file | -] [arg] ...\n\n"
        << "Options (short ones combine: -iq):\n"
        << "  -c cmd            run the program text cmd (sys.argv[0] is \"-c\")\n"
        << "  -m mod            run library module mod as the program (a package: its __main__.ny)\n"
        << "  file              run the program in file; -  reads it from stdin\n"
        << "  -i                after the program, the interactive prompt in its scope\n"
        << "  -q                no banner on the interactive prompt\n"
        << "  -u                unbuffered output (also NYTHONUNBUFFERED=1)\n"
        << "  -E                ignore NYTHON* environment variables\n"
        << "  --vm              run on the bytecode VM (default: the interpreter)\n"
        << "  --interp          run on the tree-walking interpreter\n"
        << "  --check           parse (and with --vm, compile) without running\n"
        << "  -t, --tokenize    dump the tokens          -a, --ast      dump the AST\n"
        << "  -d, --disasm      dump the VM bytecode     -p, --profile  per-function timings\n"
        << "      --trace OUT   record each executed statement to OUT (JSON lines)\n"
        << "  --cli, --repl     the interactive prompt (no IDE)\n"
        << "  --ide             NythonIDE\n"
        << "  -V, -v, --version the version          -h, --help     this text\n\n"
        << "Environment: NYTHONPATH (module search path), NYTHONSTARTUP (run before the\n"
        << "interactive prompt), NYTHONUNBUFFERED\n"
#if NYTHON_WITH_IDE
        << "\nWith no arguments on a terminal, NythonIDE opens; --cli gives the prompt instead.\n"
#endif
        ;
}

static void print_version() {
    std::cout << "Nython " << NYTHON_VERSION;
#if NYTHON_WITH_IDE
    std::cout << " (IDE build)";
#else
    std::cout << " (CLI build)";
#endif
    std::cout << "\n";
}

static void unset_env(const char* k) {
#ifdef _WIN32
    _putenv_s(k, "");
#else
    unsetenv(k);
#endif
}

int main(int argc, char** argv, char** env) {
    g_argv0 = (argc > 0 && argv[0]) ? argv[0] : "";
    nyrt::executable_path() = get_exe_path();
    try {
        setlocale(LC_ALL, "");
        nython::ConsoleManager cm; cm.setupConsole();
        // Ctrl+C raises KeyboardInterrupt (it killed the process, skipping
        // every finally block); signal.signal() installs the others.
        nyconc::install_default_signals();

        // ── The command line (round 77): options, then the program ─────
        // (-c cmd | -m mod | file | -), then the program's own arguments.
        // Options combine (-iq), and the engine choice applies to every
        // way of giving a program. The old forms still work: --vm file,
        // --trace OUT file, -p file, -t/-a/-d file.
        bool use_vm = false, inspect = false, quiet = false, force_repl = false, profile = false, ide = false;
        std::string tool, mode, target, trace_out;
        int i = 1;
        auto bad = [&](const std::string& m) { std::cerr << "nython: " << m << "\nTry 'nython -h' for more information.\n"; return 2; };
        for (; i < argc; i++) {
            std::string a = argv[i];
            if (a == "--") { i++; if (i < argc) { mode = "file"; target = argv[i]; i++; } break; }
            if (a == "-") { mode = "stdin"; i++; break; }
            if (a.size() > 2 && a[0] == '-' && a[1] == '-') {
                if (a == "--vm") use_vm = true;
                else if (a == "--interp") use_vm = false;
                else if (a == "--version") { print_version(); return 0; }
                else if (a == "--help") { print_usage(); return 0; }
                else if (a == "--ide") ide = true;
                else if (a == "--cli" || a == "--repl" || a == "--console") force_repl = true;
                else if (a == "--tokenize") tool = "tokenize";
                else if (a == "--ast") tool = "ast";
                else if (a == "--disasm") tool = "disasm";
                else if (a == "--check") tool = "check";
                else if (a == "--profile") profile = true;
                else if (a == "--trace") {
                    if (i + 1 >= argc) return bad("--trace needs an output file");
                    trace_out = argv[++i];
                }
                else return bad("unknown option " + a);
                continue;
            }
            if (a.size() > 1 && a[0] == '-') {
                bool stop = false;
                for (size_t k = 1; k < a.size() && !stop; k++) {
                    char c = a[k];
                    if (c == 'c' || c == 'm') {
                        std::string val = a.substr(k + 1);
                        if (val.empty()) {
                            if (i + 1 >= argc) return bad(std::string("option -") + c + " needs an argument");
                            val = argv[++i];
                        }
                        mode = c == 'c' ? "cmd" : "module";
                        target = val;
                        stop = true;
                    }
                    else if (c == 'W' || c == 'X') {
                        // -W action:message:category:module:lineno (round 77:
                        // sys.warnoptions); -X options are accepted and ignored
                        std::string val = a.substr(k + 1);
                        if (val.empty()) {
                            if (i + 1 >= argc) return bad(std::string("option -") + c + " needs an argument");
                            val = argv[++i];
                        }
                        if (c == 'W') nyrt::warn_options().push_back(val);
                        stop = true;
                    }
                    else if (c == 'i') inspect = true;
                    else if (c == 'q') quiet = true;
                    else if (c == 'u') setenv_default_unbuffered();
                    else if (c == 'E') { unset_env("NYTHONPATH"); unset_env("NYTHONSTARTUP"); unset_env("NYTHONUNBUFFERED"); }
                    else if (c == 'V' || c == 'v') { print_version(); return 0; }
                    else if (c == 'h' || c == '?') { print_usage(); return 0; }
                    else if (c == 't') tool = "tokenize";
                    else if (c == 'a') tool = "ast";
                    else if (c == 'd') tool = "disasm";
                    else if (c == 'p') profile = true;
                    else if (c == 'B' || c == 'O' || c == 's' || c == 'S' || c == 'b') {}   // Python's: nothing to do here
                    else return bad(std::string("unknown option -") + c);
                }
                if (stop && (mode == "cmd" || mode == "module")) { i++; break; }
                continue;
            }
            mode = "file";
            target = a;
            i++;
            break;
        }
        if (const char* ub = getenv("NYTHONUNBUFFERED")) if (*ub) setenv_default_unbuffered();
#if NYTHON_WITH_IDE
        if (ide) { launch_ide(get_binary_dir(argv[0])); return 0; }
#else
        (void)ide;
#endif
        // The program and sys.argv (Python's: "-c", the module's path, "-").
        Program prog;
        if (mode == "file") {
            prog.path = target;
            nyrt::set_command_line(target, argc, argv, i);
        } else if (mode == "cmd") {
            prog.is_file = false; prog.text = target; prog.name = "<string>";
            nyrt::set_command_line("-c", argc, argv, i);
        } else if (mode == "module") {
            std::string path;
            if (!find_module_file(target, path)) { std::cerr << "nython: No module named " << target << "\n"; return 1; }
            prog.path = path;
            nyrt::set_command_line(path, argc, argv, i);
        } else if (mode == "stdin") {
            prog.is_file = false; prog.name = "<stdin>";
            prog.text.assign((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
            nyrt::set_command_line("-", argc, argv, i);
        }
        g_inspect = inspect;
        if (!tool.empty()) {
            if (mode.empty()) return bad("-" + tool.substr(0, 1) + " needs a program");
            if (tool == "check") return check_program(prog, use_vm);
            if (tool == "tokenize") {
                auto source = source_of(prog);
                auto lex = std::make_shared<Lexer>(source);
                lex->tokenize(); std::cout << lex->toString(); return 0;
            }
            if (tool == "ast") return run_program(prog, true);
            if (tool == "disasm") {
                try {
                    auto source = source_of(prog);
                    auto reporter = std::make_shared<Reporter>(source);
                    auto lexer2 = std::make_shared<Lexer>(source);
                    auto vm2 = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
                    auto parser2 = std::make_shared<Parser>(reporter.get(), (Runnable*)vm2.get(), lexer2.get());
                    lexer2->tokenize();
                    auto ast = parser2->parse();
                    if (ast) { auto code = vm2->compile_ast(ast); std::cout << vm2->disassemble(*code); }
                } catch (std::exception& e) {
                    std::cerr << "Disasm Error: " << e.what() << "\n"; return 1;
                }
                return 0;
            }
        }
        if (mode.empty()) {
            // No program: the prompt (or, with no arguments at all on a
            // terminal, the IDE).
#if NYTHON_WITH_IDE
            if (argc == 1 && !force_repl && isatty(STDIN_FILENO)) {
                if (!launch_ide(get_binary_dir(argv[0]))) repl();
                cm.restoreConsole();
                return 0;
            }
#endif
            nyrt::set_command_line("", argc, argv, argc);
            if (quiet) setenv_quiet();
            if (use_vm) repl_vm(); else repl();
            cm.restoreConsole();
            return g_repl_exit >= 0 ? g_repl_exit : 0;
        }
        if (quiet) setenv_quiet();
        if (!trace_out.empty()) {
            if (use_vm) return bad("--trace records the interpreter (no --vm)");
            g_trace_path = trace_out;
        }
        if (profile) {
            if (use_vm) return bad("--profile measures the interpreter (no --vm)");
            NythonExecutor::profiling_enabled() = true;
        }
        if (use_vm) return run_program_vm(prog, inspect);
        return run_program(prog);
        cm.restoreConsole();
    } catch (std::exception& e) {
        std::string msg = std::string("Fatal error: ") + e.what();
#ifdef _WIN32
        MessageBoxA(nullptr, msg.c_str(), "Nython — Fatal Error", MB_OK | MB_ICONERROR);
#else
        std::cerr << msg << std::endl;
#endif
        return 1;
    }
    return 0;
}
