#!/usr/bin/env python3
"""
HHT Confidence vs Generation Speed Experiment

Measures how prediction accuracy affects tokens/cycle throughput
in the speculative decode architecture.

Approach:
- Vary the `known_seq` in draft_injection_interface to simulate
  different HHT prediction accuracies (0% to 100%)
- For each accuracy level, run VCS simulation and measure:
  - Total cycles to generate 8 tokens
  - Number of rounds (fewer rounds = better speculation)
  - Average cycles per token
"""

import paramiko
import re
import json
import os
from pathlib import Path

# RTL output sequence (from previous simulation with KV cache)
# Token[0..7] = [13, 13, 13, 11, 15, 11, 10, 12]
RTL_SEQUENCE = [13, 13, 13, 11, 15, 11, 10, 12]

# Experiment configurations:
# accuracy_pct -> how many of the first N draft predictions match the actual sequence
# We control this by setting known_seq to match different depths of the actual output
EXPERIMENTS = {
    "0%": {
        "known_seq": [0, 99, 99, 99, 99],  # All wrong predictions
        "description": "Random predictions (0% accuracy)"
    },
    "25%": {
        "known_seq": [0, 13, 99, 99, 99],  # Only first prediction correct
        "description": "First token correct (25% tree depth)"
    },
    "50%": {
        "known_seq": [0, 13, 13, 99, 99],  # First two correct
        "description": "First two tokens correct (50% tree depth)"
    },
    "75%": {
        "known_seq": [0, 13, 13, 13, 99],  # First three correct
        "description": "First three tokens correct (75% tree depth)"
    },
    "100%": {
        "known_seq": [0, 13, 13, 13, 13],  # All correct (fixed point)
        "description": "All predictions correct (100% accuracy)"
    },
}

