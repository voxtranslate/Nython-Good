# vm_audit47 — nytorch ND tensors, autograd, nn, optim, data, save/load
#
# Every check asserts a VALUE: hand-computed, or the number PyTorch gives
# for the same call (CrossEntropy on logits [2, 1, 0] with target 0 is
# 0.4076059644443806 — softmax/log-sum-exp done by hand). Runs identically
# on both engines: the arithmetic is the shared native kernel library
# (include/NyTensor.hpp), so even the trained-model numbers match bit for
# bit. Run: nython-cli examples/vm_audit47.ny  /  nython-cli --vm ...
import "lib/nytorch.ny"

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

def absf(x):
    if x < 0.0:
        return 0.0 - x
    return x

def check_close(name, got, want, tol):
    if absf(got - want) <= tol:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

def check_list(name, got, want, tol):
    var ok = len(got) == len(want)
    var k = 0
    while ok and k < len(want):
        if absf(got[k] - want[k]) > tol:
            ok = false
        k = k + 1
    if ok:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

# The error must be raised and its message must name what went wrong.
# (`except e:` binds the message on the interpreter and "Type: message" on
# the VM, so the needle is matched as a substring.)
def check_raises(name, fn, needle):
    var msg = none
    try:
        fn()
    except e:
        msg = str(e)
    if msg != none and string_find(msg, needle) >= 0:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": raised " + str(msg) + ", expected a message containing '" + needle + "'")

# numerical gradient of scalar fn(Tensor) at x, compared to autograd
def grad_check(name, x, fn, tol):
    var y = fn(x)
    y.backward()
    var analytic = x.grad
    var worst = 0.0
    var k = 0
    var h = 0.000001
    while k < len(x.data):
        var orig = x.data[k]
        x.data[k] = orig + h
        var up = 0.0
        var dn = 0.0
        with no_grad():
            up = fn(x).item()
            x.data[k] = orig - h
            dn = fn(x).item()
        x.data[k] = orig
        var num = (up - dn) / (2.0 * h)
        var d = absf(num - analytic[k])
        if d > worst:
            worst = d
        k = k + 1
    check_close(name + " (max |autograd - numeric|)", worst, 0.0, tol)

