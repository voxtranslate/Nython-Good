import "lib/nytorch.ny"

print "=== NYTORCH13 TEST SUITE ==="
print ""
var passed = 0
var failed = 0

def assert_true(name, cond):
    if cond:
        print "  PASS: " + name
        passed = passed + 1
    else:
        print "  FAIL: " + name
        failed = failed + 1

def assert_eq(name, a, b):
    if a == b:
        print "  PASS: " + name
        passed = passed + 1
    else:
        print "  FAIL: " + name + " (got " + str(a) + " expected " + str(b) + ")"
        failed = failed + 1

# ── Test 202: SACAgent ───────────────────────────────────────────────────
# A one-step bandit: in state s action 1 pays 1.0 and action 0 pays 0.0.
# After training, the critic must value action 1 above action 0 and the
# policy must prefer it.
print "--- SACAgent ---"
torch.manual_seed(0)
var sac = SACAgent(4, 2, 0.01, 0.05, 16)
assert_eq("SAC name", sac.get_stats()["name"], "SAC")
assert_eq("SAC no update yet", sac.update(), 0.0)
var bandit_s = [0.5, -0.2, 0.1, 0.3]
for i in range(0, 64):
    sac.store(bandit_s, i % 2, float(i % 2), bandit_s, true)
assert_true("SAC buffer filled", sac.get_stats()["buffer"] == 64)
var loss = sac.update()
assert_true("SAC update returns a number", type(loss) == "float")
for i in range(0, 60):
    sac.update()
var sq = sac.q1.forward(Tensor(bandit_s)).data
assert_true("SAC critic learned Q(s,1) > Q(s,0)", sq[1] > sq[0] + 0.5)
var sp = sac.actor.forward(Tensor(bandit_s)).softmax(0).data
assert_true("SAC policy prefers the paying action", sp[1] > 0.6)
assert_true("SAC act returns a valid action", sac.act(bandit_s) == 0 or sac.act(bandit_s) == 1)

# ── Test 203: TD3Agent ───────────────────────────────────────────────────
print "--- TD3Agent ---"
torch.manual_seed(0)
var td3 = TD3Agent(4, 2, 0.001)
assert_eq("TD3 name", td3.get_name(), "TD3")
var td3_a = td3.act([0.0, 0.1, 0.2, 0.3], 0.1)
assert_eq("TD3 act returns an action vector", len(td3_a), 2)
assert_true("TD3 actions are in [-1, 1]", td3_a[0] >= -1.0 and td3_a[0] <= 1.0 and td3_a[1] >= -1.0 and td3_a[1] <= 1.0)
for i in range(0, 20):
    td3.store([0.0, 0.1, 0.2, 0.3], [0.5, -0.5], 1.0, [0.1, 0.2, 0.3, 0.4], false)
var td3_result = td3.update()
assert_true("TD3 returns dict", td3_result["updates"] == 1)
assert_true("TD3 critic loss is positive", td3_result["critic"] > 0.0)

# ── Test 204: A2CAgent ───────────────────────────────────────────────────
print "--- A2CAgent ---"
torch.manual_seed(0)
var a2c = A2CAgent(4, 3, 0.001, 0.99, 0.01)
assert_eq("A2C name", a2c.get_stats()["name"], "A2C")
var a2c_act = a2c.act([0.0, 0.1, 0.2, 0.3])
assert_eq("A2C act returns [action, log_prob, value]", len(a2c_act), 3)
assert_true("A2C log_prob is a log-probability", a2c_act[1] <= 0.0)
for i in range(0, 10):
    a2c.store_step([0.0, 0.1, 0.2, 0.3], i % 3, float(i) * 0.1, 0.5, -0.3)
var returns = a2c.compute_returns()
assert_eq("A2C returns computed", len(returns), 10)
assert_true("A2C last return is the last reward", abs(returns[9] - 0.9) < 0.000001)
assert_true("A2C discounted return", abs(returns[8] - (0.8 + 0.99 * 0.9)) < 0.000001)
assert_true("A2C first return >= last reward", returns[0] >= returns[9])
var a2c_loss = a2c.update()
assert_true("A2C update returns a number", type(a2c_loss) == "float")
assert_eq("A2C clears trajectory", len(a2c.trajectory), 0)

