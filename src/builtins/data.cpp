#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/data.cpp
// JSON, crypto, collections
// ─────────────────────────────────────────────────────────────────────────────
// HOW THIS FILE WORKS:
//   dispatch_data() is called from NythonExecutor::callBuiltin().
//   It has full access to the executor via the `E` reference (same as `*this`
//   in the original monolithic main.cpp).  Every helper that was previously
//   a member call (getStringValue, makeStringValue, callBuiltin, etc.) is
//   accessed through `E.` — keeping code changes minimal.
// ─────────────────────────────────────────────────────────────────────────────

// Platform compatibility (must come first)
#include "platform_compat.hpp"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <regex>
#include <cstdlib>
#include <cmath>
#include <chrono>
#include <random>
#include <thread>
#include <mutex>
#include <functional>
#include <iomanip>
#include <string>
#include <vector>
#include <map>
#include <ctime>
#include <cwctype>
#include <locale>

// Full executor definition (needed for E.getStringValue etc.)
#include "NythonExecutor.hpp"
#include "NyJson.hpp"
#include "builtins/data.hpp"

// ── Namespace imports (match main.cpp) ────────────────────────────────────────
using namespace std;
using namespace nython;
using namespace nython::io;
using namespace nython::node;
using namespace nython::lexer;
using namespace nython::kernel;
using namespace nython::parser;
using namespace nython::reader;
using namespace nython::exception;

