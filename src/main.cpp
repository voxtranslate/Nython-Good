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
            for (uint32_t i = 1; i < loc.column && i < line.size() + 1; ++i)
                std::cerr << (line[i-1] == '\t' ? '\t' : ' ');
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

int run_file(const std::string& filename, bool show_ast = false) {
    struct stat buf;
    if (stat(filename.c_str(), &buf) != 0) {
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
        auto source = SourceCode(filename);
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
                std::ifstream in(filename);
                std::string src((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
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
        exec.execute(ast);
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
        std::string msg = s;
        if (msg.rfind("__exc__:", 0) == 0) {
            msg = msg.substr(8);
            auto colon = msg.find(':');
            if (colon != std::string::npos)
                msg = msg.substr(0, colon) + ": " + msg.substr(colon + 1);
        }
        std::cerr << "[Nython] Uncaught exception — " << msg << "\n";
        report_uncaught_where(msg);
        return 1;
    } catch (std::runtime_error& e) {
        std::cerr << "runtime error: " << e.what() << "\n";
        report_uncaught_where(e.what());
        return 1;
    } catch (std::exception& e) {
        std::cerr << "error: " << e.what() << "\n";
        report_uncaught_where(e.what());
        return 1;
    }
    return 0;
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
void repl() {
    auto reporter_src = SourceCode(std::string("<repl>"));
    auto reporter = std::make_shared<Reporter>(reporter_src);
    auto vm_ptr = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
    NythonExecutor exec((Runnable*)vm_ptr.get());

    // Non-interactive mode: read from pipe/redirect
    if (!isatty(STDIN_FILENO)) {
        std::string all_code;
        {
            char buf[4096];
            while (true) {
                ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
                if (n <= 0) break;
                all_code.append(buf, n);
            }
        }
        // Strip exit/quit lines
        {
            std::string cleaned;
            size_t pos = 0;
            while (pos < all_code.size()) {
                size_t nl = all_code.find('\n', pos);
                std::string ln = (nl == std::string::npos) ? all_code.substr(pos) : all_code.substr(pos, nl - pos);
                auto t = ln.find_first_not_of(" \t\r");
                std::string trimmed = (t != std::string::npos) ? ln.substr(t) : "";
                if (trimmed != "exit" && trimmed != "quit" && trimmed != "exit()" && trimmed != "quit()") {
                    if (!cleaned.empty()) cleaned += "\n";
                    cleaned += ln;
                }
                if (nl == std::string::npos) break;
                pos = nl + 1;
            }
            all_code = cleaned;
        }
        if (all_code.empty()) return;
        try {
            auto src = SourceCode(all_code);
            auto rep = std::make_shared<Reporter>(src);
            auto lex = std::make_shared<Lexer>(src);
            lex->tokenize();
            auto par = std::make_shared<Parser>(rep.get(), (Runnable*)vm_ptr.get(), lex.get());
            auto ast = par->parse();
            if (ast) {
                Value val = exec.execute(ast);
                if (val.type != ValueType::NONE && val.type != ValueType::UNDEFINED) {
                    exec.printValue(val);
                    std::cout << std::endl;
                }
            }
        } catch (exception::SyntaxError& se) {
            std::cerr << "SyntaxError: " << se.what() << std::endl;
        } catch (std::string& err) {
            std::cerr << "Error: " << err << std::endl;
        } catch (std::exception& ex) {
            std::cerr << "Error: " << ex.what() << std::endl;
        } catch (...) {
            std::cerr << "Unknown error" << std::endl;
        }
        return;
    }

    // Interactive REPL
    print_header();
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
            std::cout << "\x1b[1mNython " << NYTHON_VERSION << "\x1b[0m — AI-Powered Multi-Paradigm Language\n\n"
                      << "  \x1b[36mCommands:\x1b[0m  exit, help, version, clear\n"
                      << "  \x1b[36mSyntax:\x1b[0m    Python (colon+indent), C/JS (braces), Lua (do/end)\n"
                      << "  \x1b[36mKeys:\x1b[0m      Up/Down=history, Ctrl+C=cancel, Ctrl+D=exit\n"
                      << "             Ctrl+L=clear, Ctrl+A=home, Ctrl+E=end, Tab=indent\n"
                      << "  \x1b[36mMultiline:\x1b[0m Lines ending with : { or do auto-continue\n"
                      << "             Empty line submits the block\n\n";
            continue;
        }
        if (code == "version") { std::cout << "Nython " << NYTHON_VERSION << "\n"; continue; }
        if (code == "clear") { std::cout << "\x1b[2J\x1b[H"; continue; }
#if NYTHON_WITH_IDE
        if (code == "ide") {
            std::cout << "Launching NythonIDE...\n";
            launch_ide(".");
            continue;
        }
#endif

        try {
            auto src = SourceCode(code);
            auto rep = std::make_shared<Reporter>(src);
            auto lex = std::make_shared<Lexer>(src);
            lex->tokenize();
            auto par = std::make_shared<Parser>(rep.get(), (Runnable*)vm_ptr.get(), lex.get());
            auto ast = par->parse();
            if (ast) {
                Value val = exec.execute(ast);
                if (val.type != ValueType::NONE && val.type != ValueType::UNDEFINED) {
                    std::string repr;
                    if (val.type == ValueType::INTEGER) repr = val.value.i.toString();
                    else if (val.type == ValueType::DOUBLE) {
                        std::ostringstream oss; oss << val.value.d; repr = oss.str();
                    }
                    else if (val.type == ValueType::BOOLEAN) repr = val.value.b ? "true" : "false";
                    else if (val.type == ValueType::USERDATA && val.value.p) {
                        repr = "\x1b[33m'" + exec.getStringValue(val) + "'\x1b[0m";
                    }
                    else if (val.type == ValueType::COLLECTABLE) {
                        std::vector<Value> sa = {val};
                        Value sv = exec.callBuiltin("str", sa, exec.global_ctx);
                        repr = exec.getStringValue(sv);
                    }
                    if (!repr.empty()) std::cout << "\x1b[90m" << repr << "\x1b[0m" << std::endl;
                }
            }
        } catch (exception::SyntaxError& se) {
            std::cout << "\x1b[31mSyntaxError:\x1b[0m " << se.what() << "\n";
        } catch (std::string& err) {
            if (err == "break" || err == "continue")
                std::cout << "\x1b[31mSyntaxError:\x1b[0m '" << err << "' outside loop\n";
            else
                std::cout << "\x1b[31mError:\x1b[0m " << err << "\n";
        } catch (nython::node::ReturnSignal&) {
            std::cout << "\x1b[31mSyntaxError:\x1b[0m 'return' outside function\n";
        } catch (std::runtime_error& re) {
            std::cout << "\x1b[31mRuntimeError:\x1b[0m " << re.what() << "\n";
        } catch (std::exception& ex) {
            std::cout << "\x1b[31mError:\x1b[0m " << ex.what() << "\n";
        } catch (...) {
            std::cout << "\x1b[31mUnknown error\x1b[0m\n";
        }
    }
    std::cout << "\x1b[1mGoodbye!\x1b[0m\n";
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
            case VMType::LIST:
            case VMType::MAP:
            case VMType::INSTANCE: {
                const void* k = key_of(v);
                if (!k) return NONE_VALUE;
                auto hit = to_interp.find(k);
                if (hit != to_interp.end()) return hit->second;
                bool is_list = v.type == VMType::LIST;
                auto* obj = new Object((Runnable*)exec.runner, is_list ? (v.b ? "tuple" : "list") : "map",
                                       is_list ? Type::LIST : Type::MAP);
                Value out(static_cast<Collectable*>(obj));
                to_interp.emplace(k, out);
                origin_of.emplace(obj, origin.size());
                origin.emplace_back(obj, v);
                if (is_list) {
                    int64_t n = 0;
                    for (auto& e : *v.list) (*obj->container)[std::to_string(n++)] = to_value(e);
                    (*obj->container)["__len__"] = intValue(n);
                    if (v.b) (*obj->container)["__tuple__"] = Value(1);
                } else {
                    // An instance crosses as a map of its attributes plus
                    // "__class__" - enough for builtins that read fields (the
                    // file functions take a file object's "handle").
                    for (auto& kv : *v.map) (*obj->container)[kv.first] = to_value(kv.second);
                    if (v.type == VMType::INSTANCE)
                        (*obj->container)["__class__"] = exec.makeStringValue(v.class_name);
                }
                return out;
            }
            default: return NONE_VALUE;
        }
    }

    // A fresh VM value for an interpreter value; containers that began as VM
    // values come back as those same VM objects.
    VMVal to_vm(const Value& v) {
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
            return m.count("__tuple__") ? VMVal::make_tuple(std::move(out)) : VMVal::make_list(std::move(out));
        }
        VMVal r = VMVal::make_map();
        for (auto& kv : m) (*r.map)[kv.first] = to_vm(kv.second);
        return r;
    }

    // True when the interpreter value still is what the VM value was.
    bool same(const Value& a, const VMVal& b) {
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
                size_t n = 0;
                bool changed = false;
                for (auto& kv : m) {
                    if (inst && kv.first == "__class__") continue;
                    n++;
                    auto it = vm.map->find(kv.first);
                    if (it == vm.map->end() || !same(kv.second, it->second)) { changed = true; break; }
                }
                if (!changed && n == vm.map->size()) continue;
                VMMap fresh;
                for (auto& kv : m) {
                    if (inst && kv.first == "__class__") continue;
                    fresh[kv.first] = to_vm(kv.second);
                }
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
            std::vector<Value> args;
            args.reserve(a.size());
            for (auto& v : a) args.push_back(conv.to_value(v));
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


int main(int argc, char** argv, char** env) {
    g_argv0 = (argc > 0 && argv[0]) ? argv[0] : "";
    nyrt::executable_path() = get_exe_path();
    try {
        setlocale(LC_ALL, "");
        nython::ConsoleManager cm; cm.setupConsole();

        if (argc >= 2) {
            std::string arg1 = argv[1];

            // ── Version / Help ───────────────────────────────────────────
            if (arg1 == "--version" || arg1 == "-v") {
                std::cout << "Nython " << NYTHON_VERSION;
#if NYTHON_WITH_IDE
                std::cout << " (IDE build)";
#else
                std::cout << " (CLI build)";
#endif
                std::cout << "\n";
                return 0;
            }
            if (arg1 == "--help" || arg1 == "-h") {
                std::cout
                    << "Usage: nython [options] [script.ny]\n\n"
                    << "Options:\n"
                    << "  -v, --version      Show version and build type\n"
                    << "  -h, --help         Show this help\n"
                    << "  -t, --tokenize     Tokenize file and dump tokens\n"
                    << "  -a, --ast          Show AST for file\n"
                    << "  --vm <file>        Run script via Bytecode VM\n"
                    << "  -d, --disasm       Disassemble file to bytecode listing\n"
                    << "  -p, --profile      Run with the profiler; measured per-function timings\n"
                    << "      --trace OUT F  Run F, recording every executed statement to OUT (JSON lines)\n"
                    << "  --ide              Launch NythonIDE GUI\n"
                    << "  --console          Force terminal REPL (no GUI, shows all output)\n"
                    << "  --cli, --repl      Same as --console\n"
                    << "  <file>             Run script (tree-walk interpreter)\n"
#if NYTHON_WITH_IDE
                    << "\nWhen launched with no arguments, NythonIDE opens automatically.\n"
                    << "Use --cli to force the terminal REPL instead.\n"
#endif
                    ;
                return 0;
            }

            // ── CLI / REPL override ──────────────────────────────────────
            if (arg1 == "--cli" || arg1 == "--repl" || arg1 == "--console") {
                repl();
                return 0;
            }

            // ── IDE launch ───────────────────────────────────────────────
#if NYTHON_WITH_IDE
            if (arg1 == "--ide") {
                launch_ide(get_binary_dir(argv[0]));
                return 0;
            }
#endif

            // ── Tokenize ─────────────────────────────────────────────────
            if ((arg1 == "--tokenize" || arg1 == "-t") && argc >= 3) {
                auto source = SourceCode(std::string(argv[2]));
                auto lex = std::make_shared<Lexer>(source);
                lex->tokenize(); std::cout << lex->toString(); return 0;
            }

            // ── AST dump ─────────────────────────────────────────────────
            if ((arg1 == "--ast" || arg1 == "-a") && argc >= 3) {
                return run_file(argv[2], true);
            }

            // ── Bytecode VM ──────────────────────────────────────────────
            if (arg1 == "--vm" && argc >= 3) {
                // SourceCode treats a string that is not an existing file as
                // program TEXT, so a mistyped path used to be run as code
                // (`--vm t/x.ny` evaluated `t / x.ny`). Refuse it like the
                // interpreter's run_file() does.
                {
                    struct stat vm_st;
                    if (stat(argv[2], &vm_st) != 0) {
                        std::cerr << "[Nython] No such file: " << argv[2] << "\n";
                        return 2;
                    }
                }
                nyrt::set_command_line(argv[2], argc, argv, 3);
                try {
                    auto source = SourceCode(std::string(argv[2]));
                    auto reporter = std::make_shared<Reporter>(source);
                    auto lexer2 = std::make_shared<Lexer>(source);
                    auto vm2 = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
                    // Non-daemon threads finish before the VM goes away (round 74).
                    struct JoinThreadsAtExit { ~JoinThreadsAtExit() { nyconc::join_nondaemon_at_exit(); } } join_threads_at_exit;
                    // Imports must resolve relative to the script, not the
                    // working directory — and must do so on BOTH engines. The
                    // interpreter already did; without this the same file's
                    // imports resolved under one engine and failed under the
                    // other.
                    vm2->set_script_dir(std::string(argv[2]));
                    auto parser2 = std::make_shared<Parser>(reporter.get(), (Runnable*)vm2.get(), lexer2.get());
                    install_vm_builtin_bridge((Runnable*)vm2.get());
                    lexer2->tokenize();
                    auto ast = parser2->parse();
                    // run() reports an uncaught exception itself and returns
                    // RUNTIME_ERROR; that result used to be ignored, so a
                    // failed program exited 0 on the VM and 1 on the
                    // interpreter.
                    if (ast) {
                        auto res = vm2->run(ast);
                        if (res == decltype(res)::RUNTIME_ERROR) return 1;
                    }
                } catch (exception::SyntaxError& e) {
                    // The VM compiler rejects some constructs the interpreter
                    // accepts. Report it rather than letting the exception
                    // escape main() and abort the process via std::terminate.
                    report_compiler_error("syntax error", e.location(), e.message()); return 1;
                } catch (exception::UnexpectedCharError& e) {
                    report_compiler_error("error", e.location(), e.message()); return 1;
                } catch (std::string& msg) {
                    std::cerr << "VM Error: " << msg << "\n"; return 1;
                } catch (std::exception& e) {
                    std::cerr << "VM Error: " << e.what() << "\n"; return 1;
                }
                return 0;
            }

            // ── Disassemble ──────────────────────────────────────────────
            if (arg1 == "--trace" && argc >= 4) {
                nyrt::set_command_line(argv[3], argc, argv, 4);
                g_trace_path = argv[2];
                return run_file(argv[3]);
            }

            if ((arg1 == "--profile" || arg1 == "-p") && argc >= 3) {
                nyrt::set_command_line(argv[2], argc, argv, 3);
                NythonExecutor::profiling_enabled() = true;
                return run_file(argv[2]);
            }

            if ((arg1 == "--disasm" || arg1 == "-d") && argc >= 3) {
                {
                    struct stat da_st;
                    if (stat(argv[2], &da_st) != 0) {
                        std::cerr << "[Nython] No such file: " << argv[2] << "\n";
                        return 2;
                    }
                }
                try {
                    auto source = SourceCode(std::string(argv[2]));
                    auto reporter = std::make_shared<Reporter>(source);
                    auto lexer2 = std::make_shared<Lexer>(source);
                    auto vm2 = std::make_shared<nython::vm::VirtualMachine>(reporter.get());
                    auto parser2 = std::make_shared<Parser>(reporter.get(), (Runnable*)vm2.get(), lexer2.get());
                    lexer2->tokenize();
                    auto ast = parser2->parse();
                    if (ast) {
                        auto code = vm2->compile_ast(ast);
                        std::cout << vm2->disassemble(*code);
                    }
                } catch (std::exception& e) {
                    std::cerr << "Disasm Error: " << e.what() << "\n"; return 1;
                }
                return 0;
            }

            // ── Run script (tree-walk) ───────────────────────────────────
            // Everything after the script path is the script's own command
            // line (sys.argv[1:]).
            nyrt::set_command_line(arg1, argc, argv, 2);
            return run_file(arg1);

        } else {
            // No arguments: launch IDE (if built with IDE support) or REPL
#if NYTHON_WITH_IDE
            // Determine binary directory for IDE file lookup
            if (!launch_ide(get_binary_dir(argv[0]))) {
                // IDE file not found — fall back to REPL
                repl();
            }
#else
            repl();
#endif
        }

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
