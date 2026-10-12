// builtins/nypickle.cpp (round 80) - lib/pickle.ny's fast path for plain
// data, natively:
//
//   _ny_pickle_dumps(obj, protocol) -> bytes, or None when obj holds
//       anything but None, bool, int, float, str, bytes, bytearray
//       (protocol 5), tuple, list, dict, set, frozenset - then the Nython
//       Pickler runs. The bytes are what that Pickler (and CPython's
//       _pickle.c) writes: PROTO, one FRAME, the memo (MEMOIZE; strings and
//       bytes by value, containers by identity), batches of 1000, STOP.
//       Protocols 4 and 5 only, and pickles under 64 KB (the Pickler does
//       CPython's frame splitting beyond that).
//   _ny_pickle_loads(data) -> (True, obj), or (False, None) when the pickle
//       uses an opcode outside that plain-data subset (GLOBAL, REDUCE,
//       BUILD, the text opcodes of protocol 0 ...) - then the Unpickler runs.
//
// Pickling every message of lib/multiprocessing in Nython cost about 1 ms a
// call; this makes plain messages 50-100 times cheaper. Registered through
// the hashing bridge (hash_builtin_names), as zlib's natives are; the VM's
// bridge gives _ny_pickle_dumps an undefined value for anything with no
// interpreter form (a function, a class), so it is not mistaken for None.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyBytes.hpp"
#include "builtins/os.hpp"
#include <string>
#include <vector>
#include <unordered_map>
#include <cstring>

using namespace nython;
using namespace nython::kernel;

namespace {

struct NoFast {};   // thrown to give up: the Nython Pickler / Unpickler runs

const size_t kFrameTarget = 64 * 1024;

struct FastPickler {
    NythonExecutor& E;
    int proto;
    std::string out;
    size_t memo_n = 0;
    std::unordered_map<const void*, size_t> memo_obj;
    std::unordered_map<std::string, size_t> memo_str, memo_bytes;
    std::unordered_map<const void*, bool> in_tuple;
    int depth = 0;

    FastPickler(NythonExecutor& e, int p) : E(e), proto(p), out(), memo_obj(), memo_str(), memo_bytes(), in_tuple() {}

    void check_size() { if (out.size() >= kFrameTarget - 16) throw NoFast(); }
    void u32(uint32_t v) { for (int k = 0; k < 4; k++) out += (char)((v >> (8 * k)) & 0xFF); }
    void u64(uint64_t v) { for (int k = 0; k < 8; k++) out += (char)((v >> (8 * k)) & 0xFF); }
    void memoize() { out += '\x94'; memo_n++; }
    void get(size_t idx) {
        if (idx < 256) { out += 'h'; out += (char)idx; }
        else { out += 'j'; u32((uint32_t)idx); }
    }

    void save_int(const Value& v) {
        int64_t i;
        if (bigint_fits_i64(v.value.i, i) && i >= -2147483648LL && i <= 2147483647LL) {
            uint32_t u = (uint32_t)(int32_t)i;
            unsigned char b1 = (unsigned char)(u & 0xFF), b2 = (unsigned char)((u >> 8) & 0xFF),
                          b3 = (unsigned char)((u >> 16) & 0xFF), b4 = (unsigned char)((u >> 24) & 0xFF);
            if (b4 || b3) { out += 'J'; u32(u); }
            else if (b2) { out += 'M'; out += (char)b1; out += (char)b2; }
            else { out += 'K'; out += (char)b1; }
            return;
        }
        nypy::BigInt b = bigint_to_nbig(v.value.i);
        // CPython's save_long: (bit length >> 3) + 1 bytes, two's complement,
        // one byte less when a negative number's top byte is redundant
        nypy::BigInt a = b; a.neg = false;
        size_t nbits = 0;
        for (size_t w = a.mag.size(); w-- > 0;) {
            if (a.mag[w]) { uint32_t x = a.mag[w]; size_t k = 0; while (x) { k++; x >>= 1; } nbits = w * 32 + k; break; }
        }
        size_t nbytes = (nbits >> 3) + 1;
        std::string data = nypy::int_to_bytes(b, (int64_t)nbytes, true, true);
        if (b.neg && nbytes > 1 && (unsigned char)data[nbytes - 1] == 0xFF && ((unsigned char)data[nbytes - 2] & 0x80)) {
            data.pop_back();
            nbytes--;
        }
        if (nbytes < 256) { out += '\x8a'; out += (char)nbytes; }
        else { out += '\x8b'; u32((uint32_t)nbytes); }
        out += data;
    }

