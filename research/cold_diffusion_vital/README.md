# ViTAL-CF — Clock-Field Cold Diffusion

A single-file PyTorch pipeline (`cold_diffusion_vital.py`) that reorganises and extends the
original *Cold Diffusion with ViTAL (no VQ)* script into:

| Section | Class / function |
|---|---|
| 1 Configuration | `Config` (dataclass, JSON save/load) |
| 3 Physics | `HeatKernel` (exact Neumann heat operator), `ColdDegradation` (blur / noise / mask / downsample, per-pixel clock fields) |
| 4 Data | `ImageDataset`, `SyntheticImageDataset` (fallback), `build_datasets` |
| 5 Model | `ViTAL` backbone, `SpectralClockEstimator`, `ClockAwareSpectralGate`, `ColdDiffusionModel` (samplers, blind restoration, generation) |
| 6 Losses | `ColdDiffusionLoss` (+ optional `PerceptualLoss`) |
| 7 Metrics | PSNR, SSIM, LPIPS (pyiqa), Null-Space Recovery, radial spectra |
| 8 Training | `Trainer` (+ `EMA`) |
| 9 Inference | `Inferencer` |
| 10 Entry points | `main()`, `deblur_image_pipeline()` |

The script has no `argparse` or `sys` handling. Edit `Config`, then run
`python cold_diffusion_vital.py`. Alternatively, call `main(Config(...))` from a notebook.
If the Kaggle folders in `Config` do not exist, the script trains on procedural images, so
the whole pipeline can be checked anywhere.

## The two headline contributions

### [N1] Spectral Clock Field: blind, spatially varying cold diffusion
The scalar time `t` of cold diffusion becomes a **per-pixel clock field** `τ(x) ∈ [0,1]`:

* **Forward operator.** A spatially varying heat dissipation `D(x, τ(·))`. It is built from a
  bank of exact DCT-domain heat kernels, which are linearly interpolated per pixel between
  anchor levels. Noise and mask degradations are applied exactly per pixel.
* **Conditioning.** *Clock-Modulated Normalisation*,
  `GN(h)·(1+γ_g(f)+γ_s(E(τ)))+β_g(f)+β_s(E(τ))`, where `E(τ)` is a per-pixel Fourier
  embedding of the clock that is pooled to every resolution.
* **Estimator.** The *Spectral Clock Estimator* works from physics features. Gaussian blur
  attenuates band `j` by `≈exp(−σ²ω_j²)`, so `log E_j − log E_{j+1}` is locally *linear in σ²*.
  A dilated CNN turns these features into a Laplace distribution `(μ(x), b(x))` over `τ`.
  Normalised convolution with confidence `1/b` then propagates the clock into flat regions,
  where blur cannot be identified.
* **Sampling.** *Synchronised Field Descent*, `τ_k(x) = τ_obs(x)·(1−k/K)^ρ`: every pixel
  reaches τ = 0 on the same step. The number of steps adapts to `max τ_obs`, and a
  user-controlled strength `κ` scales the clock (`τ_obs = κ·τ̂`).

**Closest prior work.** SVNR (per-pixel times, *noise only*, asynchronous, noise map from a
camera model). DynFaceRestore and SuperSharpen (one *global* blur level or start step).
Cold diffusion (Bansal et al.; a scalar, known t).

### [N2] Spectral Range–Null Cold Sampler (SRN-CS)
Bansal's improved update `x_s = x_t − D(x̂₀,t) + D(x̂₀,s)` is combined with an exact
Fourier-domain range/null decomposition of `x̂₀` with respect to the observation `y`:

```
x̂₀ ← x̂₀ + η · F⁻¹[ K_τ/(K_τ² + λ) · F(y − D(x̂₀, τ_obs)) ]
```

* Frequencies that the operator keeps (the range space, `K² ≫ λ`) come from the data.
* Annihilated frequencies (the null space) are left to the network.
* Clock fields use local anchors. Masks use an exact projection; downsampling uses
  back-projection.

This carries the DDNM idea (zero-shot, Gaussian diffusion) over to **trained, deterministic,
heat-dissipation trajectories** and to spatially varying operators.

## Supporting contributions
| Tag | Component | Idea |
|---|---|---|
| N3 | Clock-Aware Spectral Gate | Feature-space inverse-heat filter `exp(c·tanh(a·σ_f²|ω|²/2c))` (learned partial inversion, smooth ceiling) plus a learned residual spectral response, spatially gated by the clock |
| N4 | Sampler-Consistent Rollout loss | The model is also trained on the exact Algorithm-2 state produced by its own detached `x̂₀`. This closes the exposure gap of cold sampling and provides self-conditioning, with no teacher or extra network |
| N5 | Null-Space Spectral loss | Fourier L1 weighted by the annihilation spectrum `(1−|K_τ|²)^γ` of the actual degradation |
| N6 | Mean-decoupled β-Laplace uncertainty | The NLL trains only the scale head. Uncertainty maps, reliability diagrams and uncertainty-gated stochastic refinement come from it |
| N7 | Exact continuous heat operator | Even-extension FFT (equivalent to a DCT), with σ(0)=0. There is no kernel truncation and no dark borders |
| N8 | Degraded-prior bank | Generation starts from a Gaussian fitted to thumbnails of maximally degraded images, not from white noise |
| — | NSR metric | *Null-Space Recovery*: the fraction of the annihilated-band error that restoration removed |

