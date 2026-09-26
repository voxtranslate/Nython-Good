// ─────────────────────────────────────────────────────────────────────────────
// VMConc.cpp — the VM side of the concurrency runtime (src/NyConc.cpp).
//
// Threads on the VM: every OS thread runs the same VirtualMachine object; the
// GIL guarantees only one of them executes bytecode at a time. What a thread
// owns — its operand stack, its frame stack, the exception in flight, the
// import flag — is swapped in when it acquires the GIL and swapped out when it
// releases it (std::swap of the containers: O(1), and element addresses are
// preserved, so references held by suspended C++ frames of that thread stay
// valid). Globals, classes and code objects are shared, as in Python.
//
// Every concurrency builtin is a VM native here (not a bridge call: the bridge
// converts functions to none and copies containers, which is exactly what
// thread targets and handles cannot survive).
// ─────────────────────────────────────────────────────────────────────────────
#include "VirtualMachine.hpp"
#include "NyConc.hpp"

namespace nython::vm {

namespace {

struct VMBox : nyconc::Box { VMVal v; explicit VMBox(VMVal x) : v(std::move(x)) {} };

VMVal unbox(const nyconc::BoxPtr& b) {
    auto* vb = dynamic_cast<VMBox*>(b.get());
    return vb ? vb->v : VMVal::make_none();
}
nyconc::BoxPtr box(const VMVal& v) { return std::make_shared<VMBox>(v); }

struct VMThreadState {
    std::vector<VMVal> stack;
    std::deque<CallFrame> calls;
    VMVal last_exc;
    bool export_globals = false;
};

VMVal ret_to_vm(const nyconc::Ret& r) {
    switch (r.k) {
        case nyconc::Ret::NONE: return VMVal::make_none();
        case nyconc::Ret::BOOL: return VMVal::make_bool(r.b);
        case nyconc::Ret::INT:  return VMVal::make_int(r.i);
        case nyconc::Ret::NUM:  return VMVal::make_float(r.d);
        case nyconc::Ret::STR:  return VMVal::make_str(r.s);
        case nyconc::Ret::BOX:  return unbox(r.box);
        case nyconc::Ret::LIST: {
            std::vector<VMVal> out;
            for (auto& x : r.list) out.push_back(ret_to_vm(x));
            return VMVal::make_list(std::move(out));
        }
    }
    return VMVal::make_none();
}

VMVal exception_instance(const std::string& type, const std::string& msg) {
    auto attrs = std::make_shared<std::unordered_map<std::string, VMVal>>();
    (*attrs)["msg"] = VMVal::make_str(msg);
    (*attrs)["args"] = VMVal::make_list({VMVal::make_str(msg)});
    return VMVal::make_instance(type, attrs);
}

// "ValueError: bad value" -> ("ValueError", "bad value") when the prefix looks
// like an exception class name.
bool split_exception_text(const std::string& raw, std::string& type, std::string& msg) {
    auto c = raw.find(": ");
    if (c == std::string::npos || c == 0) return false;
    std::string t = raw.substr(0, c);
    for (char ch : t) if (!(isalnum((unsigned char)ch) || ch == '_')) return false;
    auto ends = [&](const char* suf) { std::string x(suf); return t.size() >= x.size() && t.compare(t.size() - x.size(), x.size(), x) == 0; };
    if (!(ends("Error") || ends("Exception") || ends("Exit") || ends("Interrupt") || ends("Iteration") || ends("Warning")))
        return false;
    type = t; msg = raw.substr(c + 2);
    return true;
}

struct VMArgs : nyconc::Args {
    std::vector<VMVal> v;
    explicit VMArgs(std::vector<VMVal> xs) : v(std::move(xs)) {}
    size_t size() const override { return v.size(); }
    bool is_none(size_t i) const override { return v[i].type == VMType::NONE; }
    bool is_number(size_t i) const override { return v[i].type == VMType::INT || v[i].type == VMType::FLOAT; }
    bool is_string(size_t i) const override { return v[i].type == VMType::STRING; }
    bool is_list(size_t i) const override { return v[i].type == VMType::LIST && v[i].list; }
    int64_t as_int(size_t i) const override {
        if (v[i].type == VMType::INT) return v[i].i;
        if (v[i].type == VMType::FLOAT) return (int64_t)v[i].d;
        if (v[i].type == VMType::BOOL) return v[i].b ? 1 : 0;
        return 0;
    }
    double as_num(size_t i) const override {
        if (v[i].type == VMType::FLOAT) return v[i].d;
        return (double)as_int(i);
    }
    std::string as_str(size_t i) const override { return v[i].type == VMType::STRING ? v[i].s : v[i].to_string(); }
    bool truthy(size_t i) const override { return v[i].is_truthy(); }
    nyconc::BoxPtr box(size_t i) const override { return std::make_shared<VMBox>(v[i]); }
    std::unique_ptr<nyconc::Args> list(size_t i) const override {
        std::vector<VMVal> out;
        if (is_list(i)) out = *v[i].list;
        return std::make_unique<VMArgs>(std::move(out));
    }
};

} // namespace

struct VMConcEngine : nyconc::Engine {
    VirtualMachine& vm;
    explicit VMConcEngine(VirtualMachine& m) : vm(m) {}

