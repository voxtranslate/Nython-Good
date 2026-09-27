// builtins/pycore.cpp
// The Python core builtins for the interpreter: numbers, text, iteration
// and conversion - len, str, repr, ascii, format, int, float, bool, abs,
// round, pow, divmod, hex, oct, bin, chr, ord, min, max, sum, sorted,
// reversed, list, tuple, set, dict, enumerate, zip, map, filter, any, all,
// range, type.
// ─────────────────────────────────────────────────────────────────────────────
// dispatch_pycore() runs first in NythonExecutor::callBuiltin. These used to
// be spread over core.cpp and tensor.cpp, with two different min/max/abs/hex
// (core.cpp's shadowed tensor.cpp's), 32-bit results, min/max comparing only
// their first two arguments, list(x) returning x itself, and none of them
// accepting generators, strings or dicts as iterables. Every one of them now
// iterates through NythonExecutor::iterItems, compares through orderValues,
// computes through the shared numeric core and formats through the shared
// nypy formatter, so they agree with the operators and with the VM.
//
// Keyword arguments arrive through E.cur_kwargs_ (set by evalCall).
// ─────────────────────────────────────────────────────────────────────────────
#include "platform_compat.hpp"
#include <algorithm>
#include <cmath>
#include <string>
#include <unordered_map>
#include <vector>
#include "NythonExecutor.hpp"

using namespace nython;
using namespace nython::kernel;

namespace {
enum PyB {
    B_LEN = 1, B_STR, B_REPR, B_ASCII, B_FORMAT, B_INT, B_FLOAT, B_BOOL, B_ABS, B_ROUND,
    B_POW, B_DIVMOD, B_HEX, B_OCT, B_BIN, B_CHR, B_ORD, B_MIN, B_MAX, B_SUM, B_SORTED,
    B_REVERSED, B_LIST, B_TUPLE, B_SET, B_DICT, B_ENUMERATE, B_ZIP, B_MAP, B_FILTER,
    B_ANY, B_ALL, B_RANGE, B_TYPE, B_FMTVAL, B_HASH
};
}