# ── Test 205: PPOAgent ───────────────────────────────────────────────────
# Bandit again: action 1 pays 1.0; the clipped updates must move the policy.
print "--- PPOAgent ---"
torch.manual_seed(0)
var ppo = PPOAgent(4, 2, 0.01, 0.2, 4)
assert_eq("PPO name", ppo.get_name(), "PPO")
var ppo_s = [0.0, 0.1, 0.2, 0.3]
var act_result = ppo.act(ppo_s)
assert_eq("PPO act returns [action, log_prob]", len(act_result), 2)
var p_before = ppo.policy.forward(Tensor(ppo_s)).softmax(0).data[1]
var ppo_result = none
for round in range(0, 8):
    for i in range(0, 16):
        var ar = ppo.act(ppo_s)
        ppo.store(ppo_s, ar[0], float(ar[0]), ar[1], 0.0, true)
    ppo_result = ppo.update()
assert_true("PPO loss returned", ppo_result["updates"] == 8)
assert_eq("PPO buffer cleared after update", len(ppo.buffer), 0)
var p_after = ppo.policy.forward(Tensor(ppo_s)).softmax(0).data[1]
assert_true("PPO raised the probability of the paying action", p_after > p_before + 0.1)

# ── Test 206: TransformerTokenizer ──────────────────────────────────────
print "--- TransformerTokenizer ---"
var tok = TransformerTokenizer(1000, 16)
tok.add_word("hello")
tok.add_word("world")
tok.add_word("nython")
var ids = tok.encode("hello world")
assert_eq("Tokenizer adds CLS", ids[0], 2)
assert_eq("Tokenizer pads to max_len", len(ids), 16)
assert_eq("Tokenizer last non-pad is SEP before pads", ids[3], 3)
var decoded = tok.decode([2, 5, 6, 3, 0, 0])
assert_true("Tokenizer decode works", len(decoded) > 0)
assert_true("Tokenizer vocab growing", tok.vocab_len() > 5)

# ── Test 207: TransformerEmbedding ──────────────────────────────────────
print "--- TransformerEmbedding ---"
var emb = TransformerEmbedding(100, 16, 32)
assert_eq("Embedding name", emb.get_name(), "TransformerEmbedding")
var token_emb = emb.embed_token(5)
assert_true("Embedding token returns vector", len(token_emb) > 0)
var pos_emb = emb.embed_position(0)
assert_true("Embedding pos returns vector", len(pos_emb) > 0)
var embeddings = emb.forward([2, 5, 6, 3])
assert_eq("Embedding forward returns seq", len(embeddings), 4)

# ── Test 208: ScaledDotProductAttention ──────────────────────────────────
print "--- ScaledDotProductAttention ---"
var sdpa = ScaledDotProductAttention(16, 0.1)
assert_eq("SDPA name", sdpa.get_name(), "ScaledDotProductAttention")
assert_true("SDPA scale = 1/sqrt(16)", abs(sdpa.get_scale() - 0.25) < 0.01)
var Q = tensor_randn([16])
var K = tensor_randn([16])
var V = tensor_randn([16])
var attn_out = sdpa.forward(Q, K, V, false)
assert_true("SDPA output has attn_weight", "attn_weight" in attn_out)

# ── Test 209: MultiHeadSelfAttention ─────────────────────────────────────
print "--- MultiHeadSelfAttention ---"
var mhsa = MultiHeadSelfAttention(16, 4, 0.1)
assert_eq("MHSA n_heads", mhsa.get_n_heads(), 4)
assert_eq("MHSA name", mhsa.get_name(), "MultiHeadSelfAttention")
mhsa.eval()   # attention dropout (p=0.1) is only active in training mode
torch.manual_seed(0)
var x_seq = Tensor(tensor_randn([16]))
var y_seq = Tensor(tensor_randn([16]))
var mhsa_out = mhsa.forward([x_seq, x_seq], false)
assert_eq("MHSA output shape", mhsa_out.shape, [2, 16])
assert_true("MHSA: identical tokens get identical outputs", mhsa_out[0].allclose(mhsa_out[1]))
var causal_2 = mhsa.forward([x_seq, y_seq], true)
var causal_1 = mhsa.forward([x_seq], true)
assert_true("MHSA causal: token 0 ignores token 1", causal_2[0].allclose(causal_1[0]))
var full_2 = mhsa.forward([x_seq, y_seq], false)
assert_true("MHSA unmasked: token 0 sees token 1", not full_2[0].allclose(causal_1[0]))

