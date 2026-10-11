#include "ConsoleManager.hpp"

#ifdef _WIN32
#define  _CRT_SECURE_NO_WARNINGS 1
#include <windows.h>
#else
#include <unistd.h>
#endif // _WIN32

#include <stdio.h>
#include <stdlib.h>

#ifdef _WIN32
// Some old MinGW/CYGWIN distributions don't define this:
#ifndef ENABLE_VIRTUAL_TERMINAL_PROCESSING
#define ENABLE_VIRTUAL_TERMINAL_PROCESSING  0x0004
#endif // ENABLE_VIRTUAL_TERMINAL_PROCESSING
#endif // _WIN32

// The process-wide console setup: ANSI colour on a real console, nothing
// else. Two things this used to do, and why it no longer does:
//
//  - It called exit(GetLastError()) when stdin or stdout was not a console.
//    On Windows that is every run whose output is redirected - `nython s.ny >
//    out.txt`, an IDE or build tool capturing output, the IDE's own Run
//    command - which all exited at once with code 6 (ERROR_INVALID_HANDLE)
//    and no output. Now a handle that is not a console is simply left alone.
//  - It put stdin in no-echo, unbuffered mode for every run and restored it
//    only on the REPL's way out, so `input()` in a script ran without echo
//    and a script left the terminal that way. The REPL sets and restores its
//    own raw mode (NythonREPL.hpp); input is not touched here.
namespace nython
{
#ifdef _WIN32
    static HANDLE stdoutHandle = INVALID_HANDLE_VALUE;
    static DWORD outModeInit = 0;
    static bool outIsConsole = false;

    void ConsoleManager::setupConsole() {
        stdoutHandle = GetStdHandle(STD_OUTPUT_HANDLE);
        DWORD mode = 0;
        outIsConsole = stdoutHandle != nullptr && stdoutHandle != INVALID_HANDLE_VALUE &&
                       GetConsoleMode(stdoutHandle, &mode);
        if (!outIsConsole) return;          // a pipe or a file: nothing to set up
        outModeInit = mode;
        // Enable ANSI escape codes; a console too old to have them keeps its mode.
        SetConsoleMode(stdoutHandle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }

    void ConsoleManager::restoreConsole() {
        if (!outIsConsole) return;
        printf("\x1b[0m");                  // reset colours
        fflush(stdout);
        SetConsoleMode(stdoutHandle, outModeInit);
    }
#else
    void ConsoleManager::setupConsole() {
        // Terminals interpret ANSI escapes already; nothing to set up.
    }

    void ConsoleManager::restoreConsole() {
        // Reset colours - on a terminal only, never into a pipe or a file.
        if (isatty(STDOUT_FILENO)) {
            printf("\x1b[0m");
            fflush(stdout);
        }
    }
#endif // _WIN32
}
