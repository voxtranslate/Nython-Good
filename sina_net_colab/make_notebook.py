"""Builds SINA_Net_v4_Colab.ipynb from sina_net_v4_colab.py (run after editing the script)."""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "sina_net_v4_colab.py")).read()
tail = src.index('if __name__ == "__main__":')
defs = src[:tail] + ('if __name__ == "__main__" and os.environ.get("SINA_LAUNCHED"):  # DDP worker started by main()\n'
                     '    main(None)\n')


def md(text):
    return {"cell_type": "markdown", "metadata": {}, "source": text.strip("\n").splitlines(True)}


def code(text):
    return {"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [],
            "source": text.strip("\n").splitlines(True)}


cells = [
    md("""
# SINA-Net v4 on Google Colab (G4 GPU)

1. **Runtime -> Change runtime type -> G4 GPU** (NVIDIA RTX PRO 6000 Blackwell, 96 GB). Other GPUs work too.
2. Run the cells in order. The first run downloads the full datasets **once** into
   `/content/drive/MyDrive/Datasets/{GoPro, HIDE, DPDD, Rain13K, SIDD}` (about 45 GB of verified archives,
   so make sure your Drive has room); later sessions extract them from Drive to the fast local SSD.
3. Everything else (checkpoints, restored images, figures, tables, `REPORT.md`) is written to
   `/content/drive/MyDrive/SINA-Net-v4/`. When a session ends, open a new one and run the same cells:
   training resumes from Drive.
"""),
    code("""
# 1) Google Drive + hardware check
from google.colab import drive
drive.mount('/content/drive')
!nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
!nproc; free -h | head -2; df -h /content | tail -1
"""),
    md("## 2) SINA-Net v4 (definitions only; nothing runs yet)"),
    code(defs),
    md("""
## 3) Choose the experiment and run
* `PRESET`: `all_in_one` (one model, four tasks) or a specialist: `deblur` (GoPro/HIDE), `defocus` (DPDD),
  `derain` (Rain13K), `denoise` (SIDD). The published SOTA tables are all specialist models.
* The start-up plan prints the estimated GPU hours for the full 300K-iteration schedule.
"""),
    code("""
PRESET = "all_in_one"                # all_in_one | deblur | defocus | derain | denoise
cfg = Config()
apply_preset(cfg, PRESET)
# cfg.max_session_hours = 23.5       # Colab Pro+ with background execution (default 11.5)
# cfg.total_iters = 150_000          # shorter schedule (progressive milestones scale with it)
# cfg.run_training_ablation = True   # retrain every ablation variant (hours; resumable across sessions)
# cfg.evaluate_if_incomplete = True; cfg.max_test_images = 50   # monitor before training has finished
bundle = main(cfg)
"""),
    md("""
## 4) Evaluation / analysis only (uses `best.pth` from Drive)
"""),
    code("""
cfg = Config(); apply_preset(cfg, PRESET)
cfg.run_training = False
bundle = main(cfg)
"""),
]
nb = {"cells": cells, "metadata": {"accelerator": "GPU", "colab": {"provenance": [], "gpuType": "G4"},
                                  "kernelspec": {"name": "python3", "display_name": "Python 3"},
                                  "language_info": {"name": "python"}},
      "nbformat": 4, "nbformat_minor": 0}
with open(os.path.join(HERE, "SINA_Net_v4_Colab.ipynb"), "w") as f:
    json.dump(nb, f, indent=1)
print("wrote SINA_Net_v4_Colab.ipynb")