print("== creation, shape, reshape, transpose ==")
var m = Tensor([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
check("shape", m.shape, [2, 3])
check("flat data", m.data, [1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
check("ints become floats", Tensor([1, 2]).data, [1.0, 2.0])
check("0-d tensor", Tensor(3).item(), 3.0)
check("reshape -1", m.reshape([3, -1]).shape, [3, 2])
check("transpose values", m.t().data, [1.0, 4.0, 2.0, 5.0, 3.0, 6.0])
check("transpose shape", m.t().shape, [3, 2])
check("permute 3-d", Tensor([[[1, 2], [3, 4]], [[5, 6], [7, 8]]]).permute([2, 0, 1]).data, [1.0, 3.0, 5.0, 7.0, 2.0, 4.0, 6.0, 8.0])
check("unsqueeze/squeeze", m.unsqueeze(0).shape, [1, 2, 3])
check("squeeze back", m.unsqueeze(1).squeeze(1).shape, [2, 3])
check("flatten", m.flatten().shape, [6])
check("tolist", m.tolist(), [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
check("row index", m[1].data, [4.0, 5.0, 6.0])
check("gather rows", m[[1, 0]].data, [4.0, 5.0, 6.0, 1.0, 2.0, 3.0])
check("narrow", m.narrow(1, 1, 2).data, [2.0, 3.0, 5.0, 6.0])
check("slice step", Tensor([0, 1, 2, 3, 4, 5]).slice(0, 1, 6, 2).data, [1.0, 3.0, 5.0])
check("cat dim1", torch.cat([m, m], 1).shape, [2, 6])
check("stack", torch.stack([Tensor([1, 2]), Tensor([3, 4])], 0).data, [1.0, 2.0, 3.0, 4.0])
check_raises("reshape to wrong size raises", lambda: m.reshape([4, 2]), "invalid for input of size 6")
check_raises("ragged nested list raises", lambda: Tensor([[1, 2], [3]]), "ragged")

print("== broadcasting ==")
check("row broadcast", (m + Tensor([10, 20, 30])).data, [11.0, 22.0, 33.0, 14.0, 25.0, 36.0])
check("column broadcast", (m * Tensor([[10], [100]])).data, [10.0, 20.0, 30.0, 400.0, 500.0, 600.0])
check("outer via broadcast", (Tensor([[1], [2]]) * Tensor([1, 2, 3])).shape, [2, 3])
check("scalar", (m - 1.0).data, [0.0, 1.0, 2.0, 3.0, 4.0, 5.0])
check_raises("incompatible shapes raise", lambda: m + Tensor([1, 2]), "broadcast")
check_raises("legacy tensor_add length mismatch raises", lambda: tensor_add([1, 2, 3], [1, 2]), "length")
# typed: the kernels raise ValueError / IndexError / TypeError, catchable by type
var etype = ""
try:
    nt_binary("add", [1.0, 2.0, 3.0], [3], [1.0, 2.0], [2])
except ValueError as e:
    etype = "ValueError"
check("broadcast failure is a ValueError", etype, "ValueError")
etype = ""
try:
    nt_index_select([1.0, 2.0], [2], 0, [5])
except IndexError as e:
    etype = "IndexError"
check("index out of range is an IndexError", etype, "IndexError")
etype = ""
try:
    nt_binary(1, [1.0], [1], [1.0], [1])
except TypeError as e:
    etype = "TypeError"
check("wrong argument type is a TypeError", etype, "TypeError")
check("legacy tensor_add length-1 broadcasts", tensor_add([1, 2, 3], [10]), [11.0, 12.0, 13.0])
check("legacy ints are numbers (was [0,0,0])", tensor_scale([1, 2, 3], 2), [2.0, 4.0, 6.0])
var bc = Tensor([[1.0, 2.0, 3.0]], true)
var bd = Tensor([[10.0], [20.0]], true)
(bc * bd).sum().backward()
check("broadcast grad reduces over rows", bc.grad, [30.0, 30.0, 30.0])
check("broadcast grad reduces over cols", bd.grad, [6.0, 6.0])

print("== reductions along an axis ==")
check("sum dim 0", m.sum(0).data, [5.0, 7.0, 9.0])
check("mean dim 1 keepdim", m.mean(1, true).shape, [2, 1])
check("mean dim 1 keepdim values", m.mean(1, true).data, [2.0, 5.0])
check("max dim 1", m.max(1).data, [3.0, 6.0])
check("argmax dim 1", Tensor([[1, 7, 3], [9, 5, 6]]).argmax(1).data, [1, 0])
check("argmax all", Tensor([[1, 7, 3], [9, 5, 6]]).argmax().item(), 3)
check("var dim 1 (unbiased)", m.var(1).data, [1.0, 1.0])
check_close("var all (unbiased, torch default)", Tensor([1, 2, 3, 4]).var().item(), 1.6666666666666667, 0.000000000001)
check_close("std all", Tensor([1, 2, 3, 4]).std().item(), 1.2909944487358056, 0.000000000001)
check("sum over two dims", Tensor([[[1, 2], [3, 4]], [[5, 6], [7, 8]]]).sum([0, 2]).data, [14.0, 22.0])
check_close("logsumexp is stable", Tensor([1000.0, 1000.0]).logsumexp().item(), 1000.6931471805599, 0.000000001)
var rm = Tensor([[1.0, 5.0], [3.0, 2.0]], true)
rm.max(1).sum().backward()
check("max grad goes to the max element", rm.grad, [0.0, 1.0, 1.0, 0.0])

print("== matmul ==")
check("2x3 @ 3x2", Tensor([[1, 2, 3], [4, 5, 6]]).matmul(Tensor([[7, 8], [9, 10], [11, 12]])).data, [58.0, 64.0, 139.0, 154.0])
var bmm = Tensor([[[1, 0], [0, 1]], [[2, 0], [0, 2]]]).matmul(Tensor([[1, 2], [3, 4]]))
check("batched (broadcast rhs) shape", bmm.shape, [2, 2, 2])
check("batched values", bmm.data, [1.0, 2.0, 3.0, 4.0, 2.0, 4.0, 6.0, 8.0])
check("vector @ matrix", Tensor([1, 1]).matmul(Tensor([[1, 2], [3, 4]])).data, [4.0, 6.0])
check("dot", Tensor([1, 2, 3]).dot(Tensor([4, 5, 6])).item(), 32.0)
check("legacy 5-arg matmul", matmul([1, 2, 3, 4], [5, 6, 7, 8], 2, 2, 2), [19.0, 22.0, 43.0, 50.0])
check("legacy 2-arg nested matmul", matmul([[1, 2], [3, 4]], [[5, 6], [7, 8]]), [[19.0, 22.0], [43.0, 50.0]])
check("legacy 2-arg vector x flat matrix", tensor_matmul([1, 1], [1, 2, 3, 4]), [4.0, 6.0])
check_raises("matmul inner-dim mismatch raises", lambda: Tensor([[1, 2]]).matmul(Tensor([[1, 2]])), "matmul")
var ma = Tensor([[1.0, 2.0], [3.0, 4.0]], true)
var mb = Tensor([[5.0, 6.0], [7.0, 8.0]], true)
ma.matmul(mb).sum().backward()
check("d(sum A@B)/dA = 1 @ B^T", ma.grad, [11.0, 15.0, 11.0, 15.0])
check("d(sum A@B)/dB = A^T @ 1", mb.grad, [4.0, 4.0, 6.0, 6.0])

print("== softmax / log_softmax ==")
check_list("softmax rows", Tensor([[1.0, 2.0, 3.0], [1.0, 1.0, 1.0]]).softmax(1).data, [0.09003057317038046, 0.24472847105479767, 0.6652409557748219, 0.3333333333333333, 0.3333333333333333, 0.3333333333333333], 0.000000000001)
check("log_softmax stable at +-1000", Tensor([1000.0, 0.0]).log_softmax(0).data, [0.0, -1000.0])
check("softmax of huge logits", Tensor([1000.0, 1000.0]).softmax(0).data, [0.5, 0.5])
check("legacy log_softmax_tensor stable", log_softmax_tensor(Tensor([1000.0, 0.0])).data, [0.0, -1000.0])

print("== cross-entropy / NLL vs PyTorch ==")
var logits = Tensor([[2.0, 1.0, 0.0], [0.0, 1.0, 2.0]], true)
var ce = cross_entropy(logits, [0, 2])
check_close("F.cross_entropy logits [2,1,0]/[0,1,2] targets [0,2]", ce.item(), 0.4076059644443806, 0.000000000001)
ce.backward()
check_list("CE grad = (softmax - onehot) / N", logits.grad, [-0.16737952211258916, 0.12236423552739879, 0.04501528658519022, 0.04501528658519022, 0.12236423552739879, -0.16737952211258916], 0.000000000001)
check_close("CrossEntropyLoss unbatched (C,)", CrossEntropyLoss().forward(Tensor([2.0, 1.0, 0.0]), 0).item(), 0.4076059644443806, 0.000000000001)
check_close("class weights [1,2,3], targets [0,1]", cross_entropy(Tensor([[2.0, 1.0, 0.0], [0.0, 1.0, 2.0]]), [0, 1], Tensor([1.0, 2.0, 3.0])).item(), 1.0742726311110473, 0.000000000001)
check_close("label_smoothing 0.1", cross_entropy(Tensor([[2.0, 1.0, 0.0]]), [0], none, -100, "mean", 0.1).item(), 0.5076059644443807, 0.000000000001)
check_close("ignore_index", cross_entropy(Tensor([[2.0, 1.0, 0.0], [0.0, 1.0, 2.0]]), [0, -100]).item(), 0.4076059644443806, 0.000000000001)
check_close("reduction sum", cross_entropy(Tensor([[2.0, 1.0, 0.0], [0.0, 1.0, 2.0]]), [0, 2], none, -100, "sum").item(), 0.8152119288887612, 0.000000000001)
check("reduction none shape", cross_entropy(Tensor([[2.0, 1.0, 0.0], [0.0, 1.0, 2.0]]), [0, 2], none, -100, "none").shape, [2])
check_close("probability targets", cross_entropy(Tensor([[2.0, 1.0, 0.0]]), Tensor([[1.0, 0.0, 0.0]])).item(), 0.4076059644443806, 0.000000000001)
check_close("NLLLoss on log-probs", NLLLoss().forward(Tensor([[-0.1, -2.4]]), [0]).item(), 0.1, 0.000000000001)
check_close("nll(log_softmax) == cross_entropy", nll_loss(Tensor([[2.0, 1.0, 0.0]]).log_softmax(1), [0]).item(), 0.4076059644443806, 0.000000000001)
check_close("BCEWithLogits", BCEWithLogitsLoss().forward(Tensor([0.5, -1.0]), Tensor([1.0, 0.0])).item(), 0.39366933584916475, 0.000000000001)
check_close("MSELoss", MSELoss().forward(Tensor([1.0, 2.0]), Tensor([3.0, 5.0])).item(), 6.5, 0.0)
check("mse_loss on plain lists (was none)", mse_loss([1.0, 2.0], [3.0, 5.0]), 6.5)
check_raises("CE target out of range raises", lambda: cross_entropy(Tensor([[2.0, 1.0, 0.0]]), [3]), "out of bounds")

print("== autograd vs finite differences ==")
grad_check("tanh*sigmoid + x^3 + log(exp)", Tensor([0.3, -0.7, 1.2], true), lambda x: (x.tanh() * x.sigmoid() + x.pow(3.0) * 0.1 + x.exp().log()).mean(), 0.000001)
grad_check("matmul + softmax + CE", Tensor([[0.2, -0.1], [0.4, 0.3], [-0.5, 0.6]], true), lambda w: cross_entropy(Tensor([[1.0, 2.0, 3.0], [0.5, -1.0, 2.0]]).matmul(w), [1, 0]), 0.000001)
grad_check("layer_norm + gelu", Tensor([[0.2, -0.1, 0.7], [1.4, 0.3, -2.0]], true), lambda x: F.layer_norm(x, [3]).gelu().pow(2.0).sum(), 0.00001)
grad_check("var + std + logsumexp", Tensor([[0.5, 1.5, -0.2], [2.0, 0.1, 0.3]], true), lambda x: x.var(1).sum() + x.std(0).sum() + x.logsumexp(1).sum(), 0.00001)
grad_check("division + broadcasting", Tensor([[1.0, 2.0], [3.0, 4.0]], true), lambda x: (x.div(x.sum(1, true)) * Tensor([1.0, 3.0])).sum(), 0.00001)
var deep = Tensor(0.0, true)
var leaf = Tensor(1.0, true)
var di = 0
while di < 2000:
    deep = deep + leaf
    di = di + 1
deep.backward()
check("2000-node chain (was a hang past ~900)", leaf.grad, 2000.0)
var nb = Tensor([1.0, 2.0], true)
with no_grad():
    var nz = nb * 3.0
    check("no_grad: result does not require grad", nz.requires_grad, false)
check("grad mode restored", (nb * 3.0).requires_grad, true)

print("== conv / pool / norm layers ==")
var img = Tensor([[[[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]]]])
var ker = Tensor([[[[1.0, 0.0], [0.0, -1.0]]]])
check("conv2d known kernel", F.conv2d(img, ker).data, [-4.0, -4.0, -4.0, -4.0])
check("conv2d padding 1 shape", F.conv2d(img, ker, none, 1, 1).shape, [1, 1, 4, 4])
check("conv2d padding 1 corner", F.conv2d(img, ker, none, 1, 1).data[0], -1.0)
check("conv2d stride 2", F.conv2d(img, Tensor([[[[1.0]]]]), none, 2).data, [1.0, 3.0, 7.0, 9.0])
var sob = Tensor([[[[-1.0, 0.0, 1.0], [-2.0, 0.0, 2.0], [-1.0, 0.0, 1.0]]]])
check("sobel-x on a horizontal ramp", F.conv2d(img, sob).data, [8.0])
grad_check("conv2d (2 in, 2 out channels, bias, pad)", Tensor([[[[0.1, 0.2, 0.3], [0.4, -0.5, 0.6], [0.7, 0.8, -0.9]], [[1.0, 0.0, -1.0], [0.5, 0.5, 0.5], [0.2, 0.1, 0.0]]]], true), lambda x: F.conv2d(x, Tensor([[[[1.0, 2.0], [3.0, 4.0]], [[0.5, -0.5], [0.25, 0.0]]], [[[0.0, 1.0], [1.0, 0.0]], [[2.0, 0.0], [0.0, -2.0]]]]), Tensor([0.1, -0.2]), 1, 1).pow(2.0).sum(), 0.00001)
torch.manual_seed(0)
var c2 = Conv2d(3, 4, 3, 1, 1)
check("Conv2d(3,4,3,pad=1) output shape", c2.forward(torch.randn([2, 3, 5, 5])).shape, [2, 4, 5, 5])
var c1 = Conv1d(2, 3, 3)
check("Conv1d(2,3,3) uses its channels (was [13.0])", c1.forward(torch.randn([4, 2, 10])).shape, [4, 3, 8])
check("Conv1D (older name) is the real layer", Conv1D(1, 2, 3).forward(Tensor([[1.0, 2.0, 3.0, 4.0, 5.0, 6.0]])).shape, [2, 4])
var mp = F.max_pool2d(Tensor([[[[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0], [9.0, 10.0, 11.0, 12.0], [13.0, 14.0, 15.0, 16.0]]]], true), 2)
check("max_pool2d values", mp.data, [6.0, 8.0, 14.0, 16.0])
check("avg_pool2d values", F.avg_pool2d(Tensor([[[[1.0, 2.0], [3.0, 4.0]]]]), 2).data, [2.5])
var bn = BatchNorm1d(2)
var bnx = Tensor([[1.0, 2.0], [3.0, 4.0]])
check_list("BatchNorm1d training output", bn.forward(bnx).data, [-0.99999500003750, -0.99999500003750, 0.99999500003750, 0.99999500003750], 0.00000001)
check_list("running_mean (momentum 0.1)", bn.running_mean.data, [0.2, 0.3], 0.000000000001)
check_list("running_var uses unbiased batch var", bn.running_var.data, [1.1, 1.1], 0.000000000001)
bn.eval()
check_list("eval mode uses running stats", bn.forward(Tensor([[0.2, 0.3]])).data, [0.0, 0.0], 0.000000000001)
check("BatchNorm2d shape", BatchNorm2d(3).forward(torch.randn([2, 3, 4, 4])).shape, [2, 3, 4, 4])
check_list("LayerNorm", LayerNorm(3).forward(Tensor([1.0, 2.0, 3.0])).data, [-1.2247356859083902, 0.0, 1.2247356859083902], 0.000000000001)
var emb = Embedding(4, 2)
emb.weight.data = [0.0, 0.1, 1.0, 1.1, 2.0, 2.1, 3.0, 3.1]
var e = emb.forward(Tensor([[2, 0, 2]]))
check("Embedding output shape", e.shape, [1, 3, 2])
check("Embedding rows", e.data, [2.0, 2.1, 0.0, 0.1, 2.0, 2.1])
e.sum().backward()
check("Embedding grad accumulates repeated index", emb.weight.grad, [1.0, 1.0, 0.0, 0.0, 2.0, 2.0, 0.0, 0.0])
var dr = Dropout(0.5)
dr.eval()
check("Dropout is identity in eval", dr.forward(Tensor([1.0, 2.0])).data, [1.0, 2.0])

print("== linear / recurrent / attention shapes ==")
var lin = Linear(3, 2)
lin.weight.data = [1.0, 0.0, 0.0, 0.0, 1.0, 1.0]
lin.bias.data = [0.5, -0.5]
check("Linear 1-d", lin.forward(Tensor([1.0, 2.0, 3.0])).data, [1.5, 4.5])
check("Linear batched", lin.forward(Tensor([[1.0, 2.0, 3.0], [0.0, 0.0, 1.0]])).data, [1.5, 4.5, 0.5, 0.5])
check("Linear any leading dims", lin.forward(torch.ones([4, 5, 3])).shape, [4, 5, 2])
var rnn = RNN(3, 5, 2)
var ro = rnn.forward(torch.randn([7, 4, 3]))
check("RNN output (L, N, H)", ro[0].shape, [7, 4, 5])
check("RNN h_n (layers, N, H)", ro[1].shape, [2, 4, 5])
var lstm = LSTM(3, 6, 1, true)
var lo = lstm.forward(torch.randn([4, 7, 3]))
check("LSTM batch_first output", lo[0].shape, [4, 7, 6])
check("LSTM c_n", lo[1][1].shape, [1, 4, 6])
check("GRU unbatched", GRU(3, 4).forward(torch.randn([5, 3]))[0].shape, [5, 4])
var mha = MultiheadAttention(8, 2)
var q = torch.randn([5, 3, 8])
var ar = mha.forward(q, q, q, none, none)
check("MultiheadAttention output (L, N, E)", ar[0].shape, [5, 3, 8])
check("MultiheadAttention weights (N, L, S)", ar[1].shape, [3, 5, 5])
check_close("attention rows sum to 1", ar[1].sum(-1).mean().item(), 1.0, 0.000000000001)
var causal = mha.forward(q, q, q, causal_mask(5), none)[1]
check_close("causal mask zeroes future positions", causal.select(0, 0).select(0, 0).data[1], 0.0, 0.0)
var tel = TransformerEncoderLayer(8, 2, 16, 0.0)
check("TransformerEncoderLayer shape", tel.forward(q, none, none).shape, [5, 3, 8])

print("== optimizer steps vs hand ==")
var p1 = Parameter(Tensor([1.0, 2.0]))
p1.grad = [0.5, -1.0]
SGD([p1], 0.1).step()
check_list("SGD", p1.data, [0.95, 2.1], 0.000000000001)
var p2 = Parameter(Tensor([1.0]))
var sgdm = SGD([p2], 0.1, 0.9)
p2.grad = [1.0]
sgdm.step()
p2.grad = [1.0]
sgdm.step()
check_list("SGD momentum 0.9, two steps: 1 - 0.1 - 0.19", p2.data, [0.71], 0.000000000001)
var p3 = Parameter(Tensor([1.0]))
var adam = Adam([p3], 0.1)
p3.grad = [0.5]
adam.step()
check_list("Adam first step", p3.data, [0.900000002], 0.000000001)
var p4 = Parameter(Tensor([1.0]))
var adamw = AdamW([p4], 0.1, none, 0.00000001, 0.1)
p4.grad = [0.5]
adamw.step()
check_list("AdamW decoupled decay", p4.data, [0.890000002], 0.000000001)
var p5 = Parameter(Tensor([1.0]))
var rms = RMSprop([p5], 0.01)
p5.grad = [1.0]
rms.step()
check_list("RMSprop", p5.data, [0.900000009999999], 0.000000001)
var sched = StepLR(SGD([p1], 1.0), 2, 0.5)
sched.step()
check("StepLR after 2 steps", sched.step(), 0.5)
var legacy = SGD(0.1)
check_list("older SGD(lr).step(params, grads)", legacy.step([[1.0, 2.0]], [[0.5, -1.0]])[0], [0.95, 2.1], 0.000000000001)

print("== DataLoader ==")
var X = Tensor([[1.0, 1.0], [2.0, 2.0], [3.0, 3.0], [4.0, 4.0], [5.0, 5.0]])
var Y = Tensor([0, 1, 2, 3, 4])
var dl = DataLoader(TensorDataset(X, Y), 2)
var bs = dl.batches()
check("number of batches", len(bs), 3)
check("len(loader)", len(dl), 3)
check("first batch X", bs[0][0].data, [1.0, 1.0, 2.0, 2.0])
check("last batch Y", bs[2][1].data, [4.0])
torch.manual_seed(42)
var sb = DataLoader(TensorDataset(X, Y), 5, true).batches()
var seen = sorted(sb[0][1].data)
check("shuffle is a permutation", seen, [0.0, 1.0, 2.0, 3.0, 4.0])
torch.manual_seed(42)
check("shuffle reproducible with manual_seed", DataLoader(TensorDataset(X, Y), 5, true).batches()[0][1].data, sb[0][1].data)

print("== save / load ==")
var path = "/tmp/vm_audit47_state.nyt"
torch.manual_seed(1)
var net = Sequential(Linear(2, 3), ReLU(), Linear(3, 1))
var keys = sorted(net.state_dict().keys())
check("state_dict keys", keys, ["layers.0.bias", "layers.0.weight", "layers.2.bias", "layers.2.weight"])
torch.save(net.state_dict(), path)
var net2 = Sequential(Linear(2, 3), ReLU(), Linear(3, 1))
net2.load_state_dict(torch.load(path))
var probe = Tensor([[0.3, -0.7]])
check("loaded model gives identical output", net2.forward(probe).data, net.forward(probe).data)
torch.save(Tensor([[0.1, 2.0], [3.0, 4.0]]), path)
var back = torch.load(path)
check("float64 round trip (0.1 stays 0.1)", back.data, [0.1, 2.0, 3.0, 4.0])
check("shape round trip", back.shape, [2, 2])
tensor_save([1, 2, 3], path)
check("legacy tensor_save keeps integers (was 0.0)", tensor_load(path), [1.0, 2.0, 3.0])
var bad_load = false
try:
    net2.load_state_dict({"layers.0.weight": Tensor([1.0])})
except e:
    bad_load = true
check("load_state_dict rejects a mismatched state", bad_load, true)

print("== training with Module + optimizer converges ==")
torch.manual_seed(7)
var model = Sequential(Linear(2, 8), Tanh(), Linear(8, 2))
var opt = Adam(model.parameters(), 0.05)
var xs = Tensor([[0.0, 0.0], [0.0, 1.0], [1.0, 0.0], [1.0, 1.0]])
var ys = [0, 1, 1, 0]
var first = 0.0
var last = 0.0
var step = 0
while step < 200:
    opt.zero_grad()
    var loss = cross_entropy(model.forward(xs), ys)
    if step == 0:
        first = loss.item()
    loss.backward()
    opt.step()
    last = loss.item()
    step = step + 1
print("XOR loss " + str(first) + " -> " + str(last))
check("XOR loss fell by 100x", last < first * 0.01, true)
var pred = model.forward(xs).argmax(1).data
check("XOR all four rows correct", pred, [0, 1, 1, 0])
check("parameter count 2*8+8+8*2+2", model.num_parameters(), 42)

print("== CNN trains on a toy task ==")
torch.manual_seed(3)
var cnn = Sequential(Conv2d(1, 2, 3, 1, 1), ReLU(), MaxPool2d(2), Flatten(), Linear(8, 2))
var copt = SGD(cnn.parameters(), 0.1, 0.9)
# class 1: bright top half, class 0: bright bottom half
var cx = Tensor([[[[1, 1, 1, 1], [1, 1, 1, 1], [0, 0, 0, 0], [0, 0, 0, 0]]], [[[0, 0, 0, 0], [0, 0, 0, 0], [1, 1, 1, 1], [1, 1, 1, 1]]], [[[0.9, 1, 0.8, 1], [1, 0.7, 1, 1], [0, 0.1, 0, 0], [0.2, 0, 0, 0]]], [[[0, 0.1, 0, 0], [0, 0, 0.2, 0], [1, 0.9, 1, 0.8], [1, 1, 0.9, 1]]]])
var cy = [1, 0, 1, 0]
var cfirst = 0.0
var clast = 0.0
var cs = 0
while cs < 60:
    copt.zero_grad()
    var closs = cross_entropy(cnn.forward(cx), cy)
    if cs == 0:
        cfirst = closs.item()
    closs.backward()
    copt.step()
    clast = closs.item()
    cs = cs + 1
check("CNN loss fell by 10x", clast < cfirst * 0.1, true)
check("CNN classifies the training set", cnn.forward(cx).argmax(1).data, [1, 0, 1, 0])

print("== audio / CTC / detection kernels ==")
check_close("ctc_loss: T=2, uniform p, target [1] -> -log(3/4)", nt_ctc_loss([log(0.5), log(0.5), log(0.5), log(0.5)], [2, 2], [1], 0)[0], 0.2876820724517809, 0.000000000001)
var fb = nt_mel_filterbank(4, 16, 16000, 0.0, 8000.0)
check("mel filterbank shape [n_mels, n_fft/2+1]", fb[1], [4, 9])
var fbd = fb[0]
var peak_ok = true
var r = 0
while r < 4:
    var best = 0.0
    var c = 0
    while c < 9:
        if fbd[r * 9 + c] > best:
            best = fbd[r * 9 + c]
        c = c + 1
    if best <= 0.0 or best > 1.0:
        peak_ok = false
    r = r + 1
check("every mel filter is a triangle peaking in (0, 1]", peak_ok, true)
var sp = nt_stft([0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, -1.0], 4, 4, false)
check_list("stft (Hann, period-4 tone): all energy in bin 1", sp[0], [0.0, 0.0, 1.0, 1.0, 0.0, 0.0], 0.000000000001)
check("nms drops the overlapping box", nms([[0, 0, 10, 10], [1, 1, 11, 11], [20, 20, 30, 30]], [0.9, 0.8, 0.7], 0.5), [0, 2])

print("== one definition per class name ==")
# lib/nytorch.ny loads every submodule; the class a name resolves to must be
# the real one whichever file was imported last (these used to be shadowed
# by fakes: a TransformerEncoderLayer returning random lists, a second
# GATLayer/GraphSAGE/DDPMScheduler, four KnowledgeBase classes).
torch.manual_seed(2)
var tel = TransformerEncoderLayer(8, 2, 16, 0.0)
check("TransformerEncoderLayer is the Module", isinstance(tel, Module), true)
check("TransformerEncoderLayer keeps (L, E)", tel.forward(Tensor(nt_randn([3, 8]), false, [3, 8]), none, none).shape, [3, 8])
check("GATLayer is the attention one", GATLayer(4, 3, 2, 0.0).forward([[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0]], [[1], [0]]).shape, [2, 3])
check("GraphSAGE takes (in, hidden, out, layers, aggregator)", GraphSAGE(4, 5, 2, 2, "mean").forward([[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0]], [[1], [0]]).shape, [2, 2])
check("DDPMScheduler is the full scheduler", len(DDPMScheduler(10, 0.0001, 0.02).alphas_cumprod), 10)
var kbase = KnowledgeBase("/tmp/vm_audit47_kb")
check("KnowledgeBase is the storage one", kbase.has("nothing"), false)
# Needs a Python 3 on PATH (python3, or python on Windows); skipped without.
var py = which("python3") ?? which("python")
if py != none:
    var cc = os_run([py, "tools/ny_classcheck.py"], merge=true)["stdout"]
    check("tools/ny_classcheck.py finds no duplicate class names", string_find(cc, "no duplicate") >= 0, true)
else:
    print("  (no python3 on PATH: tools/ny_classcheck.py not run)")

print("")
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT47 PASSED ===")
else:
    print("=== VM_AUDIT47 FAILED ===")