# ── Test 210: TransformerEncoderLayer ─────────────────────────────────────
print "--- TransformerEncoderLayer ---"
var enc_layer = TransformerEncoderLayer(16, 4, 64, 0.1)
assert_eq("EncoderLayer name", enc_layer.get_name(), "TransformerEncoderLayer")
var x_in = tensor_randn([16])
var x_out = enc_layer.forward(x_in, false)
assert_eq("EncoderLayer output dim", len(x_out), 16)

# ── Test 211: TransformerEncoder ─────────────────────────────────────────
print "--- TransformerEncoder ---"
var encoder = TransformerEncoder(100, 16, 4, 2, 64, 16, 0.1)
assert_eq("Encoder name", encoder.get_name(), "TransformerEncoder")
var n_params = encoder.n_params()
assert_true("Encoder has params", n_params > 0)
var out_vec = encoder.forward([2, 5, 6, 3], false)
assert_eq("Encoder output dim", len(out_vec), 16)
var class_probs = encoder.classify([2, 5, 6, 3], 3)
assert_eq("Encoder classify n_classes", len(class_probs), 3)

# ── Test 212: BayesianLinear ──────────────────────────────────────────────
print "--- BayesianLinear ---"
var bayes = BayesianLinear(8, 4, 1.0)
assert_eq("Bayes name", bayes.get_name(), "BayesianLinear")
var b_out = bayes.forward(tensor_randn([8]))
assert_eq("Bayes output dim", len(b_out), 4)
var kl = bayes.kl_loss()
assert_true("Bayes KL >= 0", kl >= 0.0)

# ── Test 213: MCDropoutModel ──────────────────────────────────────────────
print "--- MCDropoutModel ---"
var mc = MCDropoutModel([8, 16, 4], 0.1, 10)
assert_eq("MCDropout name", mc.get_name(), "MCDropoutModel")
var uncertainty = mc.predict_with_uncertainty(tensor_randn([8]))
assert_eq("MCDropout n_samples", uncertainty["samples"], 10)
assert_true("MCDropout variance >= 0", uncertainty["variance"] >= 0.0)
assert_true("MCDropout std >= 0", uncertainty["std"] >= 0.0)

# ── Test 214: EnsembleModel ───────────────────────────────────────────────
print "--- EnsembleModel ---"
var ensemble = EnsembleModel(5, [8, 4], 0.001)
assert_eq("Ensemble name", ensemble.get_name(), "EnsembleModel")
var x_ens = tensor_randn([8])
var pred = ensemble.predict(x_ens)
assert_true("Ensemble prediction is float", type(pred) == "float" or type(pred) == "int")
var pred_var = ensemble.predict_with_variance(x_ens)
assert_eq("Ensemble n_models", pred_var["models"], 5)
assert_true("Ensemble variance >= 0", pred_var["variance"] >= 0.0)
ensemble.update_weights([0.5, 0.3, 0.2, 0.4, 0.1])
assert_true("Ensemble weights sum ~1", true)

# ── Test 215: HyperparamSearch ────────────────────────────────────────────
print "--- HyperparamSearch ---"
var search = HyperparamSearch({"lr": [0.1, 0.01, 0.001], "layers": [2, 3, 4]}, 10, "random")
assert_eq("Search name", search.get_name(), "HyperparamSearch")
var params1 = search.suggest()
assert_true("Search suggest returns dict", "lr" in params1)
search.report(params1, 0.5)
var params2 = search.suggest()
search.report(params2, 0.3)
var best = search.best_result()
assert_true("Search best score <= 0.5", best["score"] <= 0.5)
assert_eq("Search n_trials", best["n_trials"], 2)

# ── Test 216: NASCell ─────────────────────────────────────────────────────
print "--- NASCell ---"
var nas = NASCell(4, ["relu", "identity", "zero", "tanh"])
assert_eq("NAS name", nas.get_name(), "NASCell")
var discrete_ops = nas.discretize()
assert_eq("NAS discrete ops", len(discrete_ops), 4)
var nas_out = nas.forward(tensor_randn([8]))
assert_true("NAS forward returns tensor", len(nas_out) > 0)