Value dispatch_pycore(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    static const std::unordered_map<std::string, int> ids = {
        {"len", B_LEN}, {"sizeof", B_LEN}, {"str", B_STR}, {"repr", B_REPR}, {"ascii", B_ASCII},
        {"format", B_FORMAT}, {"int", B_INT}, {"float", B_FLOAT}, {"bool", B_BOOL}, {"abs", B_ABS},
        {"round", B_ROUND}, {"pow", B_POW}, {"divmod", B_DIVMOD}, {"hex", B_HEX}, {"oct", B_OCT},
        {"bin", B_BIN}, {"chr", B_CHR}, {"ord", B_ORD}, {"min", B_MIN}, {"max", B_MAX}, {"sum", B_SUM},
        {"sorted", B_SORTED}, {"reversed", B_REVERSED}, {"list", B_LIST}, {"tuple", B_TUPLE},
        {"set", B_SET}, {"dict", B_DICT}, {"enumerate", B_ENUMERATE}, {"zip", B_ZIP}, {"map", B_MAP},
        {"filter", B_FILTER}, {"any", B_ANY}, {"all", B_ALL}, {"range", B_RANGE},
        {"type", B_TYPE}, {"typeof", B_TYPE}, {"__format_value__", B_FMTVAL}, {"hash", B_HASH},
    };
    auto idit = ids.find(name);
    if (idit == ids.end()) return UNDEFINED_VALUE;
    const int id = idit->second;

    // Keyword arguments for this call (empty when there are none).
    static const std::unordered_map<std::string, Value> kNoKw;
    // Taken, not borrowed: a builtin this one calls internally must not see them.
    const std::unordered_map<std::string, Value>* kwp = E.cur_kwargs_;
    E.cur_kwargs_ = nullptr;
    const std::unordered_map<std::string, Value>& kw = kwp ? *kwp : kNoKw;
    auto kwarg = [&](const char* k) -> const Value* {
        auto it = kw.find(k);
        return it == kw.end() ? nullptr : &it->second;
    };
    auto arg = [&](size_t i, const char* kname) -> const Value* {
        if (i < args.size()) return &args[i];
        return kname ? kwarg(kname) : nullptr;
    };
    auto str_ = [&](const std::string& s) { return E.makeStringValue(s); };
    auto need = [&](size_t n, const char* what) {
        if (args.size() < n) E.pyRaise("TypeError", std::string(what) + " expected " + std::to_string(n) + " argument" + (n == 1 ? "" : "s") + ", got " + std::to_string(args.size()));
    };
    auto asInt = [&](const Value& v, const char* what) -> NythonExecutor::Num {
        NythonExecutor::Num n;
        if (!NythonExecutor::asNum(v, n) || n.k == 3)
            E.pyRaise("TypeError", "'" + E.typeNameOf(v) + "' object cannot be interpreted as an integer" + (what ? std::string(" (") + what + ")" : std::string()));
        return n;
    };
    // Ordering used by sorted/min/max: Python's where it is defined; values
    // Python cannot compare fall back to type name then text, so a sort never
    // fails halfway.
    auto less = [&](const Value& a, const Value& b) {
        int c;
        if (E.orderValues(a, b, c, ctx)) return c < 0;
        std::string ta = E.typeNameOf(a), tb = E.typeNameOf(b);
        if (ta != tb) return ta < tb;
        return E.strOf(a, ctx) < E.strOf(b, ctx);
    };
    auto call1 = [&](const Value& fn, const Value& x) {
        std::vector<Value> a = {x};
        return E.callFunctionValue(fn, a, ctx);
    };
    auto isFunc = [&](const Value& v) {
        return v.type == ValueType::USERDATA && v.value.p && E.func_names.count(v.value.p) && !E.instance_to_class.count(v.value.p);
    };
    auto callAny = [&](const Value& fn, std::vector<Value>& a) -> Value {
        if (fn.type == ValueType::USERDATA && fn.value.p) {
            auto fit = E.func_names.find(fn.value.p);
            if (fit != E.func_names.end() && fit->second.rfind("__builtin__:", 0) == 0)
                return E.callBuiltin(fit->second.substr(12), a, ctx);
            if (fit != E.func_names.end() && fit->second.rfind("__class__:", 0) == 0) {
                // A class used as the function: construct.
                return E.callFunctionValue(fn, a, ctx);
            }
        }
        return E.callFunctionValue(fn, a, ctx);
    };

    switch (id) {
    case B_LEN: {
        need(1, "len()");
        const Value& v = args[0];
        if (E.isStringValue(v)) return intValue((int64_t)nypy::u8_len(*(std::string*)v.value.p));
        // A generator has no length (it is lazy), as in Python.
        if (nygen::is_gen(v)) E.pyRaise("TypeError", "object of type 'generator' has no len()");
        if (Container* c = E.contOf(v)) {
            int64_t n = NythonExecutor::seqLen(c);
            if (n >= 0) return intValue(n);
            return intValue(E.dictSize(c));
        }
        if (E.isInstanceVal(v) && E.instanceHasMethod(v, "__len__")) {
            std::vector<Value> no;
            Value r = E.callMethod(v, "__len__", no, ctx);
            if (r.type != ValueType::NONE) return r;
        }
        // len(none) is 0, as it always was here: library code takes the
        // length of a missing (none) entry and relies on that.
        if (v.type == ValueType::NONE || v.type == ValueType::UNDEFINED) return intValue(0);
        E.pyRaise("TypeError", "object of type '" + E.typeNameOf(v) + "' has no len()");
    }
    case B_STR:
        if (args.empty()) return str_("");
        if (E.isStringValue(args[0])) return args[0];
        return str_(E.strOf(args[0], ctx));
    case B_REPR:
        need(1, "repr()");
        return str_(E.reprOf(args[0], ctx));
    case B_ASCII:
        need(1, "ascii()");
        return str_(E.toFmtVal(args[0], 'a', ctx).s);
    case B_FMTVAL: {
        // An f-string field: __format_value__(value, spec, conversion).
        need(3, "__format_value__()");
        std::string spec = E.getStringValue(args[1]), conv = E.getStringValue(args[2]);
        if (conv.empty()) {
            if (spec.empty()) return str_(E.strOf(args[0], ctx));
            return str_(E.formatValue(args[0], spec, ctx));
        }
        nypy::FmtVal fv = E.toFmtVal(args[0], conv[0], ctx);
        return str_(E.nyCall([&] { return nypy::format_value(fv, spec); }));
    }
    case B_FORMAT: {
        need(1, "format()");
        const Value* sp = arg(1, "format_spec");
        return str_(E.formatValue(args[0], sp ? E.getStringValue(*sp) : std::string(), ctx));
    }
    case B_INT: {
        if (args.empty()) return intValue(0);
        const Value& v = args[0];
        const Value* bv = arg(1, "base");
        if (bv) {
            if (!E.isStringValue(v)) E.pyRaise("TypeError", "int() can't convert non-string with explicit base");
            NythonExecutor::Num b = asInt(*bv, nullptr);
            int base = (int)b.i;
            if (b.k != 1 || (base != 0 && (base < 2 || base > 36))) E.pyRaise("ValueError", "int() base must be >= 2 and <= 36, or 0");
            nypy::BigInt out;
            const std::string& s = *(std::string*)v.value.p;
            if (!nypy::parse_int_str(s, base, out))
                E.pyRaise("ValueError", "invalid literal for int() with base " + std::to_string(base) + ": " + nypy::str_repr(s));
            return intValue(out);
        }
        switch (v.type) {
            case ValueType::INTEGER: return v;
            case ValueType::BOOLEAN: return intValue(v.value.b ? 1 : 0);
            case ValueType::DOUBLE: {
                double d = (double)v.value.d;
                if (std::isnan(d)) E.pyRaise("ValueError", "cannot convert float NaN to integer");
                if (std::isinf(d)) E.pyRaise("OverflowError", "cannot convert float infinity to integer");
                d = std::trunc(d);
                if (d >= -9.2e18 && d <= 9.2e18) return intValue((int64_t)d);
                return intValue(nypy::BigInt::from_double(d));
            }
            default: break;
        }
        if (E.isStringValue(v)) {
            const std::string& s = *(std::string*)v.value.p;
            nypy::BigInt out;
            if (!nypy::parse_int_default(s, out))
                E.pyRaise("ValueError", "invalid literal for int() with base 10: " + nypy::str_repr(s));
            return intValue(out);
        }
        if (E.isInstanceVal(v) && E.instanceHasMethod(v, "__int__")) {
            std::vector<Value> no;
            Value r = E.callMethod(v, "__int__", no, ctx);
            if (r.type != ValueType::NONE) return r;
        }
        E.pyRaise("TypeError", "int() argument must be a string, a bytes-like object or a real number, not '" + E.typeNameOf(v) + "'");
    }
    case B_FLOAT: {
        if (args.empty()) return Value(0.0);
        const Value& v = args[0];
        NythonExecutor::Num n;
        if (NythonExecutor::asNum(v, n)) return Value(NythonExecutor::numD(n));
        if (E.isStringValue(v)) {
            const std::string& s = *(std::string*)v.value.p;
            double d;
            if (!nypy::parse_float_str(s, d)) E.pyRaise("ValueError", "could not convert string to float: " + nypy::str_repr(s));
            return Value(d);
        }
        if (E.isInstanceVal(v) && E.instanceHasMethod(v, "__float__")) {
            std::vector<Value> no;
            Value r = E.callMethod(v, "__float__", no, ctx);
            if (r.type != ValueType::NONE) return r;
        }
        E.pyRaise("TypeError", "float() argument must be a string or a real number, not '" + E.typeNameOf(v) + "'");
    }
    case B_BOOL:
        return Value(!args.empty() && E.isTruthy(args[0]));
    case B_ABS: {
        need(1, "abs()");
        NythonExecutor::Num n;
        if (NythonExecutor::asNum(args[0], n)) {
            if (n.k == 3) return Value(std::fabs(n.d));
            if (n.k == 1 && n.i != INT64_MIN) return intValue(n.i < 0 ? -n.i : n.i);
            nypy::BigInt b = NythonExecutor::numBig(n); b.neg = false;
            return intValue(b);
        }
        if (E.isInstanceVal(args[0]) && E.instanceHasMethod(args[0], "__abs__")) {
            std::vector<Value> no;
            Value r = E.callMethod(args[0], "__abs__", no, ctx);
            if (r.type != ValueType::NONE) return r;
        }
        E.pyRaise("TypeError", "bad operand type for abs(): '" + E.typeNameOf(args[0]) + "'");
    }
    case B_ROUND: {
        need(1, "round()");
        NythonExecutor::Num n;
        if (!NythonExecutor::asNum(args[0], n)) {
            if (E.isInstanceVal(args[0]) && E.instanceHasMethod(args[0], "__round__")) {
                std::vector<Value> a;
                if (const Value* nd = arg(1, "ndigits")) a.push_back(*nd);
                Value r = E.callMethod(args[0], "__round__", a, ctx);
                if (r.type != ValueType::NONE) return r;
            }
            E.pyRaise("TypeError", "type " + E.typeNameOf(args[0]) + " doesn't define __round__ method");
        }
        const Value* ndv = arg(1, "ndigits");
        if (ndv && ndv->type == ValueType::NONE) ndv = nullptr;
        if (n.k == 3) {
            if (!ndv) {
                if (std::isnan(n.d)) E.pyRaise("ValueError", "cannot convert float NaN to integer");
                if (std::isinf(n.d)) E.pyRaise("OverflowError", "cannot convert float infinity to integer");
                double r = std::nearbyint(n.d);   // ties to even
                if (r >= -9.2e18 && r <= 9.2e18) return intValue((int64_t)r);
                return intValue(nypy::BigInt::from_double(r));
            }
            NythonExecutor::Num d = asInt(*ndv, nullptr);
            return Value(nypy::round_ndigits(n.d, d.k == 1 ? d.i : (NythonExecutor::numIsNeg(d) ? -1000 : 1000)));
        }
        // ints: round to a power of ten, ties to even
        if (!ndv) return intValue(NythonExecutor::numBig(n));
        NythonExecutor::Num d = asInt(*ndv, nullptr);
        if (d.k != 1 || d.i >= 0) return intValue(NythonExecutor::numBig(n));
        nypy::BigInt p = nypy::BigInt(10).pow((uint64_t)(-d.i)), q, r;
        nypy::BigInt::floordivmod(NythonExecutor::numBig(n), p, q, r);
        nypy::BigInt twice = r + r;
        int c = nypy::BigInt::cmp(twice, p);
        if (c > 0 || (c == 0 && !q.mag.empty() && (q.mag[0] & 1))) q = q + nypy::BigInt(1);
        return intValue(q * p);
    }
    case B_POW: {
        need(2, "pow()");
        const Value* mv = arg(2, "mod");
        if (mv && mv->type != ValueType::NONE) {
            NythonExecutor::Num b, e, m;
            if (!NythonExecutor::asNum(args[0], b) || !NythonExecutor::asNum(args[1], e) || !NythonExecutor::asNum(*mv, m))
                E.pyRaise("TypeError", "unsupported operand type(s) for pow()");
            return E.nyCall([&] { return NythonExecutor::fromNumV(nypy::pow_mod(NythonExecutor::toNumV(b), NythonExecutor::toNumV(e), NythonExecutor::toNumV(m))); });
        }
        return E.binaryOp(NythonExecutor::OP_POW, args[0], args[1], ctx);
    }
    case B_DIVMOD: {
        need(2, "divmod()");
        Value q = E.binaryOp(NythonExecutor::OP_FLOORDIV, args[0], args[1], ctx);
        Value r = E.binaryOp(NythonExecutor::OP_MOD, args[0], args[1], ctx);
        return E.makeListValue({q, r}, true);
    }
    case B_HEX: case B_OCT: case B_BIN: {
        need(1, name.c_str());
        NythonExecutor::Num n = asInt(args[0], nullptr);
        std::string spec = id == B_HEX ? "#x" : id == B_OCT ? "#o" : "#b";
        return str_(nypy::format_value(n.k == 1 ? nypy::FmtVal::of_int(n.i) : nypy::FmtVal::of_big(NythonExecutor::numBig(n)), spec));
    }
    case B_CHR: {
        need(1, "chr()");
        NythonExecutor::Num n = asInt(args[0], nullptr);
        return str_(E.nyCall([&] { return nypy::str_chr(n.k == 1 ? n.i : -1); }));
    }
    case B_ORD: {
        need(1, "ord()");
        if (!E.isStringValue(args[0])) E.pyRaise("TypeError", "ord() expected string of length 1, but " + E.typeNameOf(args[0]) + " found");
        return intValue(E.nyCall([&] { return nypy::str_ord(*(std::string*)args[0].value.p); }));
    }
    case B_HASH: {
        // Equal values hash equal (hash(1) == hash(1.0) == hash(true)), the
        // numbers and tuples of them to Python's own values; a list or dict
        // is unhashable. One implementation for both engines: nypy::hash_of_key.
        need(1, "hash()");
        const Value& v = args[0];
        if (E.isInstanceVal(v)) {
            auto cit = E.instance_to_class.find(v.value.p);
            if (cit != E.instance_to_class.end() && E.classDefines(cit->second, "__hash__")) {
                std::vector<Value> none;
                return E.callMethod(v, "__hash__", none, ctx);
            }
        }
        return intValue(nypy::hash_of_key(E.dictKey(v)));
    }
    case B_MIN: case B_MAX: {
        // min(iterable, *, key, default) / min(a, b, *rest, key)
        const Value* keyv = kwarg("key");
        const Value* defv = kwarg("default");
        if (keyv && keyv->type == ValueType::NONE) keyv = nullptr;
        std::vector<Value> items;
        if (args.size() == 1) items = E.iterItems(args[0], ctx);
        else if (args.empty()) E.pyRaise("TypeError", name + " expected at least 1 argument, got 0");
        else {
            if (defv) E.pyRaise("TypeError", "Cannot specify a default for " + name + "() with multiple positional arguments");
            items = args;
        }
        if (items.empty()) {
            if (defv) return *defv;
            E.pyRaise("ValueError", name + "() arg is an empty sequence");
        }
        size_t best = 0;
        Value bestk = keyv ? call1(*keyv, items[0]) : items[0];
        for (size_t i = 1; i < items.size(); i++) {
            Value k = keyv ? call1(*keyv, items[i]) : items[i];
            if (id == B_MIN ? less(k, bestk) : less(bestk, k)) { best = i; bestk = k; }
        }
        return items[best];
    }
    case B_SUM: {
        need(1, "sum()");
        std::vector<Value> items = E.iterItems(args[0], ctx);
        const Value* sv = arg(1, "start");
        Value acc = sv ? *sv : intValue(0);
        if (E.isStringValue(acc)) E.pyRaise("TypeError", "sum() can't sum strings [use ''.join(seq) instead]");
        for (auto& v : items) acc = E.binaryOp(NythonExecutor::OP_ADD, acc, v, ctx);
        return acc;
    }
    case B_SORTED: {
        need(1, "sorted()");
        std::vector<Value> items = E.iterItems(args[0], ctx);
        // Old calling convention: sorted(xs, keyfn) / sorted(xs, true).
        const Value* keyv = kwarg("key");
        const Value* revv = kwarg("reverse");
        for (size_t i = 1; i < args.size(); i++) {
            if (!keyv && isFunc(args[i])) keyv = &args[i];
            else if (!revv && args[i].type == ValueType::BOOLEAN) revv = &args[i];
        }
        if (keyv && keyv->type == ValueType::NONE) keyv = nullptr;
        bool rev = revv && E.isTruthy(*revv);
        std::vector<Value> keys;
        if (keyv) for (auto& v : items) keys.push_back(call1(*keyv, v));
        std::vector<size_t> order(items.size());
        for (size_t i = 0; i < order.size(); i++) order[i] = i;
        std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
            const Value& ka = keyv ? keys[a] : items[a];
            const Value& kb = keyv ? keys[b] : items[b];
            return rev ? less(kb, ka) : less(ka, kb);
        });
        std::vector<Value> out;
        out.reserve(items.size());
        for (size_t i : order) out.push_back(items[i]);
        return E.makeListValue(out);
    }
    case B_REVERSED: {
        need(1, "reversed()");
        if (E.isInstanceVal(args[0]) && E.instanceHasMethod(args[0], "__reversed__")) {
            std::vector<Value> no;
            Value r = E.callMethod(args[0], "__reversed__", no, ctx);
            if (r.type != ValueType::NONE) return r;
        }
        std::vector<Value> items = E.iterItems(args[0], ctx);
        std::reverse(items.begin(), items.end());
        return E.makeListValue(items);
    }
    case B_LIST: case B_TUPLE:
        if (args.empty()) return E.makeListValue({}, id == B_TUPLE);
        if (id == B_TUPLE) if (Container* c = E.contOf(args[0])) if (NythonExecutor::isTupleCont(c)) return args[0];
        return E.makeListValue(E.iterItems(args[0], ctx), id == B_TUPLE);
    case B_SET:
        if (args.empty()) return E.build_set_val({});
        return E.build_set_val(E.iterItems(args[0], ctx));
    case B_DICT: {
        Value d = E.makeDictValue();
        Container* dc = E.contOf(d);
        if (!args.empty()) {
            if (Container* src = E.contOf(args[0]); src && NythonExecutor::seqLen(src) < 0 && !nygen::is_gen(args[0])) {
                E.dictUpdate(dc, src);
            } else {
                for (auto& pairv : E.iterItems(args[0], ctx)) {
                    std::vector<Value> kv = E.iterItems(pairv, ctx);
                    if (kv.size() != 2) E.pyRaise("ValueError", "dictionary update sequence element has length " + std::to_string(kv.size()) + "; 2 is required");
                    E.dictSet(dc, kv[0], kv[1]);
                }
            }
        }
        // Keyword arguments in the order they were written (kw itself is
        // unordered), then any that came from a ** spread.
        std::vector<std::string> order = E.cur_kw_order_;
        for (auto& kv : kw) if (std::find(order.begin(), order.end(), kv.first) == order.end()) order.push_back(kv.first);
        for (auto& k : order) { auto it = kw.find(k); if (it != kw.end()) E.dictSet(dc, E.makeStringValue(k), it->second); }
        return d;
    }
    case B_ENUMERATE: {
        need(1, "enumerate()");
        std::vector<Value> items = E.iterItems(args[0], ctx);
        const Value* sv = arg(1, "start");
        NythonExecutor::Num st; st.k = 1; st.i = 0;
        if (sv) st = asInt(*sv, nullptr);
        std::vector<Value> out;
        out.reserve(items.size());
        Value idx = st.k == 1 ? intValue(st.i) : intValue(NythonExecutor::numBig(st));
        for (auto& v : items) {
            out.push_back(E.makeListValue({idx, v}, true));
            idx = E.binaryOp(NythonExecutor::OP_ADD, idx, intValue(1), ctx);
        }
        return E.makeListValue(out);
    }
    case B_ZIP: {
        std::vector<std::vector<Value>> cols;
        size_t n = args.empty() ? 0 : SIZE_MAX;
        for (auto& a : args) { cols.push_back(E.iterItems(a, ctx)); n = std::min(n, cols.back().size()); }
        std::vector<Value> out;
        for (size_t i = 0; i < n; i++) {
            std::vector<Value> row;
            for (auto& c : cols) row.push_back(c[i]);
            out.push_back(E.makeListValue(row, true));
        }
        return E.makeListValue(out);
    }
    case B_MAP: {
        need(2, "map()");
        std::vector<std::vector<Value>> cols;
        size_t n = SIZE_MAX;
        for (size_t a = 1; a < args.size(); a++) { cols.push_back(E.iterItems(args[a], ctx)); n = std::min(n, cols.back().size()); }
        std::vector<Value> out;
        for (size_t i = 0; i < n; i++) {
            std::vector<Value> ca;
            for (auto& c : cols) ca.push_back(c[i]);
            out.push_back(callAny(args[0], ca));
        }
        return E.makeListValue(out);
    }
    case B_FILTER: {
        need(2, "filter()");
        std::vector<Value> out;
        for (auto& v : E.iterItems(args[1], ctx)) {
            bool keep;
            if (args[0].type == ValueType::NONE) keep = E.isTruthy(v);
            else { std::vector<Value> ca = {v}; keep = E.isTruthy(callAny(args[0], ca)); }
            if (keep) out.push_back(v);
        }
        return E.makeListValue(out);
    }
    case B_ANY: case B_ALL: {
        need(1, name.c_str());
        for (auto& v : E.iterItems(args[0], ctx)) {
            bool t = E.isTruthy(v);
            if (id == B_ANY && t) return Value(true);
            if (id == B_ALL && !t) return Value(false);
        }
        return Value(id == B_ALL);
    }
    case B_RANGE: {
        need(1, "range()");
        NythonExecutor::Num a = asInt(args[0], nullptr), b, c;
        int64_t start = 0, stop, step = 1;
        if (args.size() == 1) stop = a.k == 1 ? a.i : INT64_MAX;
        else {
            b = asInt(args[1], nullptr);
            start = a.k == 1 ? a.i : 0;
            stop = b.k == 1 ? b.i : (NythonExecutor::numIsNeg(b) ? INT64_MIN : INT64_MAX);
            if (args.size() >= 3) { c = asInt(args[2], nullptr); step = c.k == 1 ? c.i : 1; }
        }
        if (step == 0) E.pyRaise("ValueError", "range() arg 3 must not be zero");
        auto* obj = new Object((Runnable*)E.runner, "list", Type::LIST);
        int64_t idx = 0;
        if (step > 0) for (int64_t i = start; i < stop; i += step) { (*obj->container)[std::to_string(idx++)] = intValue(i); if (i > INT64_MAX - step) break; }
        else for (int64_t i = start; i > stop; i += step) { (*obj->container)[std::to_string(idx++)] = intValue(i); if (i < INT64_MIN - step) break; }
        (*obj->container)["__len__"] = intValue(idx);
        return Value((Collectable*)obj);
    }
    case B_TYPE: {
        need(1, "type()");
        const Value& v = args[0];
        switch (v.type) {
            case ValueType::NONE: return str_("none");
            case ValueType::BOOLEAN: return str_("bool");
            case ValueType::INTEGER: return str_("int");
            case ValueType::DOUBLE: return str_("float");
            default: break;
        }
        if (Container* c = E.contOf(v)) {
            if (c->container->count("__set__")) return str_("set");
            if (c->container->count("__gen__")) return str_("generator");
            if (c->container->count("__tuple__")) return str_("tuple");
            if (c->container->count("__len__")) return str_("list");
            auto type_it = c->container->find("__type__");
            if (type_it != c->container->end()) return str_(E.getStringValue(type_it->second));
            return str_("map");
        }
        if (v.isCollectable()) return str_("object");
        if (v.type == ValueType::USERDATA && v.value.p) {
            if (E.string_ptrs_.count(v.value.p)) return str_("string");
            auto fit = E.func_names.find(v.value.p);
            if (fit != E.func_names.end()) {
                if (fit->second.find("__func__:") == 0 || fit->second.find("__lambda__") == 0) return str_("function");
                if (fit->second.find("__builtin__:") == 0) return str_("builtin");
                if (fit->second.find("__class__:") == 0) return str_("class");
                if (fit->second.find("__instance__:") == 0) return str_(fit->second.substr(13));
            }
            return str_("string");
        }
        return str_("unknown");
    }
    default: break;
    }
    return UNDEFINED_VALUE;
}