    void save_float(double d) {
        uint64_t u;
        std::memcpy(&u, &d, 8);
        out += 'G';
        for (int k = 7; k >= 0; k--) out += (char)((u >> (8 * k)) & 0xFF);
    }

    void save(const Value& v) {
        if (++depth > 400) throw NoFast();
        check_size();
        switch (v.type) {
            case ValueType::NONE: out += 'N'; depth--; return;
            case ValueType::BOOLEAN: out += v.value.b ? '\x88' : '\x89'; depth--; return;
            case ValueType::INTEGER: save_int(v); depth--; return;
            case ValueType::DOUBLE: save_float((double)v.value.d); depth--; return;
            case ValueType::UNDEFINED: throw NoFast();
            default: break;
        }
        if (E.isStringValue(v)) {
            const std::string& s = *(std::string*)v.value.p;
            auto it = memo_str.find(s);
            if (it != memo_str.end()) { get(it->second); depth--; return; }
            if (s.size() < 256) { out += '\x8c'; out += (char)s.size(); }
            else { out += 'X'; u32((uint32_t)s.size()); }
            out += s;
            memo_str[s] = memo_n;
            memoize();
            depth--;
            return;
        }
        if (auto* bo = E.bytesOf(v)) {
            if (bo->mut) {
                if (proto < 5) throw NoFast();
                auto it = memo_obj.find(bo);
                if (it != memo_obj.end()) { get(it->second); depth--; return; }
                out += '\x96';
                u64(bo->s.size());
                out += bo->s;
                memo_obj[bo] = memo_n;
                memoize();
                depth--;
                return;
            }
            auto it = memo_bytes.find(bo->s);
            if (it != memo_bytes.end()) { get(it->second); depth--; return; }
            if (bo->s.size() < 256) { out += 'C'; out += (char)bo->s.size(); }
            else { out += 'B'; u32((uint32_t)bo->s.size()); }
            out += bo->s;
            memo_bytes[bo->s] = memo_n;
            memoize();
            depth--;
            return;
        }
        if (E.isInstanceVal(v)) throw NoFast();
        Container* c = E.contOf(v);
        if (!c) throw NoFast();
        auto& m = *c->container;
        if (m.count("__class__") || m.count("__kwargs__") || NythonExecutor::isGenCont(c)) throw NoFast();
        const void* key = c;
        auto mit = memo_obj.find(key);
        if (mit != memo_obj.end()) { get(mit->second); depth--; return; }
        int64_t n = NythonExecutor::seqLen(c);
        if (n < 0) {
            // a dict
            std::vector<std::pair<Value, Value>> items;
            for (auto& kv : m) {
                if (E.isInternalKey(kv.first)) continue;
                items.push_back({E.keyValue(kv.first), kv.second});
            }
            out += '}';
            memo_obj[key] = memo_n;
            memoize();
            if (items.size() == 1) {
                save(items[0].first); save(items[0].second); out += 's';
            } else if (!items.empty()) {
                // _pickle.c's batch_dict_exact: a full batch is followed by
                // another MARK ... SETITEMS, an empty one when the size is a
                // multiple of 1000 (lists stop at the last item)
                size_t i = 0, b;
                do {
                    out += '(';
                    b = 0;
                    for (; i < items.size() && b < 1000; i++, b++) { save(items[i].first); save(items[i].second); }
                    out += 'u';
                } while (b == 1000);
            }
            depth--;
            return;
        }
        std::vector<Value> items = NythonExecutor::seqItems(c);
        if (NythonExecutor::isSetCont(c)) {
            bool frozen = m.count("__set__") && bigint_to_i64(m["__set__"].value.i) == 2;
            if (frozen) {
                if (in_tuple.count(key)) throw NoFast();
                in_tuple[key] = true;
                out += '(';
                for (auto& e : items) save(e);
                in_tuple.erase(key);
                if (memo_obj.count(key)) throw NoFast();
                out += '\x91';
                memo_obj[key] = memo_n;
                memoize();
            } else {
                out += '\x8f';
                memo_obj[key] = memo_n;
                memoize();
                if (!items.empty()) {
                    size_t i = 0;
                    size_t batch;
                    do {
                        out += '(';
                        batch = 0;
                        for (; i < items.size() && batch < 1000; i++, batch++) save(items[i]);
                        out += '\x90';
                    } while (batch == 1000);
                }
            }
            depth--;
            return;
        }
        if (NythonExecutor::isTupleCont(c)) {
            if (items.empty()) { out += ')'; depth--; return; }
            if (in_tuple.count(key)) throw NoFast();
            in_tuple[key] = true;
            if (items.size() <= 3) {
                for (auto& e : items) save(e);
                in_tuple.erase(key);
                if (memo_obj.count(key)) throw NoFast();
                out += (char)(0x84 + items.size());
            } else {
                out += '(';
                for (auto& e : items) save(e);
                in_tuple.erase(key);
                if (memo_obj.count(key)) throw NoFast();
                out += 't';
            }
            memo_obj[key] = memo_n;
            memoize();
            depth--;
            return;
        }
        // a list
        out += ']';
        memo_obj[key] = memo_n;
        memoize();
        if (items.size() == 1) {
            save(items[0]);
            out += 'a';
        } else if (!items.empty()) {
            size_t i = 0;
            while (i < items.size()) {
                out += '(';
                size_t b = 0;
                for (; i < items.size() && b < 1000; i++, b++) save(items[i]);
                out += 'e';
            }
        }
        depth--;
    }

