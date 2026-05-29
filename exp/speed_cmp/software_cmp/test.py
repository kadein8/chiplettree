"E:/learn_ai/.venv/Scripts/python.exe" -c "
import torch, time
print(f'PyTorch {torch.__version__}')
print(f'CUDA: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU: {torch.cuda.get_device_name(0)}')
    device = 'cuda'
else:
    device = 'cpu'

d_model, n_heads, head_dim, n_layers, intermediate, vocab_size = 128, 2, 64, 2, 256, 16
torch.manual_seed(42)

embed = torch.randn(vocab_size, d_model, dtype=torch.float16, device=device) * 0.125
layers = [{'wq': torch.randn(d_model,d_model,dtype=torch.float16,device=device)*0.1,
            'wk': torch.randn(d_model,d_model,dtype=torch.float16,device=device)*0.1,
            'wv': torch.randn(d_model,d_model,dtype=torch.float16,device=device)*0.1,
            'wo': torch.randn(d_model,d_model,dtype=torch.float16,device=device)*0.1,
            'gate': torch.randn(intermediate,d_model,dtype=torch.float16,device=device)*0.1,
            'up': torch.randn(intermediate,d_model,dtype=torch.float16,device=device)*0.1,
            'down': torch.randn(d_model,intermediate,dtype=torch.float16,device=device)*0.1,
           } for _ in range(n_layers)]

def tree_verify(branches_tokens):
    results = []
    for tokens in branches_tokens:
        x = embed[tokens]
        seq_len = x.shape[0]
        for L in layers:
            q = x @ L['wq'].T
            k = x @ L['wk'].T
            v = x @ L['wv'].T
            scores = q @ k.T / 8.0
            mask = torch.triu(torch.ones(seq_len,seq_len,device=device),diagonal=1)*-65504
            attn = torch.softmax((scores+mask.half()).float(), dim=-1).half()
            x = x + (attn @ v) @ L['wo'].T
            g = x @ L['gate'].T
            u = x @ L['up'].T
            x = x + (torch.sigmoid(g.float()).half() * g * u) @ L['down'].T
        results.append((x[-1:] @ embed.T).argmax().item())
    return results

branches = [torch.tensor([0],device=device), torch.tensor([0,13],device=device),
            torch.tensor([0,13,13],device=device), torch.tensor([0,12],device=device)]

# Warmup
for _ in range(10): tree_verify(branches)
if device=='cuda': torch.cuda.synchronize()

N = 1000
start = time.perf_counter()
for _ in range(N): tree_verify(branches)
if device=='cuda': torch.cuda.synchronize()
elapsed = time.perf_counter() - start

per_round_us = elapsed/N*1e6
print(f'\nPyTorch ({device}) tree verify, 4 branches, toy model:')
print(f'  Per round: {per_round_us:.1f} us')
print(f'\nRTL @ 1GHz: 490 us')
if per_round_us < 490:
    print(f'PyTorch is {490/per_round_us:.1f}x faster than RTL')
else:
    print(f'RTL is {per_round_us/490:.1f}x faster than PyTorch')
"