    nyconc::BoxPtr call(const nyconc::BoxPtr& fn, const std::vector<nyconc::BoxPtr>& args) override {
        VMVal f = unbox(fn);
        std::vector<VMVal> av;
        for (auto& a : args) av.push_back(unbox(a));
        try { return box(vm.vm_call(f, av, std::nullopt)); }
        catch (nyconc::NyError&) { throw; }
        catch (std::runtime_error& x) {
            nyconc::NyError e; e.raw = x.what();
            if (vm.last_exception_obj_.type == VMType::INSTANCE) e.obj = box(vm.last_exception_obj_);
            else {
                // The VM clears its exception object once the exception leaves
                // the frame that raised it; rebuild one from "Type: message" so
                // a typed `except Type` still matches where it is re-raised.
                std::string t, m;
                if (split_exception_text(e.raw, t, m)) e.obj = box(exception_instance(t, m));
            }
            vm.last_exception_obj_ = VMVal::make_none();
            throw e;
        }
        catch (std::string& s) { nyconc::NyError e; e.raw = s; throw e; }
        catch (std::exception& x) { nyconc::NyError e; e.raw = x.what(); throw e; }
    }
    nyconc::BoxPtr box_int(int64_t v) override { return box(VMVal::make_int(v)); }
    nyconc::BoxPtr box_none() override { return box(VMVal::make_none()); }
    bool unbox_int(const nyconc::BoxPtr& b, int64_t& out) override {
        VMVal v = unbox(b);
        if (v.type != VMType::INT) return false;
        out = v.i;
        return true;
    }
    nyconc::BoxPtr from_ret(const nyconc::Ret& r) override { return box(ret_to_vm(r)); }
    bool is_callable(const nyconc::BoxPtr& b) override {
        VMVal v = unbox(b);
        switch (v.type) {
            case VMType::FUNCTION: case VMType::NATIVE: case VMType::CLASS: case VMType::INSTANCE: return true;
            case VMType::MAP: return v.class_name == "__bound_method__" || v.class_name == "__super_bound__";
            default: return false;
        }
    }
    std::string describe(const nyconc::BoxPtr& b) override {
        VMVal v = unbox(b);
        if (v.type == VMType::FUNCTION && v.code) return v.code->name;
        return v.to_string();
    }
    void on_thread_start() override {
        // First thread: from now on other threads reach module variables
        // through the main thread's bottom frame (VirtualMachine::load_var).
        if (!vm.module_frame_ && !vm.call_stack_.empty()) vm.module_frame_ = &vm.call_stack_.front();
    }
    void* state_new() override { return new VMThreadState(); }
    void state_free(void* p) override { delete static_cast<VMThreadState*>(p); }
    void swap_in(void* p) override { swap(static_cast<VMThreadState*>(p)); }
    void swap_out(void* p) override { swap(static_cast<VMThreadState*>(p)); }
    void swap(VMThreadState* st) {
        if (!st) return;
        std::swap(vm.stack_, st->stack);
        std::swap(vm.call_stack_, st->calls);
        std::swap(vm.last_exception_obj_, st->last_exc);
        std::swap(vm.export_to_globals_, st->export_globals);
    }

    // A runtime error raised into VM code: an exception instance (so typed
    // `except DeadlockError` matches) plus the runtime_error the VM catches.
    [[noreturn]] void raise_in_vm(const nyconc::NyError& err) {
        if (err.obj) {
            vm.last_exception_obj_ = unbox(err.obj);
            throw std::runtime_error(err.raw);
        }
        if (!err.raw.empty()) {
            std::string raw = err.raw;
            // Interpreter-style tagged text: present it the VM's way.
            if (raw.rfind("__exc__:", 0) == 0) {
                std::string rest = raw.substr(8);
                auto c = rest.find(':');
                if (c != std::string::npos) {
                    std::string type = rest.substr(0, c), msg = rest.substr(c + 1);
                    vm.last_exception_obj_ = exception_instance(type, msg);
                    throw std::runtime_error(type + ": " + msg);
                }
            }
            throw std::runtime_error(raw);
        }
        vm.last_exception_obj_ = exception_instance(err.type, err.msg);
        throw std::runtime_error(err.type + ": " + err.msg);
    }
};

void VMConc::install(VirtualMachine& vm) {
    // One engine per VM, never freed: threads may outlive the call that created
    // them (daemon threads at exit).
    auto* eng = new VMConcEngine(vm);
    for (const auto& name : nyconc::builtin_names()) {
        std::string nm = name;
        vm.globals_[nm] = VMVal::make_native([eng, nm](std::vector<VMVal>& a) -> VMVal {
            VMArgs args(a);
            nyconc::Ret r;
            try { nyconc::dispatch(*eng, nm, args, r); }
            catch (nyconc::NyError& err) { eng->raise_in_vm(err); }
            return ret_to_vm(r);
        });
    }
    for (const auto& en : nyconc::exception_names()) {
        std::string cname = en;
        vm.globals_[cname] = VMVal::make_native([cname](std::vector<VMVal>& a) -> VMVal {
            std::string msg = a.empty() ? cname : a[0].to_string();
            return exception_instance(cname, msg);
        });
    }
}

} // namespace nython::vm