    std::string dump(const Value& v) {
        save(v);
        out += '.';
        check_size();
        std::string head = "\x80";
        head += (char)proto;
        if (out.size() >= 4) {
            head += '\x95';
            for (int k = 0; k < 8; k++) head += (char)(((uint64_t)out.size() >> (8 * k)) & 0xFF);
        }
        return head + out;
    }
};

struct FastUnpickler {
    NythonExecutor& E;
    const std::string& s;
    size_t pos = 0;
    std::vector<Value> stack;
    std::vector<size_t> marks;
    std::vector<Value> memo;
    FastUnpickler(NythonExecutor& e, const std::string& data) : E(e), s(data), stack(), marks(), memo() {}

    const char* need(size_t n) {
        if (n > s.size() - pos) throw NoFast();
        const char* p = s.data() + pos;
        pos += n;
        return p;
    }
    uint64_t le(size_t n) {
        const unsigned char* p = (const unsigned char*)need(n);
        uint64_t v = 0;
        for (size_t k = 0; k < n; k++) v |= (uint64_t)p[k] << (8 * k);
        return v;
    }
    Value pop() {
        if (stack.empty()) throw NoFast();
        Value v = stack.back();
        stack.pop_back();
        return v;
    }
    std::vector<Value> pop_mark() {
        if (marks.empty()) throw NoFast();
        size_t m = marks.back();
        marks.pop_back();
        if (m > stack.size()) throw NoFast();
        std::vector<Value> items(stack.begin() + (long)m, stack.end());
        stack.resize(m);
        return items;
    }
    Container* top_cont() {
        if (stack.empty()) throw NoFast();
        Container* c = E.contOf(stack.back());
        if (!c) throw NoFast();
        return c;
    }
    void list_append(Container* c, const Value& v) {
        int64_t n = NythonExecutor::seqLen(c);
        if (n < 0 || NythonExecutor::isTupleCont(c) || NythonExecutor::isSetCont(c)) throw NoFast();
        (*c->container)[std::to_string(n)] = v;
        (*c->container)["__len__"] = intValue(n + 1);
    }
    void dict_set(Container* c, const Value& k, const Value& v) {
        if (NythonExecutor::seqLen(c) >= 0) throw NoFast();
        E.dictSet(c, k, v);
    }
    Value str_of(size_t n) {
        std::string t(need(n), n);
        // generalized UTF-8 only (else the Unpickler's error)
        for (size_t i = 0; i < t.size();) {
            unsigned char ch = (unsigned char)t[i];
            size_t len = ch < 0x80 ? 1 : (ch >> 5) == 6 ? 2 : (ch >> 4) == 14 ? 3 : (ch >> 3) == 30 ? 4 : 0;
            if (!len || i + len > t.size()) throw NoFast();
            for (size_t k = 1; k < len; k++) if (((unsigned char)t[i + k] & 0xC0) != 0x80) throw NoFast();
            i += len;
        }
        return E.makeStringValue(t);
    }