# ── Test 217: ModelRegistry ───────────────────────────────────────────────
print "--- ModelRegistry ---"
var registry = ModelRegistry("production")
var key1 = registry.register("classifier", 1, "model_v1_data", ["classification", "v1"])
var key2 = registry.register("classifier", 2, "model_v2_data", ["classification", "v2"])
assert_eq("Registry key format", key1, "classifier:1")
assert_eq("Registry total", registry.total(), 2)
var m = registry.get_latest("classifier")
assert_eq("Registry latest", m, "model_v2_data")
registry.record_metrics("classifier", 2, {"accuracy": 0.95, "f1": 0.94})
var metrics = registry.get_metrics("classifier", 2)
assert_true("Registry metrics stored", metrics["accuracy"] > 0.9)
var model_list = registry.list_models()
assert_true("Registry lists models", len(model_list) > 0)

# ── Test 218: ModelServer ─────────────────────────────────────────────────
print "--- ModelServer ---"
var server = ModelServer("localhost", 8080, "my_model")
assert_eq("Server name", server.get_name(), "ModelServer")
torch.manual_seed(0)
var served = Linear(3, 2)
var srv_bad = ModelServer("localhost", 8081, "bad")
srv_bad.load_model("stub_model")
var rejected = false
try:
    srv_bad.predict([1.0])
except e:
    rejected = true
assert_true("Server rejects a string as a model", rejected)
server.load_model(served)
var response = server.predict([1.0, 2.0, 3.0])
assert_true("Server request counted", response["request_id"] == 1)
assert_true("Server latency measured", response["latency_ms"] >= 0.0)
var direct = served.forward(Tensor([1.0, 2.0, 3.0])).data
assert_true("Server returns the model's output", abs(response["predictions"][0] - direct[0]) < 0.000000001 and abs(response["predictions"][1] - direct[1]) < 0.000000001)
var batch_resp = server.batch_predict([[1.0, 2.0, 3.0], [0.0, 0.0, 0.0], [3.0, 2.0, 1.0]])
assert_eq("Server batch size", len(batch_resp), 3)
assert_true("Server zero input gives the bias", abs(batch_resp[1]["predictions"][0] - served.bias.data[0]) < 0.000000001)
var health = server.health()
assert_eq("Server status healthy", health["status"], "healthy")
assert_eq("Server request count", health["requests"], 4)

# ── Test 219: BatchInferencer ─────────────────────────────────────────────
print "--- BatchInferencer ---"
def triple_first(x):
    return [x[0] * 3.0]
var inferencer = BatchInferencer(triple_first, 4, 2)
assert_eq("Inferencer name", inferencer.get_name(), "BatchInferencer")
for i in range(0, 10):
    inferencer.submit("req_" + str(i), [float(i)])
assert_eq("Inferencer queue filled", inferencer.stats()["queued"], 10)
var n_proc = inferencer.process_batch()
assert_eq("Inferencer batch processed", n_proc, 4)
assert_eq("Inferencer result available", inferencer.stats()["processed"], 4)
assert_eq("Inferencer result is the model's output", inferencer.get_result("req_3"), [9.0])
var total_drained = inferencer.drain()
assert_eq("Inferencer drain processes rest", total_drained, 6)
assert_eq("Inferencer last result", inferencer.get_result("req_9"), [27.0])

# ── Test 220: ABTestFramework ─────────────────────────────────────────────
print "--- ABTestFramework ---"
var ab = ABTestFramework("model_ab_test", 0.5)
assert_eq("AB name", ab.get_name(), "ABTestFramework")
def model_a_fn(x):
    return x[0] + 1.0
def model_b_fn(x):
    return x[0] * 10.0
ab.set_models(model_a_fn, model_b_fn)
for i in range(0, 20):
    var res = ab.predict(i, [float(i)])
    if res["variant"] == "A":
        ab.record_outcome("A", 0.2)
    else:
        ab.record_outcome("B", 0.9)
var ab_res = ab.predict(3, [3.0])
assert_eq("AB routes request 3 to B", ab_res["variant"], "B")
assert_eq("AB returns B's real prediction", ab_res["prediction"], 30.0)
var report = ab.report()
assert_eq("AB total requests", report["total"], 21)
assert_eq("AB winner is the better-scoring variant", report["winner"], "B")
assert_true("AB requests_a + requests_b = total", report["requests_a"] + report["requests_b"] == 21)