def generate_draft_interface(known_seq, output_path):
    """Read the template and replace known_seq values"""
    template_path = output_path
    with open(template_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Replace known_seq values
    for i, val in enumerate(known_seq):
        old = f"known_seq[{i}] = 16'd"
        # Find and replace the line
        lines = content.split('\n')
        for j, line in enumerate(lines):
            if f"known_seq[{i}]" in line and "=" in line:
                lines[j] = f"        known_seq[{i}] = 16'd{val};"
                break
        content = '\n'.join(lines)

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(content)

def run_experiment(ssh, sftp, known_seq, exp_name):
    """Run one experiment with given known_seq, return (total_cycles, total_tokens, rounds)"""
    # Generate modified draft_injection_interface
    local_path = 'e:/Paper/Chen/first/code/exp/HHT_confidence_and_speed/rtl/tree_control/draft_injection_interface.sv'
    generate_draft_interface(known_seq, local_path)

    # Upload
    with open(local_path, 'r', encoding='utf-8') as f:
        content = f.read()
    with sftp.open('/home/ICer/first/code/exp/HHT_confidence_and_speed/rtl/tree_control/draft_injection_interface.sv', 'w') as rf:
        rf.write(content)

    # Run simulation
    cmd = 'cd /home/ICer/first/code/exp/HHT_confidence_and_speed && bash script/run_tc_compare.sh 2>&1 | grep -E "Token|round done|PASS|FAIL|cycles"'
    stdin, stdout, stderr = ssh.exec_command(cmd, timeout=600)
    output = stdout.read().decode('utf-8', errors='replace')

    # Parse results
    tokens = []
    rounds = 0
    total_cycles = 0

    for line in output.split('\n'):
        m = re.search(r'Token\[\d+\]\s*=\s*\d+\s*\(cycle\s+(\d+)\)', line)
        if m:
            tokens.append(int(m.group(1)))
        if 'round done' in line:
            rounds += 1
            m2 = re.search(r'emitted\s+(\d+)\s+tokens', line)

    if tokens:
        total_cycles = tokens[-1]  # Last token's cycle count
    total_tokens = len(tokens)

    return {
        'name': exp_name,
        'total_cycles': total_cycles,
        'total_tokens': total_tokens,
        'rounds': rounds,
        'avg_cycles_per_token': total_cycles / total_tokens if total_tokens > 0 else 0,
        'tokens_per_round': total_tokens / rounds if rounds > 0 else 0,
    }

def main():
    print("=" * 60)
    print("HHT Confidence vs Generation Speed Experiment")
    print("=" * 60)

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect('192.168.198.159', username='ICer', password='2022')
    sftp = ssh.open_sftp()

    # First, upload all necessary files (ensure the experiment dir is synced)
    base = 'e:/Paper/Chen/first/code/exp/HHT_confidence_and_speed'
    results = []

    for exp_name, config in EXPERIMENTS.items():
        print(f"\n--- Running experiment: {exp_name} ({config['description']}) ---")
        result = run_experiment(ssh, sftp, config['known_seq'], exp_name)
        results.append(result)
        print(f"  Tokens: {result['total_tokens']}, Rounds: {result['rounds']}, "
              f"Cycles: {result['total_cycles']}, Avg: {result['avg_cycles_per_token']:.0f} cyc/tok")

    sftp.close()
    ssh.close()

    # Save results
    out_dir = Path(base) / 'results'
    out_dir.mkdir(exist_ok=True)
    with open(out_dir / 'experiment_results.json', 'w') as f:
        json.dump(results, f, indent=2)

    print("\n" + "=" * 60)
    print("Results Summary:")
    print(f"{'Accuracy':<10} {'Tokens':<8} {'Rounds':<8} {'Cycles':<10} {'Cyc/Tok':<10} {'Tok/Round':<10}")
    print("-" * 60)
    for r in results:
        print(f"{r['name']:<10} {r['total_tokens']:<8} {r['rounds']:<8} "
              f"{r['total_cycles']:<10} {r['avg_cycles_per_token']:<10.0f} {r['tokens_per_round']:<10.2f}")

    # Generate plot
    try:
        import matplotlib.pyplot as plt
        import numpy as np

        accuracies = [0, 25, 50, 75, 100]
        cyc_per_tok = [r['avg_cycles_per_token'] for r in results]
        tok_per_round = [r['tokens_per_round'] for r in results]

        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

        # Plot 1: Cycles per token vs accuracy
        ax1.plot(accuracies, cyc_per_tok, 'bo-', linewidth=2, markersize=8)
        ax1.set_xlabel('HHT Prediction Accuracy (%)', fontsize=12)
        ax1.set_ylabel('Average Cycles per Token', fontsize=12)
        ax1.set_title('Generation Latency vs Prediction Accuracy', fontsize=13)
        ax1.grid(True, alpha=0.3)
        ax1.set_xticks(accuracies)

        # Add serial baseline
        serial_cyc = cyc_per_tok[0]  # 0% accuracy = serial
        ax1.axhline(y=serial_cyc, color='r', linestyle='--', alpha=0.5, label=f'Serial baseline ({serial_cyc:.0f})')
        ax1.legend()

        # Plot 2: Tokens per round vs accuracy
        ax2.plot(accuracies, tok_per_round, 'gs-', linewidth=2, markersize=8)
        ax2.set_xlabel('HHT Prediction Accuracy (%)', fontsize=12)
        ax2.set_ylabel('Tokens per Verification Round', fontsize=12)
        ax2.set_title('Speculation Efficiency vs Prediction Accuracy', fontsize=13)
        ax2.grid(True, alpha=0.3)
        ax2.set_xticks(accuracies)
        ax2.set_ylim(bottom=0.8)

        plt.tight_layout()
        plt.savefig(str(out_dir / 'hht_confidence_vs_speed.png'), dpi=150, bbox_inches='tight')
        plt.savefig(str(out_dir / 'hht_confidence_vs_speed.pdf'), bbox_inches='tight')
        print(f"\nPlot saved to: {out_dir / 'hht_confidence_vs_speed.png'}")

    except ImportError:
        print("\nmatplotlib not available, skipping plot generation")

if __name__ == '__main__':
    main()