    Value load() {
        while (true) {
            unsigned char op = (unsigned char)*need(1);
            switch (op) {
                case 0x80: need(1); break;                       // PROTO
                case 0x95: le(8); break;                         // FRAME
                case '.': if (stack.size() != 1 || !marks.empty()) throw NoFast(); return stack.back();
                case '(': marks.push_back(stack.size()); break;
                case 'N': stack.push_back(NONE_VALUE); break;
                case 0x88: stack.push_back(Value(true)); break;
                case 0x89: stack.push_back(Value(false)); break;
                case 'K': stack.push_back(intValue((int64_t)le(1))); break;
                case 'M': stack.push_back(intValue((int64_t)le(2))); break;
                case 'J': stack.push_back(intValue((int64_t)(int32_t)(uint32_t)le(4))); break;
                case 0x8a: case 0x8b: {
                    size_t n = op == 0x8a ? (size_t)le(1) : (size_t)le(4);
                    std::string d(need(n), n);
                    if (n == 0) stack.push_back(intValue((int64_t)0));
                    else stack.push_back(intValue(nypy::int_from_bytes(d, true, true)));
                    break;
                }
                case 'G': {
                    const unsigned char* p = (const unsigned char*)need(8);
                    uint64_t u = 0;
                    for (int k = 0; k < 8; k++) u = (u << 8) | p[k];
                    double d;
                    std::memcpy(&d, &u, 8);
                    stack.push_back(Value(d));
                    break;
                }
                case 'X': stack.push_back(str_of((size_t)le(4))); break;
                case 0x8c: stack.push_back(str_of((size_t)le(1))); break;
                case 0x8d: stack.push_back(str_of((size_t)le(8))); break;
                case 'C': { size_t n = (size_t)le(1); stack.push_back(E.makeBytesValue(std::string(need(n), n))); break; }
                case 'B': { size_t n = (size_t)le(4); stack.push_back(E.makeBytesValue(std::string(need(n), n))); break; }
                case 0x8e: { size_t n = (size_t)le(8); stack.push_back(E.makeBytesValue(std::string(need(n), n))); break; }
                case 0x96: { size_t n = (size_t)le(8); stack.push_back(E.makeBytesValue(std::string(need(n), n), true)); break; }
                case ')': stack.push_back(E.makeListValue({}, true)); break;
                case 't': stack.push_back(E.makeListValue(pop_mark(), true)); break;
                case 0x85: case 0x86: case 0x87: {
                    size_t n = op - 0x84;
                    if (stack.size() < n) throw NoFast();
                    std::vector<Value> items(stack.end() - (long)n, stack.end());
                    stack.resize(stack.size() - n);
                    stack.push_back(E.makeListValue(items, true));
                    break;
                }
                case ']': stack.push_back(E.makeListValue({}, false)); break;
                case 'l': stack.push_back(E.makeListValue(pop_mark(), false)); break;
                case 'a': { Value v = pop(); list_append(top_cont(), v); break; }
                case 'e': { auto items = pop_mark(); Container* c = top_cont(); for (auto& v : items) list_append(c, v); break; }
                case '}': stack.push_back(E.makeDictValue()); break;
                case 'd': {
                    auto items = pop_mark();
                    if (items.size() % 2) throw NoFast();
                    Value d = E.makeDictValue();
                    Container* c = E.contOf(d);
                    for (size_t i = 0; i < items.size(); i += 2) dict_set(c, items[i], items[i + 1]);
                    stack.push_back(d);
                    break;
                }
                case 's': { Value v = pop(); Value k = pop(); dict_set(top_cont(), k, v); break; }
                case 'u': {
                    auto items = pop_mark();
                    if (items.size() % 2) throw NoFast();
                    Container* c = top_cont();
                    for (size_t i = 0; i < items.size(); i += 2) dict_set(c, items[i], items[i + 1]);
                    break;
                }
                case 0x8f: stack.push_back(E.build_set_val({}, false)); break;
                case 0x90: {
                    auto items = pop_mark();
                    Container* c = top_cont();
                    if (!NythonExecutor::isSetCont(c)) throw NoFast();
                    for (auto& v : items) E.setAdd(c, v);
                    break;
                }
                case 0x91: stack.push_back(E.build_set_val(pop_mark(), true)); break;
                case 0x94: if (stack.empty()) throw NoFast(); memo.push_back(stack.back()); break;
                case 'q': case 'r': {
                    size_t i = op == 'q' ? (size_t)le(1) : (size_t)le(4);
                    if (stack.empty()) throw NoFast();
                    if (memo.size() <= i) memo.resize(i + 1, UNDEFINED_VALUE);
                    memo[i] = stack.back();
                    break;
                }
                case 'h': case 'j': {
                    size_t i = op == 'h' ? (size_t)le(1) : (size_t)le(4);
                    if (i >= memo.size() || memo[i].type == ValueType::UNDEFINED) throw NoFast();
                    stack.push_back(memo[i]);
                    break;
                }
                case '0': pop(); break;
                case '1': pop_mark(); break;
                case '2': if (stack.empty()) throw NoFast(); stack.push_back(stack.back()); break;
                default: throw NoFast();
            }
        }
    }
};

}  // namespace