## Main bugs fixed from the original script
* The time was normalised twice (`t/T/T`) and the sinusoidal embedding was fed `t∈[0,1]`
  unscaled. As a result the network never saw the time.
* The "importance" timestep sampling (weights `1/σ`) drew almost only near-clean steps.
* The random mask was re-drawn on every call, which is not a cold degradation.
* Blur kernels were truncated to 31 taps with zero padding.
* U-Net skips were misaligned by one level, and the full-resolution skip was missing.
* BatchNorm was used with batch size 3.
* The Swin block rolled the input before padding it.
* On resume, the metrics were overwritten after the checkpoint had loaded them.
* Validation was random.
* The naive Algorithm 1 sampler was used for a smooth degradation.
* `sample()` started from Gaussian noise for a blur model.
* Real-image deblurring always started at maximum blur and added noise with a standard
  deviation of up to 1.5.
* The dataclass imports were missing. `cv2` and `glob` were imported but not used.

## What the trainer and inferencer save
* **Trainer** (`checkpoint_dir`):
  * `checkpoint_latest.pt`, `checkpoint_best.pt` and the last *k* epoch checkpoints. Each
    holds the model, EMA, optimiser, scheduler, scaler, RNG state and history.
  * Automatic resume, including interrupted epochs.
  * `training_curves.png` (train vs. valid: total loss, L1, PSNR, SSIM, clock MAE, LR),
    `history.json/.csv` and periodic visual snapshots.
* **Inferencer** (`output_dir/inference`):
  * sampler × degradation-level benchmark (CSV/JSON plus quality-vs-τ plots);
  * restoration demos with a known clock and with a blind (estimated) clock;
  * evaluation of the clock estimator (hexbin plot and calibration);
  * unconditional generation (grid, prior samples, trajectory GIF);
  * blind restoration of real photos (full-resolution output, clock field, confidence,
    uncertainty, spectra, GIF) and a restoration-strength sweep;
  * an **interpretability** folder: trajectory strip, GIF and per-step PSNR; Swin attention
    maps with per-head distance and entropy; feature PCA of every stage; spectral-gate gain
    curves against the physical inverse heat; range/null decomposition with data
    consistency; radial spectra; uncertainty reliability diagram; clock-sensitivity map
    `∂x̂₀/∂τ`; physics features; raw tensors (`.pt`).

## Suggested experimental protocol (for the article)
* **Where the model fits best.** The operator is *isotropic heat dissipation*. The natural
  targets are defocus and Gaussian-type blur, which are spatially varying:
  * DPDD / RealDOF (defocus);
  * synthetic spatially varying Gaussian blur on DIV2K / Flickr2K / Urban100;
  * CUHK blur detection, to evaluate the clock field as a blur map.
* **Motion blur** (GoPro, HIDE, RealBlur) needs an anisotropic operator — see the
  limitations below.
* **Baselines:**
  * regression models: Restormer, NAFNet, FFTformer, MLWNet, EVSSM;
  * diffusion models: HI-Diff, DiffIR, FideDiff, DeblurDiff;
  * bridge / flow models: IR-SDE/Refusion, GOUB, RDBM, InDI;
  * cold diffusion: Bansal et al. (Alg. 1 and Alg. 2).
* **Metrics:** PSNR, SSIM, LPIPS, DISTS and FID; NIQE, MUSIQ and MANIQA for real photos;
  NSR; clock-map MAE.
* **Ablations**, all of which are switches in `Config`:
  * scalar t vs. clock field;
  * with vs. without the estimator's physics features;
  * `sampler ∈ {direct, naive, improved, srn}`;
  * `use_spectral_gate`;
  * `lambda_rollout`, `lambda_freq`, `lambda_unc` and `lambda_cycle` set to 0;
  * `self_condition`;
  * the schedule type.

## Status and limitations (honest)
* The code was verified on CPU with a tiny configuration (64×64 synthetic images). The
  checks covered:
  * unit checks of the operators: FFT heat vs. symmetric convolution, the semigroup
    property, identity at τ=0, nested masks, range–null consistency, and the noise cold
    step being equal to DDIM;
  * end-to-end runs of every degradation type;
  * automatic resume, bf16 autocast, odd image sizes, and gradient reaching every parameter.
* **No benchmark numbers exist yet.** Paper results require full GPU training.
* The novelty claims come from a literature search done in September 2026. Run a dedicated
  related-work search before submission; search engines miss papers.
* The heat operator is isotropic. Motion blur would need an anisotropic or learned-kernel
  operator in `ColdDegradation`. The clock-field machinery would still apply.