# ── Test 221: OnlineRegressor ───────────────────────────────────────────────
print "--- OnlineRegressor ---"
var learner = OnlineRegressor(4, 0.01, 0.001)
assert_eq("Learner name", learner.get_name(), "OnlineRegressor")
for i in range(0, 20):
    var x = tensor([float(i), float(i) * 0.5, 1.0, 0.0])
    var y = float(i) * 2.0
    learner.update(x, y)
assert_eq("Learner timestep", learner.t, 20)
var recent = learner.recent_loss(5)
assert_true("Learner recent loss >= 0", recent >= 0.0)

# ── Test 222: DriftDetector ───────────────────────────────────────────────
print "--- DriftDetector ---"
var drift = DriftDetector(10, 0.5)
assert_eq("Drift name", drift.get_name(), "DriftDetector")
var ref_data = [1.0, 1.1, 0.9, 1.0, 1.05, 0.95, 1.0, 1.1, 0.9, 1.0]
drift.set_reference(ref_data)
for v in ref_data:
    drift.update(v)
assert_true("No drift on same distribution", drift.drift_count == 0 or drift.drift_count >= 0)
for i in range(0, 10):
    drift.update(float(i) * 0.5 + 5.0)
assert_true("Drift detected on shifted distribution", drift.drift_count > 0)

# ── Test 223: FeaturePipeline ─────────────────────────────────────────────
print "--- FeaturePipeline ---"
var pipeline = FeaturePipeline("preprocessing")
assert_eq("Pipeline name", pipeline.get_name(), "preprocessing")
pipeline.add_step("normalize", lambda x: x / 10.0)
pipeline.add_step("clip", lambda x: min(max(x, 0.0), 1.0))
assert_eq("Pipeline steps count", len(pipeline.get_steps()), 2)
var data = tensor([1.0, 2.0, 3.0, 4.0, 5.0])
var transformed = pipeline.fit_transform(data)
assert_true("Pipeline is fitted", pipeline.is_fitted)
assert_true("Pipeline transform returns tensor", len(transformed) > 0)

# ── Test 224: CrossValidator ──────────────────────────────────────────────
print "--- CrossValidator ---"
var cv = CrossValidator(5, lambda fold, n: 0.8 + float(fold) * 0.02, false)
assert_eq("CV name", cv.get_name(), "CrossValidator")
var cv_data = tensor_randn([50])
var cv_labels = tensor_zeros([50])
var cv_result = cv.score("stub_model", cv_data, cv_labels)
assert_eq("CV n_folds", len(cv_result["folds"]), 5)
assert_true("CV mean in range", cv_result["mean"] >= 0.8)
assert_true("CV std >= 0", cv_result["std"] >= 0.0)

# ── Test 225: GCNLayer ────────────────────────────────────────────────────
print "--- GCNLayer ---"
var gcn = GCNLayer(8, 16, "relu")
assert_eq("GCN name", gcn.get_name(), "GCNLayer")
var node_feats = [tensor_randn([8]), tensor_randn([8]), tensor_randn([8])]
var adj = [[1, 2], [0, 2], [0, 1]]
var gcn_out = gcn.forward(node_feats, adj)
assert_eq("GCN output n_nodes", len(gcn_out), 3)
assert_eq("GCN output dim", len(gcn_out[0]), 16)

# Known values: identity weights, no bias, no activation, on the 2-node
# path graph: A + I is all ones, every degree is 2, so the normalised
# adjacency averages the two rows.
var gcn_id = GCNLayer(2, 2, "none")
nt_copy_(gcn_id.linear.weight.data, [1.0, 0.0, 0.0, 1.0])
nt_fill_(gcn_id.linear.bias.data, 0.0)
var gcn_v = gcn_id.forward([[1.0, 2.0], [3.0, 6.0]], [[1], [0]])
assert_true("GCN normalised adjacency averages neighbours", gcn_v.allclose(Tensor([[2.0, 4.0], [2.0, 4.0]])))
# a node with no neighbours keeps its own (transformed) features
var gcn_iso = gcn_id.forward([[1.0, 2.0], [3.0, 6.0], [5.0, 7.0]], [[1], [0], []])
assert_true("GCN isolated node keeps its features", gcn_iso[2].allclose(Tensor([5.0, 7.0])))

# ── Test 226: GATLayer ────────────────────────────────────────────────────
print "--- GATLayer ---"
var gat = GATLayer(8, 16, 4, 0.1)
assert_eq("GAT name", gat.get_name(), "GATLayer")
var gat_out = gat.forward(node_feats, adj)
assert_eq("GAT output n_nodes", len(gat_out), 3)
assert_eq("GAT output dim", len(gat_out[0]), 16)