std::vector<std::string> pickle_builtin_names() { return {"_ny_pickle_dumps", "_ny_pickle_loads"}; }

Value dispatch_pickle(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name == "_ny_pickle_dumps") {
        if (args.empty()) return NONE_VALUE;
        int proto = args.size() > 1 ? (int)nyos::to_int(args[1], 4) : 4;
        if (proto != 4 && proto != 5) return NONE_VALUE;
        try {
            FastPickler p(E, proto);
            return E.makeBytesValue(p.dump(args[0]));
        } catch (NoFast&) {
            return NONE_VALUE;
        }
    }
    if (name == "_ny_pickle_loads") {
        auto tuple = [&](bool ok, const Value& v) { return E.makeListValue({Value(ok), v}, true); };
        auto* bo = args.empty() ? nullptr : E.bytesOf(args[0]);
        if (!bo) return tuple(false, NONE_VALUE);
        std::string data = bo->s;
        try {
            FastUnpickler u(E, data);
            Value v = u.load();
            return tuple(true, v);
        } catch (NoFast&) {
            return tuple(false, NONE_VALUE);
        } catch (nypy::PyError&) {
            return tuple(false, NONE_VALUE);
        } catch (std::string&) {
            return tuple(false, NONE_VALUE);
        }
    }
    return UNDEFINED_VALUE;
}
