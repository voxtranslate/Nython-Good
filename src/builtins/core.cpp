#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/core.cpp
// Core builtins, type ops, functional
// ─────────────────────────────────────────────────────────────────────────────
// HOW THIS FILE WORKS:
//   dispatch_core() is called from NythonExecutor::callBuiltin().
//   It has full access to the executor via the `E` reference (same as `*this`
//   in the original monolithic main.cpp).  Every helper that was previously
//   a member call (getStringValue, makeStringValue, callBuiltin, etc.) is
//   accessed through `E.` — keeping code changes minimal.
// ─────────────────────────────────────────────────────────────────────────────

// Platform compatibility (must come first)
#include "platform_compat.hpp"
#include "NyUniNames.hpp"

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
#include "builtins/core.hpp"
#include <utility>
// ^ explicit: libstdc++ supplies these transitively, MinGW does not.

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
// dispatch_core
// ════════════════════════════════════════════════════════════════════════════════
Value dispatch_core(NythonExecutor& E,
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
    // ── from main.cpp lines 3382–3589 ──────────────────────────────────────────
        // =====================================================================
        if (name == "tensor2d_get") {
            // tensor2d_get(t, row, col, width) -> value
            if (args.size() >= 4) {
                int row = (int)bigint_to_i64(args[1].value.i);
                int col = (int)bigint_to_i64(args[2].value.i);
                int w   = (int)bigint_to_i64(args[3].value.i);
                auto* t = dynamic_cast<Container*>(args[0].value.gc);
                if (t && t->container) {
                    auto it = t->container->find(std::to_string(row*w+col));
                    if (it != t->container->end()) return Value(it->second.value.d);
                }
            }
            return Value(0.0);
        }
        if (name == "tensor2d_set") {
            // tensor2d_set(t, row, col, width, val) -> tensor
            if (args.size() >= 5) {
                int row = (int)bigint_to_i64(args[1].value.i);
                int col = (int)bigint_to_i64(args[2].value.i);
                int w   = (int)bigint_to_i64(args[3].value.i);
                double v = args[4].type==ValueType::DOUBLE ? args[4].value.d : (double)bigint_to_i64(args[4].value.i);
                auto* t = dynamic_cast<Container*>(args[0].value.gc);
                if (t && t->container) (*t->container)[std::to_string(row*w+col)] = Value(v);
                return args[0];
            }
            return NONE_VALUE;
        }
        if (name == "tensor2d_conv") {
            // tensor2d_conv(image_flat, H, W, kernel_flat, kH, kW) -> output flat tensor
            if (args.size() >= 6) {
                auto* img = dynamic_cast<Container*>(args[0].value.gc);
                int H = (int)bigint_to_i64(args[1].value.i);
                int W = (int)bigint_to_i64(args[2].value.i);
                auto* ker = dynamic_cast<Container*>(args[3].value.gc);
                int kH = (int)bigint_to_i64(args[4].value.i);
                int kW = (int)bigint_to_i64(args[5].value.i);
                if (!img || !ker || !img->container || !ker->container) return NONE_VALUE;
                int pH = kH/2, pW = kW/2;
                int oH = H, oW = W;
                auto* out = new Container((Runnable*)runner, Type::LIST);
                (*out->container)["__len__"] = Value(oH*oW);
                for (int r = 0; r < oH; r++) {
                    for (int c = 0; c < oW; c++) {
                        double acc = 0;
                        for (int kr = 0; kr < kH; kr++) {
                            for (int kc = 0; kc < kW; kc++) {
                                int ir = r+kr-pH, ic = c+kc-pW;
                                if (ir>=0 && ir<H && ic>=0 && ic<W) {
                                    auto ii = img->container->find(std::to_string(ir*W+ic));
                                    auto ki = ker->container->find(std::to_string(kr*kW+kc));
                                    double iv = (ii!=img->container->end()) ? ii->second.value.d : 0.0;
                                    double kv = (ki!=ker->container->end()) ? ki->second.value.d : 0.0;
                                    acc += iv*kv;
                                }
                            }
                        }
                        (*out->container)[std::to_string(r*oW+c)] = Value(acc);
                    }
                }
                return Value((Collectable*)out);
            }
            return NONE_VALUE;
        }
        if (name == "tensor2d_maxpool") {
            // tensor2d_maxpool(img, H, W, kH, kW, stride) -> {tensor, outH, outW}
            if (args.size() >= 6) {
                auto* img = dynamic_cast<Container*>(args[0].value.gc);
                int H=(int)bigint_to_i64(args[1].value.i), W=(int)bigint_to_i64(args[2].value.i);
                int kH=(int)bigint_to_i64(args[3].value.i), kW=(int)bigint_to_i64(args[4].value.i);
                int stride=(int)bigint_to_i64(args[5].value.i);
                if (!img || !img->container) return NONE_VALUE;
                int oH=(H-kH)/stride+1, oW=(W-kW)/stride+1;
                auto* out = new Container((Runnable*)runner, Type::LIST);
                (*out->container)["__len__"] = Value(oH*oW);
                for (int r=0;r<oH;r++) for (int c=0;c<oW;c++) {
                    double mx=-1e308;
                    for (int kr=0;kr<kH;kr++) for (int kc=0;kc<kW;kc++) {
                        int ir=r*stride+kr, ic=c*stride+kc;
                        if (ir<H&&ic<W) {
                            auto it=img->container->find(std::to_string(ir*W+ic));
                            double v=(it!=img->container->end())?it->second.value.d:0.0;
                            if(v>mx) mx=v;
                        }
                    }
                    (*out->container)[std::to_string(r*oW+c)]=Value(mx);
                }
                auto* res = new Object((Runnable*)runner, "map", Type::MAP);
                res->set("tensor", Value((Collectable*)out));
                res->set("outH", Value(oH)); res->set("outW", Value(oW));
                return Value((Collectable*)res);
            }
            return NONE_VALUE;
        }
        if (name == "tensor_sort") {
            // tensor_sort(t, ascending=true) -> sorted tensor
            if (!args.empty() && args[0].isCollectable()) {
                auto* t = dynamic_cast<Container*>(args[0].value.gc);
                bool asc = (args.size()<2) || isTruthy(args[1]);
                if (!t || !t->container) return NONE_VALUE;
                auto li = t->container->find("__len__");
                int n=(li!=t->container->end())?(int)bigint_to_i64(li->second.value.i):0;
                std::vector<double> v; v.reserve((size_t)n);
                for (int i=0;i<n;i++) { auto it=t->container->find(std::to_string(i)); v.push_back(it!=t->container->end()?it->second.value.d:0.0); }
                if (asc) std::sort(v.begin(),v.end()); else std::sort(v.begin(),v.end(),[](double a,double b){return a>b;});
                auto* out=new Container((Runnable*)runner,Type::LIST);
                (*out->container)["__len__"]=Value(n);
                for (int i=0;i<n;i++) (*out->container)[std::to_string(i)]=Value(v[(size_t)i]);
                return Value((Collectable*)out);
            }
            return NONE_VALUE;
        }
        if (name == "tensor_topk") {
            // tensor_topk(t, k) -> list of {value, index}
            if (args.size()>=2 && args[0].isCollectable()) {
                auto* t=dynamic_cast<Container*>(args[0].value.gc);
                int k=(int)bigint_to_i64(args[1].value.i);
                if (!t||!t->container) return NONE_VALUE;
                auto li=t->container->find("__len__");
                int n=(li!=t->container->end())?(int)bigint_to_i64(li->second.value.i):0;
                std::vector<std::pair<double,int>> v;
                for (int i=0;i<n;i++) { auto it=t->container->find(std::to_string(i)); v.push_back({it!=t->container->end()?it->second.value.d:0.0, i}); }
                std::sort(v.begin(),v.end(),[](auto&a,auto&b){return a.first>b.first;});
                if (k>n) k=n;
                auto* out=new Container((Runnable*)runner,Type::LIST);
                (*out->container)["__len__"]=Value(k);
                for (int i=0;i<k;i++) {
                    auto* item=new Object((Runnable*)runner,"map",Type::MAP);
                    item->set("value",Value(v[(size_t)i].first));
                    item->set("index",Value(v[(size_t)i].second));
                    (*out->container)[std::to_string(i)]=Value((Collectable*)item);
                }
                return Value((Collectable*)out);
            }
            return NONE_VALUE;
        }
        if (name == "tensor_eye") {
            // tensor_eye(n) -> identity matrix as flat n*n tensor
            if (!args.empty()) {
                int n=(int)bigint_to_i64(args[0].value.i);
                auto* t=new Container((Runnable*)runner,Type::LIST);
                (*t->container)["__len__"]=Value(n*n);
                for (int r=0;r<n;r++) for (int c=0;c<n;c++) (*t->container)[std::to_string(r*n+c)]=Value(r==c?1.0:0.0);
                return Value((Collectable*)t);
            }
            return NONE_VALUE;
        }
        if (name == "tensor_diag") {
            // tensor_diag(t) -> diagonal elements as new tensor
            if (!args.empty() && args[0].isCollectable()) {
                auto* t=dynamic_cast<Container*>(args[0].value.gc);
                if (!t||!t->container) return NONE_VALUE;
                auto li=t->container->find("__len__"); int n=(int)std::sqrt((double)bigint_to_i64(li->second.value.i));
                auto* out=new Container((Runnable*)runner,Type::LIST);
                (*out->container)["__len__"]=Value(n);
                for (int i=0;i<n;i++) { auto it=t->container->find(std::to_string(i*n+i)); (*out->container)[std::to_string(i)]=Value(it!=t->container->end()?it->second.value.d:0.0); }
                return Value((Collectable*)out);
            }
            return NONE_VALUE;
        }
        if (name == "tensor_flatten") {
            // tensor_flatten(t) -> same tensor (already flat, just updates __len__ from data)
            if (!args.empty() && args[0].isCollectable()) return args[0];
            return NONE_VALUE;
        }
        if (name == "tensor_pad") {
            // tensor_pad(t, pad_left, pad_right, val=0.0) -> padded tensor
            if (args.size()>=3 && args[0].isCollectable()) {
                auto* t=dynamic_cast<Container*>(args[0].value.gc);
                int pl=(int)bigint_to_i64(args[1].value.i), pr=(int)bigint_to_i64(args[2].value.i);
                double pv=(args.size()>=4)?(args[3].type==ValueType::DOUBLE?args[3].value.d:(double)bigint_to_i64(args[3].value.i)):0.0;
                if (!t||!t->container) return NONE_VALUE;
                auto li=t->container->find("__len__"); int n=(li!=t->container->end())?(int)bigint_to_i64(li->second.value.i):0;
                int nn=n+pl+pr;
                auto* out=new Container((Runnable*)runner,Type::LIST);
                (*out->container)["__len__"]=Value(nn);
                for (int i=0;i<pl;i++) (*out->container)[std::to_string(i)]=Value(pv);
                for (int i=0;i<n;i++) { auto it=t->container->find(std::to_string(i)); (*out->container)[std::to_string(i+pl)]=Value(it!=t->container->end()?it->second.value.d:0.0); }
                for (int i=0;i<pr;i++) (*out->container)[std::to_string(n+pl+i)]=Value(pv);
                return Value((Collectable*)out);
            }
            return NONE_VALUE;
        }
        if (name == "tensor_dot_product") {
            // tensor_dot_product(a, b) -> scalar (alias for tensor_dot)
            if (args.size()>=2) {
                std::vector<Value> dargs={args[0],args[1]};
                return callBuiltin("tensor_dot", dargs, ctx);
            }
            return Value(0.0);
        }
        if (name == "tensor_cosine_sim") {
            // tensor_cosine_sim(a, b) -> scalar
            if (args.size()>=2) {
                std::vector<Value> sa={args[0]}, sb={args[1]};
                Value na=callBuiltin("tensor_norm", sa, ctx);
                Value nb=callBuiltin("tensor_norm", sb, ctx);
                std::vector<Value> dv2={args[0],args[1]};
                Value dot=callBuiltin("tensor_dot", dv2, ctx);
                double dv=dot.type==ValueType::DOUBLE?dot.value.d:(double)bigint_to_i64(dot.value.i);
                double nva=na.type==ValueType::DOUBLE?na.value.d:(double)bigint_to_i64(na.value.i);
                double nvb=nb.type==ValueType::DOUBLE?nb.value.d:(double)bigint_to_i64(nb.value.i);
                double denom=nva*nvb; if(denom<1e-12) denom=1e-12;
                return Value(dv/denom);
            }
            return Value(0.0);
        }
        // =====================================================================
    // ── from main.cpp lines 4561–4723 ──────────────────────────────────────────
        // ===================== MAP / FILTER / REDUCE =====================
        if (name == "reduce") {
            // reduce(fn, list[, initial])
            // any other iterable - a lazy map/filter/zip, a range, a dict
            // view, a generator - is read first (round 78: map() and filter()
            // are lazy now, and reduce(f, map(...)) gave none)
            if (args.size() >= 2 && args[0].type == ValueType::USERDATA) {
                Container* lc = E.contOf(args[1]);
                bool seq = lc && NythonExecutor::seqLen(lc) >= 0 && !nygen::is_gen(args[1]);
                if (!seq && (lc || E.isInstanceValue(args[1]) || E.isStringValue(args[1])))
                    args[1] = E.makeListValue(E.iterItems(args[1], ctx));
            }
            if (args.size() >= 2 && args[0].type == ValueType::USERDATA && args[1].isCollectable()) {
                auto* cont = dynamic_cast<Container*>(args[1].value.gc);
                if (cont && cont->container) {
                    auto len_it = cont->container->find("__len__");
                    int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                    Value acc;
                    int start = 0;
                    if (args.size() >= 3) {
                        acc = args[2];
                    } else if (len > 0) {
                        acc = cont->container->at("0");
                        start = 1;
                    } else {
                        return NONE_VALUE;
                    }
                    for (int i = start; i < len; i++) {
                        auto it = cont->container->find(std::to_string(i));
                        if (it != cont->container->end()) {
                            std::vector<Value> ca = {acc, it->second};
                            acc = callFunctionValue(args[0], ca, ctx);
                        }
                    }
                    return acc;
                }
            }
            return NONE_VALUE;
        }



    // ── from main.cpp lines 9328–9641 (final core/math/io builtins) ─────────
        if (name == "hasattr") {
            if (args.size() >= 2) {
                std::string attr = getStringValue(args[1]);
                // Check Collectable containers
                if (args[0].isCollectable()) {
                    auto* cont = dynamic_cast<Container*>(args[0].value.gc);
                    if (cont && cont->container) {
                        return Value(cont->container->find(attr) != cont->container->end());
                    }
                }
                // Check USERDATA instance properties
                if (args[0].type == ValueType::USERDATA && args[0].value.p && !E.string_ptrs_.count(args[0].value.p)) {
                    auto pctx_it = instance_properties.find(args[0].value.p);
                    if (pctx_it != instance_properties.end() && pctx_it->second) {
                        try { Value v = pctx_it->second->getByName(attr); if (v.type != ValueType::UNDEFINED) return Value(true); } catch(...) {}
                    }
                    // Also check class methods
                    auto cit2 = instance_to_class.find(args[0].value.p);
                    if (cit2 != instance_to_class.end()) {
                        void* class_ptr = cit2->second;
                        void* ast_ptr2 = class_ptr;
                        auto ast_it2 = func_ast_nodes.find(class_ptr);
                        if (ast_it2 != func_ast_nodes.end()) ast_ptr2 = ast_it2->second;
                        Node* cn2 = (Node*)ast_ptr2;
                        if (cn2 && cn2->type() == NodeType::CLASS) {
                            auto* cnode = static_cast<ClassNode*>(cn2);
                            if (cnode->body) {
                                for (auto& stmt : cnode->body->statements()) {
                                    if (stmt->type() == NodeType::FUNCTION) {
                                        auto* fn = static_cast<FunctionNode*>(stmt.get());
                                        if (fn->name == attr) return Value(true);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return Value(false);
        }
        if (name == "getattr") {
            if (args.size() >= 2) {
                std::string attr = getStringValue(args[1]);
                if (args[0].isCollectable()) {
                    auto* cont = dynamic_cast<Container*>(args[0].value.gc);
                    if (cont && cont->container) {
                        auto it = cont->container->find(attr);
                        if (it != cont->container->end()) return it->second;
                    }
                }
                if (args[0].type == ValueType::USERDATA && !E.string_ptrs_.count(args[0].value.p) && instance_properties.count(args[0].value.p)) {
                    auto* pctx = instance_properties[args[0].value.p];
                    if (pctx) {
                        try {
                            Value v = pctx->getByName(attr);
                            if (v.type != ValueType::UNDEFINED) return v;
                        } catch(...) {}
                    }
                }
                if (args.size() >= 3) return args[2]; // default
            }
            return NONE_VALUE;
        }
        if (name == "setattr") {
            if (args.size() >= 3) {
                std::string attr = getStringValue(args[1]);
                if (args[0].type == ValueType::USERDATA && !E.string_ptrs_.count(args[0].value.p) && instance_properties.count(args[0].value.p)) {
                    auto* pctx = instance_properties[args[0].value.p];
                    if (pctx) pctx->defineByName(attr, args[2]);
                } else if (args[0].isCollectable()) {
                    auto* cont = dynamic_cast<Container*>(args[0].value.gc);
                    if (cont && cont->container) (*cont->container)[attr] = args[2];
                }
                return NONE_VALUE;
            }
            return NONE_VALUE;
        }

        if ((name == "keys" || name == "values" || name == "items") && args.size() >= 1) {
            // A dict: its typed keys in insertion order, as d.keys() etc.
            if (Container* dc = E.contOf(args[0]); dc && NythonExecutor::seqLen(dc) < 0) {
                std::vector<Value> none;
                static const nyrt::OrderedKw<Value> nokw;
                Value r;
                if (E.dictMethod(dc, args[0], name, none, nokw, ctx, r)) {
                    // Nython's keys(d) / values(d) / items(d) stay lists:
                    // d.keys() is a live view since round 78
                    std::vector<Value> items;
                    if (E.rangeOrViewItems(r, items)) return E.makeListValue(items);
                    return r;
                }
            }
        }
        if (name == "keys") {
            if (args.size() >= 1) {
                Container* cont = nullptr;
                if (args[0].isCollectable()) cont = dynamic_cast<Container*>(args[0].value.gc);
                // Only a non-string USERDATA can be a Collectable. A string's value.p
                // points into the executor's string store, so casting it to
                // Collectable* and dynamic_cast-ing read a bogus vtable and
                // segfaulted: items("abc"), keys("abc") and values("abc") all
                // crashed the process.
                if (!cont && args[0].type == ValueType::USERDATA && !isStringValue(args[0]))
                {
                    // An instance's fields (value.p is its identity, not a
                    // Collectable: casting it read a bogus vtable).
                    auto pit = instance_properties.find(args[0].value.p);
                    if (pit != instance_properties.end()) cont = pit->second;
                }
                if (cont && cont->container) {
                    auto* list = new Object(static_cast<Runnable*>(runner), "list", Type::LIST);
                    int idx = 0;
                    for (auto& [k, v] : *cont->container) {
                        if (!k.empty() && k[0] != '_' && (k[0] < '0' || k[0] > '9'))
                            (*list->container)[std::to_string(idx++)] = makeStringValue(k);
                    }
                    (*list->container)["__len__"] = Value(idx);
                    return Value(static_cast<Collectable*>(list));
                }
            }
            return NONE_VALUE;
        }
        if (name == "values") {
            if (args.size() >= 1) {
                Container* cont = nullptr;
                if (args[0].isCollectable()) cont = dynamic_cast<Container*>(args[0].value.gc);
                // Only a non-string USERDATA can be a Collectable. A string's value.p
                // points into the executor's string store, so casting it to
                // Collectable* and dynamic_cast-ing read a bogus vtable and
                // segfaulted: items("abc"), keys("abc") and values("abc") all
                // crashed the process.
                if (!cont && args[0].type == ValueType::USERDATA && !isStringValue(args[0]))
                {
                    // An instance's fields (value.p is its identity, not a
                    // Collectable: casting it read a bogus vtable).
                    auto pit = instance_properties.find(args[0].value.p);
                    if (pit != instance_properties.end()) cont = pit->second;
                }
                if (cont && cont->container) {
                    auto* list = new Object(static_cast<Runnable*>(runner), "list", Type::LIST);
                    int idx = 0;
                    for (auto& [k, v] : *cont->container) {
                        if (!k.empty() && k[0] != '_' && (k[0] < '0' || k[0] > '9'))
                            (*list->container)[std::to_string(idx++)] = v;
                    }
                    (*list->container)["__len__"] = Value(idx);
                    return Value(static_cast<Collectable*>(list));
                }
            }
            return NONE_VALUE;
        }
        if (name == "items") {
            if (args.size() >= 1) {
                Container* cont = nullptr;
                if (args[0].isCollectable()) cont = dynamic_cast<Container*>(args[0].value.gc);
                // Only a non-string USERDATA can be a Collectable. A string's value.p
                // points into the executor's string store, so casting it to
                // Collectable* and dynamic_cast-ing read a bogus vtable and
                // segfaulted: items("abc"), keys("abc") and values("abc") all
                // crashed the process.
                if (!cont && args[0].type == ValueType::USERDATA && !isStringValue(args[0]))
                {
                    // An instance's fields (value.p is its identity, not a
                    // Collectable: casting it read a bogus vtable).
                    auto pit = instance_properties.find(args[0].value.p);
                    if (pit != instance_properties.end()) cont = pit->second;
                }
                if (cont && cont->container) {
                    auto* list = new Object(static_cast<Runnable*>(runner), "list", Type::LIST);
                    int idx = 0;
                    for (auto& [k, v] : *cont->container) {
                        if (!k.empty() && k[0] != '_' && (k[0] < '0' || k[0] > '9')) {
                            auto* pair = new Object(static_cast<Runnable*>(runner), "list", Type::LIST);
                            (*pair->container)["0"] = makeStringValue(k);
                            (*pair->container)["1"] = v;
                            (*pair->container)["__len__"] = Value(2);
                            (*list->container)[std::to_string(idx++)] = Value(static_cast<Collectable*>(pair));
                        }
                    }
                    (*list->container)["__len__"] = Value(idx);
                    return Value(static_cast<Collectable*>(list));
                }
            }
            return NONE_VALUE;
        }
        if (name == "next") {
            if (!args.empty() && args[0].isCollectable() && args[0].value.gc) {
                auto* cont = dynamic_cast<Container*>(args[0].value.gc);
                if (cont && cont->container && cont->container->count("__gen__")) {
                    auto idx_it = cont->container->find("__idx__");
                    auto len_it = cont->container->find("__len__");
                    int idx = (idx_it != cont->container->end()) ? (int)bigint_to_i64(idx_it->second.value.i) : 0;
                    int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                    if (idx < len) {
                        auto val_it = cont->container->find(std::to_string(idx));
                        (*cont->container)["__idx__"] = Value(idx + 1);
                        return val_it != cont->container->end() ? val_it->second : NONE_VALUE;
                    }
                    // Exhausted - raise StopIteration
                    throw std::string("__exc__:StopIteration:generator exhausted");
                }
            }
            return NONE_VALUE;
        }
        // object.__new__(cls): an instance of cls without running __init__
        // (round 77).
        if (name == "_ny_object_new") {
            Node* cn = args.empty() ? nullptr : E.classNodeOfValue(args[0]);
            if (!cn) E.pyRaise("TypeError", "object.__new__(X): X is not a type object");
            std::string cname = static_cast<nython::node::ClassNode*>(cn)->name;
            Value inst = E.newInstance(cname, args[0].value.p);
            if (E.isExceptionClass(cname)) { std::vector<Value> none; E.setExceptionArgs(inst, none); }
            return inst;
        }
        // _ny_method_new(f, obj): f bound to obj (classmethod.__get__,
        // types.MethodType) - round 77
        if (name == "_ny_method_new") {
            if (args.size() != 2) E.pyRaise("TypeError", "method expected 2 arguments, got " + std::to_string(args.size()));
            return E.methodNew(args[0], args[1], ctx);
        }
        // classes deriving from builtin types (round 77): an instance's
        // value (anything else is its own), and T.__new__(cls, ...)
        if (name == "_ny_payload") {
            if (args.empty()) return NONE_VALUE;
            Value p;
            if (E.payloadOf(args[0], p)) return p;
            if (E.isInstanceValue(args[0])) E.checkHasPayload(args[0]);
            return args[0];
        }
        if (name == "_ny_payload_new" && args.size() >= 3) return E.newPayloadInstance(args[0], args[1], args[2]);
        // obj.__dict__[k] = v / del obj.__dict__[k] (the view's): a field
        // stored or removed directly (round 77)
        if (name == "_ny_setfield" && args.size() >= 3) { E.setField(args[0], args[1], args[2]); return NONE_VALUE; }
        if (name == "_ny_delfield" && args.size() >= 2) { E.delField(args[0], args[1]); return NONE_VALUE; }
        // __slots__ and __class__ assignment (round 79; the prelude's "slots"
        // chunk): a slot's value, a class's slot flags, an instance's class
        if (name == "_ny_getfield" && args.size() >= 2) return E.getField(args[0], args[1]);
        if (name == "_ny_mark_slots" && args.size() >= 2) {
            E.markSlots(args[0], args[1].type == ValueType::INTEGER ? (int)bigint_to_i64(args[1].value.i) : 0);
            return NONE_VALUE;
        }
        if (name == "_ny_slot_flags") return Value((int)(args.empty() ? 0 : E.slotFlags(args[0])));
        if (name == "_ny_switch_class" && args.size() >= 2) { E.switchClass(args[0], args[1]); return NONE_VALUE; }
        // object.__getattribute__(obj, name): the attribute lookup without
        // the class's __getattribute__ and __getattr__ (round 77)
        if (name == "_ny_getattr_raw" && args.size() >= 2) return E.rawGetattr(args[0], E.getStringValue(args[1]), ctx);
        if (name == "_ny_subclasses") return E.subclassesOf(args.empty() ? NONE_VALUE : args[0]);
        // a function's parameters, flags and place (inspect; round 77)
        if (name == "_ny_fn_info") return E.fnInfo(args.empty() ? NONE_VALUE : args[0]);
        if (name == "_ny_mark_builtin") return E.markBuiltinFn(args.empty() ? NONE_VALUE : args[0]);   // round 84
        if (name == "_ny_vm_code") return E.vmCodeInfo(args);   // round 83: lib/dis.ny
        if (name == "_ny_fn_globals") return E.fnGlobals(args.empty() ? NONE_VALUE : args[0]);
        // the lexer's keyword spellings (lib/keyword.ny's nykwlist; the VM
        // reaches this through the builtin bridge)
        if (name == "_ny_keywords") {
            std::vector<Value> ks;
            for (auto& k : nython::lexer::keyword_spellings()) ks.push_back(E.makeStringValue(k));
            return E.makeListValue(ks);
        }
        // Unicode character names (lib/unicodedata.ny, src/NyUniNames.cpp;
        // round 77): the character of a name or none, the name of a
        // character or "" - through the bridge on the VM
        if (name == "_ny_unicode_lookup") {
            uint32_t cp = 0;
            if (args.empty() || !E.isStringValue(args[0]) || !::nyuni::lookup(E.getStringValue(args[0]), cp)) return NONE_VALUE;
            std::string out;
            nypy::u8_encode(cp, out);
            return E.makeStringValue(out);
        }
        if (name == "_ny_unicode_name") {
            if (args.empty() || !E.isStringValue(args[0])) return E.makeStringValue("");
            std::string s = E.getStringValue(args[0]);
            size_t i = 0;
            if (s.empty()) return E.makeStringValue("");
            uint32_t cp = nypy::u8_decode(s, i);
            return E.makeStringValue(::nyuni::name(cp));
        }
        // type.__new__ / type.__call__ read from the builtin (round 83): the
        // prelude's _ny_type_m_new / _ny_type_m_call pass the positional
        // arguments, then the keywords as a dict
        if (name == "_ny_type_new" || name == "_ny_type_call") {
            nyrt::OrderedKw<Value> kw;
            std::vector<Value> a = args;
            if (!a.empty()) {
                if (Container* c = E.contOf(a.back()))
                    for (auto& kv : *c->container)
                        if (!NythonExecutor::isInternalKey(kv.first)) kw[nypy::key_payload(kv.first)] = kv.second;
                a.pop_back();
            }
            if (name == "_ny_type_new") return E.typeNew(a, kw, ctx);
            if (a.empty()) E.pyRaise("TypeError", "descriptor '__call__' of 'type' object needs an argument");
            Value cls = a[0];
            std::vector<Value> rest(a.begin() + 1, a.end());
            E.type_call_skip_ = true;
            return E.instantiateClass(cls, rest, kw, ctx);
        }
        if (name == "_ny_setattr_raw" && args.size() >= 3) {
            NythonExecutor::RawAttr raw;
            E.setAttr(args[0], E.getStringValue(args[1]), args[2]);
            return NONE_VALUE;
        }
        if (name == "_ny_delattr_raw" && args.size() >= 2) {
            NythonExecutor::RawAttr raw;
            E.delAttrValue(args[0], E.getStringValue(args[1]));
            return NONE_VALUE;
        }
        if (name == "eval" || name == "exec") return E.evalExecBuiltin(name == "exec", args, ctx);
        if (name == "compile") return E.compileBuiltin(args, ctx);
        // round 81: globals() is the module's live namespace (a view), and
        // so is locals() at a module's top level, as in CPython
        if (name == "locals") {
            if (!ctx || ctx == E.global_ctx || ctx->inModule || !ctx->parent) return E.globalsView(ctx);
            return E.reflectLocals(ctx);
        }
        if (name == "globals") return E.globalsView(ctx);
        // the program's globals stored and deleted by name: globals()'s
        // view and sys.modules["__main__"] (round 81)
        if (name == "_ny_main_set") {
            if (args.size() < 2 || !E.isStringValue(args[0])) E.pyRaise("TypeError", "_ny_main_set(name, value)");
            E.global_ctx->defineByName(E.getStringValue(args[0]), args[1]);
            return NONE_VALUE;
        }
        if (name == "_ny_main_del") {
            if (args.empty() || !E.isStringValue(args[0])) E.pyRaise("TypeError", "_ny_main_del(name)");
            return Value(E.global_ctx->container && E.global_ctx->container->erase(E.getStringValue(args[0])) > 0);
        }
        if (name == "_ny_globals_view") {
            // the program's globals() view (from anywhere)
            return E.globalsView(nullptr);
        }
        if (name == "_ny_frame_jump") return E.frameJump(args);   // frame.f_lineno = n (round 81)
        // The buffer protocol (round 84; the prelude's memoryview): a bytes /
        // bytearray value's storage as [address, length, readonly, owner] -
        // the owner the object a view keeps alive (the value itself here) -
        // counting an export of a bytearray (its size is then fixed:
        // BufferError); None for anything else. _ny_buf_unexport gives an
        // export back, _ny_buf_exports counts them; _ny_buf_addr is a
        // bytearray's storage address now (no export: valid until it is
        // resized - lib/array.ny reads and writes its items there).
        if (name == "_ny_buf_export" || name == "_ny_buf_unexport" || name == "_ny_buf_exports" || name == "_ny_buf_addr") {
            Value v = args.empty() ? NONE_VALUE : E.unwrapPayload(args[0]);
            nyheap::Bytes* bo = E.bytesOf(v);
            if (name == "_ny_buf_addr") return bo && bo->mut ? intValue((int64_t)(intptr_t)bo->s.data()) : NONE_VALUE;
            if (!bo) return name == "_ny_buf_export" ? NONE_VALUE : intValue(0);
            if (name == "_ny_buf_exports") return intValue(bo->exports);
            if (name == "_ny_buf_unexport") { if (bo->exports > 0) bo->exports--; return intValue(bo->exports); }
            if (bo->mut) bo->exports++;
            return E.makeListValue({intValue((int64_t)(intptr_t)bo->s.data()), intValue((int64_t)bo->s.size()), Value(!bo->mut), v});
        }
        if (name == "_ny_gc_objects") {
            // (round 85) gc.get_objects(generation): the collector's tracked
            // objects a program can see - containers (lists, dicts, sets,
            // tuples, modules, generators), instances, functions, bound
            // methods; not the engine's scopes or its builtins' members
            int gen = -1;
            if (!args.empty() && args[0].type == ValueType::INTEGER) gen = (int)bigint_to_i64(args[0].value.i);
            struct Acc { std::vector<Value> out; };
            Acc acc;
            nygc::each_tracked(gen, [](Collectable* c, void* p) {
                auto* a = static_cast<Acc*>(p);
                uint16_t f = c->gc_flags;
                if (f & nygc::F_KINST) { auto* in = static_cast<nyheap::Inst*>(c); a->out.push_back(nyheap::userValue(in, (void*)&in->tag)); return; }
                if (f & nygc::F_KFUNC) { auto* fn = static_cast<nyheap::Func*>(c); a->out.push_back(nyheap::userValue(fn, (void*)&fn->id)); return; }
                if (auto* b = dynamic_cast<nyheap::Bound*>(c)) { a->out.push_back(nyheap::userValue(b, (void*)&b->tag)); return; }
                if ((f & nygc::F_KCONT) && !dynamic_cast<Context*>(c)) a->out.push_back(Value(c));
            }, &acc);
            return E.makeListValue(acc.out);
        }
        if (name == "_ny_load_chunk") {
            // (round 84) a prelude chunk loaded on first need - "buffer":
            // memoryview's members and the buffer helpers (NyPreludeBuffer.cpp)
            if (!args.empty() && E.isStringValue(args[0])) E.ensureMirror(E.getStringValue(args[0]));
            return NONE_VALUE;
        }
        if (name == "_ny_getrefcount") {
            // sys.getrefcount(x) (round 81): the object's count (exact
            // reference counting, NyGC) without the references this call
            // holds itself, plus one for the argument - as CPython counts;
            // what is not a counted object (int, float, bool, None) is
            // immortal there: 2**32 - 1, as 3.12 reports it
            if (args.size() != 1) E.pyRaise("TypeError", "sys.getrefcount() takes exactly one argument (" + std::to_string(args.size()) + " given)");
            Collectable* o = args[0].value.o;
            if (!o) return Value(bigint((long long)4294967295LL));
            static const long long kCallRefs = getenv("NY_RC_RAW") ? 0 : 1;   // the argument vector's copy
            long long rc = (long long)o->gc_rc - kCallRefs + 1;
            return Value(bigint(rc < 1 ? 1LL : rc));
        }
        // The __main__ module's globals, from anywhere (a library module's
        // globals() is its own): unittest.main() finds the program's
        // TestCase classes here, as Python's reads sys.modules["__main__"].
        if (name == "_ny_main_globals") return E.reflectGlobals(nullptr);
        // sys.modules and importlib (round 80; the VM has its own)
        if (name == "_ny_modules") return E.sysModulesValue();
        if (name == "_ny_module_new") return E.moduleNew(args.empty() ? std::string() : E.getStringValue(args[0]));
        if (name == "_ny_module_exec") {
            if (args.size() < 3) E.pyRaise("TypeError", "_ny_module_exec(module, path, name)");
            return E.moduleExec(args[0], E.getStringValue(args[1]), E.getStringValue(args[2]));
        }
        if (name == "_ny_find_module") return E.findModule(args.empty() ? std::string() : E.getStringValue(args[0]));
        // sys's facts (round 80): plain values both engines read (the VM
        // through the builtin bridge)
        if (name == "_ny_sys_info") {
            std::string k = args.empty() ? std::string() : E.getStringValue(args[0]);
            if (k == "flags") {
                auto& f = nyrt::cli_flags();
                std::vector<Value> v;
                for (int x : {f.debug, f.inspect, f.interactive, f.optimize, f.dont_write_bytecode, f.no_user_site,
                              f.no_site, f.ignore_environment, f.verbose, f.bytes_warning, f.quiet,
                              f.hash_randomization, f.isolated, f.dev_mode, f.utf8_mode, f.warn_default_encoding,
                              f.safe_path, f.int_max_str_digits})
                    v.push_back(Value(x));
                return E.makeListValue(v);
            }
            if (k == "path") {
                // CPython's sys.path: the script's directory ("" for -c and
                // the prompt), NYTHONPATH, the standard library
                std::vector<std::string> p;
                const std::string& sp = nyrt::script_path();
                size_t cut = sp.find_last_of("/\\");
                p.push_back(cut == std::string::npos ? std::string() : sp.substr(0, cut));
                for (auto d : nyrt::library_dirs()) {
                    while (d.size() > 1 && (d.back() == '/' || d.back() == '\\')) d.pop_back();
                    p.push_back(d);
                }
                return E.nyos_list_of(p);
            }
            if (k == "orig_argv") return E.nyos_list_of(nyrt::orig_argv());
            if (k == "switch_interval") {
                // sys.getswitchinterval / setswitchinterval: the GIL's
                // hand-over interval (NyConc.cpp)
                if (args.size() > 1) {
                    double s = args[1].type == ValueType::DOUBLE ? args[1].value.d
                             : args[1].type == ValueType::INTEGER ? (double)bigint_to_i64(args[1].value.i) : 0.0;
                    nyconc::set_switch_interval(s);
                    return NONE_VALUE;
                }
                return Value(nyconc::switch_interval());
            }
            // (round 85) sys.get/set_int_max_str_digits (checked by the
            // prelude), sys.getallocatedblocks, sys.thread_info's version
            if (k == "int_max_str_digits") {
                if (args.size() > 1) {
                    nyrt::int_max_str_digits() = (int)std::min<int64_t>(bigint_to_i64(args[1].value.i), INT32_MAX);
                    return NONE_VALUE;
                }
                return Value((int)nyrt::int_max_str_digits());
            }
            if (k == "allocated_blocks") {
                auto st = nygc::stats();
                return intValue((int64_t)(st.tracked + st.live_strings));
            }
            if (k == "libc_version") {
#if defined(__GLIBC__)
                return E.makeStringValue(std::string("NPTL ") + std::to_string(__GLIBC__) + "." + std::to_string(__GLIBC_MINOR__));
#else
                return NONE_VALUE;
#endif
            }
            if (k == "prefix") {
                // the directory holding the standard library's lib/
                auto dirs = nyrt::library_dirs();
                std::string d = dirs.empty() ? std::string() : dirs.back();
                while (d.size() > 1 && (d.back() == '/' || d.back() == '\\')) d.pop_back();
                size_t cut = d.find_last_of("/\\");
                return E.makeStringValue(cut == std::string::npos ? std::string() : d.substr(0, cut));
            }
            return NONE_VALUE;
        }
        if (name == "_ny_recursion_limit") {
            // sys.getrecursionlimit() / setrecursionlimit(n): one limit both
            // engines check (NyRuntime.hpp)
            if (args.empty() || args[0].type == ValueType::NONE) return Value((int)nyrt::recursion_limit());
            if (args[0].type != ValueType::INTEGER) E.pyRaise("TypeError", "'" + E.typeNameOf(args[0]) + "' object cannot be interpreted as an integer");
            int64_t n = bigint_to_i64(args[0].value.i);
            if (n < 1) E.pyRaise("ValueError", "recursion limit must be greater or equal than 1");
            nyrt::recursion_limit() = n > 1000000 ? 1000000 : (int)n;
            return NONE_VALUE;
        }
        // The exception an except clause is handling now, here or in a
        // caller (sys.exc_info()[1]); none outside every except clause.
        if (name == "_ny_exc_current") {
            if (E.handling_exc_.empty() || E.handling_obj_.empty()) return NONE_VALUE;
            const Value& held = E.handling_obj_.back().second;
            if (held.type != ValueType::NONE) return held;
            return E.exceptionObject(E.handling_exc_.back());
        }
        // round 84: BaseException's own __init__/__str__/__repr__ as values
        // (the prelude's _NyExcExtra): the instance's args and fields set
        // from (args, kwargs) as a constructor sets them, and the text the
        // engine makes for str()/repr() whatever a subclass overrides.
        if (name == "_ny_exc_init") {
            if (args.size() < 1 || !E.isInstanceValue(args[0])) return NONE_VALUE;
            std::vector<Value> items = args.size() > 1 ? E.listItems(args[1]) : std::vector<Value>{};
            E.setExceptionArgs(args[0], items);
            if (args.size() > 2) {
                nyrt::OrderedKw<Value> kw;
                if (Container* kc = E.contOf(args[2]))
                    for (auto& kv : *kc->container) if (!E.isInternalKey(kv.first)) kw[nypy::key_payload(kv.first)] = kv.second;
                E.setExceptionKw(args[0], kw);
            }
            return NONE_VALUE;
        }
        if (name == "_ny_audit_enable") { nyrt::audit_on() = true; return NONE_VALUE; }   // round 84
        if (name == "_ny_exc_str") {
            if (args.empty() || !E.isInstanceValue(args[0])) return E.makeStringValue("");
            return E.makeStringValue(E.exceptionMessage(args[0]));
        }
        if (name == "_ny_exc_repr") {
            if (args.empty() || !E.isInstanceValue(args[0])) return E.makeStringValue("");
            return E.makeStringValue(E.exceptionRepr(args[0], ctx));
        }
        // The running frames, innermost first: (filename, lineno, function,
        // module) - sys._getframe, traceback.extract_stack, warnings (round 77).
        if (name == "_ny_stack") return E.pyStackValue();
        // Frame objects (round 78; NythonExecutor::frameObject)
        if (name == "_ny_frame_get") return E.frameGet(args);
        if (name == "_ny_frame_sync") return args.empty() ? Value(false) : E.frameSync(args[0]);
        if (name == "_ny_frame_back") return args.empty() ? NONE_VALUE : E.frameBack(args[0]);
        if (name == "_ny_frame_globals") return E.frameGlobals(args);
        if (name == "_ny_builtins_dict") return E.builtinsDict();
        // sys.settrace / sys.setprofile and f_locals write-through (round 79)
        if (name == "_ny_settrace" || name == "sys.settrace") {
            if (nyrt::audit_on() && !E.preludeCaller(ctx)) E.auditEvent("sys.settrace", {}, ctx);   // round 86
            return E.pySetHook(args, true);
        }
        if (name == "_ny_setprofile" || name == "sys.setprofile") {
            if (nyrt::audit_on() && !E.preludeCaller(ctx)) E.auditEvent("sys.setprofile", {}, ctx);   // round 86
            return E.pySetHook(args, false);
        }
        if (name == "_ny_gettrace" || name == "sys.gettrace") return E.pyGetHook(true);
        if (name == "_ny_getprofile" || name == "sys.getprofile") return E.pyGetHook(false);
        if (name == "_ny_frame_local_set") return E.frameLocalSet(args);
        if (name == "vars") return E.reflectVars(args, ctx);
        if (name == "dir") return E.reflectDir(args, ctx);
        if (name == "issubclass" || name == "property" || name == "staticmethod" || name == "classmethod" || name == "iter" || name == "help" || name == "slice" || name == "complex") {
            return NONE_VALUE; // placeholder
        }
        // id(x) / hash(x) — registered as recognised builtin names (see
        // NythonExecutor::registerBuiltins) but never actually dispatched
        // here, so a bare id(x)/hash(x) call fell through every dispatch_*
        // module and returned UNDEFINED, which reads as 0. The method form
        // obj.id()/obj.hash() (objectProtocol) already worked; this gives
        // the global function the same behaviour instead of nothing.
        // (round 86) builtins.id with the identity, as CPython's id() - not
        // for the engine's own (a repr's address: _ny_id) nor the prelude's
        if (name == "id" && nyrt::audit_on() && !E.preludeCaller(ctx)) {
            Value r = dispatch_core(E, "_ny_id", args, ctx);
            E.auditEvent("builtins.id", {r}, ctx);
            return r;
        }
        if (name == "id" || name == "_ny_id") {
            if (args.empty()) return Value(bigint((long long)0));
            Value& v = args[0];
            // Heap-allocated values (class instances, containers): identity
            // is the underlying pointer, masked to fit a signed bigint the
            // same way objectProtocol's "id" method does.
            if (v.type == ValueType::USERDATA && v.value.p) {
                unsigned long long raw = (unsigned long long)(size_t)v.value.p;
                return Value(bigint((long long)(raw & 0x7fffffffULL)));
            }
            if (v.isCollectable() && v.value.gc) {
                unsigned long long raw = (unsigned long long)(size_t)v.value.gc;
                return Value(bigint((long long)(raw & 0x7fffffffULL)));
            }
            // Primitives have no heap identity; derive a stable value so
            // id(x) is non-zero, repeatable for the same x, and type-aware
            // (id(1) != id(1.0) even though 1 == 1.0).
            unsigned long long h = std::hash<std::string>{}(getStringValue(v) + "|" + std::to_string((int)v.type));
            return Value(bigint((long long)(h & 0x7fffffffULL)));
        }
        if (name == "hash") {
            if (args.empty()) return Value(bigint((long long)0));
            unsigned long long h = std::hash<std::string>{}(getStringValue(args[0]));
            return Value(bigint((long long)(h & 0x7fffffffULL)));
        }
        if (name == "sqrt") {
            if (args.size() >= 1) {
                double v = (args[0].type == ValueType::DOUBLE) ? static_cast<double>(args[0].value.d) : (double)bigint_to_i64(args[0].value.i);
                return Value(static_cast<double>(std::sqrt(v)));
            }
            return Value(0.0);
        }
        if (name == "sin") {
            if (args.size() >= 1) {
                double v = (args[0].type == ValueType::DOUBLE) ? static_cast<double>(args[0].value.d) : (double)bigint_to_i64(args[0].value.i);
                return Value(std::sin(v));
            }
            return Value(0.0);
        }
        if (name == "cos") {
            if (args.size() >= 1) {
                double v = (args[0].type == ValueType::DOUBLE) ? static_cast<double>(args[0].value.d) : (double)bigint_to_i64(args[0].value.i);
                return Value(std::cos(v));
            }
            return Value(0.0);
        }
        if (name == "tan") {
            if (args.size() >= 1) {
                double v = (args[0].type == ValueType::DOUBLE) ? static_cast<double>(args[0].value.d) : (double)bigint_to_i64(args[0].value.i);
                return Value(std::tan(v));
            }
            return Value(0.0);
        }
        if (name == "exp") {
            if (args.size() >= 1) {
                double v = (args[0].type == ValueType::DOUBLE) ? static_cast<double>(args[0].value.d) : (double)bigint_to_i64(args[0].value.i);
                return Value(std::exp(v));
            }
            return Value(1.0);
        }
        if (name == "tanh") {
            if (args.size() >= 1) {
                double v = (args[0].type == ValueType::DOUBLE) ? static_cast<double>(args[0].value.d) : (double)bigint_to_i64(args[0].value.i);
                return Value(std::tanh(v));
            }
            return Value(0.0);
        }
        if (name == "atan2") {
            if (args.size() >= 2) {
                double y = (args[0].type == ValueType::DOUBLE) ? static_cast<double>(args[0].value.d) : (double)bigint_to_i64(args[0].value.i);
                double x = (args[1].type == ValueType::DOUBLE) ? static_cast<double>(args[1].value.d) : (double)bigint_to_i64(args[1].value.i);
                return Value(std::atan2(y, x));
            }
            return Value(0.0);
        }
        if (name == "log") {
            if (args.size() >= 1) {
                double v = (args[0].type == ValueType::DOUBLE) ? static_cast<double>(args[0].value.d) : (double)bigint_to_i64(args[0].value.i);
                return Value(std::log(v));
            }
            return Value(0.0);
        }
        if (name == "floor") {
            if (args.size() >= 1 && args[0].type == ValueType::DOUBLE) return Value((int)std::floor(args[0].value.d));
            return args.size() ? args[0] : Value(0);
        }
        if (name == "ceil") {
            if (args.size() >= 1 && args[0].type == ValueType::DOUBLE) return Value((int)std::ceil(args[0].value.d));
            return args.size() ? args[0] : Value(0);
        }
        if (name == "read_file") {
            // "" for a missing file (legacy contract); a directory is an
            // IsADirectoryError rather than the raw C++ stream failure.
            if (args.size() >= 1) {
                std::string fname = getStringValue(args[0]);
                struct stat dst;
                if (stat(fname.c_str(), &dst) == 0 && S_ISDIR(dst.st_mode))
                    throw std::string("__exc__:IsADirectoryError:[Errno 21] Is a directory: '" + fname + "'");
                // Binary: the bytes as they are. Text mode translated line
                // endings on Windows, so a file never round-tripped there (a
                // CRLF document saved back came out with \r\r\n).
                std::ifstream f(fname, std::ios::binary);
                if (f.is_open()) {
                    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
                    return makeStringValue(content);
                }
            }
            return makeStringValue("");
        }
        if (name == "write_file") {
            if (args.size() >= 2) {
                std::string fname = getStringValue(args[0]);
                std::string content = getStringValue(args[1]);
                std::ofstream f(fname, std::ios::binary | std::ios::trunc);   // byte-exact, as read_file
                if (f.is_open()) { f << content; return Value(true); }
            }
            return Value(false);
        }
        if (name == "file_exists") {
            if (args.size() >= 1) {
                struct stat buf;
                return Value(stat(getStringValue(args[0]).c_str(), &buf) == 0);
            }
            return Value(false);
        }
        if (name == "repeat") {
            if (args.size() >= 2) {
                std::string s = getStringValue(args[0]);
                int n = static_cast<int>(bigint_to_i64(args[1].value.i));
                std::string result;
                result.reserve(s.size() * n);
                for (int i = 0; i < n; i++) result += s;
                return makeStringValue(result);
            }
            return NONE_VALUE;
        }
        if (name == "input") {
            if (nyrt::audit_on()) E.auditEvent("builtins.input", {args.empty() ? NONE_VALUE : args[0]}, ctx);   // round 84
            // input(prompt): one line from stdin (NyConc.cpp: read_stdin_line -
            // the GIL is released while it waits, Ctrl+C raises
            // KeyboardInterrupt); EOFError at the end of input, as in Python.
            if (!args.empty()) std::cout << E.strOf(args[0]) << std::flush;
            std::string line;
            bool ok;
            try { ok = nyconc::read_stdin_line(line); }
            catch (nyconc::NyError& err) {
                if (!err.raw.empty()) throw std::string(err.raw);
                throw std::string("__exc__:" + err.type + ":" + err.msg);
            }
            if (!ok) E.pyRaise("EOFError", "EOF when reading a line");
            Value res = E.makeStringValue(line);
            // (round 86) the line read, as CPython's input() reports it when it
            // read the terminal (its readline path; not a pipe or a file)
            if (nyrt::audit_on() && isatty(0) && isatty(1)) E.auditEvent("builtins.input/result", {res}, ctx);
            return res;
        }

    return UNDEFINED_VALUE;  // not handled by this module
}
#pragma GCC diagnostic pop