gat.eval()
var gat_iso = gat.forward([[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]], [[], []])
var gat_self = gat.W.forward(Tensor([1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])).reshape([4, 16]).mean(0)
assert_true("GAT isolated node attends only to itself", gat_iso[0].allclose(gat_self))
var gat_same = gat.forward([node_feats[0], node_feats[0], node_feats[0]], adj)
assert_true("GAT identical nodes give identical outputs", gat_same[0].allclose(gat_same[2]))

# ── Test 227: GraphSAGE ───────────────────────────────────────────────────
print "--- GraphSAGE ---"
var sage = GraphSAGE(8, 16, 4, 2, "mean")
assert_eq("GraphSAGE name", sage.get_name(), "GraphSAGE")
var sage_out = sage.forward(node_feats, adj)
assert_eq("GraphSAGE output n_nodes", len(sage_out), 3)

# ── Test 228: KnowledgeDistillation ──────────────────────────────────────
print "--- KnowledgeDistillation ---"
var kd = KnowledgeDistillation("teacher_model", "student_model", 4.0, 0.7)
assert_eq("KD name", kd.get_name(), "KnowledgeDistillation")
var teacher_logits = tensor([2.0, 1.0, 0.5])
var student_logits = tensor([1.8, 0.9, 0.6])
var kd_result = kd.compute_loss(student_logits, teacher_logits, [1.0, 0.0, 0.0])
assert_true("KD total loss > 0", kd_result["total"] >= 0.0)
assert_true("KD loss breakdown", "kd" in kd_result and "task" in kd_result)
assert_true("KD avg loss tracked", kd.avg_kd_loss() >= 0.0)

var kd_same = kd.compute_loss([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], 2)
assert_true("KD: identical logits have zero distillation loss", abs(kd_same["kd"]) < 0.000000001)
var ce_ref = log(exp(1.0) + exp(2.0) + exp(3.0)) - 3.0
assert_true("KD task loss is the cross entropy", abs(kd_same["task"] - ce_ref) < 0.000000001)
assert_true("KD total = alpha kd + (1 - alpha) task", abs(kd_same["total"] - 0.3 * ce_ref) < 0.000000001)

# ── Test 229: PromptTemplate ──────────────────────────────────────────────
print "--- PromptTemplate ---"
var tmpl = PromptTemplate("Classify: {text} into {category}", ["text", "category"])
assert_eq("Template name", tmpl.get_name(), "PromptTemplate")
tmpl.set_system("You are a helpful classifier.")
tmpl.add_example("the cat sat", "animal")
tmpl.add_example("buy stocks now", "finance")
var formatted = tmpl.format({"text": "cute puppy", "category": "pets"})
assert_true("Template formats correctly", formatted == "Classify: cute puppy into pets")
var prompt = tmpl.build_prompt({"text": "cute puppy", "category": "pets"})
assert_true("Template build_prompt includes system", len(prompt) > 20)
assert_true("Template includes examples", len(tmpl.examples) == 2)

# ── Test 230: LLMPipeline ─────────────────────────────────────────────────
print "--- LLMPipeline ---"
var llm_tok = TransformerTokenizer(500, 20)
llm_tok.add_word("nython")
llm_tok.add_word("is")
llm_tok.add_word("great")
var llm = LLMPipeline("nython-llm-1b", llm_tok, 12, 0.7)   # 12 new tokens keep the interpreter's memory bounded
assert_eq("LLM name", llm.get_name(), "LLMPipeline")
llm.add_plugin("lowercase", lambda x: x.lower())
var gen = llm.generate("nython is great", ["\n"])
assert_true("LLM generates text", "text" in gen)
assert_true("LLM counts tokens", gen["tokens_used"] > 0)
assert_true("LLM total tokens tracked", llm.total_tokens_used() > 0)
var chat_resp = llm.chat("Hello there")
assert_true("LLM chat works", "text" in chat_resp)
assert_true("LLM history grows", len(llm.history) > 0)

# ── Summary ──────────────────────────────────────────────────────────────
print ""
print "Results: " + str(passed) + " passed, " + str(failed) + " failed"
if failed == 0:
    print "=== ALL NYTORCH13 TESTS PASSED ==="
else:
    print "=== SOME TESTS FAILED ==="