// ════════════════════════════════════════════════════════════════════════════════
// dispatch_data
// ════════════════════════════════════════════════════════════════════════════════
Value dispatch_data(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx) {
    // Local aliases — identical names to original main.cpp code so the
    // extracted if-blocks compile unchanged.
    auto  makeStringValue  = [&](const std::string& s) { return E.makeStringValue(s); };
    auto  getStringValue   = [&](const Value& v)       { return E.getStringValue(v); };
    auto  isStringValue    = [&](const Value& v)       { return E.isStringValue(v); };
    auto  callBuiltin      = [&](const std::string& n, std::vector<Value>& a, Context* c)
                                { return E.callBuiltin(n, a, c); };
    auto  callFunctionValue= [&](Value fn, std::vector<Value>& a, Context* c)
                                { return E.callFunctionValue(fn, a, c); };
    auto  isTruthy         = [&](Value v) { return E.isTruthy(v); };
    auto  evalNode         = [&](node_ptr n, Context* c) { return E.evalNode(n, c); };
    auto& file_handles     = E.file_handles;
    auto& next_file_handle = E.next_file_handle;
    Runnable* runner       = E.runner;
    auto& func_names       = E.func_names;
    auto& instance_to_class= E.instance_to_class;
    auto& instance_properties = E.instance_properties;
    auto& class_by_name    = E.class_by_name;
    auto& class_parent     = E.class_parent;
    auto& super_parent_stack = E.super_parent_stack;
    auto& func_ast_nodes   = E.func_ast_nodes;
    auto& func_id_store    = E.func_id_store;
    auto& instance_store   = E.instance_store;
    auto& string_store     = E.string_store;
    auto  registerBuiltin  = [&](const std::string& n) { E.registerBuiltin(n); };
    auto  callMethod       = [&](Value inst, const std::string& mname, std::vector<Value>& a, Context* c)
                                { return E.callMethod(inst, mname, a, c); };
    auto  printValue       = [&](const Value& v, Context* c = nullptr) { E.printValue(v, c ? c : ctx); };

    // ── shape_to_size helper (used by tensor builtins) ───────────────────────
    auto shape_to_size = [&](const Value& v) -> int {
        if (v.type == ValueType::INTEGER) return (int)bigint_to_i64(v.value.i);
        if (v.type == ValueType::DOUBLE)  return (int)v.value.d;
        if (v.isCollectable()) {
            auto* c = dynamic_cast<Container*>(v.value.gc);
            if (c && c->container) {
                auto li = c->container->find("__len__");
                int len = (li != c->container->end()) ? (int)bigint_to_i64(li->second.value.i) : 0;
                if (len == 0) return 0;
                int total = 1;
                for (int k = 0; k < len; k++) {
                    auto ei = c->container->find(std::to_string(k));
                    if (ei != c->container->end()) {
                        if (ei->second.type == ValueType::INTEGER)
                            total *= (int)bigint_to_i64(ei->second.value.i);
                        else if (ei->second.type == ValueType::DOUBLE)
                            total *= (int)ei->second.value.d;
                    }
                }
                return total;
            }
        }
        return 0;
    };

// ── Extracted builtin implementations ────────────────────────────────────────
    // ── from main.cpp lines 4858–4887 ──────────────────────────────────────────
        // ===================== FIXED CRYPTO =====================
        if (name == "md5") {
            if (!args.empty())
                return makeStringValue(ny_crypto::md5(getStringValue(args[0])));
            return NONE_VALUE;
        }
        if (name == "sha256") {
            if (!args.empty())
                return makeStringValue(ny_crypto::sha256(getStringValue(args[0])));
            return NONE_VALUE;
        }
        // ===================== JSON (include/NyJson.hpp) =====================
        // One codec for both engines. Strings are escaped, nested arrays and
        // objects decode, \u escapes (with surrogate pairs) become UTF-8, and
        // invalid JSON decodes to none rather than to a partial value.
        if (name == "json_encode" || name == "json_stringify") {
            if (args.empty()) return makeStringValue("null");
            std::function<void(const Value&, std::string&, int)> enc;
            enc = [&](const Value& v, std::string& out, int depth) {
                if (depth > 200) { out += "null"; return; }
                if (v.isNone() || v.type == ValueType::UNDEFINED) { out += "null"; return; }
                if (v.type == ValueType::BOOLEAN) { out += v.value.b ? "true" : "false"; return; }
                if (v.type == ValueType::INTEGER) {
                    std::string digits = v.value.i.toString(10);
                    out += digits.empty() ? "0" : digits;
                    return;
                }
                if (v.type == ValueType::DOUBLE) { out += nyjson::number((double)v.value.d); return; }
                if (isStringValue(v)) { nyjson::quote_to(out, getStringValue(v)); return; }
                if (v.isCollectable() && v.value.gc) {
                    auto* cont = dynamic_cast<Container*>(v.value.gc);
                    if (cont && cont->container) {
                        auto li = cont->container->find("__len__");
                        if (li != cont->container->end()) {
                            int len = (int)bigint_to_i64(li->second.value.i);
                            out += "[";
                            for (int i = 0; i < len; i++) {
                                if (i > 0) out += ", ";
                                auto it = cont->container->find(std::to_string(i));
                                if (it != cont->container->end()) enc(it->second, out, depth + 1);
                                else out += "null";
                            }
                            out += "]";
                            return;
                        }
                        // Sorted keys: the container is a hash map, so its own
                        // order is arbitrary and would differ run to run.
                        std::vector<std::string> keys;
                        for (auto& kv : *cont->container) {
                            const std::string& k = kv.first;
                            if (k == "__len__" || k == "__type__" || k == "__name__" || k == "__class__") continue;
                            keys.push_back(k);
                        }
                        std::sort(keys.begin(), keys.end());
                        out += "{";
                        bool first = true;
                        for (auto& k : keys) {
                            if (!first) out += ", ";
                            first = false;
                            nyjson::quote_to(out, k);
                            out += ": ";
                            enc(cont->container->find(k)->second, out, depth + 1);
                        }
                        out += "}";
                        return;
                    }
                }
                out += "null";
            };
            std::string out;
            enc(args[0], out, 0);
            return makeStringValue(out);
        }
        if (name == "json_decode" || name == "json_parse") {
            if (args.empty()) return NONE_VALUE;
            nyjson::Node root;
            std::string err;
            if (!nyjson::parse(getStringValue(args[0]), root, err)) return NONE_VALUE;
            std::function<Value(const nyjson::Node&)> conv = [&](const nyjson::Node& n) -> Value {
                switch (n.kind) {
                    case nyjson::Node::Null: return NONE_VALUE;
                    case nyjson::Node::Bool: return Value(n.b);
                    case nyjson::Node::Int: return Value(bigint((long long)n.i));
                    case nyjson::Node::Float: return Value(n.d);
                    case nyjson::Node::Str: return makeStringValue(n.s);
                    case nyjson::Node::Arr: {
                        auto* obj = new Object((Runnable*)runner, "list", Type::LIST);
                        int idx = 0;
                        for (auto& it : n.items) obj->set(std::to_string(idx++), conv(it));
                        obj->set("__len__", Value(idx));
                        return Value((Collectable*)obj);
                    }
                    case nyjson::Node::Obj: {
                        auto* obj = new Object((Runnable*)runner, "map", Type::LIST);
                        for (auto& f : n.fields) obj->set(f.first, conv(f.second));
                        return Value((Collectable*)obj);
                    }
                }
                return NONE_VALUE;
            };
            return conv(root);
        }
        // ===================== CRYPTO/HASH MODULE =====================
    // ── from main.cpp lines 8519–8658 ──────────────────────────────────────────
        if (name == "hash_sha256" || name == "hash_md5") {
            // Simple hash using std::hash (not cryptographic, but functional)
            if (args.size() >= 1) {
                std::string input = getStringValue(args[0]);
                std::hash<std::string> hasher;
                size_t h = hasher(input);
                // Generate pseudo-hash string
                char buf[32];
                snprintf(buf, sizeof(buf), "%016lx", (unsigned long)h);
                return makeStringValue(std::string(buf));
            }
            return makeStringValue("");
        }
        if (name == "base64_encode") {
            if (args.size() >= 1) {
                std::string input = getStringValue(args[0]);
                const char* chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
                std::string result;
                int i = 0, len = input.size();
                unsigned char c3[3]; unsigned char c4[4];
                while (len--) {
                    c3[i++] = *(input.c_str() + (input.size() - len - 1));
                    if (i == 3) {
                        c4[0] = static_cast<unsigned char>((c3[0] & 0xfc) >> 2);
                        c4[1] = ((c3[0] & 0x03) << 4) + ((c3[1] & 0xf0) >> 4);
                        c4[2] = ((c3[1] & 0x0f) << 2) + ((c3[2] & 0xc0) >> 6);
                        c4[3] = static_cast<unsigned char>(c3[2] & 0x3f);
                        for (int j = 0; j < 4; j++) result += chars[c4[j]];
                        i = 0;
                    }
                }
                if (i) {
                    for (int j = i; j < 3; j++) c3[j] = '\0';
                    c4[0] = static_cast<unsigned char>((c3[0] & 0xfc) >> 2);
                    c4[1] = ((c3[0] & 0x03) << 4) + ((c3[1] & 0xf0) >> 4);
                    c4[2] = ((c3[1] & 0x0f) << 2) + ((c3[2] & 0xc0) >> 6);
                    for (int j = 0; j < i + 1; j++) result += chars[c4[j]];
                    while (i++ < 3) result += '=';
                }
                return makeStringValue(result);
            }
            return makeStringValue("");
        }
        if (name == "base64_decode") {
            if (args.size() >= 1) {
                std::string input = getStringValue(args[0]);
                const std::string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
                std::string result;
                int i = 0;
                unsigned char c4[4], c3[3];
                for (char ch : input) {
                    if (ch == '=') break;
                    auto pos = chars.find(ch);
                    if (pos == std::string::npos) continue;
                    c4[i++] = (unsigned char)pos;
                    if (i == 4) {
                        c3[0] = (c4[0] << 2) + ((c4[1] & 0x30) >> 4);
                        c3[1] = ((c4[1] & 0xf) << 4) + ((c4[2] & 0x3c) >> 2);
                        c3[2] = ((c4[2] & 0x3) << 6) + c4[3];
                        for (int j = 0; j < 3; j++) result += (char)c3[j];
                        i = 0;
                    }
                }
                if (i) {
                    for (int j = i; j < 4; j++) c4[j] = 0;
                    c3[0] = (c4[0] << 2) + ((c4[1] & 0x30) >> 4);
                    c3[1] = ((c4[1] & 0xf) << 4) + ((c4[2] & 0x3c) >> 2);
                    for (int j = 0; j < i - 1; j++) result += (char)c3[j];
                }
                return makeStringValue(result);
            }
            return makeStringValue("");
        }
        if (name == "hex_encode") {
            if (args.size() >= 1) {
                std::string input = getStringValue(args[0]);
                std::string result;
                for (unsigned char c : input) {
                    char buf[4]; snprintf(buf, sizeof(buf), "%02x", static_cast<unsigned>(c));
                    result += buf;
                }
                return makeStringValue(result);
            }
            return makeStringValue("");
        }
        if (name == "hex_decode") {
            if (args.size() >= 1) {
                std::string input = getStringValue(args[0]);
                std::string result;
                for (size_t i = 0; i + 1 < input.size(); i += 2) {
                    unsigned int hex_byte = 0;
                    for (int j = 0; j < 2; j++) {
                        char ch = input[i + static_cast<size_t>(j)];
                        hex_byte <<= 4;
                        if (ch >= '0' && ch <= '9') hex_byte |= static_cast<unsigned>(ch - '0');
                        else if (ch >= 'a' && ch <= 'f') hex_byte |= static_cast<unsigned>(ch - 'a' + 10);
                        else if (ch >= 'A' && ch <= 'F') hex_byte |= static_cast<unsigned>(ch - 'A' + 10);
                    }
                    result += static_cast<char>(hex_byte);
                }
                return makeStringValue(result);
            }
            return makeStringValue("");
        }
        if (name == "url_encode") {
            if (args.size() >= 1) {
                std::string input = getStringValue(args[0]);
                std::string result;
                for (unsigned char c : input) {
                    if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') result += c;
                    else { char buf[4]; snprintf(buf, sizeof(buf), "%%%02X", static_cast<unsigned>(c)); result += buf; }
                }
                return makeStringValue(result);
            }
            return makeStringValue("");
        }
        if (name == "url_decode") {
            if (args.size() >= 1) {
                std::string input = getStringValue(args[0]);
                std::string result;
                for (size_t i = 0; i < input.size(); i++) {
                    if (input[i] == '%' && i + 2 < input.size()) {
                        unsigned int hex_byte = 0;
                        for (int j = 0; j < 2; j++) {
                            char ch = input[i + 1 + static_cast<size_t>(j)];
                            hex_byte <<= 4;
                            if (ch >= '0' && ch <= '9') hex_byte |= static_cast<unsigned>(ch - '0');
                            else if (ch >= 'a' && ch <= 'f') hex_byte |= static_cast<unsigned>(ch - 'a' + 10);
                            else if (ch >= 'A' && ch <= 'F') hex_byte |= static_cast<unsigned>(ch - 'A' + 10);
                        }
                        result += static_cast<char>(hex_byte); i += 2;
                    } else if (input[i] == '+') result += ' ';
                    else result += input[i];
                }
                return makeStringValue(result);
            }
            return makeStringValue("");
        }

        // ===================== THREADING MODULE =====================
    // ── from main.cpp lines 9120–9256 ──────────────────────────────────────────
        // ===================== COLLECTIONS MODULE =====================
        if (name == "Counter") {
            if (args.size() >= 1 && args[0].isCollectable()) {
                auto* cont = dynamic_cast<Container*>(args[0].value.gc);
                auto* result = new Object((Runnable*)runner, "map", Type::LIST);
                if (cont && cont->container) {
                    auto li = cont->container->find("__len__");
                    if (li != cont->container->end()) {
                        int len = (int)bigint_to_i64(li->second.value.i);
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end()) {
                                std::string key = getStringValue(it->second);
                                auto existing = result->container->find(key);
                                if (existing != result->container->end()) {
                                    existing->second = Value((int)(bigint_to_i64(existing->second.value.i) + 1));
                                } else {
                                    result->set(key, Value(1));
                                }
                            }
                        }
                    }
                }
                return Value((Collectable*)result);
            }
            return NONE_VALUE;
        }
        if (name == "Set") {
            auto* result = new Object((Runnable*)runner, "set", Type::LIST);
            result->set("__type__", makeStringValue("set"));
            int idx = 0;
            if (args.size() >= 1 && args[0].isCollectable()) {
                auto* cont = dynamic_cast<Container*>(args[0].value.gc);
                if (cont && cont->container) {
                    auto li = cont->container->find("__len__");
                    if (li != cont->container->end()) {
                        int len = (int)bigint_to_i64(li->second.value.i);
                        std::set<std::string> seen;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end()) {
                                std::string sv = getStringValue(it->second);
                                if (seen.find(sv) == seen.end()) {
                                    seen.insert(sv);
                                    result->set(std::to_string(idx++), it->second);
                                }
                            }
                        }
                    }
                }
            }
            result->set("__len__", Value(idx));
            return Value((Collectable*)result);
        }
        if (name == "deque" || name == "OrderedDict" || name == "defaultdict") {
            // Deque/OrderedDict/defaultdict: return a list/map (simplified)
            auto* result = new Object((Runnable*)runner, "list", Type::LIST);
            result->set("__len__", Value(0));
            return Value((Collectable*)result);
        }

        if (name == "any") {
            if (args.size() >= 1 && args[0].isCollectable()) {
                auto* cont = dynamic_cast<Container*>(args[0].value.gc);
                if (cont && cont->container) {
                    auto li = cont->container->find("__len__");
                    if (li != cont->container->end()) {
                        int len = (int)bigint_to_i64(li->second.value.i);
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end() && isTruthy(it->second)) return Value(true);
                        }
                    }
                }
            }
            return Value(false);
        }
        if (name == "all") {
            if (args.size() >= 1 && args[0].isCollectable()) {
                auto* cont = dynamic_cast<Container*>(args[0].value.gc);
                if (cont && cont->container) {
                    auto li = cont->container->find("__len__");
                    if (li != cont->container->end()) {
                        int len = (int)bigint_to_i64(li->second.value.i);
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end() && !isTruthy(it->second)) return Value(false);
                        }
                    }
                }
            }
            return Value(true);
        }
        if (name == "exit" || name == "quit") {
            int code = (args.size() >= 1) ? (int)bigint_to_i64(args[0].value.i) : 0;
            std::exit(code);
            return NONE_VALUE;
        }
        if (name == "open") {
            // open(filename, mode) - returns file handle as map
            if (args.size() >= 1) {
                std::string filename = getStringValue(args[0]);
                std::string mode = (args.size() >= 2) ? getStringValue(args[1]) : "r";
                auto* fobj = new Object((Runnable*)runner, "file", Type::LIST);
                fobj->set("name", makeStringValue(filename));
                fobj->set("mode", makeStringValue(mode));
                if (mode == "r") {
                    std::ifstream f(filename);
                    if (f.good()) {
                        std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
                        fobj->set("content", makeStringValue(content));
                        fobj->set("open", Value(true));
                    } else {
                        fobj->set("open", Value(false));
                    }
                } else {
                    fobj->set("content", makeStringValue(""));
                    fobj->set("open", Value(true));
                }
                return Value((Collectable*)fobj);
            }
            return NONE_VALUE;
        }
        if (name == "chr") {
            if (args.size() >= 1) {
                int code = (int)bigint_to_i64(args[0].value.i);
                return makeStringValue(std::string(1, static_cast<char>(code)));
            }
            return makeStringValue("");
        }
        if (name == "ord") {
            if (args.size() >= 1) {
                std::string s = getStringValue(args[0]);
                if (!s.empty()) return Value((int)(unsigned char)s[0]);
            }
            return Value(0);
        }
    return UNDEFINED_VALUE;  // not handled by this module
}

#pragma GCC diagnostic pop
